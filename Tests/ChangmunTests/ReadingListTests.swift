import AppKit
import Foundation
import SQLite3
import Testing
import ChangmunCore
@testable import Changmun

/// The reading list: saved pages in the library, Safari's list brought over, and the rules around them.
@MainActor
struct ReadingListStorageTests {
    private func library() throws -> (Library, URL) {
        let folder = try persistenceScratchFolder()
        return (Library(path: folder.appendingPathComponent("library.sqlite").path), folder)
    }

    @Test func theSamePageSavedTwiceIsOneItemWhateverTheFragmentOrTheSlash() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(library.addToReadingList(url: "https://News.Example/story/", title: "Story"))
        #expect(!library.addToReadingList(url: "https://news.example/story#comments", title: "Again"))
        #expect(!library.addToReadingList(url: "https://news.example/story", title: "Again"))
        #expect(library.addToReadingList(url: "https://news.example/story?page=2", title: "Page 2"), "the query tells pages apart")
        #expect(library.readingList().map(\.title) == ["Page 2", "Story"])
        #expect(ReadingList.key(for: "https://a.example") == "https://a.example/")
        #expect(ReadingList.key(for: "https://a.example/") == "https://a.example/")
    }

    @Test func onlyWebPagesAreSaved() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        for address in ["file:///etc/hosts", "javascript:alert(1)", "about:blank", "", "not a url", "https://" + String(repeating: "a", count: ReadingList.maxURLLength) + ".example/"] {
            #expect(!library.addToReadingList(url: address, title: "x"), "\(address.prefix(30))")
        }
        #expect(library.readingList().isEmpty)
    }

    @Test func newestFirstAndTheTitleIsTrimmedCutAndNeverEmpty() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        library.addToReadingList(url: "https://old.example/", title: "  Old \n", added: start)
        library.addToReadingList(url: "https://new.example/", title: String(repeating: "x", count: Tab.maxNameLength + 50), added: start + 60)
        library.addToReadingList(url: "https://www.untitled.example/page", title: "   ", added: start + 30)
        let items = library.readingList()
        #expect(items.map(\.url) == ["https://new.example/", "https://www.untitled.example/page", "https://old.example/"])
        #expect(items.map(\.title) == [String(repeating: "x", count: Tab.maxNameLength), "untitled.example", "Old"])
        #expect(items[2].added == start)
    }

    @Test func readStateRemovalAndClearingTheReadOnes() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (n, name) in ["a", "b", "c"].enumerated() { library.addToReadingList(url: "https://\(name).example/", title: name, added: Date(timeIntervalSince1970: Double(1000 + n))) }
        #expect(library.readingList().allSatisfy { !$0.read })
        #expect(library.markReadingItem(url: "https://b.example/#top", read: true))
        #expect(!library.markReadingItem(url: "https://b.example/", read: true), "already read: nothing changed")
        #expect(!library.markReadingItem(url: "https://nowhere.example/", read: true))
        #expect(!library.addToReadingList(url: "https://b.example/", title: "b"))
        #expect(library.readingList().map(\.read) == [false, true, false], "saving it again leaves it read")
        let cleared = library.clearReadItems()
        #expect(cleared.map(\.url) == ["https://b.example/"] && library.readingList().map(\.title) == ["c", "a"])
        library.restoreReadingItems(cleared)
        #expect(library.readingList().map(\.title) == ["c", "b", "a"] && library.readingList()[1].read, "put back where it was, still read")
        library.removeFromReadingList(url: "https://c.example")
        #expect(library.readingList().map(\.title) == ["b", "a"])
        #expect(library.markReadingItem(url: "https://b.example/", read: false) && library.readingList().allSatisfy { !$0.read })
    }

    @Test func itIsOnDiskAndNotInTheBookmarks() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        library.addToReadingList(url: "https://a.example/", title: "A")
        let again = Library(path: folder.appendingPathComponent("library.sqlite").path)
        #expect(again.readingList().map(\.title) == ["A"])
        #expect(again.counts.bookmarks == 0 && again.favorites().isEmpty && again.folders().isEmpty && again.search("a.example").isEmpty && !again.knowsURL("https://a.example/"))
    }

    @Test func aLibraryFromBeforeTheListGetsItsTableAndKeepsWhatItHad() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("library.sqlite").path
        let old = try SQLite(path: path)
        try old.execute("CREATE TABLE history (url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', visits INTEGER NOT NULL DEFAULT 1, last_visit REAL NOT NULL)")
        try old.run("INSERT INTO history (url, title, visits, last_visit) VALUES ('https://kept.example/', 'Kept', 3, 1000)")
        let library = Library(path: path)
        #expect(library.readingList().isEmpty && library.addToReadingList(url: "https://a.example/", title: "A") && library.readingList().count == 1)
        #expect(library.history().map(\.title) == ["Kept"])
    }

    @Test func aReadOnlyLibraryReadsNothingAndSavesNothingWithoutFailing() throws {
        let folder = try persistenceScratchFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appendingPathComponent("library.sqlite").path)
            try? FileManager.default.removeItem(at: folder)
        }
        let path = folder.appendingPathComponent("library.sqlite").path
        let old = try SQLite(path: path)
        try old.execute("CREATE TABLE history (url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', visits INTEGER NOT NULL DEFAULT 1, last_visit REAL NOT NULL)")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        let library = Library(path: path)
        #expect(library.readingList().isEmpty && library.readReadingList() == nil)
        #expect(!library.addToReadingList(url: "https://a.example/", title: "A"))
        #expect(!library.markReadingItem(url: "https://a.example/", read: true) && library.clearReadItems().isEmpty)
    }

    @Test func theLibraryTellsEveryWindowWhenTheListChanges() async throws {
        let watcher = LibraryWatcher.shared
        let url = "https://watched-reading-list.example/"
        defer { Library.shared.removeFromReadingList(url: url) }
        func settle(_ done: () -> Bool) async {
            for _ in 0..<60 where !done() { try? await Task.sleep(for: .milliseconds(50)) }
        }
        Library.shared.addToReadingList(url: url, title: "Watched")
        await settle { watcher.readingList.contains { $0.url == url } }
        #expect(watcher.readingList.first { $0.url == url }?.read == false)
        Library.shared.markReadingItem(url: url, read: true)
        await settle { watcher.readingList.first { $0.url == url }?.read == true }
        #expect(watcher.readingList.first { $0.url == url }?.read == true)
        Library.shared.removeFromReadingList(url: url)
        await settle { !watcher.readingList.contains { $0.url == url } }
        #expect(!watcher.readingList.contains { $0.url == url })
    }
}

