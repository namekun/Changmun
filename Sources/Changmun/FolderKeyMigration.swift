import Foundation

/// Renames the imported folders that earlier versions stored under the label of the language the import ran in ("Chrome 북마크 바 / Work")
/// to their canonical names ("Chrome Bookmarks Bar / Work"), everywhere a folder name is kept: the library, the spaces' pinned and
/// open folders, the session's bookmark tabs, and the settings from before spaces. Run at every launch until it has finished once.
///
/// Nothing is changed until the files it will change have been copied (once, beside them, as "<name>-before-folder-keys.<ext>"). The
/// library is changed in one transaction; every step can be repeated, so a launch cut short is finished by the next one. What marks
/// it finished is the library's `user_version`, set last.
enum FolderKeyMigration {
    static let version: Int64 = 1
    static let suffix = "-before-folder-keys"

    /// Returns whether the migration is finished (also when there was nothing to do).
    @discardableResult
    static func run(in folder: URL, defaults: UserDefaults = .standard) -> Bool {
        let manager = FileManager.default
        let libraryFile = folder.appendingPathComponent("library.sqlite")
        // A profile with no library has no imported folders yet; its first import writes the canonical names.
        guard manager.fileExists(atPath: libraryFile.path) else { return false }
        do {
            let db = try SQLite(path: libraryFile.path)
            if let done = try db.query("PRAGMA user_version").first?.first as? Int64, done >= version { return true }

            // Plan everything first, so the copies are made before the first change.
            var renames: [(old: String, new: String)] = []
            if !(try db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'bookmarks'")).isEmpty {
                for row in try db.query("SELECT DISTINCT folder FROM bookmarks WHERE folder <> '' AND substr(folder, 1, 1) <> char(1)") {
                    if let old = row[0] as? String, let new = ImportedFolders.canonicalKey(old) { renames.append((old, new)) }
                }
            }
            let files = try [("spaces.json", spacesValue), ("session.json", sessionValue), ("session-previous.json", sessionValue)].compactMap { name, transform in
                try rewrite(folder.appendingPathComponent(name), transform)
            }
            let legacy = ["pinnedFolders", "openFolders"].compactMap { name -> (name: String, old: [String], new: [String])? in
                guard let old = defaults.stringArray(forKey: name) else { return nil }
                let new = references(old)
                return new == old ? nil : (name, old, new)
            }

            if !renames.isEmpty {
                try copyOnce(to: backup(of: libraryFile)) { partial in
                    do {
                        try db.run("VACUUM INTO ?", [partial.path])
                    } catch {
                        try? manager.removeItem(at: partial)
                        try manager.copyItem(at: libraryFile, to: partial)
                    }
                }
            }
            for file in files {
                try copyOnce(to: backup(of: file.url)) { try manager.copyItem(at: file.url, to: $0) }
            }
            if !legacy.isEmpty {
                let old = Dictionary(uniqueKeysWithValues: legacy.map { ($0.name, $0.old) })
                try copyOnce(to: folder.appendingPathComponent("preferences\(suffix).json")) { try JSONEncoder().encode(old).write(to: $0) }
            }

            try db.transaction {
                for (old, new) in renames {
                    // Moving into a folder that exists already merges: a bookmark whose address is there is left behind, and then removed.
                    try db.run("UPDATE OR IGNORE bookmarks SET folder = ? WHERE folder = ?", [new, old])
                    try db.run("DELETE FROM bookmarks WHERE folder = ?", [old])
                }
            }
            for file in files { try file.data.write(to: file.url, options: .atomic) }
            for item in legacy { defaults.set(item.new, forKey: item.name) }
            try db.execute("PRAGMA user_version = \(version)")
            return true
        } catch {
            NSLog("Changmun: the imported folders could not be renamed this time (they are tried again at the next launch): %@", error.localizedDescription)
            return false
        }
    }

    // MARK: Files

    private static func backup(of file: URL) -> URL {
        let stem = file.deletingPathExtension().lastPathComponent
        return file.deletingLastPathComponent().appendingPathComponent(stem + suffix + "." + file.pathExtension)
    }

