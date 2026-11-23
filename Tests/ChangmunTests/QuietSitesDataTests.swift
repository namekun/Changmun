import Foundation
import Testing
import WebKit
@testable import Changmun

@MainActor
struct QuietSitesDataTests {
    @Test func theFlagIsRegisteredWithoutBeingWritten() {
        let suite = "QuietSitesDataTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        Browser.keepQuietSitesData(in: defaults)
        #expect(defaults.bool(forKey: Browser.keepsQuietSitesDataKey))
        #expect(defaults.persistentDomain(forName: suite) == nil, "registered, so nothing lands in a preferences file")
    }

    @Test func webKitStillHasTheFeatureTheKeyNames() throws {
        // WebKit looks the flag up as "WebKitExperimental" + the feature's key: a feature renamed in a later WebKit would leave the key unread.
        let selector = NSSelectorFromString("_features")
        try #require(WKPreferences.responds(to: selector))
        let features = (WKPreferences.self as AnyObject).perform(selector)?.takeUnretainedValue() as? [NSObject] ?? []
        let keys = features.compactMap { $0.value(forKey: "key") as? String }
        #expect(keys.contains(String(Browser.keepsQuietSitesDataKey.dropFirst("WebKitExperimental".count))))
    }

    @Test func trackingPreventionStaysOnForTheDefaultStore() throws {
        // Only the erasing is turned off: tracking prevention, which blocks third-party cookies, is still on for the store the windows use.
        let config = Browser.makeConfiguration(store: .default(), extensions: false)
        try #require(config.websiteDataStore.responds(to: NSSelectorFromString("_resourceLoadStatisticsEnabled")))
        #expect(config.websiteDataStore.isPersistent)
        #expect(config.websiteDataStore.value(forKey: "resourceLoadStatisticsEnabled") as? Bool == true)
    }
}
