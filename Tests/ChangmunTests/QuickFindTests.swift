import AppKit
import Foundation
import Testing
import WebKit
@testable import Changmun

extension SharedAgentState {
    /// ⌘K: one list for the tabs, spaces, commands, bookmarks and history the user has. The address bar goes somewhere new; this finds what is there.
    @MainActor @Suite(.serialized)
    struct QuickFindTests {
        private func browser(private isPrivate: Bool = false, spaces: SpaceStore? = nil) -> Browser {
            let b = Browser(isPrivate: isPrivate, spaces: spaces)
            b.focused()
            return b
        }

        @discardableResult
        private func open(_ b: Browser, _ url: String, _ title: String, activate: Bool = false) -> Tab {
            let tab = b.openTab(url: URL(string: url), activate: activate)
            tab.title = title
            return tab
        }

        private func tabTitles(_ items: [QuickFindItem]) -> [String] {
            items.compactMap { if case .tab(_, let title, _, _, _) = $0 { title } else { nil } }
        }

        private func commands(_ items: [QuickFindItem]) -> [QuickFindCommand] {
            items.compactMap { if case .command(let command, _) = $0 { command } else { nil } }
        }

        // MARK: What it lists

        @Test func nothingTypedListsTheOtherTabsOfEverySpaceThenTheOtherSpacesAndTheCommands() {
            let box = Sandbox()
            let b = browser(spaces: box.store())
            defer { b.windowClosed() }
            let here = b.spaceID
            open(b, "https://shown.example/", "Shown", activate: true)
            open(b, "https://here.example/", "Here")
            let other = b.spaces.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
            let away = b.openTab(url: URL(string: "https://away.example/"), activate: false, space: other.id)
            away.title = "Away"
            let items = QuickFindList.items(for: "", in: b)
            #expect(Set(tabTitles(items)) == ["Here", "Away"], "not the tab that is shown")
            #expect(items.contains { if case .space(let id, _, _) = $0 { id == other.id } else { false } })
            #expect(!items.contains { if case .space(let id, _, _) = $0 { id == here } else { false } }, "not the space already shown")
            #expect(commands(items) == QuickFindCommand.allCases)
            #expect(!items.contains { if case .bookmark = $0 { true } else if case .visit = $0 { true } else { false } }, "bookmarks and history wait for a word")
        }

        @Test func wordsFindTabsByTitleOrAddressInAnyCaseAndEveryWordHasToMatch() {
            let b = browser()
            defer { b.windowClosed() }
            open(b, "https://docs.example/guide", "Swift Guide")
            open(b, "https://news.example/", "Morning News")
            #expect(tabTitles(QuickFindList.items(for: "SWIFT", in: b)) == ["Swift Guide"])
            #expect(tabTitles(QuickFindList.items(for: "docs.example", in: b)) == ["Swift Guide"], "the address too")
            #expect(tabTitles(QuickFindList.items(for: "swift guide", in: b)) == ["Swift Guide"])
            #expect(tabTitles(QuickFindList.items(for: "swift news", in: b)).isEmpty, "both words, in one tab")
            #expect(tabTitles(QuickFindList.items(for: "스위프트", in: b)).isEmpty)
        }

        @Test func aTabNamedByTheUserIsFoundByItsName() {
            let b = browser()
            defer { b.windowClosed() }
            let tab = open(b, "https://a.example/", "Plain Title")
            tab.rename(to: "Taxes 2026")
            #expect(tabTitles(QuickFindList.items(for: "taxes", in: b)) == ["Taxes 2026"])
            #expect(tabTitles(QuickFindList.items(for: "plain", in: b)) == ["Taxes 2026"], "and still by the page's own title")
        }

        @Test func aKoreanTitleIsFoundByWhatIsTyped() {
            let b = browser()
            defer { b.windowClosed() }
            open(b, "https://ko.example/", "창문 브라우저")
            #expect(tabTitles(QuickFindList.items(for: "창문", in: b)) == ["창문 브라우저"])
        }

