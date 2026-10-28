import Foundation
import Testing
@testable import Changmun

private func stripped(_ text: String) -> String {
    TrackingParameters.strip(URL(string: text)!).absoluteString
}

struct TrackingParameterTests {
    /// (what is asked, what loads)
    static let cases: [(String, String)] = [
        // Nothing to take out.
        ("https://example.com/", "https://example.com/"),
        ("https://example.com/page?id=7", "https://example.com/page?id=7"),
        ("https://example.com/?a=1&b=2", "https://example.com/?a=1&b=2"),
        // One, and the others stay in their order.
        ("https://example.com/?utm_source=news", "https://example.com/"),
        ("https://example.com/?utm_source=news&id=7", "https://example.com/?id=7"),
        ("https://example.com/?id=7&utm_source=news", "https://example.com/?id=7"),
        ("https://example.com/?a=1&utm_source=x&b=2&utm_medium=y&c=3", "https://example.com/?a=1&b=2&c=3"),
        ("https://example.com/?b=2&a=1&fbclid=x", "https://example.com/?b=2&a=1"),
        // The whole list of names.
        ("https://example.com/?utm_campaign=c", "https://example.com/"),
        ("https://example.com/?utm_term=t", "https://example.com/"),
        ("https://example.com/?utm_content=c", "https://example.com/"),
        ("https://example.com/?utm_id=1", "https://example.com/"),
        ("https://example.com/?utm_name=n", "https://example.com/"),
        ("https://example.com/?utm_anything_new=1", "https://example.com/"),
        ("https://example.com/?fbclid=abc", "https://example.com/"),
        ("https://example.com/?gclid=abc", "https://example.com/"),
        ("https://example.com/?gclsrc=aw.ds", "https://example.com/"),
        ("https://example.com/?dclid=abc", "https://example.com/"),
        ("https://example.com/?gbraid=abc", "https://example.com/"),
        ("https://example.com/?wbraid=abc", "https://example.com/"),
        ("https://example.com/?msclkid=abc", "https://example.com/"),
        ("https://example.com/?yclid=abc", "https://example.com/"),
        ("https://example.com/?twclid=abc", "https://example.com/"),
        ("https://example.com/?ttclid=abc", "https://example.com/"),
        ("https://example.com/?li_fat_id=abc", "https://example.com/"),
        ("https://example.com/?igshid=abc", "https://example.com/"),
        ("https://example.com/?igsh=abc", "https://example.com/"),
        ("https://example.com/?mc_cid=a&mc_eid=b", "https://example.com/"),
        ("https://example.com/?_hsenc=a&_hsmi=1", "https://example.com/"),
        ("https://example.com/?hsa_acc=1&hsa_cam=2&hsa_kw=x", "https://example.com/"),
        ("https://example.com/?mkt_tok=abc", "https://example.com/"),
        ("https://example.com/?vero_id=abc", "https://example.com/"),
        ("https://example.com/?oly_enc_id=a&oly_anon_id=b", "https://example.com/"),
        ("https://example.com/?s_cid=abc", "https://example.com/"),
        ("https://example.com/?ScCid=abc", "https://example.com/"),
        ("https://example.com/?rb_clickid=abc", "https://example.com/"),
        ("https://example.com/?wickedid=abc", "https://example.com/"),
        ("https://example.com/?ef_id=abc", "https://example.com/"),
        ("https://example.com/?epik=abc", "https://example.com/"),
        ("https://example.com/?_ga=2.1.2", "https://example.com/"),
        ("https://example.com/?_gl=1*abc*", "https://example.com/"),
        ("https://example.com/?__s=abc", "https://example.com/"),
        // Names that are ambiguous stay.
        ("https://example.com/?ref=home", "https://example.com/?ref=home"),
        ("https://example.com/?source=app&id=1&cid=2&campaign=spring", "https://example.com/?source=app&id=1&cid=2&campaign=spring"),
        ("https://example.com/?spm=a2g0o.1&utm_source=x", "https://example.com/?spm=a2g0o.1"),
        ("https://example.com/?utm=1&utms_source=2&xutm_source=3", "https://example.com/?utm=1&utms_source=2&xutm_source=3"),
        ("https://example.com/?fbclid2=1&gclidx=2&myfbclid=3", "https://example.com/?fbclid2=1&gclidx=2&myfbclid=3"),
        // Names are compared without regard to case or percent-encoding, values are never looked at.
        ("https://example.com/?UTM_SOURCE=x&Fbclid=y&GCLID=z&scCID=w", "https://example.com/"),
        ("https://example.com/?utm%5Fsource=x&a=1", "https://example.com/?a=1"),
        ("https://example.com/?a=utm_source&b=fbclid", "https://example.com/?a=utm_source&b=fbclid"),
        ("https://example.com/?q=fbclid%3D1&utm_source=x", "https://example.com/?q=fbclid%3D1"),
        // Duplicates all go.
        ("https://example.com/?utm_source=a&utm_source=b&id=1", "https://example.com/?id=1"),
        ("https://example.com/?id=1&id=2&gclid=a&id=3", "https://example.com/?id=1&id=2&id=3"),
        // Encoding of what stays is kept as written.
        ("https://example.com/?q=a%20b+c&utm_source=x&r=%E2%9C%93", "https://example.com/?q=a%20b+c&r=%E2%9C%93"),
        ("https://example.com/?q=%7Etilde%2F&fbclid=1", "https://example.com/?q=%7Etilde%2F"),
        ("https://example.com/?a&b=&=c&utm_source=x", "https://example.com/?a&b=&=c"),
        ("https://example.com/?a=1&&b=2&utm_source=x", "https://example.com/?a=1&&b=2"),
        ("https://example.com/?a=1=2&gclid=x", "https://example.com/?a=1=2"),
        // An empty query loses its question mark.
        ("https://example.com/?utm_source=x", "https://example.com/"),
        ("https://example.com/path?utm_source=x&utm_medium=y", "https://example.com/path"),
        ("https://example.com?utm_source=x", "https://example.com"),
        // A fragment stays, and so does a question mark in it.
        ("https://example.com/?utm_source=x#top", "https://example.com/#top"),
        ("https://example.com/?id=1&utm_source=x#sec?utm_source=y", "https://example.com/?id=1#sec?utm_source=y"),
        ("https://example.com/#utm_source=x", "https://example.com/#utm_source=x"),
        ("https://example.com/#/route?fbclid=1", "https://example.com/#/route?fbclid=1"),
        // Ports, user info, paths and hosts are left alone.
        ("https://example.com:8443/a/b?fbclid=1&x=2", "https://example.com:8443/a/b?x=2"),
        ("http://user:pass@example.com:8080/?utm_source=x&k=v", "http://user:pass@example.com:8080/?k=v"),
        ("https://sub.example.co.kr/a%20b/c;p=1?utm_source=x", "https://sub.example.co.kr/a%20b/c;p=1"),
        ("https://[::1]:3000/?gclid=1&a=2", "https://[::1]:3000/?a=2"),
        ("http://127.0.0.1:8000/echo?utm_source=a&n=1", "http://127.0.0.1:8000/echo?n=1"),
        // International hosts and paths.
        ("https://bücher.example/straße?fbclid=1", "https://xn--bcher-kva.example/stra%C3%9Fe"),
        ("https://xn--bcher-kva.example/?utm_source=x&q=%ED%95%9C", "https://xn--bcher-kva.example/?q=%ED%95%9C"),
        ("https://example.com/%ED%95%9C%EA%B8%80?utm_source=x", "https://example.com/%ED%95%9C%EA%B8%80"),
        // Uppercase scheme and host are kept as written.
        ("HTTPS://EXAMPLE.COM/?utm_source=x", "HTTPS://EXAMPLE.COM/"),
    ]

