import AppKit
import Foundation
import Testing
@testable import Changmun

extension SharedAgentState {
    /// The tabs as the sidebar shows them: the order the keys step through, closing several, and what can be taken back.
    @MainActor @Suite(.serialized)
    struct SidebarTabsTests {
        private func browser(_ count: Int) -> Browser {
            let browser = Browser(spaces: Sandbox().store())
            for n in 1...count { browser.openTab(url: URL(string: "https://site\(n).example/"), activate: false) }
            return browser
        }

        private func entry(_ address: String) -> Library.Entry { Library.Entry(url: address, title: "") }

        /// A tab bound to a bookmark, as a click on the bookmark opens it.
        private func bookmarkTab(_ b: Browser, _ address: String, in folder: String) -> Tab {
            let tab = b.openTab(url: URL(string: address), activate: false)
            tab.bookmarkKey = Browser.bookmarkKey(url: address, folder: folder)
            return tab
        }

        // MARK: The sidebar's order

        @Test func theOrderIsTheBookmarksDrawnThenTheListedTabsEachOnce() {
            #expect(Browser.sidebarOrder(drawn: ["a", "b", "c"], bound: ["c": 3, "a": 1], listed: [7, 8]) == [1, 3, 7, 8])
            #expect(Browser.sidebarOrder(drawn: [], bound: [:], listed: [7, 8]) == [7, 8])
            #expect(Browser.sidebarOrder(drawn: ["a"], bound: ["a": 7], listed: [7, 8]) == [7, 8], "no tab twice")
        }

        @Test func steppingGoesRoundAndNumbersCountDownTheSidebar() {
            let order = [5, 6, 7]
            #expect(Browser.step(from: 5, by: 1, in: order) == 6)
            #expect(Browser.step(from: 7, by: 1, in: order) == 5)
            #expect(Browser.step(from: 5, by: -1, in: order) == 7)
            #expect(Browser.step(from: 99, by: 1, in: order) == 5, "from a tab not in the sidebar, the first")
            #expect(Browser.step(from: 99, by: -1, in: order) == 7, "or the last")
            #expect(Browser.step(from: 5, by: 1, in: []) == nil)
            #expect(Browser.numbered(1, in: order) == 5 && Browser.numbered(8, in: order) == 7 && Browser.numbered(9, in: order) == 7)
        }

        @Test func favoritesAndPinnedBookmarkTabsComeFirstInTheOrderTheyAreDrawn() {
            let b = browser(2)
            defer { b.windowClosed() }
            let loose = b.tabs.map(\.id)
            let favorites = b.favoritesFolder
            let second = bookmarkTab(b, "https://fav2.example/", in: favorites), first = bookmarkTab(b, "https://fav1.example/", in: favorites)
            let pinned = bookmarkTab(b, "https://pin.example/", in: "Work")
            b.spaces.pinFolder("Work", in: b.spaceID)
            b.spaces.toggleOpen("pin:Work", in: b.spaceID)
            let folder = Library.Folder(key: "Work", label: "Work", entries: [entry("https://other.example/"), entry("https://pin.example/")])
            let order = b.sidebarTabs(favorites: [entry("https://fav1.example/"), entry("https://none.example/"), entry("https://fav2.example/")], pinned: [folder])
            #expect(order.map(\.id) == [first.id, second.id, pinned.id] + loose)
            // From a favorite's tab the next one is the next tab down, not the first loose tab.
            #expect(Browser.step(from: second.id, by: 1, in: order.map(\.id)) == pinned.id)
            #expect(Browser.step(from: loose[0], by: -1, in: order.map(\.id)) == pinned.id)
        }

        // MARK: What a row says

        @Test func aTabsTooltipIsItsWholeTitleThenItsAddress() {
            #expect(Accessibility.tabHelp(title: "A long title", address: "https://a.example/", isStart: false) == "A long title\nhttps://a.example/")
            #expect(Accessibility.tabHelp(title: "https://a.example/", address: "https://a.example/", isStart: false) == "https://a.example/")
            #expect(Accessibility.tabHelp(title: "Untitled", address: nil, isStart: false) == "Untitled")
            #expect(Accessibility.tabHelp(title: "", address: nil, isStart: true) == "New Tab")
        }

