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
    }
}
