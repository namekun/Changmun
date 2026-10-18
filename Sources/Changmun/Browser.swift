import AppKit
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
    /// A short message in the same place ("주소를 복사했어요").
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
    weak var window: NSWindow?

    init(isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        configuration = isPrivate ? Self.makeConfiguration(store: .nonPersistent(), extensions: false) : Self.configuration
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

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeID: Int?
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
    @Published var focusMode = false {
        didSet {
            guard focusMode != oldValue else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window?.standardWindowButton(kind)?.isHidden = focusMode
            }
            guard focusMode else { return }
            showDownloads = false
            renamingGroup = nil
            flashStatus("집중 모드 · ⇧⌘F로 돌아가기")
        }
    }
    static var favicons: [String: NSImage] = [:]
    /// For a private window's requests: no disk cache, no shared cookies.
    static let ephemeral = URLSession(configuration: .ephemeral)
    private static var missingIcons = Set<String>()
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
        var url: URL?
        var title: String
        var state: Data?
        var index: Int
        var bookmarkKey: String?
        var group: TabGroup?
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

    private static func makeConfiguration(store: WKWebsiteDataStore, extensions: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
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

    /// The halves of a split that ends were on screen until now.
    @Published private(set) var split: Split? {
        didSet { for id in [oldValue?.left, oldValue?.right].compactMap({ $0 }) where split?.contains(id) != true { tab(id)?.lastShown = Date() } }
    }
    var shownSplit: Split? { split?.contains(activeID) == true ? split : nil }

    /// A link opened with ⇧-click, floating over the page until it is closed or kept as a tab (Arc's Peek).
    @Published private(set) var peek: Tab?

    func flashStatus(_ message: String) {
        overlay.statusMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
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
    func openTab(url: URL?, activate: Bool = true, after: Tab? = nil) -> Tab {
        let tab = Tab(id: Self.takeID(), url: url, browser: self)
        insert(tab, after: after)
        tab.sortsIntoGroup = tab.groupID == nil
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabOpened(tab) }
        if activate {
            self.activate(tab.id)
            commandBar = nil
        }
        return tab
    }

    func openTab(configuration: WKWebViewConfiguration, after: Tab?) -> Tab {
        let tab = Tab(id: Self.takeID(), configuration: configuration, browser: self)
        insert(tab, after: after)
        tab.sortsIntoGroup = tab.groupID == nil
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabOpened(tab) }
        activate(tab.id)
        return tab
    }

    func activate(_ id: Int) {
        guard let tab = tab(id) else { return }
        hoveredLink = nil
        if id != activeID && findBarVisible { hideFindBar() }
        let previous = active
        if let previous, previous !== tab {
            previousActiveID = previous.id
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

    // MARK: Split view

    /// Shows `id` to the right of the active tab.
    func split(with id: Int) {
        guard let activeID, id != activeID, tab(id) != nil else { return }
        split = Split(left: activeID, right: id)
        splitFraction = 0.5
        tab(id)?.wake()
    }

    func unsplit() { split = nil }

    nonisolated static func clampedSplitFraction(_ fraction: Double) -> Double { min(max(fraction, 0.2), 0.8) }

    /// The split for the menu command: the active tab and the one shown before it.
    func toggleSplit() {
        if shownSplit != nil { return unsplit() }
        guard let back = previousActiveID, tab(back) != nil else { return NSSound.beep() }
        split(with: back)
    }

    // MARK: Peek

    func openPeek(_ url: URL) {
        peek?.sleep()
        let tab = Tab(id: Self.takeID(), url: url, browser: self)
        peek = tab
        tab.wake()
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
        if split?.contains(id) == true { split = nil }
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabClosed(closing) }
        if remember {
            closedTabs.append(ClosedTab(url: closing.url, title: closing.title, state: closing.sessionState, index: index, bookmarkKey: closing.bookmarkKey,
                                        group: groups.first { $0.id == closing.groupID }))
            if closedTabs.count > 25 { closedTabs.removeFirst() }
        }
        closing.sleep()
        pruneGroups()
        if activeID == id {
            if tabs.isEmpty {
                activeID = nil
                commandBar = .newTab
            } else if let back = previousActiveID, tabs.contains(where: { $0.id == back }) {
                activate(back)
            } else {
                let listed = listedTabs
                activate(listed.isEmpty ? tabs[min(index, tabs.count - 1)].id : listed[min(listed.count - 1, max(0, listedIndex(before: index)))].id)
            }
        }
    }

    /// Brings back the last closed tab where it was, with its back/forward history.
    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let tab = Tab(id: Self.takeID(), url: closed.url, title: closed.title, state: closed.state, browser: self)
        if let key = closed.bookmarkKey, bookmarkTab(key) == nil { tab.bookmarkKey = key }
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

    /// Moves a tab to where another one is (dropping it on that tab), or to the end.
    func moveTab(_ id: Int, to target: Int?) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), id != target else { return }
        let tab = tabs.remove(at: from)
        if let target, let to = tabs.firstIndex(where: { $0.id == target }) {
            tabs.insert(tab, at: from <= to ? to + 1 : to)
        } else {
            tabs.append(tab)
        }
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabMoved(tab, from: from) }
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

    /// How many listed tabs came before position `index` in `tabs` (after a tab there was removed).
    private func listedIndex(before index: Int) -> Int {
        tabs.prefix(index).filter { $0.bookmarkKey == nil }.count - 1 + (tabs.indices.contains(index) && tabs[index].bookmarkKey == nil ? 1 : 0)
    }

    func open(_ input: String, in mode: CommandBarMode) {
        guard let url = AddressInput.resolve(input) else { return }
        if mode == .editCurrent, let active { active.load(url) } else { openTab(url: url) }
        commandBar = nil
    }

    static func bookmarkKey(url: String, folder: String) -> String { folder + "\n" + url }

    /// Tabs shown in the sidebar's tab list; bookmark tabs show in their bookmark's place instead.
    var listedTabs: [Tab] { tabs.filter { $0.bookmarkKey == nil } }

    func bookmarkTab(_ key: String) -> Tab? { tabs.first { $0.bookmarkKey == key } }

    /// A bookmark is its own tab, as in Dia and Arc: the first click opens it in its place, later clicks switch back
    /// to it (wherever it has navigated since). ⌘-click opens the page in an ordinary new tab instead.
    func openBookmark(_ address: String, key: String?, inNewTab: Bool = false) {
        guard let url = URL(string: address) else { return }
        if inNewTab {
            openTab(url: url, after: active)
            return
        }
        guard let key else {
            if let open = tabs.first(where: { $0.url?.absoluteString == address }) { activate(open.id) } else { openTab(url: url, after: active) }
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
    /// When a site allowed to open popups last had one opened as a tab, in this window.
    var lastAllowedPopup = Date.distantPast

    /// The shown tab first, then the others by when they were last shown.
    var recentTabs: [Tab] {
        tabs.enumerated().sorted { a, b in
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
    func group(_ ids: [Int], name: String = "새 그룹") -> UUID? {
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

    /// A tab dropped on another moves there and joins that tab's group, or leaves its own.
    func dropTab(_ id: Int, on target: Int) {
        moveTab(id, to: target)
        guard let tab = tab(id), let other = self.tab(target) else { return }
        tab.groupID = other.groupID
        pruneGroups()
        objectWillChange.send()
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
        for tab in tabs where tab.groupID == id { close(tab.id) }
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
    var looseTabs: [Tab] { tabs.filter { $0.groupID == nil && $0.bookmarkKey == nil } }

    func tidyTabs() {
        guard !tidying else { return }
        let loose = looseTabs
        guard loose.count > 1 else { return flashStatus("정리할 탭이 없어요") }
        tidying = true
        let items = loose.map(\.sortItem), names = groups.map(\.name)
        Task {
            let plan = await TabSorter.plan(items, existing: names)
            tidying = false
            apply(plan)
        }
    }

    /// Puts the planned tabs (those still loose) into their groups: one with the same name if the window has it, else a new one.
    func apply(_ plan: [TabSorter.Group]) {
        var tidy = Tidy(made: [], placed: [:])
        for entry in plan {
            let members = entry.ids.compactMap { tab($0) }.filter { $0.groupID == nil && $0.bookmarkKey == nil }
            let group: UUID
            if let existing = groups.first(where: { $0.name == entry.name }) {
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
            return flashStatus("묶을 만한 탭이 없어요")
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
        guard Preferences.shared.groupNewTabs, tab.groupID == nil, tab.bookmarkKey == nil, tab.openerID == nil, !groups.isEmpty else { return }
        let ids = groups.map(\.id)
        let candidates = groups.map { group in (name: group.name, members: tabs.filter { $0.groupID == group.id }.map(\.sortItem)) }
        let item = tab.sortItem
        Task {
            guard let index = await TabSorter.fit(item, groups: candidates), self.tab(tab.id) === tab, tab.groupID == nil,
                  let group = groups.first(where: { $0.id == ids[index] }) else { return }
            addTab(tab.id, to: group.id)
            if isShown(tab) { flashStatus("'\(group.name)' 그룹에 넣었어요") }
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
        if missingIcons.contains(host) { return nil }
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
        missingIcons.insert(host)
        guard let iconURL = components.url,
              let (data, response) = try? await (keep ? URLSession.shared : ephemeral).data(from: iconURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data), image.isValid else { return nil }
        missingIcons.remove(host)
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
        for tab in tabs where !isShown(tab) && now.timeIntervalSince(tab.lastShown) >= age
            && Preferences.canSleep(host: tab.url?.host(), neverSleep: neverSleep) {
            guard let webView = tab.webView, webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none else { continue }
            webView.requestMediaPlaybackState { [weak self, weak tab] state in
                Task { @MainActor in
                    guard let self, let tab, !self.isShown(tab), state != .playing else { return }
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
    /// ones playing, floating, or using the camera or microphone. A private window keeps nothing.
    func archiveIdleTabs(olderThan age: TimeInterval, to archive: TabArchive? = nil) {
        guard !isPrivate else { return }
        let archive = archive ?? .shared
        let now = Date()
        let idle = tabs.filter { tab in
            !isShown(tab) && tab.bookmarkKey == nil && tab.url != nil && now.timeIntervalSince(tab.lastShown) >= age
                && !tab.isLoading && !tab.isPlayingAudio && !tab.isInPictureInPicture
                && tab.webView.map { $0.cameraCaptureState == .none && $0.microphoneCaptureState == .none } != false
        }
        guard !idle.isEmpty else { return }
        archive.add(idle.map { tab in
            TabArchive.Entry(url: tab.url?.absoluteString ?? "", title: tab.displayTitle, archived: now, group: groups.first { $0.id == tab.groupID }?.name)
        })
        for tab in idle { close(tab.id, remember: false) }
    }

    /// Opens an archived tab again, back in its group if this window has one by that name.
    func reopen(_ entry: TabArchive.Entry, from archive: TabArchive? = nil) {
        guard let url = URL(string: entry.url) else { return }
        let archive = archive ?? .shared
        let tab = openTab(url: url)
        if let name = entry.group, let group = groups.first(where: { $0.name == name }) { addTab(tab.id, to: group.id) }
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
    }

    struct SavedSession: Codable {
        var tabs: [SavedTab]
        var active: Int?
        var previous: Int?
        var groups: [TabGroup]?
        /// When it was written: time with the app closed doesn't count toward archiving a tab.
        var saved: Date?
    }

    /// The open windows, the one in front last. Older versions saved one window as a bare `SavedSession`.
    struct SavedWindows: Codable {
        var windows: [SavedSession]

        static func decode(_ data: Data) -> [SavedSession] {
            if let saved = try? JSONDecoder().decode(SavedWindows.self, from: data) { return saved.windows }
            if let single = try? JSONDecoder().decode(SavedSession.self, from: data) { return [single] }
            return []
        }
    }

    private static var sessionFile: URL { Library.folder.appendingPathComponent("session.json") }

    var savedSession: SavedSession {
        SavedSession(
            tabs: tabs.map { SavedTab(url: $0.url?.absoluteString, title: $0.title, state: $0.sessionState, bookmarkKey: $0.bookmarkKey, group: $0.groupID,
                                  shown: $0.lastShown) },
            active: tabs.firstIndex { $0.id == activeID },
            previous: tabs.firstIndex { $0.id == previousActiveID },
            groups: groups,
            saved: Date()
        )
    }

    /// Writes the ordinary windows; with none open (the last one just closed and saved itself) it leaves the file alone.
    /// `inBackground` encodes and writes off the main thread (the periodic save); quitting writes before returning.
    static func saveSession(_ browsers: [Browser]? = nil, inBackground: Bool = false) {
        let normal = (browsers ?? all).filter { !$0.isPrivate }
        guard !normal.isEmpty else { return }
        let saved = SavedWindows(windows: normal.reversed().map(\.savedSession).filter { !$0.tabs.isEmpty })
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
            browser.tabs.map { "\($0.id) \($0.groupID?.uuidString ?? "") \($0.url?.absoluteString ?? "")" }.joined(separator: "|")
                + " #\(browser.activeID ?? 0) " + browser.groups.map { "\($0.id) \($0.isOpen) \($0.name)" }.joined(separator: "|")
        }
        guard signature != savedSignature else { return }
        savedSignature = signature
        saveSession(inBackground: true)
    }

    /// Ordinary windows closed while others stayed open, most recent last; ⌘⇧T brings them back once no tab is left to reopen.
    static var closedWindows: [SavedSession] = []

    static func savedWindows() -> [SavedSession] {
        guard Preferences.shared.restoreTabs, let data = try? Data(contentsOf: sessionFile) else { return [] }
        return SavedWindows.decode(data).filter { !$0.tabs.isEmpty }
    }

    /// Restores a saved window asleep, apart from the tab that was shown.
    func restore(_ saved: SavedSession) {
        for item in saved.tabs {
            let tab = Tab(id: Self.takeID(), url: item.url.flatMap(URL.init(string:)), title: item.title, state: item.state, browser: self)
            tab.bookmarkKey = item.bookmarkKey
            tab.groupID = item.group
            if let shown = item.shown { tab.lastShown = Date(timeIntervalSinceNow: -max(0, (saved.saved ?? shown).timeIntervalSince(shown))) }
            tabs.append(tab)
        }
        groups = saved.groups ?? []
        pruneGroups()
        guard !tabs.isEmpty else { return }
        activate(tabs[min(saved.active ?? 0, tabs.count - 1)].id)
        if let previous = saved.previous, tabs.indices.contains(previous) { previousActiveID = tabs[previous].id }
    }
}
