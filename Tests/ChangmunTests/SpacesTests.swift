import AppKit
import Foundation
import Testing
import WebKit
@testable import Changmun

/// A folder of its own, with the settings the first space is made from, so no test touches the user's data.
/// Removes the data stores a test made, so they don't pile up in the test runner's own folder.
@MainActor
func erase(_ ids: UUID...) {
    Task { for id in ids { try? await WKWebsiteDataStore.remove(forIdentifier: id) } }
}

@MainActor
struct Sandbox {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-\(UUID().uuidString)", isDirectory: true)
    let defaults = UserDefaults(suiteName: "spaces-\(UUID().uuidString)")!

    init() { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

    func store() -> SpaceStore { SpaceStore(folder: folder, defaults: defaults) }
    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
}

extension SharedAgentState {
    @MainActor @Suite(.serialized)
    struct SpaceMigrationTests {
        /// A session as the version before spaces wrote it: a bare window, tabs with no space.
        private let oldSession = """
        {"tabs":[{"url":"https://a.example/","title":"A","bookmarkKey":"\\nhttps://a.example/"},
                 {"url":"https://b.example/","title":"B","state":"AQID","group":"6F3C2F0E-8F1B-4C57-9E43-0C1F0C1D2E3A"},
                 {"url":"https://c.example/","title":"C","group":"6F3C2F0E-8F1B-4C57-9E43-0C1F0C1D2E3A"}],
         "active":2,"previous":1,"saved":750000000,
         "groups":[{"id":"6F3C2F0E-8F1B-4C57-9E43-0C1F0C1D2E3A","name":"Reading","isOpen":true}]}
        """

        @Test func anOldSessionLandsInTheFirstSpaceWithNothingLost() throws {
            let box = Sandbox()
            let browser = Browser(spaces: box.store())
            let session = try #require(Browser.SavedWindows.decode(Data(oldSession.utf8)).first)
            browser.restore(session)
            #expect(browser.tabs.map { $0.url?.absoluteString } == ["https://a.example/", "https://b.example/", "https://c.example/"])
            #expect(browser.tabs.map(\.title) == ["A", "B", "C"])
            #expect(browser.tabs.allSatisfy { $0.spaceID == Space.defaultID } && browser.spaceID == Space.defaultID)
            #expect(browser.tabs[0].bookmarkKey == "\nhttps://a.example/")
            #expect(browser.tabs[1].groupID == browser.tabs[2].groupID && browser.groups.map(\.name) == ["Reading"])
            #expect(browser.activeID == browser.tabs[2].id && browser.previousActiveID == browser.tabs[1].id)
            // The sleeping tab's back and forward state is still held, and the next save writes it again.
            let saved = browser.savedSession(fresh: false)
            #expect(saved.tabs[1].state == Data([1, 2, 3]))
            #expect(saved.tabs.allSatisfy { $0.space == Space.defaultID })
        }

        @Test func oldSettingsBecomeTheFirstSpacesFoldersAndAreKeptAsTheyWere() throws {
            let box = Sandbox()
            box.defaults.set(["Arc A", "Arc B"], forKey: "pinnedFolders")
            box.defaults.set(["Arc A", "source:Arc"], forKey: "openFolders")
            let store = box.store()
            let first = try #require(store.spaces.first)
            #expect(store.spaces.count == 1 && first.id == Space.defaultID && !first.isProfile && !first.name.isEmpty)
            #expect(first.pinnedFolders == ["Arc A", "Arc B"] && Set(first.openFolders) == ["Arc A", "source:Arc"])
            // Nothing was taken out of the old settings, and a copy of them sits beside the new file.
            #expect(box.defaults.stringArray(forKey: "pinnedFolders") == ["Arc A", "Arc B"])
            let copy = try #require(try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: box.file("before-spaces-preferences.json"))))
            #expect(copy["pinnedFolders"] == ["Arc A", "Arc B"] && Set(copy["openFolders"] ?? []) == ["Arc A", "source:Arc"])
        }

