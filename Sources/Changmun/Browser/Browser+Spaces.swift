import AppKit
import WebKit

extension Browser {
    // MARK: Spaces

    /// The tab a space shows when it is switched to: the one it showed last, else its first listed tab.
    func switchTarget(in space: UUID) -> Tab? {
        if let remembered = spaceSelection[space], let tab = tab(remembered), tab.spaceID == space { return tab }
        return tabs.first { $0.spaceID == space && $0.bookmarkKey == nil } ?? tabs.first { $0.spaceID == space }
    }

    /// Makes `id` the space shown; the caller shows a tab of it.
    func enter(_ id: UUID) {
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
        if opensBar { openNewTab(.emptied) }
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
        guard let next = store.neighbour(afterRemoving: id), let leaving = store.spaces.first(where: { $0.id == id }) else { return }
        // The favorites move first: a space whose favorites couldn't be moved stays, so they are not left where nothing shows them.
        if let target = store.spaces.first(where: { $0.id != id }), !library.moveFavorites(from: leaving.favoritesFolder, to: target.favoritesFolder) {
            current?.flashStatus(String(localized: "Couldn’t delete the space: its favorites couldn’t be moved"))
            return
        }
        guard let removed = store.remove(id) else { return }
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

    var space: Space { spaces.space(spaceID) }
    var favoritesFolder: String { space.favoritesFolder }
}
