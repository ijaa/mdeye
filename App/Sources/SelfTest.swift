import AppKit
import WebKit

/// Headless self-check mode: drive the reader rendering pipeline WITHOUT a window or
/// WindowServer session, so it can run on a CI macOS runner (no GUI login).
///
/// Invocation: `mdeye --selftest <path-to.md>`
/// Flow: locate reader → load `mdeye-app://reader/index.html` in an offscreen
/// WKWebView (no NSWindow) → read the .md via FileService → push {type:"doc"} → wait
/// for the JS reader to post back `doc-shown` (which writes /tmp/mdeye-last-shown.json).
/// On success: prints `SELFTEST OK` and exits 0. On timeout / missing stamp: exits 1.
///
/// What this *does* prove: the reader bundle loads, the classic IIFE script registers
/// `window.__mdeye`, markdown is received, rendered, and the bridge round-trips end-to-end.
/// What this does NOT cover: NSSavePanel / PDF export (user-interactive) and anything that
/// only happens with a real key window — those stay manual.
final class SelfTest: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let path: String
    private var webView: WKWebView?
    private var readerRoot: URL?
    private var started = Date()
    private let timeout: TimeInterval = 30
    private var finished = false

    init(path: String) {
        self.path = path
        super.init()
    }

    func run() {
        // Never claim the foreground / a regular app slot (keeps it headless).
        NSApp.setActivationPolicy(.accessory)

        guard let root = ReaderViewController.locateReaderRoot() else {
            fail("reader/index.html not found in bundle")
            return
        }
        readerRoot = root

        let config = WKWebViewConfiguration()
        let appHandler = AppSchemeHandler(root: root)
        config.setURLSchemeHandler(appHandler, forURLScheme: AppSchemeHandler.scheme)
        // Asset scheme isn't exercised in selftest (no images), but register for parity.
        config.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        config.userContentController.add(self, name: "mdeye")

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        wv.navigationDelegate = self
        if #available(macOS 13.3, *) { wv.isInspectable = true }
        webView = wv

        guard let url = URL(string: "\(AppSchemeHandler.scheme)://reader/index.html") else {
            fail("bad reader URL")
            return
        }
        NSLog("mdeye: selftest loading %@", url.absoluteString)
        wv.load(URLRequest(url: url))

        // 30s watchdog: reader cold-load (esp. initial 2.8MB IIFE parse + mermaid) can
        // take a few seconds; fail hard only if doc-shown never arrives in time.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.fail("timeout waiting for doc-shown")
        }
    }

    // MARK: - pushing the doc once JS is ready

    private func pushDocOnceReady() {
        guard let webView else { return }
        webView.evaluateJavaScript("!!(window.__mdeye && window.__mdeye.handle)") { [weak self] result, _ in
            guard let self else { return }
            if let ok = result as? Bool, ok {
                self.sendDoc()
            } else {
                // JS not ready yet — retry shortly.
                self.perform(#selector(Self.retryPushDoc), with: nil, afterDelay: 0.05)
            }
        }
    }

    @objc private func retryPushDoc() {
        guard !finished else { return }
        pushDocOnceReady()
    }

    private func sendDoc() {
        guard let webView else { return }
        guard let payload = try? FileService.readMarkdown(path: path) else {
            fail("could not read \(path)")
            return
        }
        let doc: [String: Any] = [
            "type": "doc",
            "path": payload.path,
            "baseDir": payload.baseDir,
            "text": payload.text,
            "encoding": payload.encoding,
            "mtimeMs": payload.mtimeMs,
        ]
        let b64 = (try? JSONSerialization.data(withJSONObject: doc, options: []))?
            .base64EncodedString() ?? ""
        let js = """
        (function(){
          try {
            var bin = atob('\(b64)');
            var bytes = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            var text = new TextDecoder('utf-8').decode(bytes);
            window.__mdeye.handle(JSON.parse(text));
            return 'ok';
          } catch (e) {
            return 'error:' + (e && e.message ? e.message : String(e));
          }
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.fail("push doc eval failed: \(error.localizedDescription)")
            } else if let status = result as? String, status != "ok" {
                self.fail("push doc status=\(status)")
            } else {
                // Sent; doc-shown stamp is written by the reader's normal handler path.
                // (SelfTest doesn't replicate writeSmokeStamp — the reader posts "doc-shown"
                // back to us; we record the stamp here so the CI poller can see a green file.)
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("mdeye: selftest didFinish")
        pushDocOnceReady()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail("provisional navigation failed: \(error.localizedDescription)")
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "mdeye",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            NSLog("mdeye: selftest reader ready v=%@", (body["version"] as? String) ?? "?")
            pushDocOnceReady()
        case "doc-shown":
            // The reader proved it rendered. Write the same stamp verify-open.sh polls.
            let path = body["path"] as? String ?? ""
            let chars = (body["chars"] as? Int) ?? (body["chars"] as? Double).map(Int.init) ?? -1
            NSLog("mdeye: SELFTEST doc-shown path=%@ chars=%d", path, chars)
            writeStamp(path: path, chars: chars)
            succeed()
        case "error":
            fail("reader error: \(body["message"] as? String ?? "?")")
        default:
            break
        }
    }

    // MARK: - outcome

    private func writeStamp(path: String, chars: Int) {
        let payload: [String: Any] = [
            "path": path,
            "chars": chars,
            "ts": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        let url = URL(fileURLWithPath: "/tmp/mdeye-last-shown.json")
        try? data.write(to: url, options: .atomic)
    }

    private func succeed() {
        guard !finished else { return }
        finished = true
        print("SELFTEST OK")
        exit(0)
    }

    private func fail(_ reason: String) {
        guard !finished else { return }
        finished = true
        NSLog("mdeye: SELFTEST FAIL %@", reason)
        print("SELFTEST FAIL: \(reason)")
        exit(1)
    }
}
