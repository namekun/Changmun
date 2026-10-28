import WebKit

/// What a tab remembers of the secure attempt in flight (see `Tab.rewriteForBrowserLoad`).
struct LinkRewriteState {
    /// The secure attempt in flight, the http address to go back to if the site isn't there over https, and the frame that clicked the link (nil
    /// for a load the browser started).
    var pendingUpgrade: (secure: URL, plain: URL, initiator: WKFrameInfo?)?
}

@MainActor enum PlainHosts {
    static var memory = PlainHostMemory()
}

extension Tab {
    private var activePlainHosts: Set<String> { PlainHosts.memory.hosts(store: trustStoreID, isPrivate: isPrivate) }

    private func plan(_ url: URL) -> LinkRewrite.Result? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let prefs = Preferences.shared
        return LinkRewrite.rewrite(url, stripsTracking: prefs.removeTrackingFromLinks && !Preferences.matches(url.host(), prefs.trackingKeptHosts),
                                   upgrades: prefs.preferSecureConnections, plainHosts: activePlainHosts, override: HTTPSFirst.testOverride)
    }

    /// The address a load the browser starts itself really loads (the address bar, a bookmark, a link opened in a new tab or the peek, the AI's
    /// tools): without tracking parameters, and over https when that is tried first. Nobody else started that load, so there is no initiator to keep
    /// (see `LinkRewrite.mayRewriteInPage` for the page's).
    func rewriteForBrowserLoad(_ url: URL) -> (url: URL, timeout: TimeInterval?) {
        linkRewrite.pendingUpgrade = nil
        guard let rewrite = plan(url) else { return (url, nil) }
        linkRewrite.pendingUpgrade = rewrite.plain.map { (secure: rewrite.url, plain: $0, initiator: nil) }
        return (rewrite.url, rewrite.plain == nil ? nil : HTTPSFirst.timeout)
    }

    /// A link the user pressed in the page: the address is rewritten, and the page's own frame goes there, as the link would have. The navigation
    /// keeps its initiator that way (the page's site, for SameSite cookies and Sec-Fetch-Site: a cross-site link stays a cross-site link), where a
    /// load the app issued for it would be the browser's own. True when the click is replaced; any other navigation of the page is loaded as it is.
    func rewriteClick(_ action: WKNavigationAction, userInitiated: Bool, in webView: WKWebView) -> Bool {
        guard let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        guard action.targetFrame?.isMainFrame == true else { return false }
        if linkRewrite.pendingUpgrade?.secure != url { linkRewrite.pendingUpgrade = nil }
        guard LinkRewrite.mayRewriteInPage(type: action.navigationType, userInitiated: userInitiated, sourceIsMainFrame: action.sourceFrame.isMainFrame,
                                           targetIsMainFrame: action.targetFrame?.isMainFrame == true,
                                           isPlainGET: action.request.httpMethod?.uppercased() == "GET" && action.request.httpBody == nil && action.request.httpBodyStream == nil),
              let rewrite = plan(url) else { return false }
        linkRewrite.pendingUpgrade = rewrite.plain.map { (secure: rewrite.url, plain: $0, initiator: action.sourceFrame) }
        navigate(action.sourceFrame, to: rewrite.url, in: webView)
        return true
    }

    /// The page's frame navigates to the address, from the app's own isolated world (the page's scripts and its content security policy are not
    /// involved). If the frame is gone the page the user clicked in is gone too, and there is nothing to go on from.
    private func navigate(_ frame: WKFrameInfo, to url: URL, in webView: WKWebView) {
        Task { @MainActor [weak self, weak webView] in
            do {
                _ = try await webView?.callAsyncJavaScript("location.assign(address)", arguments: ["address": url.absoluteString], in: frame, contentWorld: .defaultClient)
            } catch {
                self?.linkRewrite.pendingUpgrade = nil
            }
        }
    }

    /// A secure attempt that found no site is tried again over http, once, and the host is not tried over https again for a while. Any other
    /// failure, a certificate's above all, is left to the error and the warning: it is never answered with http. A link the user pressed is
    /// gone to the same way it was gone to (by the page's frame). True when http is on its way.
    func fallBackToHTTP(after error: NSError, in webView: WKWebView) -> Bool {
        guard let pending = linkRewrite.pendingUpgrade else { return false }
        let failing = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        guard HTTPSFirst.fallsBack(domain: error.domain, code: error.code, failing: failing, upgraded: pending.secure) else { return false }
        linkRewrite.pendingUpgrade = nil
        if let host = pending.plain.host() { PlainHosts.memory.insert(host: host, store: trustStoreID, isPrivate: isPrivate) }
        if let frame = pending.initiator {
            navigate(frame, to: pending.plain, in: webView)
        } else {
            Self.load(pending.plain, in: webView)
        }
        return true
    }
}