    @Test(arguments: cases) func addressBecomes(_ pair: (String, String)) {
        let (asked, loads) = pair
        guard let url = URL(string: asked) else { Issue.record("not an address: \(asked)"); return }
        let result = TrackingParameters.strip(url).absoluteString
        #expect(result == loads, "\(asked) → \(result), wanted \(loads)")
    }

    @Test func notHTTPIsNeverTouched() {
        for text in ["ftp://example.com/?utm_source=x", "file:///tmp/a.html?utm_source=x", "data:text/html,utm_source=x?utm_source=1",
                     "mailto:a@b.c?utm_source=x", "about:blank?utm_source=x", "javascript:void(0)?utm_source=x", "claude://open?utm_source=x"] {
            #expect(stripped(text) == URL(string: text)!.absoluteString, "\(text)")
        }
    }

    @Test func anAddressWithNoHostIsNeverTouched() {
        #expect(TrackingParameters.strip(URL(string: "https:///?utm_source=x")!).absoluteString == URL(string: "https:///?utm_source=x")!.absoluteString)
    }

    @Test func aRelativeURLIsNeverTouched() {
        let relative = URL(string: "/page?utm_source=x")!
        #expect(TrackingParameters.strip(relative) == relative)
    }

    @Test func strippingTwiceChangesNothingMore() {
        for (asked, _) in Self.cases {
            let once = TrackingParameters.strip(URL(string: asked)!)
            #expect(TrackingParameters.strip(once) == once, "\(asked)")
        }
    }

