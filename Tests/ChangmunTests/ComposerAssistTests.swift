import AppKit
import Foundation
import Testing
import WebKit
@testable import Changmun

struct ComposerMentionTests {
    private func token(_ text: String, caret: Int? = nil) -> ComposerMention.Token? {
        ComposerMention.token(in: text, caret: caret ?? (text as NSString).length)
    }

    @Test func anAtAtTheStartOrAfterASpaceOpensTheListAndTheQueryIsWhatFollows() {
        #expect(token("@") == .init(range: NSRange(location: 0, length: 1), query: ""))
        #expect(token("compare with @ex") == .init(range: NSRange(location: 13, length: 3), query: "ex"))
        #expect(token("one\n@news") == .init(range: NSRange(location: 4, length: 5), query: "news"))
        #expect(token("@네이버") == .init(range: NSRange(location: 0, length: 4), query: "네이버"))
        // The cursor decides: the token ends where it is.
        #expect(token("@abc def", caret: 3) == .init(range: NSRange(location: 0, length: 3), query: "ab"))
    }

    @Test func anAddressOrAWordAfterASpaceIsNotAMention() {
        #expect(token("write to me@example.com") == nil)
        #expect(token("@ex ample") == nil, "a space ends the token")
        #expect(token("nothing here") == nil)
        #expect(token("") == nil)
        #expect(token("@ex", caret: 0) == nil)
    }

    @Test func tabsAreFilteredByTitleOrHostAndTheBestFitsComeFirst() {
        #expect(ComposerMention.rank(title: "Example Domain", host: "www.example.com", query: "") == 0)
        #expect(ComposerMention.rank(title: "Example Domain", host: "www.example.com", query: "EXA") == 0)
        #expect(ComposerMention.rank(title: "My notes", host: "www.docs.example.com", query: "docs") == 0, "www. is not counted")
        #expect(ComposerMention.rank(title: "Shopping cart", host: "shop.test", query: "cart") == 1)
        #expect(ComposerMention.rank(title: "Shopping cart", host: "shop.test", query: "zzz") == nil)
        #expect(ComposerMention.rank(title: "네이버 지도", host: "map.naver.com", query: "네이") == 0)
    }

    @Test func theTokenAndOneSpaceBesideItAreCutOut() {
        func cut(_ text: String) -> String {
            let found = token(text)!
            return (text as NSString).replacingCharacters(in: ComposerMention.removalRange(for: found, in: text), with: "")
        }
        #expect(cut("@ex") == "")
        #expect(cut("compare @ex") == "compare")
        #expect(cut("hello @ex") == "hello")
        let middle = "see @ex now"
        let found = token(middle, caret: 7)!
        #expect((middle as NSString).replacingCharacters(in: ComposerMention.removalRange(for: found, in: middle), with: "") == "see now")
    }
}

extension SharedAgentState {
    @MainActor @Suite
    struct ComposerMentionTabTests {
        @Test func filteringKeepsThePrefixFitsFirstAndTheOrderOtherwise() {
            let browser = Browser(isPrivate: false)
            browser.focused()
            defer { browser.windowClosed() }
            let tabs = ["https://docs.example.com/", "https://news.test/example", "https://example.org/"].map { browser.openTab(url: URL(string: $0), activate: false) }
            tabs[0].title = "Reference manual"
            tabs[1].title = "Today in news"
            tabs[2].title = "Landing"
            #expect(ComposerMention.filter(tabs, query: "").map(\.id) == tabs.map(\.id))
            #expect(ComposerMention.filter(tabs, query: "example").map(\.id) == [tabs[2].id, tabs[0].id], "example.org starts with it, docs.example.com only has it")
            #expect(ComposerMention.filter(tabs, query: "news").map(\.id) == [tabs[1].id])
            #expect(ComposerMention.filter(tabs, query: "manual").map(\.id) == [tabs[0].id])
            #expect(ComposerMention.filter(tabs, query: "nothing").isEmpty)
        }
    }
}

@MainActor
struct ComposerHistoryTests {
    @Test func upBringsBackTheLastMessageIntoAnEmptyBoxAndDownGoesBackOut() {
        let history = ComposerHistory()
        #expect(history.older(current: "") == nil, "nothing sent yet")
        history.add("first")
        history.add("second")
        #expect(history.older(current: "") == "second")
        #expect(history.older(current: "second") == "first")
        #expect(history.older(current: "first") == "first", "the oldest stays")
        #expect(history.newer(current: "first") == "second")
        #expect(history.newer(current: "second") == "", "past the last: the empty box")
        #expect(history.newer(current: "") == nil, "nothing to go forward to")
    }

    @Test func upIsTheBoxsOwnWhenThereIsTextOfTheUsersOrItWasChanged() {
        let history = ComposerHistory()
        history.add("first")
        #expect(history.older(current: "typing") == nil)
        #expect(history.older(current: "") == "first")
        #expect(history.older(current: "first, edited") == nil, "changed after it was brought back")
        #expect(history.newer(current: "first, edited") == nil)
    }

