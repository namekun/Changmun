import AppKit
import WebKit

/// `Changmun Headless.app` (scripts/headless.sh): the same browser for tests and agents, driven through the control
/// server. It never shows a window, takes focus or makes a sound, and keeps its own profile: its bundle ID gives it
/// separate settings and website data, and its files live in their own folder. The user's keychain is left alone.
enum Headless {
    static let bundleID = "io.github.namekun.Changmun.headless"
    static let isOn = Bundle.main.bundleIdentifier == bundleID

    /// Far off every screen, where windows still draw (and can be captured by window number) but nobody sees them.
    static let origin = NSPoint(x: -32000, y: -32000)
    static let windowSize = NSSize(width: 1440, height: 900)
}

/// A picture of a whole window, sidebar included, drawn by the app itself: it works off screen and needs no
/// screen recording permission. Pages draw in WebKit's own process, so each is pasted in from a snapshot.
@MainActor
enum WindowImage {
    static func png(of window: NSWindow) async -> Data? {
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        for webView in webViews(in: view) where !webView.isHiddenOrHasHiddenAncestor {
            guard let snapshot = try? await webView.takeSnapshot(configuration: nil) else { continue }
            var frame = webView.convert(webView.bounds, to: view)
            if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            // Pages round only their bottom corners, under the card's bar.
            NSBezierPath(roundedRect: NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + 12), xRadius: 12, yRadius: 12).addClip()
            snapshot.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep.representation(using: .png, properties: [:])
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        view.subviews.flatMap { ($0 as? WKWebView).map { [$0] } ?? webViews(in: $0) }
    }
}
