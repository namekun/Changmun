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
                            showing: Bool = false, headless: Bool = false, agent: Bool = false, blocked: Bool = false, app: Bool = true,
                            shown: Bool = true) -> Decision {
            Tab.appLinkDecision(navigationType: type, userInitiated: userInitiated, isMainFrame: mainFrame, askedSinceUserNavigation: asked,
                                questionShowing: showing, headless: headless, agentDriven: agent, blocked: blocked, hasApp: app, tabShown: shown)
        }

        @Test func aRedirectOrScriptToAnAppAsksLikeAClickDoes() {
            #expect(decide(.other) == .ask)
            #expect(decide(.linkActivated, userInitiated: true) == .ask)
            #expect(decide(.linkActivated) == .ask, "a link the page clicked itself is one more redirect: it asks, once")
            #expect(decide(.reload) == .ask)
        }

        @Test func aPageAsksOnceUntilTheUserNavigatesButTheirClicksAlwaysAsk() {
            #expect(decide(.other, asked: true) == .cancelSilently)
            #expect(decide(.linkActivated, asked: true) == .cancelSilently, "a script's click doesn't get past the limit")
            #expect(decide(.linkActivated, userInitiated: true, asked: true) == .ask)
        }

        @Test func aQuestionOnScreenIsTheOnlyOne() {
            #expect(decide(.other, showing: true) == .cancelSilently)
            #expect(decide(.linkActivated, userInitiated: true, showing: true) == .cancelSilently)
        }

        @Test func onlyTheUsersOwnNavigationsStartOver() {
            for type in [WKNavigationType.linkActivated, .formSubmitted, .backForward, .reload, .formResubmitted] {
                #expect(Tab.startsUserNavigation(type, userInitiated: true), "\(type.rawValue)")
                #expect(!Tab.startsUserNavigation(type, userInitiated: false), "a script's \(type.rawValue) is the page's own")
            }
            #expect(!Tab.startsUserNavigation(.other, userInitiated: true), "a redirect or a script's location is never the user's")
        }

        @Test func theAskingSiteIsTheFramesOwnNotTheTabs() {
            let top = URL(string: "https://bank.test/page")
            #expect(Tab.askingSite(originHost: "ads.test", requestURL: top) == "ads.test")
            #expect(Tab.askingSite(originHost: "", requestURL: URL(string: "https://frame.test/x")) == "frame.test")
            #expect(Tab.askingSite(originHost: "", requestURL: nil) == nil)
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
                #expect(decide(type, userInitiated: true, shown: false) == .cancelSilently, "a tab nobody sees has no window to ask on")
            }
        }

        @Test func withoutTheSystemsUserFlagNothingCountsAsTheUsers() {
            #expect(Tab.userStartedForAppLinks(true, knowsUserInitiated: true))
            #expect(!Tab.userStartedForAppLinks(false, knowsUserInitiated: true))
            #expect(!Tab.userStartedForAppLinks(true, knowsUserInitiated: false), "where the flag can't be read, `true` is only the stand-in for it")
            for type in [WKNavigationType.linkActivated, .formSubmitted, .backForward, .reload, .formResubmitted] {
                #expect(!Tab.startsUserNavigation(type, userInitiated: Tab.userStartedForAppLinks(true, knowsUserInitiated: false)), "\(type.rawValue) can't give a page its question back")
            }
        }

        @Test func theSchemesThatRunThingsAreBlocked() {
            for scheme in ["shortcuts", "workflow", "x-apple.systempreferences", "applescript", "smb", "ssh", "tel", "facetime", "x-help-action", "prefs", "sftp", "callto", "sms"] {
                #expect(Tab.blockedSchemes.contains(scheme), "\(scheme)")
            }
            for scheme in ["mailto", "zoommtg", "claude", "slack", "http", "https"] {
                #expect(!Tab.blockedSchemes.contains(scheme), "\(scheme) is for an app the user is asked about")
            }
        }

        // MARK: What a tab does with it

        private final class Log {
            var asked: [(site: String, app: String, url: String)] = []
            var opened: [URL] = []
            var answer = false
            var app: String? = "Fake App"
            /// While true, the question stays up until `release` answers it.
            var holds = false
            var waiting: [CheckedContinuation<Bool, Never>] = []
            func release(_ answer: Bool) { let all = waiting; waiting = []; all.forEach { $0.resume(returning: answer) } }
        }

        private func tab(_ log: Log, in b: Browser, url: URL? = nil) -> Tab {
            let tab = b.openTab(url: url)
            tab.appLinks = AppLinks(appName: { _ in log.app },
                                    confirm: { site, app, url, _ in
                                        log.asked.append((site, app, url.absoluteString))
                                        if log.holds { return await withCheckedContinuation { log.waiting.append($0) } }
                                        return log.answer
                                    },
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
            for scheme in ["smb", "tel", "ssh", "x-apple.systempreferences", "shortcuts", "workflow"] {
                t.appLinkRequested(URL(string: "\(scheme)://x")!, navigationType: .linkActivated, userInitiated: true, isMainFrame: true, site: nil, in: view)
            }
            #expect(log.asked.isEmpty && log.opened.isEmpty)
        }

        private func request(_ t: Tab, _ view: WKWebView, _ type: WKNavigationType = .other, userInitiated: Bool = false, mainFrame: Bool = true, site: String? = "a.test") {
            t.appLinkRequested(URL(string: "x-changmun-test://ok")!, navigationType: type, userInitiated: userInitiated, isMainFrame: mainFrame, site: site, in: view)
        }

        @Test func thePromptNamesTheAskingSiteOrTheFallback() async {
            let b = Browser()
            let log = Log()
            let t = tab(log, in: b)
            let view = t.wake()
            request(t, view, site: "ads.test")
            #expect(await waitUntil { log.asked.count == 1 })
            #expect(log.asked.first?.site == "ads.test")
            t.load(URL(string: "https://b.test/")!)
            request(t, view, site: nil)
            #expect(await waitUntil { log.asked.count == 2 })
            #expect(log.asked.last?.site == "This page")
        }

        @Test func aTabThatIsNotShownCancelsWithoutAQuestion() async throws {
            let b = Browser()
            let log = Log()
            let behind = b.openTab(url: nil, activate: false)
            behind.appLinks = tab(log, in: b).appLinks
            let front = tab(log, in: b)
            #expect(!b.isShown(behind) && b.isShown(front))
            request(behind, behind.wake(), .linkActivated, userInitiated: true)
            try await Task.sleep(for: .milliseconds(100))
            #expect(log.asked.isEmpty && !behind.askedForAppSinceUserNavigation, "no sheet on a window whose page is another's")
            request(front, front.wake(), .linkActivated, userInitiated: true)
            #expect(await waitUntil { log.asked.count == 1 }, "the tab in front asks")
        }

        @Test func anAIsLoadDoesNotGiveThePageItsQuestionBack() async throws {
            let b = Browser()
            let log = Log()
            let t = tab(log, in: b)
            let view = t.wake()
            request(t, view)
            #expect(await waitUntil { log.asked.count == 1 })
            t.load(URL(string: "https://b.test/")!, byUser: false)
            #expect(t.askedForAppSinceUserNavigation, "the AI went there, not the user")
            request(t, view)
            try await Task.sleep(for: .milliseconds(100))
            #expect(log.asked.count == 1)
            t.load(URL(string: "https://c.test/")!)
            #expect(!t.askedForAppSinceUserNavigation, "an address the user loads does")
        }

        @Test func aPageThatNavigatesItselfCannotKeepAsking() async throws {
            let b = Browser()
            let log = Log()
            let t = tab(log, in: b)
            let view = t.wake()
            request(t, view)
            #expect(await waitUntil { log.asked.count == 1 })
            // Each round is the page's own: it commits a new page, which redirects to the app again.
            for _ in 1...3 {
                t.webView(view, didCommit: nil)
                request(t, view)
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(log.asked.count == 1, "page-caused commits don't start the count over")
        }

        @Test func afterCancelOnlyAClickOrTheUsersOwnNavigationAsksAgain() async throws {
            let b = Browser()
            let log = Log()
            let t = tab(log, in: b)
            let view = t.wake()
            request(t, view)
            #expect(await waitUntil { log.asked.count == 1 })
            try await Task.sleep(for: .milliseconds(50))
            request(t, view)
            request(t, view, .linkActivated)
            try await Task.sleep(for: .milliseconds(50))
            #expect(log.asked.count == 1, "Cancel was the answer: neither a redirect nor a script's click asks again")
            request(t, view, .linkActivated, userInitiated: true)
            #expect(await waitUntil { log.asked.count == 2 }, "the user's own click does")
            try await Task.sleep(for: .milliseconds(50))
            t.load(URL(string: "https://b.test/")!)
            request(t, view)
            #expect(await waitUntil { log.asked.count == 3 }, "so does a redirect after an address the user went to")
        }

        @Test func oneQuestionIsUpAtATimeAndTheOthersAreCancelledWithoutAWord() async throws {
            let b = Browser()
            let log = Log()
            log.holds = true
            let t = tab(log, in: b)
            let view = t.wake()
            request(t, view)
            #expect(await waitUntil { log.asked.count == 1 })
            t.load(URL(string: "https://b.test/")!)
            request(t, view)
            request(t, view, .linkActivated, userInitiated: true)
            try await Task.sleep(for: .milliseconds(50))
            #expect(log.asked.count == 1, "the first is still on screen")
            log.release(true)
            #expect(await waitUntil { log.opened.count == 1 })
            request(t, view, .linkActivated, userInitiated: true)
            #expect(await waitUntil { log.asked.count == 2 }, "answered, the next may ask")
            log.release(false)
        }

        @Test func aFramesWindowForAnAppAddressIsCancelledWithoutAQuestion() async throws {
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let log = Log()
            let t = tab(log, in: b)
            let (view, window) = await page("""
                <iframe srcdoc="<script>setTimeout(() => { parent.result = String(window.open('x-changmun-test://ok')) }, 50)</script>"></iframe>
                """, in: t)
            defer { window.close() }
            #expect(await eventually("window.result || ''", in: view) == "null")
            try await Task.sleep(for: .milliseconds(100))
            #expect(log.asked.isEmpty && b.tabs.count == 1)
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
            popup.appLinkRequested(url, navigationType: .other, userInitiated: false, isMainFrame: true, site: nil, in: popup.wake())
            #expect(await waitUntil { !b.tabs.contains { $0 === popup } }, "the popup the sign-in opened is closed")
            #expect(log.asked.count == 1 && b.tabs.contains { $0 === opener })
            // A tab nobody opened, or a frame's attempt, stays.
            let own = tab(log, in: b)
            own.appLinkRequested(url, navigationType: .other, userInitiated: false, isMainFrame: true, site: nil, in: own.wake())
            let frame = tab(log, in: b)
            frame.openerID = opener.id
            frame.appLinkRequested(url, navigationType: .other, userInitiated: false, isMainFrame: false, site: nil, in: frame.wake())
            try await Task.sleep(for: .milliseconds(200))
            #expect(b.tabs.contains { $0 === own } && b.tabs.contains { $0 === frame })
        }
    }
}
