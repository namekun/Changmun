import CommonCrypto
import Foundation
import Security
import WebKit

/// A browser profile Changmun can import from.
struct ImportSource: Identifiable, Hashable {
    enum Kind: Hashable {
        case chromium(safeStorage: String)
        case safari
    }

    var id: String { directory.path }
    var browser: String
    var profile: String?
    var directory: URL
    var kind: Kind
    /// Picked by default: a browser Changmun knows, not a Chromium-based app found by its files.
    var suggested = true

    var title: String { profile.map { "\(browser) · \($0)" } ?? browser }
    var supportsSecrets: Bool { if case .chromium = kind { return true } else { return false } }
}

struct ImportOptions: Equatable {
    var bookmarks = true
    var history = true
    var passwords = true
    var cookies = true
}

struct ImportReport {
    var source: String
    var bookmarks = 0
    var history = 0
    var passwords = 0
    var cookies = 0
    var problems: [String] = []

    var summary: String {
        var parts: [String] = []
        if bookmarks > 0 { parts.append(String(localized: "Bookmarks \(bookmarks.formatted())")) }
        if history > 0 { parts.append(String(localized: "History \(history.formatted())")) }
        if passwords > 0 { parts.append(String(localized: "Passwords \(passwords.formatted())")) }
        if cookies > 0 { parts.append(String(localized: "Cookies \(cookies.formatted())")) }
        return parts.isEmpty ? String(localized: "No items imported") : parts.joined(separator: " · ")
    }
}

enum BrowserDiscovery {
    /// Chromium browsers by data folder (under Application Support) and keychain item.
    static let known: [(name: String, folder: String, safeStorage: String)] = [
        ("Chrome", "Google/Chrome", "Chrome Safe Storage"),
        ("Arc", "Arc/User Data", "Arc Safe Storage"),
        ("Dia", "Dia/User Data", "Dia Safe Storage"),
        ("Aside", "Aside/User Data", "Aside Safe Storage"),
        ("Aside", "Aside", "Aside Safe Storage"),
        ("Brave", "BraveSoftware/Brave-Browser", "Brave Safe Storage"),
        ("Edge", "Microsoft Edge", "Microsoft Edge Safe Storage"),
        ("Vivaldi", "Vivaldi", "Vivaldi Safe Storage"),
        ("Opera", "com.operasoftware.Opera", "Opera Safe Storage"),
        ("Chromium", "Chromium", "Chromium Safe Storage"),
        ("Comet", "Comet", "Comet Safe Storage"),
        ("Whale", "Naver/Whale", "Whale Safe Storage"),
        ("Whale", "Whale", "Whale Safe Storage"),
    ]

    static func sources(applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                        safariFolder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari")) -> [ImportSource] {
        var roots: [(name: String, url: URL, safeStorage: String, known: Bool)] = []
        var seen = Set<String>()
        for entry in known {
            let url = applicationSupport.appendingPathComponent(entry.folder)
            if isChromiumRoot(url), seen.insert(url.standardizedFileURL.path).inserted { roots.append((entry.name, url, entry.safeStorage, true)) }
        }
        for url in candidateRoots(in: applicationSupport) where seen.insert(url.standardizedFileURL.path).inserted {
            let name = url.lastPathComponent == "User Data" ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent
            roots.append((name, url, "\(name) Safe Storage", false))
        }
        var sources: [ImportSource] = []
        for root in roots {
            var profiles = chromiumProfiles(in: root.url)
            // A Chromium-based app that isn't a browser keeps history but never bookmarks.
            if !root.known { profiles = profiles.filter { FileManager.default.fileExists(atPath: $0.0.appendingPathComponent("Bookmarks").path) } }
            for (directory, name) in profiles {
                sources.append(ImportSource(browser: root.name, profile: profiles.count > 1 ? name : nil, directory: directory,
                                            kind: .chromium(safeStorage: root.safeStorage), suggested: root.known))
            }
        }
        sources.append(ImportSource(browser: "Safari", profile: nil, directory: safariFolder, kind: .safari, suggested: false))
        return sources
    }

