import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Changmun

/// A site's own CSS: which sites a style is for, what is kept and what is dropped, and that it is in the page the moment the page starts.
@Suite(.serialized)
struct SiteStylesTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "site-styles-\(UUID().uuidString)")! }

    private func style(_ host: String, _ css: String = "p { color: red }", on: Bool = true) -> SiteStyle {
        SiteStyle(host: host, css: css, isOn: on)
    }

    // MARK: Sites

    @Test func aTypedAddressIsReducedToItsSite() {
        for typed in ["example.com", "EXAMPLE.com", "www.example.com", "https://www.Example.com/a/b?c=d#e", "example.com/path", "example.com:8080", "  example.com  ", "example.com."] {
            #expect(SiteStyle.normalizedHost(typed) == "example.com", "\(typed)")
        }
        #expect(SiteStyle.normalizedHost("localhost:3000") == "localhost")
        #expect(SiteStyle.normalizedHost("192.168.0.1:80/x") == "192.168.0.1")
        #expect(SiteStyle.normalizedHost("") == nil)
        #expect(SiteStyle.normalizedHost("two words.com") == nil)
        #expect(SiteStyle.normalizedHost("https://") == nil)
    }

    @Test func aStyleIsForItsSiteAndTheSitesUnderIt() {
        #expect(SiteStyle.applies(site: "example.com", to: "example.com"))
        #expect(SiteStyle.applies(site: "example.com", to: "www.example.com"))
        #expect(SiteStyle.applies(site: "example.com", to: "WWW.Example.COM"))
        #expect(SiteStyle.applies(site: "example.com", to: "mail.example.com"))
        #expect(SiteStyle.applies(site: "example.com", to: "example.com."))
        #expect(!SiteStyle.applies(site: "example.com", to: "notexample.com"))
        #expect(!SiteStyle.applies(site: "example.com", to: "example.com.evil.example"))
        #expect(!SiteStyle.applies(site: "example.com", to: "com"))
        #expect(!SiteStyle.applies(site: "mail.example.com", to: "example.com"), "a style for a part of a site is not for the whole")
        #expect(!SiteStyle.applies(site: "example.com", to: nil))
        #expect(!SiteStyle.applies(site: "example.com", to: ""))
    }

    @Test func aNameEveryoneRegistersUnderIsNoSite() {
        for site in ["com", "co.kr", "github.io", "tistory.com", "wiki"] {
            #expect(SiteStyle.problem(host: site, css: "p {}", among: []) == .tooBroad, "\(site)")
        }
        for site in ["example.com", "alice.github.io", "naver.com", "localhost", "127.0.0.1", "intranet.corp.example"] {
            #expect(SiteStyle.problem(host: site, css: "p {}", among: []) == nil, "\(site)")
        }
    }

    @Test func aStyleNeedsASiteThatIsOneAndSomeCSSAndOneStylePerSite() {
        let kept = style("example.com")
        #expect(SiteStyle.problem(host: " ", css: "p {}", among: []) == .noSite)
        #expect(SiteStyle.problem(host: "not a site", css: "p {}", among: []) == .badSite)
        #expect(SiteStyle.problem(host: "https://", css: "p {}", among: []) == .badSite)
        #expect(SiteStyle.problem(host: "exa$mple.com", css: "p {}", among: []) == .badSite)
        #expect(SiteStyle.problem(host: "www.example.com", css: "p {}", among: [kept]) == .alreadyStyled, "www. is the same site")
        #expect(SiteStyle.problem(host: "example.com", css: "p {}", among: [kept], ignoring: kept.id) == nil, "editing a style does not collide with itself")
        #expect(SiteStyle.problem(host: "mail.example.com", css: "p {}", among: [kept]) == nil, "a site under another is its own")
        #expect(SiteStyle.problem(host: "other.com", css: " \n ", among: []) == .noCSS)
        #expect(SiteStyle.problem(host: "other.com", css: String(repeating: "a", count: SiteStyle.maxLength + 1), among: []) == .tooLong)
        #expect(SiteStyle.problem(host: "other.com", css: String(repeating: "a", count: SiteStyle.maxLength), among: []) == nil)
    }

    @Test func everyReasonIsSaidInWords() {
        let problems: [SiteStyle.Problem] = [.noSite, .badSite, .tooBroad, .alreadyStyled, .noCSS, .tooLong, .tooMuch, .tooMany]
        for problem in problems { #expect(problem.reason.count > 10, "\(problem)") }
    }

    @Test func thereIsALimitOnHowManyStylesAndHowMuchCSSInAll() {
        let full = (0..<SiteStyle.maxCount).map { style("site\($0).example", "p {}") }
        #expect(SiteStyle.problem(host: "one-more.example", css: "p {}", among: full) == .tooMany)
        #expect(SiteStyle.problem(host: "site3.example", css: "q {}", among: full, ignoring: full[3].id) == nil, "editing one of the hundred is not adding a hundred and first")
        let big = (0..<20).map { style("big\($0).example", String(repeating: "a", count: SiteStyle.maxTotal / 20)) }
        #expect(SiteStyle.problem(host: "next.example", css: "a", among: big) == .tooMuch)
        #expect(SiteStyle.problem(host: "big3.example", css: String(repeating: "b", count: SiteStyle.maxTotal / 20), among: big, ignoring: big[3].id) == nil, "a style is counted without its own old text")
        #expect(SiteStyle.problem(host: "big3.example", css: String(repeating: "b", count: SiteStyle.maxTotal / 20 + 1), among: big, ignoring: big[3].id) == .tooMuch)
        #expect(SiteStyle.maxCount * SiteStyle.maxLength > SiteStyle.maxTotal, "the total, not the count times the length, is what bounds the script")
    }

    // MARK: What is kept

    @Test func whatIsStoredComesBackAsItWas() {
        let defaults = defaults()
        let styles = [style("example.com", "a { color: red }"), style("naver.com", "b {}", on: false)]
        SiteStyle.store(styles, in: defaults)
        #expect(SiteStyle.stored(in: defaults) == styles)
        SiteStyle.store([], in: defaults)
        #expect(defaults.data(forKey: SiteStyle.defaultsKey) == nil, "nothing is kept for no styles")
        #expect(SiteStyle.stored(in: defaults).isEmpty)
    }

    @Test func aDamagedEntryLosesItselfAndNoOther() throws {
        let defaults = defaults()
        let good = style("example.com")
        let encoded = try JSONEncoder().encode(good)
        let json = """
        [\(String(decoding: encoded, as: UTF8.self)),
         {"id": "not-a-uuid", "host": "bad.com", "css": "p {}"},
         {"id": "\(UUID().uuidString)", "host": "com", "css": "p {}"},
         {"id": "\(UUID().uuidString)", "host": "Mixed.Example", "css": "p {}"},
         {"id": "\(UUID().uuidString)", "host": "empty.example", "css": "   "},
         {"id": "\(UUID().uuidString)", "host": "example.com", "css": "second for the same site"},
         {"id": "\(UUID().uuidString)", "host": "old.example", "css": "q {}"},
         "nonsense", 7]
        """
        defaults.set(Data(json.utf8), forKey: SiteStyle.defaultsKey)
        let loaded = SiteStyle.load(in: defaults)
        let kept = loaded.styles
        #expect(kept.map(\.host) == ["example.com", "old.example"], "no entry that is not as it is written, covers too much, is empty or repeats a site")
        #expect(kept.last?.isOn == true, "an entry without the switch is on")
        #expect(loaded.setAside.count == 7, "and every other entry is put aside, not lost")
        defaults.set(Data("not json".utf8), forKey: SiteStyle.defaultsKey)
        #expect(SiteStyle.stored(in: defaults).isEmpty)
        #expect(SiteStyle.load(in: defaults).setAside.count == 1)
        defaults.set("a string", forKey: SiteStyle.defaultsKey)
        #expect(SiteStyle.stored(in: defaults).isEmpty)
        #expect(SiteStyle.load(in: defaults).setAside.count == 1)
    }

    @Test func whatCantBeUsedIsKeptThroughEverySaveUntilTheUserDiscardsIt() async throws {
        try await MainActor.run {
            let defaults = defaults()
            // A site that is a public suffix now, a damaged entry, and a style over the limit of length.
            let json = """
            [{"id": "\(UUID().uuidString)", "host": "co.kr", "css": "p { color: red }", "isOn": true},
             {"id": "broken", "host": "bad.example", "css": "p { color: blue }"},
             {"id": "\(UUID().uuidString)", "host": "long.example", "css": "\(String(repeating: "a", count: SiteStyle.maxLength + 1))"}]
            """
            defaults.set(Data(json.utf8), forKey: SiteStyle.defaultsKey)
            let styles = SiteStyles(defaults: defaults)
            #expect(styles.styles.isEmpty && styles.setAside.count == 3)
            _ = styles.save(SiteStyle(host: "example.com", css: "p {}"))
            styles.setOn(false, covering: "example.com")
            styles.remove(styles.styles[0].id)
            let again = SiteStyle.load(in: defaults)
            #expect(again.styles.isEmpty && again.setAside.count == 3, "saving, switching and removing left them as they were")
            #expect(again.setAside.contains { $0.contains("co.kr") && $0.contains("p { color: red }") } && again.setAside.contains { $0.contains("bad.example") })
            #expect(SiteStyles(defaults: defaults).setAside.count == 3, "and they are there at the next start, to be looked at again")
            styles.discardSetAside()
            #expect(styles.setAside.isEmpty && SiteStyle.load(in: defaults).setAside.isEmpty)
            #expect(defaults.data(forKey: SiteStyle.defaultsKey) == nil, "nothing is kept for nothing")
        }
    }

    @Test func aLimitLowerThanWhatWasSavedBeforeDoesNotPutAnythingAside() {
        let defaults = defaults()
        let many = (0..<(SiteStyle.maxCount + 5)).map { style("site\($0).example", "p {}") }
        SiteStyle.store(many, in: defaults)
        let loaded = SiteStyle.load(in: defaults)
        #expect(loaded.styles.count == many.count && loaded.setAside.isEmpty, "the limit is for what is added")
    }

    @Test func editingChangesTheSiteAndTheCSSAndNothingElse() async {
        await MainActor.run {
            let styles = SiteStyles(defaults: defaults())
            let one = style("example.com", "a {}")
            _ = styles.save(one)
            styles.setOn(false, for: one.id)
            #expect(styles.update(one.id, host: "www.Example.org", css: "b {}") == nil)
            #expect(styles.styles.map(\.host) == ["example.org"] && styles.styles[0].css == "b {}")
            #expect(styles.styles[0].isOn == false, "a switch turned off while the style was being edited stays off")
            #expect(styles.update(one.id, host: "", css: "b {}") == .noSite)
            styles.remove(one.id)
            #expect(styles.update(one.id, host: "example.org", css: "c {}") == nil)
            #expect(styles.styles.isEmpty, "a style removed while it was being edited is not made again")
        }
    }

    // MARK: What goes in a page

    @Test func theCSSForAHostIsOnlyThatOfStylesThatAreOnAndCoverIt() {
        let styles = [style("example.com", "/*wide*/"), style("mail.example.com", "/*narrow*/"), style("other.com", "/*other*/"), style("off.example.com", "/*off*/", on: false)]
        #expect(SiteStyle.css(for: "mail.example.com", in: styles) == "/*wide*/\n/*narrow*/", "the wider site first, so the narrower one wins a tie")
        #expect(SiteStyle.css(for: "www.example.com", in: styles) == "/*wide*/")
        #expect(SiteStyle.css(for: "off.example.com", in: styles) == "/*wide*/")
        #expect(SiteStyle.css(for: "elsewhere.com", in: styles) == "")
        #expect(SiteStyle.css(for: nil, in: styles) == "")
        let reversed = [styles[1], styles[0]]
        #expect(SiteStyle.css(for: "mail.example.com", in: reversed) == "/*wide*/\n/*narrow*/", "whatever order they were added in")
    }

    @Test func theScriptCarriesTheCSSWhateverIsInIt() throws {
        let nasty = "a::before { content: \"\\\"</script>'\u{2028}`${x}\" }\n/* \\ */"
        let script = SiteStyle.script(for: [style("example.com", nasty)])
        #expect(script.contains("\"example.com\""))
        let data = try JSONSerialization.data(withJSONObject: SiteStyle.rules(of: [style("example.com", nasty)]))
        #expect(try JSONSerialization.jsonObject(with: data) as? [[String]] == [["example.com", nasty]])
    }
}

