import AppKit
import Combine
import WebKit

enum CommandBarMode: Equatable {
    case newTab
    case editCurrent
}

/// The find bar's text, the link under the pointer and the split's proportions.
@MainActor
final class PageOverlay: ObservableObject {
    /// The link under the pointer in a shown tab, for the status line at the bottom of the page.
    @Published var hoveredLink: String?
    /// A short message in the same place ("Address copied").
    @Published var statusMessage: String?
    @Published var findText = ""
    @Published var findMatches: Int?
    /// Bumped to put the cursor in the find bar (⌘F while it is open).
    @Published var findFocusRequest = 0
    /// The left pane's share of the width.
    @Published var splitFraction = 0.5
}

/// One window's tabs, which one is shown, and the panels around it.
@MainActor
final class Browser: ObservableObject {
    /// Every open window's browser, the one focused last first.
    private(set) static var all: [Browser] = []
    /// The window in front, which menu commands act on.
    static var current: Browser? { all.first }
    /// The window the AI and extensions work in: never a private one.
    static var recent: Browser? { all.first { !$0.isPrivate } }

    /// A private window keeps no history, session, cookies or site data once it closes, and the AI and extensions can't see it.
    let isPrivate: Bool
    let configuration: WKWebViewConfiguration
    let spaces: SpaceStore
    weak var window: NSWindow?

