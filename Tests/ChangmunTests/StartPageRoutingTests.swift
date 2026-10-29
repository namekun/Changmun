import Foundation
import Testing
@testable import Changmun

struct NewTabRouteTests {
    private static let checks: [StartAddressCheck] = [.empty, .invalid, .insecure(URL(string: "http://site.test/")!), .ok(URL(string: "https://site.test/")!)]
    private static let contexts: [NewTabContext] = [.shortcut, .windowOpen, .emptied]

    private func decide(_ setting: NewTabOpens, private isPrivate: Bool = false, _ check: StartAddressCheck = .empty, tabs: Int = 1,
                        _ context: NewTabContext = .shortcut) -> NewTabRoute {
        NewTabRoute.decide(setting, isPrivate: isPrivate, addressCheck: check, tabsInSpace: tabs, context: context)
    }

    @Test func theCommandBarSettingKeepsTodaysBehaviourEverywhere() {
        for isPrivate in [false, true] {
            for check in Self.checks {
                for tabs in 0...2 {
                    for context in Self.contexts { #expect(decide(.commandBar, private: isPrivate, check, tabs: tabs, context) == .commandBar) }
                }
            }
        }
    }

    @Test func theStartPageSettingMakesAStartTabForAShortcutAndShowsThePageForAnEmptyWindow() {
        for isPrivate in [false, true] {
            for tabs in 0...2 { #expect(decide(.startPage, private: isPrivate, tabs: tabs, .shortcut) == .startTab, "⌘T always makes a tab") }
            for context in [NewTabContext.windowOpen, .emptied] {
                #expect(decide(.startPage, private: isPrivate, tabs: 0, context) == .startPageNoTab)
                #expect(decide(.startPage, private: isPrivate, tabs: 1, context) == .startTab)
            }
        }
    }

    @Test func blankMakesABlankTabButAnEmptiedWindowIsLeftToTheStartPage() {
        for isPrivate in [false, true] {
            #expect(decide(.blank, private: isPrivate, tabs: 0, .shortcut) == .blankTab)
            #expect(decide(.blank, private: isPrivate, tabs: 2, .shortcut) == .blankTab)
            #expect(decide(.blank, private: isPrivate, tabs: 0, .windowOpen) == .blankTab)
            #expect(decide(.blank, private: isPrivate, tabs: 0, .emptied) == .startPageNoTab, "closing the last tab does not make another")
            #expect(decide(.blank, private: isPrivate, tabs: 1, .emptied) == .blankTab)
        }
    }

    @Test func anAddressLoadsInTheOrdinaryWindowWhenItIsUsable() {
        let secure = URL(string: "https://site.test/")!, plain = URL(string: "http://site.test/")!
        #expect(decide(.address, .ok(secure), tabs: 1, .shortcut) == .loadAddress(secure))
        #expect(decide(.address, .insecure(plain), tabs: 0, .shortcut) == .loadAddress(plain), "a page that isn't encrypted is allowed")
        #expect(decide(.address, .ok(secure), tabs: 0, .windowOpen) == .loadAddress(secure))
        #expect(decide(.address, .ok(secure), tabs: 0, .emptied) == .startPageNoTab, "an emptied window shows the page, it does not go to the network")
    }

    @Test func anAddressThatIsEmptyOrInvalidFallsBackToTheStartPage() {
        for check in [StartAddressCheck.empty, .invalid] {
            #expect(decide(.address, check, tabs: 1, .shortcut) == .startTab)
            #expect(decide(.address, check, tabs: 0, .windowOpen) == .startPageNoTab)
            #expect(decide(.address, check, tabs: 0, .emptied) == .startPageNoTab)
        }
    }

    @Test func aPrivateWindowIgnoresTheAddressAndShowsItsStartPage() {
        let secure = StartAddressCheck.ok(URL(string: "https://site.test/")!), plain = StartAddressCheck.insecure(URL(string: "http://site.test/")!)
        for check in [secure, plain] {
            #expect(decide(.address, private: true, check, tabs: 1, .shortcut) == .startTab)
            #expect(decide(.address, private: true, check, tabs: 0, .windowOpen) == .startPageNoTab)
            #expect(decide(.address, private: true, check, tabs: 0, .emptied) == .startPageNoTab)
        }
    }

    @Test func theWholeMatrixKeepsItsInvariants() {
        for setting in NewTabOpens.allCases {
            for isPrivate in [false, true] {
                for check in Self.checks {
                    for tabs in 0...2 {
                        for context in Self.contexts {
                            let route = decide(setting, private: isPrivate, check, tabs: tabs, context)
                            if case .loadAddress(let url) = route {
                                #expect(setting == .address && !isPrivate && check.url == url, "only a usable address of an ordinary window is loaded")
                            }
                            if route == .startPageNoTab { #expect(tabs == 0 && context != .shortcut, "a tab asked for is a tab") }
                            if route == .startTab { #expect(setting == .startPage || setting == .address) }
                            if route == .blankTab { #expect(setting == .blank) }
                            if setting == .commandBar { #expect(route == .commandBar) } else { #expect(route != .commandBar) }
                            if context == .shortcut { #expect(route != .startPageNoTab) }
                        }
                    }
                }
            }
        }
    }
}

extension SharedAgentState {
@MainActor @Suite(.serialized)
struct StartTabTests {
    private func browser(_ opens: NewTabOpens = .startPage, address: String = "", private isPrivate: Bool = false) -> Browser {
        let b = Browser(isPrivate: isPrivate, spaces: Sandbox().store())
        b.focused()
        let suite = UserDefaults(suiteName: "start-tab-\(UUID().uuidString)")!
        let store = StartPageStore(defaults: suite, folder: FileManager.default.temporaryDirectory.appendingPathComponent("start-tab-\(UUID().uuidString)"))
        store.setNewTab(opens)
        store.setAddress(address)
        b.startPageStore = store
        return b
    }

    // MARK: Routing

    @Test func aShortcutMakesAnEmptyStartTabWithTheFieldFocusedAndNoBar() {
        let b = browser()
        defer { b.windowClosed() }
        b.commandBar = .newTab
        let before = b.startPageFocusRequest
        b.openNewTab()
        let tab = try! #require(b.active)
        #expect(b.tabs.count == 1 && tab.isStart && tab.url == nil && tab.webView == nil)
        #expect(b.commandBar == nil && b.startPageFocusRequest == before + 1)
        #expect(b.showsStartPage && tab.displayTitle == String(localized: "New Tab"))
    }

    @Test func aStartTabInFrontIsReusedRatherThanPiledUp() {
        let b = browser()
        defer { b.windowClosed() }
        b.openNewTab()
        let first = b.active
        let before = b.startPageFocusRequest
        b.openNewTab()
        #expect(b.tabs.count == 1 && b.active === first && b.startPageFocusRequest == before + 1)
    }

    @Test func aStartTabJoinsTheSpaceAndTheGroupRulesOfAnyNewTab() {
        let b = browser()
        defer { b.windowClosed() }
        let page = b.openTab(url: URL(string: "http://127.0.0.1:9/"))
        b.openNewTab()
        let tab = try! #require(b.active)
        #expect(b.tabs.map(\.id) == [page.id, tab.id] && tab.spaceID == b.spaceID && tab.groupID == nil)
        #expect(tab.sortsIntoGroup, "once it has a first page it may join the group it belongs in")
    }

    @Test func theCommandBarSettingStillOpensTheBarAndMakesNoTab() {
        let b = browser(.commandBar)
        defer { b.windowClosed() }
        b.openNewTab()
        #expect(b.commandBar == .newTab && b.tabs.isEmpty && !b.showsStartPage)
        b.commandBar = nil
        b.openNewTab(.windowOpen)
        #expect(b.commandBar == .newTab && b.tabs.isEmpty)
    }

    @Test func blankOpensAboutBlankAsAnOrdinaryTab() {
        let b = browser(.blank)
        defer { b.windowClosed() }
        b.openNewTab()
        let tab = try! #require(b.active)
        #expect(tab.url?.absoluteString == "about:blank" && !tab.isStart && b.commandBar == nil)
    }

    @Test func anAddressLoadsThroughTheNormalNavigationPath() {
        let b = browser(.address, address: "http://127.0.0.1:9/start")
        defer { b.windowClosed() }
        b.openNewTab()
        let tab = try! #require(b.active)
        #expect(tab.url?.host() == "127.0.0.1" && !tab.isStart && tab.webView != nil)
    }

    @Test func anInvalidOrEmptyAddressFallsBackToTheStartPage() {
        for typed in ["", "not an address", "ftp://x.test/"] {
            let b = browser(.address, address: typed)
            defer { b.windowClosed() }
            b.openNewTab()
            #expect(b.active?.isStart == true, "\(typed)")
        }
    }

    @Test func aPrivateWindowShowsTheStartPageWhateverAddressIsSet() {
        let b = browser(.address, address: "https://site.test/", private: true)
        defer { b.windowClosed() }
        b.openNewTab()
        #expect(b.active?.isStart == true && b.active?.url == nil && b.commandBar == nil)
    }

    @Test func aWindowWithNoTabShowsTheStartPageAndTakesTheKeyboardWithoutABar() {
        let b = browser()
        defer { b.windowClosed() }
        let before = b.startPageFocusRequest
        b.openNewTab(.windowOpen)
        #expect(b.tabs.isEmpty && b.active == nil && b.commandBar == nil && b.showsStartPage && b.startPageFocusRequest == before + 1)
    }

    @Test func closingTheLastTabLeavesTheStartPageOrTheBarAsTheSettingSays() {
        let b = browser()
        defer { b.windowClosed() }
        let page = b.openTab(url: URL(string: "http://127.0.0.1:9/"))
        b.close(page.id)
        #expect(b.active == nil && b.commandBar == nil && b.showsStartPage)
        b.startPageStore.setNewTab(.commandBar)
        let again = b.openTab(url: URL(string: "http://127.0.0.1:9/"))
        b.close(again.id)
        #expect(b.commandBar == .newTab && !b.showsStartPage)
    }

    @Test func anEmptySpaceShowsTheStartPage() {
        let b = browser()
        defer { b.windowClosed() }
        _ = b.openTab(url: URL(string: "http://127.0.0.1:9/"))
        let other = b.spaces.add(name: "Empty", symbol: "briefcase", tint: .blue, isProfile: false)
        b.switchSpace(to: other.id)
        #expect(b.active == nil && b.commandBar == nil && b.showsStartPage)
    }

    @Test func aLocationKeyOnAStartTabFocusesItsFieldAndElsewhereKeepsItsOldWays() {
        let b = browser()
        defer { b.windowClosed() }
        b.openNewTab()
        let before = b.startPageFocusRequest
        let address = b.addressFocusRequest
        b.openLocation()
        #expect(b.startPageFocusRequest == before + 1 && b.addressFocusRequest == address && b.commandBar == nil)
        _ = b.openTab(url: URL(string: "http://127.0.0.1:9/"))
        b.openLocation()
        #expect(b.startPageFocusRequest == before + 1, "on a page it is the address bar's")
        #expect(b.commandBar == .editCurrent || b.addressFocusRequest == address + 1)
    }

    // MARK: Lifecycle

    @Test func aStartTabBecomesAPageTabWhenSomethingLoadsInIt() {
        let b = browser()
        defer { b.windowClosed() }
        b.openNewTab()
        let tab = try! #require(b.active)
        b.open("127.0.0.1:9/typed", in: .editCurrent)
        #expect(b.tabs.count == 1 && b.active === tab && !tab.isStart && tab.url?.host() == "127.0.0.1" && tab.webView != nil)
    }

    @Test func typingInAWindowWithNoTabOpensATab() {
        let b = browser()
        defer { b.windowClosed() }
        b.openNewTab(.windowOpen)
        b.open("127.0.0.1:9/typed", in: .editCurrent)
        #expect(b.tabs.count == 1 && b.active?.isStart == false)
    }

    @Test func aStartTabNeverBecomesAStartTabAgainAndAnAddressBeatsTheFlag() {
        let b = browser()
        defer { b.windowClosed() }
        let withAddress = Tab(id: Browser.takeID(), url: URL(string: "http://127.0.0.1:9/"), browser: b, isStart: true)
        #expect(!withAddress.isStart)
        let withState = Tab(id: Browser.takeID(), url: nil, state: Data([1]), browser: b, isStart: true)
        #expect(!withState.isStart)
        let plain = b.openTab(url: nil)
        #expect(!plain.isStart, "a blank tab of the old kind is still a page tab")
    }

    @Test func closingAStartTabLeavesNothingToReopen() {
        let b = browser()
        defer { b.windowClosed() }
        let page = b.openTab(url: URL(string: "http://127.0.0.1:9/"))
        b.openNewTab()
        let start = try! #require(b.active)
        b.close(start.id)
        #expect(b.closedTabs.isEmpty && b.active === page)
        b.close(page.id)
        #expect(b.closedTabs.count == 1, "a page is remembered as before")
    }

    @Test func aStartTabIsNeverSleptArchivedOrSplit() {
        let b = browser()
        defer { b.windowClosed() }
        let page = b.openTab(url: URL(string: "http://127.0.0.1:9/"))
        b.openNewTab()
        let start = try! #require(b.active)
        start.lastShown = .distantPast
        b.activate(page.id)
        let archive = TabArchive(file: FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString).json"))
        b.archiveIdleTabs(olderThan: 0, to: archive)
        b.sleepIdleTabs(olderThan: 0)
        #expect(b.tabs.contains { $0 === start } && start.webView == nil && archive.entries.isEmpty)
        b.split(with: start.id)
        #expect(b.split == nil, "nothing to put beside the page")
        b.activate(start.id)
        b.split(with: page.id)
        #expect(b.split == nil)
    }

    @Test func aStartTabHasNothingForTheTidyingTheMenuOrTheFindBar() {
        let b = browser()
        defer { b.windowClosed() }
        _ = b.openTab(url: URL(string: "http://127.0.0.1:9/"), activate: false)
        b.openNewTab()
        #expect(b.looseTabs.count == 1 && b.looseTabs[0] !== b.active, "tidying sorts pages only")
        b.showFindBar()
        #expect(!b.findBarVisible)
        let tab = try! #require(b.active)
        #expect(tab.url == nil && tab.title.isEmpty && tab.webView == nil, "what an extension can read of it")
        #expect(tab.aiTitle == String(localized: "New Tab"))
    }

    @Test func theStartPageMayShowHistoryOnlyInAnOrdinaryWindow() {
        let normal = browser(), hidden = browser(private: true)
        defer { normal.windowClosed(); hidden.windowClosed() }
        #expect(normal.startPageMayShowHistory)
        #expect(!hidden.startPageMayShowHistory)
    }

    // MARK: Session

    @Test func aStartTabIsSavedAndComesBackAsOne() throws {
        let b = browser()
        defer { b.windowClosed() }
        b.openNewTab()
        let data = try JSONEncoder().encode(Browser.SavedWindows(windows: [b.savedSession(fresh: true)]))
        let saved = try #require(Browser.SavedWindows.decode(data).first)
        #expect(saved.tabs.count == 1 && saved.tabs[0].start == true && saved.tabs[0].url == nil)
        let restored = browser()
        defer { restored.windowClosed() }
        restored.restore(saved)
        let tab = try #require(restored.active)
        #expect(restored.tabs.count == 1 && tab.isStart && tab.webView == nil && restored.showsStartPage && restored.commandBar == nil)
    }

    @Test func aSessionFromBeforeHasNoStartTabsAndDecodesAsBefore() throws {
        let old = #"{"tabs":[{"url":"https://a.example/","title":"A"},{"title":"Blank"}],"active":0}"#
        let saved = Browser.SavedWindows.decode(Data(old.utf8))[0]
        #expect(saved.tabs.count == 2 && saved.tabs.allSatisfy { $0.start == nil })
        let b = browser()
        defer { b.windowClosed() }
        b.restore(saved)
        #expect(b.tabs.count == 2 && b.tabs.allSatisfy { !$0.isStart })
        let encoded = try String(data: JSONEncoder().encode(b.savedSession(fresh: false)), encoding: .utf8) ?? ""
        #expect(!encoded.contains("\"start\""), "a page tab writes no flag")
    }

    @Test func aPageTabThatWasAStartTabIsSavedAsAPage() throws {
        let b = browser()
        defer { b.windowClosed() }
        b.openNewTab()
        b.open("127.0.0.1:9/p", in: .editCurrent)
        #expect(b.savedSession(fresh: false).tabs[0].start == nil && b.savedSession(fresh: false).tabs[0].url != nil)
    }

    @Test func aWindowWhoseOnlyTabWasAStartTabIsKeptInTheSession() throws {
        let b = browser()
        defer { b.windowClosed() }
        b.openNewTab()
        let session = b.savedSession(fresh: false)
        #expect(!session.tabs.isEmpty, "the window is saved, as one with a page would be")
        #expect(Browser.sessionSignature().contains { $0.contains("\(b.tabs[0].id) ") })
    }

    @Test func movingAStartTabToAWindowOfItsOwnKeepsItAStartTab() {
        let b = browser()
        defer { b.windowClosed() }
        b.openNewTab()
        let id = b.tabs[0].id
        let before = Set(Browser.all.map(ObjectIdentifier.init))
        b.moveToNewWindow(id)
        let created = Browser.all.filter { !before.contains(ObjectIdentifier($0)) }
        defer { created.forEach { $0.windowClosed() } }
        #expect(created.first?.tabs.first?.isStart == true)
    }
}
}
