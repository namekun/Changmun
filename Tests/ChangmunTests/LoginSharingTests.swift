import AppKit
import Foundation
import Testing
import WebKit
@testable import Changmun

/// Logins saved for one host of a site are offered on its other hosts, but not across a shared hosting platform, a port or a private
/// window, and never to the AI. Everything here runs on an in-memory keychain or a stand-in for it.
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

    @Test func aSharedHostingPlatformKeepsEachSubdomainApart() {
        let required = ["github.io", "gitlab.io", "herokuapp.com", "vercel.app", "netlify.app", "pages.dev", "workers.dev", "web.app", "firebaseapp.com",
                        "appspot.com", "blogspot.com", "azurewebsites.net", "cloudfront.net", "amazonaws.com", "fly.dev", "onrender.com", "glitch.me",
                        "repl.co", "ngrok.io", "ngrok-free.app", "tistory.com", "wordpress.com", "wixsite.com", "notion.site"]
        #expect(Set(required).isSubset(of: Logins.sharedHostingDomains))
        for domain in Logins.sharedHostingDomains {
            #expect(!Logins.mayShare("alice.\(domain)", with: "bob.\(domain)"), "\(domain)")
            #expect(!Logins.mayShare(domain, with: "bob.\(domain)") && !Logins.mayShare("alice.\(domain)", with: domain), "\(domain)")
        }
        #expect(!Logins.mayShare("bucket.s3.amazonaws.com", with: "other.s3.amazonaws.com"))
        with([("alice.github.io", "alice"), ("bob.github.io", "bob")]) {
            #expect(Logins.matches(for: "bob.github.io").map(\.title) == ["bob"], "only the exact host's own")
            #expect(Logins.matches(for: "mallory.github.io").isEmpty)
        }
    }

    @Test func aSiteIsItsRegistrableDomainWithTwoLevelSuffixesKnown() {
        #expect(Logins.mayShare("mail.naver.co.kr", with: "www.naver.co.kr"))
        #expect(Logins.mayShare("naver.co.kr", with: "nid.naver.co.kr"))
        #expect(!Logins.mayShare("naver.co.kr", with: "daum.co.kr"), "co.kr is a suffix, not a site")
        #expect(Logins.mayShare("shop.example.co.uk", with: "example.co.uk"))
        #expect(!Logins.mayShare("alice.com.pl", with: "bob.com.pl"), "a suffix the list doesn't know is not taken for a site")
        #expect(!Logins.mayShare("a.example.com", with: "a.example.org"))
        #expect(!Logins.mayShare("example.com", with: "notexample.com"))
        #expect(!Logins.mayShare("example.com.evil.test", with: "example.com"))
        #expect(Logins.mayShare("Accounts.Example.com", with: "www.example.com"), "names are compared in lower case")
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

    @Test func theMenuIsOfferedOnlyOnHttpsPagesOutsidePrivateWindowsAndWithAccounts() throws {
        let page = try #require(URL(string: "https://www.example.com/login"))
        let some: (String) -> [Logins.Match] = { [Logins.Match(host: $0, username: "me", sameHost: true)] }
        #expect(LoginFieldMenu.offers(url: page, isPrivate: false, isUnverified: false, accounts: some).map(\.username) == ["me"])
        #expect(LoginFieldMenu.offers(url: page, isPrivate: true, isUnverified: false, accounts: some).isEmpty, "never in a private window")
        #expect(LoginFieldMenu.offers(url: page, isPrivate: false, isUnverified: true, accounts: some).isEmpty, "not on an unverified page")
        #expect(LoginFieldMenu.offers(url: URL(string: "http://www.example.com/login"), isPrivate: false, isUnverified: false, accounts: some).isEmpty, "never on http")
        #expect(LoginFieldMenu.offers(url: page, isPrivate: false, isUnverified: false, accounts: { _ in [] }).isEmpty, "nothing saved, no menu")
        var asked: [String] = []
        _ = LoginFieldMenu.offers(url: URL(string: "https://www.example.com:8443/"), isPrivate: false, isUnverified: false) { asked.append($0); return [] }
        #expect(asked == ["www.example.com:8443"], "asked by the page's key, port and all")
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

    @Test func aFieldsRectIsScaledByThePagesZoomAndTurnedOverWhenTheViewIsNot() {
        let css = CGRect(x: 40, y: 100, width: 200, height: 20)
        #expect(LoginFieldMenu.viewRect(css, zoom: 1.5, flipped: true, height: 600) == CGRect(x: 60, y: 150, width: 300, height: 30))
        #expect(LoginFieldMenu.viewRect(css, zoom: 1, flipped: false, height: 600) == CGRect(x: 40, y: 480, width: 200, height: 20))
    }

    @Test func theMenuGoesUnderTheFieldOrOverItWhenTheScreenEndsBelow() {
        let room = LoginFieldMenu.shadowRoom, gap = Metrics.rowGap, size = CGSize(width: 232, height: 100)
        let field = CGRect(x: 300, y: 500, width: 200, height: 24)
        let under = LoginFieldMenu.panelFrame(field: field, size: size, screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(under.minX + room == field.minX && under.maxY - room == field.minY - gap, "the list's top left just under the field's bottom left")
        let low = CGRect(x: 300, y: 40, width: 200, height: 24)
        let over = LoginFieldMenu.panelFrame(field: low, size: size, screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(over.minY + room == low.maxY + gap, "over the field when there is no room under it")
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

    private func withAccounts(_ body: () async throws -> Void) async rethrows {
        let before = Changmun.Tab.loginAccounts
        Changmun.Tab.loginAccounts = { key in
            key == "www.site.test" ? [Logins.Match(host: key, username: "carol", sameHost: true), Logins.Match(host: "accounts.site.test", username: "alice", sameHost: false)] : []
        }
        defer { Changmun.Tab.loginAccounts = before }
        try await body()
    }

    private func page(in b: Browser, zoom: CGFloat = 1) async -> (Changmun.Tab, WKWebView, NSWindow) {
        let tab = b.openTab(url: nil)
        let view = tab.wake()
        let window = OffscreenWindow(view)
        view.loadHTMLString(Self.form, baseURL: URL(string: "https://www.site.test/login"))
        _ = await waitUntil(5) { !view.isLoading && view.url != nil }
        // After the load: a page's commit sets the zoom kept for its site.
        view.pageZoom = zoom
        return (tab, view, window)
    }

    private func focus(_ id: String, in view: WKWebView) async throws {
        _ = try await view.evaluateJavaScript("document.getElementById('\(id)').focus(); true")
    }

    /// Long enough for a message from the page to have come, when none is expected.
    private func settle(_ view: WKWebView) async {
        for _ in 0..<3 { _ = try? await view.evaluateJavaScript("1") }
        try? await Task.sleep(for: .milliseconds(200))
    }

    @Test func aFocusedSignInFieldGetsTheMenuUnderItAndThePageLearnsNothingOfTheAccounts() async throws {
        try await withAccounts {
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
            tab.loginMenu.choose(shown.matches[0])
            #expect(tab.loginMenu.shown != nil, "a click in the menu's first moment is not taken")

            // A search box is no sign-in field; and the user name field, its menu put away, is not offered again on this page.
            try await focus("q", in: view)
            #expect(await waitUntil(5) { tab.loginMenu.shown == nil })
            try await focus("u", in: view)
            await settle(view)
            #expect(tab.loginMenu.shown == nil, "put away once, not offered again")
            // The password field is another field. Esc puts its menu away too.
            try await focus("p", in: view)
            #expect(await waitUntil(5) { tab.loginMenu.shown != nil })
            tab.loginMenu.dismiss()
            #expect(tab.loginMenu.shown == nil && tab.loginMenu.panel == nil)
            // Another page starts again.
            view.loadHTMLString(Self.form, baseURL: URL(string: "https://www.site.test/again"))
            _ = await waitUntil(5) { !view.isLoading && view.url?.lastPathComponent == "again" }
            try await focus("u", in: view)
            #expect(await waitUntil(5) { tab.loginMenu.shown != nil }, "a new page's field is offered")
        }
    }

    @Test(arguments: [true, false])
    func noMenuInAPrivateWindowOrOnASiteWithNothingSaved(isPrivate: Bool) async throws {
        try await withAccounts {
            let b = Browser(isPrivate: isPrivate)
            b.focused()
            defer { b.windowClosed() }
            let tab = b.openTab(url: nil)
            let view = tab.wake()
            let window = OffscreenWindow(view)
            defer { window.close() }
            view.loadHTMLString(Self.form, baseURL: URL(string: isPrivate ? "https://www.site.test/login" : "https://nothing.test/login"))
            _ = await waitUntil(5) { !view.isLoading && view.url != nil }
            try await focus("u", in: view)
            await settle(view)
            #expect(tab.loginMenu.shown == nil && tab.loginMenu.panel == nil)
        }
    }

    @Test func aLoginOfAnotherHostIsFilledOnlyWhereItsSiteIs() async throws {
        try await withAccounts { try await fillsOnlyWhereItsSiteIs() }
    }

    private func fillsOnlyWhereItsSiteIs() async throws {
        let b = Browser()
        b.focused()
        defer { b.windowClosed() }
        let (tab, view, window) = await page(in: b)
        defer { window.close() }
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
