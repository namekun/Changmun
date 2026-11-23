import AppKit
import Foundation
import Network
import Testing
import WebKit
@testable import Changmun

/// Logins saved for one host of a site are offered on its other hosts, by the Public Suffix List: never under a public suffix (a
/// shared hosting platform among them), across a port, without the list, or to the AI. Everything here runs on an in-memory keychain
/// or a stand-in for it.
struct LoginSharingTests {
    private func with(_ saved: [(host: String, username: String)], _ body: () throws -> Void) rethrows {
        let keychain = MemoryKeychain()
        for login in saved { _ = keychain.set(server: login.host, account: login.username, secret: Data("pw for \(login.host)".utf8)) }
        try Logins.$testBackend.withValue(keychain, operation: body)
    }

    @Test func theSitesOtherHostsComeAfterThePagesOwnEachLabelledWithItsHost() {
        with([("accounts.example.com", "alice"), ("example.com", "bob"), ("www.example.com", "carol"), ("mail.example.com", "alice"), ("other.com", "eve")]) {
            let onWWW = Logins.matches(for: "www.example.com")
            #expect(onWWW.map(\.title) == ["carol", "bob", "alice — accounts.example.com", "alice — mail.example.com"], "\(onWWW)")
            #expect(onWWW.map(\.sameHost) == [true, true, false, false], "the www twin is the page's own, as before")
            let onAccounts = Logins.matches(for: "accounts.example.com")
            #expect(onAccounts.map(\.title) == ["alice", "bob — example.com", "alice — mail.example.com", "carol — www.example.com"], "\(onAccounts)")
            #expect(Logins.matches(for: "other.com").map(\.title) == ["eve"])
            #expect(Logins.matches(for: "example.org").isEmpty)
        }
    }

    @Test func aLoginWithNoUsernameFromAnotherHostSaysSo() {
        with([("accounts.example.com", "")]) {
            #expect(Logins.matches(for: "example.com").map(\.title) == ["\(String(localized: "(No username)")) — accounts.example.com"])
        }
    }

    @Test func savingStillGoesUnderThePagesOwnHost() {
        with([("accounts.example.com", "alice")]) {
            #expect(Logins.save(host: "www.example.com", username: "alice", password: "new"))
            #expect(Logins.all().map { "\($0.host)/\($0.username)" } == ["accounts.example.com/alice", "www.example.com/alice"])
            #expect(Logins.password(exactly: "accounts.example.com", username: "alice") == "pw for accounts.example.com", "the other host's is left as it was")
        }
    }

    @Test func hostsOfOneRegistrableDomainShare() {
        #expect(Logins.mayShare("accounts.example.com", with: "www.example.com"))
        #expect(Logins.mayShare("nid.naver.com", with: "naver.com") && Logins.mayShare("naver.com", with: "www.naver.com"))
        #expect(Logins.mayShare("mail.naver.co.kr", with: "www.naver.co.kr"), "co.kr is a suffix: naver.co.kr is the site")
        #expect(Logins.mayShare("shop.example.co.uk", with: "example.co.uk"))
        #expect(Logins.mayShare("Accounts.Example.com", with: "www.example.com"), "names are compared in lower case")
    }

    @Test(arguments: [
        ("a.hs.kr", "b.hs.kr"), ("alice.school.sch.uk", "bob.school.sch.uk"), ("alice.synology.me", "bob.synology.me"),
        ("alice.myshopify.com", "bob.myshopify.com"), ("alice.duckdns.org", "bob.duckdns.org"), ("alice.r2.dev", "bob.r2.dev"),
        ("alice.github.io", "bob.github.io"), ("alice.tistory.com", "bob.tistory.com"), ("naver.co.kr", "daum.co.kr"),
        ("alice.com.pl", "bob.com.pl"), ("bucket.s3.amazonaws.com", "other.s3.amazonaws.com"),
    ])
    func differentSitesUnderAPublicSuffixDoNotShare(a: String, b: String) {
        #expect(!Logins.mayShare(a, with: b) && !Logins.mayShare(b, with: a))
    }

    @Test func aPublicSuffixItselfSharesWithNothing() {
        #expect(!Logins.mayShare("github.io", with: "alice.github.io") && !Logins.mayShare("alice.github.io", with: "github.io"))
        #expect(!Logins.mayShare("co.kr", with: "naver.co.kr"))
        with([("alice.github.io", "alice"), ("bob.github.io", "bob")]) {
            #expect(Logins.matches(for: "bob.github.io").map(\.title) == ["bob"], "only the exact host's own")
            #expect(Logins.matches(for: "mallory.github.io").isEmpty)
        }
    }

    @Test func otherSitesNeverShare() {
        #expect(!Logins.mayShare("a.example.com", with: "a.example.org"))
        #expect(!Logins.mayShare("example.com", with: "notexample.com"))
        #expect(!Logins.mayShare("example.com.evil.test", with: "example.com"))
    }