    @Test func aSendStartsOverAndRepeatsAndBlanksAreNotKept() {
        let history = ComposerHistory()
        history.add("a")
        history.add("a")
        history.add("   ")
        history.add("b")
        #expect(history.entries == ["a", "b"])
        _ = history.older(current: "")
        history.add("c")
        #expect(history.older(current: "") == "c")
    }

    @Test func onlyTheLastFiftyAreKept() {
        let history = ComposerHistory()
        for number in 0..<(ComposerHistory.limit + 5) { history.add("message \(number)") }
        #expect(history.entries.count == ComposerHistory.limit && history.entries.first == "message 5")
    }
}

struct AIPanelShortcutTests {
    @Test func theKeyOpensThenFocusesTheBoxThenCloses() {
        typealias Shortcut = AIPanelShortcut
        #expect(Shortcut.action(panelOpen: false, focusMode: false, box: .missing) == .open)
        #expect(Shortcut.action(panelOpen: true, focusMode: false, box: .elsewhere) == .focusBox)
        #expect(Shortcut.action(panelOpen: true, focusMode: false, box: .focused) == .close)
        #expect(Shortcut.action(panelOpen: true, focusMode: false, box: .missing) == .close, "no box to go to")
        #expect(Shortcut.action(panelOpen: true, focusMode: true, box: .focused) == .open, "in focus mode the panel is hidden, so the key shows it")
    }
}

@MainActor
struct ComposerKeyTests {
    private func press(_ keyCode: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    @Test func theKeysThePanelMayTakeAreArrowsEscTabAndPlainReturn() {
        #expect(ComposerTextView.key(for: press(126, "\u{F700}", modifiers: [.numericPad, .function])) == .up)
        #expect(ComposerTextView.key(for: press(125, "\u{F701}", modifiers: [.numericPad, .function])) == .down)
        #expect(ComposerTextView.key(for: press(53, "\u{1B}")) == .escape)
        #expect(ComposerTextView.key(for: press(48, "\t")) == .tab)
        #expect(ComposerTextView.key(for: press(36, "\r")) == .returnKey)
        #expect(ComposerTextView.key(for: press(36, "\r", modifiers: .command)) == nil, "⌘Return steers")
        #expect(ComposerTextView.key(for: press(36, "\r", modifiers: .shift)) == nil, "⇧Return breaks the line")
        #expect(ComposerTextView.key(for: press(126, "\u{F700}", modifiers: [.option, .numericPad, .function])) == nil)
        #expect(ComposerTextView.key(for: press(0, "a")) == nil)
    }

    @Test func aKeyTheHookTakesIsKeptFromTheTextAndOneItLeavesGoesOn() {
        let view = ComposerTextView()
        var taken: [ComposerKey] = []
        var sent = 0
        view.onReturn = { _, _ in sent += 1 }
        view.onKey = { key in taken.append(key); return key != .returnKey }
        view.string = "hi"
        view.keyDown(with: press(126, "\u{F700}", modifiers: [.numericPad, .function]))
        view.keyDown(with: press(53, "\u{1B}"))
        #expect(taken == [.up, .escape] && sent == 0)
        // Return the hook leaves is a send as ever.
        view.keyDown(with: press(36, "\r"))
        #expect(taken.last == .returnKey && sent == 1)
    }

    @Test func nothingIsTakenWhileAnInputMethodHoldsTextUnderComposition() {
        let view = ComposerTextView()
        var taken = 0
        view.onKey = { _ in taken += 1; return true }
        view.string = "안녕"
        view.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 2, length: 0))
        view.keyDown(with: press(53, "\u{1B}"))
        view.keyDown(with: press(36, "\r"))
        #expect(taken == 0, "Esc and Return belong to the input method then")
    }
}

struct AIPanelWidthTests {
    @Test func theWidthStaysBetweenTheLeastAndTheMost() {
        #expect(Preferences.clampedAIPanelWidth(100) == 300)
        #expect(Preferences.clampedAIPanelWidth(420) == 420)
        #expect(Preferences.clampedAIPanelWidth(900) == 560)
        #expect(Preferences.aiPanelWidths.contains(Preferences.defaultAIPanelWidth))
    }

    @Test func aNarrowWindowKeepsTheRoomOfThePageBeforeTheWidthChosen() {
        #expect(Preferences.aiPanelWidth(560, available: 1400) == 560)
        #expect(Preferences.aiPanelWidth(560, available: 800) == 480, "the page keeps its 320")
        #expect(Preferences.aiPanelWidth(560, available: 500) == 300, "never under the least")
        #expect(Preferences.aiPanelWidth(900, available: 2000) == 560)
    }
}

struct PageKindTests {
    private func kind(_ address: String, _ signals: PageKind.Signals? = nil) -> PageKind {
        PageKind.classify(url: URL(string: address), signals: signals)
    }

