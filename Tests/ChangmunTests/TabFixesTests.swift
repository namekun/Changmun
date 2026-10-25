import Foundation
import Testing
@testable import Changmun

extension SharedAgentState {
    /// Tabs that were bound to bookmarks, tab groups and the session: the places a tab could end up where the sidebar can't show it.
    @MainActor
    struct TabFixesTests {
        private func browser(_ count: Int, spaces: SpaceStore? = nil) -> Browser {
            let browser = spaces.map { Browser(spaces: $0) } ?? Browser()
            for n in 1...count { browser.openTab(url: URL(string: "https://site\(n).example/"), activate: false) }
            return browser
        }

        private func ids(_ b: Browser) -> [Int] { b.tabs.map(\.id) }

        // MARK: Bookmarks deleted while a tab was closed or the session was saved

        @Test func aReopenedTabForgetsABookmarkThatWasDeletedMeanwhile() throws {
            let folder = "Fix T1 \(UUID())"
            let kept = Browser.bookmarkKey(url: "https://site1.example/", folder: folder)
            let gone = Browser.bookmarkKey(url: "https://site2.example/", folder: folder)
            Library.shared.addBookmark(url: "https://site1.example/", title: "1", folder: folder)
            Library.shared.addBookmark(url: "https://site2.example/", title: "2", folder: folder)
            defer { Library.shared.removeFolder(folder) }
            let b = browser(2)
            b.bind(b.tabs[0], to: kept)
            b.bind(b.tabs[1], to: gone)
            let (one, two) = (b.tabs[0].id, b.tabs[1].id)
            b.close(two)
            b.close(one)
            Library.shared.removeBookmark(url: "https://site2.example/", folder: folder)
            b.reopenClosedTab()
            b.reopenClosedTab()
            let reopened = b.tabs.map(\.bookmarkKey)
            #expect(reopened.contains(kept) && !reopened.contains(gone), "the bookmark that is still there is kept; the deleted one is not")
            #expect(b.listedTabs.count == 1 && b.listedTabs.first?.url?.host() == "site2.example", "the tab is in the tab list, not out of sight")
        }

        @Test func aRestoredTabForgetsABookmarkThatWasDeletedMeanwhile() throws {
            let folder = "Fix T1 restore \(UUID())"
            Library.shared.addBookmark(url: "https://site1.example/", title: "1", folder: folder)
            defer { Library.shared.removeFolder(folder) }
            let saved = Browser.SavedSession(tabs: [
                Browser.SavedTab(url: "https://site1.example/", title: "1", bookmarkKey: Browser.bookmarkKey(url: "https://site1.example/", folder: folder)),
                Browser.SavedTab(url: "https://site2.example/", title: "2", bookmarkKey: Browser.bookmarkKey(url: "https://site2.example/", folder: folder)),
            ], active: 0, previous: nil, groups: [])
            let b = Browser()
            b.restore(saved)
            #expect(b.tabs.map { $0.bookmarkKey != nil } == [true, false])
            #expect(b.listedTabs.map { $0.url?.host() } == ["site2.example"])
        }

        // MARK: Moving a bookmark between folders

        @Test func movingABookmarkLeavesTheTabsOfOtherSpacesInTheTabList() throws {
            let box = Sandbox()
            let store = box.store()
            let work = store.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
            let folder = "Fix T2 \(UUID())", url = "https://site1.example/"
            Library.shared.addBookmark(url: url, title: "1", folder: folder)
            defer { Library.shared.removeFolder(folder); Library.shared.removeBookmark(url: url, folder: Library.favoritesFolder) }
            let b = Browser(spaces: store)
            b.focused()
            defer { b.windowClosed() }
            let key = Browser.bookmarkKey(url: url, folder: folder)
            let home = b.openTab(url: URL(string: url), activate: false)
            let away = b.openTab(url: URL(string: url), activate: false, space: work.id)
            b.bind(home, to: key)
            away.bookmarkKey = key
            Browser.moveBookmark(url: url, from: folder, to: Library.favoritesFolder)
            #expect(home.bookmarkKey == Browser.bookmarkKey(url: url, folder: Library.favoritesFolder), "the favorites are the first space's: its tab goes with the bookmark")
            #expect(away.bookmarkKey == nil, "a tab of another space has no such favorite to sit in")
        }

        // MARK: Groups

        @Test func undoingCloseAllInAGroupBringsTheTabsBackInOrder() throws {
            let b = browser(4)
            let all = ids(b)
            let group = try #require(b.group([all[1], all[2]], name: "G"))
            b.activate(all[0])
            b.closeGroup(group)
            #expect(ids(b) == [all[0], all[3]])
            b.undoNotice()
            #expect(b.tabs.map { $0.url?.host() } == ["site1.example", "site2.example", "site3.example", "site4.example"])
            #expect(b.tabs.map(\.groupID) == [nil, group, group, nil])
        }

        @Test func aReopenedGroupTabComesBackWhereItWasInTheGroup() throws {
            let b = browser(3)
            let all = ids(b)
            let group = try #require(b.group(all, name: "G"))
            b.close(all[1])
            b.reopenClosedTab()
            #expect(b.tabs.map(\.groupID) == [group, group, group])
            #expect(b.tabs.map { $0.url?.host() } == ["site1.example", "site2.example", "site3.example"])
        }

