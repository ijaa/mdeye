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
        appMenu.addItem(withTitle: NSLocalizedString("About MDEye", comment: ""), action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: NSLocalizedString("Set as Default Markdown App…", comment: ""), action: #selector(setAsDefaultApp(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Quit MDEye", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: NSLocalizedString("File", comment: ""))
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: NSLocalizedString("Open…", comment: ""), action: #selector(openMarkdown(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: NSLocalizedString("Reload", comment: ""), action: #selector(reloadMarkdown(_:)), keyEquivalent: "r")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: NSLocalizedString("Export PDF…", comment: ""), action: #selector(exportPDF(_:)), keyEquivalent: "e")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: NSLocalizedString("Reveal in Finder", comment: ""), action: #selector(revealInFinder(_:)), keyEquivalent: "R")
        let openEditor = fileMenu.addItem(withTitle: NSLocalizedString("Open in Editor", comment: ""), action: #selector(openInEditor(_:)), keyEquivalent: "E")
        openEditor.keyEquivalentModifierMask = [.command, .shift]

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: NSLocalizedString("Edit", comment: ""))
        editMenuItem.submenu = editMenu
        let findItem = editMenu.addItem(withTitle: NSLocalizedString("Find in Document…", comment: ""), action: nil, keyEquivalent: "f")
        findItem.isEnabled = false  // JS 层处理，仅显示快捷键
        findItem.toolTip = NSLocalizedString("Find Tooltip", comment: "")
        let findNextItem = editMenu.addItem(withTitle: NSLocalizedString("Find Next", comment: ""), action: nil, keyEquivalent: "g")
        findNextItem.isEnabled = false
        let findPrevItem = editMenu.addItem(withTitle: NSLocalizedString("Find Previous", comment: ""), action: nil, keyEquivalent: "g")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findPrevItem.isEnabled = false

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: NSLocalizedString("View", comment: ""))
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: NSLocalizedString("Toggle Outline", comment: ""), action: #selector(toggleOutline(_:)), keyEquivalent: "b")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: NSLocalizedString("Theme: Light", comment: ""), action: #selector(setThemeLight(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: NSLocalizedString("Theme: Dark", comment: ""), action: #selector(setThemeDark(_:)), keyEquivalent: "2")
        viewMenu.addItem(withTitle: NSLocalizedString("Theme: Sepia", comment: ""), action: #selector(setThemeSepia(_:)), keyEquivalent: "3")
        viewMenu.addItem(withTitle: NSLocalizedString("Theme: Green", comment: ""), action: #selector(setThemeGreen(_:)), keyEquivalent: "4")
        viewMenu.addItem(NSMenuItem.separator())
        // 字号缩放
        let zoomInItem = viewMenu.addItem(withTitle: NSLocalizedString("Zoom In (Text)", comment: ""), action: #selector(zoomTextIn(_:)), keyEquivalent: "+")
        zoomInItem.toolTip = NSLocalizedString("Zoom In Tooltip", comment: "")
        let zoomOutItem = viewMenu.addItem(withTitle: NSLocalizedString("Zoom Out (Text)", comment: ""), action: #selector(zoomTextOut(_:)), keyEquivalent: "-")
        zoomOutItem.toolTip = NSLocalizedString("Zoom Out Tooltip", comment: "")
        let zoomResetItem = viewMenu.addItem(withTitle: NSLocalizedString("Reset Text Zoom", comment: ""), action: #selector(zoomTextReset(_:)), keyEquivalent: "0")
        zoomResetItem.toolTip = NSLocalizedString("Reset Zoom Tooltip", comment: "")
        viewMenu.addItem(NSMenuItem.separator())
        // 栏宽调整
        let widen = NSMenuItem(title: NSLocalizedString("Widen Column", comment: ""), action: #selector(widenColumn(_:)), keyEquivalent: "+")
        widen.keyEquivalentModifierMask = [.option]
        widen.toolTip = NSLocalizedString("Widen Tooltip", comment: "")
        viewMenu.addItem(widen)
        let narrow = NSMenuItem(title: NSLocalizedString("Narrow Column", comment: ""), action: #selector(narrowColumn(_:)), keyEquivalent: "-")
        narrow.keyEquivalentModifierMask = [.option]
        narrow.toolTip = NSLocalizedString("Narrow Tooltip", comment: "")
        viewMenu.addItem(narrow)

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: NSLocalizedString("Window", comment: ""))
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: NSLocalizedString("Bring All to Front", comment: ""), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: NSLocalizedString("Minimize", comment: ""), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: NSLocalizedString("Zoom", comment: ""), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
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

    // F1：屏幕缩放（字号 / 栏宽）。打印不沿用——CSS @media print 固定字号与 max-width。
    @objc private func zoomTextIn(_ sender: Any?) { contentController.adjustFontSizeScale(by: 0.1) }
    @objc private func zoomTextOut(_ sender: Any?) { contentController.adjustFontSizeScale(by: -0.1) }
    @objc private func zoomTextReset(_ sender: Any?) { contentController.setFontSizeScale(1.0) }
    @objc private func widenColumn(_ sender: Any?) { contentController.adjustContentMaxWidth(by: 32) }
    @objc private func narrowColumn(_ sender: Any?) { contentController.adjustContentMaxWidth(by: -32) }

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