@MainActor
struct ReadingListRulesTests {
    @Test func theLabelSaysHowLongAgoInTheLanguageOfTheLocale() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let english = Locale(identifier: "en_US")
        #expect(ReadingList.dateLabel(now, now: now, locale: english) == "now")
        #expect(ReadingList.dateLabel(now - 86400, now: now, locale: english) == "yesterday")
        #expect(ReadingList.dateLabel(now - 3 * 86400, now: now, locale: english) == "3 days ago")
        #expect(ReadingList.dateLabel(now - 3 * 3600, now: now, locale: english) == "3 hr. ago")
        #expect(ReadingList.dateLabel(now - 86400, now: now, locale: Locale(identifier: "ko_KR")) == "어제")
    }

    @Test func aRowNamesTheSiteWithoutWww() {
        #expect(ReadingList.siteName(of: "https://www.example.com/a/b") == "example.com")
        #expect(ReadingList.siteName(of: "https://blog.example.com/") == "blog.example.com")
    }

    @Test func aSavedPageIsReadWhenItHasLoadedUnlessItIsInAPrivateWindow() {
        let items = [ReadingItem(url: "https://a.example/story", title: "A", added: Date(), read: false),
                     ReadingItem(url: "https://b.example/", title: "B", added: Date(), read: true)]
        #expect(ReadingList.shouldMarkRead(loaded: "https://a.example/story/#part-2", isPrivate: false, in: items))
        #expect(!ReadingList.shouldMarkRead(loaded: "https://a.example/story", isPrivate: true, in: items), "a private window's page is not looked up")
        #expect(!ReadingList.shouldMarkRead(loaded: "https://b.example/", isPrivate: false, in: items), "already read")
        #expect(!ReadingList.shouldMarkRead(loaded: "https://c.example/", isPrivate: false, in: items), "not saved")
        #expect(!ReadingList.shouldMarkRead(loaded: nil, isPrivate: false, in: items))
        #expect(!ReadingList.shouldMarkRead(loaded: "about:blank", isPrivate: false, in: items))
    }

    @Test func nothingIsSavedFromAPrivateWindowOrAPageThatIsNotOnTheWeb() {
        #expect(ReadingList.canSave("https://a.example/", isPrivate: false))
        #expect(!ReadingList.canSave("https://a.example/", isPrivate: true))
        #expect(!ReadingList.canSave("about:blank", isPrivate: false) && !ReadingList.canSave(nil, isPrivate: false))
    }

    @Test func theMenuItemHasAShortcutNothingElseUses() {
        for scheme in ShortcutScheme.allCases {
            let items = AppMenu.make(scheme: scheme).items.flatMap { $0.submenu?.items ?? [] }
            let item = items.first { $0.action == #selector(AppDelegate.addToReadingList(_:)) }
            #expect(item?.keyEquivalent == "d" && item?.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [.command, .shift])
            let same = items.filter { $0.keyEquivalent == "d" && $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [.command, .shift] }
            #expect(same.count == 1, "\(scheme): ⇧⌘D does one thing")
        }
    }
}

