import Foundation
import Testing
@testable import Changmun

extension SharedAgentState {
    /// The tab layout setting, and what the strip of tabs along the top shows and does with a drop.
    @MainActor
    struct TabStripTests {
        private func browser(_ count: Int, spaces: SpaceStore? = nil) -> Browser {
            let browser = spaces.map { Browser(spaces: $0) } ?? Browser()
            for n in 1...count { browser.openTab(url: URL(string: "https://site\(n).example/"), activate: false) }
            return browser
        }

        private func favorites(_ count: Int) -> [Library.Entry] {
            (1...count).map { Library.Entry(url: "https://fav\($0).example/", title: "Favorite \($0)") }
        }

        /// The strip as listed: a favorite by its number, a loose tab by its id, a group by its name and a count, and for a tab the ids in order.
        private func listed(_ items: [TabStripItem]) -> [String] {
            items.map { item in
                switch item {
                case .favorite(let entry): "fav:" + entry.title
                case .group(let group, let count): "group:\(group.name)/\(count)"
                case .tab(let tab): "\(tab.id)"
                }
            }
        }

        // MARK: The setting

        @Test func theTabsAreInTheSidebarUnlessTheStoredValueSaysOtherwise() {
            #expect(TabLayout(stored: nil) == .sidebar)
            #expect(TabLayout(stored: "") == .sidebar)
            #expect(TabLayout(stored: "sidebar") == .sidebar)
            #expect(TabLayout(stored: "top") == .top)
            // A value a later version wrote, or a damaged one, falls back to what everyone had before.
            #expect(TabLayout(stored: "left") == .sidebar)
            #expect(TabLayout.allCases.map(\.rawValue) == ["sidebar", "top"])
        }

        @Test func theLayoutIsKeptAcrossLaunches() {
            let prefs = Preferences.shared
            let was = prefs.tabLayout
            defer { prefs.tabLayout = was }
            prefs.tabLayout = .top
            #expect(UserDefaults.standard.string(forKey: "tabLayout") == "top")
            #expect(TabLayout(stored: UserDefaults.standard.string(forKey: "tabLayout")) == .top)
            prefs.tabLayout = .sidebar
            #expect(UserDefaults.standard.string(forKey: "tabLayout") == "sidebar")
        }

        // MARK: What the strip shows

        @Test func theFavoritesComeFirstAndThenTheTabsOfTheSpace() {
            let b = browser(3)
            let t = b.tabs.map(\.id)
            #expect(listed(b.stripItems(favorites: favorites(2))) == ["fav:Favorite 1", "fav:Favorite 2", "\(t[0])", "\(t[1])", "\(t[2])"])
            #expect(listed(b.stripItems(favorites: [])) == ["\(t[0])", "\(t[1])", "\(t[2])"])
        }

        @Test func onlyTheTabsOfTheSpaceShownAreInIt() {
            let box = Sandbox()
            let store = box.store()
            let work = store.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
            let b = browser(2, spaces: store)
            let here = b.tabs.map(\.id)
            let away = b.openTab(url: URL(string: "https://work.example/"), activate: false, space: work.id)
            #expect(listed(b.stripItems(favorites: [])) == here.map { "\($0)" })
            b.switchSpace(to: work.id, opensBar: false)
            #expect(listed(b.stripItems(favorites: [])) == ["\(away.id)"])
        }

        @Test func aFavoritesOwnTabIsInItsTileNotAmongTheTabs() {
            let b = browser(3)
            let t = b.tabs.map(\.id)
            b.bind(b.tabs[1], to: Browser.bookmarkKey(url: "https://fav1.example/", folder: b.favoritesFolder))
            #expect(listed(b.stripItems(favorites: favorites(1))) == ["fav:Favorite 1", "\(t[0])", "\(t[2])"])
        }

        @Test func aGroupIsAChipBeforeItsTabs() throws {
            let b = browser(5)
            let t = b.tabs.map(\.id)
            _ = try #require(b.group([t[1], t[2]], name: "G"))
            #expect(listed(b.stripItems(favorites: favorites(1))) == ["fav:Favorite 1", "\(t[0])", "group:G/2", "\(t[1])", "\(t[2])", "\(t[3])", "\(t[4])"])
        }

