import Foundation

/// Bookmarks and history, in one SQLite file under Application Support. The main connection is used on the main
/// thread; imports and background reads each open their own.
final class Library: @unchecked Sendable {
    static let didChange = Notification.Name("ChangmunLibraryDidChange")
    /// The first space's favorites (and the library's before spaces existed) are in folder "". Another space keeps its own
    /// in a folder named by this prefix and its id, which the bookmark folders never list.
    static let favoritesFolder = ""
    static let favoritesPrefix = "\u{1}"

    static func isFavorites(_ folder: String) -> Bool { folder.isEmpty || folder.hasPrefix(favoritesPrefix) }
    static let shared = Library(path: Library.folder.appendingPathComponent("library.sqlite").path)

    /// The user's data folder, for the app and for Changmun Headless only. Anything else (the test runner, a bare
    /// `swift run` binary) gets a folder of its own in the temporary directory, so it can never touch that data.
    static var folder: URL {
        let url = location(forBundle: Bundle.main.bundleIdentifier)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("changmun-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)

    static func location(forBundle bundleID: String?) -> URL {
        guard bundleID?.hasPrefix("io.github.namekun.Changmun") == true else { return scratch }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID == Headless.bundleID ? "Changmun Headless" : "Changmun", isDirectory: true)
    }

    struct Entry: Equatable {
        var url: String
        var title: String
    }

    private let db: SQLite?
    private let path: String

    init(path: String) {
        self.path = path
        db = try? SQLite(path: path)
        try? db?.execute("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS history (url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', visits INTEGER NOT NULL DEFAULT 1, last_visit REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS bookmarks (id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', folder TEXT NOT NULL DEFAULT '', added REAL NOT NULL, UNIQUE(url, folder));
        CREATE INDEX IF NOT EXISTS history_recent ON history(last_visit DESC);
        """)
    }

    func recordVisit(url: String, title: String, at date: Date = Date()) {
        guard url.hasPrefix("http") else { return }
        try? db?.run("""
        INSERT INTO history (url, title, visits, last_visit) VALUES (?, ?, 1, ?)
        ON CONFLICT(url) DO UPDATE SET visits = visits + 1, last_visit = excluded.last_visit,
          title = CASE WHEN excluded.title = '' THEN history.title ELSE excluded.title END
        """, [url, title, date.timeIntervalSince1970])
    }

    private func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Library.didChange, object: nil) }
    }

    /// Imports run off the main thread on their own connection, committing in chunks so the
    /// browser's own writes (visits, bookmarks) never land in, or wait long behind, an import's transaction.
    private func importing<T>(_ items: [T], _ write: (SQLite, T) throws -> Bool) throws -> Int {
        let db = try SQLite(path: path)
        var count = 0
        var start = 0
        while start < items.count {
            let chunk = items[start..<min(start + 1000, items.count)]
            try db.transaction {
                for item in chunk where try write(db, item) { count += 1 }
            }
            start += chunk.count
        }
        changed()
        return count
    }

    /// Adds history from another browser, keeping the higher visit count and the later visit.
    func importHistory(_ entries: [(url: String, title: String, visits: Int, lastVisit: Date)]) throws -> Int {
        try importing(entries) { db, e in
            guard e.url.hasPrefix("http") else { return false }
            try db.run("""
            INSERT INTO history (url, title, visits, last_visit) VALUES (?, ?, ?, ?)
            ON CONFLICT(url) DO UPDATE SET visits = MAX(visits, excluded.visits), last_visit = MAX(last_visit, excluded.last_visit),
              title = CASE WHEN history.title = '' THEN excluded.title ELSE history.title END
            """, [e.url, e.title, max(e.visits, 1), e.lastVisit.timeIntervalSince1970])
            return true
        }
    }

    func importBookmarks(_ entries: [(url: String, title: String, folder: String)]) throws -> Int {
        let now = Date().timeIntervalSince1970
        return try importing(entries) { db, e in
            guard !e.url.isEmpty else { return false }
            try db.run("INSERT OR IGNORE INTO bookmarks (url, title, folder, added) VALUES (?, ?, ?, ?)", [e.url, e.title, e.folder, now])
            return true
        }
    }

    /// Whether the page is in a space's favorites (imported folders don't count).
    func isFavorite(_ url: String, in folder: String = Library.favoritesFolder) -> Bool {
        ((try? db?.query("SELECT 1 FROM bookmarks WHERE url = ? AND folder = ? LIMIT 1", [url, folder])) ?? []).isEmpty == false
    }

    /// Adds the page to the favorites or takes it out; returns whether it is a favorite now (unchanged if the write failed).
    func toggleBookmark(url: String, title: String, in folder: String = Library.favoritesFolder) -> Bool {
        defer { changed() }
        if isFavorite(url, in: folder) {
            try? db?.run("DELETE FROM bookmarks WHERE url = ? AND folder = ?", [url, folder])
        } else {
            try? db?.run("INSERT OR IGNORE INTO bookmarks (url, title, folder, added) VALUES (?, ?, ?, ?)", [url, title, folder, Date().timeIntervalSince1970])
        }
        return isFavorite(url, in: folder)
    }

    /// Puts a bookmark back (undoing a removal): at the end of its folder, or of the favorites.
    func addBookmark(url: String, title: String, folder: String) {
        try? db?.run("INSERT OR IGNORE INTO bookmarks (url, title, folder, added) VALUES (?, ?, ?, ?)", [url, title, folder, Date().timeIntervalSince1970])
        changed()
    }

    /// Removes a folder and the folders inside it.
    func removeFolder(_ folder: String) {
        try? db?.run("DELETE FROM bookmarks WHERE folder = ? OR folder LIKE ? ESCAPE '\\'", [folder, Self.likeEscaped(folder) + " / %"])
        changed()
    }

    /// Removes everything imported from one browser (folders named "<source> …").
    func removeSource(_ source: String) {
        guard !source.isEmpty else { return }
        try? db?.run("DELETE FROM bookmarks WHERE folder <> '' AND (folder = ? OR folder LIKE ? ESCAPE '\\')", [source, Self.likeEscaped(source) + " %"])
        changed()
    }

    static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    func removeBookmark(url: String, folder: String) {
        try? db?.run("DELETE FROM bookmarks WHERE url = ? AND folder = ?", [url, folder])
        changed()
    }

    /// The bookmarks pinned in a space's tile grid: the ones added in Changmun itself.
    func favorites(in folder: String = Library.favoritesFolder) -> [Entry] {
        rows("SELECT url, title FROM bookmarks WHERE folder = ? ORDER BY added, id", [folder])
    }

    /// Imported bookmarks grouped by folder, folders in the order they were first imported.
    func folders() -> [(name: String, entries: [Entry])] {
        Self.grouped((try? db?.query(Self.foldersQuery)) ?? [])
    }

    /// Every space's favorites (by their folder) and the folders in one read, or nil when the database can't be read:
    /// an unreadable library must not look like one whose bookmarks were all deleted.
    func readBookmarks() -> (favorites: [String: [Entry]], folders: [(name: String, entries: [Entry])])? {
        guard let db, (try? db.execute("BEGIN")) != nil else { return nil }
        // One snapshot: a bookmark moving between folders meanwhile is in one place or the other, never neither.
        defer { try? db.execute("COMMIT") }
        guard let favorites = try? db.query("SELECT folder, url, title FROM bookmarks WHERE folder = '' OR substr(folder, 1, 1) = char(1) ORDER BY added, id"),
              let folders = try? db.query(Self.foldersQuery) else { return nil }
        var byFolder: [String: [Entry]] = [:]
        for row in favorites {
            guard let folder = row[0] as? String, let url = row[1] as? String else { continue }
            byFolder[folder, default: []].append(Entry(url: url, title: row[2] as? String ?? ""))
        }
        return (byFolder, Self.grouped(folders))
    }

    private static let foldersQuery = "SELECT folder, url, title FROM bookmarks WHERE folder <> '' AND substr(folder, 1, 1) <> char(1) ORDER BY id"

    private static func grouped(_ all: [[Any?]]) -> [(name: String, entries: [Entry])] {
        var order: [String] = []
        var groups: [String: [Entry]] = [:]
        for row in all {
            guard let folder = row[0] as? String, let url = row[1] as? String else { continue }
            if groups[folder] == nil { order.append(folder) }
            groups[folder, default: []].append(Entry(url: url, title: row[2] as? String ?? ""))
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    func knowsURL(_ url: String) -> Bool {
        !((try? db?.query("SELECT 1 FROM history WHERE url = ? UNION ALL SELECT 1 FROM bookmarks WHERE url = ? LIMIT 1", [url, url])) ?? []).isEmpty
    }

    /// Whether the user has been to, or bookmarked, a page on this host.
    func knowsHost(_ host: String) -> Bool {
        let escaped = host.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let patterns = ["http://\(escaped)/%", "https://\(escaped)/%", "http://\(escaped):%", "https://\(escaped):%"]
        let clause = Array(repeating: "url LIKE ? ESCAPE '\\'", count: 4).joined(separator: " OR ")
        let rows = try? db?.query("SELECT 1 FROM history WHERE \(clause) UNION ALL SELECT 1 FROM bookmarks WHERE \(clause) LIMIT 1", patterns + patterns)
        return !(rows ?? []).isEmpty
    }

    struct Visit: Identifiable, Equatable {
        var url: String
        var title: String
        var lastVisit: Date
        var id: String { url }
    }

    /// Most recent first, optionally only pages whose title or address contains every word.
    func history(matching text: String = "", limit: Int = 500) -> [Visit] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        let clause = words.isEmpty ? "1" : words.map { _ in "(lower(title) LIKE ? OR lower(url) LIKE ?)" }.joined(separator: " AND ")
        let values: [Any?] = words.flatMap { word -> [String] in ["%\(word)%", "%\(word)%"] }
        let rows = (try? db?.query("SELECT url, title, last_visit FROM history WHERE \(clause) ORDER BY last_visit DESC LIMIT ?", values + [limit])) ?? []
        return rows.compactMap { row in
            guard let url = row[0] as? String else { return nil }
            return Visit(url: url, title: row[1] as? String ?? "", lastVisit: Date(timeIntervalSince1970: row[2] as? Double ?? 0))
        }
    }

    /// Forgets visits older than a year, as Safari does, off the main thread.
    func pruneHistory() {
        let path = path
        DispatchQueue.global(qos: .utility).async {
            guard let db = try? SQLite(path: path) else { return }
            let cutoff = Date().timeIntervalSince1970 - 365 * 86400
            for _ in 0..<500 {
                guard let old = try? db.query("SELECT 1 FROM history WHERE last_visit < ? LIMIT 1", [cutoff]), !old.isEmpty else { break }
                try? db.run("DELETE FROM history WHERE rowid IN (SELECT rowid FROM history WHERE last_visit < ? LIMIT 500)", [cutoff])
            }
        }
    }

    func deleteHistory(url: String) {
        try? db?.run("DELETE FROM history WHERE url = ?", [url])
        changed()
    }

    /// Forgets visits made since the date (all of them for `.distantPast`); returns how many pages were removed.
    @discardableResult
    func clearHistory(since date: Date) -> Int {
        let before = counts.history
        try? db?.run("DELETE FROM history WHERE last_visit >= ?", [date.timeIntervalSince1970])
        changed()
        return before - counts.history
    }

    /// Moves a favorite to where another one is (dropping it on that tile), or to the end.
    func moveFavorite(_ url: String, to target: String?, in folder: String = Library.favoritesFolder) {
        let original = favorites(in: folder).map(\.url)
        guard let from = original.firstIndex(of: url), url != target else { return }
        var order = original
        order.remove(at: from)
        if let target, let to = order.firstIndex(of: target), let was = original.firstIndex(of: target) {
            order.insert(url, at: was > from ? to + 1 : to)
        } else {
            order.append(url)
        }
        guard let db else { return }
        try? db.transaction {
            for (position, item) in order.enumerated() {
                try db.run("UPDATE bookmarks SET added = ? WHERE url = ? AND folder = ?", [Double(position), item, folder])
            }
        }
        changed()
    }

    /// Puts these favorites, in this order, just above another favorite, or at the end.
    func placeFavorites(_ urls: [String], before target: String?, in folder: String = Library.favoritesFolder) {
        var order = favorites(in: folder).map(\.url).filter { !urls.contains($0) }
        order.insert(contentsOf: urls, at: target.flatMap { order.firstIndex(of: $0) } ?? order.count)
        guard let db else { return }
        try? db.transaction {
            for (position, item) in order.enumerated() {
                try db.run("UPDATE bookmarks SET added = ? WHERE url = ? AND folder = ?", [Double(position), item, folder])
            }
        }
        changed()
    }

    /// Moves every favorite of one space to another, as one change, leaving out those already there. Returns whether it worked.
    @discardableResult
    func moveFavorites(from: String, to: String) -> Bool {
        guard from != to, let db else { return false }
        do {
            try db.transaction {
                try db.run("INSERT OR IGNORE INTO bookmarks (url, title, folder, added) SELECT url, title, ?, added FROM bookmarks WHERE folder = ?", [to, from])
                try db.run("DELETE FROM bookmarks WHERE folder = ?", [from])
            }
        } catch {
            return false
        }
        changed()
        return true
    }

    /// Moves a bookmark to the end of another folder (the favorites are folder ""); if it is there already, the copy
    /// it was moved from just goes. Returns whether it moved.
    @discardableResult
    func moveBookmark(url: String, from: String, to: String) -> Bool {
        guard from != to, let db,
              !((try? db.query("SELECT 1 FROM bookmarks WHERE url = ? AND folder = ?", [url, from])) ?? []).isEmpty else { return false }
        do {
            try db.transaction {
                try db.run("INSERT OR IGNORE INTO bookmarks (url, title, folder, added) SELECT url, title, ?, ? FROM bookmarks WHERE url = ? AND folder = ?",
                           [to, Date().timeIntervalSince1970, url, from])
                try db.run("DELETE FROM bookmarks WHERE url = ? AND folder = ?", [url, from])
            }
        } catch {
            return false
        }
        changed()
        return true
    }

    /// Reads on a queue of their own, away from the main thread.
    private static let readQueue = DispatchQueue(label: "Changmun.library.read", qos: .userInitiated)
    private var openedReader: Library?
    private var reader: Library {
        if let openedReader, openedReader.db != nil { return openedReader }
        let fresh = Library(path: path)
        openedReader = fresh
        return fresh
    }

    /// Runs a read on its own connection off the main thread (the command bar's search, as the user types).
    func inBackground<T>(_ read: @escaping (Library) -> T) async -> T {
        await withCheckedContinuation { continuation in
            Self.readQueue.async { continuation.resume(returning: read(self.reader)) }
        }
    }

    /// `hiding` names folders whose bookmarks stay out (another profile's favorites).
    func bookmarks(limit: Int = 8, hiding folders: [String] = []) -> [Entry] {
        let hidden = Self.notIn(folders)
        return rows("SELECT url, title FROM bookmarks WHERE \(hidden.clause) ORDER BY added DESC, id LIMIT ?", hidden.values + [limit])
    }

    private static func notIn(_ folders: [String]) -> (clause: String, values: [Any?]) {
        folders.isEmpty ? ("1", []) : ("folder NOT IN (\(Array(repeating: "?", count: folders.count).joined(separator: ", ")))", folders)
    }

    /// Bookmarks first, then history ranked by visits and recency.
    func search(_ text: String, limit: Int = 6, hiding folders: [String] = []) -> [Entry] {
        let words = text.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let clause = words.map { _ in "(lower(title) LIKE ? OR lower(url) LIKE ?)" }.joined(separator: " AND ")
        let values: [Any?] = words.flatMap { word -> [String] in ["%\(word)%", "%\(word)%"] }
        let hidden = Self.notIn(folders)
        let marks = rows("SELECT url, title FROM bookmarks WHERE \(clause) AND \(hidden.clause) LIMIT ?", values + hidden.values + [limit])
        let recent = rows("""
        SELECT url, title FROM history WHERE \(clause)
        ORDER BY visits * 1.0 / (1 + (strftime('%s','now') - last_visit) / 604800.0) DESC LIMIT ?
        """, values + [limit])
        var seen = Set<String>()
        return (marks + recent).filter { seen.insert($0.url).inserted }.prefix(limit).map { $0 }
    }

    /// A folder with the folders inside it. `key` is the stored folder name ("Arc Bookmarks Bar / Work"); a folder
    /// that holds only folders has no bookmarks of its own but still gets the key its children's names begin with.
    struct Folder: Equatable, Identifiable {
        var key: String
        var label: String
        var entries: [Entry]
        var children: [Folder] = []

        var id: String { key }
        var count: Int { entries.count + children.reduce(0) { $0 + $1.count } }

        /// The folder and every folder inside it, with how deep each one is.
        func flattened(depth: Int = 0) -> [(folder: Folder, depth: Int)] {
            [(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
        }

        /// The folder and every folder inside it, each named by its path from here ("Work › 2026").
        func paths(_ prefix: String = "") -> [(key: String, path: String)] {
            let path = prefix.isEmpty ? label : prefix + " › " + label
            return [(key, path)] + children.flatMap { $0.paths(path) }
        }

        func find(_ key: String) -> Folder? {
            if self.key == key { return self }
            return children.lazy.compactMap { $0.find(key) }.first
        }
    }

    /// Imported folders by the browser they came from (the first word of the folder name), nested by their
    /// " / " paths, in the order they were first imported.
    static func groupBySource(_ folders: [(name: String, entries: [Entry])]) -> [(source: String, folders: [Folder])] {
        final class Node {
            let key: String, label: String
            var entries: [Entry] = []
            var children: [Node] = []
            init(key: String, label: String) { self.key = key; self.label = label }
            func child(_ key: String, _ label: String) -> Node {
                if let found = children.first(where: { $0.key == key }) { return found }
                let node = Node(key: key, label: label)
                children.append(node)
                return node
            }
            var folder: Folder { Folder(key: key, label: label, entries: entries, children: children.map(\.folder)) }
        }
        var order: [String] = []
        var roots: [String: Node] = [:]
        for folder in folders {
            let parts = folder.name.split(separator: " ", maxSplits: 1).map(String.init)
            let source = parts.count == 2 ? parts[0] : String(localized: "Other")
            let path = (parts.count == 2 ? parts[1] : folder.name).components(separatedBy: " / ")
            if roots[source] == nil {
                order.append(source)
                roots[source] = Node(key: "", label: source)
            }
            var node = roots[source]!
            var key = parts.count == 2 ? source + " " : ""
            for (index, name) in path.enumerated() {
                key += (index == 0 ? "" : " / ") + name
                node = node.child(key, name)
            }
            node.entries += folder.entries
        }
        return order.map { ($0, roots[$0]!.children.map(\.folder)) }
    }

    /// Every folder of every source, outermost first.
    static func allFolders(_ sources: [(source: String, folders: [Folder])]) -> [Folder] {
        sources.flatMap { $0.folders.flatMap { $0.flattened().map(\.folder) } }
    }

    var counts: (bookmarks: Int, history: Int) {
        let b = (try? db?.query("SELECT COUNT(*) FROM bookmarks"))?.first?.first as? Int64 ?? 0
        let h = (try? db?.query("SELECT COUNT(*) FROM history"))?.first?.first as? Int64 ?? 0
        return (Int(b), Int(h))
    }

    private func rows(_ sql: String, _ values: [Any?]) -> [Entry] {
        ((try? db?.query(sql, values)) ?? []).compactMap { row in
            guard let url = row[0] as? String else { return nil }
            return Entry(url: url, title: row[1] as? String ?? "")
        }
    }
}
