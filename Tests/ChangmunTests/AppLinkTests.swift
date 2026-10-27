import Foundation
import Testing
import WebKit
@testable import Changmun

extension SharedAgentState {
    /// A page's address for an app (claude://, as a sign-in ends with): the user is asked, whether a click, a redirect or a script
    /// brought it, once per page load; the app is never opened without that, and nothing here asks anyone or opens anything.
    @MainActor @Suite(.serialized)
    struct AppLinkTests {
        private typealias Decision = Tab.AppLinkDecision

        private func decide(_ type: WKNavigationType = .other, userInitiated: Bool = false, mainFrame: Bool = true, asked: Bool = false,
                            headless: Bool = false, agent: Bool = false, blocked: Bool = false, app: Bool = true) -> Decision {
            Tab.appLinkDecision(navigationType: type, userInitiated: userInitiated, isMainFrame: mainFrame, alreadyAskedThisLoad: asked,
                                headless: headless, agentDriven: agent, blocked: blocked, hasApp: app)
        }

        @Test func aRedirectOrScriptToAnAppAsksLikeAClickDoes() {
            #expect(decide(.other) == .ask)
            #expect(decide(.linkActivated, userInitiated: true) == .ask)
            #expect(decide(.linkActivated) == .ask, "a link the page clicked itself is one more redirect: it asks, once")
            #expect(decide(.reload) == .ask)
        }

        @Test func aPageAsksOncePerLoadButTheUsersClicksAlwaysAsk() {
            #expect(decide(.other, asked: true) == .cancelSilently)
            #expect(decide(.linkActivated, asked: true) == .cancelSilently, "a script's click doesn't get past the limit")
            #expect(decide(.linkActivated, userInitiated: true, asked: true) == .ask)
        }

        @Test func framesNobodyClickedStayCancelled() {
            #expect(decide(.other, mainFrame: false) == .cancelSilently)
            #expect(decide(.linkActivated, mainFrame: false) == .cancelSilently)
            #expect(decide(.linkActivated, userInitiated: true, mainFrame: false) == .ask, "a click in a frame asked before, and still does")
        }

        @Test func nothingAsksWhenItMustNotOrCannot() {
            for type in [WKNavigationType.other, .linkActivated] {
                #expect(decide(type, userInitiated: true, headless: true) == .cancelSilently)
                #expect(decide(type, userInitiated: true, agent: true) == .cancelSilently)
                #expect(decide(type, userInitiated: true, blocked: true) == .cancelSilently)
                #expect(decide(type, userInitiated: true, app: false) == .cancelSilently)
            }
        }

        // MARK: What a tab does with it

        private final class Log {
            var asked: [(site: String, app: String, url: String)] = []
            var opened: [URL] = []
            var answer = false
            var app: String? = "Fake App"
        }

        private func tab(_ log: Log, in b: Browser, url: URL? = nil) -> Tab {
            let tab = b.openTab(url: url)
            tab.appLinks = AppLinks(appName: { _ in log.app },
                                    confirm: { site, app, url in log.asked.append((site, app, url.absoluteString)); return log.answer },
                                    open: { log.opened.append($0) })
            return tab
        }

        private func page(_ html: String, in tab: Tab, base: String = "https://login.test/page") async -> (WKWebView, NSWindow) {
            let view = tab.wake()
            let window = OffscreenWindow(view)
            view.loadHTMLString(html, baseURL: URL(string: base))
            _ = await waitUntil(5) { !view.isLoading && view.url != nil }
            return (view, window)
        }

