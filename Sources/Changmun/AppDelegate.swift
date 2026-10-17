import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: BrowserWindow!
    private let browser = Browser.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = AppMenu.make()
        window = BrowserWindow()
        let host = NSHostingView(rootView: BrowserView(browser: browser, chat: ChatStore.shared))
        host.sizingOptions = []
        window.contentView = host
        browser.restoreSession()
        browser.startSleepingIdleTabs()
        ControlServer.shared.start()
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
    @objc func openLocation(_ sender: Any?) { browser.commandBar = browser.active == nil ? .newTab : .editCurrent }
    @objc func closeTab(_ sender: Any?) {
        if browser.commandBar != nil { browser.commandBar = nil; return }
        if let id = browser.activeID { browser.close(id) } else { window.performClose(nil) }
    }
    @objc func reload(_ sender: Any?) { browser.active?.webView?.reload() }
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
    @MainActor
    static func make() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Changmun")
        app.addItem(withTitle: "Changmun 정보", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "다른 브라우저에서 가져오기…", action: #selector(AppDelegate.importData(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Changmun 가리기", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Changmun 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "파일")
        file.addItem(withTitle: "새 탭", action: #selector(AppDelegate.newTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "주소 열기", action: #selector(AppDelegate.openLocation(_:)), keyEquivalent: "l")
        file.addItem(withTitle: "탭 닫기", action: #selector(AppDelegate.closeTab(_:)), keyEquivalent: "w")

        let edit = submenu(main, "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = submenu(main, "보기")
        view.addItem(withTitle: "새로고침", action: #selector(AppDelegate.reload(_:)), keyEquivalent: "r")
        view.addItem(withTitle: "사이드바", action: #selector(AppDelegate.toggleBrowserSidebar(_:)), keyEquivalent: "s")
        view.addItem(withTitle: "AI 패널", action: #selector(AppDelegate.toggleChat(_:)), keyEquivalent: "e")
        view.addItem(withTitle: "새 AI 대화", action: #selector(AppDelegate.newChat(_:)), keyEquivalent: "E")
        view.addItem(.separator())
        view.addItem(withTitle: "확대", action: #selector(AppDelegate.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "축소", action: #selector(AppDelegate.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "실제 크기", action: #selector(AppDelegate.actualSize(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        view.addItem(withTitle: "전체 화면", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]

        let history = submenu(main, "방문 기록")
        history.addItem(withTitle: "뒤로", action: #selector(AppDelegate.goBack(_:)), keyEquivalent: "[")
        history.addItem(withTitle: "앞으로", action: #selector(AppDelegate.goForward(_:)), keyEquivalent: "]")
        history.addItem(.separator())
        history.addItem(withTitle: "즐겨찾기 추가/제거", action: #selector(AppDelegate.toggleBookmark(_:)), keyEquivalent: "d")

        let window = submenu(main, "윈도우")
        window.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        window.addItem(withTitle: "다음 탭", action: #selector(AppDelegate.nextTab(_:)), keyEquivalent: "}")
        window.addItem(withTitle: "이전 탭", action: #selector(AppDelegate.previousTab(_:)), keyEquivalent: "{")
        let ctrlTab = window.addItem(withTitle: "다음 탭", action: #selector(AppDelegate.nextTab(_:)), keyEquivalent: "\t")
        ctrlTab.keyEquivalentModifierMask = .control
        ctrlTab.isHidden = true
        ctrlTab.allowsKeyEquivalentWhenHidden = true
        let ctrlShiftTab = window.addItem(withTitle: "이전 탭", action: #selector(AppDelegate.previousTab(_:)), keyEquivalent: "\t")
        ctrlShiftTab.keyEquivalentModifierMask = [.control, .shift]
        ctrlShiftTab.isHidden = true
        ctrlShiftTab.allowsKeyEquivalentWhenHidden = true
        for n in 1...9 {
            let item = window.addItem(withTitle: n == 9 ? "마지막 탭" : "탭 \(n)", action: #selector(AppDelegate.selectNumberedTab(_:)), keyEquivalent: "\(n)")
            item.tag = n
        }
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }
}
