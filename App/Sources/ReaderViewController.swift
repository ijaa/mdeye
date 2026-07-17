import AppKit
import WebKit

final class DropView: NSView {
    var onDropMarkdown: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        markdownPaths(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let path = markdownPaths(from: sender).first else { return false }
        onDropMarkdown?(path)
        return true
    }

    private func markdownPaths(from sender: NSDraggingInfo) -> [String] {
        let pb = sender.draggingPasteboard
        guard let items = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return []
        }
        return items.map(\.path).filter { path in
            let lower = path.lowercased()
            return lower.hasSuffix(".md")
                || lower.hasSuffix(".markdown")
                || lower.hasSuffix(".mdx")
                || lower.hasSuffix(".mdown")
                || lower.hasSuffix(".mkd")
                || lower.hasSuffix(".mkdn")
                || lower.hasSuffix(".mdwn")
        }
    }
}

final class ReaderViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView!
    private let assetHandler = AssetSchemeHandler()
    private var appSchemeHandler: AppSchemeHandler?
    private let fileWatcher = FileWatcher()
    private var currentPath: String?
    private var latestDoc: [String: Any]?
    private var readerReady = false
    private var readerRoot: URL?

    override func loadView() {
        let drop = DropView(frame: NSRect(x: 0, y: 0, width: 960, height: 720))
        drop.onDropMarkdown = { [weak self] path in
            self?.openFile(path: path)
        }
        view = drop
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupWebView()
        loadReader()
        fileWatcher.onChange = { [weak self] path in
            DispatchQueue.main.async {
                self?.handleFileChanged(path: path)
            }
        }
    }

    private func setupWebView() {
        guard let root = Self.locateReaderRoot() else {
            showFatal("reader/index.html missing from app bundle.\nRun: ./scripts/build-reader.sh && ./scripts/sync-reader-to-app.sh")
            // Still create an empty webview to avoid nil crashes
            webView = WKWebView(frame: view.bounds)
            webView.autoresizingMask = [.width, .height]
            view.addSubview(webView)
            return
        }
        readerRoot = root

        let config = WKWebViewConfiguration()
        let appHandler = AppSchemeHandler(root: root)
        appSchemeHandler = appHandler
        config.setURLSchemeHandler(appHandler, forURLScheme: AppSchemeHandler.scheme)
        config.setURLSchemeHandler(assetHandler, forURLScheme: AssetSchemeHandler.scheme)
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.userContentController.add(self, name: "mdeasy")

        let wv = WKWebView(frame: view.bounds, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
        }
        view.addSubview(wv)
        webView = wv
    }

    private static func locateReaderRoot() -> URL? {
        let candidates: [URL] = {
            var urls: [URL] = []
            if let resourceURL = Bundle.main.resourceURL {
                urls.append(resourceURL.appendingPathComponent("Resources/reader"))
                urls.append(resourceURL.appendingPathComponent("reader"))
            }
            if let u = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Resources/reader") {
                urls.append(u.deletingLastPathComponent())
            }
            if let u = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "reader") {
                urls.append(u.deletingLastPathComponent())
            }
            return urls
        }()
        return candidates.first { root in
            FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path)
                && FileManager.default.fileExists(atPath: root.appendingPathComponent("app.js").path)
        }?.standardizedFileURL
    }

    private func loadReader() {
        guard let _ = readerRoot else { return }
        // Load via custom scheme so classic scripts execute reliably.
        guard let url = URL(string: "\(AppSchemeHandler.scheme)://reader/index.html") else { return }
        NSLog("mdeasy: loading reader %@", url.absoluteString)
        readerReady = false
        webView.load(URLRequest(url: url))
    }

    func openFile(path: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.openFile(path: path) }
            return
        }

        do {
            let payload = try FileService.readMarkdown(path: path)
            currentPath = payload.path
            Preferences.shared.lastOpenedPath = payload.path
            assetHandler.baseDir = URL(fileURLWithPath: payload.baseDir, isDirectory: true)
            fileWatcher.watch(path: payload.path)
            view.window?.title = URL(fileURLWithPath: payload.path).lastPathComponent

            let doc: [String: Any] = [
                "type": "doc",
                "path": payload.path,
                "baseDir": payload.baseDir,
                "text": payload.text,
                "encoding": payload.encoding,
                "mtimeMs": payload.mtimeMs
            ]
            latestDoc = doc
            NSLog("mdeasy: document ready (%d chars) readerReady=%@", payload.text.count, readerReady ? "yes" : "no")
            pushLatestDocument(reason: "openFile")
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func reloadCurrentFile() {
        guard let path = currentPath else { return }
        openFile(path: path)
    }

    func requestExportHTML() {
        sendBridgeEvent(["type": "request-export"])
    }

    func revealInFinder() {
        guard let path = currentPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openInEditor() {
        guard let path = currentPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func setTheme(_ name: String) {
        Preferences.shared.theme = name
        sendBridgeEvent(["type": "theme", "name": name])
    }

    func sendBridgeEvent(_ object: [String: Any], completion: ((Error?) -> Void)? = nil) {
        guard let webView else {
            completion?(BridgeError.noWebView)
            return
        }

        if #available(macOS 11.0, *) {
            let script = """
            (function(payload){
              if (!window.__mdeasy || typeof window.__mdeasy.handle !== 'function') {
                return 'no-handler';
              }
              window.__mdeasy.handle(payload);
              return 'ok';
            })
            """
            // callAsyncJavaScript expects a function body; pass arguments map.
            webView.callAsyncJavaScript(
                """
                if (!window.__mdeasy || typeof window.__mdeasy.handle !== 'function') {
                  return 'no-handler';
                }
                window.__mdeasy.handle(payload);
                return 'ok';
                """,
                arguments: ["payload": object],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    let status = value as? String ?? "unknown"
                    if status == "ok" {
                        completion?(nil)
                    } else {
                        NSLog("mdeasy: bridge status=%@", status)
                        completion?(BridgeError.handlerNotReady)
                    }
                case .failure(let error):
                    NSLog("mdeasy: bridge callAsync error: %@", error.localizedDescription)
                    self.sendBridgeEventLegacy(object, completion: completion)
                }
            }
            return
        }

        sendBridgeEventLegacy(object, completion: completion)
    }

    private func sendBridgeEventLegacy(_ object: [String: Any], completion: ((Error?) -> Void)? = nil) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: []),
            let webView
        else {
            completion?(BridgeError.encodeFailed)
            return
        }

        let b64 = data.base64EncodedString()
        let js = """
        (function(){
          try {
            if (!window.__mdeasy || typeof window.__mdeasy.handle !== 'function') {
              return 'no-handler';
            }
            var bin = atob('\(b64)');
            var bytes = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            var text = new TextDecoder('utf-8').decode(bytes);
            window.__mdeasy.handle(JSON.parse(text));
            return 'ok';
          } catch (e) {
            return 'error:' + (e && e.message ? e.message : String(e));
          }
        })();
        """

        webView.evaluateJavaScript(js) { result, error in
            if let error {
                NSLog("mdeasy: bridge eval error: %@", error.localizedDescription)
                completion?(error)
                return
            }
            let status = result as? String ?? "unknown"
            if status != "ok" {
                NSLog("mdeasy: bridge status=%@", status)
                completion?(BridgeError.handlerNotReady)
                return
            }
            completion?(nil)
        }
    }

    private func pushLatestDocument(reason: String) {
        guard let doc = latestDoc else { return }

        if !readerReady {
            NSLog("mdeasy: defer doc push (%@) — reader not ready", reason)
            // Still schedule retries in case ready message is delayed/lost.
            scheduleDocRetry(attempt: 1)
            return
        }

        sendBridgeEvent(doc) { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.scheduleDocRetry(attempt: 1)
            } else {
                NSLog("mdeasy: doc pushed (%@)", reason)
            }
        }
    }

    private func scheduleDocRetry(attempt: Int) {
        guard attempt <= 20, latestDoc != nil else { return }
        let delay = min(0.05 * Double(attempt), 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let doc = self.latestDoc else { return }
            // Probe readiness each retry
            self.webView?.evaluateJavaScript("!!(window.__mdeasy && window.__mdeasy.handle)") { result, _ in
                if let ok = result as? Bool, ok {
                    self.readerReady = true
                }
            }
            self.sendBridgeEvent(doc) { err in
                if err != nil {
                    self.scheduleDocRetry(attempt: attempt + 1)
                } else {
                    NSLog("mdeasy: doc pushed on retry #%d", attempt)
                }
            }
        }
    }

    private func handleFileChanged(path: String) {
        guard path == currentPath else { return }
        openFile(path: path)
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "mdeasy"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showFatal(_ message: String) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.frame = view.bounds.insetBy(dx: 24, dy: 24)
        label.autoresizingMask = [.width, .height]
        view.addSubview(label)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("mdeasy: webView didFinish %@", webView.url?.absoluteString ?? "?")
        webView.evaluateJavaScript("!!(window.__mdeasy && window.__mdeasy.handle)") { [weak self] result, _ in
            if let ok = result as? Bool, ok {
                self?.readerReady = true
                self?.pushLatestDocument(reason: "didFinish-probe")
            } else {
                NSLog("mdeasy: __mdeasy handler missing after didFinish")
                // One more delayed probe — script tags may still be evaluating.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    webView.evaluateJavaScript("!!(window.__mdeasy && window.__mdeasy.handle)") { result2, _ in
                        if let ok2 = result2 as? Bool, ok2 {
                            self?.readerReady = true
                            self?.pushLatestDocument(reason: "didFinish-delayed")
                        }
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("mdeasy: webView didFail %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("mdeasy: webView provisional fail %@", error.localizedDescription)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "mdeasy",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            NSLog("mdeasy: reader JS ready v=%@", (body["version"] as? String) ?? windowVersionPlaceholder())
            readerReady = true
            sendBridgeEvent([
                "type": "theme",
                "name": Preferences.shared.theme
            ])
            pushLatestDocument(reason: "js-ready")
        case "pong":
            NSLog("mdeasy: pong %@", String(describing: body["version"]))
        case "export-html":
            handleExport(body)
        case "open-in-editor":
            openInEditor()
        case "reveal-in-finder":
            revealInFinder()
        case "set-preference":
            if let key = body["key"] as? String {
                Preferences.shared.set(key: key, value: body["value"])
            }
        case "error":
            if let msg = body["message"] as? String {
                NSLog("reader error: %@", msg)
            }
        default:
            break
        }
    }

    private func windowVersionPlaceholder() -> String { "?" }

    private func handleExport(_ body: [String: Any]) {
        guard let html = body["html"] as? String else { return }
        let suggested = (body["suggestedName"] as? String) ?? "export.html"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.html]
        } else {
            panel.allowedFileTypes = ["html"]
        }
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private enum BridgeError: LocalizedError {
        case encodeFailed
        case noWebView
        case handlerNotReady

        var errorDescription: String? {
            switch self {
            case .encodeFailed: return "Failed to encode bridge payload"
            case .noWebView: return "WebView not ready"
            case .handlerNotReady: return "JS handler not ready"
            }
        }
    }
}
