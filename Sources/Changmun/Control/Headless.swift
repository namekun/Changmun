import AppKit
import WebKit

/// A headless Changmun: the same browser driven through the control server. It never shows a window, takes focus or
/// makes a sound, and keeps its own profile: its bundle ID gives it separate settings and website data, and its files live
/// in their own folder. The user's keychain is left alone. There are two, which never share a profile or an endpoint:
/// `Changmun Headless.app` (scripts/headless.sh), the copy for tests, and `Changmun Agent.app` (`changmun headless start`,
/// UserHeadless.swift), the one the user's agents drive.
enum Headless {
    static let bundleID = ProfileNames.headlessBundleID
    static let userBundleID = ProfileNames.userBundleID

    static func isHeadless(bundleID id: String?) -> Bool { ProfileNames.isHeadless(bundleID: id) }
    /// The name of a headless app's profile folder in Application Support; nil for any other app.
    static func profileName(forBundle id: String?) -> String? { ProfileNames.profileName(forBundle: id) }

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
    /// `popoverAt` puts a popover's top left corner there (points from the window's top left): the window is off screen, so the system pushes a popover to
    /// the screen's edge instead of leaving it by what it points at.
    static func png(of window: NSWindow, popoverAt: CGPoint? = nil) async -> Data? {
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
        // A popover is a window of its own over this one: drawn in, where it stands.
        let popovers = NSApp.windows.filter { $0 !== window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        guard !popovers.isEmpty, let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: canvas) else { return rep.representation(using: .png, properties: [:]) }
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        rep.draw(in: view.bounds)
        for popover in popovers {
            // What the popover draws into a bitmap: its text and field, on a flat fill (its material and arrow do not draw).
            guard let top = popover.contentView?.superview ?? popover.contentView, let shot = top.bitmapImageRepForCachingDisplay(in: top.bounds) else { continue }
            top.cacheDisplay(in: top.bounds, to: shot)
            let at = popoverAt.map { CGPoint(x: $0.x, y: view.bounds.height - $0.y - top.bounds.height) } ?? CGPoint(x: popover.frame.minX - window.frame.minX, y: popover.frame.minY - window.frame.minY)
            shot.draw(in: CGRect(origin: at, size: top.bounds.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        view.subviews.flatMap { ($0 as? WKWebView).map { [$0] } ?? webViews(in: $0) }
    }
}

/// What the test copy measures after a page's element went full screen and came back: where the tab in front's web view
/// is, in its host or in another window, and whether it is shown.
@MainActor
enum FullscreenMeasure {
    private static func rect(_ r: CGRect) -> [Int] { [Int(r.minX.rounded()), Int(r.minY.rounded()), Int(r.width.rounded()), Int(r.height.rounded())] }

    static func report(of browser: Browser) async -> [String: Any] {
        guard let tab = browser.active, let page = tab.webView else { return ["error": "no page"] }
        var chain: [String] = []
        var view: NSView? = page
        while let current = view {
            chain.append("\(type(of: current)) \(rect(current.frame))" + (current.isHidden ? " isHidden" : "") + (current.alphaValue == 0 ? " alpha0" : ""))
            view = current.superview
        }
        var report: [String: Any] = ["state": page.fullscreenState.rawValue, "chain": chain, "inWindow": page.window != nil,
                                     "inBrowserWindow": page.window === browser.window, "frame": rect(page.frame),
                                     "hasLayer": page.layer != nil, "hidden": page.isHiddenOrHasHiddenAncestor]
        if let container = tab.pageOwner.host as? WebViewHost.Container {
            report["owner"] = ["bounds": rect(container.bounds), "subviews": container.subviews.map { "\(type(of: $0)) \(rect($0.frame))" },
                               "ownsPage": page.superview === container]
        }
        let script = "JSON.stringify([!!document.fullscreenElement, innerWidth, innerHeight])"
        report["page"] = (try? await page.evaluateJavaScript(script)) as? String ?? "no answer"
        return report
    }
}
