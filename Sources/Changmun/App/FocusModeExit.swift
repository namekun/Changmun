import AppKit
import SwiftUI

/// Focus mode hides the address bar and the sidebar, so the way out is at the top edge: while the pointer is there, a button says "Exit Focus Mode".
struct FocusModeExit: View {
    @ObservedObject var browser: Browser
    @State private var near = false

    /// The strip along the edge that wakes the button, and the room the pointer keeps while it is shown (the button's own).
    static func zoneHeight(near: Bool) -> CGFloat { near ? 56 : 8 }

    var body: some View {
        ZStack(alignment: .top) {
            EdgeHover(inside: $near).frame(height: Self.zoneHeight(near: near))
            if near {
                Button { browser.focusMode = false } label: {
                    HStack(spacing: 8) {
                        Text("Exit Focus Mode")
                        Keycap("⇧⌘F")
                    }
                }
                .buttonStyle(SecondaryButton(size: .regular))
                .e2()
                .padding(.top, 8)
                .transition(Motion.pop(.top))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Motion.quick, value: near)
    }
}

/// Says whether the pointer is over the view, and takes no click: the page under it keeps every one.
private struct EdgeHover: NSViewRepresentable {
    @Binding var inside: Bool

    func makeNSView(context: Context) -> Tracker {
        let view = Tracker()
        view.change = { inside = $0 }
        return view
    }

    func updateNSView(_ view: Tracker, context: Context) { view.change = { inside = $0 } }

    final class Tracker: NSView {
        var change: (Bool) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { change(true) }
        override func mouseExited(with event: NSEvent) { change(false) }
    }
}
