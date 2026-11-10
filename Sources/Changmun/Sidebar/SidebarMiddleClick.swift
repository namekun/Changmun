import AppKit
import SwiftUI

/// A click of the middle button on a tab's row closes the tab, as in Safari and Chrome. It only watches the middle button, so the left
/// button's clicks, drags and renames stay with the row. Rows tell it where they are; the list tells it where it is on screen, so a row
/// scrolled out of sight (still laid out by the lazy list) is not hit through the bar below the list.
@MainActor
final class MiddleClickTracker {
    static let shared = MiddleClickTracker()
    private struct Area {
        var frame: CGRect
        var window: Int?
        var close: () -> Void
    }
    private var areas: [AnyHashable: Area] = [:]
    private var lists: [Int: CGRect] = [:]

    private init() {
        NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { event in
            MainActor.assumeIsolated { MiddleClickTracker.shared.handle(event) } ? nil : event
        }
    }

    func place(_ id: AnyHashable, frame: CGRect, window: Int?, close: @escaping () -> Void) {
        areas[id] = Area(frame: frame, window: window, close: close)
    }

    func remove(_ id: AnyHashable) { areas[id] = nil }

    func placeList(_ frame: CGRect, window: Int?) {
        guard let window else { return }
        lists[window] = frame
    }

    /// True when the click was on a row: the press is taken, and the release closes the row's tab.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.buttonNumber == 2, let window = event.window, let content = window.contentView else { return false }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        let rows = Array(areas.values)
        guard let row = Self.hit(point, window: window.windowNumber, sheetShown: window.attachedSheet != nil, list: lists[window.windowNumber],
                                 rows: rows.map { ($0.frame, $0.window) }) else { return false }
        if event.type == .otherMouseUp { rows[row].close() }
        return true
    }

    /// Which row a point falls on: one of this window's, and inside the list as it shows on screen. None while a sheet is on the window (an
    /// approval, a page's question), which the click must not close a tab behind.
    nonisolated static func hit(_ point: CGPoint, window: Int, sheetShown: Bool, list: CGRect?, rows: [(frame: CGRect, window: Int?)]) -> Int? {
        guard !sheetShown, let list, list.contains(point) else { return nil }
        return rows.firstIndex { $0.window == window && $0.frame.contains(point) }
    }
}

private struct MiddleClickArea: ViewModifier {
    let id: AnyHashable
    let close: () -> Void
    @Environment(\.windowNumber) private var window

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MiddleClickTracker.shared.place(id, frame: $0, window: window, close: close) }
            .onDisappear { MiddleClickTracker.shared.remove(id) }
    }
}

private struct MiddleClickList: ViewModifier {
    @Environment(\.windowNumber) private var window

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MiddleClickTracker.shared.placeList($0, window: window) }
    }
}

extension View {
    /// A middle click on this row runs `close`.
    func closesOnMiddleClick(_ id: AnyHashable, close: @escaping () -> Void) -> some View { modifier(MiddleClickArea(id: id, close: close)) }
    /// The list the rows that close on a middle click are in.
    func middleClickList() -> some View { modifier(MiddleClickList()) }
}
