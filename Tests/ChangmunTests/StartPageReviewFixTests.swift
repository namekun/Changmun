import AppKit
import Foundation
import Testing
@testable import Changmun

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
}

// MARK: Settings read leniently

@MainActor
struct StartPageLenientSettingsTests {
    private func decode(_ json: String) throws -> StartPageSettings {
        try JSONDecoder().decode(StartPageSettings.self, from: Data(json.utf8))
    }

    @Test func missingKeysTakeTheirDefaults() throws {
        #expect(try decode("{}") == .default)
        #expect(try decode(#"{"address":"https://example.com/"}"#).newTab == .startPage)
    }

    @Test func whatAnOlderVersionStoredOfTheStylesSectionsAndBackgroundIsNotRead() throws {
        let read = try decode(#"{"style":"quiet","dashboard":{"items":[{"section":"frequent","enabled":true}]},"background":{"kind":"image","imageFile":"background-a.jpg"},"newTab":"blank"}"#)
        #expect(read == StartPageSettings(newTab: .blank, address: ""))
        let written = try #require(String(data: JSONEncoder().encode(read), encoding: .utf8))
        #expect(!written.contains("style") && !written.contains("background"), "and is not written back")
    }

    @Test func anUnknownValueTakesBackOnlyItsOwnDefault() throws {
        let read = try decode(#"{"newTab":"commandBar","address":5}"#)
        #expect(read.newTab == .commandBar && read.address == "")
        #expect(try decode(#"{"newTab":"hologram","address":"example.com"}"#) == StartPageSettings(newTab: .startPage, address: "example.com"))
    }

    @Test func whatIsWrittenIsReadBack() throws {
        let settings = StartPageSettings(newTab: .address, address: "example.com")
        #expect(try JSONDecoder().decode(StartPageSettings.self, from: JSONEncoder().encode(settings)) == settings)
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
