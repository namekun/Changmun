import Foundation
import Testing
@testable import Changmun

struct StartPageSettingsTests {
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

    @MainActor @Test func theStoreSavesWhereNewTabsGo() {
        let suite = UserDefaults(suiteName: "start-page-tests-\(UUID().uuidString)")!
        let store = StartPageStore(defaults: suite)
        store.setNewTab(.address)
        store.setAddress("https://example.com/")
        #expect(StartPageStore(defaults: suite).settings == store.settings, "a new store reads what was saved")
    }

    @MainActor @Test func aNewTabCanBeChosenButNeverAnUnknownValueFromAFile() {
        let suite = UserDefaults(suiteName: "start-page-tests-\(UUID().uuidString)")!
        suite.set(Data("not json".utf8), forKey: StartPageStore.defaultsKey)
        #expect(StartPageStore(defaults: suite).settings == .default)
    }
}
