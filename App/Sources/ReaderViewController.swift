import AppKit
import WebKit
import UniformTypeIdentifiers

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
        return items.map(\.path).filter { FileService.isMarkdownPath($0) }
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
        config.userContentController.add(self, name: "mdeye")

        let wv = WKWebView(frame: view.bounds, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
        }
        view.addSubview(wv)
        webView = wv
    }

    static func locateReaderRoot() -> URL? {
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
        NSLog("mdeye: loading reader %@", url.absoluteString)
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
            NSLog("mdeye: document ready (%d chars) readerReady=%@", payload.text.count, readerReady ? "yes" : "no")
            pushLatestDocument(reason: "openFile")
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func reloadCurrentFile() {
        guard let path = currentPath else { return }
        openFile(path: path)
    }

    /// 导出 PDF：用原生 `WKWebView.createPDF(configuration:)` 直出 PDF `Data` 写盘。
    ///
    /// 为什么不用 `printOp.run()` + 系统「PDF ▾ → 另存为 PDF」：实测在 `mdeye-app://` 自定义协议加载的
    /// WKWebView 上，打印面板的**预览有内容**，但经系统对话框「另存为 PDF」输出的**文件空白**——
    /// 这是系统打印对话框对自定义协议 webview 输出 PDF 的已知失效路径。`createPDF` 直接排版当前已
    /// render 的 DOM 成 PDF `Data`，不经该失效路径，内容确定不空。
    ///
    /// reader 正文在 `.markdown-body { overflow:auto }` 内部滚动容器、`#app/#main` 是 display:flex，
    /// 直接 `createPDF(rect=视口)` 只截一屏。导出前注入一段"打印态" CSS：隐藏 `.outline/.toolbar`、
    /// 把 `#app/#main` 改 block、`.markdown-body` 撑开成全高；实测 `scrollHeight` 作 rect 高，让
    /// `createPDF` 按整篇高切片成多页；导出后无论成功失败移除注入样式恢复阅读态。
    /// `NSSavePanel` 直接落盘（菜单 Export PDF… 直达文件）。
    func requestExportPDF() {
        guard currentPath != nil, let webView else { return }
        let suggested = (currentPath as NSString?)?
            .components(separatedBy: "/").last?
            .replacingOccurrences(
                of: "\\.(md|markdown|mdx|mdown|mkd|mkdn|mdwn)$",
                with: "",
                options: .regularExpression
            ) ?? "export"

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggested).pdf"
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.pdf] }
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.writePDF(from: webView, to: url)
        }
    }

    /// 注入打印态、实测整篇尺寸、用原生 `createPDF(rect=全高)` 分页出 PDF，落盘后恢复阅读态。
    private func writePDF(from webView: WKWebView, to url: URL) {
        webView.callAsyncJavaScript(
            """
            (function() {
              // 幂等：若已存在先移除，避免上次异常残留。
              document.getElementById('mdeye-print-mode')?.remove();
              var style = document.createElement('style');
              style.id = 'mdeye-print-mode';
              style.textContent = ''
                + 'html, body { height:auto !important; min-height:0 !important; overflow:visible !important; }'
                + '#app { display:block !important; height:auto !important; min-height:0 !important; }'
                + '#main { display:block !important; height:auto !important; min-height:0 !important; }'
                + '.markdown-body { flex:none !important; overflow:visible !important; height:auto !important; max-height:none !important; padding:28px 32px 64px !important; }'
                + '.outline, .toolbar { display:none !important; }';
              document.head.appendChild(style);
              // 同步读尺寸：访问 scrollHeight/offsetHeight 会触发同步 reflow，
              // 拿到注入打印态后的真实布局（不依赖 Promise/RAF，避免 callAsyncJavaScript
              // 不 await Promise 而返回 nil 导致回退视口尺寸→只截一屏）。
              var c = document.querySelector('.markdown-body');
              // 强制一次同步 reflow。
              void document.documentElement.offsetHeight;
              return {
                width: document.documentElement.clientWidth,
                height: Math.ceil(document.documentElement.scrollHeight),
                contentScroll: c ? c.scrollHeight : -1,
                vport: window.innerHeight
              };
            })();
            """,
            arguments: [:],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                let dbg = debugMeasure(value)
                let width: Double
                let height: Double
                if let dict = value as? [String: Any],
                   let w = (dict["width"] as? Double) ?? (dict["width"] as? Int).map(Double.init),
                   let h = (dict["height"] as? Double) ?? (dict["height"] as? Int).map(Double.init),
                   w > 0, h > 0 {
                    width = w
                    height = h
                } else {
                    width = Double(webView.bounds.width)
                    height = Double(webView.bounds.height)
                }
                self.renderPDF(on: webView, to: url, width: width, height: height, debugInfo: dbg)
            case .failure(let error):
                NSLog("mdeye: print-mode inject failed: %@", error.localizedDescription)
                webView.evaluateJavaScript("document.getElementById('mdeye-print-mode')?.remove()")
                self.renderPDF(on: webView, to: url,
                               width: Double(webView.bounds.width),
                               height: Double(webView.bounds.height),
                               debugInfo: "inject FAILED: \(error.localizedDescription)")
            }
        }
    }

    /// TEMP DEBUG: 把注入前后实测组装成人类可读字符串。
    private func debugMeasure(_ value: Any) -> String {
        guard let d = value as? [String: Any] else { return "non-dict: \(value)" }
        func snap(_ s: Any?) -> String {
            guard let m = s as? [String: Any] else { return "?" }
            func n(_ k: String) -> String { String(describing: m[k] ?? "?") }
            return "vport=\(n("vport")) docClient=\(n("docClient")) docScroll=\(n("docScroll")) bodyScroll=\(n("bodyScroll")) contentScroll=\(n("contentScroll")) contentClient=\(n("contentClient")) appMinH=\(n("appMinHeight"))"
        }
        return "BEFORE \(snap(d["before"]))\nAFTER  \(snap(d["after"]))\n→ width=\(d["width"] ?? "?") height=\(d["height"] ?? "?")"
    }

    private func renderPDF(on webView: WKWebView, to url: URL, width: Double, height: Double, debugInfo: String) {
        let cfg = WKPDFConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: width, height: height)
        webView.createPDF(configuration: cfg) { [weak self] (result: Result<Data, Error>) in
            DispatchQueue.main.async {
                webView.evaluateJavaScript("document.getElementById('mdeye-print-mode')?.remove()")
                switch result {
                case .success(let data):
                    let wrote = (try? data.write(to: url, options: .atomic)) != nil
                    // TEMP DEBUG: 导出后弹实测，便于定位"只一屏"根因。定位后移除。
                    self?.presentError("[PDF DEBUG] wrote=\(wrote) bytes=\(data.count)\nrect w=\(width) h=\(height)\n\n\(debugInfo)")
                case .failure(let error):
                    self?.presentError("PDF export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func revealInFinder() {
        guard let path = currentPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 打开文档内点击的同类 .md 链接：在当前文档 baseDir 树内解析（复用图片沙箱通路），
    /// 命中即替换为单文件入口 `openFile`（单文件语义，不开新窗/标签）；非法/不存在则弹提示框。
    private func openMarkdownLink(href: String) {
        guard let current = currentPath else {
            presentError("No document open — cannot resolve link.")
            return
        }
        // 去掉 `?query` 与 `#fragment`，避免被当成文件名一部分。
        var relative = FileService.stripQueryAndFragment(href)
        // markdown-it 会把含非 ASCII 的链接 href 百分号编码（如 `./00-%E5%89%8D%E8%A8%80/01-x.md`），
        // 而磁盘真实文件名是中文，按编码串查找必然 not found——先 percent-decode 还原。
        relative = relative.removingPercentEncoding ?? relative
        guard !relative.isEmpty else {
            presentError("Empty link target.")
            return
        }
        let baseDir = URL(fileURLWithPath: current).deletingLastPathComponent().path
        guard let url = FileService.resolveAsset(baseDir: baseDir, relative: relative) else {
            presentError("Cannot open link.\n\nTarget not inside the current folder tree, or not found:\n\(relative)")
            return
        }
        // resolveAsset 只验存在+非目录+不逃逸，再验一次后缀类型，仅 Markdown 才打开。
        guard FileService.isMarkdownPath(url.path) else {
            presentError("Only Markdown links are supported:\n\(relative)")
            return
        }
        openFile(path: url.path)
    }

    func openInEditor() {
        guard let path = currentPath else { return }
        let url = URL(fileURLWithPath: path)
        // Avoid recursion: mdeye is itself a registered Markdown handler, so a plain
        // NSWorkspace.open(url) may re-launch ourselves. Pick an explicit editor app,
        // skipping ourselves; fall back to TextEdit, then Finder reveal.
        let ownBundleId = Bundle.main.bundleIdentifier
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
           Bundle(url: appURL)?.bundleIdentifier != ownBundleId {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, _ in }
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: config) { _, _ in }
        } else {
            revealInFinder()
        }
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
            // callAsyncJavaScript expects a function body; pass arguments map.
            webView.callAsyncJavaScript(
                """
                if (!window.__mdeye || typeof window.__mdeye.handle !== 'function') {
                  return 'no-handler';
                }
                window.__mdeye.handle(payload);
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
                        NSLog("mdeye: bridge status=%@", status)
                        completion?(BridgeError.handlerNotReady)
                    }
                case .failure(let error):
                    NSLog("mdeye: bridge callAsync error: %@", error.localizedDescription)
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
            if (!window.__mdeye || typeof window.__mdeye.handle !== 'function') {
              return 'no-handler';
            }
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

        webView.evaluateJavaScript(js) { result, error in
            if let error {
                NSLog("mdeye: bridge eval error: %@", error.localizedDescription)
                completion?(error)
                return
            }
            let status = result as? String ?? "unknown"
            if status != "ok" {
                NSLog("mdeye: bridge status=%@", status)
                completion?(BridgeError.handlerNotReady)
                return
            }
            completion?(nil)
        }
    }

    private func pushLatestDocument(reason: String) {
        guard let doc = latestDoc else { return }

        if !readerReady {
            NSLog("mdeye: defer doc push (%@) — reader not ready", reason)
            // Still schedule retries in case ready message is delayed/lost.
            scheduleDocRetry(attempt: 1)
            return
        }

        sendBridgeEvent(doc) { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.scheduleDocRetry(attempt: 1)
            } else {
                NSLog("mdeye: doc pushed (%@)", reason)
            }
        }
    }

    private func scheduleDocRetry(attempt: Int) {
        guard attempt <= 20, latestDoc != nil else { return }
        let delay = min(0.05 * Double(attempt), 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let doc = self.latestDoc else { return }
            // Probe readiness each retry
            self.webView?.evaluateJavaScript("!!(window.__mdeye && window.__mdeye.handle)") { result, _ in
                if let ok = result as? Bool, ok {
                    self.readerReady = true
                }
            }
            self.sendBridgeEvent(doc) { err in
                if err != nil {
                    self.scheduleDocRetry(attempt: attempt + 1)
                } else {
                    NSLog("mdeye: doc pushed on retry #%d", attempt)
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
        alert.messageText = "MDEye"
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
        NSLog("mdeye: webView didFinish %@", webView.url?.absoluteString ?? "?")
        webView.evaluateJavaScript("!!(window.__mdeye && window.__mdeye.handle)") { [weak self] result, _ in
            if let ok = result as? Bool, ok {
                self?.readerReady = true
                self?.pushLatestDocument(reason: "didFinish-probe")
            } else {
                NSLog("mdeye: __mdeye handler missing after didFinish")
                // One more delayed probe — script tags may still be evaluating.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    webView.evaluateJavaScript("!!(window.__mdeye && window.__mdeye.handle)") { result2, _ in
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
        NSLog("mdeye: webView didFail %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("mdeye: webView provisional fail %@", error.localizedDescription)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "mdeye",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            NSLog("mdeye: reader JS ready v=%@", (body["version"] as? String) ?? windowVersionPlaceholder())
            readerReady = true
            sendBridgeEvent([
                "type": "theme",
                "name": Preferences.shared.theme
            ])
            pushLatestDocument(reason: "js-ready")
        case "doc-shown":
            // Proof that the web reader actually rendered content (not just native open).
            let path = body["path"] as? String ?? ""
            let chars = body["chars"] as? Int ?? (body["chars"] as? Double).map { Int($0) } ?? -1
            NSLog("mdeye: DOC_SHOWN path=%@ chars=%d", path, chars)
            Self.writeSmokeStamp(path: path, chars: chars)
        case "pong":
            NSLog("mdeye: pong %@", String(describing: body["version"]))
        case "open-in-editor":
            openInEditor()
        case "reveal-in-finder":
            revealInFinder()
        case "open-md-link":
            if let href = body["href"] as? String {
                openMarkdownLink(href: href)
            }
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

    /// Writes /tmp/mdeye-last-shown.json so smoke tests can prove content rendered.
    private static func writeSmokeStamp(path: String, chars: Int) {
        let payload: [String: Any] = [
            "path": path,
            "chars": chars,
            "ts": Date().timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        let url = URL(fileURLWithPath: "/tmp/mdeye-last-shown.json")
        try? data.write(to: url, options: .atomic)
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
