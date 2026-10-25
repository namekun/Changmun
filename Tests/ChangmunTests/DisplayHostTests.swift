import Testing
@testable import Changmun

/// The host as shown to the user: a leading "www." dropped, nothing else changed.
struct DisplayHostTests {
    @Test func aLeadingWwwIsDropped() {
        #expect(DisplayHost.trimmed("www.example.com") == "example.com")
    }

    @Test func aHostWithoutTheDotIsKept() {
        #expect(DisplayHost.trimmed("wwwexample.com") == "wwwexample.com")
    }

    @Test func theMatchIsCaseSensitive() {
        #expect(DisplayHost.trimmed("WWW.example.com") == "WWW.example.com")
    }

    @Test func wwwAloneLeavesNothing() {
        #expect(DisplayHost.trimmed("www.") == "")
    }

    @Test func aPlainHostIsKept() {
        #expect(DisplayHost.trimmed("example.com") == "example.com")
    }
}
