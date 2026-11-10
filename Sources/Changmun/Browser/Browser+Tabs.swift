import AppKit
import WebKit

extension Browser {
    // MARK: Tabs

    @discardableResult
    func openTab(url: URL?, activate: Bool = true, after: Tab? = nil, space: UUID? = nil, start: Bool = false) -> Tab {
        let tab = Tab(id: Self.takeID(), url: url, browser: self, isStart: start)
        if let space, spaces.contains(space) { tab.spaceID = space }
        insert(tab, after: after)
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
        // A start tab has no page: the start page is drawn for it, and nothing is loaded.
        if !tab.isStart { tab.wake() }
        if let split = shownSplit {
            for half in [split.left, split.right] { self.tab(half)?.wake() }
        }
        if #available(macOS 15.4, *), previous !== tab { ExtensionHost.shared.tabActivated(tab, previous: previous) }
    }

    /// Whether the tab is on screen: the active one, or the other half of the split.
    func isShown(_ tab: Tab) -> Bool { tab.id == activeID || shownSplit?.contains(tab.id) == true }

    /// Kept in the session too, so ⌘⇧T brings tabs back after a restart.
    struct ClosedTab: Codable {
        var id = UUID()
        var url: URL?
        var title: String
        var customTitle: String?
        var state: Data?
        var index: Int
        var bookmarkKey: String?
        var group: TabGroup?
        var space: UUID
        /// For the start page, which says how long ago it was closed.
        var closedAt = Date()
    }

    /// `remember` false (an archived tab) leaves it out of the tabs ⌘⇧T brings back.
    func close(_ id: Int, remember: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs.remove(at: index)
        if renamingTab == id { renamingTab = nil }
        for (space, shared) in splits where shared.contains(id) { setSplit(nil, in: space) }
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabClosed(closing) }
        // A start tab has nothing to bring back.
        if remember && !closing.isStart {
            closedTabs.append(ClosedTab(url: closing.url, title: closing.title, customTitle: closing.customTitle, state: closing.sessionState, index: index, bookmarkKey: closing.bookmarkKey,
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
                openNewTab(.emptied)
            } else if let back = previousActiveID, here.contains(where: { $0.id == back }) {
                activate(back)
            } else {
                let listed = listedTabs
                let before = tabs.prefix(index).filter { $0.spaceID == closing.spaceID }.count
                activate(listed.isEmpty ? here[min(before, here.count - 1)].id : listed[min(listed.count - 1, max(0, listedIndex(before: index, in: closing.spaceID)))].id)
            }
        }
    }

    /// Closes a tab the user closed (its ×, its menu, ⌘W, a middle click) and offers to bring it back.
    func closeTab(_ id: Int) {
        guard let tab = tab(id) else { return }
        let offers = Self.offersUndo(isStart: tab.isStart, url: tab.url), title = tab.displayTitle.isEmpty ? (tab.url?.host() ?? "") : tab.displayTitle
        close(id)
        guard offers, let closed = closedTabs.last else { return }
        offerUndo(String(localized: "Closed “\(title)”")) { [weak self] in self?.reopenClosedTab(id: closed.id) }
    }

    /// Whether closing a tab offers Undo: not a start tab or one with no page (⌘W on an empty tab), which leave nothing to bring back.
    nonisolated static func offersUndo(isStart: Bool, url: URL?) -> Bool { !isStart && url != nil }

    /// The tab list of the space in the order shown, a folded group's tabs too: what closing several tabs chooses from.
    var listedInOrder: [Tab] {
        listing.flatMap { item -> [Tab] in
            switch item {
            case .tab(let tab): [tab]
            case .group(_, let tabs): tabs
            }
        }
    }

    /// The listed tabs other than `id` (Close Other Tabs). Only the tab list: a favorite's or a bookmark's tab stays.
    nonisolated static func othersToClose(keeping id: Int, listed: [Int]) -> [Int] { listed.filter { $0 != id } }

    /// The listed tabs below `id` (Close Tabs Below); below a favorite's or a bookmark's tab, which is above the list, all of them.
    nonisolated static func belowToClose(_ id: Int, listed: [Int]) -> [Int] {
        guard let at = listed.firstIndex(of: id) else { return listed }
        return Array(listed[(at + 1)...])
    }

    func closeOtherTabs(keeping id: Int) {
        closeTabs(Self.othersToClose(keeping: id, listed: listedInOrder.map(\.id)), showing: id)
    }

    func closeTabsBelow(_ id: Int) {
        closeTabs(Self.belowToClose(id, listed: listedInOrder.map(\.id)), showing: id)
    }

    /// Closes the tabs, first showing `kept` if the tab shown is among them so none is woken just to be closed.
    private func closeTabs(_ ids: [Int], showing kept: Int) {
        if let activeID, ids.contains(activeID), tab(kept) != nil { activate(kept) }
        closeAll(tabs.filter { ids.contains($0.id) })
    }

