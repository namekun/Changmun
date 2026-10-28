import Foundation
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

    /// A server's certificate: judged by WebKit as ever, unless the user chose to go on with this very certificate for this host and port, in this
    /// window's store. A page that is not the user's, a certificate that changed since, and any other host or port are judged as ever. Subresources
    /// and scripts of the same host and port come under the same choice, as the connection is the same.
    ///
    /// WebKit keeps a certificate it was told to go on with for as long as the app runs, whoever asks and whatever the app has forgotten since. So for a
    /// host that has had an exception in this run, a load that the exception does not cover (a page the AI drives, a certificate that changed, an
    /// exception taken away) is judged by the Mac's own trust here, and cancelled if that fails; the page the user was loading then gets the warning
    /// from here, and any other the plain error.
    func answerServerTrust(_ challenge: URLAuthenticationChallenge, in webView: WKWebView) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        if Headless.isTestCopy { ServerTrustTestState.challenges.append("\(space.host):\(space.port)") }
        guard let trust = space.serverTrust, let store = browser?.trustStore, store.exceptions.hadException(host: space.host, port: space.port, store: trustStoreID),
              let leaf = ServerTrust.leaf(of: trust) else { return (.performDefaultHandling, nil) }
        let fingerprint = ServerTrust.fingerprint(of: leaf)
        let mayOffer = mayOfferTrustException
        if mayOffer, store.exceptions.allows(host: space.host, port: space.port, fingerprint: fingerprint, store: trustStoreID) {
            ServerTrust.log.notice("trust: exception applies to \(space.host, privacy: .public):\(space.port, privacy: .public), \(fingerprint.prefix(8), privacy: .public)")
            return (.useCredential, URLCredential(trust: trust))
        }
        guard !SecTrustEvaluateWithError(trust, nil) else { return (.performDefaultHandling, nil) }
        ServerTrust.log.notice("trust: \(space.host, privacy: .public):\(space.port, privacy: .public) is not covered by an exception and the Mac does not trust it, \(fingerprint.prefix(8), privacy: .public); refused")
        if let target = navigatingTo, target.host()?.lowercased() == space.host.lowercased(), (target.port ?? 443) == space.port {
            let exceptions = store.exceptions, storeID = trustStoreID
            let failure = TrustFailure.from(trust: trust, url: target, code: NSURLErrorServerCertificateUntrusted) {
                exceptions.isChanged(host: $0, port: $1, fingerprint: $2, store: storeID)
            }
            if mayOffer { trustFailure = failure } else { showError(String(localized: "Can’t open the page"), String(localized: "The certificate of this site can’t be verified."), address: target, in: webView) }
        }
        return (.cancelAuthenticationChallenge, nil)
    }

    /// A failed load of the main frame: if it failed for the server's certificate, the view over the tab says so.
    func offerTrustException(after error: NSError, in webView: WKWebView) {
        guard ServerTrust.failureCodes.contains(error.code) else { return }
        let store = trustStoreID
        let exceptions = browser?.trustStore.exceptions
        let failure = TrustFailure.from(error: error, url: url) { host, port, fingerprint in
            exceptions?.isChanged(host: host, port: port, fingerprint: fingerprint, store: store) ?? false
        }
        guard let failure else {
            ServerTrust.log.error("trust: error \(error.code, privacy: .public) with no certificate to show")
            return
        }
        ServerTrust.log.notice("trust: refused \(failure.host, privacy: .public):\(failure.port, privacy: .public), error \(failure.code, privacy: .public), \(failure.certificate.fingerprint.prefix(8), privacy: .public), changed \(failure.changed, privacy: .public)")
        guard mayOfferTrustException else {
            ServerTrust.log.notice("trust: not offered (a page the AI drives, or a headless Changmun)")
            return
        }
        trustFailure = failure
    }

    /// "Visit This Website": after the Mac's owner confirms, the certificate this page showed is accepted for the host and port, and the page loads again.
    func continueToUntrustedSite() async {
        guard let failure = trustFailure, mayOfferTrustException, let store = browser?.trustStore else { return }
        let confirmed = await ServerTrust.confirm(String(localized: "Authentication is required to visit a website whose certificate can’t be verified"))
        // The page may have been replaced, or taken by the AI, while the Mac asked.
        guard confirmed, trustFailure == failure, mayOfferTrustException else {
            ServerTrust.log.notice("trust: not confirmed for \(failure.host, privacy: .public):\(failure.port, privacy: .public)")
            return
        }
        store.exceptions.grant(host: failure.host, port: failure.port, fingerprint: failure.certificate.fingerprint, store: trustStoreID)
        ServerTrust.log.notice("trust: the user went on with \(failure.host, privacy: .public):\(failure.port, privacy: .public), \(failure.certificate.fingerprint.prefix(8), privacy: .public)")
        trustFailure = nil
        load(failure.url)
    }

    /// "Go Back": the warning goes, and the page before it comes back if there was one.
    func leaveUntrustedSite() {
        trustFailure = nil
        if webView?.canGoBack == true { webView?.goBack() }
    }

    /// "Stop trusting this certificate": the exception goes and the page is loaded again, which is judged as any other now.
    func stopTrustingCertificate() {
        guard let url, let host = url.host(), let store = browser?.trustStore else { return }
        store.exceptions.revoke(host: host, port: url.port ?? 443, store: trustStoreID)
        usesTrustException = false
        ServerTrust.log.notice("trust: exception for \(host, privacy: .public):\(url.port ?? 443, privacy: .public) taken away")
        load(url)
    }

    /// Whether the page now shown is on an exception (the address bar says so).
    func refreshTrustException() {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host(), let store = browser?.trustStore else {
            if usesTrustException { usesTrustException = false }
            return
        }
        let uses = store.exceptions.hasException(host: host, port: url.port ?? 443, store: trustStoreID)
        if usesTrustException != uses { usesTrustException = uses }
    }
}
