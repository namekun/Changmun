import AppKit
import Combine
import SwiftUI
import WebKit

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