    @Test func searchResultsVideoAndProductPagesAreKnownByWhereTheyAre() {
        #expect(kind("https://www.google.com/search?q=swift") == .search)
        #expect(kind("https://search.naver.com/search.naver?query=swift") == .search)
        #expect(kind("https://duckduckgo.com/?q=swift") == .search)
        #expect(kind("https://www.google.com/") == .general, "the home page is no results")
        #expect(kind("https://www.google.com/search") == .general, "no query")
        #expect(kind("https://www.youtube.com/watch?v=abc") == .video)
        #expect(kind("https://youtu.be/abc") == .video)
        #expect(kind("https://www.youtube.com/results?search_query=swift") == .search)
        #expect(kind("https://www.youtube.com/") == .general)
        #expect(kind("https://vimeo.com/12345") == .video)
        #expect(kind("https://www.amazon.com/Some-Thing/dp/B000") == .product)
        #expect(kind("https://www.amazon.com/s?k=thing") == .general)
        #expect(kind("https://www.coupang.com/vp/products/123") == .product)
    }

    @Test func otherPagesAreToldByWhatTheySayAndWhatTheyLookLike() {
        typealias Signals = PageKind.Signals
        #expect(kind("https://x.test/a", Signals(ogType: "article")) == .article)
        #expect(kind("https://x.test/a", Signals(ldTypes: ["NewsArticle"])) == .article)
        #expect(kind("https://x.test/a", Signals(ldTypes: ["WebSite", "Product"])) == .product)
        #expect(kind("https://x.test/a", Signals(ogType: "product")) == .product)
        #expect(kind("https://x.test/a", Signals(ogType: "video.other")) == .video)
        #expect(kind("https://x.test/a", Signals(ldTypes: ["VideoObject"])) == .video)
        #expect(kind("https://x.test/a", Signals(fields: 4)) == .form)
        #expect(kind("https://x.test/a", Signals(fields: 2)) == .general, "a search box or a login is not a form to fill")
        #expect(kind("https://x.test/a", Signals(ogType: "article", fields: 4)) == .article, "an article with a comment form is an article")
        #expect(kind("https://x.test/a", Signals(videos: 1)) == .video)
        #expect(kind("https://x.test/a", Signals(articleCharacters: 4000)) == .article)
        #expect(kind("https://x.test/a", Signals(articleCharacters: 400)) == .general)
        #expect(kind("https://x.test/a", Signals()) == .general)
        #expect(kind("about:blank", Signals(fields: 9)) == .general)
        #expect(PageKind.classify(url: nil, signals: nil) == .general)
    }

    @Test func everyKindHasThreeDifferentSuggestions() {
        for kind in [PageKind.general, .video, .article, .product, .form, .search] {
            #expect(kind.prompts.count == 3 && Set(kind.prompts).count == 3, "\(kind)")
        }
        #expect(PageKind.form.prompts.first == "Help me fill this form")
        #expect(PageKind.search.prompts.first == "Open the top 3 results and compare")
    }

    @Test func aSelectionIsQuotedLineByLineAndCutShort() {
        #expect(ComposerQuote.block(from: "  one\ntwo  ") == "> one\n> two\n\n")
        #expect(ComposerQuote.block(from: " \n ") == nil)
        let long = ComposerQuote.block(from: String(repeating: "a", count: 5000))!
        #expect(long.count < 2100 && long.contains("…"))
    }
}

extension SharedAgentState {
    @MainActor @Suite
    struct PageProbeTests {
        private func probe(_ html: String) async throws -> PageKind.Signals {
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
            let window = OffscreenWindow(view)
            defer { window.close() }
            view.loadHTMLString(html, baseURL: URL(string: "https://probe.test/page"))
            _ = await waitUntil(5) { !view.isLoading && view.url != nil }
            try await Task.sleep(for: .milliseconds(200))
            let answer = try await view.callAsyncJavaScript(PageKind.probe, contentWorld: .defaultClient) as? [String: Any]
            return PageKind.Signals(try #require(answer))
        }

        @Test func theProbeSeesWhatThePageSaysItIsAndItsForms() async throws {
            let article = try await probe(#"<html><head><meta property="og:type" content="Article"></head><body><article><p>text</p></article></body></html>"#)
            #expect(article.ogType == "article" && article.articleCharacters > 0)
            let product = try await probe(#"<html><head><script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"WebSite"},{"@type":["Product","Thing"]}]}</script></head><body>x</body></html>"#)
            #expect(Set(product.ldTypes) == ["WebSite", "Product", "Thing"])
            let form = try await probe("<form><input type=text><input type=email><textarea></textarea><input type=password><input type=submit></form>")
            #expect(form.fields == 3 && PageKind.classify(url: URL(string: "https://probe.test/a"), signals: form) == .form)
            let search = try await probe("<form role=search><input type=text><input type=text><input type=text><input type=text></form>")
            #expect(search.fields == 0)
            let video = try await probe(#"<video width="640" height="360" style="display:block"></video>"#)
            #expect(video.videos == 1)
            let plain = try await probe("<p>Hello</p>")
            #expect(plain == PageKind.Signals())
        }
    }
}