        @Test func statesShownByAFadeADotOrABadgeAreSaidInWords() {
            #expect(Accessibility.tabHelp(title: "A", address: "https://a.example/", isStart: false, asleep: true) == "A\nhttps://a.example/\nAsleep: click to wake")
            #expect(Accessibility.bookmarkTabValue(.closed) == "No tab open" && Accessibility.bookmarkTabValue(.open) == "Open in the background")
            #expect(Accessibility.bookmarkHelp("Mail", .closed) == "Mail\nNo tab open")
            #expect(Accessibility.bookmarkHelp("Mail", .open) == "Mail\nOpen in the background")
            #expect(Accessibility.bookmarkHelp("Mail", .shown) == "Mail")
            #expect(Accessibility.spaceHelp("Work", isProfile: true) == "Work\nHas its own logins" && Accessibility.spaceHelp("Home", isProfile: false) == "Home")
        }

        // MARK: Undo

        @Test func closingOneTabOffersUndoButNotForAStartTabOrAnEmptyOne() {
            #expect(Browser.offersUndo(isStart: false, url: URL(string: "https://a.example/")))
            #expect(!Browser.offersUndo(isStart: true, url: nil))
            #expect(!Browser.offersUndo(isStart: false, url: nil))
            let b = browser(2)
            defer { b.windowClosed() }
            let first = b.tabs[0]
            first.customTitle = "First"
            b.closeTab(first.id)
            #expect(b.notice?.message == "Closed “First”")
            b.undoNotice()
            #expect(b.tabs.count == 2 && b.tabs[0].url == URL(string: "https://site1.example/") && b.tabs[0].customTitle == "First")
            b.notice = nil
            let start = b.openTab(url: nil, start: true)
            b.closeTab(start.id)
            #expect(b.notice == nil && b.tab(start.id) == nil)
        }

        @Test func undoShowsOverThePageOnlyWhileTheSidebarIsHiddenAndNotInFocusMode() {
            #expect(!Browser.undoOnPage(sidebarShown: true, focusMode: false))
            #expect(Browser.undoOnPage(sidebarShown: false, focusMode: false))
            #expect(!Browser.undoOnPage(sidebarShown: false, focusMode: true), "focus mode shows no notices")
        }

        // MARK: Closed tabs across a restart

