import Foundation
import os
import Security
import WebKit

/// The tab's side of ServerTrust: a page whose server's certificate can't be verified is shown by the app (never by the page), and the user's way on.
extension Tab {
    /// The data store the tab's pages use: what a choice is kept apart by, so a profile's is not another's.
    var trustStoreID: UUID? {
        guard let browser, !browser.isPrivate else { return nil }
        return browser.spaces.space(spaceID).dataStoreID
    }

    /// Whether an exception may be offered or applied to this tab's pages (see ServerTrust.mayOffer).
    var mayOfferTrustException: Bool {
        ServerTrust.mayOffer(agentDriven: AgentActivity.shared.holds(self) || (webView.map(AppScripts.drives) ?? false),
                             headless: Headless.isOn, testCopy: Headless.isTestCopy)
    }

    /// Writes to the log (see ServerTrust.log) unless the window is private, which leaves nothing behind. Hosts go in as `.private`.
    private func trustLog(_ write: (Logger) -> Void) {
        guard browser?.isPrivate != true else { return }
        write(ServerTrust.log)
    }

    /// A server's certificate: judged by WebKit as ever, unless the user chose to go on with this very certificate for this host and port, in this
    /// window's store. A page that is not the user's, a certificate that changed since, and any other host or port are judged as ever. Subresources
    /// and scripts of the same host and port come under the same choice, as the connection is the same.
    ///
    /// WebKit keeps a certificate it was told to go on with in a session of its own for as long as the app runs, whoever asks (another store, a private
    /// window, the AI's page) and whatever the app has forgotten since. So for a host and port that the user went on with anywhere in this run, a load
    /// that this store's exception does not cover is judged by the Mac's own trust here and cancelled if that fails. The warning is made here only for
    /// the main frame load that is pending (see TrustFailure.pendingTarget); anything else is cancelled with no view.
    /// What scripts/test-server-trust.sh found with this check left out: within one store WebKit lets the AI's page, a later load, an exception taken
    /// away and a subresource through; a profile space (a store of its own) is not let through by what the default store accepted. A private window's
    /// store was not tried, so the check does not rely on that.
    func answerServerTrust(_ challenge: URLAuthenticationChallenge, in webView: WKWebView) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        if Headless.isTestCopy { ServerTrustTestState.challenges.append("\(space.host):\(space.port)") }
        let accepted = ServerTrustStore.acceptedAnywhere.contains(host: space.host, port: space.port)
        guard accepted else { return (.performDefaultHandling, nil) }
        // From here on nothing that is missing lets the load through: see ServerTrustChallengeDecision.
        let trust = space.serverTrust, store = browser?.trustStore
        let leaf = trust.flatMap(ServerTrust.leaf(of:))
        let fingerprint = leaf.map(ServerTrust.fingerprint(of:))
        let mayOffer = mayOfferTrustException
        let matches = fingerprint.map { store?.exceptions.allows(host: space.host, port: space.port, fingerprint: $0, store: trustStoreID) ?? false } ?? false
        switch ServerTrustChallengeDecision.decide(accepted: accepted, hasTrust: trust != nil, hasStore: store != nil, hasLeaf: leaf != nil,
                                                   systemTrusts: trust.map { SecTrustEvaluateWithError($0, nil) } ?? false, exceptionMatches: matches, mayOffer: mayOffer) {
        case .defaultHandling:
            return (.performDefaultHandling, nil)
        case .useException:
            trustLog { $0.notice("trust: exception applies to \(space.host, privacy: .private(mask: .hash)):\(space.port, privacy: .public), \((fingerprint ?? "").prefix(8), privacy: .public)") }
            return (.useCredential, URLCredential(trust: trust!))
        case .cancel:
            trustLog { $0.notice("trust: \(space.host, privacy: .private(mask: .hash)):\(space.port, privacy: .public) is not covered by an exception here and the Mac does not trust it, \((fingerprint ?? "-").prefix(8), privacy: .public); refused") }
            if let trust, let store, let target = TrustFailure.pendingTarget(navigatingTo: navigatingTo, host: space.host, port: space.port) {
                let failure = makeTrustFailure(trust: trust, url: target, code: NSURLErrorServerCertificateUntrusted, store: store)
                if mayOffer, failure != nil {
                    // The page that was shown may still be running behind the warning: it is replaced by an empty one, so there is nothing under the view
                    // and "Go Back" is one step.
                    errorNavigation = webView.loadHTMLString("", baseURL: nil)
                    trustFailure = failure
                } else if !mayOffer { showError(String(localized: "Can’t open the page"), String(localized: "The certificate of this site can’t be verified."), address: target, in: webView) }
            }
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    /// The failure for a page, with what the store knows of the site: whether another certificate was accepted for it, and whether it loaded over a
    /// connection the Mac trusted earlier in this run.
    private func makeTrustFailure(trust: SecTrust? = nil, error: NSError? = nil, url: URL?, code: Int, store: ServerTrustStore) -> TrustFailure? {
        let storeID = trustStoreID
        let exceptions = store.exceptions, trusted = store.trusted
        let changed = { (host: String, port: Int, fingerprint: String) in exceptions.isChanged(host: host, port: port, fingerprint: fingerprint, store: storeID) }
        let wasTrusted = { (host: String, port: Int) in trusted.contains(host: host, port: port, store: storeID) }
        if let error { return TrustFailure.from(error: error, url: url, changed: changed, wasTrusted: wasTrusted) }
        guard let trust, let url else { return nil }
        return TrustFailure.from(trust: trust, url: url, code: code, changed: changed, wasTrusted: wasTrusted)
    }

    /// A failed load of the main frame: if it failed for the server's certificate, the view over the tab says so.
    func offerTrustException(after error: NSError, in webView: WKWebView) {
        guard ServerTrust.failureCodes.contains(error.code), let store = browser?.trustStore else { return }
        guard let failure = makeTrustFailure(error: error, url: url, code: error.code, store: store) else {
            trustLog { $0.error("trust: error \(error.code, privacy: .public) with no certificate to show") }
            return
        }
        trustLog { $0.notice("trust: refused \(failure.host, privacy: .private(mask: .hash)):\(failure.port, privacy: .public), error \(failure.code, privacy: .public), \(failure.certificate.fingerprint.prefix(8), privacy: .public), changed \(failure.changed, privacy: .public), visit \(String(describing: failure.visit), privacy: .public)") }
        guard mayOfferTrustException else {
            trustLog { $0.notice("trust: not offered (a page the AI drives, or a headless Changmun)") }
            return
        }
        trustFailure = failure
    }

    /// "Visit This Website": after the Mac's owner confirms, the certificate this page showed is accepted for the host and port, and the page loads again.
    /// Not for a site that insists on https or one whose certificate was fine earlier in this run (see ServerTrustPolicy), and one question at a time.
    func continueToUntrustedSite() async {
        guard let failure = trustFailure, failure.visit == .offered, mayOfferTrustException, let store = browser?.trustStore, !isConfirmingTrust else { return }
        isConfirmingTrust = true
        defer { isConfirmingTrust = false }
        let confirmed = await ServerTrust.confirm(String(localized: "Authentication is required to visit \(failure.hostAndPort) although its certificate can’t be verified"))
        // The page may have been replaced, or taken by the AI, while the Mac asked.
        guard confirmed, trustFailure == failure, mayOfferTrustException else {
            trustLog { $0.notice("trust: not confirmed for \(failure.host, privacy: .private(mask: .hash)):\(failure.port, privacy: .public)") }
            return
        }
        store.exceptions.grant(host: failure.host, port: failure.port, fingerprint: failure.certificate.fingerprint, store: trustStoreID, details: failure.certificate)
        ServerTrustStore.acceptedAnywhere.add(host: failure.host, port: failure.port, owner: browser?.isPrivate == true ? browser.map(ObjectIdentifier.init) : nil, certificate: failure.certificate)
        trustLog { $0.notice("trust: the user went on with \(failure.host, privacy: .private(mask: .hash)):\(failure.port, privacy: .public), \(failure.certificate.fingerprint.prefix(8), privacy: .public)") }
        trustFailure = nil
        load(failure.url)
    }

    /// "Go Back": the warning goes, and the nearest page before it comes back that the tab may still show: pages of a site it has no exception for are
    /// skipped, as a page restored from the back/forward list is not asked about again.
    func leaveUntrustedSite() {
        trustFailure = nil
        guard let webView else { return }
        let list = webView.backForwardList
        let history = list.backList.compactMap(\.url)
        guard history.count == list.backList.count else { if webView.canGoBack { webView.goBack() }; return }
        let items = list.backList + (list.currentItem.map { [$0] } ?? [])
        let hasException = { (url: URL) -> Bool in
            guard let host = url.host(), url.scheme?.lowercased() == "https" else { return false }
            return self.browser?.trustStore.exceptions.hasException(host: host, port: url.port ?? 443, store: self.trustStoreID) == true
        }
        if let index = ServerTrust.backTarget(history: history + [url ?? URL(string: "about:blank")!],
                                              isStopped: { Self.isUnverified($0) && !(self.mayOfferTrustException && hasException($0)) }), index < list.backList.count {
            webView.go(to: items[index])
        }
    }

    /// "Stop trusting this certificate": the exception goes, and so does the page: the warning is shown again at once, over an empty page. WebKit may keep
    /// a connection it was let through on and use it for the next load with no question, so the page is not left to be judged by a reload; what the
    /// app can still do about such a connection is nothing (see ServerTrustChallengeDecision), which is why the address bar goes on saying the page is not verified.
    func stopTrustingCertificate() {
        guard let webView, let url = webView.url ?? url, let host = url.host(), let store = browser?.trustStore else { return }
        let port = url.port ?? 443
        let certificate = store.exceptions.revoke(host: host, port: port, store: trustStoreID)
        usesTrustException = false
        trustLog { $0.notice("trust: exception for \(host, privacy: .private(mask: .hash)):\(port, privacy: .public) taken away") }
        guard let certificate, mayOfferTrustException else { load(url); return }
        errorNavigation = webView.loadHTMLString("", baseURL: nil)
        trustFailure = TrustFailure(url: url, host: host, port: port, code: NSURLErrorServerCertificateUntrusted,
                                    reason: TrustReason.determine(code: NSURLErrorServerCertificateUntrusted, certificate: certificate, host: host, now: Date()),
                                    certificate: certificate, changed: false, visit: ServerTrustPolicy.visit(host: host, wasTrusted: false))
    }

    /// A main frame load of a host and port the user went on with in this run, which this tab may not use (the AI drives it, or this store has no exception for
    /// it): stopped here, because WebKit may carry it over a connection kept alive from before and then there is no certificate question to cancel.
    /// The user's tab gets the warning, with the certificate last gone on with; the AI's tab, the plain error. True when the load is stopped.
    func stopsLoad(of target: URL, in webView: WKWebView) -> Bool {
        guard target.scheme?.lowercased() == "https", let host = target.host(), let store = browser?.trustStore else { return false }
        let port = target.port ?? 443
        guard ServerTrustStore.isUnverified(host: host, port: port) else { return false }
        let mayOffer = mayOfferTrustException
        if mayOffer, store.exceptions.hasException(host: host, port: port, store: trustStoreID) { return false }
        trustLog { $0.notice("trust: load of \(host, privacy: .private(mask: .hash)):\(port, privacy: .public) stopped, no exception covers it here") }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if mayOffer, let certificate = ServerTrustStore.acceptedAnywhere.certificate(host: host, port: port) {
                self.errorNavigation = webView.loadHTMLString("", baseURL: nil)
                self.trustFailure = TrustFailure(url: target, host: host, port: port, code: NSURLErrorServerCertificateUntrusted,
                                                 reason: TrustReason.determine(code: NSURLErrorServerCertificateUntrusted, certificate: certificate, host: host, now: Date()),
                                                 certificate: certificate, changed: false, visit: ServerTrustPolicy.visit(host: host, wasTrusted: false))
            } else {
                self.showError(String(localized: "Can’t open the page"), String(localized: "The certificate of this site can’t be verified."), address: target, in: webView)
            }
        }
        return true
    }

