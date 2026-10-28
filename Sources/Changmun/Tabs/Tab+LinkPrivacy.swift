import WebKit

/// What a tab remembers of the rewrites in one navigation (see `Tab.rewriteNavigation`).
struct LinkRewriteState {
    /// The addresses already rewritten since the user last started a navigation: one is never rewritten twice, so a site that sends the page back
    /// to the address it was rewritten from can't make a loop.
    var chain: Set<URL> = []
    /// The secure attempt in flight and the http address to go back to if the site isn't there over https.
    var pendingUpgrade: (secure: URL, plain: URL)?
    /// Http addresses the user was offered after a secure address sent them back to http: they load as they are once.
    var plainOnce: Set<URL> = []
}

/// The hosts whose secure attempt found no site, or that the user went on with over http: kept for the run, in memory, apart for private windows.
@MainActor enum PlainHosts {
    static var normal: Set<String> = []
    static var privateWindows: Set<String> = []
}

extension Tab {
    private var plainHosts: Set<String> {
        get { isPrivate ? PlainHosts.privateWindows : PlainHosts.normal }
        set { if isPrivate { PlainHosts.privateWindows = newValue } else { PlainHosts.normal = newValue } }
    }

    /// Takes tracking parameters out of an address and tries http addresses over https first (see LinkRewrite): when the page about to load is
    /// another address than the one asked for, this load is cancelled and the other one begins. True when it was. This is the one place every
    /// main frame navigation passes, whoever started it: a click, a redirect, the address bar, a link opened in a new tab, the AI's tools.
    /// Back, forward and reload load what the history holds, and a form that sends data is not loaded twice.
    func rewriteNavigation(_ action: WKNavigationAction, userInitiated: Bool, in webView: WKWebView) -> Bool {
        guard action.targetFrame?.isMainFrame == true, let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              action.navigationType != .backForward, action.navigationType != .reload else { return false }
        if Self.startsUserNavigation(action.navigationType, userInitiated: userInitiated) { linkRewrite.chain.removeAll() }
        if linkRewrite.pendingUpgrade?.secure != url { linkRewrite.pendingUpgrade = nil }
        guard action.request.httpMethod?.uppercased() == "GET", action.request.httpBody == nil, action.request.httpBodyStream == nil else { return false }
        let prefs = Preferences.shared
        let isForm = action.navigationType == .formSubmitted || action.navigationType == .formResubmitted
        let stripsTracking = prefs.removeTrackingFromLinks && !isForm && !Preferences.matches(url.host(), prefs.trackingKeptHosts)
        var upgrades = prefs.preferSecureConnections
        if linkRewrite.plainOnce.remove(url) != nil {
            upgrades = false
            if let host = url.host().map(HTTPSFirst.normalized) { plainHosts.insert(host) }
        }
        guard let rewrite = LinkRewrite.rewrite(url, stripsTracking: stripsTracking, upgrades: upgrades, plainHosts: plainHosts, override: HTTPSFirst.testOverride) else { return false }
        if linkRewrite.chain.contains(url) {
            // A tracking parameter that comes back is the site's to send. A secure address that sends the page back to http is not followed
            // silently: the user is told, and an http page loads only when they press on.
            guard rewrite.plain != nil else { return false }
            linkRewrite.plainOnce.insert(url)
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                errorNavigation = showError(String(localized: "Can’t open the page securely"),
                                            String(localized: "This site sends you from a secure address back to an insecure one."), address: url, in: webView)
            }
            return true
        }
        linkRewrite.chain.insert(url)
        linkRewrite.pendingUpgrade = rewrite.plain.map { (secure: rewrite.url, plain: $0) }
        var request = action.request
        request.url = rewrite.url
        if rewrite.plain != nil { request.timeoutInterval = HTTPSFirst.timeout }
        Task { @MainActor [weak webView] in webView?.load(request) }
        return true
    }

    /// A secure attempt that found no site is tried again over http, once, and the host is not tried over https again in this run. Any other
    /// failure, a certificate's above all, is left to the error and the warning: it is never answered with http. True when http was loaded.
    func fallBackToHTTP(after error: NSError, in webView: WKWebView) -> Bool {
        guard let pending = linkRewrite.pendingUpgrade else { return false }
        let failing = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        guard HTTPSFirst.fallsBack(domain: error.domain, code: error.code, failing: failing, upgraded: pending.secure) else { return false }
        linkRewrite.pendingUpgrade = nil
        if let host = pending.plain.host().map(HTTPSFirst.normalized) { plainHosts.insert(host) }
        Self.load(pending.plain, in: webView)
        return true
    }
}
