import SwiftUI
import WebKit

/// The colours a space can tint the sidebar with.
enum SpaceTint: String, Codable, CaseIterable, Identifiable {
    case blue, coral, green, purple, amber, teal, pink, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: Color(red: 0.23, green: 0.48, blue: 0.88)
        case .coral: Color(red: 0.88, green: 0.42, blue: 0.30)
        case .green: Color(red: 0.25, green: 0.63, blue: 0.44)
        case .purple: Color(red: 0.55, green: 0.36, blue: 0.96)
        case .amber: Color(red: 0.88, green: 0.66, blue: 0.23)
        case .teal: Color(red: 0.18, green: 0.66, blue: 0.72)
        case .pink: Color(red: 0.86, green: 0.35, blue: 0.55)
        case .gray: Color(red: 0.54, green: 0.54, blue: 0.56)
        }
    }
}

/// A set of tabs, tab groups, favorites and pinned folders, with a name, a symbol and a colour. A profile space also
/// keeps its own cookies and site data, in a website data store named by its id.
struct Space: Identifiable, Codable, Equatable {
    /// The space made from what the browser held before spaces: its favorites stay where they were, in folder "".
    static let defaultID = UUID(uuidString: "5BACE000-0000-4000-8000-000000000001")!

    var id = UUID()
    var name: String
    /// An SF Symbol name, or an emoji.
    var symbol: String
    var tint: SpaceTint
    /// Fixed when the space is made: cookies and site data can't be moved between stores afterwards.
    var isProfile = false
    var pinnedFolders: [String] = []
    var openFolders: [String] = []

    init(id: UUID = UUID(), name: String, symbol: String, tint: SpaceTint, isProfile: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.isProfile = isProfile
    }

    /// Reads what is there and falls back for the rest, so a file from another version still opens.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = (try? values.decode(String.self, forKey: .name)) ?? String(localized: "Personal")
        symbol = (try? values.decode(String.self, forKey: .symbol)) ?? "house"
        tint = (try? values.decode(SpaceTint.self, forKey: .tint)) ?? .gray
        isProfile = (try? values.decode(Bool.self, forKey: .isProfile)) ?? false
        pinnedFolders = (try? values.decode([String].self, forKey: .pinnedFolders)) ?? []
        openFolders = (try? values.decode([String].self, forKey: .openFolders)) ?? []
    }

    /// Whether a folder lies inside one of the pinned folders, and so shows in it already.
    func hasPinnedAncestor(_ key: String) -> Bool { pinnedFolders.contains { key.hasPrefix($0 + " / ") } }

    /// The pinned folders shown among the pinned ones: a pinned folder inside another pinned folder shows there only.
    var topPinnedFolders: [String] { pinnedFolders.filter { !hasPinnedAncestor($0) } }

    var favoritesFolder: String { id == Self.defaultID ? Library.favoritesFolder : Library.favoritesPrefix + id.uuidString }
    var isEmoji: Bool { !symbol.allSatisfy(\.isASCII) }
    /// The website data store a profile space keeps its cookies and site data in; the same one at every launch.
    var dataStoreID: UUID? { isProfile ? id : nil }

    static let symbols = ["briefcase", "house", "book", "flask", "chevron.left.forwardslash.chevron.right", "cart", "heart", "paperplane", "music.note", "leaf"]
    static let emoji = ["💼", "🏠", "📚", "🧪", "💻", "🛒", "❤️", "✈️", "🎵", "🌱"]
}

/// Every space, and the one a new window starts in, kept in a file next to the library.
@MainActor
final class SpaceStore: ObservableObject {
    static let shared = SpaceStore(folder: Library.folder, defaults: .standard)
    /// Set once the pinned and open folders of the settings from before spaces have been taken into the first space.
    static let importedKey = "spacesLegacyFoldersImported"

    private struct Saved: Codable {
        var spaces: [Space]
        var active: UUID?
        /// Profile data stores of deleted spaces that are still to be erased.
        var pendingRemovals: [UUID]?

        init(spaces: [Space], active: UUID?, pendingRemovals: [UUID]) {
            self.spaces = spaces
            self.active = active
            self.pendingRemovals = pendingRemovals
        }

