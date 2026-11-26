import Foundation
import Testing
import WebKit
@testable import Changmun

/// WebKit's own feature flags as the browser sets them.
@MainActor
struct WebKitFeaturesTests {
    /// Naver drops a sign-in whose bot check WebKit stopped as a tracker's request: ordinary windows let such requests through (the ad and
    /// tracker lists still stop trackers), private windows keep WebKit's protection.
    @Test func trackerRequestsAreLetThroughInOrdinaryWindowsOnly() throws {
        let key = WebKitFeatures.trackerRequestBlocking
        let untouched = WKWebViewConfiguration().preferences
        try #require(WebKitFeatures.isEnabled(key, in: untouched) != nil, "this WebKit has the flag")
        let ordinary = Browser.makeConfiguration(store: .default(), extensions: false)
        let `private` = Browser.makeConfiguration(store: .nonPersistent(), extensions: false)
        #expect(WebKitFeatures.isEnabled(key, in: ordinary.preferences) == false)
        #expect(WebKitFeatures.isEnabled(key, in: `private`.preferences) == WebKitFeatures.isEnabled(key, in: untouched), "WebKit's own setting")
    }

    @Test func aFlagThisWebKitDoesNotHaveIsLeftAlone() {
        let preferences = WKPreferences()
        #expect(!WebKitFeatures.set("NoSuchFeatureAnywhere", true, in: preferences))
        #expect(WebKitFeatures.isEnabled("NoSuchFeatureAnywhere", in: preferences) == nil)
    }
}
