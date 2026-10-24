import UniformTypeIdentifiers
import Combine
import AppKit
import SwiftUI
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuSubscription: AnyCancellable?
    private var sessionTimer: Timer?

    /// The window in front; commands that need a window open one when none is.
    private var browser: Browser { Browser.current ?? BrowserWindow.open() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuSubscription = Preferences.shared.$shortcuts.sink { NSApp.mainMenu = AppMenu.make(scheme: $0) }
        NSApp.appearance = Preferences.shared.appearance.nsAppearance
        Task { await AdBlocker.shared.start() }
        Library.shared.pruneHistory()
        // Once the windows are back: the icons of sites nothing is left from go.
        Task { await Browser.pruneIcons() }
        ChatStore.removeOldConfigs()
        // Watching the library from the start, so no change goes unseen before a sidebar first shows.
        _ = LibraryWatcher.shared
        // Profiles deleted last time whose data couldn't be erased yet.
        Profiles.startDraining(SpaceStore.shared)
        if !Headless.isOn {
            Task { await ContentBlockerHost.shared.start() }
            if #available(macOS 15.4, *) { Task { await ExtensionHost.shared.start() } }
        }
        let saved = Browser.savedWindows()
        if saved.isEmpty {
            BrowserWindow.open().commandBar = .newTab
        } else {
            for session in saved { BrowserWindow.open(restoring: session) }
        }
        ControlServer.shared.start()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { Browser.saveSessionIfChanged() }
        }
        watchMouseButtons()
        watchPeekKeys()
        watchSwitcherKeys()
        watchSpaceSwipes()
        guard !Headless.isOn else { return }
        Updates.shared.start()
        if !UserDefaults.standard.bool(forKey: "onboarded") { browser.showOnboarding = true }
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Browser.saveSession()
        ChatStore.shared.stop()
        ChatStore.removeOldConfigs()
        ControlServer.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        let browser = Browser.recent ?? BrowserWindow.open()
        for url in urls { browser.openTab(url: url) }
        browser.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu actions

    @objc func newWindow(_ sender: Any?) { BrowserWindow.open().commandBar = .newTab }
    @objc func newPrivateWindow(_ sender: Any?) { BrowserWindow.open(private: true).commandBar = .newTab }
    @objc func closeWindow(_ sender: Any?) { Browser.current?.window?.performClose(nil) }
    @objc func toggleSplit(_ sender: Any?) { Browser.current?.toggleSplit() }
    @objc func nextSpace(_ sender: Any?) { Browser.current?.switchSpace(offset: 1) }
    @objc func previousSpace(_ sender: Any?) { Browser.current?.switchSpace(offset: -1) }
    @objc func selectNumberedSpace(_ sender: NSMenuItem) { Browser.current?.switchSpace(number: sender.tag) }
    @objc func newSpace(_ sender: Any?) { browser.spaceSheet = .new }

    @objc func newTab(_ sender: Any?) { browser.commandBar = .newTab }
    @objc func openLocation(_ sender: Any?) {
        if browser.active == nil {
            browser.commandBar = .newTab
        } else if Preferences.shared.addressBarOnTop && !browser.focusMode {
            browser.addressFocusRequest += 1
        } else {
            browser.commandBar = .editCurrent
        }
    }

    @objc func showSettings(_ sender: Any?) {
        Panels.show("settings", title: String(localized: "Settings"), size: NSSize(width: 720, height: 520), resizable: false) { SettingsView(prefs: Preferences.shared) }
        // The sidebar runs up behind the window buttons, with no title over the page.
        if let window = Panels.window("settings") {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
    }

    @objc func showHistory(_ sender: Any?) {
        Panels.show("history", title: String(localized: "History"), size: NSSize(width: 640, height: 560)) { HistoryView() }
    }

    @objc func showArchive(_ sender: Any?) {
        Panels.show("archive", title: String(localized: "Archived Tabs"), size: NSSize(width: 560, height: 520)) { ArchiveView() }
    }

    @objc func tidyTabs(_ sender: Any?) { browser.tidyTabs() }

    @objc func showDownloads(_ sender: Any?) {
        browser.showDownloads.toggle()
    }

    @objc func showFind(_ sender: Any?) { browser.showFindBar() }
    @objc func findNext(_ sender: Any?) {
        if browser.findBarVisible { browser.find() } else { browser.showFindBar() }
    }
    @objc func findPrevious(_ sender: Any?) {
        if browser.findBarVisible { browser.find(backwards: true) } else { browser.showFindBar() }
    }
    @objc func reopenClosedTab(_ sender: Any?) {
        if Browser.current?.closedTabs.isEmpty != false, let window = Browser.closedWindows.popLast() {
            BrowserWindow.open(restoring: window)
        } else {
            browser.reopenClosedTab()
        }
    }

    private var mouseMonitor: Any?

    private var focusMonitor: Any?
    private var keyMonitor: Any?
    private var switcherMonitor: Any?
    private var swipeMonitor: Any?

    /// The side buttons on most mice (4 and 5) go back and forward in the browser window. A click in the other half of
    /// a split makes that tab the active one.
    private func watchMouseButtons() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            guard let browser = (event.window as? BrowserWindow)?.browser, event.buttonNumber == 3 || event.buttonNumber == 4 else { return event }
            let webView = browser.peek?.webView ?? browser.active?.webView
            if event.buttonNumber == 3 { webView?.goBack() } else { webView?.goForward() }
            return nil
        }
        focusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let browser = (event.window as? BrowserWindow)?.browser, browser.peek == nil, let split = browser.shownSplit,
                  let hit = event.window?.contentView?.hitTest(event.locationInWindow) else { return event }
            for id in [split.left, split.right] where id != browser.activeID {
                if let webView = browser.tab(id)?.webView, hit.isDescendant(of: webView) { browser.activate(id) }
            }
            return event
        }
    }

    /// ⌃Tab's switcher goes to the picked tab when ⌃ comes up; esc puts it away.
    private func watchSwitcherKeys() {
        switcherMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            guard let browser = (event.window as? BrowserWindow)?.browser, browser.tabSwitcher != nil else { return event }
            if event.type == .flagsChanged && !event.modifierFlags.contains(.control) { browser.finishSwitching() }
            if event.type == .keyDown && event.keyCode == 53 {
                browser.cancelSwitching()
                return nil
            }
            return event
        }
    }

    /// Two fingers moving sideways over the sidebar (never over the page) go to the next space or the one before.
    private func watchSpaceSwipes() {
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.hasPreciseScrollingDeltas, let browser = (event.window as? BrowserWindow)?.browser, !browser.isPrivate,
                  browser.showSidebar, !browser.focusMode, event.locationInWindow.x < Preferences.shared.sidebarWidth else { return event }
            let began = event.phase.contains(.began), ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            guard let step = browser.swipe.scrolled(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, began: began, ended: ended) else { return event }
            // It stops at the ends, and a space with nothing in it stays empty: only a click or a key opens the bar.
            withAnimation(Motion.standard) { browser.switchSpace(offset: step, wraps: false, opensBar: false) }
            return nil
        }
    }

    /// While a link is peeked, esc closes it and ⌘↩ keeps it as a tab.
    private func watchPeekKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let browser = (event.window as? BrowserWindow)?.browser, browser.peek != nil, browser.commandBar == nil else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 && modifiers.isEmpty {
                browser.closePeek()
                return nil
            }
            if event.keyCode == 36 && modifiers == .command {
                browser.keepPeek()
                return nil
            }
            return event
        }
    }

    @objc func printPage(_ sender: Any?) {
        guard let webView = browser.active?.webView, let window = browser.window else { return }
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func savePDF(_ sender: Any?) {
        guard let tab = browser.active else { return }
        Task { await SavePage.save(tab, as: .pdf) }
    }

    @objc func captureFullPage(_ sender: Any?) {
        guard let tab = browser.active else { return }
        Task { await SavePage.save(tab, as: .image) }
    }

    /// Saving needs a page that is loaded, and a picture of a PDF document isn't offered.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(nextSpace(_:)), #selector(previousSpace(_:)), #selector(selectNumberedSpace(_:)), #selector(newSpace(_:)):
            Browser.current?.isPrivate != true
        case #selector(checkForUpdates(_:)): Updates.shared.canCheck
        case #selector(savePDF(_:)): browser.active?.webView != nil
        case #selector(captureFullPage(_:)): browser.active?.webView != nil && browser.active?.showsPDF != true
        default: true
        }
    }

    @objc func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.html, .pdf, .image, .plainText, .svg, .webArchive, .xml]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { browser.openTab(url: url) }
    }

    @objc func copyAddress(_ sender: Any?) {
        guard let address = browser.active?.url?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        browser.flashStatus(String(localized: "Address copied"))
    }

    /// Opens WebKit's Web Inspector on the Network tab, or closes it. WKWebView has no public API for this,
    /// so it goes through `_inspector`, guarded so a WebKit without it just beeps.
    @objc func toggleInspector(_ sender: Any?) {
        guard let inspector = activeInspector() else {
            NSSound.beep()
            return
        }
        if inspector.responds(to: NSSelectorFromString("isVisible")), inspector.value(forKey: "visible") as? Bool == true {
            inspector.perform(NSSelectorFromString("close"))
            return
        }
        inspector.perform(NSSelectorFromString("show"))
        Self.showNetworkTab(inspector, attempts: 20)
    }

    @objc func showConsole(_ sender: Any?) {
        guard let inspector = activeInspector(), inspector.responds(to: NSSelectorFromString("showConsole")) else {
            NSSound.beep()
            return
        }
        inspector.perform(NSSelectorFromString("showConsole"))
    }

    private func activeInspector() -> NSObject? {
        guard let webView = browser.active?.webView, webView.responds(to: NSSelectorFromString("_inspector")),
              let inspector = webView.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: NSSelectorFromString("show")) else { return nil }
        return inspector
    }

    /// The inspector's own page loads after `show`; keep trying until its `WI` object answers.
    private static func showNetworkTab(_ inspector: NSObject, attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard inspector.responds(to: NSSelectorFromString("inspectorWebView")),
                  let frontend = inspector.perform(NSSelectorFromString("inspectorWebView"))?.takeUnretainedValue() as? WKWebView else {
                return showNetworkTab(inspector, attempts: attempts - 1)
            }
            frontend.evaluateJavaScript("typeof WI !== 'undefined' && WI.showNetworkTab ? (WI.showNetworkTab(), true) : false") { result, _ in
                if result as? Bool != true { showNetworkTab(inspector, attempts: attempts - 1) }
            }
        }
    }
    @objc func closeTab(_ sender: Any?) {
        guard let browser = Browser.current else { return }
        if browser.peek != nil { return browser.closePeek() }
        if browser.commandBar != nil { browser.commandBar = nil; return }
        if let id = browser.activeID { browser.close(id) } else { browser.window?.performClose(nil) }
    }
    /// The page in front: the peek while one is open, otherwise the active tab.
    private var frontPage: WKWebView? { Browser.current.flatMap { $0.peek?.webView ?? $0.active?.webView } }
    @objc func reload(_ sender: Any?) { frontPage?.reload() }
    @objc func hardReload(_ sender: Any?) { frontPage?.reloadFromOrigin() }
    @objc func goBack(_ sender: Any?) { frontPage?.goBack() }
    @objc func goForward(_ sender: Any?) { frontPage?.goForward() }
    @objc func toggleChat(_ sender: Any?) {
        if browser.isPrivate { return NSSound.beep() }
        // Closed: it opens, with the cursor in its box. Open with the cursor elsewhere: the cursor goes to the box. In the box: it closes.
        let box = ComposerTextView.find(in: browser.window)
        let place: AIPanelShortcut.Box = box == nil ? .missing : browser.window?.firstResponder === box ? .focused : .elsewhere
        switch AIPanelShortcut.action(panelOpen: browser.showChat, focusMode: browser.focusMode, box: place) {
        case .open: browser.showChat = true
        case .focusBox: browser.window?.makeFirstResponder(box)
        case .close: browser.closeChat()
        }
    }
    @objc func toggleBrowserSidebar(_ sender: Any?) { browser.showSidebar = browser.focusMode || !browser.showSidebar }
    @objc func toggleFocusMode(_ sender: Any?) { browser.focusMode.toggle() }
    @objc func nextTab(_ sender: Any?) { browser.selectTab(offset: 1) }
    @objc func recentTab(_ sender: Any?) { switchRecent(backwards: false) }
    @objc func olderRecentTab(_ sender: Any?) { switchRecent(backwards: true) }
    private func switchRecent(backwards: Bool) {
        browser.cycleRecentTabs(backwards: backwards)
        // ⌃ already let go (a quick tap): switch at once.
        if !NSEvent.modifierFlags.contains(.control) { browser.finishSwitching() }
    }
    @objc func translatePage(_ sender: Any?) { (browser.peek ?? browser.active)?.toggleTranslation() }
    @objc func toggleReader(_ sender: Any?) { (browser.peek ?? browser.active)?.toggleReader() }
    @objc func seekBack(_ sender: Any?) { PictureInPictureKeys.target?.seekVideo(by: -PictureInPictureKeys.step) }
    @objc func seekForward(_ sender: Any?) { PictureInPictureKeys.target?.seekVideo(by: PictureInPictureKeys.step) }
    @objc func previousTab(_ sender: Any?) { browser.selectTab(offset: -1) }
    @objc func selectNumberedTab(_ sender: NSMenuItem) { browser.selectTab(number: sender.tag) }
    @objc func zoomIn(_ sender: Any?) { browser.active.map { $0.setZoom(($0.webView?.pageZoom ?? 1) + 0.1) } }
    @objc func zoomOut(_ sender: Any?) { browser.active.map { $0.setZoom(($0.webView?.pageZoom ?? 1) - 0.1) } }
    @objc func actualSize(_ sender: Any?) { browser.active?.setZoom(Preferences.shared.defaultZoom) }
    @objc func toggleMute(_ sender: Any?) { browser.active?.toggleMute() }
    @objc func togglePictureInPicture(_ sender: Any?) { (Browser.current?.peek ?? Browser.current?.active)?.pictureInPicture(.toggle) }
    @objc func toggleBookmark(_ sender: Any?) {
        guard let tab = browser.active, let url = tab.url?.absoluteString else { return }
        _ = Library.shared.toggleBookmark(url: url, title: tab.title, in: tab.favoritesFolder)
        tab.objectWillChange.send()
    }
    @objc func importData(_ sender: Any?) { browser.showOnboarding = true }
    @objc func checkForUpdates(_ sender: Any?) { Updates.shared.checkForUpdates() }
    @objc func newChat(_ sender: Any?) {
        let browser = Browser.recent ?? BrowserWindow.open()
        ChatStore.shared.reset()
        browser.showChat = true
        browser.window?.makeKeyAndOrderFront(nil)
    }
}

