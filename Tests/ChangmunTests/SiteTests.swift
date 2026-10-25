import Foundation
import Testing
@testable import Changmun

@MainActor
struct SiteTests {
    private static let table: [(String, String?)] = [
        ("https://example.com/path?q=1", "example.com"),
        ("https://EXAMPLE.Com", "example.com"),
        ("https://www.example.com", "www.example.com"),
        ("https://shop.example.com", "shop.example.com"),
        ("https://example.com.", "example.com."),
        ("https://example.com:443", "example.com"),
        ("https://example.com:8443", "example.com:8443"),
        ("https://example.com:80", "example.com:80"),
        ("http://example.com", "http://example.com"),
        ("http://example.com:80", "http://example.com"),
        ("http://example.com:443", "http://example.com:443"),
        ("http://example.com:8080", "http://example.com:8080"),
        ("https://[::1]", "[::1]"),
        ("https://[2001:DB8::1]:8443", "[2001:db8::1]:8443"),
        ("http://[::1]:80", "http://[::1]"),
        ("https://münchen.example", "xn--mnchen-3ya.example"),
        ("https://例え.jp", "xn--r8jz45g.jp"),
        ("file:///Users/me/a.html", "file:"),
        ("data:text/html,hello", "data:"),
        ("blob:null/abc", "blob:"),
        ("about:blank", nil),
        ("javascript:void(0)", "javascript:"),
        ("https:///nohost", "https:"),
        ("http://", "http:"),
    ]

    @Test func siteOfAnAddressStaysAsItWas() {
        for (address, expected) in Self.table {
            #expect(Approvals.site(of: URL(string: address)) == expected, "\(address)")
        }
        #expect(Approvals.site(of: nil) == nil)
        #expect(Approvals.site(of: URL(fileURLWithPath: "/tmp/a.html")) == "file:")
    }

    @Test func siteOfAnOriginStaysAsItWas() {
        let origins: [(String, String)] = [
            ("https://example.com:8443", "example.com:8443"),
            ("http://example.com", "http://example.com"),
            ("https://Example.com", "example.com"),
            ("null", ""),
            ("", ""),
            ("about:blank", ""),
            ("file://", "file:"),
        ]
        for (origin, expected) in origins {
            #expect(Approvals.site(ofOrigin: origin) == expected, "\(origin)")
        }
    }

    @Test func hostnameOfASiteStaysAsItWas() {
        let sites: [(String, String?)] = [
            ("example.com", "example.com"),
            ("example.com:8443", "example.com"),
            ("http://example.com", "example.com"),
            ("http://example.com:8080", "example.com"),
            ("[::1]", "::1"),
            ("http://[2001:db8::1]:8080", "2001:db8::1"),
            ("[::1", nil),
            ("file:", nil),
            ("data:", nil),
            ("", nil),
            (Approvals.unknownFrame, nil),
            (Approvals.addedImage, nil),
        ]
        for (site, expected) in sites {
            #expect(Approvals.hostname(ofSite: site) == expected, "\(site)")
        }
    }

    @Test func hasSiteStaysAsItWas() {
        for site in ["example.com", "http://example.com", "[::1]", "a:1", Approvals.unknownFrame, Approvals.addedImage] {
            #expect(Approvals.hasSite(site), "\(site)")
        }
        for site in ["", "file:", "data:", "blob:"] {
            #expect(!Approvals.hasSite(site), "\(site)")
        }
    }

    @Test func theSentinelsAreTheirOwnSites() {
        #expect(Approvals.unknownFrame == "\u{1}unknown-frame")
        #expect(Approvals.addedImage == "\u{1}added-image")
        #expect(Approvals.unknownFrame != Approvals.addedImage)
    }
}
