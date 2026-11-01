import AppKit

/// The one window class of the app: every window it makes (the browser's, settings, history, the AI's own window, an extension's options, a
/// dialog's sheet) is this or a subclass of it, so that a headless copy (Headless.swift) can never put one where anybody sees it.
/// Scripts/check-windows.sh fails for an `NSWindow` or `NSPanel` made anywhere else. In a headless copy, whatever puts the window somewhere (its
/// own frame, centring, a saved frame, being ordered front) leaves it at `Headless.origin`, which no screen reaches; macOS is not let to pull
/// it back onto one (`constrainFrameRect`), and it does not animate. Anywhere else it is an NSWindow.
class AppWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        pinned ? offScreen(frameRect) : Headless.isOn ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override func center() {
        if pinned { setFrameOrigin(Headless.origin) } else { super.center() }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(pinned ? offScreen(frameRect) : frameRect, display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(pinned ? offScreen(frameRect) : frameRect, display: displayFlag, animate: pinned ? false : animateFlag)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(pinned ? Headless.origin : point)
    }

    override func setFrameTopLeftPoint(_ point: NSPoint) {
        super.setFrameTopLeftPoint(pinned ? NSPoint(x: Headless.origin.x, y: Headless.origin.y + frame.height) : point)
    }

    /// A saved frame is where a person left the window: not for a headless copy, which keeps none.
    override func setFrameUsingName(_ name: NSWindow.FrameAutosaveName, force: Bool) -> Bool {
        Headless.isOn ? false : super.setFrameUsingName(name, force: force)
    }

    @discardableResult
    override func setFrameAutosaveName(_ name: NSWindow.FrameAutosaveName) -> Bool {
        Headless.isOn ? false : super.setFrameAutosaveName(name)
    }

    override func orderFront(_ sender: Any?) {
        keepOffScreen()
        super.orderFront(sender)
    }

    override func orderFrontRegardless() {
        keepOffScreen()
        super.orderFrontRegardless()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        keepOffScreen()
        super.makeKeyAndOrderFront(sender)
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        keepOffScreen()
        super.order(place, relativeTo: otherWin)
    }

    /// A headless copy's window that is not a sheet: a sheet hangs from the window it belongs to, which is off screen already.
    private var pinned: Bool { Headless.isOn && !isSheet }

    private func offScreen(_ frame: NSRect) -> NSRect { NSRect(origin: Headless.origin, size: frame.size) }

    private func keepOffScreen() {
        guard pinned else { return }
        animationBehavior = .none
        if frame.origin != Headless.origin { super.setFrame(offScreen(frame), display: false) }
    }
}
