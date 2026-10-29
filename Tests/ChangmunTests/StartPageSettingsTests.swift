import Foundation
import Testing
@testable import Changmun

struct StartPageSettingsTests {
    @Test func everyStyleStartsWithItsOwnSections() {
        let dashboard = StartPageSettings.defaultLayout(.dashboard)
        #expect(dashboard.shown.map(\.section) == [.aiSuggestions, .favorites, .continueViewing, .readingList])
        #expect(StartPageSettings.defaultLayout(.quiet).shown.map(\.section) == [.favorites])
        #expect(StartPageSettings.defaultLayout(.aiFirst).shown.map(\.section) == [.aiSuggestions, .favorites])
        for style in StartStyle.allCases { #expect(Set(StartPageSettings.defaultLayout(style).items.map(\.section)) == Set(StartSection.allCases)) }
    }

    @Test func movingKeepsEverySectionOnce() {
        let layout = StartPageSettings.defaultLayout(.dashboard)
        let moved = layout.moving(.readingList, to: 0)
        #expect(moved.items.first?.section == .readingList)
        #expect(Set(moved.items.map(\.section)).count == StartSection.allCases.count)
        #expect(layout.moving(.favorites, by: -1).items.first?.section == .favorites)
        #expect(layout.moving(.favorites, by: 1).items[2].section == .favorites)
        #expect(layout.moving(.aiSuggestions, by: -1) == layout, "the top one stays on top")
        #expect(layout.moving(.frequent, by: 5) == layout, "the bottom one stays at the bottom")
        #expect(layout.moving(.frequent, to: -4).items.first?.section == .frequent)
    }

    @Test func aStyleRemembersItsOwnSections() {
        var settings = StartPageSettings.default
        settings = settings.with(layout: settings.current.toggled(.frequent), for: .dashboard)
        #expect(settings.dashboard.item(.frequent)?.enabled == true)
        settings.style = .quiet
        #expect(settings.current.item(.frequent)?.enabled == false)
        settings.style = .dashboard
        #expect(settings.current.item(.frequent)?.enabled == true)
    }

    @Test func aDamagedLayoutIsMadeWhole() {
        let damaged = StartLayout(items: [StartItem(section: .readingList, enabled: true), StartItem(section: .readingList, enabled: false)])
        let whole = damaged.normalized()
        #expect(whole.items.count == StartSection.allCases.count)
        #expect(whole.items.first == StartItem(section: .readingList, enabled: true), "the first of a repeated section wins")
        #expect(whole.items.dropFirst().allSatisfy { !$0.enabled })
    }

    @Test func backgroundValuesStayInRangeAndAPictureNeedsAFile() {
        let wild = StartBackground(kind: .image, imageFile: nil, blur: 7, dim: -2).clamped()
        #expect(wild.blur == 1 && wild.dim == 0)
        #expect(wild.kind == .spaceGlow, "no picture file, no picture background")
        #expect(StartBackground(kind: .image, imageFile: "bg.jpg").clamped().kind == .image)
    }

    @Test func theAddressOfANewTabIsChecked() {
        #expect(StartAddressCheck.check("  ") == .empty)
        #expect(StartAddressCheck.check("two words.com") == .invalid)
        #expect(StartAddressCheck.check("ftp://example.com") == .invalid)
        #expect(StartAddressCheck.check("nodots") == .invalid)
        #expect(StartAddressCheck.check("example.com") == .ok(URL(string: "https://example.com")!))
        #expect(StartAddressCheck.check("http://example.com/start") == .insecure(URL(string: "http://example.com/start")!))
        #expect(StartAddressCheck.check("localhost") != .invalid)
        #expect(StartAddressCheck.check("javascript:alert(1)") == .invalid)
        #expect(StartAddressCheck.check("https://") == .invalid)
    }

    @Test func imageFileNamesCannotLeaveTheFolder() {
        #expect(StartPageFiles.imageURL(nil) == nil)
        #expect(StartPageFiles.imageURL("../secret") == nil)
        #expect(StartPageFiles.imageURL(".hidden") == nil)
        #expect(StartPageFiles.imageURL("a/b.jpg") == nil)
        #expect(StartPageFiles.imageURL("bg.jpg")?.lastPathComponent == "bg.jpg")
    }

    @MainActor @Test func theStoreSavesChangesAndResetsWithUndo() {
        let suite = UserDefaults(suiteName: "start-page-tests-\(UUID().uuidString)")!
        let store = StartPageStore(defaults: suite)
        store.setStyle(.quiet)
        store.toggle(.readingList)
        store.move(.readingList, to: 0)
        store.setNewTab(.commandBar)
        #expect(StartPageStore(defaults: suite).settings == store.settings, "a new store reads what was saved")
        let before = store.reset()
        #expect(store.settings == .default)
        #expect(before.style == .quiet)
        store.restore(before)
        #expect(store.settings.style == .quiet && store.settings.newTab == .commandBar)
    }

    @MainActor @Test func aNewTabCanBeChosenButNeverAnUnknownValueFromAFile() {
        let suite = UserDefaults(suiteName: "start-page-tests-\(UUID().uuidString)")!
        suite.set(Data("not json".utf8), forKey: StartPageStore.defaultsKey)
        #expect(StartPageStore(defaults: suite).settings == .default)
    }
}