        @Test func thisSpacesTabsComeFirstAndAnotherSpacesTabNamesItsSpace() {
            let box = Sandbox()
            let b = browser(spaces: box.store())
            defer { b.windowClosed() }
            let other = b.spaces.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
            let away = b.openTab(url: URL(string: "https://away.example/note"), activate: false, space: other.id)
            away.title = "Note away"
            open(b, "https://here.example/note", "Note here")
            let items = QuickFindList.items(for: "note", in: b)
            #expect(tabTitles(items) == ["Note here", "Note away"])
            guard case .tab(_, _, _, let here, _) = items[0], case .tab(_, _, _, let there, _) = items[1] else { Issue.record("two tabs first"); return }
            #expect(here == nil && there == "Work")
        }

        @Test func aTabThatIsAsleepSaysSo() {
            let b = browser()
            defer { b.windowClosed() }
            let tab = open(b, "https://sleepy.example/", "Sleepy")
            tab.sleep()
            guard case .tab(_, _, _, _, let sleeping)? = QuickFindList.items(for: "sleepy", in: b).first else { Issue.record("the tab"); return }
            #expect(sleeping)
        }

        @Test func bookmarksAndHistoryFollowTheTabsAndAnOpenTabIsNotOfferedAgain() {
            let b = browser()
            defer { b.windowClosed() }
            open(b, "https://open.example/", "Open page")
            let marks = [Library.Entry(url: "https://open.example/", title: "Open page"), Library.Entry(url: "https://mark.example/", title: "Marked")]
            let visits = [Library.Entry(url: "https://mark.example/", title: "Marked"), Library.Entry(url: "https://seen.example/", title: "Seen")]
            let items = QuickFindList.items(for: "e", in: b, found: .init(query: "e", bookmarks: marks, visits: visits))
            let kinds = items.compactMap { item -> String? in
                switch item {
                case .bookmark(let url, _): "bookmark " + url
                case .visit(let url, _): "visit " + url
                default: nil
                }
            }
            #expect(kinds == ["bookmark https://mark.example/", "visit https://seen.example/"], "once each, and not the page that is open")
        }

        @Test func commandsAreFoundByNameAndSplitSaysWhatItWillDo() {
            let b = browser()
            defer { b.windowClosed() }
            let first = open(b, "https://one.example/", "One", activate: true)
            let second = open(b, "https://two.example/", "Two", activate: true)
            #expect(commands(QuickFindList.items(for: "split", in: b)) == [.splitView])
            #expect(commands(QuickFindList.items(for: "sleep", in: b)) == [.sleepTabs])
            #expect(commands(QuickFindList.items(for: "zzzz", in: b)).isEmpty)
            #expect(QuickFindList.items(for: "split view", in: b).contains(.command(.splitView, title: String(localized: "Split View"))))
            b.split(with: first.id)
            #expect(b.shownSplit != nil && b.activeID == second.id)
            #expect(QuickFindList.items(for: "split", in: b).contains(.command(.splitView, title: String(localized: "Close Split View"))))
        }

        // MARK: Order

        private func kind(_ item: QuickFindItem) -> String {
            switch item {
            case .tab(_, let title, _, _, _): "tab " + title
            case .space(_, let name, _): "space " + name
            case .command(_, let title): "command " + title
            case .bookmark: "bookmark"
            case .visit: "visit"
            }
        }

        @Test func aSpaceOrACommandWhoseNameIsTypedComesBeforeTheTabsThatMerelyHoldTheWord() {
            let box = Sandbox()
            let b = browser(spaces: box.store())
            defer { b.windowClosed() }
            _ = b.spaces.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
            for i in 0..<8 { open(b, "https://work\(i).example/split", "Notes \(i)") }
            let work = QuickFindList.items(for: "work", in: b).map(kind)
            #expect(work.first == "space Work", "Return goes to the space, not to one of the eight tabs: \(work)")
            #expect(work.dropFirst().allSatisfy { $0.hasPrefix("tab ") })
            #expect(QuickFindList.items(for: "WORK", in: b).map(kind).first == "space Work", "any case")
            let split = QuickFindList.items(for: "split", in: b).map(kind)
            #expect(split.first == "command Split View", "\(split)")
            #expect(QuickFindList.items(for: "split view", in: b).map(kind).first == "command Split View")
            // Only the start of a name goes before the tabs: a name that merely holds the word follows them.
            let inside = QuickFindList.items(for: "view", in: b).map(kind)
            #expect(inside.first == "command Split View", "no tab holds \"view\", so the command is first")
            open(b, "https://view.example/", "View of things")
            let after = QuickFindList.items(for: "view", in: b).map(kind)
            #expect(after.first == "tab View of things" && after.contains("command Split View"), "\(after)")
        }

