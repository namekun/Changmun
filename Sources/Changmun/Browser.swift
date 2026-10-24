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

    /// The tabs of every space in this window.
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeID: Int?
    /// The space shown: the sidebar lists its tabs, favorites and folders, and new tabs open in it.
    @Published private(set) var spaceID: UUID
    /// Which way the last switch went (1 to a space further on), for the sidebar to slide that way.
    private(set) var spaceDirection = 1
    /// The tab each space last showed, so coming back finds it.
    private var spaceSelection: [UUID: Int] = [:]
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
            if showSidebar { focusMode = false } else { renamingGroup = nil }
        }
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
            showDownloads = false
            renamingGroup = nil
            flashStatus(String(localized: "Focus mode · ⇧⌘F to exit"))
        }
    }
    static var favicons: [String: NSImage] = [:]
    /// For a private window's requests: no disk cache, no shared cookies.
    static let ephemeral = URLSession(configuration: .ephemeral)
    /// Hosts whose icon couldn't be found, and when: asked again after an hour, not on every row.
    private static var missingIcons: [String: Date] = [:]
    /// Icons being fetched, so rows showing the same site wait for one request.
    private static var iconLoads: [String: Task<NSImage?, Never>] = [:]
    /// Tab ids are unique across windows: the AI's approvals remember tabs by id.
    private static var nextID = 1
    /// The tab shown before the current one: closing the current tab goes back to it, as in Safari and Chrome.
    private(set) var previousActiveID: Int?
    private var sleepTimer: Timer?
    private var memoryPressure: DispatchSourceMemoryPressure?

    /// Background tabs not shown for this long give up their web process; nil when that is turned off.
    var sleepAfter: TimeInterval? {
        let minutes = Preferences.shared.sleepMinutes
        return minutes > 0 ? Double(minutes) * 60 : nil
    }

    struct ClosedTab {
        let id = UUID()
        var url: URL?
        var title: String
        var state: Data?
        var index: Int
        var bookmarkKey: String?
        var group: TabGroup?
        var space: UUID
    }

    /// Most recently closed last.
    private(set) var closedTabs: [ClosedTab] = []

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

    /// Two tabs side by side. It shows while either of them is the active tab; showing another tab hides it, and
    /// closing either one ends it.
    struct Split: Equatable {
        var left: Int
        var right: Int
        func contains(_ id: Int?) -> Bool { id == left || id == right }
    }

    /// Each space's split, so going away and coming back finds it as it was.
    @Published private var splits: [UUID: Split] = [:]
    var split: Split? { splits[spaceID] }

    /// The halves of a split that ends were on screen until now.
    private func setSplit(_ new: Split?, in space: UUID) {
        let old = splits[space]
        splits[space] = new
        for id in [old?.left, old?.right].compactMap({ $0 }) where new?.contains(id) != true { tab(id)?.lastShown = Date() }
    }
    var shownSplit: Split? { split?.contains(activeID) == true ? split : nil }

    /// A link opened with ⇧-click, floating over the page until it is closed or kept as a tab (Arc's Peek).
    @Published private(set) var peek: Tab?

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

    // MARK: Tabs

    @discardableResult
    func openTab(url: URL?, activate: Bool = true, after: Tab? = nil, space: UUID? = nil) -> Tab {
        let tab = Tab(id: Self.takeID(), url: url, browser: self)
        if let space, spaces.contains(space) { tab.spaceID = space }
        insert(tab, after: after)
        tab.sortsIntoGroup = tab.groupID == nil
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabOpened(tab) }
        if activate {
            self.activate(tab.id)
            commandBar = nil
        }
        return tab
    }

    func openTab(configuration: WKWebViewConfiguration, after: Tab?, activate: Bool = true) -> Tab {
        let tab = Tab(id: Self.takeID(), configuration: configuration, browser: self)
        if let after { tab.spaceID = after.spaceID }
        insert(tab, after: after)
        tab.sortsIntoGroup = tab.groupID == nil
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabOpened(tab) }
        if activate { self.activate(tab.id) }
        return tab
    }

    func activate(_ id: Int) {
        guard let tab = tab(id) else { return }
        hoveredLink = nil
        if id != activeID && findBarVisible { hideFindBar() }
        let previous = active
        // A tab of another space brings its space along.
        if tab.spaceID != spaceID && !isPrivate { enter(tab.spaceID) }
        if let previous, previous !== tab {
            previousActiveID = previous.spaceID == tab.spaceID ? previous.id : nil
            // Like Arc: a video playing in the tab being left keeps playing in picture in picture, until it is shown again
            // (not when the two halves of a split trade places, as both stay on screen).
            let staysOnScreen = split?.contains(previous.id) == true && split?.contains(id) == true
            if Preferences.shared.autoPictureInPicture && previous.isPlayingAudio && !staysOnScreen {
                previous.pictureInPicture(.enter)
            }
        }
        // Also after closing a tab, when there is no previous tab left to compare with.
        if previous !== tab { tab.pictureInPicture(.exit) }
        for shown in tabs where isShown(shown) { shown.lastShown = Date() }
        activeID = id
        spaceSelection[tab.spaceID] = id
        closePeek()
        tab.lastShown = Date()
        tab.wake()
        if let split = shownSplit {
            for half in [split.left, split.right] { self.tab(half)?.wake() }
        }
        if #available(macOS 15.4, *), previous !== tab { ExtensionHost.shared.tabActivated(tab, previous: previous) }
    }

    /// Whether the tab is on screen: the active one, or the other half of the split.
    func isShown(_ tab: Tab) -> Bool { tab.id == activeID || shownSplit?.contains(tab.id) == true }

    // MARK: Spaces

    /// The tab a space shows when it is switched to: the one it showed last, else its first listed tab.
    private func switchTarget(in space: UUID) -> Tab? {
        if let remembered = spaceSelection[space], let tab = tab(remembered), tab.spaceID == space { return tab }
        return tabs.first { $0.spaceID == space && $0.bookmarkKey == nil } ?? tabs.first { $0.spaceID == space }
    }

    /// Makes `id` the space shown; the caller shows a tab of it.
    private func enter(_ id: UUID) {
        let order = spaces.spaces.map(\.id)
        spaceDirection = (order.firstIndex(of: id) ?? 0) >= (order.firstIndex(of: spaceID) ?? 0) ? 1 : -1
        spaceID = id
        previousActiveID = nil
        spaces.rememberActive(id)
    }

    /// `opensBar` false (a swipe) leaves an empty space empty, with no bar taking the keyboard.
    func switchSpace(to id: UUID, opensBar: Bool = true) {
        guard !isPrivate, id != spaceID, spaces.contains(id) else { return }
        commandBar = nil
        if let target = switchTarget(in: id) { return activate(target.id) }
        // A space with no tabs shows nothing but the bar to open one.
        for shown in tabs where isShown(shown) { shown.lastShown = Date() }
        if findBarVisible { hideFindBar() }
        closePeek()
        hoveredLink = nil
        enter(id)
        activeID = nil
        if opensBar { commandBar = .newTab }
    }

    /// The next space (1) or the one before (-1), going round unless `wraps` is false (a swipe stops at the ends).
    func switchSpace(offset: Int, wraps: Bool = true, opensBar: Bool = true) {
        let order = spaces.spaces
        guard order.count > 1, let at = order.firstIndex(where: { $0.id == spaceID }) else { return }
        let to = at + offset
        guard wraps || order.indices.contains(to) else { return }
        switchSpace(to: order[(to + order.count) % order.count].id, opensBar: opensBar)
    }

    /// ⌃1 to ⌃9; 9 is the last, as with tabs.
    func switchSpace(number: Int) {
        let order = spaces.spaces
        switchSpace(to: order[number >= 9 ? order.count - 1 : min(number - 1, order.count - 1)].id)
    }

    /// Takes a space away with its tabs, in this window and every other; a profile's cookies and site data go with it.
    /// Its favorites move to the first space left, in one change, so they are still somewhere to be found.
    static func deleteSpace(_ id: UUID, from store: SpaceStore? = nil, library: Library = .shared) {
        let store = store ?? .shared
        guard let next = store.neighbour(afterRemoving: id), let removed = store.remove(id) else { return }
        if let target = store.spaces.first { library.moveFavorites(from: removed.favoritesFolder, to: target.favoritesFolder) }
        for browser in all where browser.spaces === store { browser.spaceRemoved(id, to: next) }
        if removed.isProfile { Profiles.startDraining(store) }
    }

    /// `next` is where a window that was in the space goes. A private window has no spaces of its own: it only keeps a valid one.
    private func spaceRemoved(_ id: UUID, to next: UUID) {
        guard !isPrivate else {
            for tab in tabs where tab.spaceID == id { tab.spaceID = next }
            if spaceID == id { spaceID = next }
            return
        }
        if spaceID == id { switchSpace(to: next) }
        for tab in tabs where tab.spaceID == id { close(tab.id, remember: false) }
        spaceSelection[id] = nil
        splits[id] = nil
        closedTabs.removeAll { $0.space == id }
        if spaceID == id { spaceID = next }
    }

    /// Whether the AI may see the tab: not a private window's, and not a profile's other than the one the window shows,
    /// whose logins are kept apart on purpose.
    func isVisibleToAI(_ tab: Tab) -> Bool {
        !isPrivate && (tab.spaceID == spaceID || !spaces.space(tab.spaceID).isProfile)
    }

    // MARK: Split view

    /// Shows `id` to the right of the active tab.
    func split(with id: Int) {
        guard let activeID, id != activeID, tab(id)?.spaceID == spaceID else { return }
        setSplit(Split(left: activeID, right: id), in: spaceID)
        splitFraction = 0.5
        tab(id)?.wake()
    }

    func unsplit() { setSplit(nil, in: spaceID) }

    nonisolated static func clampedSplitFraction(_ fraction: Double) -> Double { min(max(fraction, 0.2), 0.8) }

    /// The split for the menu command: the active tab and the one shown before it.
    func toggleSplit() {
        if shownSplit != nil { return unsplit() }
        guard let back = previousActiveID, tab(back) != nil else { return NSSound.beep() }
        split(with: back)
    }

    // MARK: Peek

    func openPeek(_ url: URL) {
        // A peek opened from the old one's own delegate call (⇧-click in it) can't put it to sleep within that call.
        let old = peek
        let tab = Tab(id: Self.takeID(), url: url, browser: self)
        peek = tab
        tab.wake()
        DispatchQueue.main.async { old?.sleep() }
    }

    func closePeek() {
        peek?.sleep()
        peek = nil
    }

    /// Keeps the peeked page as a tab after the shown one, as it is now (not loaded again).
    func keepPeek() {
        guard let tab = peek else { return }
        peek = nil
        insert(tab, after: active)
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabOpened(tab) }
        activate(tab.id)
    }

    /// `remember` false (an archived tab) leaves it out of the tabs ⌘⇧T brings back.
    func close(_ id: Int, remember: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs.remove(at: index)
        for (space, shared) in splits where shared.contains(id) { setSplit(nil, in: space) }
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabClosed(closing) }
        if remember {
            closedTabs.append(ClosedTab(url: closing.url, title: closing.title, state: closing.sessionState, index: index, bookmarkKey: closing.bookmarkKey,
                                        group: groups.first { $0.id == closing.groupID }, space: closing.spaceID))
            if closedTabs.count > 100 { closedTabs.removeFirst() }
        }
        closing.sleep()
        pruneGroups()
        if spaceSelection[closing.spaceID] == id { spaceSelection[closing.spaceID] = nil }
        if activeID == id {
            let here = spaceTabs
            if here.isEmpty {
                activeID = nil
                commandBar = .newTab
            } else if let back = previousActiveID, here.contains(where: { $0.id == back }) {
                activate(back)
            } else {
                let listed = listedTabs
                let before = tabs.prefix(index).filter { $0.spaceID == closing.spaceID }.count
                activate(listed.isEmpty ? here[min(before, here.count - 1)].id : listed[min(listed.count - 1, max(0, listedIndex(before: index, in: closing.spaceID)))].id)
            }
        }
    }

    /// Brings back the last closed tab where it was, with its back/forward history.
    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        reopen(closed)
    }

    /// Brings back one particular closed tab (the AI panel offers it for the tabs the AI closed); false when it is no longer among them.
    @discardableResult
    func reopenClosedTab(id: UUID) -> Bool {
        guard let index = closedTabs.firstIndex(where: { $0.id == id }) else { return false }
        reopen(closedTabs.remove(at: index))
        return true
    }

    private func reopen(_ closed: ClosedTab) {
        let tab = Tab(id: Self.takeID(), url: closed.url, title: closed.title, state: closed.state, browser: self)
        if spaces.contains(closed.space) { tab.spaceID = closed.space }
        if let key = closed.bookmarkKey, Self.keeps(key, in: spaces.space(tab.spaceID)),
           !tabs.contains(where: { $0.spaceID == tab.spaceID && $0.bookmarkKey == key }) { tab.bookmarkKey = key }
        tabs.insert(tab, at: min(closed.index, tabs.count))
        // Back into its group, made again if it went away with its last tab.
        if let group = closed.group, tab.bookmarkKey == nil {
            if !groups.contains(where: { $0.id == group.id }) { groups.append(group) }
            join(tab, group.id)
        }
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabOpened(tab) }
        activate(tab.id)
        commandBar = nil
    }

    /// Moves a tab to just above another one (dropping it on that tab, where the drop line shows), or to the end.
    func moveTab(_ id: Int, to target: Int?) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), id != target else { return }
        let tab = tabs.remove(at: from)
        let to: Int
        if let target, let above = tabs.firstIndex(where: { $0.id == target }) { to = above } else { to = tabs.count }
        tabs.insert(tab, at: to)
        if to != from, #available(macOS 15.4, *) { ExtensionHost.shared.tabMoved(tab, from: from) }
    }

    // MARK: Find in page

    func showFindBar() {
        guard active != nil else { return }
        findBarVisible = true
        overlay.findFocusRequest += 1
    }

    func hideFindBar() {
        findBarVisible = false
        findMatches = nil
        active?.webView?.evaluateJavaScript("window.getSelection().removeAllRanges()")
    }

    func find(backwards: Bool = false) {
        guard let webView = active?.webView, !findText.isEmpty else {
            findMatches = nil
            return
        }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        webView.find(findText, configuration: config) { _ in }
        let query = findText
        webView.callAsyncJavaScript("""
            const text = document.body ? document.body.innerText.toLowerCase() : '';
            const needle = query.toLowerCase();
            let count = 0, at = text.indexOf(needle);
            while (at !== -1 && count < 9999) { count++; at = text.indexOf(needle, at + needle.length); }
            return count;
            """, arguments: ["query": query], in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.findText == query else { return }
            self.findMatches = (try? result.get()) as? Int
        }
    }

    func selectTab(offset: Int) {
        let listed = visibleTabs
        guard !listed.isEmpty else { return }
        guard let current = listed.firstIndex(where: { $0.id == activeID }) else { return activate(listed[0].id) }
        activate(listed[(current + offset + listed.count) % listed.count].id)
    }

    func selectTab(number: Int) {
        let listed = visibleTabs
        guard !listed.isEmpty else { return }
        activate(number >= 9 ? listed[listed.count - 1].id : listed[min(number - 1, listed.count - 1)].id)
    }

    /// How many listed tabs of the space came before position `index` in `tabs` (after a tab there was removed).
    private func listedIndex(before index: Int, in space: UUID) -> Int {
        tabs.prefix(index).filter { $0.spaceID == space && $0.bookmarkKey == nil }.count - 1
            + (tabs.indices.contains(index) && tabs[index].spaceID == space && tabs[index].bookmarkKey == nil ? 1 : 0)
    }

    func open(_ input: String, in mode: CommandBarMode) {
        guard let url = AddressInput.resolve(input) else { return }
        if mode == .editCurrent, let active { active.load(url) } else { openTab(url: url) }
        commandBar = nil
    }

    static func bookmarkKey(url: String, folder: String) -> String { folder + "\n" + url }

    /// Whether a tab of this space may keep the bookmark key. A favorite's key belongs to its own space: a tab whose space
    /// couldn't be found would otherwise be bound to a favorite it can't show, and be out of sight. Imported folders are shared.
    static func keeps(_ key: String, in space: Space) -> Bool {
        let folder = String(key.prefix { $0 != "\n" })
        return !Library.isFavorites(folder) || folder == space.favoritesFolder
    }

    var space: Space { spaces.space(spaceID) }
    var favoritesFolder: String { space.favoritesFolder }

    /// The tabs of the space shown.
    var spaceTabs: [Tab] { tabs.filter { $0.spaceID == spaceID } }

    /// Tabs shown in the sidebar's tab list; bookmark tabs show in their bookmark's place instead.
    var listedTabs: [Tab] { spaceTabs.filter { $0.bookmarkKey == nil } }

    func bookmarkTab(_ key: String) -> Tab? { spaceTabs.first { $0.bookmarkKey == key } }

    /// A bookmark is its own tab, as in Dia and Arc: the first click opens it in its place, later clicks switch back
    /// to it (wherever it has navigated since). ⌘-click opens the page in an ordinary new tab instead.
    func openBookmark(_ address: String, key: String?, inNewTab: Bool = false) {
        guard let url = URL(string: address) else { return }
        if inNewTab {
            openTab(url: url, after: active)
            return
        }
        guard let key else {
            if let open = spaceTabs.first(where: { $0.url?.absoluteString == address }) { activate(open.id) } else { openTab(url: url, after: active) }
            return
        }
        activate(bookmarkTab(opening: url, key: key).id)
        commandBar = nil
    }

    /// The bookmark's tab, opened in its place (and not shown) if it isn't open yet.
    private func bookmarkTab(opening url: URL, key: String) -> Tab {
        if let open = bookmarkTab(key) { return open }
        let tab = Tab(id: Self.takeID(), url: url, browser: self)
        tab.bookmarkKey = key
        tabs.append(tab)
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabOpened(tab) }
        return tab
    }

    /// Shows a bookmark's tab to the right of the active tab, opening it first if needed.
    func split(withBookmark address: String, key: String) {
        guard activeID != nil, let url = URL(string: address) else { return }
        split(with: bookmarkTab(opening: url, key: key).id)
    }

    /// A tab whose bookmark was deleted moves into the tab list rather than closing.
    func releaseBookmarkTabs(keeping keys: Set<String>) {
        for tab in tabs where tab.bookmarkKey.map({ !keys.contains($0) }) == true { tab.bookmarkKey = nil }
        objectWillChange.send()
    }

    /// Moves a bookmark to another folder; its tab, in any window, goes with it.
    static func moveBookmark(url: String, from: String, to: String) {
        guard Library.shared.moveBookmark(url: url, from: from, to: to) else { return }
        let old = bookmarkKey(url: url, folder: from), new = bookmarkKey(url: url, folder: to)
        for browser in all {
            for tab in browser.tabs where tab.bookmarkKey == old && !browser.tabs.contains(where: { $0.spaceID == tab.spaceID && $0.bookmarkKey == new }) {
                tab.bookmarkKey = new
                browser.objectWillChange.send()
            }
        }
    }

    /// Turns an open tab into a bookmark's tab (pinning it).
    func bind(_ tab: Tab, to key: String) {
        guard bookmarkTab(key) == nil else { return }
        tab.bookmarkKey = key
        tab.groupID = nil
        pruneGroups()
        objectWillChange.send()
    }

    // MARK: Recent tabs

    /// ⌃Tab's switcher: the tabs, most recently shown first, and the one picked so far.
    struct TabSwitcher: Equatable {
        var order: [Int]
        var index: Int
    }

    @Published private(set) var tabSwitcher: TabSwitcher?
    /// When sites allowed to open popups had one opened as a tab in this window, within the last minute.
    var allowedPopups: [Date] = []
    /// Most pop-ups the allowed sites get in a minute, and the least time between two: a page can ask for any number.
    static let allowedPopupsPerMinute = 5, allowedPopupGap = 1.0

    /// Whether an allowed site's pop-up may open now (at most one a second, and so many a minute), counting it if so.
    func takeAllowedPopupSlot() -> Bool {
        let now = Date()
        allowedPopups = allowedPopups.filter { now.timeIntervalSince($0) < 60 }
        guard allowedPopups.count < Self.allowedPopupsPerMinute, allowedPopups.last.map({ now.timeIntervalSince($0) > Self.allowedPopupGap }) ?? true else { return false }
        allowedPopups.append(now)
        return true
    }

    /// The shown tab first, then the others by when they were last shown.
    var recentTabs: [Tab] {
        spaceTabs.enumerated().sorted { a, b in
            if (a.element.id == activeID) != (b.element.id == activeID) { return a.element.id == activeID }
            if a.element.lastShown != b.element.lastShown { return a.element.lastShown > b.element.lastShown }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Opens the switcher on the tab shown before this one, or moves along it.
    func cycleRecentTabs(backwards: Bool = false) {
        guard commandBar == nil else { return }
        if var switcher = tabSwitcher {
            switcher.index = (switcher.index + (backwards ? -1 : 1) + switcher.order.count) % switcher.order.count
            tabSwitcher = switcher
            return
        }
        let order = recentTabs.map(\.id)
        guard order.count > 1 else { return }
        tabSwitcher = TabSwitcher(order: order, index: backwards ? order.count - 1 : 1)
    }

    /// Goes to the picked tab, or to the next one still open after it if it closed meanwhile.
    func finishSwitching(to id: Int? = nil) {
        guard let switcher = tabSwitcher else { return }
        tabSwitcher = nil
        let open = (switcher.order[switcher.index...] + switcher.order[..<switcher.index]).first { tab($0) != nil }
        if let pick = id ?? open { activate(pick) }
    }

    func cancelSwitching() { tabSwitcher = nil }

    // MARK: Tab groups

    struct TabGroup: Identifiable, Codable, Equatable {
        var id = UUID()
        var name: String
        var isOpen = true
    }

    @Published private(set) var groups: [TabGroup] = []
    /// The groups of the space shown (a group's tabs are all in one space).
    var spaceGroups: [TabGroup] { groups(in: spaceID) }

    func groups(in space: UUID) -> [TabGroup] {
        let used = Set(tabs.filter { $0.spaceID == space }.compactMap(\.groupID))
        return groups.filter { used.contains($0.id) }
    }
    /// The group whose name is being typed in the sidebar; a new group starts that way.
    @Published var renamingGroup: UUID?

    enum ListedItem: Identifiable {
        case tab(Tab)
        case group(TabGroup, [Tab])

        var id: String {
            switch self {
            case .tab(let tab): "tab \(tab.id)"
            case .group(let group, _): "group \(group.id)"
            }
        }
    }

    /// The tab list as the sidebar shows it: each group in the place of its first tab, holding all of its tabs.
    var listing: [ListedItem] {
        let listed = listedTabs
        var items: [ListedItem] = []
        var placed = Set<UUID>()
        for tab in listed {
            guard let id = tab.groupID, let group = groups.first(where: { $0.id == id }) else {
                items.append(.tab(tab))
                continue
            }
            if placed.insert(id).inserted { items.append(.group(group, listed.filter { $0.groupID == id })) }
        }
        return items
    }

    /// The listed tabs in the order shown, less those folded away in a closed group (the shown tab stays out).
    var visibleTabs: [Tab] {
        listing.flatMap { item -> [Tab] in
            switch item {
            case .tab(let tab): [tab]
            case .group(let group, let tabs): shown(tabs, in: group)
            }
        }
    }

    /// A group's tabs on show: all of them while it is open, only the shown tab while it is folded.
    func shown(_ tabs: [Tab], in group: TabGroup) -> [Tab] {
        group.isOpen ? tabs : tabs.filter { $0.id == activeID }
    }

    /// Puts the tabs in a new group, gathered after the first of them, and starts naming it.
    @discardableResult
    func group(_ ids: [Int], name: String = String(localized: "New Group")) -> UUID? {
        let members = tabs.filter { ids.contains($0.id) && $0.bookmarkKey == nil }
        guard !members.isEmpty else { return nil }
        let group = TabGroup(name: name)
        groups.append(group)
        for tab in members { join(tab, group.id) }
        pruneGroups()
        renamingGroup = group.id
        return group.id
    }

    func addTab(_ id: Int, to group: UUID) {
        guard let tab = tab(id), tab.bookmarkKey == nil, groups.contains(where: { $0.id == group }) else { return }
        join(tab, group)
        pruneGroups()
    }

    /// Takes a tab out of its group; it goes right after the group.
    func removeFromGroup(_ id: Int) {
        guard let tab = tab(id), let group = tab.groupID else { return }
        if let last = tabs.last(where: { $0.groupID == group }), last !== tab { place(tab, after: last) }
        tab.groupID = nil
        pruneGroups()
        objectWillChange.send()
    }

    /// A tab dropped on another moves just above it and joins that tab's group, or leaves its own. Tabs of
    /// another space stay where they are.
    func dropTab(_ id: Int, on target: Int) {
        guard let tab = tab(id), let other = self.tab(target), tab.spaceID == other.spaceID else { return }
        moveTab(id, to: target)
        tab.groupID = other.groupID
        pruneGroups()
        objectWillChange.send()
    }

    /// Moves a group, all its tabs together, to just above a tab (above that tab's group when it is in one), or to
    /// the end. The tabs keep their order, and the group stays open or folded as it was. Dropped on a tab of its own
    /// or of another space, it stays.
    func moveGroup(_ id: UUID, before target: Int?) {
        let members = tabs.filter { $0.groupID == id }
        guard let space = members.first?.spaceID else { return }
        var anchor: Tab?
        if let target {
            guard let tab = tab(target), tab.spaceID == space, tab.groupID != id else { return }
            anchor = tab.groupID.flatMap { other in tabs.first { $0.groupID == other } } ?? tab
        }
        let was = tabs.map(\.id)
        tabs.removeAll { $0.groupID == id }
        tabs.insert(contentsOf: members, at: anchor.flatMap { anchor in tabs.firstIndex { $0 === anchor } } ?? tabs.count)
        guard #available(macOS 15.4, *) else { return }
        for tab in members {
            if let from = was.firstIndex(of: tab.id), tabs.firstIndex(where: { $0 === tab }) != from { ExtensionHost.shared.tabMoved(tab, from: from) }
        }
    }

    /// A group dropped on another group's header goes just above that group.
    func dropGroup(_ id: UUID, onGroup target: UUID) {
        guard let first = tabs.first(where: { $0.groupID == target }) else { return }
        moveGroup(id, before: first.id)
    }

    func toggleGroup(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].isOpen.toggle()
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name
    }

    /// Ends the group; its tabs stay where they are.
    func ungroup(_ id: UUID) {
        for tab in tabs where tab.groupID == id { tab.groupID = nil }
        pruneGroups()
    }

    /// Closes the group's tabs, first moving off them so none is woken just to be closed.
    func closeGroup(_ id: UUID) {
        if active?.groupID == id,
           let outside = tabs.first(where: { $0.id == previousActiveID && $0.groupID != id }) ?? listedTabs.first(where: { $0.groupID != id }) {
            activate(outside.id)
        }
        let closing = tabs.filter { $0.groupID == id }
        for tab in closing { close(tab.id) }
        let count = closing.count, top = closedTabs.last?.id
        offerUndo(count == 1 ? String(localized: "Closed \(count) tab") : String(localized: "Closed \(count) tabs")) { [weak self] in
            // Only while they are still the last ones closed; ⌘⇧T is there for the rest.
            guard let self, top != nil, closedTabs.last?.id == top else { return }
            for _ in 0..<min(count, closedTabs.count) { reopenClosedTab() }
        }
    }

    /// Where a group dragged up onto the bookmarks goes: a new folder pinned to the sidebar (above the pinned folder
    /// `before`, or last), or a new folder inside a bookmark folder. Either way the group stays together.
    enum GroupDestination: Equatable {
        case pinned(before: String?)
        case folder(String)
    }

    /// Keeps a group's pages as bookmarks and ends the group. Its tabs become those bookmarks' tabs, so nothing
    /// reloads; a tab with no web page, or on a page already open as a bookmark, stays a plain tab. Offers to undo it.
    @discardableResult
    func saveGroup(_ id: UUID, to destination: GroupDestination, library: Library = .shared) -> Bool {
        guard let group = groups.first(where: { $0.id == id }) else { return false }
        let members = tabs.filter { $0.groupID == id && $0.spaceID == spaceID }
        var seen = Set<String>()
        let pages = members.compactMap { tab -> (tab: Tab, url: String)? in
            guard let url = tab.url, ["http", "https"].contains(url.scheme?.lowercased()), seen.insert(url.absoluteString).inserted else { return nil }
            return (tab, url.absoluteString)
        }
        guard !pages.isEmpty else {
            flashStatus(String(localized: "The group has no pages to save"))
            return false
        }
        let space = spaceID
        let folder: String
        switch destination {
        case .pinned: folder = newFolderKey(for: group.name, in: nil, library)
        case .folder(let parent): folder = newFolderKey(for: group.name, in: parent, library)
        }
        let added = pages.filter { !library.isFavorite($0.url, in: folder) }
        for page in added { library.addBookmark(url: page.url, title: page.tab.title.isEmpty ? (page.tab.url?.host() ?? page.url) : page.tab.title, folder: folder) }
        var bound: [Int: String] = [:]
        for page in pages {
            let key = Self.bookmarkKey(url: page.url, folder: folder)
            bind(page.tab, to: key)
            if page.tab.bookmarkKey == key { bound[page.tab.id] = key }
        }
        ungroup(id)
        var pinned = false, opened: String?
        switch destination {
        case .pinned(let before):
            pinned = !spaces.space(space).pinnedFolders.contains(folder)
            spaces.pinFolder(folder, before: before, in: space)
            if group.isOpen, !spaces.space(space).openFolders.contains("pin:" + folder) { opened = "pin:" + folder }
        case .folder(let parent):
            if !spaces.space(space).openFolders.contains("pin:" + parent) { opened = "pin:" + parent }
        }
        if let opened { spaces.toggleOpen(opened, in: space) }
        offerUndo(String(localized: "Saved the group as a bookmark folder")) { [weak self] in
            // Only what the save did: the bookmarks it added (not what was put in the folder since), and the pin and
            // the opening it made.
            for page in added { library.removeBookmark(url: page.url, folder: folder) }
            if let spaces = self?.spaces {
                if pinned { spaces.unpinFolder(folder, in: space) }
                if let opened, spaces.space(space).openFolders.contains(opened) { spaces.toggleOpen(opened, in: space) }
            }
            guard let self else { return }
            if !groups.contains(where: { $0.id == group.id }) { groups.append(group) }
            for member in members where tabs.contains(where: { $0 === member }) {
                if let key = bound[member.id], member.bookmarkKey == key { member.bookmarkKey = nil }
                if member.bookmarkKey == nil { member.groupID = group.id }
            }
            objectWillChange.send()
        }
        return true
    }

    /// The name of a folder made for a group: under "Changmun", the way imported folders are under their browser's
    /// name, or inside another folder; numbered when a folder has that name already.
    private func newFolderKey(for name: String, in parent: String?, _ library: Library) -> String {
        let name = name.replacingOccurrences(of: " / ", with: " - ")
        let base = parent.map { $0 + " / " + name } ?? "Changmun " + name
        let names = library.folders().map(\.name)
        // Taken as a folder, or as the parent of one: a folder that only exists as part of a deeper path is not free.
        func isTaken(_ key: String) -> Bool { names.contains { $0 == key || $0.hasPrefix(key + " / ") } }
        var key = base, number = 2
        while isTaken(key) {
            key = base + " \(number)"
            number += 1
        }
        return key
    }

    /// A second tab on the same page, right after it, in its group.
    @discardableResult
    func duplicate(_ id: Int) -> Tab? {
        guard let tab = tab(id), let url = tab.url else { return nil }
        let copy = openTab(url: url, activate: false, after: tab)
        if let group = tab.groupID, tab.bookmarkKey == nil { join(copy, group) }
        return copy
    }

    /// Takes a tab out into a window of its own, keeping its back and forward history.
    func moveToNewWindow(_ id: Int) {
        guard let tab = tab(id) else { return }
        let saved = SavedSession(tabs: [SavedTab(url: tab.url?.absoluteString, title: tab.title, state: tab.sessionState, space: tab.spaceID)], active: 0, space: tab.spaceID)
        close(id, remember: false)
        BrowserWindow.open(private: isPrivate, restoring: saved)
    }

    /// Something just done that can be taken back, under the new tab row for a few seconds.
    struct Notice: Equatable {
        let id = UUID()
        let message: String
        let undo: () -> Void
        static func == (a: Notice, b: Notice) -> Bool { a.id == b.id }
    }

    @Published private(set) var notice: Notice?

    func offerUndo(_ message: String, undo: @escaping () -> Void) {
        let notice = Notice(message: message, undo: undo)
        self.notice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.notice == notice { self?.notice = nil }
        }
    }

    func undoNotice() {
        guard let notice else { return }
        self.notice = nil
        notice.undo()
    }

    /// Joins a tab to a group after the group's last tab, so a group's tabs stay together.
    private func join(_ tab: Tab, _ group: UUID) {
        if let last = tabs.last(where: { $0.groupID == group && $0 !== tab }) { place(tab, after: last) }
        tab.groupID = group
        objectWillChange.send()
    }

    private func place(_ tab: Tab, after other: Tab) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: from)
        guard let to = tabs.firstIndex(where: { $0 === other }) else { return tabs.insert(tab, at: from) }
        tabs.insert(tab, at: to + 1)
        if to + 1 != from, #available(macOS 15.4, *) { ExtensionHost.shared.tabMoved(tab, from: from) }
    }

    /// Groups left without tabs go away, and tabs forget groups that are gone.
    private func pruneGroups() {
        let known = Set(groups.map(\.id))
        for tab in tabs where tab.groupID.map({ !known.contains($0) }) == true { tab.groupID = nil }
        let used = Set(tabs.compactMap { $0.bookmarkKey == nil ? $0.groupID : nil })
        if groups.contains(where: { !used.contains($0.id) }) { groups.removeAll { !used.contains($0.id) } }
        if let renaming = renamingGroup, !used.contains(renaming) { renamingGroup = nil }
    }

    // MARK: Tidying

    /// What the last tidy did, so it can be taken back: the groups it made and the tabs it put into groups already there.
    struct Tidy: Equatable {
        var id = UUID()
        var made: [UUID]
        /// Each tab it put in a group, and the group.
        var placed: [Int: UUID]
        var tabs: Int { placed.count }
    }

    @Published private(set) var tidying = false
    @Published private(set) var lastTidy: Tidy?

    /// The tabs a tidy sorts: those in no group (favorites and bookmarks live in their own places).
    var looseTabs: [Tab] { spaceTabs.filter { $0.groupID == nil && $0.bookmarkKey == nil } }

    func tidyTabs() {
        guard !tidying else { return }
        let loose = looseTabs
        guard loose.count > 1 else { return flashStatus(String(localized: "No tabs to tidy")) }
        tidying = true
        // The plan is for the tabs of this space, whichever space is shown by the time it comes.
        let space = spaceID
        let items = loose.map(\.sortItem), names = spaceGroups.map(\.name)
        Task {
            let plan = await TabSorter.plan(items, existing: names)
            tidying = false
            apply(plan, in: space)
        }
    }

    /// Puts the planned tabs (those still loose) into their groups: one with the same name if the window has it, else a new one.
    func apply(_ plan: [TabSorter.Group], in space: UUID? = nil) {
        let space = space ?? spaceID
        var tidy = Tidy(made: [], placed: [:])
        for entry in plan {
            let members = entry.ids.compactMap { tab($0) }.filter { $0.spaceID == space && $0.groupID == nil && $0.bookmarkKey == nil }
            let group: UUID
            if let existing = groups(in: space).first(where: { $0.name == entry.name }) {
                group = existing.id
            } else {
                guard members.count > 1 else { continue }
                group = TabGroup(name: entry.name).id
                groups.append(TabGroup(id: group, name: entry.name))
                tidy.made.append(group)
            }
            for tab in members {
                join(tab, group)
                tidy.placed[tab.id] = group
            }
        }
        pruneGroups()
        guard tidy.tabs > 0 else {
            lastTidy = nil
            return flashStatus(String(localized: "No tabs to group"))
        }
        lastTidy = tidy
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.lastTidy == tidy { self?.lastTidy = nil }
        }
    }

    /// Takes the tidied tabs out of their groups again, those still where the tidy put them; a group it made goes
    /// away with its last tab, unless the user has put others in it since.
    func undoTidy() {
        guard let tidy = lastTidy else { return }
        lastTidy = nil
        for (id, group) in tidy.placed where tab(id)?.groupID == group { removeFromGroup(id) }
    }

    /// A new tab whose first page has loaded joins the group it plainly belongs in, if there is one.
    func sortIntoGroup(_ tab: Tab) {
        // A tab opened from another (a link, a sign-in popup) stays by it.
        let spaceGroups = spaceGroups
        guard Preferences.shared.groupNewTabs, tab.groupID == nil, tab.bookmarkKey == nil, tab.openerID == nil, !spaceGroups.isEmpty,
              tab.spaceID == spaceID else { return }
        let ids = spaceGroups.map(\.id)
        let candidates = spaceGroups.map { group in (name: group.name, members: tabs.filter { $0.groupID == group.id }.map(\.sortItem)) }
        let item = tab.sortItem
        Task {
            guard let index = await TabSorter.fit(item, groups: candidates), self.tab(tab.id) === tab, tab.groupID == nil,
                  let group = groups.first(where: { $0.id == ids[index] }) else { return }
            addTab(tab.id, to: group.id)
            if isShown(tab) { flashStatus(String(localized: "Added to “\(group.name)”")) }
        }
    }

    /// ⌘ held during the click that triggered this.
    static var commandClick: Bool { NSApp.currentEvent?.modifierFlags.contains(.command) == true }

    // MARK: Icons

    private static var iconFolder: URL {
        let url = Library.folder.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A site's icon for a page that may not be open, cached on disk by host.
    /// `keep` false (a private window's page) leaves no trace on disk.
    static func icon(for address: String, keep: Bool = true) async -> NSImage? {
        guard let url = URL(string: address), let host = url.host(), let scheme = url.scheme, scheme.hasPrefix("http") else { return nil }
        if let cached = favicons[host] { return cached }
        if let missed = missingIcons[host], missed.timeIntervalSinceNow > -3600 { return nil }
        if let loading = iconLoads[host] { return await loading.value }
        let file = iconFolder.appendingPathComponent(host + ".png")
        if let image = NSImage(contentsOf: file) {
            favicons[host] = image
            return image
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = url.host(percentEncoded: true)
        components.port = url.port
        components.path = "/favicon.ico"
        let session = keep ? URLSession.shared : ephemeral
        let load = Task { () -> NSImage? in
            guard let iconURL = components.url,
                  let (data, response) = try? await session.data(from: iconURL),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data), image.isValid else { return nil }
            return image
        }
        iconLoads[host] = load
        let image = await load.value
        iconLoads[host] = nil
        guard let image else {
            missingIcons[host] = Date()
            return nil
        }
        missingIcons[host] = nil
        favicons[host] = image
        if keep { storeIcon(image, host: host) }
        return image
    }

    static func storeIcon(_ image: NSImage, host: String) {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: iconFolder.appendingPathComponent(host + ".png"))
    }

    private static func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func insert(_ tab: Tab, after: Tab?) {
        if let after, let index = tabs.firstIndex(where: { $0 === after }) {
            tabs.insert(tab, at: index + 1)
            tab.groupID = after.groupID
            // A tab opened into a folded group would be out of sight.
            if let group = groups.firstIndex(where: { $0.id == after.groupID }), !groups[group].isOpen { groups[group].isOpen = true }
        } else {
            tabs.append(tab)
        }
    }

    // MARK: Memory

    func startSleepingIdleTabs() {
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let age = self.archiveAfter { self.archiveIdleTabs(olderThan: age) }
                if let age = self.sleepAfter { self.sleepIdleTabs(olderThan: age) }
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.sleepIdleTabs(olderThan: 0) }
        }
        source.resume()
        memoryPressure = source
    }

    func sleepIdleTabs(olderThan age: TimeInterval) {
        let now = Date()
        let neverSleep = Preferences.shared.neverSleepHosts
        for tab in tabs where !isShown(tab) && now.timeIntervalSince(tab.lastShown) >= age && !tab.isInPictureInPicture
            && Preferences.canSleep(host: tab.url?.host(), neverSleep: neverSleep) && !AgentActivity.shared.holds(tab) {
            guard let webView = tab.webView, webView.fullscreenState == .notInFullscreen,
                  webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none else { continue }
            webView.requestMediaPlaybackState { [weak self, weak tab] state in
                Task { @MainActor in
                    guard let self, let tab, !self.isShown(tab), state != .playing, !tab.isInPictureInPicture, !AgentActivity.shared.holds(tab),
                          tab.webView?.fullscreenState == .notInFullscreen else { return }
                    tab.sleep()
                }
            }
        }
    }

    /// Tabs not shown for this long are archived; nil when that is turned off.
    var archiveAfter: TimeInterval? {
        let hours = Preferences.shared.archiveHours
        return hours > 0 ? Double(hours) * 3600 : nil
    }

    /// Closes the tabs not looked at for `age` into the archive, but not those on screen, favorites and bookmarks, or
    /// ones playing, floating, in use by the AI, or using the camera or microphone. A private window keeps nothing.
    func archiveIdleTabs(olderThan age: TimeInterval, to archive: TabArchive? = nil) {
        guard !isPrivate else { return }
        let archive = archive ?? .shared
        let now = Date()
        let idle = tabs.filter { tab in
            !isShown(tab) && tab.bookmarkKey == nil && tab.url != nil && now.timeIntervalSince(tab.lastShown) >= age
                && !tab.isLoading && !tab.isPlayingAudio && !tab.isInPictureInPicture && !AgentActivity.shared.holds(tab)
                && tab.webView.map { $0.cameraCaptureState == .none && $0.microphoneCaptureState == .none } != false
        }
        guard !idle.isEmpty else { return }
        archive.add(idle.map { tab in
            TabArchive.Entry(url: tab.url?.absoluteString ?? "", title: tab.displayTitle, archived: now, group: groups.first { $0.id == tab.groupID }?.name, space: tab.spaceID)
        })
        for tab in idle { close(tab.id, remember: false) }
    }

    /// Opens an archived tab again, back in its group if this window has one by that name.
    func reopen(_ entry: TabArchive.Entry, from archive: TabArchive? = nil) {
        guard let url = URL(string: entry.url) else { return }
        let archive = archive ?? .shared
        let tab = openTab(url: url, space: entry.space)
        if let name = entry.group, let group = spaceGroups.first(where: { $0.name == name }) { addTab(tab.id, to: group.id) }
        archive.remove(entry.id)
    }

    // MARK: Session

    struct SavedTab: Codable {
        var url: String?
        var title: String
        var state: Data?
        var bookmarkKey: String?
        var group: UUID?
        /// When it was last shown, for archiving tabs not looked at in a while.
        var shown: Date?
        /// The space it is in; sessions from before spaces have none, and their tabs go to the first space.
        var space: UUID?
        /// The tab its space showed last.
        var selected: Bool?
    }

    struct SavedSession: Codable {
        var tabs: [SavedTab]
        var active: Int?
        var previous: Int?
        var groups: [TabGroup]?
        /// When it was written: time with the app closed doesn't count toward archiving a tab.
        var saved: Date?
        /// The space the window was showing.
        var space: UUID?
    }

    /// The open windows, the one in front last. Older versions saved one window as a bare `SavedSession`.
    struct SavedWindows: Codable {
        var windows: [SavedSession]

        static func decode(_ data: Data) -> [SavedSession] { decodeIfValid(data) ?? [] }

        /// Nil only when the data is no session at all; an empty list is a session with nothing open.
        static func decodeIfValid(_ data: Data) -> [SavedSession]? {
            if let saved = try? JSONDecoder().decode(SavedWindows.self, from: data) { return saved.windows }
            if let single = try? JSONDecoder().decode(SavedSession.self, from: data) { return [single] }
            return nil
        }
    }

    /// Decodes what it can: a value that doesn't decode becomes nil instead of failing everything around it.
    struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private static var sessionFile: URL { Library.folder.appendingPathComponent("session.json") }
    /// The last session that was read back whole, kept in case the next one can't be.
    private static var previousSessionFile: URL { Library.folder.appendingPathComponent("session-previous.json") }

    var savedSession: SavedSession { savedSession(fresh: true) }

    /// `fresh` asks every open page for its back and forward list; the periodic save uses what each tab kept when
    /// its last page finished loading, so it doesn't walk every web view on the main thread.
    func savedSession(fresh: Bool) -> SavedSession {
        SavedSession(
            tabs: tabs.map { SavedTab(url: $0.url?.absoluteString, title: $0.title, state: fresh ? $0.sessionState : $0.lastSessionState,
                                  bookmarkKey: $0.bookmarkKey, group: $0.groupID, shown: $0.lastShown, space: $0.spaceID,
                                  selected: spaceSelection[$0.spaceID] == $0.id) },
            active: tabs.firstIndex { $0.id == activeID },
            previous: tabs.firstIndex { $0.id == previousActiveID },
            groups: groups,
            saved: Date(),
            space: spaceID
        )
    }

    /// Writes the ordinary windows; with none open (the last one just closed and saved itself) it leaves the file alone.
    /// `inBackground` encodes and writes off the main thread (the periodic save); quitting writes before returning.
    static func saveSession(_ browsers: [Browser]? = nil, inBackground: Bool = false) {
        let normal = (browsers ?? all).filter { !$0.isPrivate }
        guard !normal.isEmpty else { return }
        let saved = SavedWindows(windows: normal.reversed().map { $0.savedSession(fresh: !inBackground) }.filter { !$0.tabs.isEmpty })
        let file = sessionFile
        let write = { (try? JSONEncoder().encode(saved).write(to: file, options: .atomic)) != nil }
        if inBackground {
            sessionQueue.async {
                // A write that failed (a full disk) is tried again at the next tick.
                if !write() { DispatchQueue.main.async { savedSignature = [] } }
            }
        } else {
            sessionQueue.sync { _ = write() }
        }
    }

    private static let sessionQueue = DispatchQueue(label: "Changmun.session", qos: .utility)
    private static var savedSignature: [String] = []

    /// Saves whenever the ordinary windows' tabs or addresses changed, so a crash or a forced quit loses little.
    static func saveSessionIfChanged() {
        let signature = all.filter { !$0.isPrivate }.map { browser in
            browser.tabs.map { "\($0.id) \($0.spaceID) \($0.groupID?.uuidString ?? "") \($0.url?.absoluteString ?? "")" }.joined(separator: "|")
                + " #\(browser.activeID ?? 0) \(browser.spaceID) " + browser.groups.map { "\($0.id) \($0.isOpen) \($0.name)" }.joined(separator: "|")
        }
        guard signature != savedSignature else { return }
        savedSignature = signature
        saveSession(inBackground: true)
    }

    /// Ordinary windows closed while others stayed open, most recent last; ⌘⇧T brings them back once no tab is left to reopen.
    static var closedWindows: [SavedSession] = []

    static func savedWindows() -> [SavedSession] {
        guard Preferences.shared.restoreTabs else { return [] }
        let read = { (file: URL) in (try? Data(contentsOf: file)).flatMap(SavedWindows.decodeIfValid)?.filter { !$0.tabs.isEmpty } }
        if let windows = read(sessionFile) {
            if !windows.isEmpty, let data = try? Data(contentsOf: sessionFile) { try? data.write(to: previousSessionFile, options: .atomic) }
            return windows
        }
        // A session that can't be read at all (damaged): the one before it, rather than an empty window.
        return read(previousSessionFile) ?? []
    }

    /// Restores a saved window asleep, apart from the tab that was shown.
    func restore(_ saved: SavedSession) {
        for item in saved.tabs {
            let tab = Tab(id: Self.takeID(), url: item.url.flatMap(URL.init(string:)), title: item.title, state: item.state, browser: self)
            tab.spaceID = spaces.space(item.space).id
            tab.bookmarkKey = item.bookmarkKey.flatMap { Self.keeps($0, in: spaces.space(tab.spaceID)) ? $0 : nil }
            tab.groupID = item.group
            if item.selected == true { spaceSelection[tab.spaceID] = tab.id }
            if let shown = item.shown { tab.lastShown = Date(timeIntervalSinceNow: -max(0, (saved.saved ?? shown).timeIntervalSince(shown))) }
            tabs.append(tab)
        }
        groups = saved.groups ?? []
        pruneGroups()
        guard !tabs.isEmpty else { return }
        let shown = tabs[min(saved.active ?? 0, tabs.count - 1)]
        // The space the window was in, with the tab it showed there; a space with none shows its first tab, or is empty.
        if let space = saved.space, spaces.contains(space), !isPrivate { spaceID = space } else if !isPrivate { spaceID = shown.spaceID }
        if let start = shown.spaceID == spaceID ? shown : switchTarget(in: spaceID) {
            activate(start.id)
        } else {
            activeID = nil
            if !isPrivate { commandBar = .newTab }
        }
        if let previous = saved.previous, tabs.indices.contains(previous), tabs[previous].spaceID == spaceID { previousActiveID = tabs[previous].id }
    }
}

extension Browser.SavedSession {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let all = try values.decode([Browser.Lossy<Browser.SavedTab>].self, forKey: .tabs)
        tabs = all.compactMap(\.value)
        // Positions were saved among all the tabs; count only the ones that came through.
        let position = { (index: Int?) -> Int? in
            guard let index, all.indices.contains(index), all[index].value != nil else { return nil }
            return all[..<index].filter { $0.value != nil }.count
        }
        active = position((try? values.decodeIfPresent(Int.self, forKey: .active)) ?? nil)
        previous = position((try? values.decodeIfPresent(Int.self, forKey: .previous)) ?? nil)
        groups = try? values.decodeIfPresent([Browser.TabGroup].self, forKey: .groups)
        saved = try? values.decodeIfPresent(Date.self, forKey: .saved)
        space = try? values.decodeIfPresent(UUID.self, forKey: .space)
    }
}

extension Browser.SavedWindows {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windows = try values.decode([Browser.Lossy<Browser.SavedSession>].self, forKey: .windows).compactMap(\.value)
    }
}