    @Test func portsAddressesAndOneLabelNamesAreNeverShared() {
        #expect(Logins.mayShare("accounts.example.com:8443", with: "www.example.com:8443"), "the same port of the same site")
        #expect(!Logins.mayShare("accounts.example.com", with: "www.example.com:8443"))
        #expect(!Logins.mayShare("accounts.example.com:8443", with: "www.example.com"))
        #expect(!Logins.mayShare("accounts.example.com:8443", with: "www.example.com:9443"))
        #expect(!Logins.mayShare("10.0.0.1", with: "10.0.0.2") && !Logins.mayShare("10.0.0.1", with: "10.0.0.1:8080"))
        #expect(!Logins.mayShare("localhost", with: "localhost:3000") && !Logins.mayShare("app.localhost", with: "api.localhost"))
        #expect(!Logins.mayShare("[::1]:8443", with: "[::1]:9443"))
        with([("example.com", "plain"), ("accounts.example.com:8443", "port"), ("dev.example.com:8443", "dev")]) {
            #expect(Logins.matches(for: "www.example.com:8443").map(\.title) == ["plain", "port — accounts.example.com:8443", "dev — dev.example.com:8443"],
                    "the bare host's login (from before ports counted) is the page's own; another host's only on the same port")
            #expect(Logins.matches(for: "www.example.com").map(\.title) == ["plain"])
        }
    }

    @Test func withoutTheListNothingIsShared() {
        PublicSuffix.$unavailableForTest.withValue(true) {
            #expect(!Logins.mayShare("accounts.example.com", with: "www.example.com"))
            #expect(!Tab.sameSite("login.example.com", "www.example.com") && Tab.sameSite("www.example.com", "www.example.com"))
            #expect(SiteIndex.registrableStart("mail.google.com") == "mail.google.".utf8.count, "the address bar errs toward offering less")
            with([("accounts.example.com", "alice"), ("www.example.com", "carol")]) {
                #expect(Logins.matches(for: "www.example.com").map(\.title) == ["carol"])
            }
        }
    }

    @MainActor @Test func theOriginIsTheDocumentsOwnAndOnlyWhileItIsThePageCommitted() throws {
        let page = URL(string: "https://www.example.com/login"), www = Changmun.Tab.Origin(host: "www.example.com", port: 443)
        func origin(_ document: Changmun.Tab.Origin?, _ committed: URL?, provisional: Bool = false, unverified: Bool = false) -> String? {
            LoginFieldMenu.pageOrigin(document: document, committed: committed, provisional: provisional, isUnverified: unverified)?.key
        }
        #expect(origin(www, page) == "www.example.com")
        #expect(origin(www, page, provisional: true) == nil, "not while a navigation is under way")
        #expect(origin(www, URL(string: "https://bank.example:444/")) == nil, "not another document than the one committed")
        #expect(origin(Changmun.Tab.Origin(host: "bank.example", port: 444), page) == nil)
        #expect(origin(www, page, unverified: true) == nil, "not on an unverified page")
        #expect(origin(nil, URL(string: "http://www.example.com/login")) == nil, "never on http")
        let port = Changmun.Tab.Origin(host: "www.example.com", port: 8443)
        #expect(origin(port, URL(string: "https://www.example.com:8443/")) == "www.example.com:8443" && port.web == "https://www.example.com:8443")
        #expect(Changmun.Tab.Origin(host: "[::1]", port: 8443).web == "https://[::1]:8443" && Changmun.Tab.Origin(host: "::1", port: 8443).key == "[::1]:8443")
    }

    @MainActor @Test func theAIsSignInStaysWithTheExactHost() {
        with([("accounts.example.com", "alice")]) {
            #expect(!Logins.matches(for: "www.example.com").isEmpty, "the user is offered it")
            #expect(SignIn.activeStore is KeychainLogins)
            #expect(SignIn.activeStore.accounts(exactly: "www.example.com").isEmpty, "the AI is not")
            #expect(SignIn.activeStore.password(exactly: "www.example.com", username: "alice") == nil)
            #expect(SignIn.activeStore.accounts(exactly: "accounts.example.com") == ["alice"])
        }
    }

    @Test func theRecordsAreReadOnceUntilAChangeOrTheirTimeIsUp() {
        var reads = 0
        var clock = Date(timeIntervalSince1970: 1_000)
        let cache = Logins.RecordCache(now: { clock }) { reads += 1; return [Logins.Record(server: "example.com", account: "me")] }
        _ = cache.records()
        _ = cache.records()
        #expect(reads == 1)
        cache.invalidate()
        #expect(cache.records().map(\.account) == ["me"] && reads == 2, "a change made here is read at once")
        clock.addTimeInterval(Logins.RecordCache.ttl - 1)
        _ = cache.records()
        #expect(reads == 2)
        clock.addTimeInterval(2)
        _ = cache.records()
        #expect(reads == 3, "one made elsewhere within the time")
    }

    @Test func aFieldsRectIsScaledByThePagesZoomAndTurnedOverWhenTheViewIsNot() {
        let css = CGRect(x: 40, y: 100, width: 200, height: 20)
        #expect(LoginFieldMenu.viewRect(css, zoom: 1.5, flipped: true, height: 600) == CGRect(x: 60, y: 150, width: 300, height: 30))
        #expect(LoginFieldMenu.viewRect(css, zoom: 1, flipped: false, height: 600) == CGRect(x: 40, y: 480, width: 200, height: 20))
    }

    @Test func theMenuGoesUnderTheFieldOrOverItAndStaysOnThePage() {
        let room = LoginFieldMenu.shadowRoom, gap = Metrics.rowGap, size = CGSize(width: 200 + 2 * room, height: 100 + 2 * room)
        let page = CGRect(x: 100, y: 0, width: 800, height: 700)
        let field = CGRect(x: 300, y: 500, width: 200, height: 24)
        let under = LoginFieldMenu.panelFrame(field: field, size: size, bounds: page)
        #expect(under.minX + room == field.minX && under.maxY - room == field.minY - gap, "the list's top left just under the field's bottom left")
        let low = CGRect(x: 300, y: 40, width: 200, height: 24)
        let over = LoginFieldMenu.panelFrame(field: low, size: size, bounds: page)
        #expect(over.minY + room == low.maxY + gap, "over the field when there is no room under it")
        let right = LoginFieldMenu.panelFrame(field: CGRect(x: 850, y: 500, width: 40, height: 24), size: size, bounds: page)
        #expect(right.maxX - room == page.maxX, "not past the page's right edge")
        let left = LoginFieldMenu.panelFrame(field: CGRect(x: 20, y: 500, width: 40, height: 24), size: size, bounds: page)
        #expect(left.minX + room == page.minX, "nor its left")
        let squeezed = LoginFieldMenu.panelFrame(field: CGRect(x: 300, y: 50, width: 200, height: 24), size: size, bounds: CGRect(x: 100, y: 0, width: 800, height: 160))
        #expect(squeezed.minY + room >= 0 && squeezed.maxY - room <= 160, "inside the page when it fits neither way")
    }
}