        @Test func theOldSessionAndLibraryAreCopiedBeforeAnythingIsWritten() throws {
            let box = Sandbox()
            try Data(oldSession.utf8).write(to: box.file("session.json"))
            let library = Library(path: box.file("library.sqlite").path)
            #expect(library.toggleBookmark(url: "https://fav.example/", title: "Fav"))
            _ = try library.importBookmarks([("https://x.example/", "X", "Arc Bar")])
            library.recordVisit(url: "https://seen.example/", title: "Seen")
            _ = box.store()
            #expect(try Data(contentsOf: box.file("before-spaces-session.json")) == Data(oldSession.utf8))
            let copy = Library(path: box.file("before-spaces-library.sqlite").path)
            #expect(copy.favorites().map(\.url) == ["https://fav.example/"] && copy.folders().first?.entries.map(\.url) == ["https://x.example/"])
            #expect(copy.history().map(\.url) == ["https://seen.example/"])
            // The originals are as they were: the old favorites are the first space's favorites, the folders are shared.
            let read = try #require(library.readBookmarks())
            #expect(read.favorites[Space(id: Space.defaultID, name: "", symbol: "", tint: .gray).favoritesFolder]?.map(\.url) == ["https://fav.example/"])
            #expect(read.folders.map(\.name) == ["Arc Bar"] && library.history().count == 1)
            #expect(try Data(contentsOf: box.file("session.json")) == Data(oldSession.utf8))
        }

        @Test func aBackupIsNotWrittenOverLater() throws {
            let box = Sandbox()
            try Data(oldSession.utf8).write(to: box.file("session.json"))
            _ = box.store()
            try Data("{}".utf8).write(to: box.file("session.json"))
            // Another launch reads the spaces file; with it gone, the move runs again but keeps the first copy.
            try FileManager.default.removeItem(at: box.file("spaces.json"))
            _ = box.store()
            #expect(try Data(contentsOf: box.file("before-spaces-session.json")) == Data(oldSession.utf8))
        }

        @Test func aDamagedSpacesFileFallsBackToOneSpaceAndIsKept() throws {
            let box = Sandbox()
            try Data("not json {".utf8).write(to: box.file("spaces.json"))
            let store = box.store()
            #expect(store.spaces.map(\.id) == [Space.defaultID])
            let kept = try FileManager.default.contentsOfDirectory(atPath: box.folder.path).filter { $0.hasPrefix("spaces-damaged") }
            #expect(kept.count == 1)
            #expect(try Data(contentsOf: box.file(kept[0])) == Data("not json {".utf8))
            // Tabs saved in spaces that no longer exist come back in the first one.
            let gone = UUID()
            let json = #"{"windows":[{"tabs":[{"url":"https://a.example/","title":"A","space":"\#(gone)"},{"url":"https://b.example/","title":"B"}],"space":"\#(gone)"}]}"#
            let browser = Browser(spaces: store)
            browser.restore(try #require(Browser.SavedWindows.decode(Data(json.utf8)).first))
            #expect(browser.tabs.count == 2 && browser.tabs.allSatisfy { $0.spaceID == Space.defaultID } && browser.spaceID == Space.defaultID)
        }

        @Test func aSpaceFromAnotherVersionStillOpens() throws {
            let box = Sandbox()
            let id = UUID()
            let json = #"{"spaces":[{"id":"\#(Space.defaultID)","name":"Home","symbol":"house","tint":"gray"},{"id":"\#(id)","name":"Odd","tint":"mauve","extra":1},{"name":"no id"}],"active":"\#(id)"}"#
            try Data(json.utf8).write(to: box.file("spaces.json"))
            let store = box.store()
            #expect(store.spaces.map(\.name) == ["Home", "Odd"] && store.space(id).tint == .gray && store.space(id).symbol == "house" && store.lastActive == id)
        }
    }
}

extension SharedAgentState {
    @MainActor @Suite(.serialized)
    struct SpaceStoreTests {
        @Test func spacesAreAddedChangedAndRemovedAndKept() {
            let box = Sandbox()
            let store = box.store()
            let work = store.add(name: "  Work ", symbol: "briefcase", tint: .blue, isProfile: true)
            let study = store.add(name: "", symbol: "📚", tint: .green, isProfile: false)
            #expect(store.spaces.map(\.name) == [store.spaces[0].name, "Work", "Space"] && study.isEmoji && !work.isEmoji)
            store.update(work.id, name: "Job", symbol: "cart", tint: .teal)
            #expect(store.space(work.id).name == "Job" && store.space(work.id).tint == .teal && store.space(work.id).isProfile, "a profile stays a profile")
            store.rememberActive(study.id)
            let reloaded = box.store()
            #expect(reloaded.spaces == store.spaces && reloaded.lastActive == study.id)
            #expect(store.remove(study.id)?.name == "Space" && store.lastActive != study.id)
            #expect(box.store().spaces.map(\.id) == [Space.defaultID, work.id])
            #expect(store.remove(work.id) != nil)
            #expect(store.remove(Space.defaultID) == nil && store.spaces.count == 1, "the last space stays")
        }

