import AppKit
import PDFKit

// Programmatic AppKit entry (no storyboard / no @main on the delegate).
// Guarantees: shared NSApplication, regular activation policy, and a running event loop.

let argv = CommandLine.arguments

// Headless PDF export check for CI:
//   mdeye --pdf-selftest <path-to.md> <output.pdf>
// Uses the production PDFExportCoordinator and requires a valid multi-page result.
if argv.count >= 4, argv[1] == "--pdf-selftest" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    guard let root = ReaderViewController.locateReaderRoot() else {
        print("PDF SELFTEST FAIL: reader/index.html not found in bundle")
        exit(1)
    }

    do {
        let payload = try FileService.readMarkdown(path: argv[2])
        let doc: [String: Any] = [
            "type": "doc",
            "path": payload.path,
            "baseDir": payload.baseDir,
            "text": payload.text,
            "encoding": payload.encoding,
            "mtimeMs": payload.mtimeMs,
        ]
        let outputURL = URL(fileURLWithPath: argv[3])
        let pdfSelfTest = PDFExportCoordinator(
            readerRoot: root,
            document: doc,
            theme: "light",
            outputURL: outputURL
        ) { result in
            switch result {
            case .success:
                guard let pdf = PDFDocument(url: outputURL), pdf.pageCount >= 2 else {
                    print("PDF SELFTEST FAIL: expected at least 2 pages")
                    exit(1)
                }
                print("PDF SELFTEST OK pages=\(pdf.pageCount)")
                exit(0)
            case .failure(let error):
                print("PDF SELFTEST FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
        pdfSelfTest.start()
        app.run()
        exit(1)
    } catch {
        print("PDF SELFTEST FAIL: \(error.localizedDescription)")
        exit(1)
    }
}

// Headless self-check mode for CI (no GUI login / WindowServer required).
//   mdeye --selftest <path-to.md>
// Drives the reader render pipeline offscreen and exits; see SelfTest.swift.
if argv.count >= 3, argv[1] == "--selftest" {
    let app = NSApplication.shared
    // selfTest stays retained for the lifetime of app.run() (top-level scope).
    let selfTest = SelfTest(path: argv[2])
    selfTest.run()
    app.setActivationPolicy(.accessory)
    app.run()
    exit(1) // unreachable: SelfTest calls exit() on success/failure
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
