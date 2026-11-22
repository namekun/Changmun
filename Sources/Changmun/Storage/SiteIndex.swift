import Foundation

/// The sites of the bookmarks and the history, by name, for the address bar's top hit: typing the start of a site's name ("git") puts the
/// site (github.com) first, where Return opens it, and the field completes the rest of the name.
///
/// Only the start of the name counts, never a word inside it or its path: `nike shoes`, `how to` and `hub` are searches still.
struct SiteIndex: Equatable {
    struct Site: Equatable {
        /// The name, in lower case and without "www.".
        var host: String
        /// The page Return opens.
        var url: String
        var title: String
        /// Its visits, each weighed by how recent it is as the history's own ranking does, over all of its pages.
        var score: Double = 0
        /// `url` is the site's front page, which has been visited: that is what typing the name means, more than its busiest page.
        var root = false
        /// A bookmark's folder, which a window may hide (another profile's favorites); nil for the history.
        var folder: String?
    }

    /// One per site, the most visited first.
    var visited: [Site] = []
    /// One per bookmark, the shortest address first.
    var bookmarked: [Site] = []

    /// The start of a site's name in what is typed: one word, no path, in lower case, with a "www." it starts with taken off; nil for anything else.
    static func name(_ typed: String) -> String? {
        let text = typed.lowercased()
        guard !text.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        let name = text.hasPrefix("www.") ? String(text.dropFirst(4)) : text
        return name.isEmpty ? nil : name
    }

    /// The site whose name `typed` is the start of: the most visited one, else a bookmarked one (the only kind a private window, `history`
    /// false, goes by). The whole name typed is no hit: the address opens as it is. Of the site, the front page when it has been visited,
    /// else the shortest bookmark of it, else its most visited page.
    func hit(for typed: String, history: Bool = true, hiding: [String] = []) -> Site? {
        guard let name = Self.name(typed) else { return nil }
        func starts(_ site: Site) -> Bool { site.host.count > name.count && site.host.hasPrefix(name) }
        func shown(_ site: Site) -> Bool { !hiding.contains(site.folder ?? "") }
        let visit = history ? visited.first(where: starts) : nil
        guard let host = visit?.host ?? bookmarked.first(where: { starts($0) && shown($0) })?.host else { return nil }
        if let visit, visit.root { return visit }
        return bookmarked.first { $0.host == host && shown($0) } ?? visit
    }

    /// The rest of the site's name after what is typed, which the field fills in: "hub.com" for "git" (and for "www.git").
    static func completion(of typed: String, to site: Site) -> String? {
        guard let name = name(typed), site.host.count > name.count, site.host.hasPrefix(name) else { return nil }
        return String(site.host.dropFirst(name.count))
    }
}

extension Library {
    /// A row's name and how much of its address that is: `rest` is the address after "://" in lower case, `host` the part of it before
    /// the path, the query or the fragment, and `site` the host without "www.".
    private static let named = """
    named AS (SELECT *, substr(rest, 1, instr(replace(replace(rest, '?', '/'), '#', '/') || '/', '/') - 1) AS host FROM pages),
    sites AS (SELECT *, CASE WHEN host LIKE 'www.%' THEN substr(host, 5) ELSE host END AS site FROM named WHERE host <> '')
    """

    /// Every site of the history and the bookmarks (web pages only), for `SiteIndex`. Reads all of the history: off the main thread
    /// (`sitesInBackground`).
    func sites(now: Date = Date()) -> SiteIndex {
        guard let db else { return SiteIndex() }
        // Of a site, the row whose `rank` is highest: the front page when it is there (its address is the host with at most a "/"), else the busiest page.
        let visited = (try? db.query("""
        WITH pages AS (SELECT url, title, visits * 1.0 / (1 + (? - last_visit) / 604800.0) AS score, lower(substr(url, instr(url, '://') + 3)) AS rest
                       FROM history WHERE url LIKE 'http%://%'),
        \(Self.named)
        SELECT site, SUM(score), url, title, MAX((length(rest) <= length(host) + 1) * 1e12 + score) FROM sites GROUP BY site
        ORDER BY SUM(score) DESC, length(site)
        """, [now.timeIntervalSince1970])) ?? []
        let bookmarked = (try? db.query("""
        WITH pages AS (SELECT url, title, folder, lower(substr(url, instr(url, '://') + 3)) AS rest FROM bookmarks WHERE url LIKE 'http%://%'),
        \(Self.named)
        SELECT site, url, title, folder FROM sites ORDER BY length(url), url
        """)) ?? []
        return SiteIndex(
            visited: visited.compactMap { row in
                guard let host = row[0] as? String, let url = row[2] as? String else { return nil }
                let score = (row[1] as? Double) ?? 0
                return SiteIndex.Site(host: host, url: url, title: row[3] as? String ?? "", score: score, root: (row[4] as? Double ?? 0) >= 1e12)
            },
            bookmarked: bookmarked.compactMap { row in
                guard let host = row[0] as? String, let url = row[1] as? String else { return nil }
                return SiteIndex.Site(host: host, url: url, title: row[2] as? String ?? "", folder: row[3] as? String ?? "")
            })
    }
}
