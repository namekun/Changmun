import AppKit
import WebKit

extension Browser {
    static func bookmarkKey(url: String, folder: String) -> String { folder + "\n" + url }

    /// Whether a tab of this space may keep the bookmark key. A favorite's key belongs to its own space: a tab whose space
    /// couldn't be found would otherwise be bound to a favorite it can't show, and be out of sight. Imported folders are shared.
    static func keeps(_ key: String, in space: Space) -> Bool {
        let folder = String(key.prefix { $0 != "\n" })
        return !Library.isFavorites(folder) || folder == space.favoritesFolder
    }

    /// The key of every bookmark the library holds, or nil when it can't be read (a tab then keeps its bookmark, as in the sidebar).
    static func libraryKeys() -> Set<String>? {
        guard let read = Library.shared.readBookmarks() else { return nil }
        var keys = Set<String>()
        for (folder, entries) in read.favorites { for entry in entries { keys.insert(bookmarkKey(url: entry.url, folder: folder)) } }
        for folder in read.folders { for entry in folder.entries { keys.insert(bookmarkKey(url: entry.url, folder: folder.name)) } }
        return keys
    }

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
            for tab in browser.tabs where tab.bookmarkKey == old {
                // A favorite belongs to its own space: a tab of another space becomes a plain tab rather than go out of sight.
                if !keeps(new, in: browser.spaces.space(tab.spaceID)) {
                    tab.bookmarkKey = nil
                } else if !browser.tabs.contains(where: { $0.spaceID == tab.spaceID && $0.bookmarkKey == new }) {
                    tab.bookmarkKey = new
                }
                browser.objectWillChange.send()
            }
        }
    }

    /// The title a bookmark gets from what was typed, or nil when it stays as it is: nothing typed, or what is shown already.
    /// `shown` is what the row says now (the address while the bookmark has no title), so opening the field and leaving it fixes nothing.
    static func renamedTitle(_ typed: String, shown: String) -> String? {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, typed != shown.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return String(typed.prefix(Tab.maxNameLength))
    }

    /// Ends the rename of a bookmark with what was typed (nil for Esc: nothing is kept), and offers to take it back. Nothing happens unless
    /// this bookmark's rename is still on (Esc, or another one's, ended it): a focus change that comes after must not save what was cancelled.
    func finishRenamingBookmark(url: String, folder: String, title: String, with typed: String?) {
        guard renamingBookmark == Self.bookmarkKey(url: url, folder: folder) else { return }
        renamingBookmark = nil
        guard let typed, let new = Self.renamedTitle(typed, shown: title.isEmpty ? url : title),
              Library.shared.renameBookmark(url: url, folder: folder, title: new) else { return }
        guard !title.isEmpty else { return }
        offerUndo(String(localized: "Renamed the bookmark")) { Library.shared.renameBookmark(url: url, folder: folder, title: title) }
    }

    /// A click on a folder's row opens or closes it at once, with no wait to tell it from a double-click. The second click of a double-click
    /// puts it back, so the folder ends as open as it was, and types its name instead. `openKey` names the row (see `renamingFolder`).
    func clickFolder(openKey: String, clickCount: Int) {
        spaces.toggleOpen(openKey, in: spaceID)
        if clickCount >= 2 { renamingFolder = openKey }
    }

    /// The name a folder gets from what was typed, "" for the one it had before the user named it, or nil when it stays as it is: what is shown already.
    static func renamedFolder(_ typed: String, shown: String) -> String? {
        let typed = String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Tab.maxNameLength))
        return typed == shown ? nil : typed
    }

    /// Ends the rename of a folder with what was typed (nil for Esc: nothing is kept; empty: the name it came with), and offers to take it back.
    /// Nothing happens unless this row's rename is still on, as in `finishRenamingBookmark`. The folder keeps its key: pins, open folders and its bookmarks stay.
    func finishRenamingFolder(key: String, scope: String, shown: String, with typed: String?) {
        guard renamingFolder == scope + key else { return }
        renamingFolder = nil
        guard let typed, let name = Self.renamedFolder(typed, shown: shown) else { return }
        let before = Library.shared.folderNames()[key] ?? ""
        guard name != before, Library.shared.renameFolder(key: key, to: name) else { return }
        offerUndo(String(localized: "Renamed the folder")) { Library.shared.renameFolder(key: key, to: before) }
    }

    /// Turns an open tab into a bookmark's tab (pinning it).
    func bind(_ tab: Tab, to key: String) {
        guard bookmarkTab(key) == nil else { return }
        tab.bookmarkKey = key
        tab.groupID = nil
        pruneGroups()
        objectWillChange.send()
    }
}
