import Foundation
import Testing
@testable import Changmun

/// The notices a page waits on the user for: listed as rows of one popover from the dot at the left of the address.
extension SharedAgentState {
    @MainActor @Suite(.serialized)
    struct NoticeTests {
        @Test func twoNoticesAreTwoRowsAndClearingOneLeavesTheOther() throws {
            let b = Browser()
            defer { b.windowClosed() }
            let tab = b.openTab(url: URL(string: "https://accounts.example.com/"))
            #expect(tab.notices.isEmpty, "nothing pending: no dot")
            tab.loginOffer = LoginOffer(host: "accounts.example.com", username: "me", password: "x")
            tab.popupBlocked(try #require(URL(string: "https://ads.example/")))
            #expect(tab.notices == [.login, .popup])
            #expect(NoticesButton.label(tab.notices.count) == String(localized: "2 notices"))
            tab.loginOffer = nil
            #expect(tab.notices == [.popup], "the pop-up's row stays")
            #expect(tab.blockedPopup?.absoluteString == "https://ads.example/")
            #expect(NoticesButton.label(tab.notices.count) == String(localized: "1 notice"))
            tab.blockedPopup = nil
            #expect(tab.notices.isEmpty)
        }
    }
}