    /// Whether the page now shown is on an exception (the address bar says so). `url` is the web view's own address of the page that committed: the
    /// tab's `url` is set from it a moment later and can still be the page before.
    func refreshTrustException(for url: URL?) {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host(), let store = browser?.trustStore else {
            if usesTrustException { usesTrustException = false }
            return
        }
        let port = url.port ?? 443
        let uses = store.exceptions.hasException(host: host, port: port, store: trustStoreID)
        if usesTrustException != uses { usesTrustException = uses }
        // A page that committed with no exception, and that WebKit was not let through on its own, has a certificate the Mac trusts.
        if !uses, !ServerTrustStore.isUnverified(host: host, port: port) { store.trusted.add(host: host, port: port, store: trustStoreID) }
    }

    /// The address bar does not show a lock: the page is one whose certificate could not be verified (a warning is up, or the user went on).
    var isUnverified: Bool { trustFailure != nil || usesTrustException || showsUnverifiedPage }

    /// Whether the page shown (or the origin of a frame in it) is one whose certificate the user went on with: nothing kept for a site is used there.
    var showsUnverifiedPage: Bool { Self.isUnverified(webView?.url) }

    static func isUnverified(_ url: URL?) -> Bool {
        guard let url, let host = url.host() else { return false }
        return ServerTrustStore.isUnverified(host: host, port: url.port ?? 443)
    }
}
