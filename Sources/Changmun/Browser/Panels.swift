import AppKit
import SwiftUI

/// The app's other windows (settings, history), each made once and brought back on request.
@MainActor
enum Panels {
    private static var windows: [String: NSWindow] = [:]

    static func window(_ id: String) -> NSWindow? { windows[id] }

    static func show<V: View>(_ id: String, title: String, size: NSSize, resizable: Bool = true, @ViewBuilder content: () -> V) {
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .resizable, .miniaturizable] : [.titled, .closable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Changmun." + id)
        if !window.setFrameUsingName("Changmun." + id) { window.center() }
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
    }
}
