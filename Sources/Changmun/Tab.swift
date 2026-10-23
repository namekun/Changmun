import AppKit
import WebKit

/// One tab. A sleeping tab has no web view (and so no web content process); it keeps its
/// back/forward state and loads again when it is shown.
@MainActor
final class Tab: NSObject, ObservableObject, Identifiable {
    let id: Int
    /// Set when this tab belongs to a bookmark or favorite: it lives in that bookmark's place, not in the tab list.
    var bookmarkKey: String?
    /// The tab group it is in, in the sidebar's tab list.
    var groupID: UUID?
    /// The space it belongs to: its pages use that space's data store.
    var spaceID: UUID
    /// The tab it was opened from (a link, a popup): tidying keeps the two together.
    var openerID: Int?
    /// Opened outside any group: once its first page loads, it may join the group it belongs in.
    var sortsIntoGroup = false
    /// When its page's process last went away, to stop reloading a page that keeps crashing.
    private var crashes: [Date] = []
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
    /// A window the page tried to open on its own, which WebKit blocked.
    @Published var blockedPopup: URL? {
        didSet {
            guard blockedPopup == nil else { return }
            blockedPopupFrame = nil
            blockedPopupSite = nil
            blockedPopupCount = 0
        }
    }
    /// The site of the frame the blocked pop-up came from, when that was a frame in the page and not the page itself
    /// ("" for a frame with no site of its own).
    @Published var blockedPopupFrame: String?
    /// The site "Always Allow" would allow for the pop-up in the bar (nil where there is none): the origin of the page or frame
    /// that asked, as WebKit named it when it asked.
    @Published var blockedPopupSite: String?
    /// How many windows the bar stands for: the first one it shows, and the ones refused after it while it stayed up.
    @Published var blockedPopupCount = 0
    @Published var isInPictureInPicture = false {
        didSet { if isInPictureInPicture != oldValue { PictureInPictureKeys.update() } }
    }
    /// The page's language when it isn't the user's: the address bar offers to translate it.
    @Published var foreignLanguage: Locale.Language?
    @Published private(set) var translation = Translation.original
    /// The page looks like an article, which Reader Mode can show; and it is showing.
    @Published private(set) var isReadable = false
    @Published var isReading = false
    private var translating: Task<Void, Never>?
    /// Counts the pages shown, so work begun for one page doesn't land on the next.
    private var page = 0

    enum Translation {
        case original, translating, translated
    }
    @Published private(set) var isPlayingAudio = false
    @Published private(set) var isMuted = false
    /// The AI is using the tab behind the page in front (see WebViewHost.Container.keep): in the window, so WebKit counts
    /// it as visible and lets its media play, which nobody asked for, so it is silent there.
    private(set) var isHeldBehind = false
    private var audioWatcher: AudioWatcher?
    private var zoomHost: String?
    @Published private(set) var webView: WKWebView?
    /// What the AI's tools know about this tab's frames.
    var agent = AgentState()
    /// When the page last asked for a window with a user gesture behind it, and the event of that gesture (see createWebViewWith).
    private var lastGestureWindow: (at: Date, event: TimeInterval?)?
    /// The AI is going back, forward or reloading: a page that would send a form again is not loaded.
    var agentHistoryMove = false
    /// Such a load was refused.
    var resubmitBlocked = false
    var lastShown = Date()
    /// The host that shows the page now (see PageOwner).
    var pageOwner = PageOwner<WebViewHost.Container>()
    private var savedState: Data?
    private var observations: [NSKeyValueObservation] = []
    private(set) weak var browser: Browser?

    /// The page is a PDF document, not a web page.
    private(set) var showsPDF = false

    /// The folder the favorites of its space are kept in.
    var favoritesFolder: String { browser?.spaces.space(spaceID).favoritesFolder ?? Library.favoritesFolder }

    var isAsleep: Bool { webView == nil }
    var isPrivate: Bool { browser?.isPrivate == true }

    init(id: Int, url: URL?, title: String = "", state: Data? = nil, browser: Browser) {
        self.id = id
        self.url = url
        self.title = title
        self.savedState = state
        self.browser = browser
        spaceID = browser.spaceID
        super.init()
    }

