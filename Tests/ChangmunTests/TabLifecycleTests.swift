import AppKit
import Foundation
import Testing
import WebKit
@testable import Changmun

/// What WebKit hands a tab's delegate for a click or a window.open of the user's, without a real page behind it.
private final class FakeAction: WKNavigationAction {
    var shift = false
    override var navigationType: WKNavigationType { shift ? .linkActivated : .other }
    override var request: URLRequest { URLRequest(url: URL(string: "https://link.example/")!) }
    override var modifierFlags: NSEvent.ModifierFlags { shift ? .shift : [] }
    override var buttonNumber: Int { 0 }
    @objc func _isUserInitiated() -> Bool { true }

    static func make(shift: Bool = false) -> FakeAction {
        let action = unsafeDowncast(class_createInstance(FakeAction.self, 0) as AnyObject, to: FakeAction.self)
        action.shift = shift
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