        @Test func theWholeNameComesBeforeAnotherNameItIsTheStartOf() {
            let box = Sandbox()
            let b = browser(spaces: box.store())
            defer { b.windowClosed() }
            _ = b.spaces.add(name: "Workshop", symbol: "star", tint: .blue, isProfile: false)
            _ = b.spaces.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
            #expect(QuickFindList.items(for: "work", in: b).map(kind).prefix(2) == ["space Work", "space Workshop"])
        }

        @Test func everyOtherSpaceIsListedWhenNothingIsTypedSoTheArrowKeysReachThem() {
            let box = Sandbox()
            let b = browser(spaces: box.store())
            defer { b.windowClosed() }
            for n in 1...6 { _ = b.spaces.add(name: "Space \(n)", symbol: "star", tint: .blue, isProfile: false) }
            let names = QuickFindList.items(for: "", in: b).compactMap { item -> String? in if case .space(_, let name, _) = item { name } else { nil } }
            #expect(names == (1...6).map { "Space \($0)" })
            let typed = QuickFindList.items(for: "space", in: b).compactMap { item -> String? in if case .space(_, let name, _) = item { name } else { nil } }
            #expect(typed.count == 6, "the ones whose name starts with the words are not cut off either")
        }

        // MARK: What the library found, and for which words

        /// The words typed move on before the library has answered: the rows found for the earlier words must not be in the list, where Return
        /// would open one of them for words it was not found for.
        @Test func rowsFoundForEarlierWordsAreNotShownForTheWordsNowTyped() {
            let b = browser()
            defer { b.windowClosed() }
            let old = QuickFindList.Found(query: "wik", bookmarks: [Library.Entry(url: "https://wiki.example/", title: "Wiki")],
                                          visits: [Library.Entry(url: "https://wikipedia.example/", title: "Wikipedia")])
            #expect(QuickFindList.items(for: "wik", in: b, found: old).map(kind) == ["bookmark", "visit"], "for the words they were found for, they are shown")
            let now = QuickFindList.items(for: "wiki", in: b, found: old)
            #expect(now.isEmpty, "nothing matches yet, and the older rows are not it: \(now.map(kind))")
            #expect(QuickFindList.items(for: "wiki", in: b, found: .init(query: "wiki", bookmarks: old.bookmarks)).map(kind) == ["bookmark"])
            #expect(QuickFindList.items(for: " WIKI ", in: b, found: .init(query: QuickFindList.normalized(" WIKI "), bookmarks: old.bookmarks)).map(kind) == ["bookmark"],
                    "the same words in another case or with spaces around are the same words")
            #expect(QuickFindList.items(for: "", in: b, found: old).allSatisfy { if case .bookmark = $0 { false } else { true } })
        }

        // MARK: The keys

        @Test func theArrowKeysMoveTheHighlightAndStopAtTheEnds() {
            #expect(QuickFindList.moved(0, by: 1, in: 3) == 1)
            #expect(QuickFindList.moved(2, by: 1, in: 3) == 2, "down stops at the last row")
            #expect(QuickFindList.moved(0, by: -1, in: 3) == 0, "up stops at the first")
            #expect(QuickFindList.moved(1, by: -1, in: 3) == 0)
            #expect(QuickFindList.moved(0, by: 1, in: 0) == 0, "an empty list")
        }

        @Test func returnRunsTheHighlightedRowAndNothingWhileASyllableIsComposingOrPastTheEnd() {
            let rows: [QuickFindItem] = [.command(.splitView, title: "S"), .bookmark(url: "u", title: "t")]
            #expect(QuickFindList.chosen(rows, at: 1) == rows[1])
            #expect(QuickFindList.chosen(rows, at: 2) == nil)
            #expect(QuickFindList.chosen(rows, at: -1) == nil)
            #expect(QuickFindList.chosen(rows, at: 0, composing: true) == nil, "that Return only settles the Korean syllable")
            #expect(QuickFindList.chosen([], at: 0) == nil)
        }

        // MARK: Sleeping tabs

