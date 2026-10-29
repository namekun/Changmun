import AppKit
import Foundation
import Testing
@testable import Changmun

extension SharedAgentState {
    /// Dragging in the sidebar: what a drag carries, where tabs and groups land, and groups kept as bookmarks.
    @MainActor
    struct SidebarDragTests {
        private func browser(_ count: Int, spaces: SpaceStore? = nil) -> Browser {
            let browser = spaces.map { Browser(spaces: $0) } ?? Browser()
            for n in 1...count { browser.openTab(url: URL(string: "https://site\(n).example/"), activate: false) }
            return browser
        }

        private func ids(_ b: Browser) -> [Int] { b.tabs.map(\.id) }

        /// The sidebar as listed: a loose tab by its id, a group by name and the ids of its tabs.
        private func shown(_ b: Browser) -> [String] {
            b.listing.map { item in
                switch item {
                case .tab(let tab): "\(tab.id)"
                case .group(let group, let tabs): group.name + "[" + tabs.map { "\($0.id)" }.joined(separator: " ") + "]"
                }
            }
        }

        // MARK: Bookmarks within a folder

        @Test func aBookmarkDroppedOnARowOfItsFolderGoesAboveItAndOneFromElsewhereMovesIn() {
            let work = "Chrome Bookmarks Bar / Folder Order Test", other = "Chrome Bookmarks Bar / Folder Order Other"
            defer { Library.shared.removeFolder(work); Library.shared.removeFolder(other) }
            let url = { (name: String) in "https://folder-order-\(name).example/" }
            for name in ["a", "b", "c"] { Library.shared.addBookmark(url: url(name), title: name, folder: work) }
            Library.shared.addBookmark(url: url("z"), title: "z", folder: other)
            let b = Browser()
            defer { b.windowClosed() }
            func shown() -> [String] { Library.shared.folders().first { $0.name == work }?.entries.map(\.url) ?? [] }
            #expect(SidebarDrag.drop([SidebarDrag.bookmark(url("c"), in: work)], onBookmark: url("a"), in: work, browser: b))
            #expect(shown() == [url("c"), url("a"), url("b")])
            // From another folder it moves in, at that place.
            #expect(SidebarDrag.drop([SidebarDrag.bookmark(url("z"), in: other)], onBookmark: url("b"), in: work, browser: b))
            #expect(shown() == [url("c"), url("a"), url("z"), url("b")])
            #expect(Library.shared.folders().first { $0.name == other } == nil, "it left the folder it came from")
            // On the folder itself, one of its own goes to the end.
            #expect(SidebarDrag.drop([SidebarDrag.bookmark(url("c"), in: work)], onFolder: work, browser: b))
            #expect(shown() == [url("a"), url("z"), url("b"), url("c")])
            // On itself: nothing moves, and the drag is over.
            #expect(SidebarDrag.drop([SidebarDrag.bookmark(url("a"), in: work)], onBookmark: url("a"), in: work, browser: b))
            #expect(shown() == [url("a"), url("z"), url("b"), url("c")])
            #expect(SidebarDrag.dragging == nil)
        }

        // MARK: What a drag carries

        /// What SwiftUI does with a `.draggable` payload and a `.dropDestination(for: SidebarDrop.self)`: the payload goes
        /// into an item provider as a Transferable and the drop loads it back as that type.
        private func dropped(_ payload: String) async throws -> String {
            let provider = NSItemProvider()
            provider.register(payload)
            let drop: SidebarDrop = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadTransferable(type: SidebarDrop.self) { continuation.resume(with: $0) }
            }
            return drop.text
        }

