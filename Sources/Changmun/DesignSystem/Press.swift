import AppKit
import SwiftUI

/// One row's pressed state. The tracker sets it, so a press redraws the row under the pointer and nothing else.
@MainActor
final class PressState: ObservableObject {
    @Published fileprivate(set) var isPressed = false
}

/// Darkens a row the moment the left button goes down on it. It only watches the events, leaving clicks, drags and
/// menus to the views as before; rows tell it where they are.
@MainActor
final class PressTracker {
    static let shared = PressTracker()
    private struct Area {
        weak var state: PressState?
        var frame: CGRect
        var window: Int?
    }
    private var areas: [ObjectIdentifier: Area] = [:]
    private var pressed: [PressState] = []
    private var start: CGPoint?

    private init() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            MainActor.assumeIsolated { PressTracker.shared.handle(event) }
            return event
        }
        // A menu that opens takes the mouse-up with it, as does a window that loses focus mid-press.
        for name in [NSMenu.didBeginTrackingNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PressTracker.shared.release() }
            }
        }
    }

    func place(_ state: PressState, frame: CGRect, window: Int?) {
        areas[ObjectIdentifier(state)] = Area(state: state, frame: frame, window: window)
    }

    func remove(_ state: PressState) {
        areas[ObjectIdentifier(state)] = nil
    }

    private func handle(_ event: NSEvent) {
        guard let window = event.window, let content = window.contentView else { return }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        switch event.type {
        case .leftMouseDown where !event.modifierFlags.contains(.control):
            release()
            start = point
            pressed = areas.values.compactMap { $0.window == window.windowNumber && $0.frame.contains(point) ? $0.state : nil }
            for state in pressed { state.isPressed = true }
        case .leftMouseDragged:
            // A drag has begun: the row is being carried, not pressed.
            if !pressed.isEmpty, let start, hypot(point.x - start.x, point.y - start.y) > 4 { release() }
        default:
            release()
        }
    }

    func release() {
        start = nil
        for state in pressed { state.isPressed = false }
        pressed = []
    }
}

/// Tells the tracker where a pressable view is.
private struct PressArea: ViewModifier {
    let state: PressState
    @Environment(\.windowNumber) private var window

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { PressTracker.shared.place(state, frame: $0, window: window) }
            .onDisappear { PressTracker.shared.remove(state) }
    }
}

extension View {
    func pressArea(_ state: PressState) -> some View { modifier(PressArea(state: state)) }
}

private struct WindowNumberKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    /// The window the view is in, to tell its presses from another window's.
    var windowNumber: Int? {
        get { self[WindowNumberKey.self] }
        set { self[WindowNumberKey.self] = newValue }
    }
}
