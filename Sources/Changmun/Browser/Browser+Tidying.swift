import AppKit
import WebKit

extension Browser {
    // MARK: Tidying

    /// What the last tidy did, so it can be taken back: the groups it made and the tabs it put into groups already there.
    struct Tidy: Equatable {
        var id = UUID()
        var made: [UUID]
        /// Each tab it put in a group, and the group.
        var placed: [Int: UUID]
        /// The order of all the tabs before it.
        var order: [Int] = []
        var tabs: Int { placed.count }
    }

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
        var tidy = Tidy(made: [], placed: [:], order: tabs.map(\.id))
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
        Announcer.announce(tidy.message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.lastTidy == tidy { self?.lastTidy = nil }
        }
    }

    /// Takes the tidied tabs out of their groups again, those still where the tidy put them, and back to where they were
    /// in the list; a group it made goes away with its last tab, unless the user has put others in it since.
    func undoTidy() {
        guard let tidy = lastTidy else { return }
        lastTidy = nil
        let undone = tidy.order.filter { id in tidy.placed[id].map { tab(id)?.groupID == $0 } == true }
        for id in undone { removeFromGroup(id) }
        // Last to first, each just above the tab that followed it, so the ones after it are already back.
        for id in undone.reversed() {
            let after = tidy.order[(tidy.order.firstIndex(of: id) ?? 0)...].dropFirst().first { tab($0) != nil }
            moveTab(id, to: after)
        }
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
}