extension SharedAgentState {
    @MainActor @Suite(.serialized)
    struct ReadingListBrowserTests {
        private let url = "https://reading-list-browser.example/story"

        @Test func savingOffersUndoAndASecondSaveSaysSo() {
            let browser = Browser()
            defer { browser.windowClosed(); Library.shared.removeFromReadingList(url: url) }
            browser.addToReadingList(url: url + "#top", title: "Story")
            #expect(Library.shared.readingList().contains { $0.url == url })
            #expect(browser.notice?.message == "Added to Reading List")
            browser.undoNotice()
            #expect(!Library.shared.readingList().contains { $0.url == url })
            browser.addToReadingList(url: url, title: "Story")
            browser.notice = nil
            browser.addToReadingList(url: url, title: "Story")
            #expect(browser.notice == nil && browser.overlay.statusMessage == "Already in Reading List")
        }

        @Test func aPrivateWindowSavesNothing() {
            let browser = Browser(isPrivate: true)
            defer { browser.windowClosed(); Library.shared.removeFromReadingList(url: url) }
            browser.addToReadingList(url: url, title: "Story")
            #expect(!Library.shared.readingList().contains { $0.url == url } && browser.notice == nil)
        }

        @Test func removingAndClearingOfferUndo() {
            let browser = Browser()
            let other = "https://reading-list-browser.example/other"
            defer { browser.windowClosed(); Library.shared.removeFromReadingList(url: url); Library.shared.removeFromReadingList(url: other) }
            Library.shared.addToReadingList(url: url, title: "Story")
            Library.shared.addToReadingList(url: other, title: "Other")
            Library.shared.markReadingItem(url: other, read: true)
            browser.clearReadItems()
            #expect(!Library.shared.readingList().contains { $0.url == other } && browser.notice?.message == "Cleared 1 read item")
            browser.undoNotice()
            #expect(Library.shared.readingList().first { $0.url == other }?.read == true)
            let item = ReadingItem(url: url, title: "Story", added: Date(), read: false)
            browser.removeReadingItem(item)
            #expect(!Library.shared.readingList().contains { $0.url == url })
            browser.undoNotice()
            #expect(Library.shared.readingList().contains { $0.url == url })
        }
    }
}

/// Safari's Bookmarks.plist, as a fixture: the keys are the ones Safari writes (a `com.apple.ReadingList` list whose leaves carry a `ReadingList`
/// dictionary with `DateAdded`, `PreviewText` and, once read, `DateLastViewed`, and a `ReadingListNonSync` one), and a bookmarks bar.
@MainActor
struct SafariReadingListImportTests {
    private let added = Date(timeIntervalSince1970: 1_700_000_000)

