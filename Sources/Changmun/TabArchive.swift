import Foundation

/// Tabs closed for going unlooked-at a while (Settings › Tabs), newest first, to open again from History › Archived Tabs.
@MainActor
final class TabArchive: ObservableObject {
    static let shared = TabArchive(file: Library.folder.appendingPathComponent("archive.json"))
    static let limit = 500

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var url: String
        var title: String
        var archived: Date
        /// The name of the group it was in, which it joins again if the window still has one by that name.
        var group: String?
        /// The space it was in; older entries have none and open in the space shown.
        var space: UUID?
    }

    @Published private(set) var entries: [Entry]
    private let file: URL
    /// False when the file is there but couldn't be read, or couldn't be kept as it was before starting over: nothing is written over it.
    private var writable = true

    init(file: URL) {
        self.file = file
        switch Library.FileRead(file) {
        case .missing:
            entries = []
        case .unreadable:
            entries = []
            writable = false
        case .data(let data):
            if let all = try? JSONDecoder().decode([Browser.Lossy<Entry>].self, from: data) {
                entries = all.compactMap(\.value)
                // An entry that doesn't decode is lost to the next write: the file is kept as it was.
                if entries.count < all.count { writable = Library.keepDamaged(file) }
            } else {
                entries = []
                writable = Library.keepDamaged(file)
            }
        }
    }

    /// Adds the entries; false (and nothing added) when they couldn't be written, so the tabs they stand for must stay open.
    @discardableResult
    func add(_ new: [Entry]) -> Bool {
        let before = entries
        entries.insert(contentsOf: new, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        guard save() else {
            entries = before
            return false
        }
        return true
    }

    func remove(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
        _ = save()
    }

    /// Forgets what was archived since the date (Clear History).
    func remove(since date: Date) {
        entries.removeAll { $0.archived >= date }
        _ = save()
    }

    func removeAll() {
        entries = []
        _ = save()
    }

    func matching(_ search: String) -> [Entry] {
        let search = search.trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.url.localizedCaseInsensitiveContains(search) }
    }

    private func save() -> Bool {
        guard writable else { return false }
        return (try? JSONEncoder().encode(entries).write(to: file, options: .atomic)) != nil
    }
}