    /// Folders one or two levels down that hold a Chromium browser's data (and not just an Electron app's).
    private static func candidateRoots(in folder: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for first in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            for url in [first, first.appendingPathComponent("User Data")] + ((try? fm.contentsOfDirectory(at: first, includingPropertiesForKeys: nil)) ?? []) where isChromiumRoot(url) {
                found.append(url)
            }
        }
        return found
    }

    static func isChromiumRoot(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("Local State").path) else { return false }
        return chromiumProfiles(in: url).contains { profile, _ in
            ["History", "Login Data"].allSatisfy { fm.fileExists(atPath: profile.appendingPathComponent($0).path) }
        }
    }

    static func chromiumProfiles(in root: URL) -> [(URL, String)] {
        let fm = FileManager.default
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (folder, info) in cache { names[folder] = (info as? [String: Any])?["name"] as? String ?? folder }
        }
        let folders = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") || names[$0] != nil }
            .filter { !$0.hasPrefix("__") && !(names[$0] ?? "").hasPrefix("__") }
            .filter { fm.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("History").path) }
            .sorted { $0 == "Default" ? true : ($1 == "Default" ? false : $0.localizedStandardCompare($1) == .orderedAscending) }
        return folders.map { (root.appendingPathComponent($0), names[$0] ?? $0) }
    }
}

// MARK: Chromium

enum ChromiumCrypto {
    /// The AES key Chromium on macOS derives from its keychain password.
    static func key(fromSecret secret: Data) -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        _ = key.withUnsafeMutableBytes { keyBytes in
            secret.withUnsafeBytes { secretBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secretBytes.baseAddress?.assumingMemoryBound(to: CChar.self), secret.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        return key
    }

    /// Decrypts a `v10`/`v11` value; anything without that prefix is stored in the clear.
    static func decrypt(_ blob: Data, key: Data) -> Data? {
        let prefix = blob.prefix(3)
        guard prefix == Data("v10".utf8) || prefix == Data("v11".utf8) else { return blob }
        return crypt(CCOperation(kCCDecrypt), Data(blob.dropFirst(3)), key: key)
    }

    static func encrypt(_ plain: Data, key: Data) -> Data {
        Data("v10".utf8) + (crypt(CCOperation(kCCEncrypt), plain, key: key) ?? Data())
    }

    private static func crypt(_ operation: CCOperation, _ input: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, input.count, out.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written)
    }

    /// The browser's keychain password. macOS asks the user to allow this.
    static func secret(service: String) -> Data? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data { return data }
        query[kSecAttrService as String] = nil
        query[kSecReturnData as String] = nil
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let name = service.replacingOccurrences(of: " Safe Storage", with: "").lowercased()
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]],
              let match = items.compactMap({ $0[kSecAttrService as String] as? String })
                .first(where: { $0.hasSuffix("Safe Storage") && $0.lowercased().contains(name) }), match != service else { return nil }
        return secret(service: match)
    }
}

struct ChromiumImporter {
    let source: ImportSource
    let safeStorage: String
    var keySecret: Data?

    struct Cookie {
        var domain: String, name: String, value: String, path: String
        var expires: Date?, secure: Bool, httpOnly: Bool, sameSite: Int
    }

    static let chromeEpochOffset: Double = 11_644_473_600

    func bookmarks() throws -> [(url: String, title: String, folder: String)] {
        var entries: [(url: String, title: String, folder: String)] = []
        let file = source.directory.appendingPathComponent("Bookmarks")
        if let data = try? Data(contentsOf: file),
           let roots = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["roots"] as? [String: Any] {
            for (key, label) in [("bookmark_bar", String(localized: "Bookmarks Bar")), ("other", String(localized: "Other Bookmarks")), ("synced", String(localized: "Mobile Bookmarks"))] {
                guard let node = roots[key] as? [String: Any] else { continue }
                walk(node, path: [source.browser + " " + label], into: &entries)
            }
        }
        if source.browser == "Arc" { entries += arcSidebar() }
        return entries
    }

    private func walk(_ node: [String: Any], path: [String], into entries: inout [(url: String, title: String, folder: String)]) {
        for child in node["children"] as? [[String: Any]] ?? [] {
            if child["type"] as? String == "url", let url = child["url"] as? String {
                entries.append((url, child["name"] as? String ?? "", path.joined(separator: " / ")))
            } else if child["type"] as? String == "folder" {
                walk(child, path: path + [child["name"] as? String ?? String(localized: "Folder")], into: &entries)
            }
        }
    }

