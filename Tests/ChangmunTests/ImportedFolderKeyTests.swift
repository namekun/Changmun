import Foundation
import Testing
@testable import Changmun

/// Imported folders are stored under English names whatever the language; earlier versions stored the language's label.
@MainActor
struct ImportedFolderKeyTests {
    private static let languages = ["en", "ko", "ja", "zh-Hans", "es", "de", "fr"]
    private static let sections = [ImportedFolders.barLabel, ImportedFolders.otherLabel, ImportedFolders.mobileLabel,
                                   ImportedFolders.sidebarLabel, ImportedFolders.favoritesLabel, ImportedFolders.menuLabel]
    private static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    /// What an earlier version stored for a section in a language (English is the label itself).
    private func label(_ section: String, in language: String) -> String {
        let index = Self.languages.firstIndex(of: language)!
        return index == 0 ? section : ImportedFolders.earlierLabels[section]![index - 1]
    }

    private func table(_ language: String) throws -> [String: String] {
        let file = Self.resources.appendingPathComponent("\(language).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: file) as? [String: String])
    }

    private func scratch() throws -> URL { try persistenceScratchFolder() }

    private func seeded(_ folder: URL, _ rows: [(String, String)]) throws -> Library {
        let library = Library(path: folder.appendingPathComponent("library.sqlite").path)
        _ = try library.importBookmarks(rows.map { ($0.0, $0.0, $0.1) })
        return library
    }

    private func suite() -> (UserDefaults, () -> Void) {
        let name = "changmun-folder-keys-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    private func version(_ folder: URL) throws -> Int64 {
        try #require(SQLite(path: folder.appendingPathComponent("library.sqlite").path).query("PRAGMA user_version").first?.first as? Int64)
    }

    private func names(_ library: Library) -> [String] { library.folders().map(\.name).sorted() }

    // MARK: The labels

    @Test func theEarlierLabelsAreTheOnesInTheStringsTables() throws {
        for (index, language) in Self.languages.enumerated().dropFirst() {
            let strings = try table(language)
            for section in Self.sections {
                #expect(strings[section] == ImportedFolders.earlierLabels[section]![index - 1], "\(language) \(section)")
            }
        }
        #expect(Set(Self.sections.flatMap { [$0] + ImportedFolders.earlierLabels[$0]! }).count == Self.sections.count * 7, "no two labels are alike")
    }

    @Test func aKeyIsShownInTheLanguageOfTheApp() throws {
        for language in Self.languages.dropFirst() {
            let strings = try table(language)
            let translate = { (section: String) in strings[section] ?? section }
            #expect(ImportedFolders.displayKey("Chrome Bookmarks Bar / Work / 개발", translate: translate) == "Chrome \(strings["Bookmarks Bar"]!) / Work / 개발")
            #expect(ImportedFolders.displayKey("Arc Sidebar", translate: translate) == "Arc \(strings["Sidebar"]!)")
            #expect(ImportedFolders.displayKey("Safari / Favorites / Sites", translate: translate) == "Safari / \(strings["Favorites"]!) / Sites")

            let groups = Library.groupBySource([("Chrome Other Bookmarks / Bookmarks Bar", []), ("Arc Sidebar", []), ("Changmun Sidebar", [])], section: translate)
            #expect(groups.map(\.source) == ["Chrome", "Arc", "Changmun"])
            // Only the section is translated: the sub-folder with the same words and the user's own folder keep their names.
            #expect(groups[0].folders.map(\.label) == [strings["Other Bookmarks"]!])
            #expect(groups[0].folders[0].children.map(\.label) == ["Bookmarks Bar"])
            #expect(groups[1].folders.map(\.label) == [strings["Sidebar"]!])
            #expect(groups[2].folders.map(\.label) == ["Sidebar"])
            #expect(Library.allFolders(groups).map(\.key) == ["Chrome Other Bookmarks", "Chrome Other Bookmarks / Bookmarks Bar", "Arc Sidebar", "Changmun Sidebar"])
        }
        #expect(ImportedFolders.displayKey("Chrome Work") == "Chrome Work")
        #expect(ImportedFolders.displayKey("Chrome Bookmarks Bar") == "Chrome " + String(localized: "Bookmarks Bar"))
    }

    @Test func theImporterNamesFoldersTheSameInEveryLanguage() throws {
        let fake = try FakeChromium()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let entries = try ChromiumImporter(source: fake.source, safeStorage: "").bookmarks()
        #expect(entries.map(\.folder) == ["Dia Bookmarks Bar", "Dia Bookmarks Bar / dev"])
        #expect(ImportedFolders.chromiumRoot("Arc", ImportedFolders.sidebarLabel) == "Arc Sidebar")
    }

    // MARK: The migration

    @Test(arguments: ["en", "ko", "ja", "zh-Hans", "es", "de", "fr"])
    func foldersImportedInAnyLanguageGetTheCanonicalName(language: String) throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (defaults, cleanUp) = suite()
        defer { cleanUp() }
        let bar = "Chrome " + label(ImportedFolders.barLabel, in: language)
        let rows = [("https://1.example/", bar), ("https://2.example/", bar + " / Work"), ("https://3.example/", bar + " / Work / 2026 / Sidebar"),
                    ("https://4.example/", "Chrome " + label(ImportedFolders.otherLabel, in: language)),
                    ("https://5.example/", "Chrome " + label(ImportedFolders.mobileLabel, in: language) + " / 북마크 바"),
                    ("https://6.example/", "Arc " + label(ImportedFolders.sidebarLabel, in: language)),
                    ("https://7.example/", "Safari / " + label(ImportedFolders.favoritesLabel, in: language) + " / News"),
                    ("https://8.example/", "Safari / " + label(ImportedFolders.menuLabel, in: language)),
                    ("https://9.example/", "Changmun Bookmarks Bar"), ("https://10.example/", "Brave Work")]
        let library = try seeded(folder, rows)
        library.addBookmark(url: "https://fav.example/", title: "Fav", folder: Library.favoritesFolder)
        library.addBookmark(url: "https://other.example/", title: "Other", folder: Library.favoritesPrefix + UUID().uuidString)

        #expect(FolderKeyMigration.run(in: folder, defaults: defaults))
        #expect(names(library) == ["Arc Sidebar", "Brave Work", "Changmun Bookmarks Bar", "Chrome Bookmarks Bar", "Chrome Bookmarks Bar / Work",
                                   "Chrome Bookmarks Bar / Work / 2026 / Sidebar", "Chrome Mobile Bookmarks / 북마크 바", "Chrome Other Bookmarks",
                                   "Safari / Bookmarks Menu", "Safari / Favorites / News"])
        #expect(library.favorites().map(\.url) == ["https://fav.example/"], "the favorites are not imported folders")
        #expect(library.counts.bookmarks == rows.count + 2)
        #expect(try version(folder) == FolderKeyMigration.version)
        let hasBackup = FileManager.default.fileExists(atPath: folder.appendingPathComponent("library-before-folder-keys.sqlite").path)
        #expect(hasBackup == (language != "en"), "a library with nothing to rename is not copied")
        if language != "en" {
            let backup = Library(path: folder.appendingPathComponent("library-before-folder-keys.sqlite").path)
            #expect(backup.folders().map(\.name).contains(bar), "the copy holds the names as they were")
        }
    }

    @Test func aLocalizedFolderAndACanonicalOneAreMergedWithoutDuplicates() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (defaults, cleanUp) = suite()
        defer { cleanUp() }
        let library = try seeded(folder, [
            ("https://same.example/", "Chrome Bookmarks Bar"), ("https://only-canonical.example/", "Chrome Bookmarks Bar"),
            ("https://same.example/", "Chrome 북마크 바"), ("https://only-korean.example/", "Chrome 북마크 바"),
            ("https://same.example/", "Chrome 북마크 바 / Work"), ("https://work.example/", "Chrome 북마크 바 / Work"),
            ("https://same.example/", "Chrome Bookmarks Bar / Work"),
            ("https://japanese.example/", "Chrome ブックマークバー"),
        ])
        #expect(FolderKeyMigration.run(in: folder, defaults: defaults))
        let result = Dictionary(uniqueKeysWithValues: library.folders().map { ($0.name, $0.entries.map(\.url)) })
        #expect(Set(result.keys) == ["Chrome Bookmarks Bar", "Chrome Bookmarks Bar / Work"])
        #expect(result["Chrome Bookmarks Bar"]?.sorted() == ["https://japanese.example/", "https://only-canonical.example/", "https://only-korean.example/", "https://same.example/"])
        #expect(result["Chrome Bookmarks Bar / Work"]?.sorted() == ["https://same.example/", "https://work.example/"])
        #expect(library.counts.bookmarks == 6)
    }

    @Test func itRunsOnceAndASecondRunChangesNothing() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (defaults, cleanUp) = suite()
        defer { cleanUp() }
        let library = try seeded(folder, [("https://a.example/", "Chrome 북마크 바 / Work"), ("https://b.example/", "Arc 사이드바")])
        #expect(FolderKeyMigration.run(in: folder, defaults: defaults))
        let after = library.folders().map { "\($0.name) \($0.entries.map(\.url))" }
        let backup = try Data(contentsOf: folder.appendingPathComponent("library-before-folder-keys.sqlite"))
        #expect(FolderKeyMigration.run(in: folder, defaults: defaults))
        #expect(library.folders().map { "\($0.name) \($0.entries.map(\.url))" } == after)
        // Done is done: a folder named like an earlier label, made since, is left alone.
        library.addBookmark(url: "https://c.example/", title: "C", folder: "Chrome 북마크 바")
        #expect(FolderKeyMigration.run(in: folder, defaults: defaults))
        #expect(names(library).contains("Chrome 북마크 바"))
        #expect(try Data(contentsOf: folder.appendingPathComponent("library-before-folder-keys.sqlite")) == backup, "the first copy stays")

        // Run again with the mark taken off (a library restored from a copy): the same result, nothing doubled.
        try SQLite(path: folder.appendingPathComponent("library.sqlite").path).execute("PRAGMA user_version = 0")
        #expect(FolderKeyMigration.run(in: folder, defaults: defaults))
        #expect(names(library) == ["Arc Sidebar", "Chrome Bookmarks Bar", "Chrome Bookmarks Bar / Work"])
        #expect(library.counts.bookmarks == 3)
    }

    @Test func aLibraryThatIsNotThereOrHasNoBookmarksYetIsLeftAlone() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (defaults, cleanUp) = suite()
        defer { cleanUp() }
        #expect(!FolderKeyMigration.run(in: folder, defaults: defaults))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("library.sqlite").path), "it makes no library")
        try SQLite(path: folder.appendingPathComponent("library.sqlite").path).execute("CREATE TABLE history (url TEXT)")
        #expect(FolderKeyMigration.run(in: folder, defaults: defaults))
    }

    @Test func pinnedFoldersOpenFoldersAndBookmarkTabsFollowTheNewNames() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (defaults, cleanUp) = suite()
        defer { cleanUp() }
        let store = SpaceStore(folder: folder, defaults: defaults)
        let second = store.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
        store.pinFolder("Chrome 북마크 바 / Work", in: Space.defaultID)
        store.pinFolder("Arc 사이드바", in: Space.defaultID)
        store.pinFolder("Brave Mine", in: Space.defaultID)
        store.pinFolder("Chrome ブックマークバー", in: second.id)
        for key in ["pin:Chrome 북마크 바 / Work", "Chrome 북마크 바 / Work", "source:Chrome", "pin:Arc 사이드바", "pin:Brave Mine"] { store.toggleOpen(key, in: Space.defaultID) }
        let library = try seeded(folder, [("https://a.example/", "Chrome 북마크 바 / Work"), ("https://a.example/", "Chrome Bookmarks Bar / Work"),
                                           ("https://s.example/", "Arc 사이드바"), ("https://m.example/", "Brave Mine")])
        _ = library
        let favorites = Library.favoritesPrefix + second.id.uuidString
        func tab(_ key: String?, _ space: UUID) -> [String: Any] {
            var tab: [String: Any] = ["url": "https://a.example/", "title": "A", "state": "AAEC/w==", "space": space.uuidString]
            tab["bookmarkKey"] = key
            return tab
        }
        let tabs = [tab("Chrome 북마크 바 / Work\nhttps://a.example/", Space.defaultID), tab("Chrome Bookmarks Bar / Work\nhttps://a.example/", Space.defaultID),
                    tab("Chrome Bookmarks Bar / Work\nhttps://a.example/", second.id), tab("Arc 사이드바\nhttps://s.example/", second.id),
                    tab("\(favorites)\nhttps://f.example/", second.id), tab("\nhttps://home.example/", Space.defaultID), tab("Brave Mine\nhttps://m.example/", Space.defaultID), tab(nil, Space.defaultID)]
        let session = try JSONSerialization.data(withJSONObject: ["windows": [["tabs": tabs, "active": 1, "saved": 782_000_000.5]]])
        let single = try JSONSerialization.data(withJSONObject: ["tabs": [tab("Chrome 북마크 바 / Work\nhttps://a.example/", Space.defaultID)], "saved": 1.5])
        try session.write(to: folder.appendingPathComponent("session.json"))
        try single.write(to: folder.appendingPathComponent("session-previous.json"))
        defaults.set(["Chrome 북마크 바 / Work", "Chrome Bookmarks Bar / Work", "Brave Mine"], forKey: "pinnedFolders")
        defaults.set(["pin:Arc 사이드바"], forKey: "openFolders")
        let spacesBefore = try Data(contentsOf: folder.appendingPathComponent("spaces.json"))

        #expect(FolderKeyMigration.run(in: folder, defaults: defaults))

        let reread = SpaceStore(folder: folder, defaults: defaults)
        #expect(reread.space(Space.defaultID).pinnedFolders == ["Chrome Bookmarks Bar / Work", "Arc Sidebar", "Brave Mine"])
        #expect(reread.space(Space.defaultID).openFolders == ["pin:Chrome Bookmarks Bar / Work", "Chrome Bookmarks Bar / Work", "source:Chrome", "pin:Arc Sidebar", "pin:Brave Mine"])
        #expect(reread.space(second.id).pinnedFolders == ["Chrome Bookmarks Bar"])
        #expect(reread.space(second.id).name == "Work")

        let windows = Browser.SavedWindows.decode(try Data(contentsOf: folder.appendingPathComponent("session.json")))
        #expect(windows.count == 1)
        let saved = windows[0].tabs
        #expect(saved.map(\.bookmarkKey) == ["Chrome Bookmarks Bar / Work\nhttps://a.example/", nil, "Chrome Bookmarks Bar / Work\nhttps://a.example/",
                                             "Arc Sidebar\nhttps://s.example/", "\(favorites)\nhttps://f.example/", "\nhttps://home.example/", "Brave Mine\nhttps://m.example/", nil],
                "the second tab of one space for one bookmark is an ordinary tab now; the favorites and the others stay")
        #expect(saved.map(\.state).compactMap { $0 }.allSatisfy { $0 == Data([0, 1, 2, 255]) })
        #expect(windows[0].active == 1)
        #expect(windows[0].saved == Date(timeIntervalSinceReferenceDate: 782_000_000.5))
        #expect(Browser.SavedWindows.decode(try Data(contentsOf: folder.appendingPathComponent("session-previous.json"))).first?.tabs.first?.bookmarkKey
                == "Chrome Bookmarks Bar / Work\nhttps://a.example/")

        #expect(defaults.stringArray(forKey: "pinnedFolders") == ["Chrome Bookmarks Bar / Work", "Brave Mine"])
        #expect(defaults.stringArray(forKey: "openFolders") == ["pin:Arc Sidebar"])

        // What changed was copied first, as it was; the copies are made once.
        func copy(_ name: String) -> Data? { try? Data(contentsOf: folder.appendingPathComponent(name)) }
        #expect(copy("spaces-before-folder-keys.json") == spacesBefore)
        #expect(copy("session-before-folder-keys.json") == session)
        #expect(copy("session-previous-before-folder-keys.json") == single)
        let old = try JSONDecoder().decode([String: [String]].self, from: try #require(copy("preferences-before-folder-keys.json")))
        #expect(old["pinnedFolders"] == ["Chrome 북마크 바 / Work", "Chrome Bookmarks Bar / Work", "Brave Mine"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("library-before-folder-keys.sqlite").path))
    }

    @Test func filesWithNothingToRenameAreNotTouchedOrCopied() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (defaults, cleanUp) = suite()
        defer { cleanUp() }
        let store = SpaceStore(folder: folder, defaults: defaults)
        store.pinFolder("Chrome Bookmarks Bar", in: Space.defaultID)
        let library = try seeded(folder, [("https://a.example/", "Chrome Bookmarks Bar")])
        let session = Data(#"{"windows":[{"tabs":[{"title":"A","bookmarkKey":"Chrome Bookmarks Bar\nhttps://a.example/"}]}]}"#.utf8)
        try session.write(to: folder.appendingPathComponent("session.json"))
        try Data("not json {".utf8).write(to: folder.appendingPathComponent("session-previous.json"))
        let spaces = try Data(contentsOf: folder.appendingPathComponent("spaces.json"))
        #expect(FolderKeyMigration.run(in: folder, defaults: defaults))
        #expect(try Data(contentsOf: folder.appendingPathComponent("session.json")) == session)
        #expect(try Data(contentsOf: folder.appendingPathComponent("spaces.json")) == spaces)
        #expect(try String(contentsOf: folder.appendingPathComponent("session-previous.json"), encoding: .utf8) == "not json {")
        let made = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("before-folder-keys") }
        #expect(made.isEmpty, "\(made)")
        #expect(library.counts.bookmarks == 1)
    }

    @Test func safariFoldersAreLabelledWithoutTheSlashAfterTheBrowser() {
        let entry = Library.Entry(url: "https://a.com/", title: "A")
        let translate = { (section: String) in section == "Favorites" ? "즐겨찾기" : section }
        let groups = Library.groupBySource([("Safari / Favorites", [entry]), ("Safari / Favorites / News", [entry]), ("Safari / Bookmarks Menu", [entry])], section: translate)
        #expect(groups.map(\.source) == ["Safari"])
        #expect(groups[0].folders.map(\.label) == ["즐겨찾기", "Bookmarks Menu"])
        #expect(groups[0].folders.map(\.key) == ["Safari / Favorites", "Safari / Bookmarks Menu"], "the keys are as stored")
        #expect(groups[0].folders[0].children.map(\.label) == ["News"])
        #expect(groups[0].folders[0].paths().map(\.path) == ["즐겨찾기", "즐겨찾기 › News"])
    }

    @Test func withoutRoomForTheCopyNothingIsChangedAndItIsTriedAgainAfterADay() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (defaults, cleanUp) = suite()
        defer { cleanUp() }
        let library = try seeded(folder, [("https://a.example/", "Chrome 북마크 바")])
        let start = Date()
        #expect(!FolderKeyMigration.run(in: folder, defaults: defaults, freeBytes: { _ in 0 }, now: start))
        #expect(names(library) == ["Chrome 북마크 바"])
        #expect(try version(folder) == 0)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("library-before-folder-keys.sqlite").path))
        // Room again, but it was tried a moment ago: not yet.
        #expect(!FolderKeyMigration.run(in: folder, defaults: defaults, freeBytes: { _ in Int64.max }, now: start.addingTimeInterval(3600)))
        #expect(names(library) == ["Chrome 북마크 바"])
        #expect(FolderKeyMigration.run(in: folder, defaults: defaults, freeBytes: { _ in Int64.max }, now: start.addingTimeInterval(FolderKeyMigration.retryAfter + 1)))
        #expect(names(library) == ["Chrome Bookmarks Bar"] && defaults.object(forKey: FolderKeyMigration.attemptKey) == nil)
    }

    @Test func twiceTheLibrarysSizeIsRoomEnough() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (defaults, cleanUp) = suite()
        defer { cleanUp() }
        let library = try seeded(folder, [("https://a.example/", "Chrome 북마크 바")])
        let size = try #require(FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("library.sqlite").path)[.size] as? Int64)
        #expect(!FolderKeyMigration.run(in: folder, defaults: defaults, freeBytes: { _ in size * 2 - 1 }))
        defaults.removeObject(forKey: FolderKeyMigration.attemptKey)
        #expect(FolderKeyMigration.run(in: folder, defaults: defaults, freeBytes: { _ in size * 2 }))
        #expect(names(library) == ["Chrome Bookmarks Bar"])
    }

    @Test func aFileThatCannotBeReadDoesNotHoldTheMigrationBack() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (defaults, cleanUp) = suite()
        defer { cleanUp() }
        let library = try seeded(folder, [("https://a.example/", "Chrome 북마크 바")])
        let session = Data(#"{"windows":[{"tabs":[{"title":"A","bookmarkKey":"Chrome 북마크 바\nhttps://a.example/"}]}]}"#.utf8)
        try session.write(to: folder.appendingPathComponent("session.json"))
        let locked = folder.appendingPathComponent("session-previous.json")
        try session.write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        try #require(!FileManager.default.isReadableFile(atPath: locked.path), "a file this process can't read")

        #expect(FolderKeyMigration.run(in: folder, defaults: defaults))
        #expect(try version(folder) == FolderKeyMigration.version)
        #expect(names(library) == ["Chrome Bookmarks Bar"])
        #expect(Browser.SavedWindows.decode(try Data(contentsOf: folder.appendingPathComponent("session.json"))).first?.tabs.first?.bookmarkKey
                == "Chrome Bookmarks Bar\nhttps://a.example/", "the readable file is migrated")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("session-previous-before-folder-keys.json").path))
    }

    @Test func importingAgainAfterTheMigrationAddsNoFolder() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (defaults, cleanUp) = suite()
        defer { cleanUp() }
        let library = try seeded(folder, [("https://apple.com/", "Dia 북마크 바"), ("https://swift.org/", "Dia 북마크 바 / dev")])
        #expect(FolderKeyMigration.run(in: folder, defaults: defaults))
        let fake = try FakeChromium()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let entries = try ChromiumImporter(source: fake.source, safeStorage: "").bookmarks()
        _ = try library.importBookmarks(entries)
        _ = try library.importBookmarks(entries)
        #expect(names(library) == ["Dia Bookmarks Bar", "Dia Bookmarks Bar / dev"])
        #expect(library.counts.bookmarks == 2)
        library.removeSource("Dia")
        #expect(library.counts.bookmarks == 0, "removing the browser takes both")
    }
}
