import AppKit
import Foundation
import Testing
import WebKit
@testable import Changmun

struct SiteListTests {
    @Test func aSiteIsAddedOnceWithoutWWW() {
        #expect(Preferences.adding("www.Example.com", to: ["a.com"]) == ["a.com", "example.com"])
        #expect(Preferences.adding("example.com", to: ["example.com"]) == ["example.com"])
    }

    @Test func nothingEmptyIsEverStored() {
        #expect(Preferences.adding("", to: ["a.com"]) == ["a.com"])
        #expect(Preferences.adding("www.", to: []) == [])
    }

    @Test func blockingComesBackOnForASiteUnderAnAllowedParent() {
        #expect(AdBlocker.allowlist(["example.com", "a.com"], blocking: true, host: "WWW.Sub.Example.com") == ["a.com"])
        #expect(AdBlocker.allowlist(["a.com"], blocking: false, host: "www.Sub.example.com") == ["a.com", "sub.example.com"])
        #expect(AdBlocker.allowlist(["a.com"], blocking: true, host: "other.org") == ["a.com"])
        #expect(AdBlocker.allowlist(["a.com"], blocking: false, host: "") == ["a.com"])
    }

    @Test func removingASiteAlsoRemovesTheOneAboveItThatCoversIt() {
        #expect(Preferences.removing("www.example.com", from: ["example.com", "a.com"]) == ["a.com"])
        #expect(Preferences.removing("example.com", from: ["www.example.com", "a.com"]) == ["www.example.com", "a.com"])
        #expect(Preferences.removing("notexample.com", from: ["example.com"]) == ["example.com"])
    }
}

extension SharedAgentState {
    @MainActor
    struct ReaderTests {
        static let sentence = "The quick brown fox jumps over the lazy dog, and then it runs back across the meadow again, which takes a while. "
        static let article = """
            <html lang=en><head><title>Site - Big Story</title><meta name=author content="Jane Doe"></head><body>
            <nav><a href="/">Home</a> <a href="/news">NavigationWord</a></nav>
            <div class="page-with-sidebar"><article>
            <h1>Big Story</h1>
            <p>Intro: \(sentence)\(sentence)</p>
            <p>Second: \(sentence)\(sentence)<a href="/more">more</a> <a href="javascript:alert(1)">bad</a></p>
            <img src="http://localhost:1/big.png" width=400 height=200 alt="Big picture">
            <img src="http://localhost:1/tiny.png" width=16 height=16>
            <h2>Part two</h2>
            <p>Third: \(sentence)\(sentence)</p>
            <ul><li>First point</li><li>Second point</li></ul>
            <blockquote>Quoted words</blockquote>
            <pre>let x = 1</pre>
            <div class="ad-slot"><p>AdvertisementWord \(sentence)</p></div>
            <script>document.title = 'ScriptWord'</script>
            </article><aside><p>AsideWord \(sentence)</p></aside></div>
            <footer>FooterWord</footer></body></html>
            """

        static let listing = """
            <html><body><h1>Front page</h1>
            \((1...12).map { "<div><a href=\"/s\($0)\">Story number \($0) with a headline that goes on</a> <p>Short blurb \($0).</p></div>" }.joined())
            </body></html>
            """

        private func page(_ html: String) async throws -> (WKWebView, NSWindow) {
            let view = WKWebView()
            let window = OffscreenWindow(view)
            view.loadHTMLString(html, baseURL: URL(string: "https://www.reader.test/post"))
            for _ in 0..<60 where view.isLoading || view.url == nil { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(200))
            return (view, window)
        }

        private func shadow(_ view: WKWebView, _ script: String) async throws -> Any? {
            try await view.callAsyncJavaScript("const s = globalThis.changmunReader.shadow; \(script)", contentWorld: .defaultClient)
        }

        @Test func anArticleLooksReadableAndAListingDoesNot() async throws {
            let (article, articleWindow) = try await page(Self.article)
            defer { articleWindow.close() }
            #expect(await Reader.run(.check, in: article) == .readable)
            let (listing, listingWindow) = try await page(Self.listing)
            defer { listingWindow.close() }
            #expect(await Reader.run(.check, in: listing) == .unreadable)
            let (short, shortWindow) = try await page("<p>Just one line, nothing to read here.</p>")
            defer { shortWindow.close() }
            #expect(await Reader.run(.check, in: short) == .unreadable)
        }

