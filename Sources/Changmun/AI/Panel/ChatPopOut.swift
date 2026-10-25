import AppKit
import SwiftUI

/// The AI panel in a window of its own, for putting it beside the browser (or on another screen). It is the same chat and the same panel
/// view as the one in the browser window, which is hidden while this is open; closing the window docks the panel back.
///
/// Questions of the AI stay on cards in the panel: `Approvals` asks where the panel is shown, and that includes this window
/// (`panelBrowser`), and the keys that answer a card work in it as they do in the browser window.
@MainActor
final class ChatPopOut: NSObject, NSWindowDelegate {
    static let shared = ChatPopOut()

    private(set) var window: NSWindow?
    /// The browser window the panel came from: its tabs are the panel's.
    private(set) weak var browser: Browser?
    /// Closing the window docks the panel back, except when the panel's own close button ends it.
    private var docksOnClose = true
    private var browserClosing: NSObjectProtocol?

    /// The panel of `browser` is in the pop-out window.
    func isPoppedOut(for browser: Browser) -> Bool { window != nil && self.browser === browser }

    /// The browser whose panel the pop-out window shows; nil when it isn't open.
    var panelBrowser: Browser? { window == nil ? nil : browser }

    func open(for browser: Browser) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        self.browser = browser
        let content = ZStack {
            WindowMaterial()
            // The panel's header is on the row of the window buttons, so there is no inset above it.
            ChatPanel(chat: ChatStore.shared, browser: browser, inWindow: true).padding([.leading, .trailing, .bottom], Metrics.inset)
        }
        .ignoresSafeArea()
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        // Like the browser window: no title bar of its own (the title is kept for Mission Control and the Window menu).
        window.title = "Changmun AI"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 380, height: 620))
        window.contentMinSize = NSSize(width: 320, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("Changmun.aiPopOut")
        if !window.setFrameUsingName("Changmun.aiPopOut") { window.center() }
        self.window = window
        docksOnClose = true
        layoutTrafficLights()
        // The AI buttons of the browser window read as on while the panel is out.
        browser.objectWillChange.send()
        // Hidden in the browser window from here on (`Browser.showChat` keeps it so while this window is open).
        browser.showChat = false
        browserClosing = browser.window.map { host in
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: host, queue: .main) { _ in
                MainActor.assumeIsolated { ChatPopOut.shared.close(dock: false) }
            }
        }
        window.makeKeyAndOrderFront(nil)
        layoutTrafficLights()
    }

    /// The window buttons level with the panel's header, which is as high as the browser's page bar.
    private func layoutTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen), let close = window.standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        let height = BrowserWindow.pageBarHeight
        container.frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
        close.superview?.frame = container.bounds
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            window.standardWindowButton(kind)?.setFrameOrigin(NSPoint(x: BrowserWindow.windowButtonsLeading + CGFloat(index) * 20,
                                                                      y: height / 2 - (window.standardWindowButton(kind)?.frame.height ?? 0) / 2))
        }
    }

    func windowDidResize(_ notification: Notification) { layoutTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { layoutTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { layoutTrafficLights() }

    /// What bringing the window forward for a question comes to: it comes back from the Dock if it was put there, and goes in front of the
    /// other windows only while this app is the one in use (it never takes the screen from another app: the Dock icon bounces instead).
    struct Reveal: Equatable {
        var restore: Bool
        var orderFront: Bool
        var askAttention: Bool
    }

    static func reveal(miniaturized: Bool, appActive: Bool) -> Reveal {
        Reveal(restore: miniaturized, orderFront: appActive, askAttention: !appActive)
    }

    /// A question of the AI has come up on a card in this window: it must not be out of sight.
    func revealForQuestion() {
        guard let window else { return }
        let plan = Self.reveal(miniaturized: window.isMiniaturized, appActive: NSApp.isActive)
        if plan.restore { window.deminiaturize(nil) }
        if plan.orderFront { window.orderFrontRegardless() }
        if plan.askAttention { NSApp.requestUserAttention(.informationalRequest) }
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closes the window; `dock`: the panel comes back in the browser window, else it is closed altogether.
    func close(dock: Bool) {
        guard let window else { return }
        docksOnClose = dock
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        let browser = self.browser
        let dock = docksOnClose
        window?.delegate = nil
        window = nil
        self.browser = nil
        browser?.objectWillChange.send()
        if let browserClosing { NotificationCenter.default.removeObserver(browserClosing) }
        browserClosing = nil
        // Questions waiting in the panel go to the window of the browser, where they can't be missed.
        if let browser { ApprovalCards.shared.moveToSheet(for: browser) }
        if dock, let browser { browser.showChat = true }
    }
}
