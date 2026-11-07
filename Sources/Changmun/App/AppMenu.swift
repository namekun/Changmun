import AppKit
import SwiftUI

enum AppMenu {
    private static let f12 = String(Character(UnicodeScalar(NSF12FunctionKey)!))
    private static let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    private static let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))

    /// The menu bar with the key equivalents of the chosen scheme. Only what differs between Safari and Chrome
    /// changes; the rest is shared.
    @MainActor
    static func make(scheme: ShortcutScheme) -> NSMenu {
        let chrome = scheme == .chrome
        let main = NSMenu()

        let app = submenu(main, "Changmun")
        add(app, "About Changmun", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        add(app, "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)))
        app.addItem(.separator())
        add(app, "Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        add(app, "Import from Another Browser…", #selector(AppDelegate.importData(_:)))
        app.addItem(.separator())
        add(app, "Hide Changmun", #selector(NSApplication.hide(_:)), "h")
        add(app, "Quit Changmun", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu(main, "File")
        add(file, "New Tab", #selector(AppDelegate.newTab(_:)), "t")
        add(file, "New Window", #selector(AppDelegate.newWindow(_:)), "n")
        add(file, "New Private Window", #selector(AppDelegate.newPrivateWindow(_:)), "n", [.command, .shift])
        add(file, "Open Location", #selector(AppDelegate.openLocation(_:)), "l")
        add(file, "Close Tab", #selector(AppDelegate.closeTab(_:)), "w")
        add(file, "Close Window", #selector(AppDelegate.closeWindow(_:)), "w", [.command, .shift])
        add(file, "Reopen Closed Tab", #selector(AppDelegate.reopenClosedTab(_:)), "t", [.command, .shift])
        add(file, "Open File…", #selector(AppDelegate.openFile(_:)), "o")
        file.addItem(.separator())
        add(file, "Copy Address", #selector(AppDelegate.copyAddress(_:)), "c", [.command, .shift])
        add(file, "Print…", #selector(AppDelegate.printPage(_:)), "p")
        add(file, "Save as PDF…", #selector(AppDelegate.savePDF(_:)))
        add(file, "Capture Full Page…", #selector(AppDelegate.captureFullPage(_:)))

        let edit = submenu(main, "Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Find…", #selector(AppDelegate.showFind(_:)), "f")
        add(edit, "Find Next", #selector(AppDelegate.findNext(_:)), "g")
        add(edit, "Find Previous", #selector(AppDelegate.findPrevious(_:)), "g", [.command, .shift])

        let view = submenu(main, "View")
        add(view, "Reload", #selector(AppDelegate.reload(_:)), "r")
        add(view, "Hard Reload", #selector(AppDelegate.hardReload(_:)), "r", chrome ? [.command, .shift] : [.command, .option])
        add(view, "Sidebar", #selector(AppDelegate.toggleBrowserSidebar(_:)), chrome ? "s" : "l", chrome ? [.command] : [.command, .shift])
        add(view, "Focus Mode", #selector(AppDelegate.toggleFocusMode(_:)), "f", [.command, .shift])
        add(view, "AI Panel", #selector(AppDelegate.toggleChat(_:)), "e")
        add(view, "New AI Chat", #selector(AppDelegate.newChat(_:)), "e", [.command, .shift])
        add(view, "Split View", #selector(AppDelegate.toggleSplit(_:)), "\\", [.command, .option])
        view.addItem(.separator())
        add(view, "Zoom In", #selector(AppDelegate.zoomIn(_:)), "+")
        add(view, "Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-")
        add(view, "Actual Size", #selector(AppDelegate.actualSize(_:)), "0")
        add(view, "Mute Tab", #selector(AppDelegate.toggleMute(_:)), "m", [.command, .control])
        add(view, "Picture in Picture", #selector(AppDelegate.togglePictureInPicture(_:)), "p", [.command, .control])
        add(view, "Skip Back 5 Seconds", #selector(AppDelegate.seekBack(_:)), left, [.command, .control])
        add(view, "Skip Forward 5 Seconds", #selector(AppDelegate.seekForward(_:)), right, [.command, .control])
        add(view, "Translate Page", #selector(AppDelegate.translatePage(_:)), "t", [.command, .option])
        // The one of ⇧⌘R and ⌥⌘R that Hard Reload leaves free.
        add(view, "Reader Mode", #selector(AppDelegate.toggleReader(_:)), "r", chrome ? [.command, .option] : [.command, .shift])
        view.addItem(.separator())
        add(view, "Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let develop = submenu(main, "Develop")
        add(develop, "Web Inspector (Network)", #selector(AppDelegate.toggleInspector(_:)), f12, [])
        add(develop, "Web Inspector (Network)", #selector(AppDelegate.toggleInspector(_:)), "i", [.command, .option], hidden: true)
        add(develop, "Console", #selector(AppDelegate.showConsole(_:)), chrome ? "j" : "c", [.command, .option])

        let history = submenu(main, "History")
        add(history, "Back", #selector(AppDelegate.goBack(_:)), "[")
        add(history, "Forward", #selector(AppDelegate.goForward(_:)), "]")
        history.addItem(.separator())
        add(history, "Add/Remove Bookmark", #selector(AppDelegate.toggleBookmark(_:)), "d")
        add(history, "Add to Reading List", #selector(AppDelegate.addToReadingList(_:)), "d", [.command, .shift])
        history.addItem(.separator())
        add(history, "Show All History", #selector(AppDelegate.showHistory(_:)), "y")
        add(history, "Archived Tabs", #selector(AppDelegate.showArchive(_:)))
        add(history, "Downloads", #selector(AppDelegate.showDownloads(_:)), chrome ? "j" : "l", chrome ? [.command, .shift] : [.command, .option])

        let window = submenu(main, "Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        window.addItem(.separator())
        add(window, "Next Tab", #selector(AppDelegate.nextTab(_:)), "]", [.command, .shift])
        add(window, "Previous Tab", #selector(AppDelegate.previousTab(_:)), "[", [.command, .shift])
        add(window, "Tidy Tabs", #selector(AppDelegate.tidyTabs(_:)))
        add(window, "Recent Tab", #selector(AppDelegate.recentTab(_:)), "\t", [.control], hidden: true)
        add(window, "Recent Tab", #selector(AppDelegate.olderRecentTab(_:)), "\t", [.control, .shift], hidden: true)
        if chrome {
            add(window, "Next Tab", #selector(AppDelegate.nextTab(_:)), right, [.command, .option], hidden: true)
            add(window, "Previous Tab", #selector(AppDelegate.previousTab(_:)), left, [.command, .option], hidden: true)
        }
        for n in 1...9 {
            add(window, n == 9 ? "Last Tab" : "Tab \(n)", #selector(AppDelegate.selectNumberedTab(_:)), "\(n)").tag = n
        }
        window.addItem(.separator())
        add(window, "New Space…", #selector(AppDelegate.newSpace(_:)), "n", [.command, .control])
        add(window, "Next Space", #selector(AppDelegate.nextSpace(_:)), right, [.control, .option])
        add(window, "Previous Space", #selector(AppDelegate.previousSpace(_:)), left, [.control, .option])
        for n in 1...9 {
            add(window, n == 9 ? "Last Space" : "Space \(n)", #selector(AppDelegate.selectNumberedSpace(_:)), "\(n)", [.control], hidden: true).tag = n
        }
        NSApp?.windowsMenu = window
        return main
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: LocalizedStringResource, _ action: Selector, _ key: String = "",
                            _ modifiers: NSEvent.ModifierFlags = [.command], hidden: Bool = false) -> NSMenuItem {
        let item = menu.addItem(withTitle: String(localized: title), action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        if hidden {
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        return item
    }

    private static func submenu(_ main: NSMenu, _ title: LocalizedStringResource) -> NSMenu {
        let title = String(localized: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }
}
