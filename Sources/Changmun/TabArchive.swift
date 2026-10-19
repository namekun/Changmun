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

    init(file: URL) {
        self.file = file
        entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))) ?? []
    }

    func add(_ new: [Entry]) {
        entries.insert(contentsOf: new, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func remove(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        entries = []
        save()
    }

    func matching(_ search: String) -> [Entry] {
        let search = search.trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.url.localizedCaseInsensitiveContains(search) }
    }

    private func save() {
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}