    /// Writes the copy under another name and renames it when whole, so a copy cut short is never taken for one; an existing copy
    /// (the first one, from before anything changed) stays.
    private static func copyOnce(to copy: URL, _ make: (URL) throws -> Void) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: copy.path) else { return }
        let partial = copy.appendingPathExtension("partial")
        try? manager.removeItem(at: partial)
        do {
            try make(partial)
            try manager.moveItem(at: partial, to: copy)
        } catch {
            try? manager.removeItem(at: partial)
            throw error
        }
    }

    /// A JSON file with the names in it rewritten; nil when it isn't there, isn't JSON (the app deals with a damaged file itself), or
    /// holds no name to change. An unreadable file stops the migration, which is tried again at the next launch.
    private static func rewrite(_ url: URL, _ transform: (String, Any) -> Any?) throws -> (url: URL, data: Data)? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileReadNoSuchFileError { return nil }
            throw error
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var changed = false
        let rewritten = map(json, changed: &changed, transform)
        guard changed else { return nil }
        return (url, try JSONSerialization.data(withJSONObject: rewritten, options: [.withoutEscapingSlashes]))
    }

    /// Visits every value of the JSON; `transform` is given a dictionary's key and value and returns the value to put there, or nil to leave it.
    private static func map(_ value: Any, changed: inout Bool, _ transform: (String, Any) -> Any?) -> Any {
        if var dictionary = value as? [String: Any] {
            for (key, inner) in dictionary {
                if let replaced = transform(key, inner) {
                    dictionary[key] = replaced
                    changed = true
                } else {
                    dictionary[key] = map(inner, changed: &changed, transform)
                }
            }
            return dictionary
        }
        if let array = value as? [Any] { return array.map { map($0, changed: &changed, transform) } }
        return value
    }

    // MARK: Names

    /// A pinned or open folder: "pin:" in front of it when it is open where the pinned folders are. "source:Chrome" is no folder.
    private static func reference(_ entry: String) -> String {
        if entry.hasPrefix("pin:") {
            let folder = String(entry.dropFirst(4))
            return "pin:" + (ImportedFolders.canonicalKey(folder) ?? folder)
        }
        return ImportedFolders.canonicalKey(entry) ?? entry
    }

    /// The list with its names changed, and an entry that is there twice now (a folder imported in two languages) once, at the first place.
    private static func references(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.map(reference).filter { seen.insert($0).inserted }
    }

    private static func spacesValue(_ key: String, _ value: Any) -> Any? {
        guard key == "pinnedFolders" || key == "openFolders", let list = value as? [String] else { return nil }
        let new = references(list)
        return new == list ? nil : new
    }

    /// A tab's `bookmarkKey` is "<folder>\n<address>". When two tabs of one space name the same bookmark only because of a rename (it was in
    /// both folders), the later one is an ordinary tab, as a space never has two for one bookmark.
    private static func sessionValue(_ key: String, _ value: Any) -> Any? {
        guard key == "tabs", let tabs = value as? [[String: Any]] else { return nil }
        func slot(_ tab: [String: Any], _ key: String) -> String { "\(tab["space"] as? String ?? "")\n\(key)" }
        let renamed = tabs.map { tab -> String? in
            guard let old = tab["bookmarkKey"] as? String, let newline = old.firstIndex(of: "\n"),
                  let folder = ImportedFolders.canonicalKey(String(old[..<newline])) else { return nil }
            return folder + old[newline...]
        }
        guard renamed.contains(where: { $0 != nil }) else { return nil }
        let touched = Set(zip(tabs, renamed).compactMap { tab, new in new.map { slot(tab, $0) } })
        var bound = Set<String>()
        return zip(tabs, renamed).map { tab, new -> [String: Any] in
            var tab = tab
            guard let key = new ?? tab["bookmarkKey"] as? String else { return tab }
            if !bound.insert(slot(tab, key)).inserted && touched.contains(slot(tab, key)) {
                tab["bookmarkKey"] = nil
            } else if let new {
                tab["bookmarkKey"] = new
            }
            return tab
        }
    }
}
