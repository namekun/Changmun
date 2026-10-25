import AppKit
import SwiftUI
import WebKit

/// Who shows a tab's page, and where: the newest host to start showing it (in front, when the tab is shown, or behind, when
/// the AI is using the tab). When a view is replaced (a split that ends or begins, a peek kept as a tab) the host on its
/// way out is still updated after the new one took the page, and must not take it back.
struct PageOwner<Host: AnyObject> {
    enum Place {
        /// The page the host is there to show.
        case front
        /// A page kept in the window, not shown (see WebViewHost.Container.keep).
        case behind
    }

    private(set) weak var host: Host?
    private(set) var place = Place.front

    mutating func claim(_ new: Host, as place: Place = .front) {
        host = new
        self.place = place
    }

    func owns(_ candidate: Host) -> Bool { host === candidate }

    /// The host stops showing the page (it was passed on to another tab).
    mutating func release(_ old: Host) {
        if host === old { host = nil }
    }
}

struct WebViewHost: NSViewRepresentable {
    @ObservedObject var tab: Tab
    let browser: Browser
    /// The tabs the AI is using change what is kept behind the page here.
    @ObservedObject private var agent = AgentActivity.shared

    init(tab: Tab, browser: Browser) {
        self.tab = tab
        self.browser = browser
    }

    /// Holds a page that isn't shown, full size so that it lays out as it would, and out of the user's way: invisible,
    /// out of the accessibility tree, with no part of it under the pointer, and never the one that takes the keys.
    final class PassiveHost: NSView {
        private(set) weak var page: WKWebView?
        private(set) weak var tab: Tab?

        init(tab: Tab, page: WKWebView, frame: NSRect) {
            self.tab = tab
            self.page = page
            super.init(frame: frame)
            autoresizingMask = [.width, .height]
            wantsLayer = true
            alphaValue = 0
            page.frame = bounds
            page.autoresizingMask = [.width, .height]
            addSubview(page)
            tab.holdBehind(true)
        }
        required init?(coder: NSCoder) { fatalError() }

        /// Whether the page is still in here (another host may have taken it).
        var holdsPage: Bool { page?.superview === self }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
        override func isAccessibilityElement() -> Bool { false }
        override func accessibilityChildren() -> [Any]? { [] }
    }

    final class Container: NSView {
        /// What it shows now: SwiftUI reuses a container when the tab in the same place changes.
        weak var tab: Tab?
        weak var browser: Browser?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
        }
        required init?(coder: NSCoder) { fatalError() }

        /// Whether its page is meant to be on screen: a closed peek or a tab hidden by a switch isn't.
        var showsPage: Bool {
            guard let tab, let browser else { return false }
            return browser.isShown(tab) || browser.peek === tab
        }

        /// Whether it is the host of the window's page in front: the tab the browser has active, which the newest host claimed.
        /// Only it holds the pages the AI uses behind that one. A peek or the other pane of a split would hold them at its
        /// own smaller size, and drop them when it closes.
        var isMain: Bool {
            guard let browser else { return false }
            // A window with no tab in front (see HeldPagesHost) holds them for want of any other.
            guard let tab else { return browser.active == nil }
            return tab === browser.active && browser.peek !== tab && tab.pageOwner.owns(self)
        }

        private var passive: [PassiveHost] { subviews.compactMap { $0 as? PassiveHost } }

        /// With no tab to show it holds pages only, which are out of reach, and must not stand between the user and what is under it.
        override func hitTest(_ point: NSPoint) -> NSView? { tab == nil ? nil : super.hitTest(point) }

        /// The page in front: it takes the top place, whatever was there (a page it held behind included), and any other
        /// page that was in front goes.
        func show(_ webView: WKWebView) {
            for view in subviews where view !== webView && !(view is PassiveHost) { view.removeFromSuperview() }
            if webView.superview !== self {
                webView.frame = bounds
                webView.autoresizingMask = [.width, .height]
                addSubview(webView)
            } else if subviews.last !== webView {
                addSubview(webView, positioned: .above, relativeTo: nil)
            }
            for host in passive where host.page === webView || !host.holdsPage { host.removeFromSuperview() }
            tab?.holdBehind(false)
        }

        /// The page of `left` (the tab shown here when none is named) is back from a full screen window (WebKit moved it there and left a placeholder here): in front again, and
        /// as big as this is, wherever WebKit put it back (a host that went in the meantime), unless it is still away. If this
        /// shows another tab by now, the page is not its to show: it goes out of here, held again if the AI uses it.
        func restore(for left: Tab? = nil) {
            guard let left = left ?? tab else { return }
            guard left === tab else {
                left.pageOwner.release(self)
                if let page = left.webView, !WebViewHost.isAway(page), page.superview === self { page.removeFromSuperview() }
                holdWhatIsInUse()
                return
            }
            guard let tab, let webView = tab.webView, !WebViewHost.isAway(webView), tab.pageOwner.owns(self), showsPage else { return }
            if webView.superview !== self {
                show(webView)
            } else if webView.frame != bounds {
                webView.frame = bounds
            }
        }

        /// No page in front (the tab has none): what is held behind stays invisible, so it doesn't show through.
        func clearFront() {
            for view in subviews where !(view is PassiveHost) { view.removeFromSuperview() }
        }

