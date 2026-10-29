import Foundation
import Testing
@testable import Changmun

/// A folder of its own for each test, so nothing here touches the user's data.
func persistenceScratchFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("persistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func damagedCopies(in folder: URL, of name: String) throws -> [URL] {
    let stem = (name as NSString).deletingPathExtension
    return try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("\(stem)-damaged-") }.map { folder.appendingPathComponent($0) }
}

@MainActor
struct DataFileSafetyTests {
    // MARK: Tab archive

    @Test func aDamagedArchiveIsKeptBeforeAnythingIsWrittenOverIt() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("archive.json")
        try Data("not json {".utf8).write(to: file)
        let archive = TabArchive(file: file)
        #expect(archive.entries.isEmpty)
        archive.add([TabArchive.Entry(url: "https://new.example/", title: "New", archived: Date())])
        let kept = try damagedCopies(in: folder, of: "archive.json")
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: try #require(kept.first)) == Data("not json {".utf8))
        #expect(TabArchive(file: file).entries.map(\.url) == ["https://new.example/"])
    }

    @Test func theSameDamageFoundAtEveryLaunchIsKeptOnceAndOnlyTheNewestCopiesStay() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("archive.json")
        try Data("not json {".utf8).write(to: file)
        for _ in 0..<4 { #expect(Library.keepDamaged(file)) }
        #expect(try damagedCopies(in: folder, of: "archive.json").count == 1, "the same damage again is no new copy")
        for n in 0..<6 {
            try Data("broken \(n)".utf8).write(to: file)
            #expect(Library.keepDamaged(file))
        }
        let kept = try damagedCopies(in: folder, of: "archive.json")
        #expect(kept.count == Library.damagedCopies)
        let contents = try kept.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }.sorted()
        #expect(contents == ["broken 3", "broken 4", "broken 5"], "the newest are the ones kept: \(contents)")
    }

    @Test func anArchiveEntryThatDoesNotDecodeDoesNotTakeTheOthersWithIt() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("archive.json")
        let good = TabArchive.Entry(url: "https://good.example/", title: "Good", archived: Date(timeIntervalSince1970: 1_700_000_000))
        var entries = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode([good])) as? [[String: Any]])
        entries.append(["url": 5])
        let original = try JSONSerialization.data(withJSONObject: entries)
        try original.write(to: file)
        let archive = TabArchive(file: file)
        #expect(archive.entries.map(\.url) == ["https://good.example/"])
        let kept = try damagedCopies(in: folder, of: "archive.json")
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: try #require(kept.first)) == original, "what could not be read is kept")
    }

    @Test func anArchiveThatCannotBeReadIsNeverWrittenOver() throws {
        let folder = try persistenceScratchFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appendingPathComponent("archive.json").path)
            try? FileManager.default.removeItem(at: folder)
        }
        let file = folder.appendingPathComponent("archive.json")
        let original = Data(#"[{"url":"https://a.example/","title":"A","archived":0,"id":"\#(UUID())"}]"#.utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        let archive = TabArchive(file: file)
        archive.add([TabArchive.Entry(url: "https://new.example/", title: "New", archived: Date())])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func tabsStayOpenWhenTheArchiveCannotBeSaved() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("archive.json")
        try Data("not json {".utf8).write(to: file)
        // The archive's folder is a file, so nothing can be written there.
        let blocker = folder.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let archive = TabArchive(file: blocker.appendingPathComponent("archive.json"))
        let b = Browser()
        defer { b.windowClosed() }
        let shown = b.openTab(url: URL(string: "https://shown.example/"))
        let old = b.openTab(url: URL(string: "https://old.example/"), activate: false)
        for tab in [shown, old] { tab.lastShown = Date(timeIntervalSinceNow: -3 * 86400) }
        b.archiveIdleTabs(olderThan: 86400, to: archive)
        #expect(b.tabs.map(\.id) == [shown.id, old.id], "the tab is still open: it was not saved")
        #expect(archive.entries.isEmpty)
    }

    // MARK: AI chat history

    private func chat(_ text: String) -> StoredChat {
        StoredChat(id: UUID(), started: Date(timeIntervalSince1970: 1_700_000_000), updated: Date(timeIntervalSince1970: 1_700_000_100),
                   items: [ChatItem(kind: .user, text: text)])
    }

    @Test func aDamagedChatHistoryIsKeptBeforeTheNextSave() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("ai-chats.json")
        try Data("{\"version\":1,\"chats\":".utf8).write(to: file)
        let history = ChatHistory(file: file)
        #expect(history.chats.isEmpty)
        history.record(id: UUID(), started: Date(), items: [ChatItem(kind: .user, text: "after")])
        let kept = try damagedCopies(in: folder, of: "ai-chats.json")
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: try #require(kept.first)) == Data("{\"version\":1,\"chats\":".utf8))
        #expect(ChatHistory(file: file).chats.map(\.title) == ["after"])
    }

    @Test func aChatThatDoesNotDecodeDoesNotTakeTheOthersWithIt() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("ai-chats.json")
        let first = ChatHistory(file: file)
        first.record(id: UUID(), started: Date(), items: [ChatItem(kind: .user, text: "keep me")])
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["chats"] = (json["chats"] as? [Any] ?? []) + [["id": "not a uuid"]]
        let original = try JSONSerialization.data(withJSONObject: json)
        try original.write(to: file)
        let history = ChatHistory(file: file)
        #expect(history.chats.map(\.title) == ["keep me"])
        let kept = try damagedCopies(in: folder, of: "ai-chats.json")
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: try #require(kept.first)) == original)
    }

    @Test func aChatHistoryThatCannotBeReadIsNeverWrittenOver() throws {
        let folder = try persistenceScratchFolder()
        let file = folder.appendingPathComponent("ai-chats.json")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let original = Data("{\"version\":1,\"chats\":[]}".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        let history = ChatHistory(file: file)
        history.record(id: UUID(), started: Date(), items: [ChatItem(kind: .user, text: "new")])
        #expect(history.saveFailed)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
    }
}