        @Test func theFirstSpaceCanBeRenamedAndDeleted() throws {
            let store = Sandbox().store()
            let other = store.add(name: "Other", symbol: "book", tint: .purple, isProfile: false)
            store.update(Space.defaultID, name: "Home", symbol: "house", tint: .gray)
            #expect(store.space(Space.defaultID).name == "Home")
            #expect(store.remove(Space.defaultID) != nil)
            #expect(store.spaces.map(\.id) == [other.id] && store.space(Space.defaultID).id == other.id, "tabs of a gone space belong to the first one left")
        }

        @Test func foldersArePinnedAndOpenPerSpace() {
            let store = Sandbox().store()
            let b = store.add(name: "B", symbol: "book", tint: .purple, isProfile: false).id
            store.pinFolder("Arc A", in: Space.defaultID)
            store.pinFolder("Arc B", in: b)
            store.toggleOpen("Arc A", in: b)
            #expect(store.space(Space.defaultID).pinnedFolders == ["Arc A"] && store.space(b).pinnedFolders == ["Arc B"])
            #expect(store.space(Space.defaultID).openFolders.isEmpty && store.space(b).openFolders == ["Arc A"])
            store.toggleOpen("Arc A", in: b)
            #expect(store.space(b).openFolders.isEmpty)
            store.unpinFolder("Arc A")
            #expect(store.space(Space.defaultID).pinnedFolders.isEmpty && store.space(b).pinnedFolders == ["Arc B"])
        }

        @Test func eachSpaceKeepsItsOwnFavoritesInTheSharedLibrary() throws {
            let box = Sandbox()
            let store = box.store()
            let other = store.add(name: "Other", symbol: "book", tint: .purple, isProfile: false)
            let mine = store.space(Space.defaultID).favoritesFolder, theirs = other.favoritesFolder
            #expect(mine == Library.favoritesFolder && theirs != mine && Library.isFavorites(theirs))
            let library = Library(path: box.file("lib.sqlite").path)
            #expect(library.toggleBookmark(url: "https://both.example/", title: "Both", in: mine))
            #expect(library.toggleBookmark(url: "https://both.example/", title: "Both", in: theirs), "the same page can be a favorite in two spaces")
            #expect(library.toggleBookmark(url: "https://only.example/", title: "Only", in: theirs))
            _ = try library.importBookmarks([("https://shared.example/", "Shared", "Arc Bar")])
            #expect(library.favorites(in: mine).map(\.url) == ["https://both.example/"])
            #expect(library.favorites(in: theirs).map(\.url) == ["https://both.example/", "https://only.example/"])
            #expect(library.isFavorite("https://only.example/", in: theirs) && !library.isFavorite("https://only.example/", in: mine))
            // Bookmark folders and the search are shared, and a space's favorites never show up as a folder.
            #expect(library.folders().map(\.name) == ["Arc Bar"])
            let read = try #require(library.readBookmarks())
            #expect(read.favorites[mine]?.count == 1 && read.favorites[theirs]?.count == 2 && read.folders.map(\.name) == ["Arc Bar"])
            #expect(library.search("only").map(\.url) == ["https://only.example/"])
            library.moveFavorite("https://only.example/", to: "https://both.example/", in: theirs)
            #expect(library.favorites(in: theirs).map(\.url) == ["https://only.example/", "https://both.example/"])
            // Taking one out of a space leaves the other's.
            #expect(!library.toggleBookmark(url: "https://both.example/", title: "Both", in: theirs))
            #expect(library.favorites(in: mine).count == 1 && library.favorites(in: theirs).count == 1)
            library.removeSource("Arc")
            #expect(library.favorites(in: mine).count == 1 && library.folders().isEmpty)
        }