/// The CSS is in the page from the first moment, only on its site, and follows a switch without a reload.
@MainActor @Suite(.serialized)
struct SiteStylesInPageTests {
    private func styles(_ list: [SiteStyle]) -> SiteStyles {
        let defaults = UserDefaults(suiteName: "site-styles-\(UUID().uuidString)")!
        SiteStyle.store(list, in: defaults)
        return SiteStyles(defaults: defaults)
    }

    private func page(_ styles: SiteStyles, at base: String, body: String = "<p>Hello</p>") async throws -> (WKWebView, NSWindow) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        styles.install(in: config.userContentController)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        styles.openWebViews = { [view] }
        view.loadHTMLString(body, baseURL: URL(string: base))
        let end = Date().addingTimeInterval(60)
        // WebKit writes the host in lower case.
        let loaded = { !view.isLoading && view.url?.absoluteString.lowercased() == base.lowercased() }
        while !loaded() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        try #require(loaded(), "the page never loaded")
        return (view, window)
    }

    private func color(of selector: String = "p", in view: WKWebView) async throws -> String {
        try #require(try await view.evaluateJavaScript("getComputedStyle(document.querySelector('\(selector)')).color") as? String)
    }

    private let red = "rgb(255, 0, 0)"
    private let black = "rgb(0, 0, 0)"

    @Test func theCSSIsAppliedOnTheSiteAndTheHostsUnderItAndNowhereElse() async throws {
        let styles = styles([SiteStyle(host: "example.com", css: "p { color: red }")])
        for (address, expected) in [("https://example.com/", red), ("https://www.example.com/a", red), ("https://mail.example.com/", red),
                                    ("https://notexample.com/", black), ("https://example.com.evil.example/", black), ("https://example.org/", black)] {
            let (view, window) = try await page(styles, at: address)
            defer { window.close() }
            #expect(try await color(in: view) == expected, "\(address)")
        }
    }

    @Test func thePageScriptAndTheSwiftSideAgreeOnWhichHostsAreCovered() async throws {
        // The script and `SiteStyle.applies` each match a host: they must say the same of every host.
        let styles = styles([SiteStyle(host: "example.com", css: "p { color: red }")])
        for address in ["https://example.com/", "https://WWW.Example.com/", "https://a.b.example.com/", "https://xexample.com/", "https://example.com.cn/", "https://www.www.example.com/"] {
            let (view, window) = try await page(styles, at: address)
            defer { window.close() }
            let host = try #require(URL(string: address)?.host())
            #expect((try await color(in: view) == red) == SiteStyle.applies(site: "example.com", to: host), "\(address)")
        }
    }

    @Test func theCSSIsThereBeforeThePageIsDrawnAndWinsOverIt() async throws {
        let styles = styles([SiteStyle(host: "example.com", css: "p { color: red !important } .later { color: red }")])
        let body = "<style>p { color: blue !important } .later { color: blue }</style><p>one</p><p class=later>two</p>"
        let (view, window) = try await page(styles, at: "https://example.com/", body: body)
        defer { window.close() }
        #expect(try await color(in: view) == red, "an !important rule of the user's beats the page's")
        #expect(try await color(of: ".later", in: view) == red, "and a plain one beats a plain one: the user's sheet comes after the page's")
    }

    @Test func aStyleThatIsOffIsNotInThePage() async throws {
        let styles = styles([SiteStyle(host: "example.com", css: "p { color: red }", isOn: false)])
        let (view, window) = try await page(styles, at: "https://example.com/")
        defer { window.close() }
        #expect(try await color(in: view) == black)
    }

    @Test func theSwitchAndTheEditsReachThePageThatIsOpenAndTheNextOne() async throws {
        let styles = styles([])
        let (view, window) = try await page(styles, at: "https://example.com/")
        defer { window.close() }
        #expect(try await color(in: view) == black)
        let saved = SiteStyle(host: "www.Example.com", css: "p { color: red }")
        #expect(styles.save(saved) == nil)
        #expect(styles.styles.map(\.host) == ["example.com"], "kept as the site, not as typed")
        #expect(try await color(in: view) == red, "a style added is in the open page without a reload")
        styles.setOn(false, for: saved.id)
        #expect(try await color(in: view) == black, "off takes it out of the open page")
        styles.setOn(true, covering: "mail.example.com")
        #expect(try await color(in: view) == red, "and the site settings' switch turns it on again")
        var edited = saved
        edited.css = "p { color: rgb(1, 2, 3) }"
        #expect(styles.save(edited) == nil)
        #expect(try await color(in: view) == "rgb(1, 2, 3)", "an edit replaces what was there")
        // A page opened after a change gets it from the web view's own scripts.
        let (next, nextWindow) = try await page(styles, at: "https://example.com/next")
        defer { nextWindow.close() }
        styles.openWebViews = { [view, next] }
        #expect(try await color(in: next) == "rgb(1, 2, 3)")
        styles.remove(saved.id)
        #expect(try await color(in: view) == black, "a style taken out is gone from the open page")
        let (after, afterWindow) = try await page(styles, at: "https://example.com/after")
        defer { afterWindow.close() }
        #expect(try await color(in: after) == black)
    }

    @Test(arguments: [true, false]) func onlyTheScriptOfTheStylesIsReplacedWhicheverWayItIsTakenOut(privateCall: Bool) async throws {
        let styles = styles([SiteStyle(host: "example.com", css: "p { color: red }")])
        styles.usesPrivateRemoval = privateCall
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: "window.somebodyElses = 1", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        styles.install(in: config.userContentController)
        #expect(config.userContentController.userScripts.count == 2)
        styles.setOn(false, covering: "example.com")
        #expect(config.userContentController.userScripts.count == 1, "no style on: only the other script is left")
        styles.setOn(true, covering: "example.com")
        styles.save(SiteStyle(host: "other.com", css: "p {}"))
        #expect(config.userContentController.userScripts.count == 2, "a script of the styles, once, beside the other")
        #expect(config.userContentController.userScripts.first?.source == "window.somebodyElses = 1")
        let view = WKWebView(frame: .zero, configuration: config)
        styles.openWebViews = { [view] }
        view.loadHTMLString("<p>Hello</p>", baseURL: URL(string: "https://example.com/"))
        while view.isLoading || view.url == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try await view.evaluateJavaScript("String(window.somebodyElses) + getComputedStyle(document.querySelector('p')).color") as? String == "1rgb(255, 0, 0)")
    }

    @Test func aStyleThatCantBeKeptIsNotSavedAndSaysWhy() {
        let styles = styles([SiteStyle(host: "example.com", css: "p {}")])
        #expect(styles.save(SiteStyle(host: "co.kr", css: "p {}")) == .tooBroad)
        #expect(styles.save(SiteStyle(host: "example.com", css: "q {}")) == .alreadyStyled)
        #expect(styles.save(SiteStyle(host: "other.com", css: "")) == .noCSS)
        #expect(styles.styles.map(\.host) == ["example.com"])
    }

    @Test func changesAreKeptOnThisMacOnly() {
        let defaults = UserDefaults(suiteName: "site-styles-\(UUID().uuidString)")!
        let styles = SiteStyles(defaults: defaults)
        #expect(styles.save(SiteStyle(host: "example.com", css: "p { color: red }")) == nil)
        #expect(SiteStyles(defaults: defaults).styles.map(\.host) == ["example.com"], "what was saved is there at the next start")
        styles.setOn(false, covering: "example.com")
        #expect(SiteStyles(defaults: defaults).styles.first?.isOn == false)
        styles.remove(styles.styles[0].id)
        #expect(SiteStyles(defaults: defaults).styles.isEmpty)
    }

    /// What the page's own scripts can and can't do with a style. The script runs in a world of its own, which hides its variables; but the
    /// style sheet it makes is part of the document, so the page can read its rules (a site can see which elements a user hides) and can take
    /// it away. This is a fact of putting CSS in a page, and the guide says so: this test is here so that nobody takes it for a secret again.
    @Test func thePagesOwnScriptsCanSeeTheSheetAndTakeItAwayAndOnlyTheScriptsVariablesAreHidden() async throws {
        let styles = styles([SiteStyle(host: "example.com", css: "p { color: red } .hidden { display: none }")])
        let (view, window) = try await page(styles, at: "https://example.com/")
        defer { window.close() }
        let seen = try await view.evaluateJavaScript("typeof globalThis.changmunSiteSheet + typeof globalThis.changmunSiteStyles")
        #expect(seen as? String == "undefinedundefined", "the script's variables are not in the page's own world")
        let inWorld = try await view.evaluateJavaScript("typeof globalThis.changmunSiteSheet", in: nil, contentWorld: SiteStyles.world)
        #expect(inWorld as? String == "object")
        let rules = try await view.evaluateJavaScript("Array.from(document.adoptedStyleSheets).flatMap(s => Array.from(s.cssRules).map(r => r.selectorText + '|' + r.style.cssText)).join(';')") as? String
        #expect(rules?.contains("p|color: red") == true && rules?.contains(".hidden|display: none") == true, "the page reads the user's rules through the document")
        _ = try await view.evaluateJavaScript("document.adoptedStyleSheets = []; 0")
        #expect(try await color(in: view) == black, "and takes the style away")
        styles.setOn(false, covering: "example.com")
        styles.setOn(true, covering: "example.com")
        #expect(try await color(in: view) == red, "turning the style off and on again puts it back")
    }
}


