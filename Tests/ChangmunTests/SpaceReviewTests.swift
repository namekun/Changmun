import AppKit
import Foundation
import Testing
import WebKit
@testable import Changmun

extension SharedAgentState {
    /// Spaces: what happens to old data, to favorites and to profiles when things go wrong or are deleted.
    @MainActor @Suite(.serialized)
    struct SpaceDataSafetyTests {
        private let oldSession = """
        {"tabs":[{"url":"https://a.example/","title":"A"}],"active":0}
        """

        private func stray(_ id: UUID = Space.defaultID, name: String = "Home") -> Data {
            Data(#"{"spaces":[{"id":"\#(id)","name":"\#(name)","symbol":"house","tint":"gray"}],"active":"\#(id)"}"#.utf8)
        }

        @Test func aStraySpacesFileStillTakesOverTheOldFoldersOnce() throws {
            let box = Sandbox()
            try stray().write(to: box.file("spaces.json"))
            try Data(oldSession.utf8).write(to: box.file("session.json"))
            box.defaults.set(["Arc A", "Arc B"], forKey: "pinnedFolders")
            box.defaults.set(["Arc A"], forKey: "openFolders")
            let store = box.store()
            #expect(store.space(Space.defaultID).pinnedFolders == ["Arc A", "Arc B"] && store.space(Space.defaultID).openFolders == ["Arc A"])
            #expect(try Data(contentsOf: box.file("before-spaces-session.json")) == Data(oldSession.utf8), "the copy is made on this path too")
            // Unpinned and closed since: the next launch doesn't bring them back.
            store.unpinFolder("Arc A", in: Space.defaultID)
            store.toggleOpen("Arc A", in: Space.defaultID)
            let again = box.store()
            #expect(again.space(Space.defaultID).pinnedFolders == ["Arc B"] && again.space(Space.defaultID).openFolders.isEmpty)
        }

        @Test func foldersAlreadyInTheFirstSpaceAreNotReplacedByTheOldSettings() throws {
            let box = Sandbox()
            let json = #"{"spaces":[{"id":"\#(Space.defaultID)","name":"Home","symbol":"house","tint":"gray","pinnedFolders":["Mine"]}]}"#
            try Data(json.utf8).write(to: box.file("spaces.json"))
            box.defaults.set(["Old"], forKey: "pinnedFolders")
            #expect(box.store().space(Space.defaultID).pinnedFolders == ["Mine"])
            box.defaults.set(["Later"], forKey: "pinnedFolders")
            #expect(box.store().space(Space.defaultID).pinnedFolders == ["Mine"], "and the settings are looked at only once")
        }

        @Test func aFavoritesTabWhoseSpaceCantBeFoundIsNotLeftBoundToIt() throws {
            let box = Sandbox()
            let other = UUID(), gone = UUID()
            try stray(other, name: "Other").write(to: box.file("spaces.json"))
            let store = box.store()
            #expect(!store.contains(Space.defaultID))
            let favorites = Library.favoritesPrefix + gone.uuidString
            // Only a bookmark the library holds is restored as one.
            Library.shared.addBookmark(url: "https://a.example/", title: "A", folder: Library.favoritesFolder)
            Library.shared.addBookmark(url: "https://x.example/", title: "X", folder: "Arc Bar")
            Library.shared.addBookmark(url: "https://g.example/", title: "G", folder: favorites)
            defer {
                Library.shared.removeBookmark(url: "https://a.example/", folder: Library.favoritesFolder)
                Library.shared.removeBookmark(url: "https://x.example/", folder: "Arc Bar")
                Library.shared.removeBookmark(url: "https://g.example/", folder: favorites)
            }
            let session = Browser.SavedSession(tabs: [
                Browser.SavedTab(url: "https://a.example/", title: "A", bookmarkKey: "\nhttps://a.example/"),
                Browser.SavedTab(url: "https://x.example/", title: "X", bookmarkKey: "Arc Bar\nhttps://x.example/"),
                Browser.SavedTab(url: "https://g.example/", title: "G", bookmarkKey: favorites + "\nhttps://g.example/", space: gone),
            ], active: 0)
            let browser = Browser(spaces: store)
            browser.restore(session)
            #expect(browser.tabs.allSatisfy { $0.spaceID == other })
            #expect(browser.tabs.map(\.bookmarkKey) == [nil, "Arc Bar\nhttps://x.example/", nil], "a real imported folder's key stays")
            #expect(browser.listedTabs.count == 2, "the tabs that lost their key are in the list, not out of sight")
        }

        @Test func aDamagedSpacesFileKeepsTheFirstSpacesFavoritesAndDropsOthers() throws {
            let box = Sandbox()
            try Data("{ nope".utf8).write(to: box.file("spaces.json"))
            let store = box.store()
            let gone = UUID()
            Library.shared.addBookmark(url: "https://a.example/", title: "A", folder: Library.favoritesFolder)
            Library.shared.addBookmark(url: "https://g.example/", title: "G", folder: Library.favoritesPrefix + gone.uuidString)
            defer {
                Library.shared.removeBookmark(url: "https://a.example/", folder: Library.favoritesFolder)
                Library.shared.removeBookmark(url: "https://g.example/", folder: Library.favoritesPrefix + gone.uuidString)
            }
            let session = Browser.SavedSession(tabs: [
                Browser.SavedTab(url: "https://a.example/", title: "A", bookmarkKey: "\nhttps://a.example/"),
                Browser.SavedTab(url: "https://g.example/", title: "G", bookmarkKey: Library.favoritesPrefix + gone.uuidString + "\nhttps://g.example/", space: gone),
            ], active: 0)
            let browser = Browser(spaces: store)
            browser.restore(session)
            #expect(browser.tabs.map(\.bookmarkKey) == ["\nhttps://a.example/", nil])
        }

        @Test func aReopenedTabOfAGoneSpaceDoesNotComeBackBoundToItsFavorite() {
            let box = Sandbox()
            let store = box.store()
            let work = store.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
            let b = Browser(spaces: store)
            b.focused()
            defer { b.windowClosed() }
            _ = b.openTab(url: URL(string: "https://home.example/"))
            let tab = b.openTab(url: URL(string: "https://w.example/"), activate: false, space: work.id)
            tab.bookmarkKey = Browser.bookmarkKey(url: "https://w.example/", folder: work.favoritesFolder)
            b.close(tab.id)
            store.remove(work.id)
            b.reopenClosedTab()
            #expect(b.tabs.last?.spaceID == Space.defaultID && b.tabs.last?.bookmarkKey == nil && b.listedTabs.count == 2)
        }

        @Test func keysAreKeptOnlyInTheirOwnSpace() {
            let home = Space(id: Space.defaultID, name: "", symbol: "", tint: .gray), work = Space(name: "", symbol: "", tint: .blue)
            #expect(Browser.keeps("\nhttps://a/", in: home) && !Browser.keeps("\nhttps://a/", in: work))
            let key = Browser.bookmarkKey(url: "https://a/", folder: work.favoritesFolder)
            #expect(Browser.keeps(key, in: work) && !Browser.keeps(key, in: home))
            #expect(Browser.keeps("Chrome Bar / Work\nhttps://a/", in: work) && Browser.keeps("Chrome Bar / Work\nhttps://a/", in: home))
        }

        // MARK: Backups

        @Test func aBackupCutShortIsMadeAgainAndOneThatIsWholeIsLeftAlone() throws {
            let box = Sandbox()
            try Data(oldSession.utf8).write(to: box.file("session.json"))
            try Data("half".utf8).write(to: box.file("before-spaces-session.json.partial"))
            _ = box.store()
            #expect(try Data(contentsOf: box.file("before-spaces-session.json")) == Data(oldSession.utf8))
            #expect(!FileManager.default.fileExists(atPath: box.file("before-spaces-session.json.partial").path))
            try Data("changed".utf8).write(to: box.file("session.json"))
            SpaceStore.backUp(folder: box.folder, defaults: box.defaults)
            #expect(try Data(contentsOf: box.file("before-spaces-session.json")) == Data(oldSession.utf8))
        }

        @Test func aSpacesFileThatCantBeReadIsNeitherReplacedNorTakenForMissing() throws {
            let box = Sandbox()
            let original = stray(name: "Mine")
            try original.write(to: box.file("spaces.json"))
            try Data(oldSession.utf8).write(to: box.file("session.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: box.file("spaces.json").path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: box.file("spaces.json").path) }
            let store = box.store()
            #expect(store.spaces.count == 1)
            _ = store.add(name: "New", symbol: "book", tint: .green, isProfile: false)
            store.rememberActive(store.spaces[1].id)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: box.file("spaces.json").path)
            #expect(try Data(contentsOf: box.file("spaces.json")) == original, "nothing was written over it")
            #expect(!FileManager.default.fileExists(atPath: box.file("before-spaces-session.json").path))
            #expect(box.store().space(Space.defaultID).name == "Mine", "and once it can be read again, it is what is used")
        }

        // MARK: Deleting

        @MainActor private struct Rig {
            let box = Sandbox()
            let store: SpaceStore
            let library: Library
            let browser: Browser
            let work: Space

            init() {
                store = box.store()
                library = Library(path: box.file("lib.sqlite").path)
                work = store.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
                browser = Browser(spaces: store)
                browser.focused()
            }
        }

        @Test func aDeletedSpacesFavoritesMoveToTheFirstSpaceLeft() throws {
            let rig = Rig(), store = rig.store, library = rig.library
            defer { rig.browser.windowClosed() }
            let home = store.space(Space.defaultID).favoritesFolder, work = rig.work.favoritesFolder
            _ = library.toggleBookmark(url: "https://a.example/", title: "A", in: home)
            _ = library.toggleBookmark(url: "https://both.example/", title: "Both", in: home)
            _ = library.toggleBookmark(url: "https://both.example/", title: "Both", in: work)
            _ = library.toggleBookmark(url: "https://w.example/", title: "W", in: work)
            Browser.deleteSpace(rig.work.id, from: store, library: library)
            #expect(library.favorites(in: home).map(\.url).sorted() == ["https://a.example/", "https://both.example/", "https://w.example/"])
            #expect(library.favorites(in: work).isEmpty)
            // The first space can be deleted too: its favorites (the old folder "") are still reachable afterwards.
            let other = store.add(name: "Other", symbol: "book", tint: .green, isProfile: false)
            Browser.deleteSpace(Space.defaultID, from: store, library: library)
            #expect(store.spaces.map(\.id) == [other.id])
            #expect(library.favorites(in: other.favoritesFolder).count == 3 && library.favorites(in: Library.favoritesFolder).isEmpty)
            #expect(try #require(library.readBookmarks()).favorites[other.favoritesFolder]?.count == 3)
        }

        @Test func aPrivateWindowKeepsItsTabsWhenTheFirstSpaceIsDeleted() {
            let rig = Rig()
            defer { rig.browser.windowClosed() }
            let hidden = Browser(isPrivate: true, spaces: rig.store)
            hidden.focused()
            defer { hidden.windowClosed() }
            hidden.openTab(url: URL(string: "https://secret.example/"))
            Browser.deleteSpace(Space.defaultID, from: rig.store, library: rig.library)
            #expect(hidden.tabs.count == 1 && hidden.spaceID == rig.work.id && hidden.tabs[0].spaceID == rig.work.id && hidden.active != nil)
        }

        @Test func aWindowGoesToTheSpaceThatTakesTheDeletedOnesPlace() {
            let rig = Rig()
            defer { rig.browser.windowClosed() }
            let c = rig.store.add(name: "C", symbol: "leaf", tint: .teal, isProfile: false)
            let b = rig.browser
            _ = b.openTab(url: URL(string: "https://home.example/"), space: Space.defaultID)
            _ = b.openTab(url: URL(string: "https://w.example/"), space: rig.work.id)
            _ = b.openTab(url: URL(string: "https://c.example/"), space: c.id)
            b.switchSpace(to: rig.work.id)
            Browser.deleteSpace(rig.work.id, from: rig.store, library: rig.library)
            #expect(b.spaceID == c.id && rig.store.lastActive == c.id, "the one that came after it")
            Browser.deleteSpace(c.id, from: rig.store, library: rig.library)
            #expect(b.spaceID == Space.defaultID && rig.store.lastActive == Space.defaultID, "the one before it when it was the last")
        }

        @Test func aTidyPlanOnlyTouchesTheSpaceItWasMadeFor() throws {
            let rig = Rig(), b = rig.browser
            defer { b.windowClosed() }
            let a1 = b.openTab(url: URL(string: "https://a1.example/"), activate: false), a2 = b.openTab(url: URL(string: "https://a2.example/"), activate: false)
            let w1 = b.openTab(url: URL(string: "https://w1.example/"), activate: false, space: rig.work.id)
            let w2 = b.openTab(url: URL(string: "https://w2.example/"), activate: false, space: rig.work.id)
            b.switchSpace(to: rig.work.id)
            let workGroup = try #require(b.group([w1.id, w2.id], name: "Mixed"))
            let plan = [TabSorter.Group(name: "Mixed", ids: [a1.id, a2.id, w1.id, w2.id])]
            b.apply(plan, in: Space.defaultID)
            #expect(a1.groupID != nil && a1.groupID == a2.groupID && a1.groupID != workGroup, "a group of the same name in another space isn't joined")
            #expect(w1.groupID == workGroup && w2.groupID == workGroup)
            #expect(b.groups(in: Space.defaultID).count == 1 && b.groups(in: rig.work.id).count == 1)
        }

        // MARK: Profiles' data

        private final class Calls: @unchecked Sendable {
            var ids: [UUID] = []
            var failures: Int
            init(failures: Int) { self.failures = failures }
        }

        @Test func aProfilesDataStaysOnTheListUntilItIsReallyGone() async throws {
            let savedRemover = Profiles.remover, savedDelays = Profiles.delays
            defer { Profiles.remover = savedRemover; Profiles.delays = savedDelays }
            Profiles.delays = [.milliseconds(1), .milliseconds(1), .milliseconds(1)]
            let box = Sandbox()
            let store = box.store()
            let profile = store.add(name: "P", symbol: "key", tint: .coral, isProfile: true)
            let plain = store.add(name: "N", symbol: "leaf", tint: .teal, isProfile: false)
            store.remove(plain.id)
            store.remove(profile.id)
            #expect(store.pendingRemovals == [profile.id], "only a profile's store is ever listed")
            let calls = Calls(failures: 100)
            Profiles.remover = { id in
                calls.ids.append(id)
                if calls.failures > 0 { calls.failures -= 1; throw CocoaError(.fileWriteUnknown) }
            }
            await Profiles.drain(store)
            #expect(store.pendingRemovals == [profile.id] && calls.ids.count == 3, "it gave up for now, and kept it on the list")
            #expect(box.store().pendingRemovals == [profile.id], "and the list is kept across launches")
            calls.failures = 1
            await Profiles.drain(box.store())
            #expect(calls.ids.count == 5 && Set(calls.ids) == [profile.id], "tried again at the next launch, and nothing else was touched")
            let later = box.store()
            #expect(later.pendingRemovals.isEmpty)
            await Profiles.drain(later)
            #expect(calls.ids.count == 5)
        }

        @Test func aDownloadResumesInTheStoreItCameFromAndNeverRecreatesADeletedOne() async throws {
            let box = Sandbox()
            let store = box.store()
            let profile = store.add(name: "P", symbol: "key", tint: .coral, isProfile: true)
            defer { erase(profile.id) }
            let item = DownloadItem(filename: "f", progress: Progress(), isPrivate: false)
            item.space = profile
            #expect(Downloads.resumeConfiguration(for: item, spaces: store).websiteDataStore.identifier == profile.id)
            // The profile is deleted: the default store is used, and the profile's isn't made again.
            let ghost = store.add(name: "G", symbol: "key", tint: .pink, isProfile: true)
            let lost = DownloadItem(filename: "g", progress: Progress(), isPrivate: false)
            lost.space = ghost
            store.remove(ghost.id)
            #expect(Downloads.resumeConfiguration(for: lost, spaces: store) === Browser.configuration)
            #expect(!(await WKWebsiteDataStore.allDataStoreIdentifiers).contains(ghost.id))
            // A private download never has a space and uses its window's own non-persistent configuration.
            let hidden = Browser(isPrivate: true, spaces: store)
            let secret = DownloadItem(filename: "s", progress: Progress(), isPrivate: true)
            secret.owner = hidden
            secret.space = profile
            #expect(Downloads.resumeConfiguration(for: secret, spaces: store) === hidden.configuration && !hidden.configuration.websiteDataStore.isPersistent)
            let tab = hidden.openTab(url: nil, activate: false)
            #expect(Downloads.spaceToKeep(for: tab) == nil)
            let open = Browser(spaces: store)
            #expect(Downloads.spaceToKeep(for: open.openTab(url: nil, activate: false))?.id == open.spaceID)
        }

        // MARK: What the search and the AI may see

        @Test func suggestionsLeaveOutAnotherProfilesFavorites() {
            let box = Sandbox()
            let library = Library(path: box.file("lib.sqlite").path)
            _ = library.toggleBookmark(url: "https://normal.example/", title: "Shared word", in: "\u{1}normal")
            _ = library.toggleBookmark(url: "https://profile.example/", title: "Shared word", in: "\u{1}profile")
            #expect(library.search("shared").count == 2 && library.bookmarks().count == 2)
            #expect(library.search("shared", hiding: ["\u{1}profile"]).map(\.url) == ["https://normal.example/"])
            #expect(library.bookmarks(hiding: ["\u{1}profile"]).map(\.url) == ["https://normal.example/"])
            #expect(library.search("shared", hiding: ["\u{1}other"]).count == 2)
        }

        @Test func theAISeesOrdinarySpacesButOnlyTheProfileShown() async throws {
            let box = Sandbox()
            let store = box.store()
            let work = store.add(name: "Work", symbol: "briefcase", tint: .blue, isProfile: false)
            let bank = store.add(name: "Bank", symbol: "key", tint: .coral, isProfile: true)
            let b = Browser(spaces: store)
            b.focused()
            defer { b.windowClosed(); erase(bank.id) }
            let home = b.openTab(url: URL(string: "https://home.example/"))
            let ordinary = b.openTab(url: URL(string: "https://w.example/"), activate: false, space: work.id)
            let secret = b.openTab(url: URL(string: "https://bank.example/"), activate: false, space: bank.id)
            func listing() async throws -> String {
                try #require(await ToolCatalog.call("list_tabs", [:], caller: "test").content.first?["text"] as? String)
            }
            var text = try await listing()
            #expect(text.contains("#\(ordinary.id) [Work]") && !text.contains("bank.example") && text.contains("#\(home.id) "))
            #expect(ToolCatalog.findTab(ordinary.id) === ordinary && ToolCatalog.findTab(secret.id) == nil)
            b.switchSpace(to: bank.id)
            text = try await listing()
            #expect(text.contains("#\(secret.id) [Bank]") && ToolCatalog.findTab(secret.id) === secret)
            b.switchSpace(to: work.id)
            #expect(ToolCatalog.findTab(secret.id) == nil)
            let hidden = Browser(isPrivate: true, spaces: store)
            #expect(!hidden.isVisibleToAI(hidden.openTab(url: nil, activate: false)))
        }

        // MARK: Switching

        @Test func aSwipeStopsAtTheEndsAndDoesNotOpenTheBarInAnEmptySpace() {
            let rig = Rig(), b = rig.browser
            b.startPageStore = commandBarStore()
            defer { b.windowClosed() }
            _ = b.openTab(url: URL(string: "https://home.example/"))
            b.switchSpace(offset: -1, wraps: false, opensBar: false)
            #expect(b.spaceID == Space.defaultID, "no way round from the first space")
            b.switchSpace(offset: 1, wraps: false, opensBar: false)
            #expect(b.spaceID == rig.work.id && b.activeID == nil && b.commandBar == nil, "empty, and the keyboard stays where it was")
            b.switchSpace(offset: 1, wraps: false, opensBar: false)
            #expect(b.spaceID == rig.work.id, "nor from the last")
            b.switchSpace(offset: 1)
            #expect(b.spaceID == Space.defaultID && b.commandBar == nil, "a menu command goes round")
            b.switchSpace(to: rig.work.id)
            #expect(b.commandBar == .newTab, "a click or a key opens the bar in an empty space")
        }

        @Test func aWindowKeepsItsOwnSwipe() {
            let rig = Rig(), a = rig.browser
            let b = Browser(spaces: rig.store)
            defer { a.windowClosed() }
            _ = a.swipe.scrolled(dx: -40, dy: 0, began: true, ended: false)
            #expect(a.swipe.travelled == -40 && b.swipe.travelled == 0)
            #expect(b.swipe.scrolled(dx: -30, dy: 0, began: false, ended: false) == nil && a.swipe.travelled == -40)
        }

        @Test func aWindowRestoredIntoAnEmptySpaceOpensTheBar() throws {
            let rig = Rig()
            let json = #"{"tabs":[{"url":"https://a.example/","title":"A","space":"\#(Space.defaultID)"}],"active":0,"space":"\#(rig.work.id)"}"#
            let b = Browser(spaces: rig.store)
            b.startPageStore = commandBarStore()
            b.restore(try #require(Browser.SavedWindows.decode(Data(json.utf8)).first))
            #expect(b.spaceID == rig.work.id && b.activeID == nil && b.commandBar == .newTab)
            b.windowClosed()
            rig.browser.windowClosed()
        }

        @Test func eachSpaceKeepsItsOwnSplit() {
            let rig = Rig(), b = rig.browser
            defer { b.windowClosed() }
            let a1 = b.openTab(url: URL(string: "https://a1.example/")), a2 = b.openTab(url: URL(string: "https://a2.example/"), activate: false)
            let w1 = b.openTab(url: URL(string: "https://w1.example/"), space: rig.work.id), w2 = b.openTab(url: URL(string: "https://w2.example/"), activate: false, space: rig.work.id)
            b.activate(a1.id)
            b.split(with: a2.id)
            b.switchSpace(to: rig.work.id)
            #expect(b.split == nil)
            b.split(with: w2.id)
            #expect(b.split == Browser.Split(left: w1.id, right: w2.id))
            b.switchSpace(to: Space.defaultID)
            #expect(b.split == Browser.Split(left: a1.id, right: a2.id), "the other space's split wasn't lost")
            b.close(a2.id)
            #expect(b.split == nil)
            b.switchSpace(to: rig.work.id)
            #expect(b.split == Browser.Split(left: w1.id, right: w2.id))
        }

        @Test func aNewWindowFromAPrivateOneStartsWhereTheLastSpaceWas() {
            let rig = Rig(), b = rig.browser
            b.switchSpace(to: rig.work.id)
            b.windowClosed()
            let hidden = Browser(isPrivate: true, spaces: rig.store)
            hidden.focused()
            defer { hidden.windowClosed() }
            #expect(hidden.spaceID == Space.defaultID && rig.store.lastActive == rig.work.id)
            #expect(Browser(spaces: rig.store).spaceID == rig.work.id)
        }
    }
}