        @Test func aProfileHasItsOwnStableDataStoreAndTheSameSettingsAndScripts() async throws {
            let box = Sandbox()
            let store = box.store()
            let work = store.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: true)
            let other = store.add(name: "Other", symbol: "book", tint: .green, isProfile: true)
            let plain = store.add(name: "Plain", symbol: "leaf", tint: .teal, isProfile: false)
            #expect(work.dataStoreID == work.id && other.dataStoreID == other.id && work.dataStoreID != other.dataStoreID)
            #expect(plain.dataStoreID == nil && store.space(Space.defaultID).dataStoreID == nil)
            // The same identifiers at the next launch.
            let again = box.store()
            #expect(again.space(work.id).dataStoreID == work.id && again.space(other.id).dataStoreID == other.id)

            let browser = Browser(spaces: store)
            defer { erase(work.id, other.id) }
            let ordinary = browser.configuration(for: plain.id)
            let first = browser.configuration(for: work.id)
            #expect(ordinary === browser.configuration, "an ordinary space uses the shared configuration")
            #expect(first === browser.configuration(for: work.id), "all of a profile's tabs share one configuration")
            #expect(first.websiteDataStore.identifier == work.id && first.websiteDataStore !== ordinary.websiteDataStore)
            #expect(browser.configuration(for: other.id).websiteDataStore.identifier == other.id)
            #expect(first.websiteDataStore.isPersistent)
            // Everything but the data store is as in an ordinary tab.
            #expect(first.userContentController.userScripts.count == ordinary.userContentController.userScripts.count)
            #expect(first.userContentController.userScripts.map(\.source) == ordinary.userContentController.userScripts.map(\.source))
            #expect(first.applicationNameForUserAgent == ordinary.applicationNameForUserAgent)
            #expect(first.preferences.isElementFullscreenEnabled == ordinary.preferences.isElementFullscreenEnabled)
            // A private window has no spaces: its configuration is always its own.
            let hidden = Browser(isPrivate: true, spaces: store)
            #expect(hidden.configuration(for: work.id) === hidden.configuration && !hidden.configuration.websiteDataStore.isPersistent)
            // A tab of a profile loads with the profile's store.
            let tab = browser.openTab(url: nil, activate: false, space: work.id)
            #expect(tab.spaceID == work.id && tab.wake().configuration.websiteDataStore.identifier == work.id)
            tab.sleep()
        }