    @Test func theListHasNoAmbiguousName() {
        for name in ["ref", "source", "id", "cid", "campaign", "spm", "src", "medium", "from", "track", "tag", "s", "t", "si"] {
            #expect(!TrackingParameters.isTracking(name), "\(name) means something to a page")
        }
        for name in TrackingParameters.names { #expect(name == name.lowercased()) }
    }
}

struct HTTPSFirstTests {
    private func secure(_ text: String, plainHosts: Set<String> = [], override: HTTPSFirst.Override? = nil) -> String? {
        HTTPSFirst.secureURL(for: URL(string: text)!, plainHosts: plainHosts, override: override)?.absoluteString
    }

    @Test func aPublicHostIsTriedOverHTTPS() {
        #expect(secure("http://example.com/") == "https://example.com/")
        #expect(secure("http://www.example.co.kr/a/b?c=d#e") == "https://www.example.co.kr/a/b?c=d#e")
        #expect(secure("http://user:pw@example.com/x") == "https://user:pw@example.com/x")
        #expect(secure("HTTP://Example.COM/")?.lowercased() == "https://example.com/")
        #expect(secure("http://example.com:80/x") == "https://example.com/x", "port 80 is the default one")
        #expect(secure("http://example.com./") == "https://example.com./")
    }

    @Test func otherSchemesAreLeftAlone() {
        for text in ["https://example.com/", "file:///tmp/a", "data:text/html,hi", "about:blank", "ftp://example.com/", "claude://x", "blob:https://example.com/id"] {
            #expect(secure(text) == nil, "\(text)")
        }
    }

    @Test func aPortOtherThan80IsLeftAlone() {
        #expect(secure("http://example.com:8080/") == nil)
        #expect(secure("http://example.com:443/") == nil)
        #expect(secure("http://example.com:81/") == nil)
    }

    @Test func localAndTestNamesStayHTTP() {
        for host in ["localhost", "LOCALHOST", "foo.localhost", "printer.local", "nas.local.", "my.test", "a.b.test", "router.internal", "x.lan", "box.home",
                     "app.corp", "wiki.intranet", "tv.home.arpa", "x.invalid", "x.example", "intranet", "mac", "nas"] {
            #expect(secure("http://\(host)/") == nil, "\(host)")
        }
    }

    @Test func nameThatMerelyEndsLikeALocalOneIsPublic() {
        for host in ["mytest.com", "notlocalhost.com", "contest.org", "local.example.com", "test.example.com", "lan.io", "home.com"] {
            #expect(secure("http://\(host)/") != nil, "\(host)")
        }
    }