    /// Closes the tabs, each one ⌘⇧T can bring back, and offers to bring them all back at once.
    func closeAll(_ closing: [Tab]) {
        guard !closing.isEmpty else { return }
        for tab in closing { close(tab.id) }
        // A start tab is not remembered, so there is nothing of it to bring back.
        let count = closing.filter { !$0.isStart }.count, top = closedTabs.last?.id
        guard count > 0 else { return }
        offerUndo(count == 1 ? String(localized: "Closed \(count) tab") : String(localized: "Closed \(count) tabs")) { [weak self] in
            // Only while they are still the last ones closed; ⌘⇧T is there for the rest.
            guard let self, top != nil, closedTabs.last?.id == top else { return }
            for _ in 0..<min(count, closedTabs.count) { reopenClosedTab() }
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

    /// Forgets the tabs closed since `date` (clearing history takes them off the start page's "Continue viewing" too).
    func removeClosedTabs(since date: Date) {
        closedTabs.removeAll { $0.closedAt >= date }
    }

    private func reopen(_ closed: ClosedTab) {
        let tab = Tab(id: Self.takeID(), url: closed.url, title: closed.title, state: closed.state, browser: self)
        tab.customTitle = closed.customTitle
        if spaces.contains(closed.space) { tab.spaceID = closed.space }
        // Not the bookmark of a tab whose bookmark was deleted meanwhile: it would be out of sight in the tab list.
        if let key = closed.bookmarkKey, Self.keeps(key, in: spaces.space(tab.spaceID)), (Self.libraryKeys()?.contains(key) ?? true),
           !tabs.contains(where: { $0.spaceID == tab.spaceID && $0.bookmarkKey == key }) { tab.bookmarkKey = key }
        tabs.insert(tab, at: min(closed.index, tabs.count))
        // Back into its group, made again if it went away with its last tab; in its place, so a group closed all at once comes back in order.
        if let group = closed.group, tab.bookmarkKey == nil {
            if !groups.contains(where: { $0.id == group.id }) { groups.append(group) }
            tab.groupID = group.id
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

    /// The next tab down the sidebar (1) or the one above (-1), going round; from a tab the sidebar doesn't show, the first or the last.
    func selectTab(offset: Int) {
        if let id = Self.step(from: activeID, by: offset, in: sidebarTabs.map(\.id)) { activate(id) }
    }

    /// ⌘1 to ⌘8 down the sidebar; 9 is the last.
    func selectTab(number: Int) {
        if let id = Self.numbered(number, in: sidebarTabs.map(\.id)) { activate(id) }
    }

    nonisolated static func step(from current: Int?, by offset: Int, in order: [Int]) -> Int? {
        guard !order.isEmpty else { return nil }
        guard let at = order.firstIndex(where: { $0 == current }) else { return offset < 0 ? order.last : order.first }
        return order[((at + offset) % order.count + order.count) % order.count]
    }

    nonisolated static func numbered(_ number: Int, in order: [Int]) -> Int? {
        guard !order.isEmpty else { return nil }
        return number >= 9 ? order.last : order[min(max(number, 1) - 1, order.count - 1)]
    }

    /// Every tab the sidebar shows, top to bottom: the favorites' open tabs, the tabs of the bookmarks shown in the pinned folders,
    /// then the tab list (a folded group shows only its shown tab).
    var sidebarTabs: [Tab] {
        let library = LibraryWatcher.shared
        return sidebarTabs(favorites: library.favorites(in: favoritesFolder), pinned: space.topPinnedFolders.compactMap(library.folder))
    }

    func sidebarTabs(favorites: [Library.Entry], pinned: [Library.Folder]) -> [Tab] {
        let drawn = favorites.map { Self.bookmarkKey(url: $0.url, folder: favoritesFolder) }
            + pinned.flatMap { Sidebar.treeRows($0, depth: 0, scope: "pin:", pinned: true, open: space.openFolders, dragging: false) }.compactMap { row in
                if case .bookmark(let entry, let folder, _, _) = row { Self.bookmarkKey(url: entry.url, folder: folder) } else { nil }
            }
        var bound: [String: Int] = [:]
        for tab in spaceTabs { if let key = tab.bookmarkKey { bound[key] = tab.id } }
        return Self.sidebarOrder(drawn: drawn, bound: bound, listed: visibleTabs.map(\.id)).compactMap { id in tabs.first { $0.id == id } }
    }

    /// The tabs in the order the sidebar draws them: the tab of each bookmark drawn (`drawn`, top to bottom; `bound` names each open
    /// bookmark's tab), then the listed tabs. A bookmark with no tab open is skipped, and no tab comes twice.
    nonisolated static func sidebarOrder(drawn: [String], bound: [String: Int], listed: [Int]) -> [Int] {
        var seen = Set<Int>()
        return (drawn.compactMap { bound[$0] } + listed).filter { seen.insert($0).inserted }
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

    /// The tabs of the space shown.
    var spaceTabs: [Tab] { tabs.filter { $0.spaceID == spaceID } }

    /// Tabs shown in the sidebar's tab list; bookmark tabs show in their bookmark's place instead.
    var listedTabs: [Tab] { spaceTabs.filter { $0.bookmarkKey == nil } }

    func insert(_ tab: Tab, after: Tab?) {
        if let after, let index = tabs.firstIndex(where: { $0 === after }) {
            tabs.insert(tab, at: index + 1)
            tab.groupID = after.groupID
            // A tab opened into a folded group would be out of sight.
            if let group = groups.firstIndex(where: { $0.id == after.groupID }), !groups[group].isOpen { groups[group].isOpen = true }
        } else {
            tabs.append(tab)
        }
    }
}
