import Foundation

/// Bookmarks and history, in one SQLite file under Application Support. The main connection is used on the main
/// thread; imports and background reads each open their own.
final class Library: @unchecked Sendable {
    static let didChange = Notification.Name("ChangmunLibraryDidChange")
    static let favoritesFolder = ""
    static let shared = Library(path: Library.folder.appendingPathComponent("library.sqlite").path)

    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Changmun", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    /// Whether the page is in the sidebar's favorites (imported folders don't count).
    func isFavorite(_ url: String) -> Bool {
        ((try? db?.query("SELECT 1 FROM bookmarks WHERE url = ? AND folder = '' LIMIT 1", [url])) ?? []).isEmpty == false
    }

    /// Adds the page to the favorites or takes it out; returns whether it is a favorite now.
    func toggleBookmark(url: String, title: String) -> Bool {
        defer { changed() }
        if isFavorite(url) {
            try? db?.run("DELETE FROM bookmarks WHERE url = ? AND folder = ''", [url])
            return false
        }
        try? db?.run("INSERT OR IGNORE INTO bookmarks (url, title, folder, added) VALUES (?, ?, '', ?)", [url, title, Date().timeIntervalSince1970])
        return true
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

    /// The bookmarks pinned in the sidebar's tile grid: the ones added in Changmun itself.
    func favorites() -> [Entry] {
        rows("SELECT url, title FROM bookmarks WHERE folder = '' ORDER BY added, id", [])
    }

    /// Imported bookmarks grouped by folder, folders in the order they were first imported.
    func folders() -> [(name: String, entries: [Entry])] {
        let all = ((try? db?.query("SELECT folder, url, title FROM bookmarks WHERE folder <> '' ORDER BY id")) ?? [])
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
    func moveFavorite(_ url: String, to target: String?) {
        let original = favorites().map(\.url)
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
                try db.run("UPDATE bookmarks SET added = ? WHERE url = ? AND folder = ''", [Double(position), item])
            }
        }
        changed()
    }

    /// Reads on a queue of their own, away from the main thread.
    private static let readQueue = DispatchQueue(label: "Changmun.library.read", qos: .userInitiated)
    private lazy var reader = Library(path: path)

    /// Runs a read on its own connection off the main thread (the command bar's search, as the user types).
    func inBackground<T>(_ read: @escaping (Library) -> T) async -> T {
        await withCheckedContinuation { continuation in
            Self.readQueue.async { continuation.resume(returning: read(self.reader)) }
        }
    }

    func bookmarks(limit: Int = 8) -> [Entry] {
        rows("SELECT url, title FROM bookmarks ORDER BY added DESC, id LIMIT ?", [limit])
    }

    /// Bookmarks first, then history ranked by visits and recency.
    func search(_ text: String, limit: Int = 6) -> [Entry] {
        let words = text.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let clause = words.map { _ in "(lower(title) LIKE ? OR lower(url) LIKE ?)" }.joined(separator: " AND ")
        let values: [Any?] = words.flatMap { word -> [String] in ["%\(word)%", "%\(word)%"] }
        let marks = rows("SELECT url, title FROM bookmarks WHERE \(clause) LIMIT ?", values + [limit])
        let recent = rows("""
        SELECT url, title FROM history WHERE \(clause)
        ORDER BY visits * 1.0 / (1 + (strftime('%s','now') - last_visit) / 604800.0) DESC LIMIT ?
        """, values + [limit])
        var seen = Set<String>()
        return (marks + recent).filter { seen.insert($0.url).inserted }.prefix(limit).map { $0 }
    }

    struct Folder: Equatable {
        var key: String
        var label: String
        var entries: [Entry]
    }

    /// Imported folders grouped by the browser they came from (the first word of the folder path),
    /// each labelled by the last folder in its path.
    static func groupBySource(_ folders: [(name: String, entries: [Entry])]) -> [(source: String, folders: [Folder])] {
        var order: [String] = []
        var groups: [String: [Folder]] = [:]
        for folder in folders {
            let parts = folder.name.split(separator: " ", maxSplits: 1).map(String.init)
            let source = parts.count == 2 ? parts[0] : "기타"
            let path = parts.count == 2 ? parts[1] : folder.name
            let label = path.components(separatedBy: " / ").last ?? path
            if groups[source] == nil { order.append(source) }
            groups[source, default: []].append(Folder(key: folder.name, label: label, entries: folder.entries))
        }
        return order.map { ($0, groups[$0] ?? []) }
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