/// The Public Suffix List as the app reads it.
struct PublicSuffixTests {
    @Test func theBundledListIsReadWithBothSections() throws {
        let list = try #require(PublicSuffix.shared)
        #expect(list.count > 9_000)
        #expect(list.isPublicSuffix("co.kr") && list.isPublicSuffix("com"), "ICANN")
        #expect(list.isPublicSuffix("github.io") && list.isPublicSuffix("myshopify.com"), "PRIVATE")
        #expect(!list.isPublicSuffix("example.com"))
    }

    @Test func wildcardAndExceptionRules() throws {
        let list = try #require(PublicSuffix.shared)
        // *.ck and !www.ck
        #expect(list.registrableDomain("a.b.ck") == "a.b.ck" && list.isPublicSuffix("b.ck"))
        #expect(list.registrableDomain("www.ck") == "www.ck" && list.registrableDomain("x.www.ck") == "www.ck")
        // *.kawasaki.jp and !city.kawasaki.jp
        #expect(list.registrableDomain("x.city.kawasaki.jp") == "city.kawasaki.jp")
        #expect(list.registrableDomain("a.b.kawasaki.jp") == "a.b.kawasaki.jp" && list.registrableDomain("b.kawasaki.jp") == nil)
        // *.sch.uk
        #expect(list.registrableDomain("www.school.sch.uk") == "www.school.sch.uk")
        // The implicit "*": an unknown last label is a suffix of its own.
        #expect(list.registrableDomain("a.b.example") == "b.example")
    }

    @Test func namesInOtherScriptsAreMatchedInPunycode() throws {
        #expect(PublicSuffix.punycode("公司") == "55qx5d")
        #expect(PublicSuffix.punycode("한국") == "3e0b707e")
        #expect(PublicSuffix.punycode("bücher") == "bcher-kva")
        let list = try #require(PublicSuffix.shared)
        #expect(list.isPublicSuffix("xn--55qx5d.cn") && list.isPublicSuffix("公司.cn"))
        #expect(list.registrableDomain("www.例子.公司.cn") == "xn--fsqu00a.xn--55qx5d.cn")
        #expect(list.registrableDomain("www.xn--fsqu00a.xn--55qx5d.cn") == "xn--fsqu00a.xn--55qx5d.cn")
    }

    @Test func addressesAndOneLabelNamesHaveNoRegistrableDomain() throws {
        let list = try #require(PublicSuffix.shared)
        #expect(list.registrableDomain("10.0.0.1") == nil && list.registrableDomain("localhost") == nil && list.registrableDomain("::1") == nil)
        #expect(list.registrableDomain("WWW.Example.COM.") == "example.com")
    }

    @Test func aRuleListIsParsedByTheSpec() {
        let list = PublicSuffix(list: "// comment\ncom\n*.jp\n!metro.jp\n\nuk extra-text\n")
        #expect(list.registrableDomain("a.example.com") == "example.com")
        #expect(list.registrableDomain("a.b.foo.jp") == "b.foo.jp" && list.registrableDomain("a.metro.jp") == "metro.jp")
        #expect(list.registrableDomain("a.bbc.uk") == "bbc.uk")
    }
}

extension SharedAgentState {
/// The menu under a focused field, in a real page. With the key button's tests, as both set `Tab.loginAccounts`.
@MainActor
struct LoginFieldMenuTests {
    private static let form = """
        <body style="margin:0"><form>
        <input id=u style="position:absolute;left:40px;top:100px;width:200px;height:20px;border:0;padding:0">
        <input id=p type=password style="position:absolute;left:40px;top:140px">
        <input id=q type=search style="position:absolute;left:40px;top:180px">
        </form></body>
        """

    private final class Lookups { var keys: [String] = [] }

    /// Accounts for www.site.test, and a panel that may show though the test's window is never key.
    private func withAccounts(_ body: (Lookups) async throws -> Void) async rethrows {
        let before = Changmun.Tab.loginAccounts, showable = LoginFieldMenu.showable
        let lookups = Lookups()
        Changmun.Tab.loginAccounts = { key in
            await MainActor.run { lookups.keys.append(key) }
            return key == "www.site.test" ? [Logins.Match(host: key, username: "carol", sameHost: true), Logins.Match(host: "accounts.site.test", username: "alice", sameHost: false)] : []
        }
        LoginFieldMenu.showable = { _, _ in true }
        defer {
            Changmun.Tab.loginAccounts = before
            LoginFieldMenu.showable = showable
        }
        try await body(lookups)
    }

    private func page(in b: Browser, base: String = "https://www.site.test/login", zoom: CGFloat = 1) async -> (Changmun.Tab, WKWebView, NSWindow) {
        let tab = b.openTab(url: nil)
        let view = tab.wake()
        let window = OffscreenWindow(view)
        view.loadHTMLString(Self.form, baseURL: URL(string: base))
        _ = await waitUntil(5) { !view.isLoading && view.url != nil }
        // After the load: a page's commit sets the zoom kept for its site.
        view.pageZoom = zoom
        return (tab, view, window)
    }

    private func load(_ base: String, in view: WKWebView) async {
        await load(Self.form, at: base, in: view)
    }

    private func load(_ html: String, at base: String, in view: WKWebView) async {
        view.loadHTMLString(html, baseURL: URL(string: base))
        _ = await waitUntil(5) { !view.isLoading && view.url?.absoluteString == base }
    }

    private func focus(_ id: String, in view: WKWebView) async throws {
        _ = try await view.evaluateJavaScript("document.getElementById('\(id)').focus(); true")
    }

