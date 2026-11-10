import Foundation
import Testing
import WebKit
@testable import Changmun

/// What the address says about the page in words, and what the find bar starts from.
@MainActor
struct AddressPillTests {
    private func name(_ address: String?) -> String? { AddressPill.shownName(for: address.flatMap(URL.init(string:))) }

    @Test func thePillNamesWebPagesByTheirSiteFilesByTheirNameAndDataPagesInAWord() {
        #expect(name("https://www.example.com/a/b") == DisplayHost.trimmed("www.example.com"))
        #expect(name("http://example.com/") == DisplayHost.trimmed("example.com"))
        #expect(name("file:///Users/me/Notes/Trip%20plan.pdf") == "Trip plan.pdf", "a file reads as its name, not as 'Enter Address'")
        #expect(name("data:text/html,<p>hi</p>") == String(localized: "Data Page"))
        #expect(name(nil) == nil, "no address: the pill asks for one")
    }

    @Test func onlyAnHttpPageIsCalledNotSecure() {
        func insecure(_ address: String) -> Bool { AddressPill.isNotSecure(URL(string: address)) }
        #expect(insecure("http://example.com/"))
        #expect(insecure("HTTP://example.com/"))
        #expect(!insecure("https://example.com/"))
        #expect(!insecure("file:///Users/me/a.html"), "a local file is not on the network")
        #expect(!insecure("data:text/html,hi"))
        #expect(!AddressPill.isNotSecure(nil))
    }

    @Test func pasteAndGoNeedsTextThatMakesAnAddressOrASearch() {
        #expect(AddressPill.pastedAddress("example.com/page")?.absoluteString == "https://example.com/page")
        #expect(AddressPill.pastedAddress("  https://a.example/x \n")?.absoluteString == "https://a.example/x")
        #expect(AddressPill.pastedAddress("best ramen")?.host() == AddressInput.searchURL("best ramen")?.host())
        #expect(AddressPill.pastedAddress("   ") == nil)
        #expect(AddressPill.pastedAddress("") == nil)
        #expect(AddressPill.pastedAddress(nil) == nil, "an empty pasteboard leaves the item dimmed")
    }

    @Test func theCaptureIsSaidInWordsForEachPairOfStates() {
        func label(_ camera: WKMediaCaptureState, _ microphone: WKMediaCaptureState) -> String? { MediaCapture(camera: camera, microphone: microphone).label }
        #expect(label(.none, .none) == nil)
        #expect(label(.active, .none) == String(localized: "Camera on"))
        #expect(label(.none, .active) == String(localized: "Microphone on"))
        #expect(label(.active, .active) == String(localized: "Camera and microphone on"))
        #expect(label(.muted, .muted) == nil, "a muted capture records nothing")
        #expect(label(.muted, .active) == String(localized: "Microphone on"))
        #expect(MediaCapture(camera: .active, microphone: .active).stopHelp == String(localized: "Stop the camera and microphone"))
        #expect(MediaCapture(camera: .none, microphone: .active).stopHelp == String(localized: "Stop the microphone"))
        #expect(MediaCapture().stopHelp == nil)
    }

    @Test func aTabStartsWithNothingCaptured() throws {
        let b = Browser()
        defer { b.windowClosed() }
        let tab = b.openTab(url: URL(string: "https://example.com/"))
        #expect(tab.capture == MediaCapture())
    }

    @Test func adBlockingOffOnASiteIsSaidInWords() {
        #expect(AdBlockShield.value(off: true) == String(localized: "Ad blocking is off on this site"))
        #expect(AdBlockShield.value(off: false) == Accessibility.onOffValue(true))
        #expect(AdBlockShield.help(off: true) == String(localized: "Ad blocking is off on this site. Click to turn it on."))
        #expect(AdBlockShield.help(off: false) != AdBlockShield.help(off: true))
    }

    @Test func findStartsFromTheSelectedTextWhenThereIsSome() {
        #expect(Browser.findPrefill(selection: "ramen", current: "") == "ramen")
        #expect(Browser.findPrefill(selection: "  two words \n second line", current: "old") == "two words", "the first line, trimmed")
        #expect(Browser.findPrefill(selection: "", current: "old") == nil, "nothing selected keeps what was searched")
        #expect(Browser.findPrefill(selection: " \n ", current: "old") == nil)
        #expect(Browser.findPrefill(selection: nil, current: "old") == nil)
        #expect(Browser.findPrefill(selection: "Ramen", current: "ramen") == nil, "the match the last find selected is not new text")
        #expect(Browser.findPrefill(selection: String(repeating: "x", count: 500), current: "")?.count == 200)
    }

    @Test func noMatchComesFromWebKitAndAFoundTextIsNeverCalledNone() {
        #expect(Browser.findCount(matchFound: false, scanned: 5) == 0, "WebKit found nothing, whatever the text scan says")
        #expect(Browser.findCount(matchFound: false, scanned: nil) == 0)
        #expect(Browser.findCount(matchFound: true, scanned: 7) == 7)
        #expect(Browser.findCount(matchFound: true, scanned: 0) == 1, "found in a place innerText doesn't read")
        #expect(Browser.findCount(matchFound: true, scanned: nil) == nil, "no count rather than a wrong one")
        #expect(Accessibility.findMatches(0) == String(localized: "No matches"))
    }
}
