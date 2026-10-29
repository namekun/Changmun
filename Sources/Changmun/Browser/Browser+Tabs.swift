import AppKit
import WebKit

extension Browser {
    // MARK: Tabs

    @discardableResult
    func openTab(url: URL?, activate: Bool = true, after: Tab? = nil, space: UUID? = nil, start: Bool = false) -> Tab {
        let tab = Tab(id: Self.takeID(), url: url, browser: self, isStart: start)
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
        // A start tab has no page: the start page is drawn for it, and nothing is loaded.
        if !tab.isStart { tab.wake() }
        if let split = shownSplit {
            for half in [split.left, split.right] { self.tab(half)?.wake() }
        }
        if #available(macOS 15.4, *), previous !== tab { ExtensionHost.shared.tabActivated(tab, previous: previous) }
    }

    /// Whether the tab is on screen: the active one, or the other half of the split.
    func isShown(_ tab: Tab) -> Bool { tab.id == activeID || shownSplit?.contains(tab.id) == true }

    struct ClosedTab {
        let id = UUID()
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
