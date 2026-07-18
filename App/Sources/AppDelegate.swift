import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var pendingPaths: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let wc = MainWindowController()
        windowController = wc
        wc.showWindow(nil)

        if let window = wc.window {
            window.makeKeyAndOrderFront(nil)
            if NSScreen.screens.allSatisfy({ !$0.visibleFrame.intersects(window.frame) }) {
                window.center()
                window.makeKeyAndOrderFront(nil)
            }
        }

        NSApp.activate(ignoringOtherApps: true)

        // Files may arrive via Apple Events before or after this callback.
        flushPendingPaths()

        // Some Launch Services paths only show up slightly after launch.
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingPaths()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            windowController?.showWindow(nil)
            windowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    // Modern Finder double-click / `open -a` path (macOS 10.13+).
    func application(_ application: NSApplication, open urls: [URL]) {
        enqueue(paths: urls.map { $0.standardizedFileURL.path })
    }

    // Legacy path still used by some system versions / tools.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        enqueue(paths: [filename])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        enqueue(paths: filenames)
        // Required when implementing openFiles: tell AppKit we handled them.
        sender.reply(toOpenOrPrint: .success)
    }

    /// Product decision: mdeye is a single-document reader. When multiple files are
    /// opened together (Finder multi-select, `open a.md b.md`), render only the last
    /// one instead of looping through each — keeps the UI to exactly one open file
    /// and avoids a storm of redundant latestDoc pushes / re-renders.
    private func enqueue(paths: [String]) {
        let cleaned = paths
            .map { ($0 as NSString).expandingTildeInPath }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { !$0.isEmpty }

        guard let target = cleaned.last else { return }

        if let wc = windowController {
            NSLog("mdeye: open request → %@%@", cleaned.count > 1 ? "(\(cleaned.count)) " : "", target)
            wc.openFile(path: target)
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            pendingPaths.append(target)
            NSLog("mdeye: queued open → %@", target)
        }
    }

    private func flushPendingPaths() {
        guard let wc = windowController, !pendingPaths.isEmpty else { return }
        let path = pendingPaths.last!
        pendingPaths.removeAll()
        NSLog("mdeye: flush queued → %@", path)
        wc.openFile(path: path)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }
}
