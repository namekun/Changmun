import AppKit
import Foundation
import Testing
import WebKit
@testable import Changmun

struct PageOwnerTests {
    @Test func theNewestHostToClaimOwnsThePage() {
        let old = NSObject(), new = NSObject()
        var owner = PageOwner<NSObject>()
        #expect(!owner.owns(old))
        owner.claim(old)
        #expect(owner.owns(old))
        owner.claim(new)
        #expect(owner.owns(new))
        #expect(!owner.owns(old))
        owner.claim(new)
        #expect(owner.owns(new))
    }

    @Test func aPageIsInFrontUnlessItsHostSaysItIsKeptBehind() {
        let host = NSObject()
        var owner = PageOwner<NSObject>()
        owner.claim(host)
        #expect(owner.place == .front)
        owner.claim(host, as: .behind)
        #expect(owner.owns(host) && owner.place == .behind)
        owner.claim(host)
        #expect(owner.place == .front)
    }

    @Test func aHostThatIsGoneOwnsNothing() {
        var owner = PageOwner<NSObject>()
        var gone: NSObject? = NSObject()
        owner.claim(gone!)
        gone = nil
        #expect(owner.host == nil)
        #expect(!owner.owns(NSObject()))
    }
}

extension SharedAgentState {
    /// The pages move between hosts when SwiftUI replaces a view (ending a split, keeping a peek): the host on its way out
    /// updates after the new one, and its container is torn down with whatever it holds.
    @MainActor @Suite(.serialized)
    struct WebViewHostTests {
        private func tabs() -> (Browser, Tab, Tab, WebViewHost) {
            let browser = Browser()
            browser.focused()
            let tab = browser.openTab(url: nil)
            let other = browser.openTab(url: nil, activate: false)
            _ = tab.wake()
            _ = other.wake()
            return (browser, tab, other, WebViewHost(tab: tab, browser: browser))
        }

        @Test func aHostOnItsWayOutDoesNotTakeThePageBackFromTheNewOne() throws {
            let (browser, tab, _, host) = tabs()
            defer { browser.windowClosed() }
            let view = try #require(tab.webView)
            let old = WebViewHost.Container(), new = WebViewHost.Container()
            host.update(old)
            #expect(view.superview === old)
            // The split ends: a new host starts, then the old one is updated once more before it goes.
            host.update(new)
            host.update(old)
            #expect(view.superview === new)
            WebViewHost.dismantleNSView(old, coordinator: ())
            #expect(view.superview === new)
        }

        @Test func aHostThatGoesHoldingAPageStillShownHandsItToTheOwner() throws {
            let (browser, tab, _, host) = tabs()
            defer { browser.windowClosed() }
            let view = try #require(tab.webView)
            let old = WebViewHost.Container(), new = WebViewHost.Container()
            host.update(old)
            host.update(new)
            old.show(view)
            WebViewHost.dismantleNSView(old, coordinator: ())
            #expect(view.superview === new)
        }

        @Test func aPageNotShownAnymoreStaysWhereItIs() throws {
            let (browser, tab, other, host) = tabs()
            defer { browser.windowClosed() }
            let view = try #require(tab.webView)
            let old = WebViewHost.Container(), new = WebViewHost.Container()
            host.update(old)
            host.update(new)
            browser.activate(other.id)
            WebViewHost.dismantleNSView(old, coordinator: ())
            #expect(view.superview === new)
            // The page of a tab that is no longer shown isn't taken by a host that starts after the switch either.
            let late = WebViewHost.Container()
            host.update(late)
            #expect(view.superview === new)
        }

        @Test func aContainerReusedForAnotherTabOwnsThatTabsPage() throws {
            let (browser, tab, other, host) = tabs()
            defer { browser.windowClosed() }
            let first = try #require(tab.webView), second = try #require(other.webView)
            let container = WebViewHost.Container()
            host.update(container)
            #expect(first.superview === container)
            browser.activate(other.id)
            WebViewHost(tab: other, browser: browser).update(container)
            #expect(second.superview === container)
            #expect(first.superview == nil)
            // The first tab's old host can't claim through the reused container.
            let stale = WebViewHost.Container()
            host.update(stale)
            WebViewHost.dismantleNSView(container, coordinator: ())
            #expect(second.superview === container)
        }
    }
}
