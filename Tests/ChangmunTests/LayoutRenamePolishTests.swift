import Foundation
import Testing
@testable import Changmun

/// Naming groups, folders and bookmarks.
extension SharedAgentState {
    @MainActor @Suite(.serialized)
    struct LayoutRenamePolishTests {
        private func browser() -> (Browser, Tab, UUID) {
            let b = Browser()
            let a = b.openTab(url: URL(string: "https://a.example/"), activate: false)
            let c = b.openTab(url: URL(string: "https://b.example/"), activate: false)
            let group = b.group([a.id, c.id], name: "Work")!
            return (b, a, group)
        }

        @Test func showingAnotherSpaceEndsTheGroupNameToo() {
            let box = Sandbox()
            let b = Browser(spaces: box.store())
            defer { b.windowClosed() }
            b.renamingGroup = UUID()
            let other = b.spaces.add(name: "Other", symbol: "star", tint: .blue, isProfile: false)
            b.switchSpace(to: other.id, opensBar: false)
            #expect(b.renamingGroup == nil)
        }

        // MARK: Group names

        @Test func aGroupNameIsCut() {
            let (b, _, group) = browser()
            defer { b.windowClosed() }
            b.rename(group, to: String(repeating: "g", count: Tab.maxNameLength + 30))
            #expect(b.groups.first { $0.id == group }?.name.count == Tab.maxNameLength)
            b.rename(group, to: "  Short \n")
            #expect(b.groups.first { $0.id == group }?.name == "Short")
        }

        // MARK: Folder and bookmark names

        @Test func aFolderNameLongerThanTheCapIsLeftAloneWhenTheFieldIsLeftUntouched() {
            let long = String(repeating: "f", count: Tab.maxNameLength + 25)
            #expect(Browser.renamedFolder(long, shown: long) == nil, "what the field opened with is not a rename")
            #expect(Browser.renamedFolder(" " + long + " ", shown: long) == nil)
            #expect(Browser.renamedFolder(long + "!", shown: long)?.count == Tab.maxNameLength, "a change is cut")
        }

        @Test func undoingARenameBringsBackTheTitleExactly() throws {
            let url = "https://undo-exact.example/"
            let browser = Browser()
            defer { browser.windowClosed() }
            let folder = browser.favoritesFolder
            defer { Library.shared.removeBookmark(url: url, folder: folder) }
            let long = " " + String(repeating: "t", count: Tab.maxNameLength + 40) + "  "
            for original in ["  Spaced out \n", long, "   "] {
                Library.shared.addBookmark(url: url, title: original, folder: folder)
                browser.renamingBookmark = Browser.bookmarkKey(url: url, folder: folder)
                browser.finishRenamingBookmark(url: url, folder: folder, title: original, with: "New")
                #expect(Library.shared.favorites().first { $0.url == url }?.title == "New")
                browser.undoNotice()
                #expect(Library.shared.favorites().first { $0.url == url }?.title == original)
                Library.shared.removeBookmark(url: url, folder: folder)
            }
        }
    }
}

struct WindowDragThresholdTests {
    @Test func theWindowFollowsOnlyOnceThePointerHasMovedPastAFewPoints() {
        let down = NSPoint(x: 100, y: 20)
        #expect(!WindowDragArea.movedEnough(from: down, to: down))
        #expect(!WindowDragArea.movedEnough(from: down, to: NSPoint(x: 101, y: 21)), "a tremor is not a drag")
        #expect(!WindowDragArea.movedEnough(from: down, to: NSPoint(x: 103, y: 20)), "the threshold itself is not past it")
        #expect(WindowDragArea.movedEnough(from: down, to: NSPoint(x: 104, y: 20)))
        #expect(WindowDragArea.movedEnough(from: down, to: NSPoint(x: 98, y: 17)), "any direction, by the distance")
        #expect(WindowDragArea.movedEnough(from: down, to: NSPoint(x: 101, y: 21), threshold: 1))
    }
}