    @Test func everyIPAddressStaysHTTP() {
        for host in ["127.0.0.1", "10.0.0.5", "192.168.1.1", "172.16.0.1", "169.254.1.1", "100.64.0.1", "8.8.8.8", "203.0.113.9", "0.0.0.0",
                     "[::1]", "[fe80::1]", "[fc00::1]", "[2001:db8::1]", "2130706433", "0x7f.0.0.1", "1.2.3.4."] {
            #expect(secure("http://\(host)/") == nil, "\(host)")
        }
    }

    @Test func aHostTheUserWentOnWithOverHTTPStaysHTTP() {
        #expect(secure("http://example.com/", plainHosts: ["example.com"]) == nil)
        #expect(secure("http://Example.com./x", plainHosts: ["example.com"]) == nil)
        #expect(secure("http://www.example.com/", plainHosts: ["example.com"]) != nil, "another host of the site is its own")
    }

    @Test func aTestHostCanPlayAPublicSite() {
        let override = HTTPSFirst.Override(hosts: ["localhost"], plainPort: 8080, securePort: 8443)
        #expect(secure("http://localhost:8080/p?q=1", override: override) == "https://localhost:8443/p?q=1")
        #expect(secure("http://localhost:9999/", override: override) == nil)
        #expect(secure("http://localhost/", override: override) != nil, "no port is the plain one")
        #expect(secure("http://other.localhost:8080/", override: override) == nil)
        #expect(secure("http://localhost:8080/", plainHosts: ["localhost"], override: override) == nil)
        #expect(secure("http://localhost:8080/", override: nil) == nil)
        let standard = HTTPSFirst.Override(hosts: ["127.0.0.1"], plainPort: 80, securePort: 443)
        #expect(secure("http://127.0.0.1/x", override: standard) == "https://127.0.0.1/x")
    }

    // MARK: Falling back

    private let attempt = URL(string: "https://example.com/page")!

    @Test func onlyAFailedConnectionFallsBackToHTTP() {
        for code in [NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost] {
            #expect(HTTPSFirst.fallsBack(domain: NSURLErrorDomain, code: code, failing: attempt, upgraded: attempt), "\(code)")
        }
    }

    @Test func aCertificateErrorNeverFallsBackToHTTP() {
        let certificate = [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                           NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired,
                           NSURLErrorSecureConnectionFailed]
        for code in certificate {
            #expect(!HTTPSFirst.fallsBack(domain: NSURLErrorDomain, code: code, failing: attempt, upgraded: attempt), "\(code)")
        }
        #expect(ServerTrust.failureCodes.isDisjoint(with: HTTPSFirst.fallbackCodes), "the codes that bring the certificate warning are never a way to http")
    }

    @Test func otherFailuresStayErrors() {
        for code in [NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet, NSURLErrorCancelled, NSURLErrorBadURL,
                     NSURLErrorBadServerResponse, NSURLErrorCannotParseResponse, NSURLErrorHTTPTooManyRedirects, NSURLErrorUserCancelledAuthentication] {
            #expect(!HTTPSFirst.fallsBack(domain: NSURLErrorDomain, code: code, failing: attempt, upgraded: attempt), "\(code)")
        }
        #expect(!HTTPSFirst.fallsBack(domain: "WebKitErrorDomain", code: NSURLErrorCannotConnectToHost, failing: attempt, upgraded: attempt))
        #expect(!HTTPSFirst.fallsBack(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, failing: nil, upgraded: attempt), "no address said, no fallback")
    }

