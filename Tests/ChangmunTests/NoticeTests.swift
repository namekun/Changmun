import Foundation
import Testing
@testable import Changmun

/// The notices a page waits on the user for: named in words at the left of the address, and listed as rows of the popover it opens.
extension SharedAgentState {
    @MainActor @Suite(.serialized)
    struct NoticeTests {
        @Test func twoNoticesAreTwoRowsAndClearingOneLeavesTheOther() throws {
            let b = Browser()
            defer { b.windowClosed() }
            let tab = b.openTab(url: URL(string: "https://accounts.example.com/"))
            #expect(tab.notices.isEmpty, "nothing pending: nothing at the left of the address")
            tab.loginOffer = LoginOffer(host: "accounts.example.com", username: "me", password: "x")
            tab.popupBlocked(try #require(URL(string: "https://ads.example/")))
            #expect(tab.notices == [.login, .popup])
            #expect(NoticesButton.title(tab.notices).text == String(localized: "2 notices"), "two say how many")
            tab.loginOffer = nil
            #expect(tab.notices == [.popup], "the pop-up's row stays")
            #expect(tab.blockedPopup?.absoluteString == "https://ads.example/")
            #expect(NoticesButton.title(tab.notices).text == String(localized: "Pop-up Blocked"), "one says what it is")
            #expect(NoticesButton.title([.login]).text == String(localized: "Save Password?"))
            tab.blockedPopup = nil
            #expect(tab.notices.isEmpty)
        }

        @Test func aWebStoreNoticeCanBePutAwayAndComesBackOnAnotherExtension() throws {
            guard #available(macOS 15.4, *) else { return }
            let b = Browser()
            defer { b.windowClosed() }
            let id = String(repeating: "a", count: 32), other = String(repeating: "b", count: 32)
            let tab = b.openTab(url: URL(string: "https://chromewebstore.google.com/detail/dark-reader/\(id)"))
            #expect(tab.notices == [.webStore(id)])
            tab.dismissedStoreNotices.insert(id)
            #expect(tab.notices.isEmpty, "× puts it away")
            tab.url = URL(string: "https://chromewebstore.google.com/detail/other/\(other)")
            #expect(tab.notices == [.webStore(other)], "another extension's page asks again")
        }
    }
}
