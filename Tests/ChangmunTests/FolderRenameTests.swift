import Foundation
import Testing
@testable import Changmun

/// The name a user gives a bookmark folder, kept beside the folder's key in the library; and a folder row taking a double-click.
@MainActor
struct LibraryFolderNameTests {
    private func library() throws -> (Library, URL) {
        let folder = try persistenceScratchFolder()
        return (Library(path: folder.appendingPathComponent("library.sqlite").path), folder)
    }

    private let chrome = "Chrome Bookmarks Bar"

    @Test func aNameIsKeptTrimmedAndOnDisk() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        library.addBookmark(url: "https://a.example/", title: "A", folder: chrome + " / Dev")
        #expect(library.renameFolder(key: chrome + " / Dev", to: "  Work \n"))
        #expect(library.folderNames() == [chrome + " / Dev": "Work"])
        #expect(Library(path: folder.appendingPathComponent("library.sqlite").path).folderNames() == [chrome + " / Dev": "Work"], "it is on disk")
        #expect(library.renameFolder(key: chrome + " / Dev", to: "Play"))
        #expect(library.folderNames() == [chrome + " / Dev": "Play"], "naming again replaces it")
    }

    @Test func anEmptyNameGivesBackTheOriginalOne() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        library.addBookmark(url: "https://a.example/", title: "A", folder: chrome + " / Dev")
        library.renameFolder(key: chrome + " / Dev", to: "Work")
        #expect(library.renameFolder(key: chrome + " / Dev", to: " \n "))
        #expect(library.folderNames().isEmpty)
        let groups = Library.groupBySource(library.folders(), names: library.folderNames())
        #expect(groups[0].folders[0].children.map(\.label) == ["Dev"])
        #expect(!library.renameFolder(key: "", to: "x"), "there is no folder with no key")
    }

    @Test func aLongNameIsCut() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        library.renameFolder(key: chrome, to: String(repeating: "x", count: Tab.maxNameLength + 40))
        #expect(library.folderNames()[chrome]?.count == Tab.maxNameLength)
    }

    @Test func aNameIsForTheLastPartOfTheKeyOnly() {
        let entry = Library.Entry(url: "https://a.example/", title: "A")
        let folders = [(name: chrome + " / Work / 2026", entries: [entry]), (name: chrome + " / Work / Other", entries: [entry]), (name: "Safari / Favorites", entries: [entry])]
        let names = [chrome + " / Work": "Job", chrome + " / Work / 2026": "This year", "Safari / Favorites": "Top"]
        let groups = Library.groupBySource(folders, names: names, section: { "[\($0)]" })
        let work = groups[0].folders[0].children[0]
        #expect(groups[0].folders[0].label == "[Bookmarks Bar]", "the folder above is as it was")
        #expect(work.label == "Job" && work.key == chrome + " / Work", "the key is the same")
        #expect(work.children.map(\.label) == ["This year", "Other"] && work.children.map(\.key) == [chrome + " / Work / 2026", chrome + " / Work / Other"])
        #expect(work.paths().map(\.path) == ["Job", "Job › This year", "Job › Other"], "the Move To menu shows them too")
        #expect(groups[1].folders.map(\.label) == ["Top"] && groups[1].folders.map(\.key) == ["Safari / Favorites"])
        #expect(Library.groupBySource(folders, section: { "[\($0)]" })[1].folders.map(\.label) == ["[Favorites]"], "without a name it is called what it was")
    }

    @Test func aTopFolderCanBeNamedToo() {
        let groups = Library.groupBySource([(name: chrome, entries: [])], names: [chrome: "Mine"])
        #expect(groups[0].folders.map(\.label) == ["Mine"] && groups[0].source == "Chrome")
    }

    @Test func removingAFolderRemovesTheNamesInsideIt() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        for key in [chrome + " / Work", chrome + " / Work / 2026", chrome + " / Work 2", chrome + " / Play"] {
            library.addBookmark(url: "https://a.example/", title: "A", folder: key)
            library.renameFolder(key: key, to: "named")
        }
        library.removeFolder(chrome + " / Work")
        #expect(Set(library.folderNames().keys) == [chrome + " / Work 2", chrome + " / Play"], "the folder and what is inside it, not a folder that only starts like it")
    }

    @Test func removingASourceRemovesItsNames() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        for key in [chrome, chrome + " / Work", "Arc Sidebar", "Arcade Bookmarks Bar"] {
            library.addBookmark(url: "https://a.example/", title: "A", folder: key)
            library.renameFolder(key: key, to: "named")
        }
        library.removeSource("Chrome")
        #expect(Set(library.folderNames().keys) == ["Arc Sidebar", "Arcade Bookmarks Bar"])
    }

    @Test func importingAgainKeepsTheName() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = chrome + " / Dev"
        #expect(try library.importBookmarks([(url: "https://a.example/", title: "A", folder: key)]) == 1)
        library.renameFolder(key: key, to: "Work")
        _ = try library.importBookmarks([(url: "https://a.example/", title: "A", folder: key), (url: "https://b.example/", title: "B", folder: key)])
        let read = try #require(library.readBookmarks())
        #expect(read.names == [key: "Work"])
        let groups = Library.groupBySource(read.folders, names: read.names)
        #expect(groups[0].folders[0].children.map(\.label) == ["Work"] && groups[0].folders[0].children[0].entries.count == 2)
    }

    @Test func aLibraryWithoutTheTableStillReadsItsBookmarks() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        library.addBookmark(url: "https://a.example/", title: "A", folder: chrome)
        try SQLite(path: folder.appendingPathComponent("library.sqlite").path).execute("DROP TABLE folder_names")
        let read = try #require(library.readBookmarks())
        #expect(read.names.isEmpty && read.folders.map(\.name) == [chrome])
        #expect(library.folderNames().isEmpty)
        // Opened again, it has the table back.
        #expect(Library(path: folder.appendingPathComponent("library.sqlite").path).renameFolder(key: chrome, to: "Mine"))
    }
}

