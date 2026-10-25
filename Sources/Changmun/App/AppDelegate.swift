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
        // Before anything reads the library, the spaces or the session: imported folders stored under another language's name get their canonical one.
        FolderKeyMigration.run(in: Library.folder)
        Library.shared.pruneHistory()
        // Once the windows are back: the icons of sites nothing is left from go.
        Task { await Browser.pruneIcons() }
        ChatStore.removeOldConfigs()
        let downloads = Downloads.folder
        DispatchQueue.global(qos: .utility).async { Downloads.removeOrphanedParts(in: downloads, olderThan: Date().addingTimeInterval(-86_400)) }
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
        ChatStore.shared.stopForQuit()
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
                  browser.showSidebar, Preferences.shared.tabLayout == .sidebar, !browser.focusMode, event.locationInWindow.x < Preferences.shared.sidebarWidth else { return event }
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
        case #selector(toggleBookmark(_:)): browser.active?.isPrivate != true
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
    @objc func toggleBrowserSidebar(_ sender: Any?) {
        if Preferences.shared.tabLayout == .top {
            browser.focusMode = false
            browser.showSidebarOverlay.toggle()
        } else {
            browser.showSidebar = browser.focusMode || !browser.showSidebar
        }
    }
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
        guard let tab = browser.active, !tab.isPrivate, let url = tab.url?.absoluteString else { return }
        _ = Library.shared.toggleBookmark(url: url, title: tab.bookmarkTitle, in: tab.favoritesFolder)
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