        @Test func aDragPayloadComesBackAsTheSameTextAtTheDrop() async throws {
            let group = UUID()
            let payloads = [SidebarDrag.tab(12), SidebarDrag.group(group), SidebarDrag.folder("Arc Bookmarks Bar / Work"),
                            SidebarDrag.bookmark("https://a.example/x?y=1", in: "Arc Reading"), SidebarDrag.bookmark("https://b.example/", in: Library.favoritesFolder)]
            for payload in payloads {
                #expect(try await dropped(payload) == payload)
            }
            #expect(SidebarDrag.groupID([try await dropped(SidebarDrag.group(group))]) == group)
            #expect(SidebarDrag.folderKey([try await dropped(SidebarDrag.folder("Arc Work"))]) == "Arc Work")
            // A link dragged from a page arrives as the address.
            #expect(SidebarDrag.link([try await dropped("https://c.example/page")])?.absoluteString == "https://c.example/page")
        }

        @Test func aDragRemembersWhatItCarries() {
            let group = UUID()
            _ = SidebarDrag.group(group)
            #expect(SidebarDrag.dragging == .group && SidebarDrag.draggingGroup == group && !SidebarDrag.carriesTab)
            _ = SidebarDrag.tab(1)
            #expect(SidebarDrag.dragging == .tab && SidebarDrag.draggingGroup == nil && SidebarDrag.carriesTab)
            #expect(SidebarDrag.groupID(["changmun-group:not-an-id"]) == nil)
            #expect(SidebarDrag.groupID([SidebarDrag.tab(1)]) == nil)
        }

        // MARK: Tabs

        @Test func aTabLandsJustAboveTheTabItWasDroppedOnInBothDirections() {
            let b = browser(5)
            let (one, two, three, four, five) = (b.tabs[0].id, b.tabs[1].id, b.tabs[2].id, b.tabs[3].id, b.tabs[4].id)
            b.moveTab(one, to: four)
            #expect(ids(b) == [two, three, one, four, five], "down: above the target, not after it")
            b.moveTab(five, to: two)
            #expect(ids(b) == [five, two, three, one, four], "up: above the target")
            b.moveTab(five, to: nil)
            #expect(ids(b) == [two, three, one, four, five])
            // Dropped on the tab right below, it stays where the line is; on the one below that, it moves one down.
            b.moveTab(two, to: three)
            #expect(ids(b) == [two, three, one, four, five])
            b.moveTab(two, to: one)
            #expect(ids(b) == [three, two, one, four, five])
            // Dropped on the tab right above, it moves up.
            b.moveTab(one, to: two)
            #expect(ids(b) == [three, one, two, four, five])
        }

        @Test func droppingATabInTheSidebarFollowsTheLineThroughGroups() throws {
            let b = browser(5)
            let (one, two, three, four, five) = (b.tabs[0].id, b.tabs[1].id, b.tabs[2].id, b.tabs[3].id, b.tabs[4].id)
            let group = try #require(b.group([two, three], name: "G"))
            // Into a group, above one of its tabs, from below and from above.
            #expect(SidebarDrag.drop([SidebarDrag.tab(five)], onTab: three, browser: b))
            #expect(shown(b) == ["\(one)", "G[\(two) \(five) \(three)]", "\(four)"])
            #expect(SidebarDrag.drop([SidebarDrag.tab(one)], onTab: three, browser: b))
            #expect(shown(b) == ["G[\(two) \(five) \(one) \(three)]", "\(four)"])
            // Out of it, above a loose tab; to a group's header it joins at the end; below everything it leaves.
            #expect(SidebarDrag.drop([SidebarDrag.tab(five)], onTab: four, browser: b))
            #expect(shown(b) == ["G[\(two) \(one) \(three)]", "\(five)", "\(four)"])
            #expect(SidebarDrag.drop([SidebarDrag.tab(four)], onGroup: group, browser: b))
            #expect(shown(b) == ["G[\(two) \(one) \(three) \(four)]", "\(five)"])
            #expect(SidebarDrag.dropAtEnd([SidebarDrag.tab(two)], browser: b))
            #expect(shown(b) == ["G[\(one) \(three) \(four)]", "\(five)", "\(two)"])
            // On itself, nothing changes.
            #expect(SidebarDrag.drop([SidebarDrag.tab(five)], onTab: five, browser: b))
            #expect(shown(b) == ["G[\(one) \(three) \(four)]", "\(five)", "\(two)"])
        }