/// A window without a visible title bar: the traffic lights sit at the top of the sidebar, level with the page card's bar.
final class BrowserWindow: NSWindow, NSWindowDelegate {
    /// The space above the page bar's controls (the card itself runs to the window's top), and the bar: the traffic lights sit level with the bar.
    static let cardInset: CGFloat = 0
    static let pageBarHeight: CGFloat = 44
    static let barHeight = cardInset + pageBarHeight
    /// Just below the window buttons, where the sidebar starts when the page bar is on the page card.
    static let windowButtonsBottom = cardInset + pageBarHeight / 2 + 12
    /// The window buttons start where a sidebar row's icon does; controls beside them start one inset after the third.
    static let windowButtonsLeading: CGFloat = 16
    static let windowButtonsTrailing = windowButtonsLeading + 2 * 20 + 14 + Metrics.inset
    private static var windows: [BrowserWindow] = []

    let browser: Browser
    private var observers: [NSObjectProtocol] = []

    /// A new window in front, with its own tabs (and, private, its own throwaway cookies and site data).
    @discardableResult
    static func open(private isPrivate: Bool = false, restoring session: Browser.SavedSession? = nil) -> Browser {
        let browser = Browser(isPrivate: isPrivate)
        let window = BrowserWindow(browser: browser, cascadingFrom: windows.last)
        windows.append(window)
        browser.focused()
        if let session { browser.restore(session) }
        browser.startSleepingIdleTabs()
        if #available(macOS 15.4, *) { ExtensionHost.shared.windowOpened(browser) }
        window.makeKeyAndOrderFront(nil)
        browser.fullScreen = window.styleMask.contains(.fullScreen)
        window.layoutTrafficLights()
        return browser
    }