    private func leaf(_ url: String, title: String?, dates: [String: Any]? = nil) -> [String: Any] {
        var leaf: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url, "WebBookmarkUUID": UUID().uuidString]
        if let title { leaf["URIDictionary"] = ["title": title] }
        if let dates {
            leaf["ReadingList"] = dates.merging(["PreviewText": "A preview of the page."]) { $1 }
            leaf["ReadingListNonSync"] = ["neverFetchMetadata": false]
        }
        return leaf
    }

    private func safariFolder() throws -> URL {
        let folder = try persistenceScratchFolder()
        let root: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList", "Title": "", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [leaf("https://bar.example/", title: "On the bar")]],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                    leaf("https://unread.example/post/", title: "Unread post", dates: ["DateAdded": added]),
                    leaf("https://read.example/essay", title: "Read essay", dates: ["DateAdded": added - 86400, "DateLastViewed": added]),
                    leaf("https://www.untitled.example/page#intro", title: nil, dates: ["DateAdded": added + 60]),
                    leaf("ftp://elsewhere.example/file", title: "Not a web page", dates: ["DateAdded": added]),
                ]],
            ],
        ]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: folder.appendingPathComponent("Bookmarks.plist"))
        return folder
    }

    @Test func theListIsReadWithItsDatesTitlesAndReadState() throws {
        let folder = try safariFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let items = try SafariImporter.readingList(folder: folder)
        #expect(items.map(\.url) == ["https://unread.example/post", "https://read.example/essay", "https://www.untitled.example/page"])
        #expect(items.map(\.title) == ["Unread post", "Read essay", "untitled.example"])
        #expect(items.map(\.read) == [false, true, false])
        #expect(items.map(\.added) == [added, added - 86400, added + 60])
    }

    @Test func theBookmarksStillLeaveTheListOut() throws {
        let folder = try safariFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try SafariImporter.bookmarks(folder: folder).map(\.url) == ["https://bar.example/"])
    }

    @Test func importingAgainAddsNothingAndKeepsWhatTheUserDidSince() throws {
        let safari = try safariFolder()
        let data = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: safari); try? FileManager.default.removeItem(at: data) }
        let library = Library(path: data.appendingPathComponent("library.sqlite").path)
        #expect(try library.importReadingList(SafariImporter.readingList(folder: safari)) == 3)
        library.markReadingItem(url: "https://unread.example/post", read: true)
        library.markReadingItem(url: "https://read.example/essay", read: false)
        library.removeFromReadingList(url: "https://www.untitled.example/page")
        let again = try library.importReadingList(SafariImporter.readingList(folder: safari))
        #expect(again == 1, "only the one the user removed comes back")
        let items = library.readingList()
        #expect(items.count == 3)
        #expect(items.first { $0.url == "https://unread.example/post" }?.read == true && items.first { $0.url == "https://read.example/essay" }?.read == false)
        #expect(try library.importReadingList(SafariImporter.readingList(folder: safari)) == 0)
    }

    @Test func theSafariImportBringsBookmarksAndTheListAndSaysSo() async throws {
        let safari = try safariFolder()
        let data = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: safari); try? FileManager.default.removeItem(at: data) }
        let library = Library(path: data.appendingPathComponent("library.sqlite").path)
        let source = ImportSource(browser: "Safari", profile: nil, directory: safari, kind: .safari, suggested: false)
        let report = await ImportRunner.run(source, options: ImportOptions(bookmarks: true, history: false, passwords: false, cookies: false), library: library) { _ in }
        #expect(report.bookmarks == 1 && report.readingList == 3 && report.problems.isEmpty)
        #expect(report.summary.contains("3"))
        #expect(library.readingList().count == 3)
        let without = await ImportRunner.run(source, options: ImportOptions(bookmarks: false, history: false, passwords: false, cookies: false), library: Library(path: data.appendingPathComponent("other.sqlite").path)) { _ in }
        #expect(without.readingList == 0)
    }

    @Test func aSafariWithoutAListImportsNothingFromIt() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Title": "", "Children": [Any]()]
        try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0).write(to: folder.appendingPathComponent("Bookmarks.plist"))
        #expect(try SafariImporter.readingList(folder: folder).isEmpty)
    }
}
