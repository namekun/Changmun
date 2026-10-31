import Foundation

/// What the strip of tabs along the top of the window shows, in order: the favorites, then the tabs of the space as the sidebar lists them.
enum TabStripItem: Identifiable {
    case favorite(Library.Entry)
    /// A group's chip, before its tabs; `count` is all of its tabs, folded away or not.
    case group(Browser.TabGroup, count: Int)
    case tab(Tab)

    var id: String {
        switch self {
        case .favorite(let entry): "favorite \(entry.url)"
        case .group(let group, _): "group \(group.id)"
        case .tab(let tab): "tab \(tab.id)"
        }
    }

    var tab: Tab? {
        if case .tab(let tab) = self { tab } else { nil }
    }
}

extension Browser {
    /// The strip's items: the favorites as pinned tiles, then each loose tab, and each group as its chip followed by its tabs, none of
    /// them but the shown one while the group is folded (as in the sidebar's list).
    /// The last tab on show of each group that has one, by that tab: where the end of the group is.
    var lastShownTabOfGroups: [Int: UUID] {
        var ends: [Int: UUID] = [:]
        for case .group(let group, let tabs) in listing {
            if let last = shown(tabs, in: group).last { ends[last.id] = group.id }
        }
        return ends
    }

    func stripItems(favorites: [Library.Entry]) -> [TabStripItem] {
        var items = favorites.map(TabStripItem.favorite)
        for item in listing {
            switch item {
            case .tab(let tab):
                items.append(.tab(tab))
            case .group(let group, let tabs):
                items.append(.group(group, count: tabs.count))
                items += shown(tabs, in: group).map(TabStripItem.tab)
            }
        }
        return items
    }
}
