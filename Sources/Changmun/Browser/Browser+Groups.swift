import AppKit
import WebKit

extension Browser {
    // MARK: Tab groups

    struct TabGroup: Identifiable, Codable, Equatable {
        var id = UUID()
        var name: String
        var isOpen = true
    }

    /// The groups of the space shown (a group's tabs are all in one space).
    var spaceGroups: [TabGroup] { groups(in: spaceID) }

    func groups(in space: UUID) -> [TabGroup] {
        let used = Set(tabs.filter { $0.spaceID == space }.compactMap(\.groupID))
        return groups.filter { used.contains($0.id) }
    }

    /// Ends the rename of `tab` with what was typed: an unchanged name leaves the tab as it was, so opening the field and leaving
    /// it does not fix the page's title as the name. Nothing happens unless the rename is still on (Esc, or another tab's, ended it):
    /// a focus change that comes after must not save what was cancelled or close another tab's field.
    func finishRenaming(_ tab: Tab, with name: String) {
        guard renamingTab == tab.id else { return }
        renamingTab = nil
        let trimmed = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trimmed(name) != trimmed(tab.displayTitle) { tab.rename(to: name) }
    }

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
        guard !isPrivate, let group = groups.first(where: { $0.id == id }) else { return false }
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
        for page in added { library.addBookmark(url: page.url, title: page.tab.bookmarkTitle.isEmpty ? (page.tab.url?.host() ?? page.url) : page.tab.bookmarkTitle, folder: folder) }
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
        let saved = SavedSession(tabs: [SavedTab(url: tab.url?.absoluteString, title: tab.title, customTitle: tab.customTitle, state: tab.sessionState, space: tab.spaceID)], active: 0, space: tab.spaceID)
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
    func join(_ tab: Tab, _ group: UUID) {
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
    func pruneGroups() {
        let known = Set(groups.map(\.id))
        for tab in tabs where tab.groupID.map({ !known.contains($0) }) == true { tab.groupID = nil }
        let used = Set(tabs.compactMap { $0.bookmarkKey == nil ? $0.groupID : nil })
        if groups.contains(where: { !used.contains($0.id) }) { groups.removeAll { !used.contains($0.id) } }
        if let renaming = renamingGroup, !used.contains(renaming) { renamingGroup = nil }
    }
}
