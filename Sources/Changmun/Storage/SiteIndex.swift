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

        /// The site's front page, at the scheme and name (with any "www.") it was visited at: what Return opens while the field shows
        /// the name filled in, which is the site and not one of its pages.
        var frontPage: Site {
            guard !root, var parts = URLComponents(string: url), parts.host != nil else { return self }
            parts.user = nil
            parts.password = nil
            parts.path = "/"
            parts.query = nil
            parts.fragment = nil
            guard let front = parts.string else { return self }
            return Site(host: host, url: front, title: "", score: score, root: true, folder: folder)
        }
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
    /// false, goes by). Of the site, the front page when it has been visited, else the shortest bookmark of it, else its most visited page.
    ///
    /// A name typed whole that is a site of its own (`github.com`, `localhost`) is no hit, even when a longer name starts with it
    /// (github.community, localhost:3000): the address opens as typed. And what is typed has to reach into the site's own domain
    /// (`completes`): any page the user was ever sent to is in the history, redirects included, so a stranger's name could otherwise be offered.
    func hit(for typed: String, history: Bool = true, hiding: [String] = []) -> Site? {
        guard let name = Self.name(typed) else { return nil }
        func shown(_ site: Site) -> Bool { site.folder.map { !hiding.contains($0) } ?? true }
        let visits = history ? visited : []
        if visits.contains(where: { $0.host == name }) || bookmarked.contains(where: { $0.host == name && shown($0) }) { return nil }
        let visit = visits.first { Self.completes(name, to: $0.host) }
        guard let host = visit?.host ?? bookmarked.first(where: { Self.completes(name, to: $0.host) && shown($0) })?.host else { return nil }
        if let visit, visit.root { return visit }
        return bookmarked.first { $0.host == host && shown($0) } ?? visit
    }

    /// The rest of the site's name after what is typed, which the field fills in: "hub.com" for "git" (and for "www.git").
    static func completion(of typed: String, to site: Site) -> String? {
        guard let name = name(typed), completes(name, to: site.host) else { return nil }
        return String(decoding: site.host.utf8.dropFirst(name.utf8.count), as: UTF8.self)
    }

    /// Whether `name` is the start of `host` and reaches into its registrable domain (the part a registrar hands out: github.com,
    /// naver.co.kr), not only into the labels in front of it, which whoever holds that domain names as they like: `git` completes to
    /// github.com but not to github.com.evil.example, `naver` not to naver.evil.com, `mail.goo` to mail.google.com (and `mail` not).
    ///
    ///
    /// And a name typed whole that is a site of its own (github.com) never completes to another site's host that merely starts with it:
    /// under a suffix anyone can register below, github.com.s3.amazonaws.com, github.com.workers.dev and github.com-login.pages.dev
    /// are strangers' sites. What is typed counts as whole when the host goes on with "." or "-" right after it (`mail.goo` is the
    /// start of a word of mail.google.com, not a name of its own), and is let through only when it is the host's site, or when it
    /// already reaches past the host's own name into its suffix (`shop.naver.co` on its way to shop.naver.co.kr).
    static func completes(_ name: String, to host: String) -> Bool {
        guard host.utf8.starts(with: name.utf8), host.utf8.count > name.utf8.count, isHostName(host),
              let start = registrableStart(host), name.utf8.count > start else { return false }
        let next = host.utf8[host.utf8.index(host.utf8.startIndex, offsetBy: name.utf8.count)]
        guard next == UInt8(ascii: ".") || next == UInt8(ascii: "-"), let list = PublicSuffix.list, let typed = list.registrableDomain(name) else { return true }
        let bare = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
        guard let site = list.registrableDomain(bare), let siteLabels = list.registrableLabelCount(bare) else { return false }
        if typed == site { return true }
        // The labels typed, the last one perhaps cut at a "-", against where the host's own name (the label before its suffix) is.
        let ownName = bare.split(separator: ".").count - siteLabels
        return name.split(separator: ".").count > ownName + 1
    }

    /// Only what a host name and its port are made of. The name is cut from the address as text, so one with a user name in it
    /// (`https://github.com@evil.example/`) would read as "github.com@evil.example", and `github.com` would complete to it.
    static func isHostName(_ host: String) -> Bool {
        !host.isEmpty && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" || $0 == "[" || $0 == "]" }
    }

    /// Where in `host` (in UTF-8 bytes) its registrable domain starts, by the Public Suffix List (`PublicSuffix`): the suffix and one
    /// label more, so github.io's users' sites (alice.github.io) are each a domain of their own. A name with no dot (localhost), an IP
    /// address, a bracketed IPv6 one and a name that is a public suffix itself are a domain whole; a port doesn't count. Without the
    /// list the last label alone is taken for the domain, which errs toward offering less, never a stranger's name. nil for a name
    /// with an empty label (`a..b`, a dot at the end), which nothing completes to.
    static func registrableStart(_ host: String) -> Int? {
        guard !host.hasPrefix("[") else { return 0 }
        let name = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(host)
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.contains(where: \.isEmpty) else { return nil }
        guard labels.count > 1, !name.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return 0 }
        let kept = PublicSuffix.list.map { $0.registrableLabelCount(String(name)) ?? labels.count } ?? 1
        return labels.dropLast(kept).reduce(0) { $0 + $1.utf8.count + 1 }
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
