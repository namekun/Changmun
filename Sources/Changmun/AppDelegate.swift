import UniformTypeIdentifiers
import Combine
import AppKit
import SwiftUI
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: BrowserWindow!
    private let browser = Browser.shared
    private var menuSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuSubscription = Preferences.shared.$shortcuts.sink { NSApp.mainMenu = AppMenu.make(scheme: $0) }
        window = BrowserWindow()
        let host = NSHostingView(rootView: BrowserView(browser: browser, chat: ChatStore.shared))
        host.sizingOptions = []
        window.contentView = host
        NSApp.appearance = Preferences.shared.appearance.nsAppearance
        Task { await AdBlocker.shared.start() }
        if #available(macOS 15.4, *) { Task { await ExtensionHost.shared.start() } }
        browser.restoreSession()
        browser.startSleepingIdleTabs()
        ControlServer.shared.start()
        watchMouseButtons()
        if !UserDefaults.standard.bool(forKey: "onboarded") { browser.showOnboarding = true }
        window.makeKeyAndOrderFront(nil)
        window.layoutTrafficLights()
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        browser.saveSession()
        ChatStore.shared.stop()
        ControlServer.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { browser.openTab(url: url) }
    }

    // MARK: Menu actions

    @objc func newTab(_ sender: Any?) { browser.commandBar = .newTab }
    @objc func openLocation(_ sender: Any?) {
        if browser.active == nil {
            browser.commandBar = .newTab
        } else if Preferences.shared.addressBarOnTop {
            browser.addressFocusRequest += 1
        } else {
            browser.commandBar = .editCurrent
        }
    }

    @objc func showSettings(_ sender: Any?) {
        Panels.show("settings", title: "설정", size: NSSize(width: 580, height: 500), resizable: false) { SettingsView(prefs: Preferences.shared) }
    }

    @objc func showHistory(_ sender: Any?) {
        Panels.show("history", title: "방문 기록", size: NSSize(width: 640, height: 560)) { HistoryView() }
    }

    @objc func showDownloads(_ sender: Any?) {
        Panels.show("downloads", title: "다운로드", size: NSSize(width: 480, height: 380)) { DownloadsView() }
    }

    @objc func showFind(_ sender: Any?) { browser.showFindBar() }
    @objc func findNext(_ sender: Any?) {
        if browser.findBarVisible { browser.find() } else { browser.showFindBar() }
    }
    @objc func findPrevious(_ sender: Any?) {
        if browser.findBarVisible { browser.find(backwards: true) } else { browser.showFindBar() }
    }
    @objc func reopenClosedTab(_ sender: Any?) { browser.reopenClosedTab() }

    private var mouseMonitor: Any?

    /// The side buttons on most mice (4 and 5) go back and forward in the browser window.
    private func watchMouseButtons() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, event.window is BrowserWindow, event.buttonNumber == 3 || event.buttonNumber == 4 else { return event }
            if event.buttonNumber == 3 { self.browser.active?.webView?.goBack() } else { self.browser.active?.webView?.goForward() }
            return nil
        }
    }

    @objc func printPage(_ sender: Any?) {
        guard let webView = browser.active?.webView, let window else { return }
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
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
        browser.flashStatus("주소를 복사했어요")
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
        if browser.commandBar != nil { browser.commandBar = nil; return }
        if let id = browser.activeID { browser.close(id) } else { window.performClose(nil) }
    }
    @objc func reload(_ sender: Any?) { browser.active?.webView?.reload() }
    @objc func hardReload(_ sender: Any?) { browser.active?.webView?.reloadFromOrigin() }
    @objc func goBack(_ sender: Any?) { browser.active?.webView?.goBack() }
    @objc func goForward(_ sender: Any?) { browser.active?.webView?.goForward() }
    @objc func toggleChat(_ sender: Any?) { browser.showChat.toggle() }
    @objc func toggleBrowserSidebar(_ sender: Any?) { browser.showSidebar.toggle() }
    @objc func nextTab(_ sender: Any?) { browser.selectTab(offset: 1) }
    @objc func previousTab(_ sender: Any?) { browser.selectTab(offset: -1) }
    @objc func selectNumberedTab(_ sender: NSMenuItem) { browser.selectTab(number: sender.tag) }
    @objc func zoomIn(_ sender: Any?) { browser.active?.webView.map { $0.pageZoom = min($0.pageZoom + 0.1, 3) } }
    @objc func zoomOut(_ sender: Any?) { browser.active?.webView.map { $0.pageZoom = max($0.pageZoom - 0.1, 0.3) } }
    @objc func actualSize(_ sender: Any?) { browser.active?.webView?.pageZoom = 1 }
    @objc func toggleBookmark(_ sender: Any?) {
        guard let tab = browser.active, let url = tab.url?.absoluteString else { return }
        _ = Library.shared.toggleBookmark(url: url, title: tab.title)
        tab.objectWillChange.send()
    }
    @objc func importData(_ sender: Any?) { browser.showOnboarding = true }
    @objc func newChat(_ sender: Any?) { ChatStore.shared.reset(); browser.showChat = true }
}