        /// A space that doesn't decode is left out; the others stay.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            spaces = try values.decode([Browser.Lossy<Space>].self, forKey: .spaces).compactMap(\.value)
            active = try? values.decodeIfPresent(UUID.self, forKey: .active)
            pendingRemovals = try? values.decodeIfPresent([UUID].self, forKey: .pendingRemovals)
        }
    }

    @Published private(set) var spaces: [Space] = []
    private(set) var lastActive: UUID
    private(set) var pendingRemovals: [UUID] = []
    private let file: URL
    /// False when the file is there but couldn't be read: what it holds is never written over.
    private var writable = true

    /// With no file yet, the first space is made from what the browser already holds: its pinned and open folders come from
    /// the settings, and its tabs and favorites carry over as they are. Everything the move could touch is copied first.
    init(folder: URL, defaults: UserDefaults) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("spaces.json")
        lastActive = Space.defaultID
        var data: Data?
        do {
            data = try Data(contentsOf: file)
        } catch {
            let missing = (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileReadNoSuchFileError
            writable = missing
        }
        if let data {
            if let saved = try? JSONDecoder().decode(Saved.self, from: data), !saved.spaces.isEmpty {
                spaces = saved.spaces
                lastActive = saved.active ?? saved.spaces[0].id
                pendingRemovals = saved.pendingRemovals ?? []
                // A file made before the settings were taken over (a stray one, or the first launch cut short) still gets them, once.
                if !defaults.bool(forKey: Self.importedKey) {
                    Self.backUp(folder: folder, defaults: defaults)
                    if let index = spaces.firstIndex(where: { $0.id == Space.defaultID }), spaces[index].pinnedFolders.isEmpty, spaces[index].openFolders.isEmpty {
                        spaces[index].pinnedFolders = defaults.stringArray(forKey: "pinnedFolders") ?? []
                        spaces[index].openFolders = (defaults.stringArray(forKey: "openFolders") ?? []).sorted()
                    }
                    defaults.set(true, forKey: Self.importedKey)
                    save()
                }
                return
            }
            // Damaged: kept as it is, and the browser starts over from one space holding everything.
            try? FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("spaces-damaged-\(Int(Date().timeIntervalSince1970)).json"))
        }
        var first = Space(id: Space.defaultID, name: String(localized: "Personal"), symbol: "house", tint: .gray)
        first.pinnedFolders = defaults.stringArray(forKey: "pinnedFolders") ?? []
        first.openFolders = (defaults.stringArray(forKey: "openFolders") ?? []).sorted()
        spaces = [first]
        guard writable else { return }
        Self.backUp(folder: folder, defaults: defaults)
        defaults.set(true, forKey: Self.importedKey)
        save()
    }

    /// Copies, once, the files the move to spaces reads (the session, the library, the settings it takes over). Nothing is
    /// overwritten or deleted: the originals stay as they are. A copy is written under another name and renamed when whole,
    /// so a copy cut short is never taken for one, and is made again.
    static func backUp(folder: URL, defaults: UserDefaults) {
        let manager = FileManager.default
        func copyOnce(_ name: String, from source: URL?, _ make: (URL) throws -> Void) {
            let copy = folder.appendingPathComponent("before-spaces-" + name)
            guard !manager.fileExists(atPath: copy.path), source.map({ manager.fileExists(atPath: $0.path) }) != false else { return }
            let partial = copy.appendingPathExtension("partial")
            try? manager.removeItem(at: partial)
            do {
                try make(partial)
                try manager.moveItem(at: partial, to: copy)
            } catch {
                try? manager.removeItem(at: partial)
            }
        }
        let session = folder.appendingPathComponent("session.json")
        copyOnce("session.json", from: session) { try manager.copyItem(at: session, to: $0) }
        // The library is copied by SQLite itself, so the copy is whole even while the browser is writing to it.
        let library = folder.appendingPathComponent("library.sqlite")
        copyOnce("library.sqlite", from: library) { partial in
            do {
                try SQLite(path: library.path).run("VACUUM INTO ?", [partial.path])
            } catch {
                try? manager.removeItem(at: partial)
                try manager.copyItem(at: library, to: partial)
            }
        }
        let old: [String: [String]] = ["pinnedFolders": defaults.stringArray(forKey: "pinnedFolders") ?? [], "openFolders": defaults.stringArray(forKey: "openFolders") ?? []]
        copyOnce("preferences.json", from: nil) { try JSONEncoder().encode(old).write(to: $0) }
    }

    private func save() {
        guard writable else { return }
        try? JSONEncoder().encode(Saved(spaces: spaces, active: lastActive, pendingRemovals: pendingRemovals)).write(to: file, options: .atomic)
    }

    /// The space with this id; a tab saved in a space that is gone, or in none, belongs to the first one.
    func space(_ id: UUID?) -> Space {
        spaces.first { $0.id == id } ?? spaces.first { $0.id == Space.defaultID } ?? spaces[0]
    }

    func contains(_ id: UUID?) -> Bool { spaces.contains { $0.id == id } }

    func rememberActive(_ id: UUID) {
        guard id != lastActive else { return }
        lastActive = id
        save()
    }

    @discardableResult
    func add(name: String, symbol: String, tint: SpaceTint, isProfile: Bool) -> Space {
        let space = Space(name: Self.clean(name), symbol: symbol, tint: tint, isProfile: isProfile)
        spaces.append(space)
        save()
        return space
    }

    /// The profile can't change.
    func update(_ id: UUID, name: String, symbol: String, tint: SpaceTint) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].name = Self.clean(name)
        spaces[index].symbol = symbol
        spaces[index].tint = tint
        save()
    }

    /// The space a window in `id` goes to when it is deleted: the one that takes its place in the row, or the one before it
    /// when it was the last. Nil for the last space, which stays.
    func neighbour(afterRemoving id: UUID) -> UUID? {
        let rest = spaces.filter { $0.id != id }
        guard !rest.isEmpty, let index = spaces.firstIndex(where: { $0.id == id }) else { return nil }
        return rest[min(index, rest.count - 1)].id
    }

    /// The last space stays. A profile's data store is put on the list of those still to be erased.
    @discardableResult
    func remove(_ id: UUID) -> Space? {
        guard let next = neighbour(afterRemoving: id), let index = spaces.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = spaces.remove(at: index)
        if lastActive == id { lastActive = next }
        if removed.isProfile, !pendingRemovals.contains(id) { pendingRemovals.append(id) }
        save()
        return removed
    }

    /// The store is gone; it needn't be tried again.
    func finishRemoval(_ id: UUID) {
        pendingRemovals.removeAll { $0 == id }
        save()
    }

    private static func clean(_ name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Space") : name
    }

    // MARK: Folders

    /// Pins a folder, or moves a pinned one, to where `target` is (dropped on it), or to the end.
    func pinFolder(_ key: String, before target: String? = nil, in id: UUID) {
        guard !key.isEmpty, key != target, let index = spaces.firstIndex(where: { $0.id == id }), !spaces[index].hasPinnedAncestor(key) else { return }
        var list = spaces[index].pinnedFolders.filter { $0 != key }
        if let target, let at = list.firstIndex(of: target) { list.insert(key, at: at) } else { list.append(key) }
        spaces[index].pinnedFolders = list
        save()
    }

    /// Takes a folder off one space's pinned list, or off every space's (a folder that was deleted).
    func unpinFolder(_ key: String, in id: UUID? = nil) {
        for index in spaces.indices where id == nil || spaces[index].id == id { spaces[index].pinnedFolders.removeAll { $0 == key } }
        save()
    }

    func toggleOpen(_ key: String, in id: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        if let at = spaces[index].openFolders.firstIndex(of: key) { spaces[index].openFolders.remove(at: at) } else { spaces[index].openFolders.append(key) }
        save()
    }
}

