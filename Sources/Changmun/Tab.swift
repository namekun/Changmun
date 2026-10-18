import AppKit
import WebKit

/// One tab. A sleeping tab has no web view (and so no web content process); it keeps its
/// back/forward state and loads again when it is shown.
@MainActor
final class Tab: NSObject, ObservableObject, Identifiable {
    let id: Int
    /// Set when this tab belongs to a bookmark or favorite: it lives in that bookmark's place, not in the tab list.
    var bookmarkKey: String?
    @Published var title: String
    @Published var url: URL?
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var favicon: NSImage?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var savedLogins: [String] = []
    /// A sign-in just submitted on this page, waiting for the user to save it or not.
    @Published var loginOffer: LoginOffer?
    @Published private(set) var isPlayingAudio = false
    @Published private(set) var isMuted = false
    private var audioWatcher: AudioWatcher?
    private var zoomHost: String?
    @Published private(set) var webView: WKWebView?
    var lastShown = Date()
    private var savedState: Data?
    private var observations: [NSKeyValueObservation] = []
    private(set) weak var browser: Browser?

    var isAsleep: Bool { webView == nil }
    var isPrivate: Bool { browser?.isPrivate == true }

    init(id: Int, url: URL?, title: String = "", state: Data? = nil, browser: Browser) {
        self.id = id
        self.url = url
        self.title = title
        self.savedState = state
        self.browser = browser
        super.init()
    }

    /// A tab for a page WebKit opens itself (`target=_blank`, `window.open`): it must use the configuration WebKit hands over.
    init(id: Int, configuration: WKWebViewConfiguration, browser: Browser) {
        self.id = id
        self.title = ""
        self.browser = browser
        super.init()
        attach(WKWebView(frame: .zero, configuration: configuration))
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host() ?? "새 탭"
    }

    @discardableResult
    func wake() -> WKWebView {
        lastShown = Date()
        if let webView { return webView }
        let view = WKWebView(frame: .zero, configuration: browser?.configuration ?? Browser.configuration)
        attach(view)
        if let savedState {
            view.interactionState = savedState as NSData
        } else if let url {
            if url.isFileURL { userFileLoad = url }
            Self.load(url, in: view)
        }
        savedState = nil
        return view
    }

    func sleep() {
        guard let webView else { return }
        savedState = webView.interactionState as? Data
        url = webView.url ?? url
        webView.stopLoading()
        webView.removeFromSuperview()
        observations.removeAll()
        audioWatcher = nil
        isPlayingAudio = false
        loginOffer = nil
        self.webView = nil
        isLoading = false
        progress = 0
    }

    /// The local file the user asked for (Open File, the address bar, a bookmark); only it and its folder may load from file:.
    private var userFileLoad: URL?

