import Foundation

/// A page saved to read later. `url` is the address as `ReadingList.key` writes it, which is what two saves of the same page share.
struct ReadingItem: Equatable, Identifiable {
    var url: String
    var title: String
    var added: Date
    var read: Bool

    var id: String { url }
}

/// The rules of the reading list that need no database: which pages can be saved, what counts as the same page, what a row says.
enum ReadingList {
    /// Longer addresses are not saved (cutting one would save another page).
    static let maxURLLength = 2048

    /// The address a saved page is kept under: web pages only, with no fragment and no slash at the end of the path, so the same page
    /// saved from two links is one item. Everything else about the address (the query, the case of the path) tells pages apart.
    static func key(for address: String?) -> String? {
        guard let address, var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        parts.scheme = scheme
        parts.host = host
        parts.fragment = nil
        if parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path.isEmpty { parts.path = "/" }
        guard let key = parts.string, key.count <= maxURLLength else { return nil }
        return key
    }

    /// The title a saved page is shown with: what it was called (trimmed, cut at `Tab.maxNameLength`), or its site while it has none.
    static func title(_ title: String, for key: String) -> String {
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Tab.maxNameLength))
        return trimmed.isEmpty ? siteName(of: key) : trimmed
    }

    /// The site a saved page is on, as its row names it: the host without a leading "www.".
    static func siteName(of address: String) -> String {
        let host = URL(string: address)?.host() ?? address
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Whether the page in this tab can be saved: not in a private window, and a web page.
    static func canSave(_ address: String?, isPrivate: Bool) -> Bool { !isPrivate && key(for: address) != nil }

    /// Whether a page that has finished loading is a saved page not read yet, which opening it reads. A private window's page is nobody's business.
    static func shouldMarkRead(loaded address: String?, isPrivate: Bool, in items: [ReadingItem]) -> Bool {
        guard !isPrivate, let key = key(for: address) else { return false }
        return items.contains { $0.url == key && !$0.read }
    }

    /// When a page was saved, as a row says it ("2 days ago", "yesterday"), in the language of `locale`.
    static func dateLabel(_ date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

extension Library {
    /// Saves a page to read later; false when it was not added: it is not a web page, or it is saved already (its place and read state stay).
    @discardableResult
    func addToReadingList(url: String, title: String, added: Date = Date()) -> Bool {
        guard let key = ReadingList.key(for: url), let db,
              (try? db.run("INSERT OR IGNORE INTO reading_list (url, title, added, read) VALUES (?, ?, ?, 0)",
                           [key, ReadingList.title(title, for: key), added.timeIntervalSince1970])) != nil,
              Self.changedRows(db) else { return false }
        changed()
        return true
    }

    func removeFromReadingList(url: String) {
        guard let key = ReadingList.key(for: url) else { return }
        try? db?.run("DELETE FROM reading_list WHERE url = ?", [key])
        changed()
    }

    /// Marks a saved page read or unread; false when nothing changed (it is not saved, or is that already).
    @discardableResult
    func markReadingItem(url: String, read: Bool) -> Bool {
        guard let key = ReadingList.key(for: url), let db,
              (try? db.run("UPDATE reading_list SET read = ? WHERE url = ? AND read <> ?", [read ? 1 : 0, key, read ? 1 : 0])) != nil,
              Self.changedRows(db) else { return false }
        changed()
        return true
    }

    /// Takes the pages that are read off the list; returns them, so they can be put back.
    @discardableResult
    func clearReadItems() -> [ReadingItem] {
        let gone = readingList().filter(\.read)
        guard !gone.isEmpty else { return [] }
        try? db?.run("DELETE FROM reading_list WHERE read = 1")
        changed()
        return gone
    }

    /// Puts pages back as they were (undoing a removal), with their dates and read state; those saved again meanwhile are left alone.
    func restoreReadingItems(_ items: [ReadingItem]) {
        guard let db else { return }
        try? db.transaction { for item in items { try Self.insert(item, into: db) } }
        changed()
    }

    /// Adds the pages from another browser's reading list, keeping what is here: a page saved already stays as it is, read state too.
    /// Returns how many were new.
    func importReadingList(_ items: [ReadingItem]) throws -> Int {
        try importing(items) { db, item in try Self.insert(item, into: db) }
    }

    /// The saved pages, newest first.
    func readingList() -> [ReadingItem] { readReadingList() ?? [] }

    /// The saved pages, newest first, or nil when the database can't be read (that must not look like an empty list).
    func readReadingList() -> [ReadingItem]? {
        guard let rows = try? db?.query("SELECT url, title, added, read FROM reading_list ORDER BY added DESC, rowid DESC") else { return nil }
        return rows.compactMap { row in
            guard let url = row[0] as? String else { return nil }
            return ReadingItem(url: url, title: row[1] as? String ?? "", added: Date(timeIntervalSince1970: row[2] as? Double ?? 0),
                               read: (row[3] as? Int64 ?? 0) != 0)
        }
    }

    /// Whether the statement just run on this connection wrote a row.
    private static func changedRows(_ db: SQLite) -> Bool {
        ((try? db.query("SELECT changes()"))?.first?.first as? Int64 ?? 0) > 0
    }

    @discardableResult
    private static func insert(_ item: ReadingItem, into db: SQLite) throws -> Bool {
        guard let key = ReadingList.key(for: item.url) else { return false }
        try db.run("INSERT OR IGNORE INTO reading_list (url, title, added, read) VALUES (?, ?, ?, ?)",
                   [key, ReadingList.title(item.title, for: key), item.added.timeIntervalSince1970, item.read ? 1 : 0])
        return changedRows(db)
    }
}