/// The CSS editor takes nothing typed for prose: no curly quotes, dashes, replaced text or corrected words in what is meant to be code.
@MainActor @Suite(.serialized)
struct CSSEditorTests {
    private func textView(in view: NSView) -> NSTextView? {
        if let found = view as? NSTextView { return found }
        for sub in view.subviews { if let found = textView(in: sub) { return found } }
        return nil
    }

    private final class Box { var text = "" }

    @Test func nothingIsSubstitutedOrCorrectedAsItIsTyped() throws {
        let box = Box()
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let host = NSHostingView(rootView: Form { CSSEditor(text: binding).frame(height: 128) }.formStyle(.grouped).frame(width: 400, height: 300))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let view = try #require(textView(in: host))
        #expect(!view.isAutomaticQuoteSubstitutionEnabled && !view.isAutomaticDashSubstitutionEnabled)
        #expect(!view.isAutomaticTextReplacementEnabled && !view.isAutomaticSpellingCorrectionEnabled)
        #expect(!view.isAutomaticLinkDetectionEnabled && !view.isAutomaticDataDetectionEnabled && !view.isAutomaticTextCompletionEnabled)
        #expect(!view.isContinuousSpellCheckingEnabled && !view.isGrammarCheckingEnabled && !view.smartInsertDeleteEnabled)
        #expect(!view.isRichText && view.allowsUndo)
        #expect(view.accessibilityLabel() == String(localized: "CSS"))
        // What is typed reaches the text it edits, exactly as typed.
        let typed = "a::before { content: \"x\"; --bg: 1; font-family: 'Inter' }"
        view.insertText(typed, replacementRange: NSRange(location: 0, length: 0))
        #expect(view.string == typed && box.text == typed)
    }
}