extension SharedAgentState {
    @MainActor @Suite(.serialized)
    struct FolderRenameTests {
        private let key = "Chrome Bookmarks Bar / Folder Rename Test"

        private func rig(_ body: (Browser, SpaceStore) -> Void) {
            let box = Sandbox()
            let store = box.store()
            let browser = Browser(spaces: store)
            defer {
                browser.windowClosed()
                Library.shared.removeFolder(key)
            }
            Library.shared.addBookmark(url: "https://folder-rename.example/", title: "A", folder: key)
            body(browser, store)
        }

        private var name: String? { Library.shared.folderNames()[key] }

        @Test func unpinningAFolderBringsItsOpenTabsBackAsAGroupAndKeepsTheFolder() {
            rig { browser, store in
                let id = browser.spaceID
                let inner = key + " / Inner"
                for (n, folder) in [(1, key), (2, key), (3, inner)] {
                    Library.shared.addBookmark(url: "https://folder-rename.example/\(n)", title: "\(n)", folder: folder)
                    let tab = browser.openTab(url: URL(string: "https://folder-rename.example/\(n)"), activate: false)
                    browser.bind(tab, to: Browser.bookmarkKey(url: "https://folder-rename.example/\(n)", folder: folder))
                }
                let other = browser.openTab(url: URL(string: "https://elsewhere.example/"), activate: false)
                defer { Library.shared.removeFolder(inner) }
                store.pinFolder(key, in: id)
                #expect(browser.listedTabs.map(\.id) == [other.id], "the folder's tabs show with the folder")
                browser.unpinFolder(key, named: "Reading")
                #expect(!store.space(id).pinnedFolders.contains(key))
                let group = browser.groups.first { $0.name == "Reading" }
                #expect(group != nil)
                #expect(browser.tabs.filter { $0.groupID == group?.id }.count == 3, "the folder's tabs and the inner folder's are all back")
                #expect(browser.tabs.allSatisfy { $0.bookmarkKey == nil })
                #expect(browser.renamingGroup == nil)
                #expect(Library.shared.folders().first { $0.name == key }?.entries.count == 3, "the folder is still among the bookmarks, with all it had")
                // One tab alone comes back as a plain tab, and a folder with none open only goes.
                let lone = browser.openTab(url: URL(string: "https://folder-rename.example/1"), activate: false)
                browser.bind(lone, to: Browser.bookmarkKey(url: "https://folder-rename.example/1", folder: key))
                store.pinFolder(key, in: id)
                browser.unpinFolder(key, named: "Reading")
                #expect(lone.bookmarkKey == nil && lone.groupID == nil)
                store.pinFolder(key, in: id)
                browser.unpinFolder(key, named: "Reading")
                #expect(browser.groups.filter { $0.name == "Reading" }.count == 1)
            }
        }

        @Test func aDoubleClickLeavesTheFolderAsOpenAsItWasAndRenamesIt() {
            rig { browser, store in
                let id = browser.spaceID
                for open in [true, false] {
                    store.pinFolder(key, in: id)
                    if store.space(id).openFolders.contains("pin:" + key) != open { store.toggleOpen("pin:" + key, in: id) }
                    browser.clickFolder(openKey: "pin:" + key, clickCount: 1)
                    #expect(store.space(id).openFolders.contains("pin:" + key) == !open && browser.renamingFolder == nil, "a single click opens or closes it at once")
                    browser.clickFolder(openKey: "pin:" + key, clickCount: 2)
                    #expect(store.space(id).openFolders.contains("pin:" + key) == open && browser.renamingFolder == "pin:" + key, "the second click puts it back and renames")
                    browser.renamingFolder = nil
                }
            }
        }