        /// Pages the AI is using that aren't shown: kept in the window, behind the page that is, so WebKit counts them as
        /// visible and goes on running their timers and drawing, which it stops for a page without a window. They are
        /// silent there.
        func keep(_ tabs: [Tab]) {
            // A page in WebKit's full screen window isn't taken, and the host that is to get it back stays for it to return to.
            let pages = tabs.compactMap { tab -> (Tab, WKWebView)? in
                guard let page = tab.webView, !WebViewHost.isAway(page) else { return nil }
                return (tab, page)
            }
            for host in passive where !(host.page.map(WebViewHost.isAway) ?? false) && (!host.holdsPage || !pages.contains(where: { $0.1 === host.page })) {
                if host.holdsPage, let page = host.page {
                    page.removeFromSuperview()
                    host.tab?.holdBehind(false)
                }
                host.removeFromSuperview()
            }
            for (tab, page) in pages where !passive.contains(where: { $0.page === page }) {
                addSubview(PassiveHost(tab: tab, page: page, frame: bounds), positioned: .below, relativeTo: nil)
            }
            // Nothing held has the keys.
            if let responder = window?.firstResponder as? NSView, passive.contains(where: { responder.isDescendant(of: $0) }) {
                window?.makeFirstResponder(subviews.last)
            }
        }

        func releaseHeld() { keep([]) }

        /// Takes the pages the AI is using that nobody looks at, if this is the host to hold them, else lets go of any it has.
        func holdWhatIsInUse() {
            var held: [Tab] = []
            if isMain, let browser {
                held = Array(AgentActivity.shared.held.compactMap { id in browser.tabs.first { $0.id == id } }.filter { candidate in
                    candidate !== tab && !browser.isShown(candidate) && browser.peek !== candidate && candidate.webView != nil
                        && candidate.webView.map(WebViewHost.isAway) != true
                }.prefix(AgentActivity.maxHeld))
            }
            keep(held)
            for candidate in held { candidate.pageOwner.claim(self, as: .behind) }
        }
    }

    func makeNSView(context: Context) -> Container { Container() }

    /// The page is in WebKit's full screen window (a video's or another element's), with a placeholder where it was. A host
    /// that took it back then would leave the full screen window empty and, as it ends, WebKit nothing to put the page back in.
    static func isAway(_ webView: WKWebView) -> Bool { webView.fullscreenState != .notInFullscreen }

    func updateNSView(_ container: Container, context: Context) { update(container) }

    func update(_ container: Container) {
        if container.tab !== tab {
            // The tab the container showed before is not its to show, unless its page is in a full screen window and comes back to it.
            if let previous = container.tab, previous.webView.map(Self.isAway) != true { previous.pageOwner.release(container) }
            container.tab = tab
            tab.pageOwner.claim(container)
        }
        container.browser = browser
        if let webView = tab.webView {
            // A host fading out (a closed peek, a split that ended) must not take the page back from the one showing it.
            if webView.superview !== container, !Self.isAway(webView), tab.pageOwner.owns(container), container.showsPage {
                container.show(webView)
                DispatchQueue.main.async {
                    let shown = tab.id == browser.activeID || browser.peek === tab
                    if shown, browser.commandBar == nil, browser.showOnboarding == false { container.window?.makeFirstResponder(webView) }
                }
            }
        } else {
            container.clearFront()
        }
        container.holdWhatIsInUse()
    }

    /// A host that goes while it still holds a page meant to be shown hands it to the host that owns it, so the page
    /// doesn't go away with the container (and leave the window blank). The pages it held behind go to the host of the
    /// page in front, which may have updated before this one went.
    static func dismantleNSView(_ container: Container, coordinator: ()) {
        container.releaseHeld()
        if let main = container.browser?.active?.pageOwner.host, main !== container { main.holdWhatIsInUse() }
        guard let tab = container.tab, let webView = tab.webView, webView.superview === container, !isAway(webView),
              let owner = tab.pageOwner.host, owner !== container, owner.tab === tab, tab.pageOwner.place == .front, owner.showsPage else { return }
        owner.show(webView)
    }
}

/// Where the pages the AI uses are held while no tab is in front (the last tab of a space closed, an empty space): there is no
/// WebViewHost then, and a page in use that is in another space would be left without a window to run in.
struct HeldPagesHost: NSViewRepresentable {
    let browser: Browser
    @ObservedObject private var agent = AgentActivity.shared

    init(browser: Browser) { self.browser = browser }

    func makeNSView(context: Context) -> WebViewHost.Container { WebViewHost.Container() }

    func updateNSView(_ container: WebViewHost.Container, context: Context) { update(container) }

    func update(_ container: WebViewHost.Container) {
        container.browser = browser
        container.holdWhatIsInUse()
    }

    static func dismantleNSView(_ container: WebViewHost.Container, coordinator: ()) {
        WebViewHost.dismantleNSView(container, coordinator: ())
    }
}

struct EmptyPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.ink(0.3))
            HStack(spacing: 6) {
                Text("New Tab").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.faint)
                Keycap("⌘T")
                Text("AI").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.faint).padding(.leading, 8)
                Keycap("⌘E")
            }
        }
    }
}
