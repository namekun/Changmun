import AppKit
import Foundation
import Testing
import WebKit
@testable import Changmun

/// What WebKit hands a tab's delegate for a click or a window.open of the user's, without a real page behind it.
private final class FakeAction: WKNavigationAction {
    var shift = false
    var address = "https://link.example/"
    var goesBack = false
    override var navigationType: WKNavigationType { goesBack ? .backForward : shift ? .linkActivated : .other }
    override var request: URLRequest { URLRequest(url: URL(string: address)!) }
    override var targetFrame: WKFrameInfo? { nil }
    override var shouldPerformDownload: Bool { false }
    override var modifierFlags: NSEvent.ModifierFlags { shift ? .shift : [] }
    override var buttonNumber: Int { 0 }
    @objc func _isUserInitiated() -> Bool { true }

    static func make(shift: Bool = false, address: String = "https://link.example/", goesBack: Bool = false) -> FakeAction {
        let action = unsafeDowncast(class_createInstance(FakeAction.self, 0) as AnyObject, to: FakeAction.self)
        action.shift = shift
        action.address = address
        action.goesBack = goesBack
        return action
    }
}

extension SharedAgentState {
    @MainActor @Suite(.serialized)
    struct TabLifecycleTests {
        private func browser() -> Browser {
            let browser = Browser()
            browser.focused()
            return browser
        }

        // MARK: Sleeping idle tabs

        @Test func aTabInPictureInPictureIsNotPutToSleep() async throws {
            let b = browser()
            defer { b.windowClosed() }
            _ = b.openTab(url: nil)
            let floating = b.openTab(url: nil, activate: false), idle = b.openTab(url: nil, activate: false)
            for tab in [floating, idle] { _ = tab.wake(); tab.lastShown = .distantPast }
            floating.isInPictureInPicture = true
            b.sleepIdleTabs(olderThan: 0)
            #expect(await waitUntil { idle.isAsleep }, "an idle one goes to sleep")
            #expect(!(await waitUntil(0.5) { floating.isAsleep }), "the floating video stays")
        }

        @Test func aTabThatStartsFloatingWhileItsMediaIsBeingCheckedIsNotPutToSleep() async throws {
            let b = browser()
            defer { b.windowClosed() }
            _ = b.openTab(url: nil)
            let tab = b.openTab(url: nil, activate: false), idle = b.openTab(url: nil, activate: false)
            for t in [tab, idle] { _ = t.wake(); t.lastShown = .distantPast }
            b.sleepIdleTabs(olderThan: 0)
            tab.isInPictureInPicture = true
            #expect(await waitUntil { idle.isAsleep })
            #expect(!(await waitUntil(0.5) { tab.isAsleep }))
        }

        @Test func aTabWhosePageIsFullScreenIsNotPutToSleep() async throws {
            let b = browser()
            defer { b.windowClosed() }
            _ = b.openTab(url: nil)
            let full = b.openTab(url: nil, activate: false), idle = b.openTab(url: nil, activate: false)
            for t in [full, idle] { _ = t.wake(); t.lastShown = .distantPast }
            (full.webView as? PageWebView)?.fullscreenStateForTests = .inFullscreen
            b.sleepIdleTabs(olderThan: 0)
            #expect(await waitUntil { idle.isAsleep })
            #expect(!(await waitUntil(0.5) { full.isAsleep }))
        }

        // MARK: Page process crashes

        @Test func aPageThatCrashedBeforeItsFirstLoadFinishedLoadsItsAddressAgain() async throws {
            let b = browser()
            defer { b.windowClosed() }
            let tab = b.openTab(url: nil)
            let view = tab.wake()
            tab.url = URL(string: "about:blank")
            // Nothing was committed yet: there is no history to reload.
            #expect(view.url == nil && view.backForwardList.currentItem == nil)
            tab.webViewWebContentProcessDidTerminate(view)
            #expect(await waitUntil { view.url?.absoluteString == "about:blank" })
        }

        @Test func aPageTheAIUsesBehindTheOneShownIsLoadedAgainNotPutToSleep() async throws {
            let b = browser()
            defer { b.windowClosed(); AgentActivity.shared.runEnded() }
            _ = b.openTab(url: nil)
            let held = b.openTab(url: nil, activate: false)
            let view = held.wake()
            AgentActivity.shared.runStarted()
            AgentActivity.shared.use(held, caller: ChatStore.caller)
            held.url = URL(string: "about:blank")
            held.webViewWebContentProcessDidTerminate(view)
            #expect(!held.isAsleep && held.webView === view)
            #expect(await waitUntil { view.url?.absoluteString == "about:blank" })
        }