    /// A tab for a page WebKit opens itself (`target=_blank`, `window.open`): it must use the configuration WebKit hands over.
    init(id: Int, configuration: WKWebViewConfiguration, browser: Browser) {
        self.id = id
        self.title = ""
        self.browser = browser
        spaceID = browser.spaceID
        super.init()
        attach(WKWebView(frame: .zero, configuration: configuration))
    }

    var sortItem: TabSorter.Item {
        TabSorter.Item(id: id, title: displayTitle, host: url?.host(), opener: openerID)
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host() ?? String(localized: "New Tab")
    }

    @discardableResult
    func wake() -> WKWebView {
        lastShown = Date()
        if let webView { return webView }
        let view = WKWebView(frame: .zero, configuration: browser?.configuration(for: spaceID) ?? Browser.configuration)
        attach(view)
        // A file the user opened is allowed to load again, also when it comes back from a saved back/forward list.
        if let url, url.isFileURL { userFileLoad = url }
        if let savedState {
            view.interactionState = savedState as NSData
        } else if let url {
            Self.load(url, in: view)
        }
        finishedState = savedState
        savedState = nil
        AgentActivity.shared.pageChanged(self)
        return view
    }

    func sleep() {
        guard let webView else { return }
        savedState = webView.interactionState as? Data
        finishedState = nil
        url = webView.url ?? url
        webView.stopLoading()
        webView.removeFromSuperview()
        observations.removeAll()
        audioWatcher = nil
        isPlayingAudio = false
        isHeldBehind = false
        loginOffer = nil
        forgetPage()
        agent.reset()
        self.webView = nil
        isLoading = false
        progress = 0
        AgentActivity.shared.pageChanged(self)
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
    /// The same as of the last page that finished loading, cheap to read.
    var lastSessionState: Data? { finishedState ?? savedState }
    private var finishedState: Data?

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
            view.observe(\.url) { [weak self] v, _ in Task { @MainActor in if let u = v.url { if self?.url != u { self?.closeReader() }; self?.url = u; self?.extensionsSeeChange() } } },
            view.observe(\.isLoading) { [weak self] v, _ in Task { @MainActor in self?.isLoading = v.isLoading; self?.extensionsSeeChange() } },
            view.observe(\.estimatedProgress) { [weak self] v, _ in Task { @MainActor in self?.progress = v.estimatedProgress } },
            view.observe(\.canGoBack) { [weak self] v, _ in Task { @MainActor in self?.canGoBack = v.canGoBack } },
            view.observe(\.canGoForward) { [weak self] v, _ in Task { @MainActor in self?.canGoForward = v.canGoForward } },
        ]
        webView = view
        audioWatcher = AudioWatcher(view) { [weak self] playing in
            if self?.webView != nil { self?.isPlayingAudio = playing }
        }
        if isMuted || isHeldBehind || Headless.isOn { Self.setMuted(true, in: view) }
        // Off screen counts as hidden, and WebKit stops drawing hidden pages.
        if Headless.isOn, view.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
            view.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        }
    }

    /// Silences the tab (or lets it play again). WebKit's switch for this is private, so a WebKit without it does nothing.
    func toggleMute() {
        if let webView, !Self.setMuted(!isMuted || isHeldBehind || Headless.isOn, in: webView) { return }
        isMuted.toggle()
    }

    /// The tab is held behind the page in front, or no longer is: it is silent while held, and sounds as the user left it after.
    func holdBehind(_ held: Bool) {
        guard held != isHeldBehind else { return }
        isHeldBehind = held
        if let webView { Self.setMuted(isMuted || held || Headless.isOn, in: webView) }
    }

    /// Hosts under the same registrable name, roughly: the last two labels, or three for names like example.co.kr.
    /// Only for the sign-in offer, where a false match costs nothing; the AI's approvals use the exact host (Approvals.site).
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

    enum PictureInPicture: String {
        case toggle, enter, exit
    }

    /// Puts the page's video in picture in picture (the playing one, else the largest), or brings it back.
    func pictureInPicture(_ mode: PictureInPicture) {
        guard let webView else { return }
        webView.appScript(Self.pictureInPictureScript, arguments: ["mode": mode.rawValue])
    }

    /// Moves the floating video (else the one playing) by `seconds`.
    func seekVideo(by seconds: Double) {
        webView?.appScript(Self.seekScript, arguments: ["by": seconds])
    }

    static let seekScript = """
    const videos = [...document.querySelectorAll('video')];
    const video = document.pictureInPictureElement || videos.find(v => v.webkitPresentationMode === 'picture-in-picture') || videos.find(v => !v.paused);
    if (video) video.currentTime = Math.max(0, Math.min(isFinite(video.duration) ? video.duration : Infinity, video.currentTime + by));
    """

    static let pictureInPictureScript = """
    const videos = [...document.querySelectorAll('video')];
    const floating = document.pictureInPictureElement || videos.find(v => v.webkitPresentationMode === 'picture-in-picture');
    const set = (video, on) => video.webkitSetPresentationMode
      ? video.webkitSetPresentationMode(on ? 'picture-in-picture' : 'inline')
      : (on ? video.requestPictureInPicture() : document.exitPictureInPicture());
    if (floating && mode !== 'enter') { set(floating, false); return 'exited'; }
    if (floating || mode === 'exit') return 'unchanged';
    const area = v => { const r = v.getBoundingClientRect(); return r.width * r.height; };
    const playing = videos.filter(v => !v.paused && v.readyState > 1).sort((a, b) => (a.muted - b.muted) || (area(b) - area(a)));
    const video = playing[0] || (mode === 'toggle' ? videos.sort((a, b) => area(b) - area(a))[0] : null);
    if (!video) return 'none';
    set(video, true);
    return 'entered';
    """

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
        // A frame that is about to show another document is no longer the one the AI's tools were told about.
        if action.targetFrame?.isMainFrame == false { agent.frameNavigated() }
        if action.navigationType == .formResubmitted, agentHistoryMove {
            resubmitBlocked = true
            return (.cancel, preferences)
        }
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
            browser?.openTab(url: url, activate: action.modifierFlags.contains(.shift), after: self).openerID = id
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
        guard !Headless.isOn, !Self.blockedSchemes.contains(scheme), let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        let alert = NSAlert()
        let site = page?.host() ?? String(localized: "This page")
        alert.messageText = String(localized: "\(site) wants to open \(FileManager.default.displayName(atPath: app.path))")
        alert.informativeText = String(url.absoluteString.prefix(200))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Open"))
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
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
        forgetPage()
        agent.reset()
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
    private func forgetPage() {
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

    // MARK: Popups

    /// A popup that was not opened: offered in a bar, or opened as a tab when the site it came from is one the user allows
    /// popups from. That site is the origin of the page (`pageSite`, as WebKit named it; the address of the tab when it
    /// isn't known) or, for a popup from a frame (`frame`), the frame's own: an ad's frame never borrows the permission of
    /// the page it sits in. An allowed site's tabs are few (`Browser.takeAllowedPopupSlot`); the ones beyond them are offered too.
    func popupBlocked(_ popup: URL, fromFrame frame: String? = nil, pageSite: String? = nil) {
        let site = (frame ?? pageSite ?? url?.host() ?? "").lowercased()
        let judged = site.isEmpty ? nil : site
        guard !isPrivate, Preferences.shared.allowsPopups(from: judged), let browser, browser.takeAllowedPopupSlot() else {
            // The bar keeps the first one until it is closed, so that a frame can't swap the address (and the site "Always
            // Allow" would allow) under a user who is about to press it; the others only add to its count.
            if blockedPopup == nil {
                blockedPopup = popup
                blockedPopupFrame = frame
                blockedPopupSite = judged
                blockedPopupCount = 1
            } else {
                blockedPopupCount += 1
            }
            return
        }
        browser.openTab(url: popup, activate: browser.isShown(self), after: self).openerID = id
    }

    /// Whether the site the bar would allow is not the one the page shows (a frame's, or the main frame's when the tab has
    /// moved on): the button then names it. It is the site that is granted that is compared, nothing else.
    var blockedPopupIsFromOtherSite: Bool {
        guard let site = blockedPopupSite else { return false }
        func bare(_ host: String?) -> String { (host ?? "").lowercased().replacingOccurrences(of: "www.", with: "", options: .anchored) }
        return bare(site) != bare(url?.host())
    }

    /// Opens the pop-up in the bar, and with `always` allows its site. `seen` is what the bar showed when the user pressed the
    /// button: if the bar has changed since (another page's, or another site's), nothing is opened or allowed on its word.
    func openBlockedPopup(always: Bool, seen: (popup: URL, site: String?)? = nil) {
        guard let popup = blockedPopup else { return }
        let site = blockedPopupSite
        if let seen, seen.popup != popup || (always && seen.site != site) { return }
        blockedPopup = nil
        if always, !isPrivate, let site { Preferences.shared.allowPopups(from: site) }
        browser?.openTab(url: popup, after: self).openerID = id
    }

    // MARK: Reader Mode

    /// Shows the page's article over it as clean text, or takes it away again.
    func toggleReader() {
        guard let webView, webView.url?.scheme?.hasPrefix("http") == true else { return }
        let page = page
        Task {
            let state = await Reader.run(.toggle, in: webView)
            guard self.page == page else { return }
            if state == .none { browser?.flashStatus(String(localized: "No article to show in Reader Mode")) }
            isReading = state == .up
        }
    }

    /// Reads from the page whether it looks like an article and whether the article is up: a page that comes back from
    /// the back/forward cache keeps its article, whatever was reset on the way.
    func checkReader() async {
        guard let webView else { return }
        let page = page
        let state = await Reader.run(.check, in: webView)
        guard self.page == page else { return }
        isReadable = state == .up || state == .readable
        isReading = state == .up
    }

    /// The address changed without a new page (a single-page site moved on): the article is no longer this page's.
    private func closeReader() {
        guard isReading, let webView else { return }
        isReading = false
        Task { _ = await Reader.run(.close, in: webView) }
    }

    // MARK: Translation

    /// Translates the page into the user's language, or puts the original back (also stopping a translation under way).
    func toggleTranslation() {
        guard let webView else { return }
        if translation != .original {
            translating?.cancel()
            translating = nil
            translation = .original
            Task { await PageTranslator.showOriginal(webView) }
            return
        }
        translation = .translating
        let page = page
        let current = { [weak self] in self?.page == page && self?.webView === webView && !Task.isCancelled }
        translating = Task {
            guard let source = await PageTranslator.foreignLanguage(of: webView) else {
                guard current() else { return }
                translating = nil
                translation = .original
                browser?.flashStatus(String(localized: "No text in another language to translate"))
                return
            }
            foreignLanguage = source
            let outcome = await PageTranslator.translate(webView, from: source, while: current)
            guard current() else { return }
            translating = nil
            translation = outcome == .translated ? .translated : .original
            switch outcome {
            case .needsDownload: browser?.flashStatus(String(localized: "Download this language in System Settings › General › Language & Region › Translation Languages"))
            case .unsupported: browser?.flashStatus(String(localized: "This language can’t be translated"))
            case .nothingToTranslate: browser?.flashStatus(String(localized: "No text in another language to translate"))
            case .failed: browser?.flashStatus(String(localized: "Couldn't translate this page"))
            case .translated: break
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled, nsError.domain != "WebKitErrorDomain" || nsError.code != 102 else { return }
        let failing = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        showError(String(localized: "Can’t open the page"), nsError.localizedDescription, address: failing, in: webView)
        if let failing { url = failing }
    }

    /// A page of our own in place of one that couldn't be shown, with a way to try again.
    private func showError(_ heading: String, _ message: String, address: URL?, in webView: WKWebView) {
        let escape = { (text: String) in
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let link = address.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? escape($0.absoluteString) : nil }
        let retry = link.map { "<a href=\"\($0)\" style=\"display: inline-block; margin-top: 16px; padding: 6px 14px; border-radius: 8px; background: rgba(128,128,128,0.16); color: CanvasText; text-decoration: none; font-weight: 600; font-size: 13px\">\(escape(String(localized: "Try Again")))</a>" } ?? ""
        webView.loadHTMLString("""
        <meta name="color-scheme" content="light dark"><title>\(escape(heading))</title>
        <body style="font: 13px -apple-system; display: grid; place-content: center; height: 90vh; text-align: center; color: #888">
        <h2 style="color: CanvasText; font-weight: 600; font-size: 17px; margin: 0 0 8px">\(escape(heading))</h2><div>\(escape(message))</div>
        <div style="font-size: 11px; margin-top: 4px">\(escape(address?.absoluteString ?? ""))</div>\(retry)
        </body>
        """, baseURL: nil)
    }

    /// Sites behind HTTP authentication ask for a user name and password.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
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

    /// The page's process went away (it crashed, or was killed for memory): load it again, but a page that keeps
    /// crashing stops after two tries, and a tab nobody is looking at just goes to sleep.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashes = crashes.filter { $0.timeIntervalSinceNow > -30 } + [Date()]
        if browser?.isShown(self) != true && browser?.peek !== self {
            sleep()
        } else if crashes.count <= 2 {
            webView.reload()
        } else {
            showError(String(localized: "This page keeps crashing"), String(localized: "Changmun stopped reloading it."), address: url, in: webView)
        }
    }
}

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // SECURITY DEPENDENCY: with javaScriptCanOpenWindowsAutomatically on, every window.open reaches this method, and all that keeps
        // a page from opening windows on its own is that `_isUserInitiated` (private, read through KVC) is false for them. If a
        // macOS release renames it, `knowsUserInitiated` goes false and the preference is turned off again (Browser.swift), so WebKit
        // refuses the unclicked windows itself. If one changes what it says, only the test that opens a window from a timer with no
        // gesture (aTimersPopupWithNoGestureIsRefused) notices, so it must keep passing.
        // The app's own scripts (the AI's tools, a login filled in...) run with a user gesture too: see AppScripts.
        let userInitiated = !AppScripts.drives(webView) && Self.isUserInitiated(action)
        if userInitiated, Self.isPeekClick(action), let url = action.request.url {
            browser?.openPeek(url)
            return nil
        }
        var activate = true
        // The user's window is the first of its gesture, so that a loop of window.open in a click opens one tab, not hundreds.
        if !userInitiated || isAnotherWindowOfTheGesture() {
            // Not the user's, or one more of the same gesture: only a site the user allowed gets a window, and only a few.
            let site = PopupWatcher.site(of: action.sourceFrame)
            guard let browser, !isPrivate, Preferences.shared.allowsPopups(from: site.isEmpty ? nil : site),
                  browser.takeAllowedPopupSlot() else { return nil }
            activate = browser.isShown(self)
        }
        let tab = browser?.openTab(configuration: configuration, after: self, activate: activate)
        tab?.openerID = id
        return tab?.webView
    }

    /// Whether the window a user-initiated `window.open` asks for follows another of the same gesture: within a second of the last
    /// one asked for (each ask renews that, so a long loop is one gesture), and with no new click or key between. Where the event
    /// can't be told (a script of the app's, a stale one), the second alone decides.
    private func isAnotherWindowOfTheGesture() -> Bool {
        let event = NSApp.currentEvent?.timestamp
        defer { lastGestureWindow = (Date(), event) }
        guard let last = lastGestureWindow, Date().timeIntervalSince(last.at) < 1 else { return false }
        return event == nil || event == last.event
    }

    /// Whether WebKit can say a window was asked for by the user (it can in this version of macOS: its navigation actions carry
    /// `_isUserInitiated`). Where it can't, windows are left to WebKit to allow or refuse, and the watcher offers the refused.
    static let knowsUserInitiated = WKNavigationAction.instancesRespond(to: NSSelectorFromString("_isUserInitiated"))

    /// A click (or a script a click started a moment ago, as WebKit counts it) is behind the action.
    private static func isUserInitiated(_ action: WKNavigationAction) -> Bool {
        guard knowsUserInitiated else { return true }
        return action.value(forKey: "_isUserInitiated") as? Bool ?? false
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        SitePermissions.shared.decide(host: origin.host, type: type, remember: !isPrivate)
    }

    /// "Back to tab" on the floating video, the only thing WebKit asks this for: its tab and window come to the front, as
    /// in Safari. WebKit holds the video until its page is on screen; if it still floats a moment later, it is let go.
    @objc(_webViewFullscreenMayReturnToInline:)
    func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        guard let browser else { return }
        if browser.peek !== self && !browser.isShown(self) { browser.activate(id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.isInPictureInPicture == true { self?.pictureInPicture(.exit) }
        }
        guard let window = browser.window else { return }
        window.makeKeyAndOrderFront(nil)
        if !Headless.isOn { NSApp.activate() }
    }

    func webViewDidClose(_ webView: WKWebView) {
        if browser?.peek === self { browser?.closePeek() } else { browser?.close(id) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        guard !Headless.isOn else { return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard !Headless.isOn else { return false }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard !Headless.isOn else { return nil }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard !Headless.isOn else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