        @Test func aTabDroppedOnAFoldedGroupsShownTabJoinsTheGroup() throws {
            let b = browser(4)
            let (one, two, three, four) = (b.tabs[0].id, b.tabs[1].id, b.tabs[2].id, b.tabs[3].id)
            let group = try #require(b.group([two, three], name: "G"))
            b.activate(three)
            b.toggleGroup(group)
            #expect(b.visibleTabs.map(\.id) == [one, three, four])
            b.dropTab(four, on: three)
            #expect(b.tab(four)?.groupID == group)
            #expect(shown(b) == ["\(one)", "G[\(two) \(four) \(three)]"])
            #expect(b.groups.first?.isOpen == false)
        }

        @Test func aTabDroppedOnATabOfAnotherSpaceStaysPut() {
            let box = Sandbox()
            let store = box.store()
            let work = store.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
            let b = browser(2, spaces: store)
            let away = b.openTab(url: URL(string: "https://work.example/"), activate: false, space: work.id)
            let before = ids(b)
            b.dropTab(before[0], on: away.id)
            #expect(ids(b) == before)
            b.moveGroup(UUID(), before: away.id)
            #expect(ids(b) == before)
        }

        // MARK: Groups

        @Test func aGroupLandsAboveTheTabOrGroupItWasDroppedOnOrAtTheEnd() throws {
            let b = browser(7)
            let t = b.tabs.map(\.id)
            let first = try #require(b.group([t[0], t[1]], name: "First"))
            let second = try #require(b.group([t[3], t[4]], name: "Second"))
            #expect(shown(b) == ["First[\(t[0]) \(t[1])]", "\(t[2])", "Second[\(t[3]) \(t[4])]", "\(t[5])", "\(t[6])"])
            // Above a loose tab, from above and from below.
            #expect(SidebarDrag.drop([SidebarDrag.group(first)], onTab: t[5], browser: b))
            #expect(shown(b) == ["\(t[2])", "Second[\(t[3]) \(t[4])]", "First[\(t[0]) \(t[1])]", "\(t[5])", "\(t[6])"])
            #expect(SidebarDrag.drop([SidebarDrag.group(first)], onTab: t[2], browser: b))
            #expect(shown(b) == ["First[\(t[0]) \(t[1])]", "\(t[2])", "Second[\(t[3]) \(t[4])]", "\(t[5])", "\(t[6])"])
            // Above another group: dropped on its header, and on one of its tabs.
            #expect(SidebarDrag.drop([SidebarDrag.group(second)], onGroup: first, browser: b))
            #expect(shown(b) == ["Second[\(t[3]) \(t[4])]", "First[\(t[0]) \(t[1])]", "\(t[2])", "\(t[5])", "\(t[6])"])
            #expect(SidebarDrag.drop([SidebarDrag.group(first)], onTab: t[4], browser: b))
            #expect(shown(b) == ["First[\(t[0]) \(t[1])]", "Second[\(t[3]) \(t[4])]", "\(t[2])", "\(t[5])", "\(t[6])"])
            // To the end.
            #expect(SidebarDrag.dropAtEnd([SidebarDrag.group(first)], browser: b))
            #expect(shown(b) == ["Second[\(t[3]) \(t[4])]", "\(t[2])", "\(t[5])", "\(t[6])", "First[\(t[0]) \(t[1])]"])
            #expect(b.tabs.map(\.id) == [t[3], t[4], t[2], t[5], t[6], t[0], t[1]])
        }

