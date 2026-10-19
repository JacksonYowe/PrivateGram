import AppKit
import WebKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "PrivateGram"
    private var window: NSWindow!
    private let browser = MacBrowserController()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua) // app + Instagram page are always dark
        NSApp.mainMenu = buildMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = appName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.minSize = NSSize(width: 480, height: 600)
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 1200, height: 860))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Menus

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(item("Sign In with Email Link…", #selector(MacBrowserController.openLoginLink(_:)), "l"))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: appName))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let view = NSMenu(title: "View")
        view.addItem(item("Home", #selector(MacBrowserController.goHome(_:)), "h", [.command, .shift]))
        view.addItem(item("Reload", #selector(MacBrowserController.reloadPage(_:)), "r"))
        view.addItem(.separator())
        view.addItem(item("Back", #selector(MacBrowserController.goBack(_:)), "["))
        view.addItem(item("Forward", #selector(MacBrowserController.goForward(_:)), "]"))
        view.addItem(.separator())
        view.addItem(item("Actual Size", #selector(MacBrowserController.zoomReset(_:)), "0"))
        view.addItem(item("Zoom In", #selector(MacBrowserController.zoomIn(_:)), "+"))
        view.addItem(item("Zoom Out", #selector(MacBrowserController.zoomOut(_:)), "-"))
        view.addItem(.separator())
        let full = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu(view, title: "View"))

        let privacy = NSMenu(title: "Privacy")
        privacy.addItem(item("Block Trackers & Logging", #selector(MacBrowserController.toggleShields(_:)), ""))
        privacy.addItem(.separator())
        privacy.addItem(item("What This App Protects…", #selector(MacBrowserController.showProtections(_:)), ""))
        main.addItem(submenu(privacy, title: "Privacy"))

        let reset = NSMenu(title: "Reset")
        reset.addItem(item("Reset to Clean Slate…", #selector(MacBrowserController.resetEverything(_:)), "\u{8}", [.command, .shift]))
        reset.addItem(.separator())
        reset.addItem(item("Clear Cache Only (Stay Signed In)", #selector(MacBrowserController.clearCache(_:)), ""))
        main.addItem(submenu(reset, title: "Reset"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu

        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private func item(_ title: String, _ action: Selector, _ key: String,
                      _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