/// A window whose title bar is the tab strip: the traffic lights sit centered in the strip.
final class BrowserWindow: NSWindow {
    static let barHeight: CGFloat = 44

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = "Changmun"
        minSize = NSSize(width: 640, height: 420)
        isReleasedWhenClosed = false
        if !setFrameUsingName("ChangmunMain") { center() }
        setFrameAutosaveName("ChangmunMain")
        for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutTrafficLights() }
            }
        }
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
            button.setFrameOrigin(NSPoint(x: 16 + CGFloat(index) * 20, y: (height - button.frame.height) / 2))
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
        add(app, "Changmun 정보", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "설정…", #selector(AppDelegate.showSettings(_:)), ",")
        add(app, "다른 브라우저에서 가져오기…", #selector(AppDelegate.importData(_:)))
        app.addItem(.separator())
        add(app, "Changmun 가리기", #selector(NSApplication.hide(_:)), "h")
        add(app, "Changmun 종료", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu(main, "파일")
        add(file, "새 탭", #selector(AppDelegate.newTab(_:)), "t")
        add(file, "주소 열기", #selector(AppDelegate.openLocation(_:)), "l")
        add(file, "탭 닫기", #selector(AppDelegate.closeTab(_:)), "w")
        add(file, "닫은 탭 다시 열기", #selector(AppDelegate.reopenClosedTab(_:)), "t", [.command, .shift])
        add(file, "파일 열기…", #selector(AppDelegate.openFile(_:)), "o")
        file.addItem(.separator())
        add(file, "주소 복사", #selector(AppDelegate.copyAddress(_:)), "c", [.command, .shift])
        add(file, "인쇄…", #selector(AppDelegate.printPage(_:)), "p")

        let edit = submenu(main, "편집")
        add(edit, "실행 취소", Selector(("undo:")), "z")
        add(edit, "실행 복귀", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "오려두기", #selector(NSText.cut(_:)), "x")
        add(edit, "복사하기", #selector(NSText.copy(_:)), "c")
        add(edit, "붙여넣기", #selector(NSText.paste(_:)), "v")
        add(edit, "전체 선택", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "찾기…", #selector(AppDelegate.showFind(_:)), "f")
        add(edit, "다음 찾기", #selector(AppDelegate.findNext(_:)), "g")
        add(edit, "이전 찾기", #selector(AppDelegate.findPrevious(_:)), "g", [.command, .shift])

        let view = submenu(main, "보기")
        add(view, "새로고침", #selector(AppDelegate.reload(_:)), "r")
        add(view, "강력 새로고침", #selector(AppDelegate.hardReload(_:)), "r", chrome ? [.command, .shift] : [.command, .option])
        add(view, "사이드바", #selector(AppDelegate.toggleBrowserSidebar(_:)), chrome ? "s" : "l", chrome ? [.command] : [.command, .shift])
        add(view, "AI 패널", #selector(AppDelegate.toggleChat(_:)), "e")
        add(view, "새 AI 대화", #selector(AppDelegate.newChat(_:)), "e", [.command, .shift])
        view.addItem(.separator())
        add(view, "확대", #selector(AppDelegate.zoomIn(_:)), "+")
        add(view, "축소", #selector(AppDelegate.zoomOut(_:)), "-")
        add(view, "실제 크기", #selector(AppDelegate.actualSize(_:)), "0")
        view.addItem(.separator())
        add(view, "전체 화면", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let develop = submenu(main, "개발자")
        add(develop, "웹 인스펙터 (네트워크)", #selector(AppDelegate.toggleInspector(_:)), f12, [])
        add(develop, "웹 인스펙터 (네트워크)", #selector(AppDelegate.toggleInspector(_:)), "i", [.command, .option], hidden: true)
        add(develop, "콘솔", #selector(AppDelegate.showConsole(_:)), chrome ? "j" : "c", [.command, .option])

        let history = submenu(main, "방문 기록")
        add(history, "뒤로", #selector(AppDelegate.goBack(_:)), "[")
        add(history, "앞으로", #selector(AppDelegate.goForward(_:)), "]")
        history.addItem(.separator())
        add(history, "즐겨찾기 추가/제거", #selector(AppDelegate.toggleBookmark(_:)), "d")
        history.addItem(.separator())
        add(history, "모든 방문 기록 보기", #selector(AppDelegate.showHistory(_:)), "y")
        add(history, "다운로드", #selector(AppDelegate.showDownloads(_:)), chrome ? "j" : "l", chrome ? [.command, .shift] : [.command, .option])

        let window = submenu(main, "윈도우")
        add(window, "최소화", #selector(NSWindow.performMiniaturize(_:)), "m")
        window.addItem(.separator())
        add(window, "다음 탭", #selector(AppDelegate.nextTab(_:)), "]", [.command, .shift])
        add(window, "이전 탭", #selector(AppDelegate.previousTab(_:)), "[", [.command, .shift])
        add(window, "다음 탭", #selector(AppDelegate.nextTab(_:)), "\t", [.control], hidden: true)
        add(window, "이전 탭", #selector(AppDelegate.previousTab(_:)), "\t", [.control, .shift], hidden: true)
        if chrome {
            add(window, "다음 탭", #selector(AppDelegate.nextTab(_:)), right, [.command, .option], hidden: true)
            add(window, "이전 탭", #selector(AppDelegate.previousTab(_:)), left, [.command, .option], hidden: true)
        }
        for n in 1...9 {
            add(window, n == 9 ? "마지막 탭" : "탭 \(n)", #selector(AppDelegate.selectNumberedTab(_:)), "\(n)").tag = n
        }
        NSApp?.windowsMenu = window
        return main
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                            _ modifiers: NSEvent.ModifierFlags = [.command], hidden: Bool = false) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        if hidden {
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        return item
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }
}
