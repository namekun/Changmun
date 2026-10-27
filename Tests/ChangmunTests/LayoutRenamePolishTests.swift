import Foundation
import Testing
@testable import Changmun

/// Naming things with the tabs on top, where the strip and the sidebar over the page both show the tabs; and the strip's smaller rules.
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

        // MARK: One field at a time

        @Test func theStripTypesTheNameUnlessTheSidebarIsOpenOverThePage() {
            let (b, tab, group) = browser()
            defer { b.windowClosed() }
            b.renamingTab = tab.id
            b.renamingGroup = group
            #expect(b.stripRenaming(tab: tab.id) && b.stripRenaming(group: group))
            #expect(!b.stripRenaming(tab: tab.id + 1) && !b.stripRenaming(group: UUID()), "only the one being named")
            b.showSidebarOverlay = true
            #expect(!b.stripRenaming(tab: tab.id) && !b.stripRenaming(group: group), "the overlay's rows type it, so the two fields do not fight for the focus")
            #expect(b.renamingTab == tab.id && b.renamingGroup == group, "opening the overlay does not end it")
        }

        @Test func closingTheOverlayEndsTheNamesBeingTyped() {
            let (b, tab, group) = browser()
            defer { b.windowClosed() }
            b.showSidebarOverlay = true
            b.renamingTab = tab.id
            b.renamingGroup = group
            b.renamingBookmark = "key"
            b.renamingFolder = "folder"
            b.showSidebarOverlay = false
            #expect(b.renamingTab == nil && b.renamingGroup == nil && b.renamingBookmark == nil && b.renamingFolder == nil)
            #expect(!b.stripRenaming(tab: tab.id), "the strip's field does not open in its place")
        }

        @Test func aNameTypedInTheStripSurvivesTheOverlayBeingPutAwayAgain() {
            let (b, tab, _) = browser()
            defer { b.windowClosed() }
            b.renamingTab = tab.id
            b.showSidebarOverlay = false
            #expect(b.renamingTab == tab.id, "putting away what was never open changes nothing")
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

        // MARK: Esc

        @Test func escPutsTheOverlayAwayUnlessSomethingElseHasTheKey() throws {
            let (b, _, _) = browser()
            defer { b.windowClosed() }
            #expect(!b.escapeClosesSidebarOverlay(typing: false), "nothing to put away")
            b.showSidebarOverlay = true
            #expect(b.escapeClosesSidebarOverlay(typing: false))
            #expect(!b.escapeClosesSidebarOverlay(typing: true), "a field being typed in keeps its Esc")
            b.commandBar = .newTab
            #expect(!b.escapeClosesSidebarOverlay(typing: false), "the command bar's")
            b.commandBar = nil
            b.showOnboarding = true
            #expect(!b.escapeClosesSidebarOverlay(typing: false))
            b.showOnboarding = false
            #expect(b.escapeClosesSidebarOverlay(typing: false))
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

        // MARK: The strip

        @Test func manyFavoritesScrollWithinTheRoomThatLeavesTheTabsTheirLeast() throws {
            let strip: CGFloat = 900, leading: CGFloat = 80
            #expect(TabStrip.favoritesScrollWidth(count: 0, strip: strip, leading: leading) == nil)
            #expect(TabStrip.favoritesScrollWidth(count: 4, strip: strip, leading: leading) == nil, "a few fit beside the tabs")
            let width = try #require(TabStrip.favoritesScrollWidth(count: 40, strip: strip, leading: leading))
            #expect(width < strip - leading - 120 - Metrics.control, "the tabs keep room for one of the least width and the plus button")
            #expect(width > 34, "and the favorites keep more than one tile")
            #expect(try #require(TabStrip.favoritesScrollWidth(count: 40, strip: 100, leading: leading)) == TabStrip.favoriteWidth,
                    "a window too narrow for either still shows a tile")
            let limit = (1...60).first { TabStrip.favoritesScrollWidth(count: $0, strip: strip, leading: leading) != nil }
            #expect(limit != nil && limit! > 4, "it begins to scroll where they stop fitting, not before")
        }

        @Test func theWheelMovesTheTabsSidewaysOnlyWhenTheyOverflow() {
            typealias W = StripWheelScroll
            #expect(W.offset(current: 0, delta: -30, content: 400, viewport: 400) == nil, "all fit: nothing to move")
            #expect(W.offset(current: 0, delta: -30, content: 300, viewport: 400) == nil)
            #expect(W.offset(current: 100, delta: -30, content: 800, viewport: 400) == 130, "the wheel toward you moves on")
            #expect(W.offset(current: 100, delta: 30, content: 800, viewport: 400) == 70)
            #expect(W.offset(current: 10, delta: 30, content: 800, viewport: 400) == 0, "not past the start")
            #expect(W.offset(current: 390, delta: -30, content: 800, viewport: 400) == 400, "nor the end")
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