// MARK: Library

@MainActor
struct LibraryDataTests {
    private func library() throws -> (Library, URL) {
        let folder = try persistenceScratchFolder()
        return (Library(path: folder.appendingPathComponent("library.sqlite").path), folder)
    }

    /// A library as the version before the order column wrote it: the favorites' order was in `added`.
    private func oldLibrary(_ rows: [(url: String, folder: String, added: Double)]) throws -> (path: String, folder: URL) {
        let folder = try persistenceScratchFolder()
        let path = folder.appendingPathComponent("library.sqlite").path
        let db = try SQLite(path: path)
        try db.execute("""
        CREATE TABLE history (url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', visits INTEGER NOT NULL DEFAULT 1, last_visit REAL NOT NULL);
        CREATE TABLE bookmarks (id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', folder TEXT NOT NULL DEFAULT '', added REAL NOT NULL, UNIQUE(url, folder));
        """)
        for row in rows { try db.run("INSERT INTO bookmarks (url, title, folder, added) VALUES (?, ?, ?, ?)", [row.url, row.url, row.folder, row.added]) }
        return (path, folder)
    }

    @Test func movingAFavoriteLeavesWhenItWasAddedAlone() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (index, name) in ["a", "b", "c"].enumerated() {
            library.addBookmark(url: "https://\(name).example/", title: name, folder: Library.favoritesFolder)
            Thread.sleep(forTimeInterval: 0.01 * Double(index + 1))
        }
        let recentBefore = library.bookmarks(limit: 10).map(\.url)
        library.moveFavorite("https://c.example/", to: "https://a.example/")
        #expect(library.favorites().map(\.url) == ["https://c.example/", "https://a.example/", "https://b.example/"])
        #expect(library.bookmarks(limit: 10).map(\.url) == recentBefore, "recent bookmarks go by when they were added, not by where they sit")
        #expect(library.knowsURL("https://a.example/", before: Date().addingTimeInterval(60)))
        #expect(!library.knowsURL("https://a.example/", before: Date().addingTimeInterval(-3600)), "the time added is still the real one")
        // A favorite added later comes last.
        library.addBookmark(url: "https://d.example/", title: "d", folder: Library.favoritesFolder)
        #expect(library.favorites().map(\.url).last == "https://d.example/")
    }

    @Test func aBookmarkOfAFolderMovesWithinItAndTheRestStayWhereTheyAre() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a", "b", "c", "d"] { library.addBookmark(url: "https://\(name).example/", title: name, folder: "Work") }
        library.addBookmark(url: "https://x.example/", title: "x", folder: "Home")
        library.addBookmark(url: "https://y.example/", title: "y", folder: "Home")
        func urls(_ name: String) -> [String] { library.folders().first { $0.name == name }?.entries.map(\.url) ?? [] }
        let untouched = ["https://a.example/", "https://b.example/", "https://c.example/", "https://d.example/"]
        #expect(urls("Work") == untouched, "a folder nobody arranged is as it was")
        #expect(library.moveFolderBookmark("https://d.example/", to: "https://b.example/", in: "Work"))
        #expect(urls("Work") == ["https://a.example/", "https://d.example/", "https://b.example/", "https://c.example/"])
        #expect(urls("Home") == ["https://x.example/", "https://y.example/"], "another folder is not touched")
        #expect(library.folders().map(\.name) == ["Work", "Home"], "the folders keep their order")
        #expect(library.moveFolderBookmark("https://a.example/", to: nil, in: "Work"))
        #expect(urls("Work") == ["https://d.example/", "https://b.example/", "https://c.example/", "https://a.example/"], "to the end")
        #expect(!library.moveFolderBookmark("https://a.example/", to: nil, in: "Work"), "already last: nothing moves")
        #expect(!library.moveFolderBookmark("https://a.example/", to: "https://a.example/", in: "Work"), "dropped on itself")
        #expect(!library.moveFolderBookmark("https://nowhere.example/", to: nil, in: "Work"))
        // A bookmark added or moved in afterwards comes last, and the folder stays as arranged.
        library.addBookmark(url: "https://e.example/", title: "e", folder: "Work")
        #expect(urls("Work").last == "https://e.example/")
        #expect(library.moveBookmark(url: "https://x.example/", from: "Home", to: "Work"))
        #expect(urls("Work") == ["https://d.example/", "https://b.example/", "https://c.example/", "https://a.example/", "https://e.example/", "https://x.example/"])
        // It is kept: another connection to the same file sees it.
        #expect(Library(path: folder.appendingPathComponent("library.sqlite").path).folders().first { $0.name == "Work" }?.entries.first?.url == "https://d.example/")
        // The favorites are not a folder to arrange this way.
        library.addBookmark(url: "https://f.example/", title: "f", folder: Library.favoritesFolder)
        #expect(!library.moveFolderBookmark("https://f.example/", to: nil, in: Library.favoritesFolder))
    }

    @Test func aLibraryFromBeforeTheOrderColumnKeepsItsOrderAndItsDates() throws {
        let old = try oldLibrary([("https://a.example/", "", 10), ("https://b.example/", "", 5), ("https://x.example/", "Chrome Bookmarks Bar", 7),
                                  ("https://c.example/", "", 20), ("https://y.example/", "Chrome Bookmarks Bar", 3)])
        defer { try? FileManager.default.removeItem(at: old.folder) }
        let library = Library(path: old.path)
        #expect(library.problem == nil)
        #expect(library.favorites().map(\.url) == ["https://b.example/", "https://a.example/", "https://c.example/"], "the order it had")
        #expect(library.folders().first?.entries.map(\.url) == ["https://x.example/", "https://y.example/"], "imported folders keep their order")
        let db = try SQLite(path: old.path)
        let added = try db.query("SELECT url, added FROM bookmarks ORDER BY id").map { ($0[0] as? String ?? "", $0[1] as? Double ?? -1) }
        #expect(added.map(\.1) == [10, 5, 7, 20, 3], "added is not touched")
        library.moveFavorite("https://c.example/", to: "https://b.example/")
        #expect(library.favorites().map(\.url) == ["https://c.example/", "https://b.example/", "https://a.example/"])
        #expect(try db.query("SELECT added FROM bookmarks ORDER BY id").map { $0[0] as? Double ?? -1 } == [10, 5, 7, 20, 3])
        // Opening it again changes nothing.
        #expect(Library(path: old.path).favorites().map(\.url) == ["https://c.example/", "https://b.example/", "https://a.example/"])
    }

    @Test func aReadOnlyLibraryIsStillReadAndOnlyAFailedOrderMigrationIsAProblem() throws {
        let old = try oldLibrary([("https://a.example/", "", 10), ("https://b.example/", "", 5), ("https://x.example/", "Chrome Bookmarks Bar", 7)])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.folder.path)
            try? FileManager.default.removeItem(at: old.folder)
        }
        // Read-only file in a read-only folder: no WAL, no ALTER, no CREATE can happen.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: old.folder.path)
        let library = Library(path: old.path)
        #expect(library.problem != nil, "the order column could not be added")
        #expect(library.favorites().map(\.url) == ["https://b.example/", "https://a.example/"], "read in the order they were added")
        #expect(library.folders().first?.entries.map(\.url) == ["https://x.example/"])
        #expect(library.readBookmarks() != nil)
    }

    @Test func aReadOnlyLibraryThatIsUpToDateHasNoProblem() throws {
        let (library, folder) = try library()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        library.addBookmark(url: "https://a.example/", title: "a", folder: "")
        let path = folder.appendingPathComponent("library.sqlite").path
        let before = Library(path: path)
        #expect(before.favorites().count == 1)
        for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: folder.appendingPathComponent(file).path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let readOnly = Library(path: path)
        #expect(readOnly.problem == nil)
        #expect(readOnly.favorites().map(\.url) == ["https://a.example/"])
    }

    @Test func aSpaceDeletedKeepsTheOrderOfItsFavoritesInTheNextOne() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        let work = Library.favoritesPrefix + UUID().uuidString
        for name in ["a", "b", "c"] { library.addBookmark(url: "https://\(name).example/", title: name, folder: work) }
        library.addBookmark(url: "https://home.example/", title: "home", folder: Library.favoritesFolder)
        library.moveFavorite("https://c.example/", to: "https://a.example/", in: work)
        #expect(library.moveFavorites(from: work, to: Library.favoritesFolder))
        #expect(library.favorites().map(\.url) == ["https://home.example/", "https://c.example/", "https://a.example/", "https://b.example/"])
    }

    @Test func searchTreatsPercentAndUnderscoreAsPlainCharacters() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        library.recordVisit(url: "https://a.example/100%25-off", title: "100% off")
        library.recordVisit(url: "https://b.example/1000", title: "1000 items")
        library.recordVisit(url: "https://c.example/snake_case", title: "snake_case")
        library.recordVisit(url: "https://d.example/snakexcase", title: "snakexcase")
        #expect(library.search("100%").map(\.url) == ["https://a.example/100%25-off"])
        #expect(library.history(matching: "100%").map(\.url) == ["https://a.example/100%25-off"])
        #expect(library.search("snake_case").map(\.url) == ["https://c.example/snake_case"])
        #expect(library.history(matching: "%").map(\.url) == ["https://a.example/100%25-off"])
        #expect(library.history(matching: "_").map(\.url) == ["https://c.example/snake_case"])
    }

    @Test func searchIgnoresCaseBeyondASCII() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        library.recordVisit(url: "https://a.example/", title: "Élan Vital")
        library.recordVisit(url: "https://b.example/", title: "ЖУРНАЛ")
        library.recordVisit(url: "https://c.example/", title: "한글 제목")
        library.recordVisit(url: "https://d.example/", title: "Plain Title")
        #expect(library.history(matching: "élan").map(\.url) == ["https://a.example/"])
        #expect(library.history(matching: "ÉLAN").map(\.url) == ["https://a.example/"])
        #expect(library.search("журнал").map(\.url) == ["https://b.example/"])
        #expect(library.search("제목").map(\.url) == ["https://c.example/"])
        #expect(library.search("PLAIN title").map(\.url) == ["https://d.example/"])
        #expect(library.history(matching: "élan vital").map(\.url) == ["https://a.example/"], "several words")
    }

    @Test func removingASourceTakesExactlyItsFolders() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try library.importBookmarks([("https://1.example/", "1", "Arc Bookmarks Bar"), ("https://2.example/", "2", "Arc Sidebar / Work"),
                                         ("https://3.example/", "3", "arc Notes"), ("https://4.example/", "4", "Arcade Games"),
                                         ("https://5.example/", "5", "Chrome Bookmarks Bar / Arc")])
        library.removeSource("Arc")
        #expect(library.folders().map(\.name) == ["arc Notes", "Arcade Games", "Chrome Bookmarks Bar / Arc"])
        library.removeFolder("Chrome Bookmarks Bar")
        #expect(library.folders().map(\.name) == ["arc Notes", "Arcade Games"])
        _ = try library.importBookmarks([("https://6.example/", "6", "Work / 2026"), ("https://7.example/", "7", "work / 2026"), ("https://8.example/", "8", "Work")])
        library.removeFolder("Work")
        #expect(library.folders().map(\.name).contains("work / 2026") && !library.folders().map(\.name).contains("Work / 2026"))
    }

    @Test func aLibraryThatCannotBeOpenedSaysSo() throws {
        let broken = Library(path: "/nonexistent-\(UUID().uuidString)/library.sqlite")
        #expect(broken.problem != nil)
        let (fine, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(fine.problem == nil)
        let b = Browser()
        defer { b.windowClosed() }
        b.reportLibraryProblem(fine)
        #expect(b.overlay.statusMessage == nil)
        b.reportLibraryProblem(broken)
        let first = b.overlay.statusMessage
        #expect(first != nil)
        b.overlay.statusMessage = nil
        b.reportLibraryProblem(broken)
        #expect(b.overlay.statusMessage == nil, "told once")
    }

    @Test func aSpaceIsNotDeletedWhenItsFavoritesCannotMove() throws {
        let box = Sandbox()
        let store = box.store()
        let work = store.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
        let broken = Library(path: "/nonexistent-\(UUID().uuidString)/library.sqlite")
        Browser.deleteSpace(work.id, from: store, library: broken)
        #expect(store.contains(work.id) && store.spaces.count == 2, "its favorites could not be moved, so it stays")
        let working = Library(path: box.file("lib.sqlite").path)
        Browser.deleteSpace(work.id, from: store, library: working)
        #expect(!store.contains(work.id))
    }
}