    private func key(_ code: UInt16, _ characters: String, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    /// Long enough for a message from the page to have come, when none is expected.
    private func settle(_ view: WKWebView) async {
        for _ in 0..<3 { _ = try? await view.evaluateJavaScript("1") }
        try? await Task.sleep(for: .milliseconds(200))
    }

    @Test func aFocusedSignInFieldGetsTheMenuUnderItAndThePageLearnsNothingOfTheAccounts() async throws {
        try await withAccounts { lookups in
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let (tab, view, window) = await page(in: b, zoom: 1.5)
            defer { window.close() }
            try await focus("u", in: view)
            #expect(await waitUntil(5) { tab.loginMenu.shown != nil }, "no menu came for the user name field")
            let shown = try #require(tab.loginMenu.shown)
            #expect(shown.matches.map(\.title) == ["carol", "alice — accounts.site.test"])
            #expect(shown.fieldRect == CGRect(x: 60, y: 150, width: 300, height: 30), "the field's place at 150 %: \(shown.fieldRect)")
            let panel = try #require(tab.loginMenu.panel)
            #expect(!panel.canBecomeKey && !panel.canBecomeMain, "the field keeps the keyboard")
            #expect(panel.parent === window && panel.frame.maxY - LoginFieldMenu.shadowRoom <= window.convertToScreen(view.convert(shown.fieldRect, to: nil)).minY)
            let html = try await view.evaluateJavaScript("document.documentElement.outerHTML + JSON.stringify(Object.keys(window))") as? String ?? ""
            #expect(!html.contains("alice") && !html.contains("carol") && !html.contains("accounts.site.test"), "nothing of the accounts is in the page")

            // A move of the field uses what was looked up: the keychain is not asked again for the page.
            let asked = lookups.keys.count
            for dy in [0.0, 1, 2, 3] { tab.loginMenu.fieldFocused(shown.field, at: CGRect(x: 40, y: 100 + dy, width: 200, height: 20), document: shown.origin, reason: .move) }
            await settle(view)
            #expect(tab.loginMenu.shown != nil && lookups.keys.count == asked)

            // A search box is no sign-in field; leaving the field only hides the menu, and the password field is offered it in turn.
            try await focus("q", in: view)
            #expect(await waitUntil(5) { tab.loginMenu.shown == nil })
            try await focus("p", in: view)
            #expect(await waitUntil(5) { tab.loginMenu.shown != nil && tab.loginMenu.shown?.field != shown.field })
            // Esc puts it away until the user clicks a field: a scroll or a focus (which a page can make) doesn't bring it back.
            tab.loginMenu.handle(try key(53, "\u{1b}", in: window))
            #expect(tab.loginMenu.shown == nil && tab.loginMenu.clickOnly)
            tab.loginMenu.fieldFocused(shown.field, at: CGRect(x: 40, y: 100, width: 200, height: 20), document: shown.origin, reason: .move)
            #expect(tab.loginMenu.shown == nil, "a scroll doesn't bring it back")
            try await focus("q", in: view)
            try await focus("u", in: view)
            await settle(view)
            try? await Task.sleep(for: .seconds(1))
            #expect(tab.loginMenu.shown == nil, "nor does a focus")
            tab.loginMenu.fieldFocused(shown.field, at: CGRect(x: 40, y: 100, width: 200, height: 20), document: shown.origin, reason: .click)
            #expect(await waitUntil(5) { tab.loginMenu.shown?.field == shown.field }, "the user's click on the field does")

            // Typing puts it away for the field while it has text; emptied, a focus offers it again.
            _ = try await view.evaluateJavaScript("const u = document.getElementById('u'); u.value = 'me'; u.dispatchEvent(new Event('input', {bubbles: true})); true")
            #expect(await waitUntil(5) { tab.loginMenu.shown == nil })
            try await focus("q", in: view)
            try await focus("u", in: view)
            await settle(view)
            try? await Task.sleep(for: .seconds(1))
            #expect(tab.loginMenu.shown == nil, "the field has text the user typed")
            _ = try await view.evaluateJavaScript("document.getElementById('u').value = ''; true")
            try await focus("q", in: view)
            try await focus("u", in: view)
            #expect(await waitUntil(5) { tab.loginMenu.shown?.field == shown.field }, "emptied, it is offered again")
            // Another page starts again.
            await load("https://www.site.test/again", in: view)
            try await focus("u", in: view)
            #expect(await waitUntil(5) { tab.loginMenu.shown != nil }, "a new page's field is offered")
        }
    }

    @Test func aClickCountsOnlyOnceThePointerCameInAndThePanelStayedPutForAMoment() async throws {
        #expect(LoginFieldMenu.Hosting.trackingOptions.contains(.mouseEnteredAndExited) && !LoginFieldMenu.Hosting.trackingOptions.contains(.assumeInside),
                "a pointer already there when the panel appears gets no mouseEntered")
        #expect(LoginFieldMenu.clickDelay == 0.4)
        try await withAccounts { _ in
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let (tab, view, window) = await page(in: b)
            defer { window.close() }
            var clock = Date(timeIntervalSince1970: 1_000)
            var filled: [String] = []
            tab.loginMenu.now = { clock }
            tab.loginMenu.fill = { filled.append($0.username) }
            try await focus("u", in: view)
            #expect(await waitUntil(5) { tab.loginMenu.shown != nil })
            let shown = try #require(tab.loginMenu.shown)
            let carol = shown.matches[0]

            clock.addTimeInterval(1)
            tab.loginMenu.choose(carol)
            #expect(filled.isEmpty && tab.loginMenu.shown != nil, "the pointer never came into the panel (it may have been there all along)")
            tab.loginMenu.pointerDidEnter()
            #expect(tab.loginMenu.clickCounts)

            // A small move keeps it; a move further, as a page moving its field under the pointer would make, starts over.
            tab.loginMenu.fieldFocused(shown.field, at: CGRect(x: 42, y: 101, width: 200, height: 20), document: shown.origin, reason: .move)
            #expect(tab.loginMenu.clickCounts)
            tab.loginMenu.fieldFocused(shown.field, at: CGRect(x: 40, y: 140, width: 200, height: 20), document: shown.origin, reason: .move)
            #expect(!tab.loginMenu.clickCounts)
            tab.loginMenu.pointerDidEnter()
            #expect(!tab.loginMenu.clickCounts, "and waits again")
            clock.addTimeInterval(LoginFieldMenu.clickDelay + 0.01)
            #expect(tab.loginMenu.clickCounts)
            // Out of the page's view and back is appearing anew too.
            tab.loginMenu.fieldFocused(shown.field, at: CGRect(x: 40, y: 5_000, width: 200, height: 20), document: shown.origin, reason: .move)
            tab.loginMenu.fieldFocused(shown.field, at: CGRect(x: 40, y: 140, width: 200, height: 20), document: shown.origin, reason: .move)
            #expect(!tab.loginMenu.clickCounts)
            tab.loginMenu.pointerDidEnter()
            clock.addTimeInterval(LoginFieldMenu.clickDelay + 0.01)
            tab.loginMenu.choose(carol)
            #expect(filled == ["carol"] && tab.loginMenu.shown == nil)
        }
    }