    nonisolated static func fileLoadAllowed(_ url: URL, userOpened: URL?) -> Bool {
        guard let userOpened else { return false }
        if url.standardizedFileURL == userOpened.standardizedFileURL { return true }
        let folder = userOpened.deletingLastPathComponent().standardizedFileURL.path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    func load(_ url: URL) {
        self.url = url
        if url.isFileURL { userFileLoad = url }
        Self.load(url, in: wake())
    }

    /// Local files the user opened may read their folder (for the page's own images and styles).
    static func load(_ url: URL, in view: WKWebView) {
        if url.isFileURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: url))
        }
    }

    /// What gets written to disk to restore the tab at the next launch.
    var sessionState: Data? { (webView?.interactionState as? Data) ?? savedState }

    private func attach(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.isInspectable = true
        view.underPageBackgroundColor = .clear
        view.pageZoom = Preferences.shared.zoom(for: url?.host())
        observations = [
            view.observe(\.title) { [weak self] v, _ in Task { @MainActor in if let t = v.title, !t.isEmpty { self?.title = t; self?.extensionsSeeChange() } } },
            view.observe(\.url) { [weak self] v, _ in Task { @MainActor in if let u = v.url { self?.url = u; self?.extensionsSeeChange() } } },
            view.observe(\.isLoading) { [weak self] v, _ in Task { @MainActor in self?.isLoading = v.isLoading; self?.extensionsSeeChange() } },
            view.observe(\.estimatedProgress) { [weak self] v, _ in Task { @MainActor in self?.progress = v.estimatedProgress } },
            view.observe(\.canGoBack) { [weak self] v, _ in Task { @MainActor in self?.canGoBack = v.canGoBack } },
            view.observe(\.canGoForward) { [weak self] v, _ in Task { @MainActor in self?.canGoForward = v.canGoForward } },
        ]
        webView = view
        audioWatcher = AudioWatcher(view) { [weak self] playing in
            if self?.webView != nil { self?.isPlayingAudio = playing }
        }
        if isMuted { Self.setMuted(true, in: view) }
    }

    /// Silences the tab (or lets it play again). WebKit's switch for this is private, so a WebKit without it does nothing.
    func toggleMute() {
        if let webView, !Self.setMuted(!isMuted, in: webView) { return }
        isMuted.toggle()
    }

    /// Hosts under the same registrable name, roughly: the last two labels, or three for names like example.co.kr.
    nonisolated static func sameSite(_ a: String?, _ b: String?) -> Bool {
        guard let a = a?.lowercased(), let b = b?.lowercased() else { return false }
        func site(_ host: String) -> String {
            let labels = host.split(separator: ".")
            let keep = labels.count >= 3 && labels[labels.count - 2].count <= 3 && labels.last!.count == 2 ? 3 : 2
            return labels.suffix(keep).joined(separator: ".")
        }
        return site(a) == site(b)
    }

    @discardableResult
    private static func setMuted(_ muted: Bool, in view: WKWebView) -> Bool {
        typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        let selector = NSSelectorFromString("_setPageMuted:")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return false }
        unsafeBitCast(method_getImplementation(method), to: SetMuted.self)(view, selector, muted ? 1 : 0)
        return true
    }

    /// Zooms the page; the size is remembered for the site (except in a private window).
    func setZoom(_ zoom: Double) {
        guard let webView else { return }
        let zoom = min(max(zoom, 0.3), 3)
        webView.pageZoom = zoom
        if !isPrivate, let host = webView.url?.host() { Preferences.shared.setZoom(zoom, for: host) }
    }

    private func extensionsSeeChange() {
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabChanged(self) }
    }

    private func loadFavicon() {
        guard let webView, let host = webView.url?.host() else { return }
        if let cached = Browser.favicons[host] { favicon = cached; return }
        let script = """
        (() => { const l = document.querySelector('link[rel~="icon"][sizes="32x32"], link[rel~="icon"], link[rel="apple-touch-icon"]');
          return l ? l.href : location.origin + '/favicon.ico'; })()
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let href = value as? String, let iconURL = URL(string: href), ["http", "https"].contains(iconURL.scheme ?? "") else { return }
            (self?.isPrivate == true ? Browser.ephemeral : URLSession.shared).dataTask(with: iconURL) { data, _, _ in
                guard let data, let image = NSImage(data: data), image.isValid else { return }
                Task { @MainActor in
                    Browser.favicons[host] = image
                    if self?.isPrivate == false { Browser.storeIcon(image, host: host) }
                    if self?.url?.host() == host { self?.favicon = image }
                }
            }.resume()
        }
    }
}

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if action.shouldPerformDownload { return (.download, preferences) }
        if let url = action.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "data", "blob", "file", "javascript"].contains(scheme) {
            if action.navigationType == .linkActivated { openExternally(url, scheme: scheme, from: webView.url) }
            return (.cancel, preferences)
        }
        // Local files load only as the user opened them: that file, or files in its folder (which it may read anyway).
        if let url = action.request.url, url.isFileURL {
            guard Self.fileLoadAllowed(url, userOpened: userFileLoad) else { return (.cancel, preferences) }
            // Never handed to a new tab, which would treat it as opened by the user.
            return (.allow, preferences)
        }
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) || action.buttonNumber == Self.middleButton,
           let url = action.request.url {
            browser?.openTab(url: url, activate: action.modifierFlags.contains(.shift), after: self)
            return (.cancel, preferences)
        }
        if Self.isPeekClick(action), let url = action.request.url {
            browser?.openPeek(url)
            return (.cancel, preferences)
        }
        return (Self.allowHere, preferences)
    }

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
                                              "x-man-page", "applescript", "itms-services", "facetime", "facetime-audio", "tel"]

    /// mailto:, zoommtg: and the like open their app after the user says which app and agrees.
    private func openExternally(_ url: URL, scheme: String, from page: URL?) {
        guard !Self.blockedSchemes.contains(scheme), let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        let alert = NSAlert()
        alert.messageText = "\(page?.host() ?? "이 페이지")에서 \(FileManager.default.displayName(atPath: app.path))을(를) 열려고 해요"
        alert.informativeText = String(url.absoluteString.prefix(200))
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "열기")
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.isForMainFrame && !response.canShowMIMEType ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.track(download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView.url?.isFileURL != true { userFileLoad = nil }
        // A new site gets its own zoom; staying on the same one keeps what the user set (a private tab never saves it).
        let host = webView.url?.host()
        if host != zoomHost {
            zoomHost = host
            let zoom = Preferences.shared.zoom(for: host)
            if webView.pageZoom != zoom { webView.pageZoom = zoom }
        }
        // Sign-ins often land on another host of the same site (login.example.com → www.example.com).
        if let offer = loginOffer, !Self.sameSite(offer.host, host) { loginOffer = nil }
        if let host = webView.url?.host(), let cached = Browser.favicons[host] { favicon = cached }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadFavicon()
        if !isPrivate, let url = webView.url?.absoluteString { Library.shared.recordVisit(url: url, title: webView.title ?? "") }
        checkForLogins()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled, nsError.domain != "WebKitErrorDomain" || nsError.code != 102 else { return }
        let failing = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        let message = nsError.localizedDescription.replacingOccurrences(of: "<", with: "&lt;")
        let address = (failing?.absoluteString ?? "").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        webView.loadHTMLString("""
        <meta name="color-scheme" content="light dark"><title>페이지를 열 수 없어요</title>
        <body style="font: 15px -apple-system; display: grid; place-content: center; height: 90vh; text-align: center; color: #888">
        <h2 style="color: CanvasText; font-weight: 600">페이지를 열 수 없어요</h2><p>\(message)</p><p style="font-size: 12px">\(address)</p>
        </body>
        """, baseURL: nil)
        if let failing { url = failing }
    }

    /// Sites behind HTTP authentication ask for a user name and password.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else { return (.performDefaultHandling, nil) }
        guard challenge.previousFailureCount < 3 else { return (.cancelAuthenticationChallenge, nil) }
        let alert = NSAlert()
        alert.messageText = "\(challenge.protectionSpace.host)에 로그인"
        alert.informativeText = challenge.previousFailureCount > 0 ? "아이디나 비밀번호가 맞지 않아요." : (challenge.protectionSpace.realm ?? "")
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = "아이디"
        user.stringValue = challenge.proposedCredential?.user ?? ""
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = "비밀번호"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        fields.addSubview(user)
        fields.addSubview(password)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = user
        alert.addButton(withTitle: "로그인")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if Self.isPeekClick(action), let url = action.request.url {
            browser?.openPeek(url)
            return nil
        }
        return browser?.openTab(configuration: configuration, after: self).webView
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        SitePermissions.shared.decide(host: origin.host, type: type, remember: !isPrivate)
    }

    func webViewDidClose(_ webView: WKWebView) {
        if browser?.peek === self { browser?.closePeek() } else { browser?.close(id) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
