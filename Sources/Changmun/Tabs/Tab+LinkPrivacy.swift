import WebKit

/// The secure attempt of a load the browser started, and what to do if the site isn't there over https. It belongs to that load alone (`navigation`):
/// the failure of any other never brings the http address.
struct PendingUpgrade {
    var navigation: WKNavigation?
    var secure: URL
    var plain: URL
}

@MainActor enum PlainHosts {
    static var memory = PlainHostMemory()
}

/// Removing tracking from links and preferring secure connections, for the loads the browser starts itself: the address bar, a bookmark, the
/// sidebar, a link opened in a new tab or the peek, the AI's tools. Nobody else started those, so there is no page whose initiator, referrer
/// policy or window target a rewrite could lose. What a page does itself (a link pressed in it, a redirect, a script, a form) is never rewritten:
/// an address the app issued in its place would be the browser's own, and a site's SameSite cookies and Sec-Fetch-Site would no longer tell a
/// cross-site link from the user typing the address. (A content rule list with a redirect action would do it inside the request, but WebKit
/// compiles and then ignores `redirect` and `make-https` outside web extensions.)
extension Tab {
    private var privateWindowID: ObjectIdentifier? { browser.flatMap { $0.isPrivate ? ObjectIdentifier($0) : nil } }

    private var openPrivateWindows: Set<ObjectIdentifier> { Set(Browser.all.filter(\.isPrivate).map(ObjectIdentifier.init)) }

    /// What a load the browser starts really loads: without tracking parameters, and over https when that is tried first.
    private func rewriteForBrowserLoad(_ url: URL) -> (url: URL, timeout: TimeInterval?, upgrade: PendingUpgrade?) {
        pendingUpgrade = nil
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return (url, nil, nil) }
        let prefs = Preferences.shared
        let plainHosts = PlainHosts.memory.hosts(store: trustStoreID, privateWindow: privateWindowID, windows: openPrivateWindows)
        guard let rewrite = LinkRewrite.rewrite(url, stripsTracking: prefs.removeTrackingFromLinks && !Preferences.matches(url.host(), prefs.trackingKeptHosts),
                                                upgrades: prefs.preferSecureConnections, plainHosts: plainHosts, override: HTTPSFirst.testOverride) else { return (url, nil, nil) }
        let upgrade = rewrite.plain.map { PendingUpgrade(navigation: nil, secure: rewrite.url, plain: $0) }
        return (rewrite.url, upgrade == nil ? nil : HTTPSFirst.timeout, upgrade)
    }

    /// Loads an address the browser starts (the address bar, a bookmark, a link opened in a new tab, the AI's tools) in the view.
    func browserLoad(_ url: URL, in view: WKWebView) {
        let target = rewriteForBrowserLoad(url)
        let navigation = Self.load(target.url, in: view, timeout: target.timeout)
        pendingUpgrade = target.upgrade.map { PendingUpgrade(navigation: navigation, secure: $0.secure, plain: $0.plain) }
    }

    /// A secure attempt that found no site is tried again over http, once, and the host is not tried over https again for a while. Any other
    /// failure, a certificate's above all, is left to the error and the warning: it is never answered with http, nor is the failure of a load that
    /// is not the attempt. A timeout counts only where the AI isn't driving the tab. True when http is on its way.
    func fallBackToHTTP(after error: NSError, of navigation: WKNavigation?, in webView: WKWebView) -> Bool {
        let pending = pendingUpgrade
        pendingUpgrade = nil
        guard let pending, let navigation, navigation === pending.navigation else { return false }
        let failing = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        guard HTTPSFirst.fallsBack(domain: error.domain, code: error.code, failing: failing, upgraded: pending.secure, allowsTimeout: !AgentActivity.shared.holds(self)) else { return false }
        if let host = pending.plain.host(percentEncoded: false) {
            PlainHosts.memory.insert(host: host, store: trustStoreID, privateWindow: privateWindowID, windows: openPrivateWindows)
        }
        Self.load(pending.plain, in: webView)
        return true
    }
}
