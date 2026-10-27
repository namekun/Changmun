import AppKit
import SwiftUI

/// Lets a vertical mouse wheel scroll the strip's tabs sideways, which a horizontal scroll view does not do by itself. Put behind the scroll
/// view; it takes the wheel only over its own area, only when the wheel moves more up and down than sideways (a trackpad's sideways scrolling
/// is the scroll view's own), and only when the tabs do not all fit, so there is nothing to move otherwise.
struct StripWheelScroll: NSViewRepresentable {
    /// How far a notch of a wheel without fine deltas moves the tabs, in points.
    private static let notch: CGFloat = 10

    /// Where the scroll view's content starts after the wheel moved by `delta` (positive: the content goes the way it does when scrolling
    /// toward its start), or nil when the content fits and stays put. Kept within the content.
    static func offset(current: CGFloat, delta: CGFloat, content: CGFloat, viewport: CGFloat) -> CGFloat? {
        guard content > viewport + 0.5 else { return nil }
        return min(max(current - delta, 0), content - viewport)
    }

    final class WheelView: NSView {
        private var monitor: Any?

        /// It only watches: every click and hover goes to what is under it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = window == nil ? nil : NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.scrolled(event) ?? event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func scrolled(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  let content = window.contentView, let frame = content.superview,
                  var hit = content.hitTest(frame.convert(event.locationInWindow, from: nil)) else { return event }
            while !(hit is NSScrollView), let up = hit.superview { hit = up }
            guard let scroller = hit as? NSScrollView, let document = scroller.documentView else { return event }
            let clip = scroller.contentView
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : StripWheelScroll.notch)
            guard let x = StripWheelScroll.offset(current: clip.bounds.origin.x, delta: delta, content: document.frame.width, viewport: clip.bounds.width) else { return event }
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
            scroller.reflectScrolledClipView(clip)
            return nil
        }
    }

    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ view: WheelView, context: Context) {}
}