/// A profile space's websites: the same configuration for all its tabs, kept for as long as the space lasts.
@MainActor
enum Profiles {
    private static var configurations: [UUID: WKWebViewConfiguration] = [:]

    /// `base` for an ordinary space; for a profile, the same settings, scripts and blocking rules over its own data store.
    static func configuration(for space: Space, base: WKWebViewConfiguration) -> WKWebViewConfiguration {
        guard let id = space.dataStoreID else { return base }
        if let kept = configurations[id] { return kept }
        let made = Browser.makeConfiguration(store: WKWebsiteDataStore(forIdentifier: id), extensions: !Headless.isOn)
        configurations[id] = made
        return made
    }

    /// How a store is erased, and how long to wait between tries (a store a closing page still holds can't go yet).
    static var remover: (UUID) async throws -> Void = { try await WKWebsiteDataStore.remove(forIdentifier: $0) }
    static var delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)]
    private static var draining: Set<UUID> = []

    /// Erases the stores of deleted profiles, each leaving the store's list only once it is gone; one that wouldn't go is
    /// tried again at the next launch. Only stores that were on the list are touched, never any other.
    static func drain(_ store: SpaceStore) async {
        for id in store.pendingRemovals where !draining.contains(id) {
            draining.insert(id)
            defer { draining.remove(id) }
            guard !store.spaces.contains(where: { $0.dataStoreID == id }) else {
                store.finishRemoval(id)
                continue
            }
            configurations[id] = nil
            for delay in delays {
                if (try? await remover(id)) != nil {
                    store.finishRemoval(id)
                    break
                }
                try? await Task.sleep(for: delay)
            }
        }
    }

    static func startDraining(_ store: SpaceStore) {
        Task { await drain(store) }
    }

    /// Every profile's store, for clearing website data in Settings.
    static func stores(_ spaces: [Space]) -> [WKWebsiteDataStore] {
        spaces.compactMap(\.dataStoreID).map { WKWebsiteDataStore(forIdentifier: $0) }
    }
}

/// Moving two fingers sideways over the sidebar goes to the next space or the one before.
struct SpaceSwipe {
    private(set) var travelled: CGFloat = 0
    private var done = false
    static let distance: CGFloat = 60

    /// The scroll event's horizontal and vertical delta; returns the step (1 = next, -1 = before) once the swipe is far
    /// enough, once per swipe.
    mutating func scrolled(dx: CGFloat, dy: CGFloat, began: Bool, ended: Bool) -> Int? {
        if began { travelled = 0; done = false }
        defer { if ended { travelled = 0; done = false } }
        guard !done, abs(dx) > abs(dy) else { return nil }
        travelled += dx
        guard abs(travelled) >= Self.distance else { return nil }
        done = true
        return travelled < 0 ? 1 : -1
    }
}