    @Test func aPageItWasSentOnToIsNotItsFallback() {
        let other = URL(string: "https://elsewhere.example/page")!
        #expect(!HTTPSFirst.fallsBack(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, failing: other, upgraded: attempt))
        let port = URL(string: "https://example.com:8443/page")!
        #expect(!HTTPSFirst.fallsBack(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, failing: port, upgraded: attempt))
        let insecure = URL(string: "http://example.com/page")!
        #expect(!HTTPSFirst.fallsBack(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, failing: insecure, upgraded: attempt))
        let path = URL(string: "https://EXAMPLE.com/other")!
        #expect(HTTPSFirst.fallsBack(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, failing: path, upgraded: attempt), "the same site, the same connection")
    }
}

struct LinkRewriteTests {
    private func rewrite(_ text: String, tracking: Bool = true, https: Bool = true, plainHosts: Set<String> = []) -> LinkRewrite.Result? {
        LinkRewrite.rewrite(URL(string: text)!, stripsTracking: tracking, upgrades: https, plainHosts: plainHosts)
    }

    @Test func nothingToDoIsNil() {
        #expect(rewrite("https://example.com/?a=1") == nil)
        #expect(rewrite("http://127.0.0.1:8000/?a=1") == nil)
        #expect(rewrite("https://example.com/?utm_source=x", tracking: false) == nil)
        #expect(rewrite("http://example.com/", https: false) == nil)
    }

    @Test func trackingAloneLoadsTheCleanedAddress() {
        let result = rewrite("https://example.com/?utm_source=x&a=1")
        #expect(result == LinkRewrite.Result(url: URL(string: "https://example.com/?a=1")!, plain: nil))
        #expect(rewrite("http://127.0.0.1:8000/?gclid=1")?.url.absoluteString == "http://127.0.0.1:8000/")
        #expect(rewrite("http://127.0.0.1:8000/?gclid=1")?.plain == nil, "an address that stays http has no fallback")
    }

    @Test func httpsAloneKeepsEverythingElse() {
        let result = rewrite("http://example.com/p?utm_source=x#f", tracking: false)
        #expect(result?.url.absoluteString == "https://example.com/p?utm_source=x#f")
        #expect(result?.plain?.absoluteString == "http://example.com/p?utm_source=x#f")
    }

    @Test func bothTogetherFallBackToTheCleanedAddress() {
        let result = rewrite("http://example.com/p?utm_source=x&a=1")
        #expect(result?.url.absoluteString == "https://example.com/p?a=1")
        #expect(result?.plain?.absoluteString == "http://example.com/p?a=1", "the fallback does not bring the tracking back")
    }

    @Test func aHostFoundNotToSpeakHTTPSIsOnlyCleaned() {
        let result = rewrite("http://example.com/?fbclid=1", plainHosts: ["example.com"])
        #expect(result == LinkRewrite.Result(url: URL(string: "http://example.com/")!, plain: nil))
        #expect(rewrite("http://example.com/", plainHosts: ["example.com"]) == nil)
    }

    @Test func rewritingTheResultAgainChangesNothing() {
        for text in ["http://example.com/?utm_source=x&a=1", "https://example.com/?fbclid=1", "http://127.0.0.1/?gclid=1"] {
            guard let first = rewrite(text) else { Issue.record("no rewrite of \(text)"); continue }
            #expect(rewrite(first.url.absoluteString) == nil, "\(text)")
        }
    }
}

@MainActor struct PrivacySwitchTests {
    @Test func theTwoSwitchesAreOnUntilTurnedOff() {
        #expect(Preferences.privacySwitch(nil), "everyone who had the app before has nothing stored: on")
        #expect(Preferences.privacySwitch(true))
        #expect(!Preferences.privacySwitch(false))
        #expect(Preferences.privacySwitch("false"), "a value of another kind is not a choice")
    }

    @Test func aSiteKeepsItsTrackingBySiteNotByExactHost() {
        var kept = Preferences.adding("www.Example.com", to: [])
        #expect(kept == ["example.com"])
        #expect(Preferences.matches("shop.example.com", kept))
        #expect(!Preferences.matches("example.org", kept))
        kept = Preferences.removing("shop.example.com", from: kept)
        #expect(kept.isEmpty)
    }
}