        @Test func aFoldedGroupHidesItsTabsBehindTheChipButTheOneShown() throws {
            let b = browser(5)
            let t = b.tabs.map(\.id)
            let group = try #require(b.group([t[1], t[2], t[3]], name: "G"))
            b.activate(t[0])
            b.toggleGroup(group)
            #expect(listed(b.stripItems(favorites: [])) == ["\(t[0])", "group:G/3", "\(t[4])"], "the chip still counts all three")
            // The tab shown stays in view, as it does in the sidebar's list.
            b.activate(t[2])
            #expect(listed(b.stripItems(favorites: [])) == ["\(t[0])", "group:G/3", "\(t[2])", "\(t[4])"])
            b.toggleGroup(group)
            #expect(listed(b.stripItems(favorites: [])) == ["\(t[0])", "group:G/3", "\(t[1])", "\(t[2])", "\(t[3])", "\(t[4])"])
        }

        @Test func theStripShowsTheTabsInTheOrderOfTheSidebarsList() throws {
            let b = browser(6)
            let t = b.tabs.map(\.id)
            _ = try #require(b.group([t[1], t[4]], name: "G"))
            b.activate(t[1])
            let strip = b.stripItems(favorites: []).compactMap { $0.tab?.id }
            #expect(strip == b.visibleTabs.map(\.id))
        }

        // MARK: Reordering

        @Test func aTabDroppedOnAStripTabLandsJustBeforeItAndOnThePlusItGoesToTheEnd() {
            let b = browser(4)
            let t = b.tabs.map(\.id)
            func strip() -> [Int] { b.stripItems(favorites: favorites(1)).compactMap { $0.tab?.id } }
            #expect(strip() == t)
            // From a position further along to an earlier one, and from an earlier one to a later one: always just before the target.
            #expect(SidebarDrag.drop([SidebarDrag.tab(t[3])], onTab: t[1], browser: b))
            #expect(strip() == [t[0], t[3], t[1], t[2]])
            #expect(SidebarDrag.drop([SidebarDrag.tab(t[0])], onTab: t[2], browser: b))
            #expect(strip() == [t[3], t[1], t[0], t[2]])
            #expect(SidebarDrag.dropAtEnd([SidebarDrag.tab(t[3])], browser: b))
            #expect(strip() == [t[1], t[0], t[2], t[3]])
            // The favorites stay first whatever the tabs do.
            #expect(listed(b.stripItems(favorites: favorites(1))).first == "fav:Favorite 1")
        }

        @Test func movingATabByItsPlaceInTheStripIsMoveTab() {
            let b = browser(4)
            let t = b.tabs.map(\.id)
            let items = b.stripItems(favorites: favorites(2))
            // The strip's items, by index: the tab at 3 (the second tab) goes before the one at 5 (the fourth).
            let moving = items[3].tab?.id, before = items[5].tab?.id
            #expect(moving == t[1] && before == t[3])
            b.moveTab(t[1], to: t[3])
            #expect(b.stripItems(favorites: favorites(2)).compactMap { $0.tab?.id } == [t[0], t[2], t[1], t[3]])
        }

        @Test func aTabDroppedOnAGroupsChipJoinsIt() throws {
            let b = browser(4)
            let t = b.tabs.map(\.id)
            let group = try #require(b.group([t[1], t[2]], name: "G"))
            #expect(SidebarDrag.drop([SidebarDrag.tab(t[3])], onGroup: group, browser: b))
            #expect(listed(b.stripItems(favorites: [])) == ["\(t[0])", "group:G/3", "\(t[1])", "\(t[2])", "\(t[3])"])
        }

        // MARK: Switching layouts

        @Test func switchingLayoutsLeavesTheBrowsersStateAlone() throws {
            let prefs = Preferences.shared
            let was = prefs.tabLayout
            defer { prefs.tabLayout = was }
            let b = browser(5)
            let t = b.tabs.map(\.id)
            let group = try #require(b.group([t[1], t[2]], name: "G"))
            b.activate(t[2])
            b.toggleGroup(group)
            func state() -> String {
                "\(b.tabs.map(\.id)) \(String(describing: b.activeID)) \(b.spaceID) \(b.groups.map { "\($0.id) \($0.name) \($0.isOpen)" }) \(b.showSidebar) \(b.showChat) \(b.focusMode) \(b.showSidebarOverlay)"
            }
            func strip() -> [String] { listed(b.stripItems(favorites: favorites(1))) }
            prefs.tabLayout = .sidebar
            let before = state(), shownBefore = strip()
            prefs.tabLayout = .top
            #expect(state() == before)
            #expect(strip() == shownBefore)
            prefs.tabLayout = .sidebar
            #expect(state() == before)
            #expect(strip() == shownBefore)
        }
    }
}
