import AppKit
import WebKit

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // A frame that is about to show another document is no longer the one the AI's tools were told about.
        if action.targetFrame?.isMainFrame == false { agent.frameNavigated() }
        if action.navigationType == .formResubmitted, agentHistoryMove {
            resubmitBlocked = true
            return (.cancel, preferences)
        }
        if action.shouldPerformDownload { return (.download, preferences) }
        if action.targetFrame?.isMainFrame ?? true, let target = action.request.url, ["http", "https"].contains(target.scheme?.lowercased() ?? "") { navigatingTo = target }
        let userInitiated = !AppScripts.drives(webView) && Self.userStartedForAppLinks(Self.isUserInitiated(action), knowsUserInitiated: Self.knowsUserInitiated)
        if let url = action.request.url, let scheme = url.scheme?.lowercased(), !Self.browserSchemes.contains(scheme) {
            // A frame can't speak for the page: the question is only for what the page itself, or the user's click, asks.
            appLinkRequested(url, navigationType: action.navigationType, userInitiated: userInitiated,
                             isMainFrame: (action.targetFrame?.isMainFrame ?? true) && action.sourceFrame.isMainFrame,
                             site: Self.askingSite(of: action.sourceFrame), in: webView)
            return (.cancel, preferences)
        }
        if action.targetFrame?.isMainFrame ?? true, !AgentActivity.shared.holds(self), Self.startsUserNavigation(action.navigationType, userInitiated: userInitiated) {
            askedForAppSinceUserNavigation = false
        }
        // Local files load only as the user opened them: that file, or files in its folder (which it may read anyway).
        if let url = action.request.url, url.isFileURL {
            guard Self.fileLoadAllowed(url, userOpened: userFileLoad) else { return (.cancel, preferences) }
            // Never handed to a new tab, which would treat it as opened by the user.
            return (.allow, preferences)
        }
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) || action.buttonNumber == Self.middleButton,
           let url = action.request.url {
            browser?.openTab(url: url, activate: action.modifierFlags.contains(.shift), after: self).openerID = id
            return (.cancel, preferences)
        }
        if Self.isPeekClick(action), let url = action.request.url {
            browser?.openPeek(url)
            return (.cancel, preferences)
        }
        return (Self.allowHere, preferences)
    }

    /// The schemes the browser shows itself; any other address is for an app.
    static let browserSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript"]

    /// Allows the load here, without first offering the address to an app that claims it (a Safari web app made with
    /// Add to Dock, a universal link). WebKit's plain allow tries that first, and a page opened in a new window then
    /// never loads: YouTube's link to YouTube Music left two blank tabs. The value is WebKit's own
    /// `_WKNavigationActionPolicyAllowWithoutTryingAppLink`, the one after `.download`.
    static let allowHere = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.download.rawValue + 1) ?? .allow

    /// WebKit reports the mouse button as a mask: left 1, right 2, middle 4.
    static let middleButton = 4

    /// ⇧-click on a link (without ⌘) opens it in the peek.
    static func isPeekClick(_ action: WKNavigationAction) -> Bool {
        action.navigationType == .linkActivated && action.buttonNumber != middleButton
            && ["http", "https"].contains(action.request.url?.scheme?.lowercased() ?? "")
            && action.modifierFlags.contains(.shift) && !action.modifierFlags.contains(.command)
    }

    /// Schemes that mount servers, run commands or change settings: a page never gets to launch these.
    static let blockedSchemes: Set<String> = ["smb", "afp", "nfs", "ftp", "ftps", "vnc", "ssh", "telnet", "x-apple.systempreferences",
                                              "x-man-page", "applescript", "itms-services", "facetime", "facetime-audio", "tel", "shortcuts", "workflow",
                                              "x-help-action", "prefs", "sftp", "callto", "sms"]

    /// A page's address for an app (mailto:, zoommtg:, the claude: a sign-in ends with). Whatever brought it, a click, a server's
    /// redirect or a script, the user is asked whether to open the app, as Safari does; the navigation itself is always cancelled.
    /// `site` is the page or frame that asks, as its own origin says. The question is a sheet on the window, one at a time, and a
    /// tab gets to ask once until the user next navigates (see `startsUserNavigation`): a page can't go on asking by loading
    /// itself again. An empty window the page opened for it is closed.
    func appLinkRequested(_ url: URL, navigationType: WKNavigationType, userInitiated: Bool, isMainFrame: Bool, site: String?, in webView: WKWebView) {
        let scheme = url.scheme?.lowercased() ?? ""
        let blocked = Self.blockedSchemes.contains(scheme)
        let app = blocked ? nil : appLinks.appName(url)
        let decision = Self.appLinkDecision(navigationType: navigationType, userInitiated: userInitiated, isMainFrame: isMainFrame,
                                            askedSinceUserNavigation: askedForAppSinceUserNavigation, questionShowing: appLinkQuestionShowing,
                                            headless: Headless.isOn, agentDriven: AgentActivity.shared.holds(self) || AppScripts.drives(webView),
                                            blocked: blocked, hasApp: app != nil, tabShown: browser.map { $0.isShown(self) || $0.peek === self } ?? false)
        if decision == .ask, let app {
            askedForAppSinceUserNavigation = true
            appLinkQuestionShowing = true
            let site = site ?? String(localized: "This page")
            let window = webView.window ?? browser?.window
            Task { @MainActor in
                let open = await appLinks.confirm(site, app, url, window)
                appLinkQuestionShowing = false
                if open { appLinks.open(url) }
            }
        }
        if isMainFrame, openerID != nil, webView.url == nil || webView.url?.scheme == "about", !webView.canGoBack { closeEmptyPopup() }
    }

    enum AppLinkDecision { case ask, cancelSilently }

    /// Whether a navigation to an app's address asks the user. A click of the user's always does (the one case allowed in a frame
    /// too); anything else asks only in the main frame and only once until the user navigates again, whatever the answer was.
    /// Nothing asks while a question is up, in a headless Changmun, for a page the AI is driving, for a scheme that is blocked,
    /// when no app handles it, or for a tab that isn't shown (the sheet would come up on a window whose page is another's).
    nonisolated static func appLinkDecision(navigationType: WKNavigationType, userInitiated: Bool, isMainFrame: Bool, askedSinceUserNavigation: Bool,
                                            questionShowing: Bool, headless: Bool, agentDriven: Bool, blocked: Bool, hasApp: Bool, tabShown: Bool) -> AppLinkDecision {
        guard !headless, !agentDriven, !blocked, hasApp, !questionShowing, tabShown else { return .cancelSilently }
        if navigationType == .linkActivated && userInitiated { return .ask }
        return isMainFrame && !askedSinceUserNavigation ? .ask : .cancelSilently
    }

    /// A navigation the user started: a click on a link or a form's button, back, forward, reload. Only these (and an address the
    /// user loads, see `Tab.load`) give a page its question back; a page's own redirects and loads never do.
    nonisolated static func startsUserNavigation(_ type: WKNavigationType, userInitiated: Bool) -> Bool {
        userInitiated && [.linkActivated, .formSubmitted, .backForward, .reload, .formResubmitted].contains(type)
    }

    /// The site a frame asks for, by the origin it runs in, never by the address the tab shows: an ad's frame is not the page.
    @MainActor static func askingSite(of frame: WKFrameInfo) -> String? {
        askingSite(originHost: frame.securityOrigin.host, requestURL: frame.request.url)
    }

    nonisolated static func askingSite(originHost: String, requestURL: URL?) -> String? {
        originHost.isEmpty ? requestURL?.host() : originHost
    }

    /// The window a sign-in opened and sent to an app's address has nothing to show once that is cancelled.
    private func closeEmptyPopup() {
        Task { @MainActor [weak self] in
            guard let self, let browser else { return }
            if browser.peek === self { browser.closePeek() } else { browser.close(id, remember: false) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame { showsPDF = response.response.mimeType == "application/pdf" }
        return response.isForMainFrame && !response.canShowMIMEType ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.track(download, from: self)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.track(download, from: self)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // The page that asked for the pop-up is on its way out: its bar goes now, not at the commit, so that no button is pressed
        // while the tab's address and the bar's site have parted ways.
        blockedPopup = nil
        // A certificate a page asked for is not wanted by the one that replaces it.
        browser?.certificatePrompter.forget(self)
        // The warning about a certificate belongs to the page that failed, not to the one that comes next (or our own page for the error).
        if navigation == nil || navigation !== errorNavigation { trustFailure = nil }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        navigations += 1
        if webView.url?.isFileURL != true { userFileLoad = nil }
        // A new site gets its own zoom; staying on the same one keeps what the user set (a private tab never saves it).
        let host = webView.url?.host()
        if host != zoomHost {
            zoomHost = host
            let zoom = Preferences.shared.zoom(for: host)
            if webView.pageZoom != zoom { webView.pageZoom = zoom }
        }
        // Sign-ins often land on another host of the same site (login.example.com → www.example.com).
        if let offer = loginOffer, !Self.sameSite(Logins.hostname(ofKey: offer.host), host) { loginOffer = nil }
        forgetPage()
        agent.reset()
        refreshTrustException()
        if let host = webView.url?.host(), let cached = Browser.favicons[host] { favicon = cached }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishedState = webView.interactionState as? Data
        loadFavicon()
        if sortsIntoGroup, webView.url?.scheme?.hasPrefix("http") == true, webView.title?.isEmpty == false {
            sortsIntoGroup = false
            browser?.sortIntoGroup(self)
        }
        if !isPrivate, let url = webView.url?.absoluteString { Library.shared.recordVisit(url: url, title: webView.title ?? "") }
        checkForLogins()
        let page = page
        Task {
            let language = await PageTranslator.foreignLanguage(of: webView)
            if self.page == page && translation == .original { foreignLanguage = language }
        }
        if webView.url?.scheme?.hasPrefix("http") == true { Task { await checkReader() } }
    }

    /// What belonged to the page that was shown: a new page, or a sleeping tab, starts without it.
    func forgetPage() {
        page += 1
        translating?.cancel()
        translating = nil
        blockedPopup = nil
        isInPictureInPicture = false
        foreignLanguage = nil
        translation = .original
        isReadable = false
        isReading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled, nsError.domain != "WebKitErrorDomain" || nsError.code != 102 else { return }
        let failing = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        errorNavigation = showError(String(localized: "Can’t open the page"), nsError.localizedDescription, address: failing, in: webView)
        if let failing { url = failing }
        offerTrustException(after: nsError, in: webView)
    }

    /// A page of our own in place of one that couldn't be shown, with a way to try again.
    @discardableResult
    func showError(_ heading: String, _ message: String, address: URL?, in webView: WKWebView) -> WKNavigation? {
        let escape = { (text: String) in
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let link = address.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? escape($0.absoluteString) : nil }
        let retry = link.map { "<a href=\"\($0)\" style=\"display: inline-block; margin-top: 16px; padding: 6px 14px; border-radius: 8px; background: rgba(128,128,128,0.16); color: CanvasText; text-decoration: none; font-weight: 600; font-size: 13px\">\(escape(String(localized: "Try Again")))</a>" } ?? ""
        return webView.loadHTMLString("""
        <meta name="color-scheme" content="light dark"><title>\(escape(heading))</title>
        <body style="font: 13px -apple-system; display: grid; place-content: center; height: 90vh; text-align: center; color: #888">
        <h2 style="color: CanvasText; font-weight: 600; font-size: 17px; margin: 0 0 8px">\(escape(heading))</h2><div>\(escape(message))</div>
        <div style="font-size: 11px; margin-top: 4px">\(escape(address?.absoluteString ?? ""))</div>\(retry)
        </body>
        """, baseURL: nil)
    }

    /// Sites behind HTTP authentication ask for a user name and password, and others for a certificate. A server's own certificate is
    /// judged by WebKit as ever.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodClientCertificate { return await answerCertificateRequest(challenge) }
        if method == NSURLAuthenticationMethodServerTrust { return answerServerTrust(challenge, in: webView) }
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else { return (.performDefaultHandling, nil) }
        guard challenge.previousFailureCount < 3, !Headless.isOn else { return (.cancelAuthenticationChallenge, nil) }
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign in to \(challenge.protectionSpace.host)")
        alert.informativeText = challenge.previousFailureCount > 0 ? String(localized: "The user name or password is incorrect.") : (challenge.protectionSpace.realm ?? "")
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = String(localized: "User Name")
        user.stringValue = challenge.proposedCredential?.user ?? ""
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = String(localized: "Password")
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        fields.addSubview(user)
        fields.addSubview(password)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = user
        alert.addButton(withTitle: String(localized: "Sign In"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
    }

    /// A site that wants a certificate to identify the user (see ClientCertificates). Cancel, no certificate, and a headless Changmun all go on
    /// without one (`performDefaultHandling`, not cancelling the load): a site that asks for a certificate but doesn't insist shows its own
    /// page, and one that does insist fails the connection, which Changmun's error page reports, where a cancelled load would leave a blank tab.
    private func answerCertificateRequest(_ challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard !Headless.isOn, let browser else { return (.performDefaultHandling, nil) }
        let space = challenge.protectionSpace
        let issuers = space.distinguishedNames ?? []
        // A profile space has a website data store of its own, and what was chosen in it is not what is chosen in another.
        let profile = browser.isPrivate ? nil : browser.spaces.space(spaceID).dataStoreID
        let site = ClientCertificates.requestKey(host: space.host, port: space.port, acceptedIssuers: issuers, store: profile)
        let prompter = browser.certificatePrompter
        let agentDriven = AgentActivity.shared.holds(self)
        let prompt = { (candidates: [ClientCertificates.Candidate]) in
            ClientCertificatePrompter.Prompt(host: space.host, candidates: candidates, agentDriven: agentDriven,
                                             domain: ClientCertificates.domainToRemember(host: space.host, port: space.port, isPrivate: self.isPrivate, agentDriven: agentDriven,
                                                                        isProfile: profile != nil))
        }
        let environment = ClientCertificates.Environment(
            situation: ClientCertificates.Situation(isHeadless: Headless.isOn, agentDriven: agentDriven, isProfile: profile != nil),
            identities: { ClientCertificates.keychainIdentities() },
            preferred: { ClientCertificates.preferredIdentity(names: $0, acceptedIssuers: $1) },
            remembered: prompter.remembered.choice(forSite: site, agentDriven: agentDriven),
            exists: { ClientCertificates.identityExists($0) },
            ask: { await prompter.ask(prompt($0), queueKey: ClientCertificates.queueKey(site: site, agentDriven: agentDriven, tab: self.id), site: site, tab: self) })
        guard let identity = await ClientCertificates.resolve(host: space.host, port: space.port, acceptedIssuers: issuers, environment: environment)?.identity else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
    }

    /// The page's process went away (it crashed, or was killed for memory): load it again, but a page that keeps
    /// crashing stops after two tries, and a tab nobody is looking at just goes to sleep.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashes = crashes.filter { $0.timeIntervalSinceNow > -30 } + [Date()]
        if browser?.isShown(self) != true && browser?.peek !== self && !AgentActivity.shared.holds(self) {
            sleep()
        } else if crashes.count <= 2 {
            // A crash during the first load leaves no history to reload: the address is loaded again.
            if webView.backForwardList.currentItem == nil, let address = webView.url ?? url {
                Self.load(address, in: webView)
            } else {
                webView.reload()
            }
        } else {
            showError(String(localized: "This page keeps crashing"), String(localized: "Changmun stopped reloading it."), address: url, in: webView)
        }
    }
}