        @Test func theSpaceKeysAreFreeInBothShortcutSchemes() {
            for scheme in ShortcutScheme.allCases {
                let window = AppMenu.make(scheme: scheme).items.compactMap(\.submenu).first { $0.items.contains { $0.action == #selector(AppDelegate.newSpace(_:)) } }
                let spaceItems = window?.items.filter { [#selector(AppDelegate.nextSpace(_:)), #selector(AppDelegate.previousSpace(_:)), #selector(AppDelegate.newSpace(_:)),
                                                         #selector(AppDelegate.selectNumberedSpace(_:))].contains($0.action) } ?? []
                #expect(spaceItems.count == 12, "new, next, previous and nine numbered")
                let keys = AppMenu.make(scheme: scheme).items.compactMap(\.submenu).flatMap(\.items)
                for item in spaceItems {
                    let same = keys.filter { $0.keyEquivalent == item.keyEquivalent && $0.keyEquivalentModifierMask == item.keyEquivalentModifierMask }
                    #expect(same.count == 1, "\(item.title) shares its key with \(same.map(\.title))")
                }
                #expect(spaceItems.filter { $0.action == #selector(AppDelegate.selectNumberedSpace(_:)) }.map(\.tag) == Array(1...9))
            }
        }

        @Test func aSwipeSidewaysSwitchesOnceAndAVerticalScrollNever() {
            var swipe = SpaceSwipe()
            #expect(swipe.scrolled(dx: -20, dy: 1, began: true, ended: false) == nil)
            #expect(swipe.scrolled(dx: -30, dy: 2, began: false, ended: false) == nil)
            #expect(swipe.scrolled(dx: -20, dy: 0, began: false, ended: false) == 1)
            #expect(swipe.scrolled(dx: -50, dy: 0, began: false, ended: true) == nil, "once per swipe")
            #expect(swipe.scrolled(dx: 70, dy: 3, began: true, ended: false) == -1)
            var vertical = SpaceSwipe()
            #expect(vertical.scrolled(dx: 5, dy: -80, began: true, ended: false) == nil)
            #expect(vertical.scrolled(dx: 5, dy: -80, began: false, ended: false) == nil)
        }
    }
}

extension SharedAgentState {
    @MainActor @Suite(.serialized)
    struct SpaceBrowserTests {
        @MainActor private struct Rig {
            let box = Sandbox()
            let browser: Browser
            let work: Space
            init() {
                let store = box.store()
                work = store.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
                browser = Browser(spaces: store)
                browser.focused()
            }
            var home: UUID { Space.defaultID }
            func open(_ address: String, in space: UUID? = nil, activate: Bool = false) -> Tab {
                browser.openTab(url: URL(string: "https://\(address).example/"), activate: activate, space: space)
            }
        }

        @Test func eachSpaceShowsOnlyItsOwnTabsAndGroups() throws {
            let rig = Rig(), b = rig.browser
            defer { b.windowClosed() }
            let a1 = rig.open("a1", activate: true), a2 = rig.open("a2")
            let w1 = rig.open("w1", in: rig.work.id), w2 = rig.open("w2", in: rig.work.id)
            #expect(b.spaceID == rig.home, "opening a tab in another space doesn't switch to it unless it is shown")
            #expect(b.spaceTabs.map(\.id) == [a1.id, a2.id] && b.listedTabs.map(\.id) == [a1.id, a2.id] && b.recentTabs.map(\.id).sorted() == [a1.id, a2.id].sorted())
            let group = try #require(b.group([a1.id, a2.id], name: "Mine"))
            #expect(b.spaceGroups.map(\.id) == [group] && b.looseTabs.isEmpty)
            b.switchSpace(to: rig.work.id)
            #expect(b.spaceTabs.map(\.id) == [w1.id, w2.id] && b.spaceGroups.isEmpty && b.looseTabs.count == 2 && b.tabs.count == 4)
            #expect(b.visibleTabs.map(\.id) == [w1.id, w2.id])
            // Selecting by number and by offset stays inside the space.
            b.selectTab(number: 1)
            #expect(b.activeID == w1.id)
            b.selectTab(offset: -1)
            #expect(b.activeID == w2.id)
        }

        @Test func switchingKeepsEachSpacesSelectedTab() throws {
            let rig = Rig(), b = rig.browser
            defer { b.windowClosed() }
            let a1 = rig.open("a1", activate: true), a2 = rig.open("a2")
            let w1 = rig.open("w1", in: rig.work.id), w2 = rig.open("w2", in: rig.work.id)
            b.activate(a2.id)
            b.switchSpace(to: rig.work.id)
            #expect(b.spaceID == rig.work.id && b.activeID == w1.id, "a space never shown shows its first tab")
            b.activate(w2.id)
            b.switchSpace(to: rig.home)
            #expect(b.activeID == a2.id && b.previousActiveID == nil)
            b.activate(a1.id)
            b.switchSpace(to: rig.work.id)
            #expect(b.activeID == w2.id)
            b.switchSpace(offset: 1)
            #expect(b.spaceID == rig.home && b.activeID == a1.id)
            b.switchSpace(number: 2)
            #expect(b.spaceID == rig.work.id)
            b.switchSpace(number: 9)
            #expect(b.spaceID == rig.work.id, "9 is the last space")
            // Showing a tab of the other space brings its space along.
            b.activate(a2.id)
            #expect(b.spaceID == rig.home && b.activeID == a2.id)
            // Closing the shown tab goes to one in the same space, never across.
            b.close(a2.id)
            #expect(b.spaceID == rig.home && b.activeID == a1.id)
            b.close(a1.id)
            #expect(b.spaceID == rig.home && b.activeID == nil && b.commandBar == .newTab && b.tabs.count == 2)
            b.switchSpace(to: rig.work.id)
            #expect(b.activeID == w2.id && b.commandBar == nil, "the bar an empty space opened goes away when another space is shown")
        }

        @Test func splitViewStaysInsideTheSpace() {
            let rig = Rig(), b = rig.browser
            defer { b.windowClosed() }
            let a1 = rig.open("a1", activate: true), a2 = rig.open("a2")
            let w1 = rig.open("w1", in: rig.work.id)
            b.split(with: w1.id)
            #expect(b.split == nil)
            b.split(with: a2.id)
            #expect(b.shownSplit == Browser.Split(left: a1.id, right: a2.id))
            b.switchSpace(to: rig.work.id)
            #expect(b.shownSplit == nil)
        }

        @Test func aTabInAProfileSpaceUsesItsStoreAndANormalOneDoesNot() {
            let rig = Rig(), b = rig.browser
            defer { b.windowClosed() }
            let profile = b.spaces.add(name: "Login", symbol: "key", tint: .coral, isProfile: true)
            defer { erase(profile.id) }
            let plain = rig.open("plain", activate: true)
            let kept = rig.open("kept", in: profile.id)
            #expect(plain.wake().configuration.websiteDataStore === b.configuration.websiteDataStore)
            #expect(kept.wake().configuration.websiteDataStore.identifier == profile.id)
            kept.sleep()
            plain.sleep()
        }

        @Test func aSessionWithTwoSpacesComesBackAsItWas() throws {
            let rig = Rig(), b = rig.browser
            defer { b.windowClosed() }
            let a1 = rig.open("a1", activate: true), a2 = rig.open("a2")
            let w1 = rig.open("w1", in: rig.work.id), w2 = rig.open("w2", in: rig.work.id)
            let group = try #require(b.group([w1.id, w2.id], name: "Docs"))
            w1.bookmarkKey = Browser.bookmarkKey(url: "https://w1.example/", folder: rig.work.favoritesFolder)
            b.activate(a2.id)
            b.activate(w2.id)
            b.activate(a1.id)
            let data = try JSONEncoder().encode(Browser.SavedWindows(windows: [b.savedSession]))

            let again = Browser(spaces: rig.box.store())
            again.restore(try #require(Browser.SavedWindows.decode(data).first))
            #expect(again.tabs.map { $0.url?.host() } == b.tabs.map { $0.url?.host() })
            #expect(again.tabs.map(\.spaceID) == [rig.home, rig.home, rig.work.id, rig.work.id])
            #expect(again.spaceID == rig.home && again.active?.url?.host() == "a1.example")
            #expect(again.tabs[2].bookmarkKey == w1.bookmarkKey && again.groups.map(\.id) == [group])
            again.switchSpace(to: rig.work.id)
            #expect(again.active?.url?.host() == "w2.example", "the other space's selected tab came back too")
            again.switchSpace(to: rig.home)
            #expect(again.active?.url?.host() == "a1.example")
            // The same bookmark key can be open in two spaces without one standing for the other.
            #expect(again.bookmarkTab(w1.bookmarkKey!) == nil)
            again.windowClosed()
        }

        @Test func aTabMovedToANewWindowKeepsItsSpace() throws {
            let rig = Rig(), b = rig.browser
            defer { b.windowClosed() }
            _ = rig.open("a", activate: true)
            let w = rig.open("w", in: rig.work.id)
            b.switchSpace(to: rig.work.id)
            let saved = Browser.SavedSession(tabs: [Browser.SavedTab(url: w.url?.absoluteString, title: "", space: w.spaceID)], active: 0, space: w.spaceID)
            let window = Browser(spaces: rig.box.store())
            window.restore(saved)
            #expect(window.spaceID == rig.work.id && window.tabs.first?.spaceID == rig.work.id)
            window.windowClosed()
        }

        @Test func aNewWindowStartsInTheSpaceOfTheOneInFront() {
            let rig = Rig(), b = rig.browser
            defer { b.windowClosed() }
            b.switchSpace(to: rig.work.id)
            let second = Browser(spaces: b.spaces)
            #expect(second.spaceID == rig.work.id)
            #expect(Browser(isPrivate: true, spaces: b.spaces).spaceID == Space.defaultID)
            let tab = second.openTab(url: URL(string: "https://link.example/"))
            #expect(tab.spaceID == rig.work.id && second.active === tab)
        }

        @Test func deletingASpaceClosesItsTabsEverywhereAndKeepsTheLast() {
            let rig = Rig(), b = rig.browser
            defer { b.windowClosed() }
            let a = rig.open("a", activate: true)
            _ = rig.open("w1", in: rig.work.id)
            _ = rig.open("w2", in: rig.work.id)
            let other = Browser(spaces: b.spaces)
            other.focused()
            defer { other.windowClosed() }
            b.focused()
            b.switchSpace(to: rig.work.id)
            other.switchSpace(to: rig.work.id)
            _ = other.openTab(url: URL(string: "https://w3.example/"))
            Browser.deleteSpace(rig.work.id, from: b.spaces)
            #expect(b.spaces.spaces.map(\.id) == [rig.home] && b.spaceID == rig.home && b.activeID == a.id)
            #expect(b.tabs.map(\.id) == [a.id] && other.tabs.isEmpty && other.spaceID == rig.home)
            #expect(b.closedTabs.isEmpty, "tabs of a deleted space aren't offered by Reopen Closed Tab")
            Browser.deleteSpace(rig.home, from: b.spaces)
            #expect(b.spaces.spaces.count == 1)
        }

        @Test func archivedTabsReopenInTheirSpace() {
            let rig = Rig(), b = rig.browser
            defer { b.windowClosed() }
            _ = rig.open("a", activate: true)
            let w = rig.open("w", in: rig.work.id)
            w.lastShown = Date(timeIntervalSinceNow: -7200)
            let archive = TabArchive(file: rig.box.file("archive.json"))
            b.archiveIdleTabs(olderThan: 3600, to: archive)
            #expect(archive.entries.map(\.space) == [rig.work.id] && b.tabs.count == 1)
            b.reopen(archive.entries[0], from: archive)
            #expect(b.spaceID == rig.work.id && b.active?.url?.host() == "w.example")
        }

        @Test func theAIListsTabsOfEverySpaceWithTheirNames() async throws {
            let rig = Rig(), b = rig.browser
            defer { b.windowClosed() }
            let a = rig.open("a", activate: true)
            let w = rig.open("w", in: rig.work.id)
            let text = try #require(await ToolCatalog.call("list_tabs", [:], caller: "test").content.first?["text"] as? String)
            #expect(text.contains("* #\(a.id) [\(b.spaces.space(Space.defaultID).name)] "))
            #expect(text.contains("#\(w.id) [Work] ") && a.id != w.id)
            #expect(ToolCatalog.findTab(w.id) === w, "a tab of another space is found by id")
        }

        @Test func aSingleSpaceListsTabsAsBefore() async throws {
            let box = Sandbox()
            let b = Browser(spaces: box.store())
            b.focused()
            defer { b.windowClosed() }
            let tab = b.openTab(url: URL(string: "https://solo.example/"))
            let text = try #require(await ToolCatalog.call("list_tabs", [:], caller: "test").content.first?["text"] as? String)
            #expect(text.contains("* #\(tab.id) ") && !text.contains("["))
        }
    }
}