        @Test func theArticleIsShownWithoutTheRestOfThePage() async throws {
            let (view, window) = try await page(Self.article)
            defer { window.close() }
            #expect(await Reader.run(.toggle, in: view) == .up)
            let text = try #require(try await shadow(view, "return s.textContent") as? String)
            for kept in ["Big Story", "Intro:", "Third:", "Part two", "First point", "Quoted words", "let x = 1", "Jane Doe", "reader.test"] {
                #expect(text.contains(kept), "\(kept)")
            }
            for dropped in ["NavigationWord", "AdvertisementWord", "AsideWord", "FooterWord", "ScriptWord"] {
                #expect(!text.contains(dropped), "\(dropped)")
            }
            // The title is the heading once, the big picture stays and the icon-sized one goes, and a javascript: link is just text.
            #expect(try await shadow(view, "return s.querySelectorAll('h1').length") as? Int == 1)
            #expect(try await shadow(view, "return s.querySelectorAll('h2').length") as? Int == 1)
            #expect(try await shadow(view, "return [...s.querySelectorAll('img')].map(i => i.src).join()") as? String == "http://localhost:1/big.png")
            #expect(try await shadow(view, "return [...s.querySelectorAll('a')].map(a => a.href).join()") as? String == "https://www.reader.test/more")
            #expect(try await shadow(view, "return s.querySelectorAll('script, [onclick], style').length") as? Int == 0)
        }

        @Test func togglingAgainPutsThePageBack() async throws {
            let (view, window) = try await page(Self.article)
            defer { window.close() }
            #expect(await Reader.run(.toggle, in: view) == .up)
            #expect(await Reader.run(.check, in: view) == .up)
            let up: () async throws -> Bool? = { try await view.callAsyncJavaScript("return document.getElementById('changmun-reader') !== null", contentWorld: .page) as? Bool }
            #expect(try await up() == true)
            #expect(try await view.callAsyncJavaScript("return getComputedStyle(document.documentElement).overflow", contentWorld: .page) as? String == "hidden")
            #expect(await Reader.run(.toggle, in: view) == .down)
            #expect(try await up() == false)
            #expect(try await view.callAsyncJavaScript("return getComputedStyle(document.documentElement).overflow", contentWorld: .page) as? String != "hidden")
        }

        @Test func aPageWithoutAnArticleShowsNothing() async throws {
            let (view, window) = try await page(Self.listing)
            defer { window.close() }
            #expect(await Reader.run(.toggle, in: view) == .none)
            #expect(try await view.callAsyncJavaScript("return document.getElementById('changmun-reader') === null", contentWorld: .page) as? Bool == true)
        }

        @Test func theTabKnowsWhenThePageIsReadableAndWhenReaderModeEndsFromInside() async throws {
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let tab = b.openTab(url: nil)
            let view = tab.wake()
            let window = OffscreenWindow(view)
            defer { window.close() }
            view.loadHTMLString(Self.article, baseURL: URL(string: "https://www.reader.test/post"))
            for _ in 0..<80 where !tab.isReadable { try await Task.sleep(for: .milliseconds(50)) }
            #expect(tab.isReadable)
            tab.toggleReader()
            for _ in 0..<80 where !tab.isReading { try await Task.sleep(for: .milliseconds(50)) }
            #expect(tab.isReading)
            _ = try await shadow(view, "s.querySelector('.close').click()")
            for _ in 0..<80 where tab.isReading { try await Task.sleep(for: .milliseconds(50)) }
            #expect(!tab.isReading)
            view.loadHTMLString("<p>Another page</p>", baseURL: URL(string: "https://www.reader.test/other"))
            for _ in 0..<80 where tab.isReadable { try await Task.sleep(for: .milliseconds(50)) }
            #expect(!tab.isReadable)
        }