        @Test func returnKeepsTheNameAndOffersToTakeItBack() {
            rig { browser, _ in
                browser.renamingFolder = "pin:" + key
                browser.finishRenamingFolder(key: key, scope: "pin:", shown: "Folder Rename Test", with: " Work ")
                #expect(name == "Work" && browser.renamingFolder == nil)
                #expect(browser.notice?.message == "Renamed the folder")
                browser.undoNotice()
                #expect(name == nil, "undoing it gives back the name it came with")
                browser.renamingFolder = "pin:" + key
                browser.finishRenamingFolder(key: key, scope: "pin:", shown: "Folder Rename Test", with: "First")
                browser.renamingFolder = "pin:" + key
                browser.finishRenamingFolder(key: key, scope: "pin:", shown: "First", with: "Second")
                browser.undoNotice()
                #expect(name == "First", "and the name it had before this one")
            }
        }

        @Test func escapeKeepsNothingAndALateFocusLossDoesNotEither() {
            rig { browser, _ in
                browser.renamingFolder = key
                browser.finishRenamingFolder(key: key, scope: "", shown: "Folder Rename Test", with: nil) // Esc
                browser.finishRenamingFolder(key: key, scope: "", shown: "Folder Rename Test", with: "cancelled text") // the field losing focus after that
                #expect(name == nil && browser.notice == nil)
            }
        }

        @Test func anUnchangedNameChangesNothingAndAnEmptyOneResetsIt() {
            rig { browser, _ in
                browser.renamingFolder = key
                browser.finishRenamingFolder(key: key, scope: "", shown: "Folder Rename Test", with: "Folder Rename Test ")
                #expect(name == nil && browser.renamingFolder == nil && browser.notice == nil, "opening the field and leaving it fixes nothing")
                browser.renamingFolder = key
                browser.finishRenamingFolder(key: key, scope: "", shown: "Folder Rename Test", with: "  ")
                #expect(name == nil && browser.notice == nil, "an empty name for a folder that has none")
                Library.shared.renameFolder(key: key, to: "Work")
                browser.renamingFolder = key
                browser.finishRenamingFolder(key: key, scope: "", shown: "Work", with: "")
                #expect(name == nil && browser.notice?.message == "Renamed the folder", "an empty name takes the name away")
                browser.undoNotice()
                #expect(name == "Work")
            }
        }

        @Test func theSamePinnedAndUnderBookmarksFolderIsRenamedOnlyWhereItWasStarted() {
            rig { browser, _ in
                browser.renamingFolder = "pin:" + key
                browser.finishRenamingFolder(key: key, scope: "", shown: "Folder Rename Test", with: "late") // the other row's field losing focus
                #expect(name == nil && browser.renamingFolder == "pin:" + key)
            }
        }

        @Test func showingAnotherSpaceEndsTheRename() {
            let box = Sandbox()
            let browser = Browser(spaces: box.store())
            defer { browser.windowClosed() }
            browser.renamingFolder = "pin:" + key
            let other = browser.spaces.add(name: "Other", symbol: "star", tint: .blue, isProfile: false)
            browser.switchSpace(to: other.id, opensBar: false)
            #expect(browser.renamingFolder == nil)
        }

        @Test func renamingChangesNeitherThePinsNorTheOpenFoldersNorTheBookmarks() {
            rig { browser, store in
                let id = browser.spaceID
                store.pinFolder(key, in: id)
                store.toggleOpen("pin:" + key, in: id)
                store.toggleOpen(key, in: id)
                let before = store.space(id)
                browser.renamingFolder = "pin:" + key
                browser.finishRenamingFolder(key: key, scope: "pin:", shown: "Folder Rename Test", with: "Work")
                #expect(name == "Work")
                #expect(store.space(id).pinnedFolders == before.pinnedFolders && store.space(id).openFolders == before.openFolders)
                #expect(Library.shared.folders().contains { $0.name == key && $0.entries.map(\.url) == ["https://folder-rename.example/"] }, "its bookmarks stay under the same key")
            }
        }

        @Test func aNameTypedIsCutAndTrimmed() {
            #expect(Browser.renamedFolder("  Work ", shown: "Old") == "Work")
            #expect(Browser.renamedFolder("Old ", shown: "Old") == nil)
            #expect(Browser.renamedFolder("   ", shown: "Old") == "", "an empty one resets")
            #expect(Browser.renamedFolder(String(repeating: "x", count: Tab.maxNameLength + 5), shown: "Old")?.count == Tab.maxNameLength)
        }
    }
}
