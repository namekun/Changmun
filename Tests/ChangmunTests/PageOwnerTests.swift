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

        /// What WebKit does to a page whose element goes full screen: its own window gets the page, a placeholder takes its place.
        private func enterFullscreen(_ view: PageWebView, from container: WebViewHost.Container) -> NSView {
            let screen = NSView(frame: NSRect(x: 0, y: 0, width: 2560, height: 1410))
            view.fullscreenStateForTests = .inFullscreen
            container.addSubview(NSView(frame: view.frame), positioned: .above, relativeTo: view)
            screen.addSubview(view)
            view.frame = screen.bounds
            return screen
        }

        @Test func aHostUpdatedWhileThePageIsFullScreenLeavesItThere() throws {
            let (browser, tab, _, host) = tabs()
            defer { browser.windowClosed() }
            let view = try #require(tab.webView as? PageWebView)
            let container = WebViewHost.Container(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            host.update(container)
            let screen = enterFullscreen(view, from: container)
            // The page's title changes (a video's does), and SwiftUI updates the host.
            host.update(container)
            #expect(view.superview === screen)
            #expect(container.subviews.count == 1)
            WebViewHost.dismantleNSView(container, coordinator: ())
            #expect(view.superview === screen)
        }

        @Test func aPageLeavingFullScreenIsShownInItsHostAtItsSize() throws {
            let (browser, tab, _, host) = tabs()
            defer { browser.windowClosed() }
            let view = try #require(tab.webView as? PageWebView)
            let container = WebViewHost.Container(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            host.update(container)
            _ = enterFullscreen(view, from: container)
            host.update(container)
            // WebKit's end: the page leaves the full screen window, and nothing it was left in is the host's any more.
            view.fullscreenStateForTests = .notInFullscreen
            view.removeFromSuperview()
            container.restore()
            #expect(view.superview === container)
            #expect(view.frame == container.bounds)
            #expect(container.subviews.last === view)
        }

        @Test func aPageLeavingFullScreenGoesToTheHostThatOwnsItNow() throws {
            let (browser, tab, _, host) = tabs()
            defer { browser.windowClosed() }
            let view = try #require(tab.webView as? PageWebView)
            let old = WebViewHost.Container(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let new = WebViewHost.Container(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
            host.update(old)
            _ = enterFullscreen(view, from: old)
            // A split begins while it is full screen: the new host starts, and WebKit puts the page back where its placeholder is.
            host.update(new)
            #expect(view.superview !== new)
            view.fullscreenStateForTests = .notInFullscreen
            old.addSubview(view)
            new.restore()
            #expect(view.superview === new)
            #expect(view.frame == new.bounds)
            // A host that doesn't own the page leaves it be, and so does one that is told while the page is still away.
            old.restore()
            #expect(view.superview === new)
            view.fullscreenStateForTests = .exitingFullscreen
            view.removeFromSuperview()
            new.restore()
            #expect(view.superview == nil)
        }
    }
}
