import AppKit

extension Browser {
    /// Saves a page to read later, and offers to take it back. Nothing is saved from a private window, and the AI has no way here.
    func addToReadingList(url: String?, title: String) {
        guard ReadingList.canSave(url, isPrivate: isPrivate), let url, let key = ReadingList.key(for: url) else { return }
        if Library.shared.addToReadingList(url: key, title: title) {
            offerUndo(String(localized: "Added to Reading List")) { Library.shared.removeFromReadingList(url: key) }
        } else {
            flashStatus(String(localized: "Already in Reading List"))
        }
    }

    func addToReadingList(_ tab: Tab) { addToReadingList(url: tab.url?.absoluteString, title: tab.bookmarkTitle) }

    /// Opens a saved page the way a bookmark opens: the tab that has it already, or a new one next to this one (always a new one for ⌘-click).
    /// A page that is open and not loading is read now; one that loads is read when it has loaded (see `pageLoaded`).
    func openReadingItem(_ item: ReadingItem, inNewTab: Bool = false) {
        let showing = spaceTabs.first { ReadingList.key(for: $0.url?.absoluteString) == item.url }
        openBookmark(item.url, key: nil, inNewTab: inNewTab)
        if !inNewTab, let showing, !showing.isLoading { Library.shared.markReadingItem(url: item.url, read: true) }
    }

    /// A page finished loading: if it is a saved page not read yet, it is read now.
    func pageLoaded(_ address: String?) {
        guard ReadingList.shouldMarkRead(loaded: address, isPrivate: isPrivate, in: LibraryWatcher.shared.readingList), let address else { return }
        Library.shared.markReadingItem(url: address, read: true)
    }

    func removeReadingItem(_ item: ReadingItem) {
        Library.shared.removeFromReadingList(url: item.url)
        offerUndo(String(localized: "Removed from Reading List")) { Library.shared.restoreReadingItems([item]) }
    }

    func clearReadItems() {
        let gone = Library.shared.clearReadItems()
        guard !gone.isEmpty else { return }
        offerUndo(gone.count == 1 ? String(localized: "Cleared \(gone.count) read item") : String(localized: "Cleared \(gone.count) read items")) {
            Library.shared.restoreReadingItems(gone)
        }
    }

    func markReadingItem(_ item: ReadingItem, read: Bool) { Library.shared.markReadingItem(url: item.url, read: read) }
}
