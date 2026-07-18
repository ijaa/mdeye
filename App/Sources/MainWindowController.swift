import AppKit
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let contentController = ReaderViewController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MDEye"
        window.minSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.center()

        self.init(window: window)
        window.delegate = self
        window.contentViewController = contentController
        // Apply autosave AFTER first center, and only if saved frame is on-screen.
        window.setFrameUsingName("MainWindow")
        if NSScreen.screens.allSatisfy({ !$0.visibleFrame.intersects(window.frame) }) {
            window.setFrame(NSRect(x: 0, y: 0, width: 960, height: 720), display: false)
            window.center()
        }
        window.setFrameAutosaveName("MainWindow")
        setupMenu()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openFile(path: String) {
        contentController.openFile(path: path)
        showWindow(nil)
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About MDEye", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "Set as Default Markdown App…", action: #selector(setAsDefaultApp(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit MDEye", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Open…", action: #selector(openMarkdown(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Reload", action: #selector(reloadMarkdown(_:)), keyEquivalent: "r")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Export PDF…", action: #selector(exportPDF(_:)), keyEquivalent: "e")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "R")
        fileMenu.addItem(withTitle: "Open in Editor", action: #selector(openInEditor(_:)), keyEquivalent: "E")

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Toggle Outline", action: #selector(toggleOutline(_:)), keyEquivalent: "b")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Theme: Light", action: #selector(setThemeLight(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Theme: Dark", action: #selector(setThemeDark(_:)), keyEquivalent: "2")
        viewMenu.addItem(withTitle: "Theme: Sepia", action: #selector(setThemeSepia(_:)), keyEquivalent: "3")
        viewMenu.addItem(withTitle: "Theme: Green", action: #selector(setThemeGreen(_:)), keyEquivalent: "4")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openMarkdown(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [
                UTType(filenameExtension: "md") ?? .plainText,
                UTType(filenameExtension: "markdown") ?? .plainText,
                UTType(filenameExtension: "mdx") ?? .plainText,
                .plainText
            ]
        }
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.openFile(path: url.path)
        }
    }

    @objc private func reloadMarkdown(_ sender: Any?) {
        contentController.reloadCurrentFile()
    }

    @objc private func exportPDF(_ sender: Any?) {
        contentController.requestExportPDF()
    }

    @objc private func revealInFinder(_ sender: Any?) {
        contentController.revealInFinder()
    }

    @objc private func openInEditor(_ sender: Any?) {
        contentController.openInEditor()
    }

    @objc private func toggleOutline(_ sender: Any?) {
        contentController.sendBridgeEvent(["type": "toggle-outline"])
    }

    @objc private func setThemeLight(_ sender: Any?) { contentController.setTheme("light") }
    @objc private func setThemeDark(_ sender: Any?) { contentController.setTheme("dark") }
    @objc private func setThemeSepia(_ sender: Any?) { contentController.setTheme("sepia") }
    @objc private func setThemeGreen(_ sender: Any?) { contentController.setTheme("green") }

    @objc private func setAsDefaultApp(_ sender: Any?) {
        let result = DefaultAppService.setAsDefaultMarkdownViewer()
        let alert = NSAlert()
        alert.messageText = result.ok ? "Default app updated" : "Could not fully set default"
        alert.informativeText = result.message
        alert.alertStyle = result.ok ? .informational : .warning
        alert.addButton(withTitle: "OK")
        if !result.ok {
            alert.addButton(withTitle: "Open Get Info Guide")
        }
        let response = alert.runModal()
        if !result.ok && response == .alertSecondButtonReturn {
            let tip = NSAlert()
            tip.messageText = "Finder → Get Info"
            tip.informativeText = """
            1. Select any .md file in Finder
            2. Press ⌘I (Get Info)
            3. Open with → choose MDEye
            4. Click “Change All…”
            """
            tip.addButton(withTitle: "OK")
            tip.runModal()
        }
    }

    @objc private func showAbout() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        let alert = NSAlert()
        alert.messageText = "MDEye"
        alert.informativeText = """
        Version \(version) (full)

        Offline Markdown reader for macOS.
        GFM · Mermaid · Themes · PDF export

        Unsigned self-use build:
        System Settings → Privacy & Security → Open Anyway

        Set as default: MDEye menu → Set as Default Markdown App…
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
