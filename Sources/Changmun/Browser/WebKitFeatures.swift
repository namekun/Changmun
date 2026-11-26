import Foundation
import WebKit

/// WebKit's feature flags (`WKPreferences._features`), private: set by key when this WebKit has the flag, left alone when it doesn't.
enum WebKitFeatures {
    /// WebKit stops the network requests of scripts it takes for trackers. Naver's sign-in page sends what its bot check found through
    /// such a script; with that request stopped, Naver takes the sign-in for a bot's and drops it the moment www.naver.com loads (the
    /// cookies NID_AUT and NID_SES are gone within a second, every time). Off in ordinary windows, as Safari has it outside Private
    /// Browsing; the ad and tracker lists still stop requests to trackers, and WebKit still limits what such scripts can read.
    static let trackerRequestBlocking = "ScriptTrackingPrivacyNetworkRequestBlockingEnabled"

    private typealias Set = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
    private typealias Get = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    private static let setSelector = NSSelectorFromString("_setEnabled:forFeature:")
    private static let getSelector = NSSelectorFromString("_isEnabledForFeature:")

    private static func feature(_ key: String) -> NSObject? {
        let all = (WKPreferences.self as AnyObject).perform(NSSelectorFromString("_features"))?.takeUnretainedValue() as? [NSObject]
        return all?.first { $0.value(forKey: "key") as? String == key }
    }

    /// Whether it was set: false when this WebKit has no such flag.
    @discardableResult
    static func set(_ key: String, _ enabled: Bool, in preferences: WKPreferences) -> Bool {
        guard preferences.responds(to: setSelector), let feature = feature(key) else { return false }
        unsafeBitCast(preferences.method(for: setSelector), to: Set.self)(preferences, setSelector, enabled, feature)
        return true
    }

    /// Nil when this WebKit has no such flag.
    static func isEnabled(_ key: String, in preferences: WKPreferences) -> Bool? {
        guard preferences.responds(to: getSelector), let feature = feature(key) else { return nil }
        return unsafeBitCast(preferences.method(for: getSelector), to: Get.self)(preferences, getSelector, feature)
    }
}