        @Test func aPageNobodyUsesStillGoesToSleepWhenItCrashes() {
            let b = browser()
            defer { b.windowClosed() }
            _ = b.openTab(url: nil)
            let idle = b.openTab(url: nil, activate: false)
            idle.webViewWebContentProcessDidTerminate(idle.wake())
            #expect(idle.isAsleep)
        }

        // MARK: Windows opened from the peek

        @Test func aPopupOfAPageInThePeekLeavesItsOpenerAlive() throws {
            let b = browser()
            defer { b.windowClosed() }
            _ = b.openTab(url: nil)
            b.openPeek(URL(string: "about:blank")!)
            let peek = try #require(b.peek), view = try #require(peek.webView)
            let popup = peek.webView(view, createWebViewWith: b.configuration(for: peek.spaceID), for: FakeAction.make(), windowFeatures: WKWindowFeatures())
            #expect(popup != nil)
            #expect(peek.webView === view, "the page that asked for the window is still there, for window.opener")
            #expect(b.peek == nil && b.tabs.contains { $0 === peek }, "kept as a tab")
            #expect(b.active?.webView === popup, "and the window is the tab in front")
        }

        // MARK: Windows a page opened

        /// `window.open("about:blank;")` followed by `w.location.href = …` leaves the blank document as the window's first entry of the back list
        /// (WebKit replaces only the plain `about:blank`): Back would show a white page, so nothing goes back to it.
        @Test func backDoesNotGoToTheBlankDocumentAWindowStartedOn() async throws {
            let server = try await TinyServer { _, path in "<p>\(path)</p>" }
            defer { server.stop() }
            let b = browser()
            defer { b.windowClosed() }
            let opener = b.openTab(url: nil)
            let window = b.openTab(url: nil), typed = b.openTab(url: nil)
            window.openerID = opener.id
            func load(_ tab: Tab, _ address: URL) async -> Bool {
                let view = tab.wake()
                view.load(URLRequest(url: address))
                return await waitUntil { view.url == address && !view.isLoading }
            }
            func back(_ tab: Tab, to address: URL) async -> WKNavigationActionPolicy {
                await tab.webView(tab.wake(), decidePolicyFor: FakeAction.make(address: address.absoluteString, goesBack: true), preferences: WKWebpagePreferences()).0
            }
            let blank = URL(string: "about:blank#start")!
            let frame = OffscreenWindow(window.wake()), typedFrame = OffscreenWindow(typed.wake())
            defer { frame.close(); typedFrame.close() }
            for tab in [window, typed] {
                #expect(await load(tab, blank))
                #expect(await load(tab, server.url("/first")))
                #expect(tab.wake().canGoBack, "WebKit counts the blank document")
            }
            #expect(!window.canGoBack)
            #expect(await back(window, to: blank) == .cancel)
            #expect(typed.canGoBack, "a tab the user opened goes back to it")
            #expect(await back(typed, to: blank) != .cancel)
            #expect(await load(window, server.url("/second")))
            #expect(await waitUntil { window.canGoBack }, "a page to go back to")
            #expect(await back(window, to: server.url("/first")) != .cancel)
        }

        @Test func aLinkShiftClickedInThePeekReplacesItOutsideItsOwnCallback() async throws {
            let b = browser()
            defer { b.windowClosed() }
            _ = b.openTab(url: nil)
            b.openPeek(URL(string: "about:blank")!)
            let old = try #require(b.peek), view = try #require(old.webView)
            let popup = old.webView(view, createWebViewWith: b.configuration(for: old.spaceID), for: FakeAction.make(shift: true), windowFeatures: WKWindowFeatures())
            #expect(popup == nil)
            #expect(b.peek != nil && b.peek !== old)
            #expect(old.webView === view, "the page is still within its own delegate call: it goes after it")
            #expect(await waitUntil { old.isAsleep })
        }

        // MARK: Full screen

        @Test func aTabThatGoesToSleepInFullScreenAsksTheFullScreenToEnd() async throws {
            let b = browser()
            defer { b.windowClosed() }
            _ = b.openTab(url: nil)
            let tab = b.openTab(url: nil, activate: false)
            let view = try #require(tab.wake() as? PageWebView)
            view.fullscreenStateForTests = .inFullscreen
            tab.sleep()
            #expect(tab.isAsleep && view.fullscreenExitsRequested == 1)
            // A page that isn't full screen is not asked anything.
            let plain = b.openTab(url: nil, activate: false)
            let plainView = try #require(plain.wake() as? PageWebView)
            plain.sleep()
            #expect(plainView.fullscreenExitsRequested == 0)
        }
    }
}