        @Test func sleepingBackgroundTabsSaysWhetherThereWereAnyToSleep() {
            let b = browser()
            defer { b.windowClosed() }
            open(b, "https://shown.example/", "Shown", activate: true)
            QuickFindList.run(.command(.sleepTabs, title: ""), in: b)
            #expect(b.overlay.statusMessage == String(localized: "No background tabs are awake"))
            open(b, "https://awake.example/", "Awake").wake()
            QuickFindList.run(.command(.sleepTabs, title: ""), in: b)
            #expect(b.overlay.statusMessage == String(localized: "Putting background tabs to sleep"))
        }

        // MARK: Private windows

        @Test func aPrivateWindowsTabsAreNeverInAnotherWindowsListOrTheOtherWayRound() {
            let box = Sandbox()
            let ordinary = browser(spaces: box.store())
            let hidden = browser(private: true)
            defer { ordinary.windowClosed(); hidden.windowClosed() }
            open(ordinary, "https://public.example/", "Visible everywhere")
            open(hidden, "https://secret.example/", "Hidden thing")
            for query in ["", "thing", "secret", "visible", "e"] {
                #expect(!tabTitles(QuickFindList.items(for: query, in: ordinary)).contains("Hidden thing"), "\"\(query)\" in the ordinary window")
                #expect(!tabTitles(QuickFindList.items(for: query, in: hidden)).contains("Visible everywhere"), "\"\(query)\" in the private window")
            }
            #expect(tabTitles(QuickFindList.items(for: "hidden", in: hidden)) == ["Hidden thing"])
        }

        @Test func aPrivateWindowHasNoSpacesToGoToAndNoHistory() {
            let box = Sandbox()
            let hidden = browser(private: true, spaces: box.store())
            defer { hidden.windowClosed() }
            _ = hidden.spaces.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
            let marks = [Library.Entry(url: "https://mark.example/", title: "Marked")]
            let visits = [Library.Entry(url: "https://seen.example/", title: "Seen")]
            let items = QuickFindList.items(for: "e", in: hidden, found: .init(query: "e", bookmarks: marks, visits: visits))
            #expect(!items.contains { if case .space = $0 { true } else { false } })
            #expect(!items.contains { if case .visit = $0 { true } else { false } }, "what is visited in the other windows is not offered")
            #expect(items.contains(.bookmark(url: "https://mark.example/", title: "Marked")), "bookmarks are, as in the address bar's list")
            let ordinary = QuickFindList.items(for: "", in: hidden)
            #expect(!ordinary.contains { if case .space = $0 { true } else { false } })
        }

        // MARK: Running a row

        @Test func aTabInAnotherSpaceBringsItsSpaceAlong() {
            let box = Sandbox()
            let b = browser(spaces: box.store())
            defer { b.windowClosed() }
            open(b, "https://here.example/", "Here", activate: true)
            let other = b.spaces.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
            let away = b.openTab(url: URL(string: "https://away.example/"), activate: false, space: other.id)
            b.quickFind = true
            QuickFindList.run(.tab(id: away.id, title: "", url: "", space: "Work", sleeping: false), in: b)
            #expect(b.activeID == away.id && b.spaceID == other.id)
            #expect(!b.quickFind, "the list closes")
        }

        @Test func aSpaceRowSwitchesToTheSpace() {
            let box = Sandbox()
            let b = browser(spaces: box.store())
            defer { b.windowClosed() }
            open(b, "https://here.example/", "Here", activate: true)
            let other = b.spaces.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
            let away = b.openTab(url: URL(string: "https://away.example/"), activate: false, space: other.id)
            b.quickFind = true
            QuickFindList.run(.space(id: other.id, name: "Work", symbol: "briefcase"), in: b)
            #expect(b.spaceID == other.id && b.activeID == away.id && !b.quickFind)
        }

        @Test func aBookmarkOrVisitOpensInANewTabAndLeavesThePageAlone() {
            let b = browser()
            defer { b.windowClosed() }
            let page = open(b, "https://here.example/", "Here", activate: true)
            b.quickFind = true
            QuickFindList.run(.bookmark(url: "https://mark.example/", title: "Marked"), in: b)
            #expect(page.url?.absoluteString == "https://here.example/")
            #expect(b.tabs.count == 2 && b.active?.url?.absoluteString == "https://mark.example/" && !b.quickFind)
        }

