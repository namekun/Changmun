import AppKit
import SwiftUI

/// The AI panel in a window of its own, for putting it beside the browser (or on another screen). It is the same chat and the same panel
/// view as the one in the browser window, which is hidden while this is open; closing the window docks the panel back.
///
/// Questions of the AI stay on cards in the panel: `Approvals` asks where the panel is shown, and that includes this window
/// (`panelBrowser`), and the keys that answer a card work in it as they do in the browser window.
///
/// The menu's commands reach it too: with this window key, ⌘W and ⇧⌘W close it (docking the panel back, as its red button does), ⌘E closes
/// the panel as its X does, and the commands for the browser (⌘T, ⌘L, ⌘F…) are for the browser it belongs to (`keyBrowser`).
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

    /// Where the window shows up: on the space the user is in, which may be one a browser window is full screen in (a window is shown
    /// there only when it says it may), so that a question put to it is not missed. `.canJoinAllSpaces` would leave it on every space
    /// at once, which a window the user puts beside the browser should not do. The cost: it can't go full screen itself.
    static let spaces: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

    func open(for browser: Browser) {
        if window != nil {
            bringToFront()
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
        window.collectionBehavior = Self.spaces
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

    /// The browser the commands of the menu are for while this window is the key window; nil when another window is.
    func keyBrowser() -> Browser? { keyBrowser(NSApp?.keyWindow) }

    func keyBrowser(_ keyWindow: NSWindow?) -> Browser? {
        window != nil && keyWindow === window ? browser : nil
    }

    /// Close Tab and Close Window with this window key: they close it (the panel docks back) rather than a tab or the window of the browser,
    /// which would take this window with it. False when it isn't the key window.
    func closeFromMenu() -> Bool { closeFromMenu(NSApp?.keyWindow) }

    func closeFromMenu(_ keyWindow: NSWindow?) -> Bool {
        guard window != nil, keyWindow === window else { return false }
        close(dock: true)
        return true
    }

    /// ⌘E while the panel is out, from whichever window: what the panel's own X does. In this window with the cursor elsewhere than in the
    /// box it goes to the box first, as in the browser window. False when the panel isn't out.
    func toggleFromShortcut() -> Bool { toggleFromShortcut(NSApp?.keyWindow) }

    func toggleFromShortcut(_ keyWindow: NSWindow?) -> Bool {
        guard let window else { return false }
        let box = ComposerTextView.find(in: window)
        let place: AIPanelShortcut.Box = box == nil ? .missing : window.firstResponder === box ? .focused : .elsewhere
        if AIPanelShortcut.popOutAction(inPopOut: keyWindow === window, box: place) == .focusBox {
            window.makeFirstResponder(box)
        } else {
            close(dock: false)
        }
        return true
    }

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
        // Coming back from the Dock may make it the key window, which would put the user's typing in it: the window that had the keys gets them back.
        let keyBefore = NSApp.keyWindow
        if plan.restore { window.deminiaturize(nil) }
        if let keyBefore, keyBefore !== window, keyBefore.isVisible { keyBefore.makeKey() }
        if plan.orderFront { window.orderFrontRegardless() }
        if plan.askAttention { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// In front and key; from the Dock too, if it was put there (the AI button reads as on while the panel is out, and pressing it must show it).
    func bringToFront() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
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
