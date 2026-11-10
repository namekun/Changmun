import Foundation
import Testing
import WebKit
@testable import Changmun

/// What an extension's permission question shows is all that Allow grants: every entry whole, broad ones first, and when something cannot be shown the
/// question counts it and has no Allow.
@MainActor
struct ExtensionPromptTests {
    private func allows(_ spec: DialogSpec) -> Bool { spec.buttons.contains { $0.role == .normal } }

    private func shownText(_ spec: DialogSpec) -> String {
        guard case .text(let text)? = spec.detail else { return "" }
        return text
    }

    @Test func everythingTheQuestionGrantsIsInTheBox() {
        let hosts = (0..<40).map { "https://site\($0).example/*" } + ["<all_urls>", "*://*.com/*"]
        let spec = ExtensionPrompt.permissionsSpec(name: "X", hosts: hosts, permissions: ["tabs", "storage"], updating: false)
        #expect(allows(spec))
        for host in hosts { #expect(shownText(spec).contains(host), "\(host) is granted, so it is shown") }
        #expect(shownText(spec).contains(String(localized: "See the tabs you have open")) && shownText(spec).contains(String(localized: "Keep its own data on this Mac")))
        #expect(spec.message == String(localized: "It can read and change the content of all websites."))
    }

    @Test func broadPatternsComeFirst() {
        let spec = ExtensionPrompt.askSpec("t", items: ["https://a.example/*", "*://*.com/*", "https://*/*", "https://b.example/*"])
        let lines = shownText(spec).split(separator: "\n").map(String.init)
        #expect(lines.prefix(2).sorted() == ["*://*.com/*", "https://*/*"])
        #expect(ExtensionPrompt.isBroad("<all_urls>") && ExtensionPrompt.isBroad("*://*.com/*") && !ExtensionPrompt.isBroad("https://*.example.com/*"))
    }

    @Test func whatCannotBeShownWholeIsCountedAndThereIsNoAllow() {
        let many = (0..<(ExtensionPrompt.maxItems + 25)).map { "https://site\($0).example/*" }
        let spec = ExtensionPrompt.askSpec("t", items: many)
        #expect(!allows(spec), "too many entries to show: nothing to allow")
        #expect(spec.message?.contains("25") == true, "the count of what is left out is said: \(spec.message ?? "")")
        let long = ExtensionPrompt.askSpec("t", items: ["https://example.com/" + String(repeating: "a", count: ExtensionPrompt.itemLimit + 10)])
        #expect(!allows(long), "an entry that is cut is not granted")
        let update = ExtensionPrompt.permissionsSpec(name: "X", hosts: many, permissions: [], updating: true)
        #expect(!allows(update) && update.buttons.count == 1 && update.buttons[0].role == .cancel)
        #expect(update.button(for: .return) == 0)
    }

    @Test func theGrantedSetNeverExceedsWhatIsShown() {
        for count in [0, 1, 5, ExtensionPrompt.maxItems, ExtensionPrompt.maxItems + 1, 600] {
            let items = (0..<count).map { "https://s\($0).example/*" }
            let spec = ExtensionPrompt.askSpec("t", items: items)
            guard allows(spec) else { #expect(count > ExtensionPrompt.maxItems); continue }
            let shown = Set(shownText(spec).split(separator: "\n").map(String.init))
            #expect(Set(items).isSubset(of: shown), "\(count) entries: Allow is only there when all are shown")
        }
        // The same count of characters in the whole box.
        let wide = (0..<200).map { "https://" + String(repeating: "w", count: 100) + "\($0).example/*" }
        let spec = ExtensionPrompt.askSpec("t", items: wide)
        let shown = Set(shownText(spec).split(separator: "\n").map(String.init))
        #expect(!allows(spec) ? true : Set(wide).isSubset(of: shown))
    }

    @Test func aNoticeThatSaysNothingIsStillSafe() {
        let spec = ExtensionPrompt.askSpec("t", items: [])
        #expect(spec.detail == nil && allows(spec) && spec.button(for: .return) == 0)
    }

    @Test func permissionsAreSaidInWordsAndWhatIsNotKnownKeepsItsId() {
        let spec = ExtensionPrompt.permissionsSpec(name: "X", hosts: ["https://a.example/*"], permissions: ["tabs", "webRequest", "declarativeNetRequest", "somethingNew"], updating: false)
        let text = shownText(spec)
        #expect(text.contains(String(localized: "See the tabs you have open")))
        #expect(text.components(separatedBy: String(localized: "See and change what pages load")).count == 2, "two ids that say the same are said once")
        #expect(text.contains("somethingNew"), "an id with no words is shown as it is, so nothing granted is left unsaid")
        #expect(!text.contains("declarativeNetRequest") && !text.contains("webRequest"))
        #expect(text.contains("https://a.example/*"), "a match pattern is shown whole")
        #expect(ExtensionPrompt.words(for: "nativeMessaging") == String(localized: "Talk to other apps on this Mac"))
        #expect(ExtensionPrompt.words(for: "https://*/*") == "https://*/*")
    }

    @Test func theQuestionWhileItRunsOffersAddAndTheSafeDontAdd() {
        let spec = ExtensionPrompt.askSpec("t", items: ["https://a.example/*"])
        #expect(spec.buttons.map(\.title) == [String(localized: "Don’t Add"), String(localized: "Add")])
        #expect(spec.button(for: .return) == 0 && spec.button(for: .escape) == 0, "Return and Esc both give the safe answer")
    }

    @available(macOS 15.4, *)
    @Test func anExtensionWebKitDoesNotSupportSaysSoBeforeTheSystemsText() {
        let unsupported = NSError(domain: WKWebExtension.errorDomain, code: WKWebExtension.Error.Code.unsupportedManifestVersion.rawValue,
                                  userInfo: [NSLocalizedDescriptionKey: "Manifest version 1 is not supported."])
        let text = ExtensionHost.failureText(unsupported)
        #expect(text == String(localized: "WebKit, which Changmun uses, does not support this extension. Manifest version 1 is not supported."))
        let other = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSLocalizedDescriptionKey: "No such file."])
        #expect(ExtensionHost.failureText(other) == "No such file.", "other failures are the system's own words")
        let broken = NSError(domain: WKWebExtension.errorDomain, code: WKWebExtension.Error.Code.resourceNotFound.rawValue, userInfo: [NSLocalizedDescriptionKey: "Missing."])
        #expect(ExtensionHost.failureText(broken) == "Missing.", "a missing file is not WebKit refusing the extension")
    }
}
