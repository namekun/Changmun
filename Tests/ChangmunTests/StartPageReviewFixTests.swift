import AppKit
import Foundation
import Testing
@testable import Changmun

private func tempFolder(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
}

private func suiteDefaults() -> UserDefaults {
    let name = "StartReviewFix-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: Private windows and history

@MainActor
struct StartPageHistoryReachTests {
    @Test func aSearchWithoutHistoryFindsBookmarksOnly() {
        let library = Library(path: FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString).sqlite").path)
        library.recordVisit(url: "https://gitlab.example/secret-visit", title: "git visited")
        library.addBookmark(url: "https://github.example/kept", title: "git bookmark", folder: "Favorites")
        #expect(Set(library.search("git").map(\.url)) == ["https://gitlab.example/secret-visit", "https://github.example/kept"])
        #expect(library.search("git", history: false).map(\.url) == ["https://github.example/kept"], "a private window's suggestions name no visited page")
    }

    @Test func clearingHistoryForgetsTheTabsClosedInTheRange() {
        let b = Browser(spaces: Sandbox().store())
        let now = Date()
        func closed(_ title: String, ago: TimeInterval) -> Browser.ClosedTab {
            Browser.ClosedTab(url: URL(string: "https://\(title).example/"), title: title, index: 0, space: b.spaceID, closedAt: now.addingTimeInterval(-ago))
        }
        b.closedTabs = [closed("old", ago: 86_400 * 3), closed("earlier", ago: 7200), closed("recent", ago: 600)]
        b.removeClosedTabs(since: now.addingTimeInterval(-3600))
        #expect(b.closedTabs.map(\.title) == ["old", "earlier"])
        b.removeClosedTabs(since: .distantPast)
        #expect(b.closedTabs.isEmpty, "all time takes them all")
    }

    @Test func customizeInAPrivateWindowOpensSettingsAndDoesNotPostToThePopover() {
        let before = UserDefaults.standard.object(forKey: "settingsPage")
        defer { if let before { UserDefaults.standard.set(before, forKey: "settingsPage") } else { UserDefaults.standard.removeObject(forKey: "settingsPage") } }
        let hidden = Browser(isPrivate: true, spaces: Sandbox().store())
        let normal = Browser(spaces: Sandbox().store())
        var posted: [Browser] = []
        let token = NotificationCenter.default.addObserver(forName: StartPageUI.customizeRequested, object: nil, queue: nil) { note in
            MainActor.assumeIsolated { if let browser = note.object as? Browser { posted.append(browser) } }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        for browser in [hidden, normal] { StartPageUI.appeared(in: browser) }
        defer { for browser in [hidden, normal] { StartPageUI.disappeared(from: browser) } }
        StartPageUI.customize(hidden)
        #expect(posted.isEmpty && UserDefaults.standard.string(forKey: "settingsPage") == SettingsPage.startPage.rawValue)
        StartPageUI.customize(normal)
        #expect(posted.count == 1 && posted.first === normal, "a window with a pill still gets the popover")
    }
}

// MARK: Settings read leniently

@MainActor
struct StartPageLenientSettingsTests {
    private func decode(_ json: String) throws -> StartPageSettings {
        try JSONDecoder().decode(StartPageSettings.self, from: Data(json.utf8))
    }

    private final class Place {
        let root = tempFolder("start-fix")
        var folder: URL { root.appendingPathComponent("StartPage", isDirectory: true) }
        init() { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }
        func put(_ name: String) { try! Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        var copies: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
    }

    @Test func missingKeysTakeTheirDefaultsAndKeepTheRest() throws {
        #expect(try decode("{}") == .default)
        let partial = try decode(#"{"style":"quiet","background":{"kind":"color"}}"#)
        #expect(partial.style == .quiet && partial.newTab == .startPage && partial.dashboard == StartPageSettings.defaultLayout(.dashboard))
        #expect(partial.background.kind == .color && partial.background.colorID == "slate" && partial.background.dim == 0.4)
    }

    @Test func anUnknownValueTakesBackOnlyItsOwnDefault() throws {
        let read = try decode(#"{"style":"hologram","newTab":"commandBar","address":5,"background":{"kind":"future","imageFile":"background-a.jpg","blur":0.5}}"#)
        #expect(read.style == .dashboard && read.newTab == .commandBar && read.address == "")
        #expect(read.background.kind == .spaceGlow && read.background.imageFile == "background-a.jpg" && read.background.blur == 0.5)
    }

    @Test func anUnknownSectionIsLeftOutAndTheOthersStay() throws {
        let read = try decode(#"{"dashboard":{"items":[{"section":"weather","enabled":true},{"section":"favorites","enabled":true,"option":1},{"enabled":true}]}}"#)
        #expect(read.dashboard.items == [StartItem(section: .favorites, enabled: true, option: 1)])
        #expect(read.normalized().dashboard.items.count == StartSection.allCases.count, "the others come back off")
    }

    @Test func whatIsWrittenIsReadBack() throws {
        var settings = StartPageSettings.default
        settings.style = .aiFirst
        settings.newTab = .address
        settings.address = "example.com"
        settings.background = StartBackground(kind: .image, imageFile: "background-z.jpg", blur: 0.2, dim: 0.9)
        #expect(try JSONDecoder().decode(StartPageSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func settingsThatCannotBeReadLeaveThePictureAlone() async {
        let unreadable: [Any] = [Data(#"{"style":"qui"#.utf8), Data("[1,2]".utf8), "not data"]
        for stored in unreadable {
            let place = Place()
            place.put("background-keep.jpg")
            let defaults = suiteDefaults()
            defaults.set(stored, forKey: StartPageStore.defaultsKey)
            let store = StartPageStore(defaults: defaults, folder: place.folder)
            #expect(store.settings == .default)
            await store.removeOrphanedImages()
            #expect(place.copies == ["background-keep.jpg"], "\(stored)")
        }
    }

    @Test func settingsMissingKeysKeepTheirPictureAndAnUnusedOneStillGoes() async {
        let place = Place()
        place.put("background-keep.jpg")
        place.put("background-old.jpg")
        let defaults = suiteDefaults()
        defaults.set(Data(#"{"newTab":"future","background":{"kind":"image","imageFile":"background-keep.jpg"}}"#.utf8), forKey: StartPageStore.defaultsKey)
        let store = StartPageStore(defaults: defaults, folder: place.folder)
        #expect(store.settings.background.imageFile == "background-keep.jpg" && store.settings.background.kind == .image)
        await store.removeOrphanedImages()
        #expect(place.copies == ["background-keep.jpg"])
    }

    @Test func aPictureChosenWhileTheFolderWasScannedIsNotDeleted() {
        let place = Place()
        place.put("background-new.jpg")
        place.put("background-old.jpg")
        let store = StartPageStore(defaults: suiteDefaults(), folder: place.folder)
        let found = StartPageImage.orphans(in: place.folder, keeping: [])
        #expect(found.sorted() == ["background-new.jpg", "background-old.jpg"])
        store.setBackground(StartBackground(kind: .image, imageFile: "background-new.jpg"))
        store.removeOrphanedCopies(found)
        #expect(place.copies == ["background-new.jpg"])
    }
}

// MARK: New tab address

struct StartAddressCheckTests {
    @Test func aUserNameAndPasswordMakeNoAddress() {
        for typed in ["https://user:pw@example.com/", "http://user@example.com", "user@example.com", "user:pw@example.com"] {
            #expect(StartAddressCheck.check(typed) == .invalid, Comment(rawValue: typed))
        }
        #expect(StartAddressCheck.check("http://example.com/?mail=a@b.com") == .insecure(URL(string: "http://example.com/?mail=a@b.com")!), "an @ after the host is not a login")
    }

    @Test func aLongTextMakesNoAddress() {
        let room = StartAddressCheck.maxLength - "example.com/".count
        #expect(StartAddressCheck.check("example.com/" + String(repeating: "a", count: room)).url != nil)
        #expect(StartAddressCheck.check("example.com/" + String(repeating: "a", count: room + 1)) == .invalid)
    }

    @Test func aSchemeIsOnlyOneBeforeThePathQueryOrFragment() {
        #expect(StartAddressCheck.check("example.com/?u=http://x") == .ok(URL(string: "https://example.com/?u=http://x")!))
        #expect(StartAddressCheck.check("example.com#http://x") == .ok(URL(string: "https://example.com#http://x")!))
        #expect(StartAddressCheck.check("example.com/a://b") == .ok(URL(string: "https://example.com/a://b")!))
        #expect(StartAddressCheck.check("http://example.com/?u=https://x") == .insecure(URL(string: "http://example.com/?u=https://x")!))
        #expect(StartAddressCheck.check("ftp://example.com") == .invalid)
    }
}

// MARK: Hidden list

@MainActor
struct StartHiddenListLoadTests {
    @Test func aStoredListLongerThanTheLimitIsCutToTheNewestOnLoad() throws {
        var list = StartHiddenList.fresh()
        list.hashes = (0..<(StartHiddenList.limit + 20)).map { "h\($0)" }
        let defaults = suiteDefaults()
        defaults.set(try JSONEncoder().encode(list), forKey: StartHiddenItems.defaultsKey)
        let hidden = StartHiddenItems(defaults: defaults)
        #expect(hidden.count == StartHiddenList.limit && hidden.list?.hashes.first == "h20" && hidden.list?.hashes.last == "h519")
        #expect(hidden.list?.salt == list.salt)
    }
}

// MARK: The AI's navigate

extension SharedAgentState {
    @MainActor @Suite(.serialized)
    struct StartTabNavigateTests {
        @Test func aRefusedNavigateLeavesAStartTabWithoutAWebView() async {
            let b = Browser(spaces: Sandbox().store())
            b.focused()
            defer { b.windowClosed() }
            b.openNewTab()
            let tab = b.active!
            #expect(tab.isStart && tab.webView == nil)
            let before = Preferences.shared.aiApprovalMode
            Preferences.shared.aiApprovalMode = .afterReading
            defer { Preferences.shared.aiApprovalMode = before }
            let stand = Approvals.Stand { _ in .deny }
            let result = await Approvals.$stand.withValue(stand) {
                await ToolCatalog.call("navigate", ["tab_id": tab.id, "url": "https://never-visited.example/page?x=1"], caller: "start-navigate-test")
            }
            #expect(!stand.asked.isEmpty, "the address was asked about")
            #expect(tab.webView == nil && tab.isStart && tab.url == nil, "nothing was opened, so nothing is left woken")
            #expect(result.isError && String(describing: result.content).contains("declined"))
        }
    }
}
