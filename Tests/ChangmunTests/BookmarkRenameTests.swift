import Foundation
import Testing
@testable import Changmun

/// A title the user gives a bookmark or favorite, kept in the library; and a group's header taking a double-click.
@MainActor
struct LibraryRenameTests {
    private func library() throws -> (Library, URL) {
        let folder = try persistenceScratchFolder()
        return (Library(path: folder.appendingPathComponent("library.sqlite").path), folder)
    }

    @Test func aTitleIsKeptTrimmedAndAnEmptyOneIsIgnored() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        library.addBookmark(url: "https://a.example/", title: "Old", folder: "")
        library.addBookmark(url: "https://a.example/", title: "Other", folder: "Chrome Bookmarks Bar")
        #expect(library.renameBookmark(url: "https://a.example/", folder: "", title: "  Mail \n"))
        #expect(library.favorites().map(\.title) == ["Mail"])
        #expect(library.folders().first?.entries.map(\.title) == ["Other"], "the same address in another folder is another bookmark")
        #expect(!library.renameBookmark(url: "https://a.example/", folder: "", title: "   "))
        #expect(library.favorites().map(\.title) == ["Mail"])
        #expect(Library(path: folder.appendingPathComponent("library.sqlite").path).favorites().map(\.title) == ["Mail"], "it is on disk")
    }

    @Test func aLongTitleIsCut() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        library.addBookmark(url: "https://a.example/", title: "Old", folder: "")
        library.renameBookmark(url: "https://a.example/", folder: "", title: String(repeating: "x", count: Tab.maxNameLength + 40))
        #expect(library.favorites().first?.title.count == Tab.maxNameLength)
    }

    @Test func importingAgainKeepsTheTitleTheUserSet() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        let folderName = "Chrome Bookmarks Bar"
        #expect(try library.importBookmarks([(url: "https://a.example/", title: "From Chrome", folder: folderName)]) == 1)
        library.renameBookmark(url: "https://a.example/", folder: folderName, title: "Mine")
        _ = try library.importBookmarks([(url: "https://a.example/", title: "Changed in Chrome", folder: folderName),
                                         (url: "https://b.example/", title: "New", folder: folderName)])
        let entries = library.folders().first?.entries ?? []
        #expect(entries.map(\.title) == ["Mine", "New"], "a bookmark already here is left as it is, new ones are added")
        library.moveBookmark(url: "https://a.example/", from: folderName, to: "")
        #expect(library.favorites().map(\.title) == ["Mine"], "the title goes along when it moves")
    }

    @Test func aTitleIsChosenOnlyIfItIsNewAndNotEmpty() {
        #expect(Browser.renamedTitle("  Mail ", shown: "Old") == "Mail")
        #expect(Browser.renamedTitle("   ", shown: "Old") == nil)
        #expect(Browser.renamedTitle("Old ", shown: " Old") == nil, "opening the field and leaving it fixes nothing")
        #expect(Browser.renamedTitle("https://a.example/", shown: "https://a.example/") == nil, "a bookmark with no title shows its address")
        #expect(Browser.renamedTitle(String(repeating: "x", count: Tab.maxNameLength + 5), shown: "Old")?.count == Tab.maxNameLength)
    }
}

extension SharedAgentState {
    @MainActor @Suite(.serialized)
    struct BookmarkRenameTests {
        private let url = "https://rename-bookmark.example/"

        private func rig(_ body: (Browser, String, String) -> Void) {
            let browser = Browser()
            defer { browser.windowClosed() }
            let folder = browser.favoritesFolder
            Library.shared.addBookmark(url: url, title: "Old", folder: folder)
            defer { Library.shared.removeBookmark(url: url, folder: folder) }
            body(browser, folder, Browser.bookmarkKey(url: url, folder: folder))
        }

        private var title: String? { Library.shared.favorites().first { $0.url == url }?.title }

        @Test func returnKeepsTheNewTitleAndOffersToTakeItBack() {
            rig { browser, folder, key in
                browser.renamingBookmark = key
                browser.finishRenamingBookmark(url: url, folder: folder, title: "Old", with: " New ")
                #expect(title == "New" && browser.renamingBookmark == nil)
                #expect(browser.notice?.message == "Renamed the bookmark")
                browser.undoNotice()
                #expect(title == "Old")
            }
        }

        @Test func escapeKeepsNothingAndALateFocusLossDoesNotEither() {
            rig { browser, folder, key in
                browser.renamingBookmark = key
                browser.finishRenamingBookmark(url: url, folder: folder, title: "Old", with: nil) // Esc
                browser.finishRenamingBookmark(url: url, folder: folder, title: "Old", with: "cancelled text") // the field losing focus after that
                #expect(title == "Old" && browser.notice == nil)
            }
        }

        @Test func anUnchangedOrEmptyNameChangesNothing() {
            rig { browser, folder, key in
                browser.renamingBookmark = key
                browser.finishRenamingBookmark(url: url, folder: folder, title: "Old", with: "Old")
                #expect(title == "Old" && browser.renamingBookmark == nil && browser.notice == nil)
                browser.renamingBookmark = key
                browser.finishRenamingBookmark(url: url, folder: folder, title: "Old", with: "  ")
                #expect(title == "Old" && browser.notice == nil)
            }
        }

        @Test func anotherBookmarksFocusLossDoesNotCloseTheOneBeingRenamed() {
            rig { browser, folder, key in
                browser.renamingBookmark = key
                browser.finishRenamingBookmark(url: "https://other.example/", folder: folder, title: "Other", with: "late")
                #expect(browser.renamingBookmark == key)
            }
        }

        @Test func showingAnotherSpaceEndsTheRename() {
            let box = Sandbox()
            let browser = Browser(spaces: box.store())
            defer { browser.windowClosed() }
            browser.renamingBookmark = "key"
            let other = browser.spaces.add(name: "Other", symbol: "star", tint: .blue, isProfile: false)
            browser.switchSpace(to: other.id, opensBar: false)
            #expect(browser.renamingBookmark == nil)
        }

        @Test func aDoubleClickOnAGroupHeaderLeavesItAsOpenAsItWasAndRenamesIt() throws {
            let browser = Browser()
            defer { browser.windowClosed() }
            let a = browser.openTab(url: URL(string: "https://a.example/"), activate: false)
            let b = browser.openTab(url: URL(string: "https://b.example/"), activate: false)
            let id = try #require(browser.group([a.id, b.id], name: "Work"))
            browser.renamingGroup = nil
            for open in [true, false] {
                if browser.groups.first(where: { $0.id == id })?.isOpen != open { browser.toggleGroup(id) }
                browser.clickGroup(id, clickCount: 1)
                #expect(browser.groups.first { $0.id == id }?.isOpen == !open && browser.renamingGroup == nil, "a single click folds at once")
                browser.clickGroup(id, clickCount: 2)
                #expect(browser.groups.first { $0.id == id }?.isOpen == open && browser.renamingGroup == id, "the second click puts it back and renames")
                browser.renamingGroup = nil
            }
        }
    }
}