    @Test func leavingTheFieldOnlyHidesItAndItComesBackAtMostOnceASecondAPageWithTheGuardStartedOver() async throws {
        try await withAccounts { _ in
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let (tab, view, window) = await page(in: b)
            defer { window.close() }
            var clock = Date(timeIntervalSince1970: 1_000)
            tab.loginMenu.now = { clock }
            try await focus("u", in: view)
            #expect(await waitUntil(5) { tab.loginMenu.shown != nil })
            let field = try #require(tab.loginMenu.shown?.field)
            let site = try #require(tab.loginMenu.shown?.origin)
            let here = CGRect(x: 40, y: 100, width: 200, height: 20), there = CGRect(x: 300, y: 400, width: 200, height: 20)
            tab.loginMenu.pointerDidEnter()
            clock.addTimeInterval(1)
            #expect(tab.loginMenu.clickCounts)

            // Tab moves on: hidden.
            tab.loginMenu.handle(try key(48, "\t", in: window))
            #expect(tab.loginMenu.shown == nil)
            tab.loginMenu.fieldFocused(field, at: here, document: site, reason: .focus)
            #expect(tab.loginMenu.shown != nil, "a second after it last appeared, the field gets it again")
            #expect(!tab.loginMenu.clickCounts, "with the guard started over")
            // A page blurring and focusing its field to make the menu jump: once a second at most, and each time guarded anew.
            clock.addTimeInterval(0.3)
            tab.loginMenu.fieldLeft(field)
            tab.loginMenu.fieldFocused(field, at: there, document: site, reason: .focus)
            #expect(tab.loginMenu.shown == nil, "not again within a second")
            tab.loginMenu.fieldFocused(field + 100, at: there, document: site, reason: .click)
            #expect(tab.loginMenu.shown == nil, "nor for a field drawn anew: once a second for the page")
            clock.addTimeInterval(0.8)
            tab.loginMenu.fieldFocused(field, at: there, document: site, reason: .focus)
            #expect(tab.loginMenu.shown != nil && !tab.loginMenu.clickCounts)
            tab.loginMenu.pointerDidEnter()
            clock.addTimeInterval(LoginFieldMenu.clickDelay + 0.01)
            #expect(tab.loginMenu.clickCounts)

            // A key hides it; a move doesn't bring it back, a focus or a click does (nothing is locked for the page).
            tab.loginMenu.handle(try key(0, "a", in: window))
            #expect(tab.loginMenu.shown == nil)
            clock.addTimeInterval(5)
            tab.loginMenu.fieldFocused(field, at: here, document: site, reason: .move)
            #expect(tab.loginMenu.shown == nil)
            tab.loginMenu.fieldFocused(field, at: here, document: site, reason: .click)
            #expect(tab.loginMenu.shown != nil && !tab.loginMenu.clickCounts)

            // Waiting to come back, Esc calls it off.
            tab.loginMenu.fieldLeft(field)
            clock.addTimeInterval(0.2)
            tab.loginMenu.fieldFocused(field, at: here, document: site, reason: .focus)
            #expect(tab.loginMenu.shown == nil)
            tab.loginMenu.handle(try key(53, "\u{1b}", in: window))
            try? await Task.sleep(for: .seconds(1.2))
            clock.addTimeInterval(1)
            #expect(tab.loginMenu.shown == nil, "the wait was called off")
        }
    }

    @Test func aPageFocusingItsFieldOverAndOverGetsTheMenuFiveTimesAMinuteThenOnlyOnAClick() async throws {
        try await withAccounts { _ in
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let (tab, view, window) = await page(in: b)
            defer { window.close() }
            var clock = Date(timeIntervalSince1970: 1_000)
            tab.loginMenu.now = { clock }
            try await focus("u", in: view)
            #expect(await waitUntil(5) { tab.loginMenu.shown != nil })
            let field = try #require(tab.loginMenu.shown?.field), site = try #require(tab.loginMenu.shown?.origin)
            let here = CGRect(x: 40, y: 100, width: 200, height: 20)
            for _ in 1..<LoginFieldMenu.focusShowsPerMinute {
                tab.loginMenu.fieldLeft(field)
                clock.addTimeInterval(1.1)
                tab.loginMenu.fieldFocused(field, at: here, document: site, reason: .focus)
                #expect(tab.loginMenu.shown != nil)
            }
            tab.loginMenu.fieldLeft(field)
            clock.addTimeInterval(1.1)
            tab.loginMenu.fieldFocused(field, at: here, document: site, reason: .focus)
            #expect(tab.loginMenu.shown == nil, "a sixth focus within the minute")
            tab.loginMenu.fieldFocused(field, at: here, document: site, reason: .click)
            #expect(tab.loginMenu.shown != nil, "a click still does")
            tab.loginMenu.fieldLeft(field)
            clock.addTimeInterval(61)
            tab.loginMenu.fieldFocused(field, at: here, document: site, reason: .focus)
            #expect(tab.loginMenu.shown != nil, "and a minute later a focus again")
        }
    }