    private init(browser: Browser, cascadingFrom previous: BrowserWindow?) {
        self.browser = browser
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        // Clear, so the window's material shows the desktop through the sidebar.
        isOpaque = false
        backgroundColor = .clear
        title = browser.isPrivate ? String(localized: "Changmun Private Window") : "Changmun"
        minSize = NSSize(width: 640, height: 420)
        isReleasedWhenClosed = false
        delegate = self
        browser.window = self
        let host = NSHostingView(rootView: BrowserView(browser: browser, chat: ChatStore.shared))
        host.sizingOptions = []
        contentView = host
        // The first window keeps its place across launches; others step down from the one before.
        if Headless.isOn {
            setFrame(NSRect(origin: Headless.origin, size: Headless.windowSize), display: false)
        } else if let previous {
            setFrame(Self.cascaded(from: previous.frame, in: previous.screen?.visibleFrame), display: false)
        } else {
            if !setFrameUsingName("ChangmunMain") { center() }
            setFrameAutosaveName("ChangmunMain")
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutTrafficLights() }
            })
        }
        for (name, entering) in [(NSWindow.willEnterFullScreenNotification, true), (NSWindow.didEnterFullScreenNotification, true),
                                 (NSWindow.willExitFullScreenNotification, false), (NSWindow.didExitFullScreenNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.browser.fullScreen = entering }
            })
        }
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        Headless.isOn ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    /// One step down and right of the window before; a window that fills the screen leaves room for the step,
    /// so the new one never lands exactly on top of it.
    nonisolated static func cascaded(from frame: NSRect, in screen: NSRect?, step: CGFloat = 28) -> NSRect {
        var next = frame.offsetBy(dx: step, dy: -step)
        guard let screen else { return next }
        if next.maxX > screen.maxX { next.size.width = max(640, screen.maxX - next.minX) }
        if next.minY < screen.minY {
            next.size.height = max(420, next.maxY - screen.minY)
            next.origin.y = next.maxY - next.size.height
            next.origin.y = max(next.origin.y, screen.minY)
        }
        return next
    }

    func windowDidResignKey(_ notification: Notification) { browser.cancelSwitching() }

    func windowDidBecomeKey(_ notification: Notification) {
        browser.focused()
        if #available(macOS 15.4, *) { ExtensionHost.shared.windowFocused(browser) }
    }

    func windowWillClose(_ notification: Notification) {
        // The last ordinary window to close is the one the next launch restores; others can come back with ⌘⇧T.
        if !browser.isPrivate {
            if Browser.all.contains(where: { $0 !== browser && !$0.isPrivate }) {
                if !browser.tabs.isEmpty { Browser.closedWindows = Array((Browser.closedWindows + [browser.savedSession]).suffix(5)) }
            } else {
                Browser.saveSession([browser])
            }
        }
        browser.windowClosed()
        observers.forEach(NotificationCenter.default.removeObserver)
        Self.windows.removeAll { $0 === self }
    }

    func layoutTrafficLights() {
        guard !styleMask.contains(.fullScreen),
              let close = standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        let height = Self.barHeight
        container.frame = NSRect(x: 0, y: frame.height - height, width: frame.width, height: height)
        close.superview?.frame = container.bounds
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = standardWindowButton(kind) else { continue }
            button.isHidden = browser.focusMode
            button.setFrameOrigin(NSPoint(x: Self.windowButtonsLeading + CGFloat(index) * 20, y: height - Self.cardInset - Self.pageBarHeight / 2 - button.frame.height / 2))
        }
    }
}

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