        @Test func theSplitCommandRunsTheMenusSplit() {
            let b = browser()
            defer { b.windowClosed() }
            let first = open(b, "https://one.example/", "One", activate: true)
            open(b, "https://two.example/", "Two", activate: true)
            #expect(b.previousActiveID == first.id)
            QuickFindList.run(.command(.splitView, title: ""), in: b)
            #expect(b.shownSplit == Browser.Split(left: b.activeID!, right: first.id))
            QuickFindList.run(.command(.splitView, title: ""), in: b)
            #expect(b.shownSplit == nil)
        }

        // MARK: Taking turns with the address bar

        @Test func theListAndTheAddressBarNeverShowTogether() {
            let b = browser()
            defer { b.windowClosed() }
            b.commandBar = .newTab
            b.toggleQuickFind()
            #expect(b.quickFind && b.commandBar == nil)
            b.commandBar = .editCurrent
            #expect(!b.quickFind && b.commandBar == .editCurrent)
            b.toggleQuickFind()
            b.toggleQuickFind()
            #expect(!b.quickFind, "⌘K again closes it")
            b.showOnboarding = true
            b.toggleQuickFind()
            #expect(!b.quickFind, "nothing opens behind the welcome")
        }

        @Test func theHighlightStaysOnItsRowWhenTheListChangesUnderIt() {
            let rows: [QuickFindItem] = [.tab(id: 1, title: "A", url: "", space: nil, sleeping: false), .command(.splitView, title: "S"), .bookmark(url: "u", title: "t")]
            let longer = [.tab(id: 9, title: "Z", url: "", space: nil, sleeping: false)] + rows
            #expect(QuickFindList.keptSelection(1, old: rows, new: longer) == 2)
            #expect(QuickFindList.keptSelection(2, old: rows, new: [rows[0]]) == 0, "gone: back to the first")
            #expect(QuickFindList.keptSelection(5, old: rows, new: longer) == 0)
            let renamed = QuickFindItem.tab(id: 1, title: "A (loaded)", url: "https://a.example/", space: nil, sleeping: false)
            #expect(QuickFindList.keptSelection(0, old: rows, new: [rows[1], renamed]) == 1, "a tab is the same row whatever its title becomes")
        }

        // MARK: The key

        /// ⌘K is a menu item, so the Keyboard Shortcuts window lists it, and nothing else in either scheme uses it.
        @Test(arguments: [ShortcutScheme.safari, .chrome]) func commandKIsTheOnlyUseOfThatKey(scheme: ShortcutScheme) throws {
            let menu = AppMenu.make(scheme: scheme)
            let uses = menu.items.compactMap(\.submenu).flatMap(\.items).filter { $0.keyEquivalent == "k" && $0.keyEquivalentModifierMask == .command }
            #expect(uses.count == 1)
            #expect(uses.first?.action == #selector(AppDelegate.openQuickFind(_:)))
            let listed = ShortcutList.groups(in: menu).flatMap(\.rows)
            #expect(listed.contains { $0.keys == "⌘K" })
        }

        // MARK: What the library finds

        private func library() -> Library {
            Library(path: FileManager.default.temporaryDirectory.appendingPathComponent("quickfind-\(UUID().uuidString).sqlite").path)
        }

        @Test func theLibraryKeepsBookmarksAndHistoryApartAndSearchStillMergesThem() throws {
            let library = library()
            library.addBookmark(url: "https://wiki.example/", title: "Wiki", folder: Library.favoritesFolder)
            library.addBookmark(url: "https://wiki.example/other", title: "Wiki hidden", folder: Library.favoritesPrefix + "other")
            _ = try library.importHistory([(url: "https://wiki.example/", title: "Wiki", visits: 3, lastVisit: Date()),
                                           (url: "https://wiki.example/page", title: "Wiki page", visits: 1, lastVisit: Date())])
            let kinds = library.searchKinds("wiki", hiding: [Library.favoritesPrefix + "other"])
            #expect(kinds.bookmarks.map(\.url) == ["https://wiki.example/"], "another profile's favorites stay out")
            #expect(Set(kinds.visits.map(\.url)) == ["https://wiki.example/", "https://wiki.example/page"])
            #expect(library.searchKinds("wiki", history: false).visits.isEmpty)
            #expect(library.search("wiki").map(\.url) == ["https://wiki.example/", "https://wiki.example/other", "https://wiki.example/page"], "as before: bookmarks first, each page once")
            #expect(library.searchKinds("  ").bookmarks.isEmpty)
        }
    }
}