    /// Arc keeps pinned tabs in its sidebar file, not in Bookmarks.
    private func arcSidebar() -> [(url: String, title: String, folder: String)] {
        let file = source.directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("StorableSidebar.json")
        guard let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var entries: [(url: String, title: String, folder: String)] = []
        var seen = Set<String>()
        func visit(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let tab = (dict["data"] as? [String: Any])?["tab"] as? [String: Any], let url = tab["savedURL"] as? String, seen.insert(url).inserted {
                    entries.append((url, dict["title"] as? String ?? tab["savedTitle"] as? String ?? "", "Arc " + String(localized: "Sidebar")))
                }
                dict.values.forEach(visit)
            } else if let array = value as? [Any] {
                array.forEach(visit)
            }
        }
        visit(json)
        return entries
    }

    func history(limit: Int = 50_000) throws -> [(url: String, title: String, visits: Int, lastVisit: Date)] {
        try withCopy(of: "History") { db in
            try db.query("SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT ?", [limit]).compactMap { row in
                guard let url = row[0] as? String else { return nil }
                let micros = Double(row[3] as? Int64 ?? 0)
                return (url, row[1] as? String ?? "", Int(row[2] as? Int64 ?? 1), Date(timeIntervalSince1970: micros / 1_000_000 - Self.chromeEpochOffset))
            }
        }
    }

    func passwords(key: Data) throws -> [(host: String, username: String, password: String)] {
        try withCopy(of: "Login Data") { db in
            try db.query("SELECT origin_url, username_value, password_value FROM logins WHERE blacklisted_by_user = 0").compactMap { row in
                guard let origin = row[0] as? String, let host = URL(string: origin)?.host(), origin.hasPrefix("http"),
                      let blob = row[2] as? Data, let plain = ChromiumCrypto.decrypt(blob, key: key),
                      let password = String(data: plain, encoding: .utf8), !password.isEmpty else { return nil }
                return (host, row[1] as? String ?? "", password)
            }
        }
    }

    func cookies(key: Data, now: Date = Date()) throws -> [Cookie] {
        let name = FileManager.default.fileExists(atPath: source.directory.appendingPathComponent("Network/Cookies").path) ? "Network/Cookies" : "Cookies"
        return try withCopy(of: name) { db in
            let version = Int((try? db.query("SELECT value FROM meta WHERE key = 'version'"))?.first?.first as? String ?? "") ?? 0
            return try db.query("SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite FROM cookies").compactMap { row in
                guard let domain = row[0] as? String, let name = row[1] as? String else { return nil }
                var value = row[2] as? String ?? ""
                if value.isEmpty, let blob = row[3] as? Data, !blob.isEmpty {
                    guard var plain = ChromiumCrypto.decrypt(blob, key: key) else { return nil }
                    if version >= 24 { plain = plain.dropFirst(32) }
                    guard let text = String(data: plain, encoding: .utf8) else { return nil }
                    value = text
                }
                let micros = Double(row[5] as? Int64 ?? 0)
                let expires = micros > 0 ? Date(timeIntervalSince1970: micros / 1_000_000 - Self.chromeEpochOffset) : nil
                if let expires, expires < now { return nil }
                return Cookie(domain: domain, name: name, value: value, path: row[4] as? String ?? "/", expires: expires,
                              secure: row[6] as? Int64 == 1, httpOnly: row[7] as? Int64 == 1, sameSite: Int(row[8] as? Int64 ?? -1))
            }
        }
    }

    private func withCopy<T>(of name: String, _ body: (SQLite) throws -> T) throws -> T {
        try withDatabaseCopy(source.directory.appendingPathComponent(name), body)
    }
}

/// Reads a copy, since the browser may hold the database open (with recent writes in its WAL file).
func withDatabaseCopy<T>(_ original: URL, _ body: (SQLite) throws -> T) throws -> T {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("changmun-import-\(UUID().uuidString)")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let copy = folder.appendingPathComponent("db")
    try fm.copyItem(at: original, to: copy)
    for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: original.path + suffix) {
        try? fm.copyItem(atPath: original.path + suffix, toPath: copy.path + suffix)
    }
    return try body(SQLite(path: copy.path))
}

extension ChromiumImporter.Cookie {
    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: name, .value: value]
        if let expires { properties[.expires] = expires }
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if sameSite == 1 { properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue }
        if sameSite == 2 { properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue }
        return HTTPCookie(properties: properties)
    }
}

// MARK: Safari

