import AppKit
import SwiftUI

/// The bookmarks as the sidebar shows them, read again off the main thread whenever the library changes. One for
/// the whole app, so showing and hiding the sidebar costs nothing.
@MainActor
final class LibraryWatcher: ObservableObject {
    static let shared = LibraryWatcher()
    /// Every space's favorites, by the folder they are kept in.
    @Published private(set) var favoritesByFolder: [String: [Library.Entry]] = [:]
    @Published private(set) var sources: [(source: String, folders: [Library.Folder])] = []
    /// The favorites' addresses, for the star in the address bar.
    private var favoriteURLs: [String: Set<String>] = [:]
    private var reading = false
    private var readAgain = false

    func favorites(in folder: String) -> [Library.Entry] { favoritesByFolder[folder] ?? [] }

    func isFavorite(_ url: String, in folder: String) -> Bool { favoriteURLs[folder]?.contains(url) == true }

    func folder(_ key: String) -> Library.Folder? {
        for source in sources {
            for folder in source.folders { if let found = folder.find(key) { return found } }
        }
        return nil
    }

    private init() {
        if let read = Library.shared.readBookmarks() { apply(read) }
        NotificationCenter.default.addObserver(forName: Library.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LibraryWatcher.shared.reload() }
        }
    }

    private func reload() {
        guard !reading else { readAgain = true; return }
        reading = true
        Task {
            // An unreadable library (locked, damaged, a full disk) keeps what is shown, and every tab keeps its bookmark.
            let read = await Library.shared.inBackground { $0.readBookmarks() }
            // Changed while reading: this read may already be old, so only the next one counts.
            if let read, !readAgain { apply(read) }
            reading = false
            if readAgain {
                readAgain = false
                reload()
            }
        }
    }

    private func apply(_ read: (favorites: [String: [Library.Entry]], folders: [(name: String, entries: [Library.Entry])], names: [String: String])) {
        let sources = Library.groupBySource(read.folders, names: read.names)
        if read.favorites != favoritesByFolder {
            favoritesByFolder = read.favorites
            favoriteURLs = read.favorites.mapValues { Set($0.map(\.url)) }
        }
        if sources.map(\.source) != self.sources.map(\.source) || sources.map(\.folders) != self.sources.map(\.folders) { self.sources = sources }
        var keys = Set(read.favorites.flatMap { folder, entries in entries.map { Browser.bookmarkKey(url: $0.url, folder: folder) } })
        for folder in read.folders { for entry in folder.entries { keys.insert(Browser.bookmarkKey(url: entry.url, folder: folder.name)) } }
        for browser in Browser.all { browser.releaseBookmarkTabs(keeping: keys) }
    }
}