    @Test func aPanelShownOrMovedUnderThePointerTakesNoClickUntilThePointerLeavesAndComesBack() async throws {
        try await withAccounts { _ in
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let (tab, view, window) = await page(in: b)
            defer { window.close() }
            var clock = Date(timeIntervalSince1970: 1_000)
            let menu = tab.loginMenu
            menu.now = { clock }
            // The pointer stands in the middle of wherever the panel is.
            menu.mouseLocation = { [weak menu] in menu?.panel.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero }
            try await focus("u", in: view)
            #expect(await waitUntil(5) { menu.shown != nil })
            let shown = try #require(menu.shown)
            clock.addTimeInterval(1)
            menu.pointerDidEnter()
            #expect(!menu.clickCounts, "it came up under the pointer")
            menu.pointerDidExit()
            menu.pointerDidEnter()
            clock.addTimeInterval(1)
            #expect(menu.clickCounts, "out and back in")
            // Scrolled under the still pointer: the same again.
            menu.fieldFocused(shown.field, at: CGRect(x: 40, y: 160, width: 200, height: 20), document: shown.origin, reason: .move)
            clock.addTimeInterval(1)
            menu.pointerDidEnter()
            #expect(!menu.clickCounts)
            menu.pointerDidExit()
            menu.pointerDidEnter()
            clock.addTimeInterval(1)
            #expect(menu.clickCounts)
            // A pointer elsewhere when it appears: the first time it comes in counts.
            menu.mouseLocation = { NSPoint(x: -100_000, y: -100_000) }
            menu.fieldFocused(shown.field, at: CGRect(x: 40, y: 220, width: 200, height: 20), document: shown.origin, reason: .move)
            menu.pointerDidEnter()
            #expect(!menu.clickCounts, "not before the delay")
            clock.addTimeInterval(LoginFieldMenu.clickDelay + 0.01)
            #expect(menu.clickCounts)
        }
    }

    /// A page that sends itself to another site's address that never answers is still the page on screen, though `webView.url` already
    /// names the other site: nothing of that site's is offered or filled into it, by the menu or the key button.
    @Test func aPageOnItsWayToAnotherSiteThatNeverAnswersIsOfferedAndFilledNothing() async throws {
        let server = try await SilentServer()
        defer { server.stop() }
        try await withAccounts { lookups in
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let (tab, view, window) = await page(in: b)
            defer { window.close() }
            let bank = "https://localhost:\(server.port)/bank"
            _ = try await view.evaluateJavaScript("location.href = '\(bank)'; true")
            #expect(await waitUntil(10) { view.url?.absoluteString == bank && tab.isLoadingProvisionally }, "\(String(describing: view.url))")
            #expect(try await view.evaluateJavaScript("location.origin") as? String == "https://www.site.test", "the old page is still the one on screen")

            try await focus("p", in: view)
            await settle(view)
            #expect(tab.loginMenu.shown == nil && tab.loginMenu.panel == nil, "no menu while a navigation is under way")
            #expect(!lookups.keys.contains { $0.hasPrefix("localhost") }, "the address being gone to is never asked for: \(lookups.keys)")

            let noQuestion = FillAuthorization(required: { false }, confirm: { _ in false })
            var reads = 0
            tab.fillLogin(username: "me", authorization: noQuestion) { _, _ in reads += 1; return "bank password" }
            tab.fillLogin(username: "me", savedUnder: "localhost:\(server.port)", authorization: noQuestion) { _, _ in reads += 1; return "bank password" }
            await settle(view)
            #expect(reads == 0, "nothing is read for the key button either")

            // And the script that fills checks for itself where it is.
            let filled = try await view.callAsyncJavaScript(Logins.fillScript, arguments: ["username": "me", "password": "bank password", "origin": "https://localhost:\(server.port)", "field": 0],
                                                            in: nil, contentWorld: .defaultClient)
            #expect(filled as? Bool == false)
            #expect(try await view.evaluateJavaScript("document.getElementById('p').value") as? String == "")
            view.stopLoading()
        }
    }

    // MARK: Which fields are sign-in fields

    /// Markup as the sites have it (trimmed): Google's and Microsoft's first steps, a Korean site's ID field with no autocomplete, a
    /// search box, a sign-up form.
    static let google = """
        <form><div><input type=text name=identifier id=identifierId autocomplete="username webauthn" aria-label="Email or phone"></div>
        <input type=password name=hiddenPassword tabindex=-1 aria-hidden=true style="position:absolute;opacity:0;width:1px;height:1px">
        <button type=button>Next</button></form>
        """
    static let microsoft = """
        <form><input type=email name=loginfmt id=i0116 maxlength=113 aria-label="Email, phone, or Skype">
        <input name=passwd type=password id=i0118 style="display:none"><input type=submit value=Next></form>
        """
    static let korean = """
        <form role=search action=/search><input type=text name=query id=query title="검색어 입력"></form>
        <form name=loginForm action=/login><input type=text name=memId id=memId maxlength=20><button>다음</button></form>
        """
    static let searchOnly = """
        <form action=/s><input type=text name=q id=q placeholder="Search"></form><input type=search id=s><input id=kw name=keyword>
        <div role=search><input type=text id=box name=box></div>
        """
    static let signUp = """
        <form><input type=text name=userId id=userId><input type=email name=email id=email>
        <input type=password id=np autocomplete=new-password><input type=password id=np2 autocomplete=new-password></form>
        """