        private func readableTab(_ html: String = ReaderTests.article) async throws -> (Browser, Tab, WKWebView, NSWindow) {
            let b = Browser()
            b.focused()
            let tab = b.openTab(url: nil)
            let view = tab.wake()
            let window = OffscreenWindow(view)
            view.loadHTMLString(html, baseURL: URL(string: "https://www.reader.test/post"))
            for _ in 0..<80 where !tab.isReadable { try await Task.sleep(for: .milliseconds(50)) }
            return (b, tab, view, window)
        }

        @Test func aPageBackFromTheCacheStillKnowsItsArticleIsUp() async throws {
            let (b, tab, _, window) = try await readableTab()
            defer { window.close(); b.windowClosed() }
            tab.toggleReader()
            for _ in 0..<80 where !tab.isReading { try await Task.sleep(for: .milliseconds(50)) }
            #expect(tab.isReading)
            // What a page shown again from the back/forward cache goes through: the tab forgets, the page didn't.
            tab.isReading = false
            await tab.checkReader()
            #expect(tab.isReading && tab.isReadable)
            tab.toggleReader()
            for _ in 0..<80 where tab.isReading { try await Task.sleep(for: .milliseconds(50)) }
            #expect(!tab.isReading)
            #expect(b.overlay.statusMessage == nil, "closing the article is not 'no article'")
        }

        @Test func aPageWithNothingToShowSaysSo() async throws {
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let tab = b.openTab(url: nil)
            let view = tab.wake()
            let window = OffscreenWindow(view)
            defer { window.close() }
            view.loadHTMLString(Self.listing, baseURL: URL(string: "https://www.reader.test/list"))
            for _ in 0..<60 where view.isLoading || view.url == nil { try await Task.sleep(for: .milliseconds(50)) }
            #expect(b.overlay.statusMessage == nil)
            tab.toggleReader()
            for _ in 0..<80 where b.overlay.statusMessage == nil { try await Task.sleep(for: .milliseconds(50)) }
            #expect(b.overlay.statusMessage != nil)
            #expect(!tab.isReading)
        }

        @Test func aSinglePageSiteMovingOnTakesTheArticleAway() async throws {
            let (b, tab, view, window) = try await readableTab()
            defer { window.close(); b.windowClosed() }
            tab.toggleReader()
            for _ in 0..<80 where !tab.isReading { try await Task.sleep(for: .milliseconds(50)) }
            #expect(tab.isReading)
            _ = try await view.callAsyncJavaScript("history.pushState({}, '', '/next')", contentWorld: .page)
            for _ in 0..<80 where tab.isReading { try await Task.sleep(for: .milliseconds(50)) }
            #expect(!tab.isReading)
            var gone = false
            for _ in 0..<80 where !gone {
                gone = try await view.callAsyncJavaScript("return document.getElementById('changmun-reader') === null", contentWorld: .page) as? Bool == true
                if !gone { try await Task.sleep(for: .milliseconds(50)) }
            }
            #expect(gone)
        }

        @Test func aLinkToAPlaceInThePageScrollsTheArticleNotThePage() async throws {
            let filler = (1...30).map { "<p>Filler \($0): \(Self.sentence)\(Self.sentence)</p>" }.joined()
            let html = """
                <html><body><article><h1>Long</h1><p>Top: <a href="#end">to the end</a> \(Self.sentence)\(Self.sentence)</p>\(filler)
                <h2 id="end">The end</h2><p>Last: \(Self.sentence)\(Self.sentence)</p></article></body></html>
                """
            let (view, window) = try await page(html)
            defer { window.close() }
            #expect(await Reader.run(.toggle, in: view) == .up)
            let top = { (try await self.shadow(view, "return s.host.scrollTop") as? NSNumber)?.doubleValue ?? -1 }
            #expect(try await top() == 0)
            _ = try await shadow(view, "s.querySelector('a[href]').click()")
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await top() > 100)
            #expect(try await view.callAsyncJavaScript("return location.hash", contentWorld: .page) as? String == "")
            #expect(try await view.callAsyncJavaScript("return window.scrollY", contentWorld: .page) as? NSNumber == 0)
        }
    }
}
