import AppKit
import PDFKit
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
    private var pdfExporter: PDFExportCoordinator?

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

    /// Export through a dedicated file-backed WKWebView and WebKit's print pipeline.
    /// The reading webview remains untouched; the exporter applies `@media print`, paginates to A4,
    /// and saves directly without going through the system print panel's custom-scheme path.
    func requestExportPDF() {
        guard pdfExporter == nil else {
            presentError("A PDF export is already in progress.")
            return
        }
        guard let currentPath, let readerRoot, let doc = latestDoc else { return }
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
            guard let self else { return }
            let exporter = PDFExportCoordinator(
                readerRoot: readerRoot,
                document: doc,
                theme: Preferences.shared.theme,
                outputURL: url
            ) { [weak self] result in
                guard let self else { return }
                self.pdfExporter = nil
                if case .failure(let error) = result {
                    self.presentError("PDF export failed: \(error.localizedDescription)")
                }
            }
            self.pdfExporter = exporter
            exporter.start()
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

final class PDFExportCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private static let a4Size = NSSize(width: 595.28, height: 841.89)
    private static let margin: CGFloat = 45.35 // 16 mm

    private let readerRoot: URL
    private let document: [String: Any]
    private let theme: String
    private let outputURL: URL
    private let temporaryURL: URL
    private let completion: (Result<Void, Error>) -> Void
    private let assetHandler = AssetSchemeHandler()

    private var webView: WKWebView?
    private var timeoutWorkItem: DispatchWorkItem?
    private var didSendDocument = false
    private var didRequestPrintPreparation = false
    private var isFinished = false

    init(
        readerRoot: URL,
        document: [String: Any],
        theme: String,
        outputURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.readerRoot = readerRoot
        self.document = document
        self.theme = theme
        self.outputURL = outputURL
        self.temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".mdeye-pdf-\(UUID().uuidString).pdf")
        self.completion = completion
        super.init()
    }

    func start() {
        guard let baseDir = document["baseDir"] as? String else {
            finish(.failure(ExportError.invalidDocument))
            return
        }

        assetHandler.baseDir = URL(fileURLWithPath: baseDir, isDirectory: true)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(assetHandler, forURLScheme: AssetSchemeHandler.scheme)
        configuration.userContentController.add(self, name: "mdeye")

        let webView = WKWebView(frame: NSRect(origin: .zero, size: Self.a4Size), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(ExportError.timedOut))
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)

        let indexURL = readerRoot.appendingPathComponent("index.html")
        webView.loadFileURL(indexURL, allowingReadAccessTo: readerRoot)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "mdeye",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            sendDocumentIfNeeded()
        case "doc-shown":
            requestPrintPreparationIfNeeded()
        case "print-ready":
            printPDF()
        case "error":
            let message = body["message"] as? String ?? "Reader rendering failed"
            finish(.failure(ExportError.reader(message)))
        default:
            break
        }
    }

    private func sendDocumentIfNeeded() {
        guard !didSendDocument else { return }
        didSendDocument = true
        send(["type": "theme", "name": theme]) { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            self.send(self.document) { error in
                if let error { self.finish(.failure(error)) }
            }
        }
    }

    private func requestPrintPreparationIfNeeded() {
        guard !didRequestPrintPreparation else { return }
        didRequestPrintPreparation = true
        send(["type": "prepare-print"]) { [weak self] error in
            if let error { self?.finish(.failure(error)) }
        }
    }

    private func send(_ object: [String: Any], completion: @escaping (Error?) -> Void) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else {
            completion(ExportError.bridgeFailed)
            return
        }
        webView.evaluateJavaScript("window.__mdeye && window.__mdeye.handle(\(json))") { _, error in
            completion(error)
        }
    }

    private func printPDF() {
        guard let webView, !isFinished else { return }

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.orientation = .portrait
        printInfo.paperSize = Self.a4Size
        printInfo.leftMargin = Self.margin
        printInfo.rightMargin = Self.margin
        printInfo.topMargin = Self.margin
        printInfo.bottomMargin = Self.margin
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.jobDisposition = .save
        let savingURLKey: NSPrintInfo.AttributeKey = .jobSavingURL
        printInfo.dictionary()[savingURLKey] = temporaryURL

        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false

        guard operation.run() else {
            finish(.failure(ExportError.printFailed))
            return
        }
        guard let pdf = PDFDocument(url: temporaryURL), pdf.pageCount > 0 else {
            finish(.failure(ExportError.invalidPDF))
            return
        }
        do {
            let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
            try data.write(to: outputURL, options: .atomic)
        } catch {
            finish(.failure(error))
            return
        }
        finish(.success(()))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !isFinished else { return }
        isFinished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "mdeye")
        webView = nil
        try? FileManager.default.removeItem(at: temporaryURL)
        completion(result)
    }

    private enum ExportError: LocalizedError {
        case invalidDocument
        case bridgeFailed
        case timedOut
        case reader(String)
        case printFailed
        case invalidPDF

        var errorDescription: String? {
            switch self {
            case .invalidDocument: return "Document metadata is incomplete."
            case .bridgeFailed: return "Could not communicate with the print renderer."
            case .timedOut: return "The print renderer did not become ready in time."
            case .reader(let message): return message
            case .printFailed: return "The WebKit print operation failed."
            case .invalidPDF: return "The generated file is not a valid PDF."
            }
        }
    }
}