        @Test func aGroupDroppedOnItselfOrItsOwnTabsStaysAndKeepsItsState() throws {
            let b = browser(4)
            let t = b.tabs.map(\.id)
            let group = try #require(b.group([t[1], t[2]], name: "G"))
            b.toggleGroup(group)
            let order = ids(b)
            #expect(SidebarDrag.drop([SidebarDrag.group(group)], onGroup: group, browser: b))
            #expect(SidebarDrag.drop([SidebarDrag.group(group)], onTab: t[2], browser: b))
            #expect(ids(b) == order)
            // Moved, it is still folded and its tabs are in the same order.
            #expect(SidebarDrag.dropAtEnd([SidebarDrag.group(group)], browser: b))
            #expect(shown(b) == ["\(t[0])", "\(t[3])", "G[\(t[1]) \(t[2])]"])
            #expect(b.groups.first?.isOpen == false)
            // A group that is gone is no drop.
            b.ungroup(group)
            let after = ids(b)
            #expect(SidebarDrag.dropAtEnd([SidebarDrag.group(group)], browser: b))
            #expect(ids(b) == after)
        }

        // MARK: Groups as bookmarks

        @MainActor private struct Rig {
            let box = Sandbox()
            let store: SpaceStore
            let library: Library
            let b: Browser

            init(tabs count: Int = 4) {
                store = box.store()
                library = Library(path: box.file("lib.sqlite").path)
                b = Browser(spaces: store)
                for n in 1...count { b.openTab(url: URL(string: "https://site\(n).example/"), activate: false) }
            }
        }

        private func entries(_ library: Library, _ folder: String) -> [String] {
            library.folders().first { $0.name == folder }?.entries.map(\.url) ?? []
        }

        @Test func aGroupDroppedOnThePinnedFoldersBecomesAPinnedFolderOfItsPages() throws {
            let rig = Rig(tabs: 5), b = rig.b
            let t = b.tabs.map(\.id)
            b.tab(t[2])?.title = "Third"
            let group = try #require(b.group([t[1], t[2], t[3]], name: "Reading list"))
            rig.store.pinFolder("Arc Work", in: Space.defaultID)
            rig.store.pinFolder("Arc Home", in: Space.defaultID)
            #expect(b.saveGroup(group, to: .pinned(before: "Arc Home"), library: rig.library))
            let folder = "Changmun Reading list"
            #expect(entries(rig.library, folder) == ["https://site2.example/", "https://site3.example/", "https://site4.example/"], "in tab order")
            #expect(rig.library.folders().first { $0.name == folder }?.entries.map(\.title) == ["site2.example", "Third", "site4.example"])
            #expect(rig.store.space(Space.defaultID).pinnedFolders == ["Arc Work", folder, "Arc Home"])
            #expect(b.groups.isEmpty && b.tabs.allSatisfy { $0.groupID == nil })
            #expect(b.tab(t[1])?.bookmarkKey == Browser.bookmarkKey(url: "https://site2.example/", folder: folder))
            #expect(b.tab(t[3])?.bookmarkKey == Browser.bookmarkKey(url: "https://site4.example/", folder: folder))
            #expect(b.listedTabs.map(\.id) == [t[0], t[4]], "the pages show in the folder now, not the tab list")
            #expect(rig.store.space(Space.defaultID).openFolders == ["pin:" + folder], "an open group's folder is open")
            b.undoNotice()
            #expect(rig.store.space(Space.defaultID).openFolders.isEmpty && b.listedTabs.count == 5)
        }

        @Test func savingAgainNumbersTheFolderAndSlashesStayInsideTheName() throws {
            let rig = Rig(tabs: 4), b = rig.b
            let t = b.tabs.map(\.id)
            let first = try #require(b.group([t[0], t[1]], name: "A / B"))
            #expect(b.saveGroup(first, to: .pinned(before: nil), library: rig.library))
            let second = try #require(b.group([t[2], t[3]], name: "A / B"))
            #expect(b.saveGroup(second, to: .pinned(before: nil), library: rig.library))
            #expect(rig.store.space(Space.defaultID).pinnedFolders == ["Changmun A - B", "Changmun A - B 2"])
            let sources = Library.groupBySource(rig.library.folders())
            #expect(sources.map(\.source) == ["Changmun"] && sources[0].folders.map(\.label) == ["A - B", "A - B 2"])
        }

