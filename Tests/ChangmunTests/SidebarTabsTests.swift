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
