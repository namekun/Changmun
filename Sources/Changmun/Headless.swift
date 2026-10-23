import AppKit
import WebKit

/// A headless Changmun: the same browser driven through the control server. It never shows a window, takes focus or
/// makes a sound, and keeps its own profile: its bundle ID gives it separate settings and website data, and its files live
/// in their own folder. The user's keychain is left alone. There are two, which never share a profile or an endpoint:
/// `Changmun Headless.app` (scripts/headless.sh), the copy for tests, and `Changmun Agent.app` (`changmun headless start`,
/// UserHeadless.swift), the one the user's agents drive.
enum Headless {
    static let bundleID = "io.github.namekun.Changmun.headless"
    static let userBundleID = "io.github.namekun.Changmun.agent"

    static func isHeadless(bundleID id: String?) -> Bool { id == bundleID || id == userBundleID }
    /// The name of a headless app's profile folder in Application Support; nil for any other app.
    static func profileName(forBundle id: String?) -> String? {
        id == bundleID ? "Changmun Headless" : id == userBundleID ? "Changmun Agent" : nil
    }

    static let isOn = isHeadless(bundleID: Bundle.main.bundleIdentifier)
    /// The user's headless app, whose AI questions the user's agents get answered by Approvals.userHeadlessAnswer.
    static let isUser = Bundle.main.bundleIdentifier == userBundleID
    /// What only the test copy has: the endpoints that put the app into a state for a test.
    static let isTestCopy = Bundle.main.bundleIdentifier == bundleID

    /// Far off every screen, where windows still draw (and can be captured by window number) but nobody sees them.
    static let origin = NSPoint(x: -32000, y: -32000)
    static let windowSize = NSSize(width: 1440, height: 900)
}

/// A picture of a whole window, sidebar included, drawn by the app itself: it works off screen and needs no
/// screen recording permission. Pages draw in WebKit's own process, so each is laid in from a snapshot, under
/// whatever floats over it (bars, the find field).
@MainActor
enum WindowImage {
    static func png(of window: NSWindow) async -> Data? {
        // The window's frame view, so the window buttons above the content show too.
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        // A window that isn't key is never told to put its window buttons back, which AppKit may have moved since.
        (window as? BrowserWindow)?.layoutTrafficLights()
        view.layoutSubtreeIfNeeded()
        var stand: [NSView] = []
        for webView in webViews(in: view) where !webView.isHiddenOrHasHiddenAncestor {
            guard let snapshot = try? await webView.takeSnapshot(configuration: nil) else { continue }
            let image = NSImageView(frame: webView.bounds)
            image.image = snapshot
            image.imageScaling = .scaleAxesIndependently
            webView.addSubview(image)
            stand.append(image)
        }
        defer { stand.forEach { $0.removeFromSuperview() } }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        view.subviews.flatMap { ($0 as? WKWebView).map { [$0] } ?? webViews(in: $0) }
    }
}