        @Test func aGroupDroppedOnABookmarkFolderBecomesAFolderInsideIt() throws {
            let rig = Rig(tabs: 3), b = rig.b
            let t = b.tabs.map(\.id)
            rig.library.addBookmark(url: "https://old.example/", title: "Old", folder: "Arc Work")
            let group = try #require(b.group([t[0], t[2]], name: "Trip"))
            #expect(b.saveGroup(group, to: .folder("Arc Work"), library: rig.library))
            #expect(entries(rig.library, "Arc Work / Trip") == ["https://site1.example/", "https://site3.example/"])
            #expect(entries(rig.library, "Arc Work") == ["https://old.example/"])
            #expect(rig.store.space(Space.defaultID).pinnedFolders.isEmpty, "it is inside the folder, not pinned on its own")
            #expect(b.tab(t[2])?.bookmarkKey == Browser.bookmarkKey(url: "https://site3.example/", folder: "Arc Work / Trip"))
            let sources = Library.groupBySource(rig.library.folders())
            #expect(sources[0].folders[0].children.map(\.label) == ["Trip"])
        }

        @Test func aGroupSavedFirstAmongThePinnedFoldersStaysTogether() throws {
            let rig = Rig(tabs: 5), b = rig.b
            let t = b.tabs.map(\.id)
            let favorites = b.favoritesFolder
            rig.library.addBookmark(url: "https://x.example/", title: "X", folder: favorites)
            rig.store.pinFolder("Arc Home", before: nil, in: Space.defaultID)
            let group = try #require(b.group([t[1], t[2], t[3]], name: "G"))
            #expect(b.saveGroup(group, to: .pinned(before: "Arc Home"), library: rig.library))
            #expect(rig.store.space(Space.defaultID).pinnedFolders == ["Changmun G", "Arc Home"])
            #expect(entries(rig.library, "Changmun G") == ["https://site2.example/", "https://site3.example/", "https://site4.example/"])
            #expect(rig.library.favorites(in: favorites).map(\.url) == ["https://x.example/"], "the favorites are left alone")
            for id in [t[1], t[2], t[3]] {
                #expect(b.tab(id)?.bookmarkKey == Browser.bookmarkKey(url: b.tab(id)?.url?.absoluteString ?? "", folder: "Changmun G"))
            }
            #expect(b.groups.isEmpty)
        }

        @Test func tabsWithoutAWebPageStayPlainTabs() throws {
            let rig = Rig(tabs: 2), b = rig.b
            let blank = b.openTab(url: URL(string: "about:blank"), activate: false)
            let t = [b.tabs[0].id, b.tabs[1].id, blank.id]
            let group = try #require(b.group(t, name: "Mixed"))
            #expect(b.saveGroup(group, to: .pinned(before: nil), library: rig.library))
            #expect(entries(rig.library, "Changmun Mixed") == ["https://site1.example/", "https://site2.example/"])
            #expect(blank.bookmarkKey == nil && blank.groupID == nil && b.groups.isEmpty)
            #expect(b.listedTabs.map(\.id) == [blank.id])
            // A group with nothing to keep is left as it is.
            let only = try #require(b.group([blank.id], name: "Blank"))
            #expect(!b.saveGroup(only, to: .pinned(before: nil), library: rig.library))
            #expect(b.groups.map(\.id) == [only] && blank.groupID == only)
            #expect(rig.library.folders().map(\.name) == ["Changmun Mixed"])
        }

        @Test func savingAGroupCanBeTakenBack() throws {
            let rig = Rig(tabs: 4), b = rig.b
            let t = b.tabs.map(\.id)
            let group = try #require(b.group([t[1], t[2]], name: "G"))
            b.toggleGroup(group)
            #expect(b.saveGroup(group, to: .pinned(before: nil), library: rig.library))
            #expect(!rig.store.space(Space.defaultID).pinnedFolders.isEmpty)
            b.undoNotice()
            #expect(rig.library.folders().isEmpty)
            #expect(rig.store.space(Space.defaultID).pinnedFolders.isEmpty && rig.store.space(Space.defaultID).openFolders.isEmpty)
            #expect(b.tabs.allSatisfy { $0.bookmarkKey == nil })
            #expect(shown(b) == ["\(t[0])", "G[\(t[1]) \(t[2])]", "\(t[3])"])
            #expect(b.groups.first?.isOpen == false, "folded as it was")

            #expect(b.saveGroup(group, to: .folder("Arc Work"), library: rig.library))
            b.undoNotice()
            #expect(rig.library.folders().isEmpty)
            #expect(shown(b) == ["\(t[0])", "G[\(t[1]) \(t[2])]", "\(t[3])"])
        }