// MARK: Clear History

@MainActor
struct ClearHistoryTests {
    @Test func clearingHistoryForgetsTheArchivedTabsOfThatTime() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("archive.json")
        let archive = TabArchive(file: file)
        let now = Date()
        archive.add([TabArchive.Entry(url: "https://old.example/", title: "Old", archived: now.addingTimeInterval(-86400 * 3)),
                     TabArchive.Entry(url: "https://new.example/", title: "New", archived: now.addingTimeInterval(-60))])
        archive.remove(since: now.addingTimeInterval(-3600))
        #expect(archive.entries.map(\.url) == ["https://old.example/"])
        #expect(TabArchive(file: file).entries.map(\.url) == ["https://old.example/"], "and on disk")
        archive.remove(since: .distantPast)
        #expect(archive.entries.isEmpty && TabArchive(file: file).entries.isEmpty)
    }

    @Test func iconsOfSitesNothingIsLeftFromAreDeleted() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for host in ["kept.example", "Open.example", "gone.example", "also-gone.example"] { try Data("png".utf8).write(to: folder.appendingPathComponent(host + ".png")) }
        try Data("note".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        Browser.pruneIcons(keeping: ["kept.example", "open.example"], in: folder)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["Open.example.png", "kept.example.png", "notes.txt"])
    }

    @Test func theHostsOfTheLibraryAreKnownAndAnUnreadableLibraryKnowsNone() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = Library(path: folder.appendingPathComponent("library.sqlite").path)
        library.recordVisit(url: "https://Visited.example/a", title: "")
        library.addBookmark(url: "https://marked.example:8080/b", title: "", folder: Library.favoritesFolder)
        #expect(library.knownHosts() == ["visited.example", "marked.example"])
        #expect(Library(path: "/nonexistent-\(UUID().uuidString)/library.sqlite").knownHosts() == nil, "so nothing is pruned by it")
    }
}