        @Test func undoingATidyPutsTheTabsBackWhereTheyWere() {
            let b = Browser()
            let a = b.openTab(url: URL(string: "https://a.example/"))
            b.openTab(url: URL(string: "https://x.example/"))
            let c = b.openTab(url: URL(string: "https://c.example/"))
            b.openTab(url: URL(string: "https://y.example/"))
            let d = b.openTab(url: URL(string: "https://d.example/"))
            let before = ids(b)
            b.apply([TabSorter.Group(name: "One", ids: [a.id, c.id, d.id])])
            #expect(ids(b) != before)
            b.undoTidy()
            #expect(ids(b) == before)
            #expect(b.tabs.allSatisfy { $0.groupID == nil } && b.groups.isEmpty)
        }

        // MARK: The session

        @Test func pinningATabChangesWhatTheSessionSaves() {
            let b = browser(2)
            b.focused()
            defer { b.windowClosed() }
            let before = Browser.sessionSignature()
            b.bind(b.tabs[0], to: Browser.bookmarkKey(url: "https://site1.example/", folder: Library.favoritesFolder))
            #expect(Browser.sessionSignature() != before)
        }

        // MARK: Pinned folders

        @Test func aFolderInsideAPinnedFolderIsNotPinnedAgain() {
            var space = Space(name: "S", symbol: "house", tint: .blue)
            space.pinnedFolders = ["Arc Work", "Arc Work / Q", "Arc Workshop", "Arc Other / Z"]
            #expect(space.hasPinnedAncestor("Arc Work / Q") && space.hasPinnedAncestor("Arc Work / Q / R"))
            #expect(!space.hasPinnedAncestor("Arc Work") && !space.hasPinnedAncestor("Arc Workshop"), "a folder whose name merely begins the same is not inside")
            #expect(space.topPinnedFolders == ["Arc Work", "Arc Workshop", "Arc Other / Z"], "the pinned child shows inside its parent, not a second time at the top")
        }

        @Test func pinningAFolderInsideAPinnedFolderDoesNothing() {
            let store = Sandbox().store()
            let id = Space.defaultID
            store.pinFolder("Arc Work", in: id)
            store.pinFolder("Arc Work / Q", in: id)
            #expect(store.space(id).pinnedFolders == ["Arc Work"])
        }

        // MARK: Dragging

        @Test func aCancelledDragIsForgottenOnceTheMouseIsUp() {
            _ = SidebarDrag.folder("Arc Work")
            SidebarDrag.dragEnded(buttons: 1)
            #expect(SidebarDrag.dragging == .folder, "still being held")
            SidebarDrag.dragEnded(buttons: 0)
            #expect(SidebarDrag.dragging == nil && SidebarDrag.carriesTab)
        }

        @Test func aDropCarriesTheAddressOfItsPageToOtherAppsAndNothingForFolders() {
            let b = browser(1)
            b.focused()
            defer { b.windowClosed() }
            let tab = b.tabs[0]
            #expect(SidebarDrag.address(of: SidebarDrag.bookmark("https://a.example/x?y=1", in: "Arc Reading"))?.absoluteString == "https://a.example/x?y=1")
            #expect(SidebarDrag.address(of: SidebarDrag.tab(tab.id))?.absoluteString == "https://site1.example/")
            #expect(SidebarDrag.address(of: "https://c.example/page")?.absoluteString == "https://c.example/page")
            #expect(SidebarDrag.address(of: SidebarDrag.folder("Arc Reading")) == nil)
            #expect(SidebarDrag.address(of: SidebarDrag.group(UUID())) == nil)
            SidebarDrag.dragEnded(buttons: 0)
        }

        @Test func aLinkDroppedAtAPlaceStaysThereInsteadOfSortingIntoAGroup() throws {
            let b = browser(2)
            let target = b.tabs[0].id
            #expect(SidebarDrag.drop(["https://dropped.example/"], onTab: target, browser: b))
            let dropped = try #require(b.tabs.first { $0.url?.host() == "dropped.example" })
            #expect(!dropped.sortsIntoGroup)
            #expect(SidebarDrag.dropAtEnd(["https://end.example/"], browser: b))
            #expect(b.tabs.last?.url?.host() == "end.example" && b.tabs.last?.sortsIntoGroup == false)
            for tab in b.tabs { tab.sleep() }
        }

        // MARK: Private windows

        @Test func aPrivateWindowsTabCannotBeSavedToTheLibrary() throws {
            let url = "https://private-\(UUID()).example/"
            let b = Browser(isPrivate: true)
            let tab = b.openTab(url: URL(string: url))
            defer { tab.sleep() }
            let favorites = b.favoritesFolder, folder = "Fix T8 \(UUID())"
            defer { Library.shared.removeFolder(folder) }
            #expect(!SidebarDrag.drop([SidebarDrag.tab(tab.id)], onFavorite: nil, browser: b))
            #expect(!SidebarDrag.drop([SidebarDrag.tab(tab.id)], onFolder: folder, browser: b))
            #expect(!Library.shared.isFavorite(url, in: favorites) && !Library.shared.isFavorite(url, in: folder))
            #expect(tab.bookmarkKey == nil)
            let group = try #require(b.group([tab.id]))
            #expect(!b.saveGroup(group, to: .pinned(before: nil)))
            #expect(Library.shared.folders().allSatisfy { $0.entries.allSatisfy { $0.url != url } })
        }
    }
}