        @Test func aFolderThatOnlyExistsAsAPartOfADeeperPathIsNotFreeForANewOne() throws {
            let rig = Rig(tabs: 4), b = rig.b
            let t = b.tabs.map(\.id)
            // Imported with no row of its own for "Work".
            rig.library.addBookmark(url: "https://old.example/", title: "Old", folder: "Chrome Bookmarks Bar / Work / Projects")
            rig.library.addBookmark(url: "https://changmun.example/", title: "Old", folder: "Changmun Work / Projects")
            let inside = try #require(b.group([t[0], t[1]], name: "Work"))
            #expect(b.saveGroup(inside, to: .folder("Chrome Bookmarks Bar"), library: rig.library))
            #expect(entries(rig.library, "Chrome Bookmarks Bar / Work 2") == ["https://site1.example/", "https://site2.example/"])
            b.undoNotice()
            #expect(entries(rig.library, "Chrome Bookmarks Bar / Work / Projects") == ["https://old.example/"], "the imported bookmarks stay")
            #expect(rig.library.folders().map(\.name).sorted() == ["Changmun Work / Projects", "Chrome Bookmarks Bar / Work / Projects"])
            let pinned = try #require(b.group([t[2], t[3]], name: "Work"))
            #expect(b.saveGroup(pinned, to: .pinned(before: nil), library: rig.library))
            #expect(rig.store.space(Space.defaultID).pinnedFolders == ["Changmun Work 2"])
            b.undoNotice()
            #expect(entries(rig.library, "Changmun Work / Projects") == ["https://changmun.example/"])
            #expect(rig.store.space(Space.defaultID).pinnedFolders.isEmpty)
        }

        @Test func takingBackASaveKeepsWhatWasPutInTheFolderMeanwhile() throws {
            let rig = Rig(tabs: 3), b = rig.b
            let t = b.tabs.map(\.id)
            let group = try #require(b.group([t[0], t[1]], name: "G"))
            #expect(b.saveGroup(group, to: .pinned(before: nil), library: rig.library))
            rig.library.addBookmark(url: "https://later.example/", title: "Later", folder: "Changmun G")
            b.undoNotice()
            #expect(entries(rig.library, "Changmun G") == ["https://later.example/"], "only the saved pages go")
            #expect(shown(b) == ["G[\(t[0]) \(t[1])]", "\(t[2])"])
        }

        @Test func takingBackASaveInAFolderLeavesWhatItDidNotChange() throws {
            let rig = Rig(tabs: 3), b = rig.b
            let t = b.tabs.map(\.id)
            rig.library.addBookmark(url: "https://old.example/", title: "Old", folder: "Arc Work")
            rig.store.pinFolder("Arc Work", in: Space.defaultID)
            // The parent is pinned and open already: it stays so, and pinned.
            rig.store.toggleOpen("pin:Arc Work", in: Space.defaultID)
            let first = try #require(b.group([t[0]], name: "Trip"))
            #expect(b.saveGroup(first, to: .folder("Arc Work"), library: rig.library))
            b.undoNotice()
            #expect(rig.store.space(Space.defaultID).pinnedFolders == ["Arc Work"])
            #expect(rig.store.space(Space.defaultID).openFolders == ["pin:Arc Work"])
            // Closed, it is opened by the save and closed again by taking it back.
            rig.store.toggleOpen("pin:Arc Work", in: Space.defaultID)
            #expect(b.saveGroup(first, to: .folder("Arc Work"), library: rig.library))
            #expect(rig.store.space(Space.defaultID).openFolders == ["pin:Arc Work"])
            b.undoNotice()
            #expect(rig.store.space(Space.defaultID).openFolders.isEmpty && rig.store.space(Space.defaultID).pinnedFolders == ["Arc Work"])
            #expect(entries(rig.library, "Arc Work") == ["https://old.example/"])
        }