    /// The password and user name fields `Logins.fieldFinder` picks on a page, by id.
    private func picked(_ view: WKWebView) async throws -> [String] {
        let found = try await view.callAsyncJavaScript(Logins.fieldFinder + "const d = e => e ? (e.id || 'name=' + e.name) : ''; const f = loginFields(); return [d(f.pw), d(f.user)];",
                                                       in: nil, contentWorld: .defaultClient)
        return found as? [String] ?? []
    }

    @Test(arguments: [
        (google, "identifierId", true), (microsoft, "i0116", true), (korean, "memId", true),
        (searchOnly, "", false), (signUp, "", false),
    ])
    func theSignInFieldIsFoundAsTheSitesDrawIt(html: String, user: String, offered: Bool) async throws {
        try await withAccounts { _ in
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let tab = b.openTab(url: nil)
            let view = tab.wake()
            let window = OffscreenWindow(view)
            defer { window.close() }
            await load(html, at: "https://www.site.test/login", in: view)
            let found = try await picked(view)
            #expect(found.last == user, "\(found)")
            if html == Self.google { #expect(found.first == "", "the hidden password field Google keeps is not shown, so not taken: \(found)") }
            // The key button goes by the same fields.
            if offered {
                #expect(await waitUntil(5) { !tab.savedLogins.isEmpty }, "no key button")
                try await focus(user, in: view)
                #expect(await waitUntil(5) { tab.loginMenu.shown != nil }, "no menu under \(user)")
                // And the fill goes into it.
                _ = try await view.callAsyncJavaScript(Logins.fillScript, arguments: ["username": "me@example.com", "password": "pw", "origin": "https://www.site.test", "field": 0],
                                                       in: nil, contentWorld: .defaultClient)
                #expect(try await view.evaluateJavaScript("document.getElementById('\(user)').value") as? String == "me@example.com")
            } else {
                for id in ["q", "s", "kw", "box", "userId", "email", "np"] {
                    _ = try? await view.evaluateJavaScript("(document.getElementById('\(id)') || {focus() {}}).focus(); true")
                }
                await settle(view)
                #expect(tab.loginMenu.shown == nil && tab.savedLogins.isEmpty)
            }
        }
    }

    /// The reviewer's markups, and names that are or aren't an account: [password field, user name field] as the finder picks them.
    @Test(arguments: [
        ("<form><input type=email id=em name=email><input type=password id=np autocomplete=new-password><input type=password id=cf name=confirm></form>", "", ""),
        ("<form action=/login><input type=password id=pw name=pw></form><footer><form action=/sub><input type=email id=news name=email autocomplete=email></form></footer>", "pw", ""),
        ("<div><input type=text id=user name=username><input type=password id=pw name=password></div><div style=\"display:none\"><input type=text id=ru name=ruser><input type=password id=rp autocomplete=new-password></div>", "pw", "user"),
        ("<header><input type=email id=news autocomplete=email placeholder=Newsletter></header><form><input type=text id=login name=login autocomplete=username><button>Next</button></form>", "", "login"),
        ("<form><input type=text id=c name=coupon_id></form>", "", ""),
        ("<form><input type=text id=v name=video_id></form>", "", ""),
        ("<form><input type=text id=acct name=accountNo><input type=number name=amount></form>", "", ""),
        ("<form><input type=text id=an name=account_number></form>", "", ""),
        ("<form action=/><input type=text id=s name=s></form><input type=password id=pw>", "pw", ""),
        ("<form><input type=text id=f1 name=id></form>", "", "f1"),
        ("<form><input type=text id=f2 name=memId></form>", "", "f2"),
        ("<form><input type=text id=f3 name=userId></form>", "", "f3"),
        ("<form><input type=text id=f4 name=loginId></form>", "", "f4"),
        ("<form><input type=text id=f5 name=account_id></form>", "", "f5"),
        ("<form><input type=password id=a style=\"visibility:hidden\"><input type=password id=b style=\"position:absolute;left:-9999px\"><div style=\"opacity:0\"><input type=password id=c></div><input type=password id=d style=\"width:2px;height:2px;padding:0;border:0\"></form>", "", ""),
        ("<div><input type=text id=su name=email><input type=password id=snp autocomplete=new-password><input type=password id=scf></div><div><input type=text id=lu name=username><input type=password id=lp></div>", "lp", "lu"),
    ])
    func theFinderPicksTheSignInFieldsOnly(html: String, pw: String, user: String) async throws {
        let b = Browser()
        b.focused()
        defer { b.windowClosed() }
        let tab = b.openTab(url: nil)
        let view = tab.wake()
        let window = OffscreenWindow(view)
        defer { window.close() }
        await load(html, at: "https://www.site.test/login", in: view)
        #expect(try await picked(view) == [pw, user])
    }

    @Test func theFillGoesToTheFieldTheMenuWasOfferedUnderOrNowhere() async throws {
        try await withAccounts { _ in
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let (tab, view, window) = await page(in: b)
            defer { window.close() }
            try await focus("u", in: view)
            #expect(await waitUntil(5) { tab.loginMenu.shown != nil })
            let field = try #require(tab.loginMenu.shown?.field)
            func fill(_ field: Int) async throws -> Bool {
                try await view.callAsyncJavaScript(Logins.fillScript, arguments: ["username": "me", "password": "pw", "origin": "https://www.site.test", "field": field],
                                                   in: nil, contentWorld: .defaultClient) as? Bool == true
            }
            #expect(try await fill(field))
            #expect(try await view.evaluateJavaScript("document.getElementById('u').value") as? String == "me")
            // The field drawn anew (as a page swapping it out from under the menu would): the old one is gone, so nothing is filled.
            _ = try await view.evaluateJavaScript("const u = document.getElementById('u'); const n = u.cloneNode(); n.value = ''; u.replaceWith(n); document.getElementById('p').value = ''; true")
            #expect(try await fill(field) == false)
            #expect(try await view.evaluateJavaScript("document.getElementById('p').value") as? String == "")
            #expect(try await fill(0), "the key button's fill, offered under no field")
        }
    }

    @Test func thePagesOwnScrollAndFocusEventsMoveNothing() async throws {
        try await withAccounts { _ in
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let (tab, view, window) = await page(in: b)
            defer { window.close() }
            // A focus the page only dispatches is no focus.
            _ = try await view.evaluateJavaScript("document.getElementById('u').dispatchEvent(new FocusEvent('focusin', {bubbles: true})); true")
            await settle(view)
            #expect(tab.loginMenu.shown == nil)
            try await focus("u", in: view)
            #expect(await waitUntil(5) { tab.loginMenu.shown != nil })
            let before = try #require(tab.loginMenu.shown?.fieldRect)
            _ = try await view.evaluateJavaScript("""
                document.getElementById('u').style.top = '300px';
                window.dispatchEvent(new Event('scroll')); window.dispatchEvent(new Event('resize'));
                window.visualViewport && window.visualViewport.dispatchEvent(new Event('scroll')); true
                """)
            await settle(view)
            #expect(tab.loginMenu.shown?.fieldRect == before, "the panel stays where it appeared")
        }
    }

    @Test(arguments: [true, false])
    func aPrivateWindowGetsTheMenuAndASiteWithNothingSavedDoesNot(isPrivate: Bool) async throws {
        try await withAccounts { lookups in
            let b = Browser(isPrivate: isPrivate)
            b.focused()
            defer { b.windowClosed() }
            let (tab, view, window) = await page(in: b, base: isPrivate ? "https://www.site.test/login" : "https://nothing.test/login")
            defer { window.close() }
            try await focus("u", in: view)
            if isPrivate {
                #expect(await waitUntil(5) { tab.loginMenu.shown != nil }, "as the key button does")
            } else {
                await settle(view)
                #expect(tab.loginMenu.shown == nil && tab.loginMenu.panel == nil)
                let asked = lookups.keys.count
                for dy in [1.0, 2, 3] { tab.loginMenu.fieldFocused(1, at: CGRect(x: 40, y: 100 + dy, width: 200, height: 20), document: Changmun.Tab.Origin(host: "nothing.test", port: 443), reason: .focus) }
                try await focus("p", in: view)
                await settle(view)
                #expect(lookups.keys.count == asked && Set(lookups.keys) == ["nothing.test"], "nothing saved is remembered for the page too")
            }
        }
    }

    @Test func noPanelForATabHeldBehindOrAWindowThatIsNotKey() async throws {
        try await withAccounts { _ in
            LoginFieldMenu.showable = { LoginFieldMenu.isShowable(tab: $0, webView: $1) }
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let (tab, view, window) = await page(in: b)
            defer { window.close() }
            try await focus("u", in: view)
            await settle(view)
            #expect(!window.isKeyWindow && tab.loginMenu.shown == nil, "a window that isn't key")
            _ = b.openTab(url: nil)
            #expect(tab.isInBackground && !LoginFieldMenu.isShowable(tab: tab, webView: view), "a tab that isn't the one shown")
            // A page held behind the one shown (PassiveHost) is in the window but drawn at alpha 0.
            let holder = NSView(frame: window.contentView!.bounds)
            holder.alphaValue = 0
            window.contentView!.addSubview(holder)
            holder.addSubview(view)
            #expect(!LoginFieldMenu.isVisible(view))
            holder.alphaValue = 1
            #expect(LoginFieldMenu.isVisible(view))
        }
    }
}
}

extension SharedAgentState {
@MainActor
struct LoginFillAcrossHostsTests {
    @Test func aLoginOfAnotherHostIsFilledOnlyWhereItsSiteIs() async throws {
        let before = Changmun.Tab.loginAccounts
        Changmun.Tab.loginAccounts = { _ in [] }
        defer { Changmun.Tab.loginAccounts = before }
        let b = Browser()
        b.focused()
        defer { b.windowClosed() }
        let tab = b.openTab(url: nil)
        let view = tab.wake()
        let window = OffscreenWindow(view)
        defer { window.close() }
        view.loadHTMLString("<form><input id=u><input id=p type=password></form>", baseURL: URL(string: "https://www.site.test/login"))
        _ = await waitUntil(5) { !view.isLoading && view.url != nil }
        let noQuestion = FillAuthorization(required: { false }, confirm: { _ in false })
        var reads: [String] = []
        tab.fillLogin(username: "eve", savedUnder: "evil.test", authorization: noQuestion) { host, _ in reads.append(host); return "stolen" }
        tab.fillLogin(username: "eve", savedUnder: "accounts.site.test:8443", authorization: noQuestion) { host, _ in reads.append(host); return "other port" }
        tab.fillLogin(username: "alice", savedUnder: "accounts.site.test", authorization: noQuestion) { host, _ in reads.append(host); return "secret" }
        #expect(await waitUntil(10) { reads == ["accounts.site.test"] }, "\(reads)")
        var filled = ""
        let end = Date().addingTimeInterval(10)
        while filled != "secret", Date() < end {
            filled = ((try? await view.evaluateJavaScript("document.getElementById('p').value")) as? String) ?? ""
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(filled == "secret", "the other host's login of the same site was filled")
    }
}
}

/// Takes connections on the loopback address and never answers: a navigation to it stays provisional.
final class SilentServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var held: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init() async throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.lock.withLock { self?.held.append(connection) }
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let once = NSLock()
            var done = false
            listener.stateUpdateHandler = { [weak self] state in
                once.lock(); defer { once.unlock() }
                guard !done else { return }
                switch state {
                case .ready: done = true; continuation.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error): done = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { held.forEach { $0.cancel() } }
    }
}
