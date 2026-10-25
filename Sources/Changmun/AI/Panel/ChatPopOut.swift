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
            ChatPanel(chat: ChatStore.shared, browser: browser, inWindow: true).padding(Metrics.inset)
        }
        .ignoresSafeArea()
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = "Changmun AI"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 380, height: 620))
        window.contentMinSize = NSSize(width: 320, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("Changmun.aiPopOut")
        if !window.setFrameUsingName("Changmun.aiPopOut") { window.center() }
        self.window = window
        docksOnClose = true
        // Hidden in the browser window from here on (`Browser.showChat` keeps it so while this window is open).
        browser.showChat = false
        browserClosing = browser.window.map { host in
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: host, queue: .main) { _ in
                MainActor.assumeIsolated { ChatPopOut.shared.close(dock: false) }
            }
        }
        window.makeKeyAndOrderFront(nil)
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
        if let browserClosing { NotificationCenter.default.removeObserver(browserClosing) }
        browserClosing = nil
        // Questions waiting in the panel go to the window of the browser, where they can't be missed.
        if let browser { ApprovalCards.shared.moveToSheet(for: browser) }
        if dock, let browser { browser.showChat = true }
    }
}