        @Test func takingBackASaveDoesNotRegroupATabMovedToAnotherBookmark() throws {
            let rig = Rig(tabs: 3), b = rig.b
            let t = b.tabs.map(\.id)
            let group = try #require(b.group([t[0], t[1]], name: "G"))
            #expect(b.saveGroup(group, to: .pinned(before: nil), library: rig.library))
            let elsewhere = Browser.bookmarkKey(url: "https://site1.example/", folder: "Arc Home")
            b.tab(t[0])?.bookmarkKey = elsewhere
            b.undoNotice()
            #expect(b.tab(t[0])?.bookmarkKey == elsewhere && b.tab(t[0])?.groupID == nil, "a tab with a bookmark has no group")
            #expect(b.tab(t[1])?.groupID == group && b.tab(t[1])?.bookmarkKey == nil)
        }

        @Test func aTabDroppedOnAFolderBecomesItsBookmark() throws {
            let b = browser(3, spaces: Sandbox().store())
            let tab = b.tabs[1]
            let folder = "Changmun Kept \(UUID().uuidString)"
            #expect(SidebarDrag.drop([SidebarDrag.tab(tab.id)], onFolder: folder, browser: b))
            #expect(Library.shared.folders().first { $0.name == folder }?.entries.map(\.url) == ["https://site2.example/"])
            #expect(tab.bookmarkKey == Browser.bookmarkKey(url: "https://site2.example/", folder: folder))
            #expect(!b.listedTabs.contains { $0 === tab } && b.space.openFolders.contains("pin:" + folder))
            // A tab with no web page is left where it is.
            let blank = b.openTab(url: URL(string: "about:blank"), activate: false)
            #expect(!SidebarDrag.drop([SidebarDrag.tab(blank.id)], onFolder: folder, browser: b))
            Library.shared.removeFolder(folder)
        }

        @Test func theSidebarDropsKeepGroupsThroughTheSharedLibrary() throws {
            let b = browser(3, spaces: Sandbox().store())
            let t = b.tabs.map(\.id)
            let group = try #require(b.group([t[0], t[1]], name: "Dragged \(UUID().uuidString)"))
            let name = try #require(b.groups.first?.name)
            #expect(SidebarDrag.pin([SidebarDrag.group(group)], before: nil, in: b))
            #expect(b.space.pinnedFolders == ["Changmun " + name])
            #expect(Library.shared.folders().first { $0.name == "Changmun " + name }?.entries.count == 2)
            b.undoNotice()
            #expect(b.space.pinnedFolders.isEmpty && Library.shared.folders().allSatisfy { $0.name != "Changmun " + name })
            // Dropped on a folder row or a favorite, the same path.
            #expect(SidebarDrag.drop([SidebarDrag.group(group)], onFolder: "Arc Nowhere", browser: b))
            #expect(Library.shared.folders().first { $0.name == "Arc Nowhere / " + name }?.entries.count == 2)
            b.undoNotice()
            // On the favorites it is not split into favorites: it becomes the first pinned folder, tabs and all.
            #expect(SidebarDrag.pin([SidebarDrag.folder("Arc Home")], before: nil, in: b))
            #expect(SidebarDrag.drop([SidebarDrag.group(group)], onFavorite: nil, browser: b))
            #expect(b.space.pinnedFolders.first == "Changmun " + name)
            #expect(!Library.shared.isFavorite("https://site1.example/", in: b.favoritesFolder))
            b.undoNotice()
            #expect(b.space.pinnedFolders == ["Arc Home"])
        }
    }
}