enum SafariImporter {
    static func bookmarks(folder: URL) throws -> [(url: String, title: String, folder: String)] {
        let data = try Data(contentsOf: folder.appendingPathComponent("Bookmarks.plist"))
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var entries: [(url: String, title: String, folder: String)] = []
        func walk(_ node: [String: Any], path: [String]) {
            for child in node["Children"] as? [[String: Any]] ?? [] {
                if child["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf", let url = child["URLString"] as? String {
                    entries.append((url, (child["URIDictionary"] as? [String: Any])?["title"] as? String ?? "", path.joined(separator: " / ")))
                } else if child["WebBookmarkType"] as? String == "WebBookmarkTypeList" {
                    let title = child["Title"] as? String ?? String(localized: "Folder")
                    if title == "com.apple.ReadingList" { continue }
                    let label = ["BookmarksBar": String(localized: "Favorites"), "BookmarksMenu": String(localized: "Bookmarks Menu")][title] ?? title
                    walk(child, path: path + [label])
                }
            }
        }
        walk(root, path: ["Safari"])
        return entries
    }

    static func history(folder: URL, limit: Int = 50_000) throws -> [(url: String, title: String, visits: Int, lastVisit: Date)] {
        try withDatabaseCopy(folder.appendingPathComponent("History.db")) { db in try db.query("""
        SELECT i.url, (SELECT title FROM history_visits WHERE history_item = i.id ORDER BY visit_time DESC LIMIT 1), i.visit_count, MAX(v.visit_time)
        FROM history_items i JOIN history_visits v ON v.history_item = i.id GROUP BY i.id ORDER BY MAX(v.visit_time) DESC LIMIT ?
        """, [limit]).compactMap { row in
            guard let url = row[0] as? String else { return nil }
            return (url, row[1] as? String ?? "", Int(row[2] as? Int64 ?? 1), Date(timeIntervalSinceReferenceDate: row[3] as? Double ?? 0))
        } }
    }
}

// MARK: Running an import

enum ImportRunner {
    /// Imports one source. Secrets are read only when passwords or cookies are chosen; macOS asks before handing them over.
    static func run(_ source: ImportSource, options: ImportOptions, library: Library = .shared, progress: @escaping @Sendable (String) -> Void) async -> ImportReport {
        var report = ImportReport(source: source.title)
        switch source.kind {
        case .safari:
            if options.bookmarks {
                progress(String(localized: "Safari bookmarks"))
                do { report.bookmarks = try library.importBookmarks(SafariImporter.bookmarks(folder: source.directory)) }
                catch { report.problems.append(safariProblem(error)) }
            }
            if options.history {
                progress(String(localized: "Safari history"))
                do { report.history = try library.importHistory(SafariImporter.history(folder: source.directory)) }
                catch { report.problems.append(safariProblem(error)) }
            }
        case .chromium(let safeStorage):
            let importer = ChromiumImporter(source: source, safeStorage: safeStorage)
            if options.bookmarks {
                progress(String(localized: "\(source.title) bookmarks"))
                do { report.bookmarks = try library.importBookmarks(importer.bookmarks()) } catch { report.problems.append(String(localized: "Bookmarks: \(error.localizedDescription)")) }
            }
            if options.history {
                progress(String(localized: "\(source.title) history"))
                do { report.history = try library.importHistory(importer.history()) } catch { report.problems.append(String(localized: "History: \(error.localizedDescription)")) }
            }
            if options.passwords || options.cookies {
                progress(String(localized: "Waiting for \(source.browser) Keychain access…"))
                guard let secret = ChromiumCrypto.secret(service: safeStorage) else {
                    report.problems.append(String(localized: "Couldn't read '\(safeStorage)' from the Keychain, so passwords and cookies were skipped. Click 'Allow' in the permission dialog to import them."))
                    return report
                }
                let key = ChromiumCrypto.key(fromSecret: secret)
                if options.passwords {
                    progress(String(localized: "\(source.title) passwords"))
                    do {
                        for login in try importer.passwords(key: key) where Logins.save(host: login.host, username: login.username, password: login.password) {
                            report.passwords += 1
                        }
                    } catch { report.problems.append(String(localized: "Passwords: \(error.localizedDescription)")) }
                }
                if options.cookies {
                    progress(String(localized: "\(source.title) cookies"))
                    do {
                        let cookies = try importer.cookies(key: key).compactMap(\.httpCookie)
                        report.cookies = await store(cookies)
                    } catch { report.problems.append(String(localized: "Cookies: \(error.localizedDescription)")) }
                }
            }
        }
        return report
    }

    @MainActor
    private static func store(_ cookies: [HTTPCookie]) async -> Int {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in cookies { await store.setCookie(cookie) }
        return cookies.count
    }

    static var fullDiskAccessProblem: String {
        String(localized: "Safari data can only be read once Changmun is turned on in System Settings › Privacy & Security › Full Disk Access.")
    }

    private static func safariProblem(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && (nsError.code == NSFileReadNoPermissionError || nsError.code == 257) || "\(error)".contains("authorization") || "\(error)".contains("unable to open") {
            return fullDiskAccessProblem
        }
        return error.localizedDescription
    }
}