    /// A new window starts in the space the one in front is in, and the first window in the one used last.
    init(isPrivate: Bool = false, spaces: SpaceStore? = nil) {
        let spaces = spaces ?? .shared
        self.isPrivate = isPrivate
        self.spaces = spaces
        spaceID = isPrivate ? spaces.space(nil).id : spaces.space(Self.current.flatMap { $0.isPrivate ? nil : $0.spaceID } ?? spaces.lastActive).id
        configuration = isPrivate ? Self.makeConfiguration(store: .nonPersistent(), extensions: false) : Self.configuration
        // A space renamed or recoloured redraws what shows it.
        spacesWatch = spaces.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    private var spacesWatch: AnyCancellable?

    /// A profile space's tabs load with its own data store and everything else the same; a private window has no spaces.
    func configuration(for space: UUID) -> WKWebViewConfiguration {
        isPrivate ? configuration : Profiles.configuration(for: spaces.space(space), base: configuration)
    }

    func focused() {
        Self.all.removeAll { $0 === self }
        Self.all.insert(self, at: 0)
        reportLibraryProblem()
    }

    private static var reportedLibraries = Set<ObjectIdentifier>()

    /// Says once that bookmarks and history can't be saved, when the library couldn't be opened: until then every write to it fails silently.
    func reportLibraryProblem(_ library: Library = .shared) {
        guard !isPrivate, library.problem != nil, Self.reportedLibraries.insert(ObjectIdentifier(library)).inserted else { return }
        flashStatus(String(localized: "Couldn’t open the bookmarks and history file, so nothing new is saved in it"))
    }

    /// The window closed: its tabs give up their pages and the browser stops being one of `all`.
    func windowClosed() {
        Self.all.removeAll { $0 === self }
        sleepTimer?.invalidate()
        memoryPressure?.cancel()
        closePeek()
        for tab in tabs {
            if #available(macOS 15.4, *) { ExtensionHost.shared.tabClosed(tab) }
            tab.sleep()
        }
        if #available(macOS 15.4, *) { ExtensionHost.shared.windowClosed(self) }
        if isPrivate { Downloads.shared.forget(self) }
    }

    /// Internal so the Browser+… extensions can change the tabs, the active tab and the space; anything else changes them through Browser's methods.
    /// The tabs of every space in this window.
    @Published var tabs: [Tab] = []
    @Published var activeID: Int? {
        // Showing another tab ends a rename in progress, which belongs to the tab it was started on.
        didSet { if renamingTab != nil && renamingTab != activeID { renamingTab = nil } }
    }
    /// The space shown: the sidebar lists its tabs, favorites and folders, and new tabs open in it.
    @Published var spaceID: UUID {
        didSet { if renamingTab != nil { renamingTab = nil } }
    }
    /// Which way the last switch went (1 to a space further on), for the sidebar to slide that way.
    var spaceDirection = 1
    /// The tab each space last showed, so coming back finds it.
    var spaceSelection: [UUID: Int] = [:]
    /// A swipe over the sidebar in progress, for this window.
    var swipe = SpaceSwipe()
    /// The space's new-space sheet or edit sheet, shown over the window.
    @Published var spaceSheet: SpaceSheetMode?
    /// Opening the AI panel, the sidebar or the downloads ends focus mode, whichever way it is opened.
    @Published var showChat = false {
        didSet { if showChat { focusMode = false } }
    }
    @Published var showSidebar = UserDefaults.standard.object(forKey: "showSidebar") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showSidebar, forKey: "showSidebar")
            showDownloads = false
            if showSidebar { focusMode = false } else { renamingGroup = nil; renamingTab = nil }
        }
    }
    /// With the tabs on top there is no sidebar column: this shows the sidebar over the page, from the page bar, until a click outside it.
    @Published var showSidebarOverlay = false {
        didSet { if showSidebarOverlay { showDownloads = false } }
    }
    @Published var commandBar: CommandBarMode? {
        didSet { if commandBar != nil { closePeek() } }
    }
    @Published var showOnboarding = false
    @Published var showDownloads = false {
        didSet { if showDownloads { focusMode = false } }
    }
    /// Bumped to put the cursor in the full address field (⌘L).
    @Published var addressFocusRequest = 0
    /// Only the page, as in Dia: no sidebar, bar, AI panel or window buttons. Not kept across launches.
    /// In full screen the window buttons are gone, and so is the room kept for them.
    @Published var fullScreen = false
    @Published var focusMode = false {
        didSet {
            guard focusMode != oldValue else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window?.standardWindowButton(kind)?.isHidden = focusMode
            }
            guard focusMode else { return }
            showSidebarOverlay = false
            showDownloads = false
            renamingGroup = nil
            renamingTab = nil
            flashStatus(String(localized: "Focus mode · ⇧⌘F to exit"))
        }
    }
    static var favicons: [String: NSImage] = [:]
    /// For a private window's requests: no disk cache, no shared cookies.
    static let ephemeral = URLSession(configuration: .ephemeral)

    /// Tab ids are unique across windows: the AI's approvals remember tabs by id.
    private static var nextID = 1
    /// Internal so the Browser+… extensions can change these; anything else changes them through Browser's methods.
    /// The tab shown before the current one: closing the current tab goes back to it, as in Safari and Chrome.
    var previousActiveID: Int?
    var sleepTimer: Timer?
    var memoryPressure: DispatchSourceMemoryPressure?

    /// Most recently closed last.
    var closedTabs: [ClosedTab] = []

    @Published var findBarVisible = false

    /// What changes many times a second: kept apart so only the page area redraws, not the sidebar with it.
    let overlay = PageOverlay()

    var findText: String {
        get { overlay.findText }
        set { overlay.findText = newValue }
    }
    var findMatches: Int? {
        get { overlay.findMatches }
        set { overlay.findMatches = newValue }
    }
    var splitFraction: Double {
        get { overlay.splitFraction }
        set { overlay.splitFraction = newValue }
    }
    var hoveredLink: String? {
        get { overlay.hoveredLink }
        set { if overlay.hoveredLink != newValue { overlay.hoveredLink = newValue } }
    }

    static let configuration = makeConfiguration(store: .default(), extensions: !Headless.isOn)

    static func makeConfiguration(store: WKWebsiteDataStore, extensions: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.preferences.isElementFullscreenEnabled = true
        // WebKit then asks for every window.open, clicked or not, and Tab decides: with it off, WebKit refuses the ones nobody
        // clicked for itself, and an allowed site's window can only be opened later as a plain tab (no window.opener).
        config.preferences.javaScriptCanOpenWindowsAutomatically = Tab.knowsUserInitiated
        config.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
        config.mediaTypesRequiringUserActionForPlayback = .audio
        // Lets the Web Inspector open inside the app (F12, "Inspect Element"); private, so only when WebKit has it.
        if config.preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        // Picture in picture is off in WKWebView unless this private preference is on.
        if config.preferences.responds(to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")) {
            config.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        }
        LinkHover.install(in: config.userContentController)
        PopupWatcher.install(in: config.userContentController)
        PictureInPictureWatcher.install(in: config.userContentController)
        FrameWatcher.install(in: config.userContentController)
        PasswordWatcher.install(in: config.userContentController)
        ReaderWatcher.install(in: config.userContentController)
        if !Headless.isOn { LoginCapture.install(in: config.userContentController) }
        AdBlocker.shared.attach(config.userContentController)
        if extensions, #available(macOS 15.4, *) { config.webExtensionController = ExtensionHost.shared.controller }
        return config
    }

    /// Internal so the Browser+… extensions can change the splits and the peek; anything else changes them through Browser's methods.
    /// Each space's split, so going away and coming back finds it as it was.
    @Published var splits: [UUID: Split] = [:]

    /// A link opened with ⇧-click, floating over the page until it is closed or kept as a tab (Arc's Peek).
    @Published var peek: Tab?

    func flashStatus(_ message: String) {
        overlay.statusMessage = message
        // Long enough to read: a short word for a moment, a sentence for longer.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1.6, Double(message.count) * 0.06)) { [weak self] in
            if self?.overlay.statusMessage == message { self?.overlay.statusMessage = nil }
        }
    }

    private static var safariVersion: String {
        let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        return info?["CFBundleShortVersionString"] as? String ?? "18.0"
    }

    var active: Tab? { tabs.first { $0.id == activeID } }

    func tab(_ id: Int?) -> Tab? {
        guard let id else { return active }
        return tabs.first { $0.id == id }
    }

    /// The tabs and the peeked page.
    var openTabs: [Tab] { tabs + [peek].compactMap { $0 } }

    /// The tab (or peeked page) a web view belongs to, in any window.
    static func tab(showing webView: WKWebView) -> Tab? {
        all.lazy.compactMap { browser in browser.openTabs.first { $0.webView === webView } }.first
    }

    /// Internal so the Browser+… extensions can change the switcher, groups, notice and tidying; anything else changes them through Browser's methods.
    @Published var tabSwitcher: TabSwitcher?
    /// When sites allowed to open popups had one opened as a tab in this window, within the last minute.
    var allowedPopups: [Date] = []
    @Published var groups: [TabGroup] = []
    /// The group whose name is being typed in the sidebar; a new group starts that way.
    @Published var renamingGroup: UUID?
    /// The tab whose name is being typed in the sidebar.
    @Published var renamingTab: Int?
    @Published var notice: Notice?
    @Published var tidying = false
    @Published var lastTidy: Tidy?

    /// ⌘ held during the click that triggered this.
    static var commandClick: Bool { NSApp.currentEvent?.modifierFlags.contains(.command) == true }

    static func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }
}