        @Test func closedTabsAreKeptWithTheSessionAndComeBackAfterARestart() throws {
            let spaces = Sandbox().store()
            let b = Browser(spaces: spaces)
            defer { b.windowClosed() }
            for n in 1...3 { b.openTab(url: URL(string: "https://site\(n).example/"), activate: false) }
            b.tabs[1].customTitle = "Kept"
            b.close(b.tabs[1].id)
            let data = try JSONEncoder().encode(Browser.SavedWindows(windows: [b.savedSession]))
            let restored = Browser(spaces: spaces)
            defer { restored.windowClosed() }
            restored.restore(try #require(Browser.SavedWindows.decode(data).first))
            #expect(restored.closedTabs.map(\.url) == [URL(string: "https://site2.example/")])
            restored.reopenClosedTab()
            #expect(restored.tabs.map(\.url?.absoluteString) == (1...3).map { "https://site\($0).example/" } && restored.tabs[1].customTitle == "Kept")
        }

        @Test func aPrivateWindowKeepsNoClosedTabsAndOnlyTheLastOnesAreKept() {
            let b = Browser(isPrivate: true)
            defer { b.windowClosed() }
            b.closedTabs = [Browser.ClosedTab(url: URL(string: "https://private.example/"), title: "P", index: 0, space: b.spaceID)]
            #expect(b.savedSession.closed == nil)
            let normal = browser(1)
            defer { normal.windowClosed() }
            normal.closedTabs = (0..<30).map { Browser.ClosedTab(url: URL(string: "https://c\($0).example/"), title: "", index: 0, space: normal.spaceID) }
            #expect(normal.savedSession.closed?.count == Browser.keptClosedTabs)
            #expect(normal.savedSession.closed?.last?.url == URL(string: "https://c29.example/"), "the most recent")
        }

        @Test func aSessionFromBeforeOrWithADamagedClosedTabStillLoads() throws {
            let old = #"{"windows":[{"tabs":[{"url":"https://a.example/","title":"A"}],"active":0}]}"#
            let window = try #require(Browser.SavedWindows.decode(Data(old.utf8)).first)
            #expect(window.tabs.count == 1 && window.closed == nil)
            let damaged = #"{"windows":[{"tabs":[{"url":"https://a.example/","title":"A"}],"active":0,"closed":[{"title":2},"#
                + #"{"id":"5BACE000-0000-4000-8000-0000000000AA","url":"https://b.example/","title":"B","index":0,"space":"5BACE000-0000-4000-8000-000000000001","closedAt":0}]}]}"#
            let read = try #require(Browser.SavedWindows.decode(Data(damaged.utf8)).first)
            #expect(read.tabs.count == 1 && read.closed?.map(\.title) == ["B"])
            let wrong = #"{"windows":[{"tabs":[{"url":"https://a.example/","title":"A"}],"closed":"nope"}]}"#
            #expect(Browser.SavedWindows.decode(Data(wrong.utf8)).first?.tabs.count == 1)
        }

        @Test func clearingHistoryScrubsTheClosedTabsFromEveryWindowAndTheSessionFiles() throws {
            let box = Sandbox()
            let now = Date(), since = now.addingTimeInterval(3600)
            let old = Browser.ClosedTab(url: URL(string: "https://old.example/"), title: "Old", index: 0, space: Space.defaultID, closedAt: now.addingTimeInterval(-7200))
            let recent = Browser.ClosedTab(url: URL(string: "https://recent.example/"), title: "Recent", index: 0, space: Space.defaultID, closedAt: since.addingTimeInterval(60))
            let b = browser(1)
            b.focused()
            defer { b.windowClosed() }
            b.closedTabs = [old, recent]
            var window = b.savedSession
            window.closed = [old, recent]
            let file = box.file("session.json"), damaged = box.file("damaged.json"), missing = box.file("missing.json")
            try JSONEncoder().encode(Browser.SavedWindows(windows: [window])).write(to: file)
            try Data("{\"windows\":[{\"tabs\":".utf8).write(to: damaged)
            Browser.forgetClosedTabs(since: since, files: [file, damaged, missing], defaults: box.defaults)
            #expect(b.closedTabs.map(\.title) == ["Old"], "open windows forget them")
            let read = try #require(Browser.SavedWindows.decode(Data(contentsOf: file)).first)
            #expect(read.closed?.map(\.title) == ["Old"] && read.tabs.count == 1, "the file is rewritten at once, its tabs kept")
            #expect(!FileManager.default.fileExists(atPath: damaged.path), "a file that can't be read goes")
            #expect(!FileManager.default.fileExists(atPath: missing.path))
        }

        @Test func closedTabsAFileStillHoldsAfterAClearDoNotComeBack() throws {
            let box = Sandbox()
            let now = Date()
            let cleared = Browser.ClosedTab(url: URL(string: "https://cleared.example/"), title: "Cleared", index: 0, space: Space.defaultID, closedAt: now.addingTimeInterval(-60))
            let before = Browser.ClosedTab(url: URL(string: "https://before.example/"), title: "Before", index: 0, space: Space.defaultID, closedAt: now.addingTimeInterval(-7200))
            Browser.noteCleared(since: now.addingTimeInterval(-3600), at: now, defaults: box.defaults)
            #expect(Browser.wasCleared(cleared.closedAt, defaults: box.defaults) && !Browser.wasCleared(before.closedAt, defaults: box.defaults))
            #expect(!Browser.wasCleared(now.addingTimeInterval(60), defaults: box.defaults), "a tab closed after the clear is kept")
            let source = browser(1)
            defer { source.windowClosed() }
            var window = source.savedSession
            window.closed = [before, cleared]
            let restored = Browser(spaces: Sandbox().store())
            defer { restored.windowClosed() }
            restored.restore(window, defaults: box.defaults)
            #expect(restored.closedTabs.map(\.title) == ["Before"])
        }

        // MARK: Folded folders

        @Test func aFoldedFolderStillShowsTheRowOfTheTabShownAsAFoldedGroupDoes() {
            let inner = Library.Folder(key: "Work / Old", label: "Old", entries: [entry("https://deep.example/")])
            let folder = Library.Folder(key: "Work", label: "Work", entries: [entry("https://a.example/"), entry("https://b.example/")], children: [inner])
            func bookmarks(_ rows: [Sidebar.TreeRow]) -> [String] {
                rows.compactMap { if case .bookmark(let entry, let folder, _, _) = $0 { folder + " " + entry.url } else { nil } }
            }
            let folded = Sidebar.treeRows(folder, depth: 0, scope: "pin:", pinned: true, open: [], shownKey: "Work\nhttps://b.example/", dragging: false)
            #expect(folded.count == 2 && bookmarks(folded) == ["Work https://b.example/"])
            let deep = Sidebar.treeRows(folder, depth: 0, scope: "pin:", pinned: true, open: [], shownKey: "Work / Old\nhttps://deep.example/", dragging: false)
            #expect(bookmarks(deep) == ["Work / Old https://deep.example/"], "from a folder inside it too")
            #expect(Sidebar.treeRows(folder, depth: 0, scope: "pin:", pinned: true, open: [], shownKey: nil, dragging: false).count == 1, "nothing shown, nothing but the folder")
            let open = Sidebar.treeRows(folder, depth: 0, scope: "pin:", pinned: true, open: ["pin:Work"], shownKey: "Work\nhttps://b.example/", dragging: false)
            #expect(bookmarks(open) == ["Work https://a.example/", "Work https://b.example/"], "an open folder shows its own once")
        }

        @Test func anOpenEmptyFolderSaysSoAndTakesADropAtItsEnd() {
            let empty = Library.Folder(key: "Empty", label: "Empty", entries: [])
            let rows = Sidebar.treeRows(empty, depth: 0, scope: "pin:", pinned: true, open: ["pin:Empty"], dragging: false)
            #expect(rows.map(\.id) == ["pin:Empty", "pin:Empty\n\u{1}empty"])
            let dragging = Sidebar.treeRows(empty, depth: 0, scope: "pin:", pinned: true, open: ["pin:Empty"], dragging: true)
            #expect(dragging.map(\.id) == ["pin:Empty", "pin:Empty\n\u{1}empty", "pin:Empty\n\u{1}end"])
            #expect(Sidebar.treeRows(empty, depth: 0, scope: "pin:", pinned: true, open: [], dragging: true).count == 1, "folded, only the folder")
            let full = Library.Folder(key: "Full", label: "Full", entries: [entry("https://a.example/")])
            #expect(!Sidebar.treeRows(full, depth: 0, scope: "pin:", pinned: true, open: ["pin:Full"], dragging: false).map(\.id).contains("pin:Full\n\u{1}empty"))
        }

        @Test func theKeysReachTheShownBookmarkTabOfAFoldedFolder() {
            let b = browser(1)
            defer { b.windowClosed() }
            let pinned = bookmarkTab(b, "https://pin.example/", in: "Work")
            b.spaces.pinFolder("Work", in: b.spaceID)
            let folder = Library.Folder(key: "Work", label: "Work", entries: [entry("https://pin.example/")])
            #expect(!b.sidebarTabs(favorites: [], pinned: [folder]).contains { $0 === pinned }, "folded away while not shown")
            b.activate(pinned.id)
            #expect(b.sidebarTabs(favorites: [], pinned: [folder]).first === pinned)
        }

        // MARK: Moving to another space

        @Test func movingToAnotherSpaceKeepsThePageUnlessTheCookieStoresDiffer() {
            let home = Space.defaultID, work = UUID(), profile = UUID()
            #expect(Browser.spaceMove(bound: false, from: home, to: work, fromStore: nil, toStore: nil) == .move)
            #expect(Browser.spaceMove(bound: false, from: home, to: profile, fromStore: nil, toStore: profile) == .reload)
            #expect(Browser.spaceMove(bound: false, from: profile, to: home, fromStore: profile, toStore: nil) == .reload)
            #expect(Browser.spaceMove(bound: true, from: home, to: work, fromStore: nil, toStore: nil) == .refuse)
            #expect(Browser.spaceMove(bound: false, from: home, to: home, fromStore: nil, toStore: nil) == .stay)
        }

        @Test func aTabMovesToAnotherSpaceAndTheShownOneTakesItsSpaceAlong() throws {
            let b = browser(3)
            defer { b.windowClosed() }
            let t = b.tabs
            let work = b.spaces.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
            let group = try #require(b.group([t[1].id, t[2].id], name: "G"))
            b.activate(t[1].id)
            #expect(b.moveTab(t[2].id, toSpace: work.id))
            #expect(t[2].spaceID == work.id && t[2].groupID == nil && b.spaceID == Space.defaultID, "a tab not shown moves alone, out of its group")
            #expect(b.moveTab(t[1].id, toSpace: work.id))
            #expect(b.spaceID == work.id && b.activeID == t[1].id && b.tab(t[1].id) === t[1], "the same tab, page and all")
            #expect(!b.groups.contains { $0.id == group })
            let favorite = bookmarkTab(b, "https://fav.example/", in: b.favoritesFolder)
            #expect(!b.moveTab(favorite.id, toSpace: Space.defaultID) && favorite.spaceID == work.id, "a favorite's tab stays")
        }

        @Test func aTabMovedIntoAProfileLoadsAfreshThereWithNothingOfItsSession() {
            let b = browser(2)
            defer { b.windowClosed() }
            let profile = b.spaces.add(name: "Bank", symbol: "lock", tint: .green, isProfile: true)
            let tab = b.tabs[1]
            tab.customTitle = "Named"
            #expect(b.moveTab(tab.id, toSpace: profile.id))
            #expect(b.tab(tab.id) == nil && b.closedTabs.isEmpty, "the old tab goes, and is not one to reopen")
            let moved = b.tabs.first { $0.spaceID == profile.id }
            #expect(moved?.url == URL(string: "https://site2.example/") && moved?.customTitle == "Named" && moved?.isAsleep == true)
        }

        // MARK: Dropping on another window

        @Test func aTabDroppedOnAnotherWindowMovesThereOrTheDropTakesNothing() {
            #expect(Browser.adopts(fromPrivate: false, toPrivate: false, bound: false))
            #expect(!Browser.adopts(fromPrivate: true, toPrivate: false, bound: false) && !Browser.adopts(fromPrivate: false, toPrivate: true, bound: false))
            #expect(!Browser.adopts(fromPrivate: false, toPrivate: false, bound: true))
            let store = Sandbox().store()
            let from = Browser(spaces: store), to = Browser(spaces: store), hidden = Browser(isPrivate: true)
            for b in [from, to, hidden] { b.focused() }
            defer { for b in [from, to, hidden] { b.windowClosed() } }
            let leaving = from.openTab(url: URL(string: "https://leaving.example/"), activate: false)
            leaving.customTitle = "Leaving"
            _ = from.openTab(url: URL(string: "https://stays.example/"), activate: false)
            let target = to.openTab(url: URL(string: "https://here.example/"), activate: false)
            #expect(SidebarDrag.drop([SidebarDrag.tab(leaving.id)], onTab: target.id, browser: to))
            #expect(from.tab(leaving.id) == nil && from.tabs.count == 1 && from.closedTabs.isEmpty)
            #expect(to.tabs.map(\.customTitle) == ["Leaving", nil], "just above the tab it was dropped on")
            let secret = hidden.openTab(url: URL(string: "https://secret.example/"), activate: false)
            #expect(!SidebarDrag.drop([SidebarDrag.tab(secret.id)], onTab: target.id, browser: to), "a private tab never comes into an ordinary window")
            #expect(!SidebarDrag.dropAtEnd([SidebarDrag.tab(secret.id)], browser: to))
            #expect(hidden.tab(secret.id) != nil && to.tabs.count == 2)
        }

        @Test func splitViewWithNoOtherTabSaysSoInsteadOfBeeping() {
            let b = browser(1)
            defer { b.windowClosed() }
            b.activate(b.tabs[0].id)
            b.toggleSplit()
            #expect(b.split == nil && b.overlay.statusMessage == "There is no other tab to show beside this one")
        }

        // MARK: Archiving

        @Test func archivingSaysHowManyTabsWentAndUndoBringsThemBack() {
            let b = browser(3)
            defer { b.windowClosed() }
            b.activate(b.tabs[0].id)
            for tab in b.tabs.dropFirst() { tab.lastShown = .distantPast }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let archive = TabArchive(file: file)
            b.archiveIdleTabs(olderThan: 3600, to: archive)
            #expect(b.tabs.count == 1 && archive.entries.count == 2)
            #expect(b.notice?.message == "Archived 2 tabs to History › Archived Tabs")
            let shown = b.activeID
            b.undoNotice()
            #expect(b.tabs.count == 3 && archive.entries.isEmpty && b.activeID == shown, "back where they were kept, without switching to them")
        }

        // MARK: Keyboard

        @Test func arrowKeysGoFromRowToRowAndStopAtTheEnds() {
            let rows = ["fav:a", "pin:Work", "tab:1", "tab:2"]
            #expect(Sidebar.focusStep(from: "pin:Work", by: 1, in: rows) == "tab:1")
            #expect(Sidebar.focusStep(from: "pin:Work", by: -1, in: rows) == "fav:a")
            #expect(Sidebar.focusStep(from: "fav:a", by: -1, in: rows) == "fav:a")
            #expect(Sidebar.focusStep(from: "tab:2", by: 1, in: rows) == "tab:2")
            #expect(Sidebar.focusStep(from: nil, by: 1, in: rows) == nil, "the keyboard isn't in the sidebar: the arrows are left alone")
            #expect(Sidebar.focusStep(from: "gone", by: 1, in: rows) == nil)
        }

        // MARK: Closing several

        @Test func closingOthersOrBelowChoosesFromTheTabListOnly() {
            #expect(Browser.othersToClose(keeping: 2, listed: [1, 2, 3]) == [1, 3])
            #expect(Browser.belowToClose(2, listed: [1, 2, 3]) == [3])
            #expect(Browser.belowToClose(3, listed: [1, 2, 3]).isEmpty)
            #expect(Browser.belowToClose(9, listed: [1, 2, 3]) == [1, 2, 3], "below a bookmark's tab, above the list, all of it")
        }

        @Test func closeTabsBelowLeavesBookmarkTabsAndCanBeTakenBackAtOnce() throws {
            let b = browser(4)
            defer { b.windowClosed() }
            let t = b.tabs.map(\.id)
            let favorite = bookmarkTab(b, "https://fav.example/", in: b.favoritesFolder)
            let group = try #require(b.group([t[2], t[3]], name: "G"))
            b.toggleGroup(group)
            b.activate(t[3])
            b.closeTabsBelow(t[1])
            #expect(b.tabs.map(\.id) == [t[0], t[1], favorite.id], "a folded group's tabs go too; the favorite's tab stays")
            #expect(b.activeID == t[1], "the tab the menu was for is shown, not a tab about to close")
            #expect(b.notice != nil)
            b.undoNotice()
            #expect(b.tabs.count == 5)
            #expect(Set(b.listedTabs.compactMap(\.url?.absoluteString)) == Set((1...4).map { "https://site\($0).example/" }))
            b.closeOtherTabs(keeping: b.listedTabs[0].id)
            #expect(b.listedTabs.count == 1 && b.tab(favorite.id) != nil)
        }
    }
}
