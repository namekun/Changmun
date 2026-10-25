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

    /// The user's data folder, for the app and for the headless apps only. Anything else (the test runner, a bare
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
            .appendingPathComponent(Headless.profileName(forBundle: bundleID) ?? "Changmun", isDirectory: true)
    }

    /// What reading a data file gave: nothing yet, its bytes, or an error (permissions, a disk fault) that says nothing about what it holds.
    enum FileRead {
        case missing, unreadable
        case data(Data)

        init(_ file: URL) {
            do {
                self = .data(try Data(contentsOf: file))
            } catch {
                let nsError = error as NSError
                self = nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError ? .missing : .unreadable
            }
        }
    }

    /// Copies a file that couldn't be read whole to "<name>-damaged-<time>.<ext>" beside it, so starting over never costs what it held.
    /// The same damage found again at the next launch is not copied again, and only the newest `damagedCopies` copies are kept.
    /// Returns whether a copy of it is there.
    static func keepDamaged(_ file: URL) -> Bool {
        let manager = FileManager.default
        let folder = file.deletingLastPathComponent()
        let stem = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        /// The copies beside it, oldest first: by the time in the name, then by the number after it.
        func copies() -> [(order: [Int], url: URL)] {
            var found: [(order: [Int], url: URL)] = []
            for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("\(stem)-damaged-") && name.hasSuffix(suffix) {
                let parts = name.dropFirst("\(stem)-damaged-".count).dropLast(suffix.count).split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
                if (1...2).contains(parts.count), !parts.contains(nil) { found.append((parts.compactMap { $0 }, folder.appendingPathComponent(name))) }
            }
            return found.sorted { $0.order.lexicographicallyPrecedes($1.order) }
        }
        let damaged = try? Data(contentsOf: file)
        if let damaged, copies().contains(where: { (try? Data(contentsOf: $0.url)) == damaged }) { return true }
        // Named after the newest copy there is, so a copy never takes the place (and the age) of an older one that was pruned.
        var time = Int(Date().timeIntervalSince1970), attempt = 0
        if let last = copies().last?.order, last[0] >= time {
            time = last[0]
            attempt = (last.count > 1 ? last[1] : 0) + 1
        }
        let copy = folder.appendingPathComponent("\(stem)-damaged-\(time)" + (attempt == 0 ? "" : "-\(attempt)") + suffix)
        guard (try? manager.copyItem(at: file, to: copy)) != nil else { return false }
        for old in copies().dropLast(damagedCopies) { try? manager.removeItem(at: old.url) }
        return true
    }

    static let damagedCopies = 3

    struct Entry: Equatable {
        var url: String
        var title: String
    }

    private let db: SQLite?
    private let path: String
    /// Why the database can't be used (it wouldn't open, or its bookmarks couldn't be brought up to date), or nil. Every write
    /// then fails without a word, so the app tells the user once.
    private(set) var problem: String?
    /// How the favorites are ordered: by their positions, or by when they were added while the database has no position column to read.
    private let favoriteOrder: String

    init(path: String) {
        self.path = path
        var opened: SQLite?
        var ordered = false
        do {
            let db = try SQLite(path: path)
            opened = db
            db.addFunction("fold", Self.fold)
            // One statement at a time, each allowed to fail (a read-only file, a full disk, a lock that times out): the library
            // is still read from what is there. Only a database that won't open at all, or whose order column can't be added, is a problem.
            for statement in [
                "PRAGMA journal_mode=WAL",
                "PRAGMA synchronous=NORMAL",
                "CREATE TABLE IF NOT EXISTS history (url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', visits INTEGER NOT NULL DEFAULT 1, last_visit REAL NOT NULL)",
                "CREATE TABLE IF NOT EXISTS bookmarks (id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', folder TEXT NOT NULL DEFAULT '', added REAL NOT NULL, position REAL, UNIQUE(url, folder))",
                "CREATE INDEX IF NOT EXISTS history_recent ON history(last_visit DESC)",
            ] {
                do { try db.execute(statement) } catch { NSLog("Changmun: the library at %@ could not run \"%@\": %@", path, statement, error.localizedDescription) }
            }
            do {
                try Self.addPositionColumn(db)
            } catch {
                problem = error.localizedDescription
                NSLog("Changmun: the library at %@ could not be brought up to date: %@", path, error.localizedDescription)
            }
            ordered = (try? db.query("PRAGMA table_info(bookmarks)").contains { $0[1] as? String == "position" }) ?? false
        } catch {
            opened = nil
            problem = error.localizedDescription
            NSLog("Changmun: the library at %@ can't be used: %@", path, error.localizedDescription)
        }
        db = opened
        favoriteOrder = ordered ? Self.byPosition : "added, id"
    }

    /// Bookmarks had their order in `added`, which a move of a favorite overwrote with positions (so "recent bookmarks" was wrong).
    /// The order has a column of its own, set from the order the favorites are in now; `added` is left as it is.
    private static func addPositionColumn(_ db: SQLite) throws {
        func hasPosition() throws -> Bool {
            try db.query("PRAGMA table_info(bookmarks)").contains { $0[1] as? String == "position" }
        }
        guard try !hasPosition() else { return }
        do {
            try db.transaction {
                try db.execute("ALTER TABLE bookmarks ADD COLUMN position REAL")
                try db.execute("""
                UPDATE bookmarks SET position = ordered.place FROM
                  (SELECT id, ROW_NUMBER() OVER (PARTITION BY folder ORDER BY added, id) - 1 AS place FROM bookmarks) AS ordered
                WHERE ordered.id = bookmarks.id
                """)
            }
        } catch {
            // Another connection (a background read opening the library at the same moment) did it first.
            guard try hasPosition() else { throw error }
        }
    }

    /// Where bookmarks put at the end of the folder start: after those in it, which are numbered (in the order they show) first.
    private static func nextPosition(_ db: SQLite, in folder: String) throws -> Double {
        try db.run("""
        UPDATE bookmarks SET position = ordered.place FROM
          (SELECT id, ROW_NUMBER() OVER (ORDER BY \(byPosition)) - 1 AS place FROM bookmarks WHERE folder = ?) AS ordered
        WHERE ordered.id = bookmarks.id
        """, [folder])
        return (try db.query("SELECT MAX(position) FROM bookmarks WHERE folder = ?", [folder]).first?.first as? Double).map { $0 + 1 } ?? 0
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
        try? db?.run("DELETE FROM bookmarks WHERE folder = ? OR substr(folder, 1, ?) = ?", [folder, (folder + " / ").unicodeScalars.count, folder + " / "])
        changed()
    }

    /// Removes everything imported from one browser (folders named "<source> …").
    func removeSource(_ source: String) {
        guard !source.isEmpty else { return }
        // Compared as it is written, not with LIKE, which ignores the case of ASCII letters: "Arc" must not take a folder named "arc …".
        try? db?.run("DELETE FROM bookmarks WHERE folder <> '' AND (folder = ? OR substr(folder, 1, ?) = ?)", [source, (source + " ").unicodeScalars.count, source + " "])
        changed()
    }

    /// The condition that the title or the address of a row has every word in it, with its values. `%` and `_` in a word are plain characters.
    /// LIKE ignores case for ASCII letters only, so a word with cased letters beyond ASCII (é, Ж) is compared as Swift folds it, both sides.
    private static func containing(_ words: [String]) -> (clause: String, values: [Any?]) {
        guard !words.isEmpty else { return ("1", []) }
        var parts: [String] = []
        var values: [Any?] = []
        for word in words {
            let folded = word.contains { !$0.isASCII && $0.isCased }
            let pattern = "%" + likeEscaped(folded ? fold(word) : word) + "%"
            let (title, url) = folded ? ("fold(title)", "fold(url)") : ("title", "url")
            parts.append("(\(title) LIKE ? ESCAPE '\\' OR \(url) LIKE ? ESCAPE '\\')")
            values += [pattern, pattern]
        }
        return (parts.joined(separator: " AND "), values)
    }

    static func fold(_ text: String) -> String { text.folding(options: .caseInsensitive, locale: nil) }

    static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    func removeBookmark(url: String, folder: String) {
        try? db?.run("DELETE FROM bookmarks WHERE url = ? AND folder = ?", [url, folder])
        changed()
    }

    /// The bookmarks pinned in a space's tile grid: the ones added in Changmun itself.
    func favorites(in folder: String = Library.favoritesFolder) -> [Entry] {
        rows("SELECT url, title FROM bookmarks WHERE folder = ? ORDER BY \(favoriteOrder)", [folder])
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
        guard let favorites = try? db.query("SELECT folder, url, title FROM bookmarks WHERE folder = '' OR substr(folder, 1, 1) = char(1) ORDER BY \(favoriteOrder)"),
              let folders = try? db.query(Self.foldersQuery) else { return nil }
        var byFolder: [String: [Entry]] = [:]
        for row in favorites {
            guard let folder = row[0] as? String, let url = row[1] as? String else { continue }
            byFolder[folder, default: []].append(Entry(url: url, title: row[2] as? String ?? ""))
        }
        return (byFolder, Self.grouped(folders))
    }

    /// Favorites in the order the user put them in; those without a position yet (added since) come after, in the order they were added.
    private static let byPosition = "position IS NULL, position, added, id"

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

    /// Whether the address was visited, or bookmarked, before `date` (a page visited again since then was not only visited before).
    func knowsURL(_ url: String, before date: Date) -> Bool {
        let time = date.timeIntervalSince1970
        return !((try? db?.query("SELECT 1 FROM history WHERE url = ? AND last_visit < ? UNION ALL SELECT 1 FROM bookmarks WHERE url = ? AND added < ? LIMIT 1", [url, time, url, time])) ?? []).isEmpty
    }

    /// The hosts of every address in the history and the bookmarks; nil when the database can't be read (that must not look like none).
    func knownHosts() -> Set<String>? {
        guard let rows = try? db?.query("SELECT url FROM history UNION SELECT url FROM bookmarks") else { return nil }
        return Set(rows.compactMap { ($0[0] as? String).flatMap { URL(string: $0)?.host()?.lowercased() } })
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
        let (clause, values) = Self.containing(text.lowercased().split(separator: " ").map(String.init))
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

    /// Moves a favorite to just before another one (dropping it on that tile, where the drop line shows), or to the end.
    func moveFavorite(_ url: String, to target: String?, in folder: String = Library.favoritesFolder) {
        let original = favorites(in: folder).map(\.url)
        guard let from = original.firstIndex(of: url), url != target else { return }
        var order = original
        order.remove(at: from)
        if let target, let to = order.firstIndex(of: target) {
            order.insert(url, at: to)
        } else {
            order.append(url)
        }
        guard let db else { return }
        try? db.transaction {
            for (position, item) in order.enumerated() {
                try db.run("UPDATE bookmarks SET position = ? WHERE url = ? AND folder = ?", [Double(position), item, folder])
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
                // They keep their order, after what is in the other space already.
                let start = try Self.nextPosition(db, in: to)
                try db.run("INSERT OR IGNORE INTO bookmarks (url, title, folder, added, position) SELECT url, title, ?, added, position + ? FROM bookmarks WHERE folder = ?",
                           [to, start, from])
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
        let (clause, values) = Self.containing(words)
        let hidden = Self.notIn(folders)
        let marks = rows("SELECT url, title FROM bookmarks WHERE \(clause) AND \(hidden.clause) LIMIT ?", values + hidden.values + [limit])
        let recent = rows("""
        SELECT url, title FROM history WHERE \(clause)
        ORDER BY visits * 1.0 / (1 + (strftime('%s','now') - last_visit) / 604800.0) DESC LIMIT ?
        """, values + [limit])
        var seen = Set<String>()
        return (marks + recent).filter { seen.insert($0.url).inserted }.prefix(limit).map { $0 }
    }

    /// A folder with the folders inside it. `key` is the stored folder name ("Arc Bookmarks Bar / Work", whatever the language); a folder
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
    /// A folder's label is its name, except that the part naming where in the other browser it was ("Bookmarks Bar") is translated by `section`.
    static func groupBySource(_ folders: [(name: String, entries: [Entry])], section: (String) -> String = ImportedFolders.localized) -> [(source: String, folders: [Folder])] {
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
                // The part of the key after the browser's name, in the language shown.
                let label = index == 0 && parts.count == 2 ? String(ImportedFolders.displayKey(key, translate: section).dropFirst(source.count + 1)) : name
                node = node.child(key, label)
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