        /// What the page says `script` is, once it is not empty.
        private func eventually(_ script: String, in view: WKWebView) async -> String {
            let end = Date().addingTimeInterval(8)
            var value = ""
            while Date() < end {
                value = ((try? await view.evaluateJavaScript(script)) as? String) ?? ""
                if !value.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return value
        }

        @Test func aScriptsRedirectAsksOnceNamingTheSiteAndTheApp() async throws {
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let log = Log()
            let t = tab(log, in: b)
            let (view, window) = await page("""
                <script>setTimeout(() => { location = 'x-changmun-test://one' }, 50); setTimeout(() => { location = 'x-changmun-test://two' }, 400)</script>
                """, in: t)
            defer { window.close() }
            #expect(await waitUntil { !log.asked.isEmpty })
            try await Task.sleep(for: .milliseconds(900))
            #expect(log.asked.count == 1, "the second try in the same load is cancelled without a word")
            #expect(log.asked.first?.site == "login.test" && log.asked.first?.app == "Fake App" && log.asked.first?.url == "x-changmun-test://one")
            #expect(log.opened.isEmpty, "Cancel opens nothing")
            #expect(view.url?.host() == "login.test", "the page stays where it was")
        }

        @Test func openingAsksForTheAppOnlyWhenTheUserSaysOpen() async throws {
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let log = Log()
            log.answer = true
            let t = tab(log, in: b)
            let (_, window) = await page("<script>setTimeout(() => { location = 'x-changmun-test://ok?code=1' }, 50)</script>", in: t)
            defer { window.close() }
            #expect(await waitUntil { !log.opened.isEmpty })
            #expect(log.opened.map(\.absoluteString) == ["x-changmun-test://ok?code=1"])
        }

        @Test func noAppForTheSchemeMeansNoQuestion() async throws {
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let log = Log()
            log.app = nil
            let t = tab(log, in: b)
            let (view, window) = await page("<script>setTimeout(() => { location = 'x-changmun-test://ok'; window.done = 'yes' }, 50)</script>", in: t)
            defer { window.close() }
            #expect(await eventually("window.done || ''", in: view) == "yes")
            try await Task.sleep(for: .milliseconds(300))
            #expect(log.asked.isEmpty && log.opened.isEmpty && view.url?.host() == "login.test")
        }

        @Test func aBlockedSchemeNeverAsks() {
            let b = Browser()
            let log = Log()
            let t = tab(log, in: b)
            let view = t.wake()
            for scheme in ["smb", "tel", "ssh", "x-apple.systempreferences"] {
                t.appLinkRequested(URL(string: "\(scheme)://x")!, navigationType: .linkActivated, userInitiated: true, isMainFrame: true, source: nil, in: view)
            }
            #expect(log.asked.isEmpty && log.opened.isEmpty)
        }

        @Test func aNewPageMayAskAgain() {
            let b = Browser()
            let log = Log()
            let t = tab(log, in: b)
            let view = t.wake()
            let url = URL(string: "x-changmun-test://ok")!
            t.appLinkRequested(url, navigationType: .other, userInitiated: false, isMainFrame: true, source: URL(string: "https://a.test/"), in: view)
            t.appLinkRequested(url, navigationType: .other, userInitiated: false, isMainFrame: true, source: URL(string: "https://a.test/"), in: view)
            #expect(log.asked.count == 1 && log.asked.first?.site == "a.test", "with no address of its own yet, the page that redirected is named")
            t.load(URL(string: "https://b.test/")!)
            t.appLinkRequested(url, navigationType: .other, userInitiated: false, isMainFrame: true, source: nil, in: view)
            #expect(log.asked.count == 2)
        }

        @Test func aWindowOpenedForAnAppAddressIsNoWindowAndAsksInThePageThatOpenedIt() async throws {
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let log = Log()
            let t = tab(log, in: b)
            let (view, window) = await page("<script>setTimeout(() => { window.result = String(window.open('x-changmun-test://ok')) }, 50)</script>", in: t)
            defer { window.close() }
            #expect(await eventually("window.result || ''", in: view) == "null")
            #expect(log.asked.count == 1 && b.tabs.count == 1, "one question, and no empty tab left behind")
        }

        @Test func anEmptyWindowThatLandsOnAnAppAddressIsClosedButAPageIsNot() async throws {
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let log = Log()
            let opener = tab(log, in: b, url: URL(string: "https://login.test/"))
            let popup = tab(log, in: b)
            popup.openerID = opener.id
            let url = URL(string: "x-changmun-test://ok")!
            popup.appLinkRequested(url, navigationType: .other, userInitiated: false, isMainFrame: true, source: nil, in: popup.wake())
            #expect(await waitUntil { !b.tabs.contains { $0 === popup } }, "the popup the sign-in opened is closed")
            #expect(log.asked.count == 1 && b.tabs.contains { $0 === opener })
            // A tab nobody opened, or a frame's attempt, stays.
            let own = tab(log, in: b)
            own.appLinkRequested(url, navigationType: .other, userInitiated: false, isMainFrame: true, source: nil, in: own.wake())
            let frame = tab(log, in: b)
            frame.openerID = opener.id
            frame.appLinkRequested(url, navigationType: .other, userInitiated: false, isMainFrame: false, source: nil, in: frame.wake())
            try await Task.sleep(for: .milliseconds(200))
            #expect(b.tabs.contains { $0 === own } && b.tabs.contains { $0 === frame })
        }
    }
}
