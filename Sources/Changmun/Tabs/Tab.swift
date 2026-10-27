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
    /// Internal so the Tab+… extensions can change the crash record and the translation, reading and page-count state; anything else changes them through Tab's methods.
    /// When its page's process last went away, to stop reloading a page that keeps crashing.
    var crashes: [Date] = []
    @Published var title: String
    /// A name the user gave the tab: shown wherever the title is, in place of the page's. The page's own title is still kept
    /// (see `pageTitle`) for the history and for the AI.
    @Published var customTitle: String?
    @Published var url: URL?
    @Published var isLoading = false
    /// How many navigations have committed in this tab: a count that did not change says no page came and went in between (A to B to A).
    var navigations = 0
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
    @Published var translation = Translation.original
    /// The page looks like an article, which Reader Mode can show; and it is showing.
    @Published var isReadable = false
    @Published var isReading = false
    var translating: Task<Void, Never>?
    /// Counts the pages shown, so work begun for one page doesn't land on the next.
    var page = 0

    enum Translation {
        case original, translating, translated
    }
    @Published private(set) var isPlayingAudio = false
    @Published private(set) var isMuted = false
    /// The AI is using the tab behind the page in front (held by whatever shows the page, see PageHost): in the window, so WebKit counts
    /// it as visible and lets its media play, which nobody asked for, so it is silent there.
    private(set) var isHeldBehind = false
    private var audioWatcher: AudioWatcher?
    var zoomHost: String?
    @Published private(set) var webView: WKWebView?
    /// What the AI's tools know about this tab's frames.
    var agent = AgentState()
    /// When the page last asked for a window with a user gesture behind it, and the event of that gesture (see createWebViewWith).
    var lastGestureWindow: (at: Date, event: TimeInterval?)?
    /// A page has already asked to open an app in this load (see appLinkRequested): it doesn't get to ask again until the next page.
    var askedForAppThisLoad = false
    /// What finds, asks about and opens the app for an address like claude://: the system's, except in tests.
    var appLinks = AppLinks.system
    /// The AI is going back, forward or reloading: a page that would send a form again is not loaded.
    var agentHistoryMove = false
    /// Such a load was refused.
    var resubmitBlocked = false
    var lastShown = Date()
    /// The host that shows the page now (see PageOwner).
    var pageOwner = PageOwner()
    private var savedState: Data?
    private var observations: [NSKeyValueObservation] = []
    private(set) weak var browser: Browser?

    /// The page is a PDF document, not a web page.
    var showsPDF = false

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
        attach(PageWebView(frame: .zero, configuration: configuration))
    }

    var sortItem: TabSorter.Item {
        TabSorter.Item(id: id, title: displayTitle, host: url?.host(), opener: openerID)
    }

    /// What the page calls itself, or its host while it has no title.
    var pageTitle: String {
        if !title.isEmpty { return title }
        return url?.host() ?? String(localized: "New Tab")
    }

    /// What the user sees for the tab: the name they gave it, else the page's title.
    var displayTitle: String { customTitle ?? pageTitle }

    /// The title as the AI is told it: the page's own, with the user's name for the tab after it when there is one.
    var aiTitle: String { customTitle.map { "\(ChatStore.oneLine(pageTitle)) [the user named this tab \"\(ChatStore.oneLine($0))\"]" } ?? pageTitle }

    /// The title a bookmark or favorite made from the tab gets: the user's name for it if it has one, else the page's title (empty before it has one).
    var bookmarkTitle: String { customTitle ?? title }

    /// Names the tab, or takes the name away (empty, or only spaces) so the page's title shows again.
    func rename(to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        customTitle = name.isEmpty ? nil : String(name.prefix(Self.maxNameLength))
    }

    nonisolated static let maxNameLength = 200

    @discardableResult
    func wake() -> WKWebView {
        lastShown = Date()
        if let webView { return webView }
        let view = PageWebView(frame: .zero, configuration: browser?.configuration(for: spaceID) ?? Browser.configuration)
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
        browser?.certificatePrompter.forget(self)
        guard let webView else { return }
        savedState = webView.interactionState as? Data
        finishedState = nil
        url = webView.url ?? url
        webView.stopLoading()
        // A page in a full screen window is asked to leave it first, and let go of once it is back (WebKit puts it back in its
        // host); taken out of the window before, the full screen window would be left holding nothing.
        if let page = webView as? PageWebView, page.isAway {
            page.leaveFullscreen()
        } else {
            webView.removeFromSuperview()
        }
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
    var userFileLoad: URL?

    nonisolated static func fileLoadAllowed(_ url: URL, userOpened: URL?) -> Bool {
        guard let userOpened else { return false }
        if url.standardizedFileURL == userOpened.standardizedFileURL { return true }
        let folder = userOpened.deletingLastPathComponent().standardizedFileURL.path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    func load(_ url: URL) {
        self.url = url
        askedForAppThisLoad = false
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
    var finishedState: Data?

    private func attach(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        (view as? PageWebView)?.owner = self
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
            // WebKit moves the page into a full screen window and back; the host that shows it makes sure it is back (see PageHost.restore).
            view.observe(\.fullscreenState) { [weak self] v, _ in
                Task { @MainActor in if v.fullscreenState == .notInFullscreen, let self { self.pageOwner.host?.restore(for: self) } }
            },
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

    func loadFavicon() {
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
