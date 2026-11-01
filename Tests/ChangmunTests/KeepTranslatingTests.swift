import AppKit
import Combine
import Foundation
import Testing
import WebKit
@testable import Changmun

// MARK: Pure parts

struct KeepTranslatingPureTests {
    @Test func aKeptSiteIsOneHostWithOrWithoutWWWAndNothingUnderOrAboveIt() {
        for (kept, host, matches) in [
            ("example.com", "example.com", true), ("example.com", "www.example.com", true), ("example.com", "WWW.Example.com", true),
            ("www.example.com", "example.com", true),
            ("example.com", "mail.example.com", false), ("example.com", "a.b.example.com", false),
            ("mail.example.com", "example.com", false), ("mail.example.com", "www.example.com", false), ("mail.example.com", "mail.example.com", true),
            ("example.com", "notexample.com", false), ("example.com", "example.com.evil.test", false), ("example.com", "", false),
        ] {
            #expect(Preferences.matchesExactly(host, [kept]) == matches, "\(kept) and \(host)")
        }
        #expect(!Preferences.matchesExactly(nil, ["example.com"]))
        // Saved lower case, without "www.", once; taken off by that host alone.
        #expect(Preferences.adding("www.Naver.com", to: []) == ["naver.com"])
        #expect(Preferences.removingExactly("mail.naver.com", from: ["naver.com", "mail.naver.com"]) == ["naver.com"])
        #expect(Preferences.removingExactly("www.naver.com", from: ["naver.com", "mail.naver.com"]) == ["mail.naver.com"])
        #expect(Preferences.removingExactly("naver.com", from: ["mail.naver.com"]) == ["mail.naver.com"], "a site above is not what is taken off")
        // The pop-up sites are as they were.
        #expect(Preferences.matches("mail.example.com", ["example.com"]))
    }

    @MainActor @Test func theSettingIsStoredAsAListOfHostsAndMatchedExactly() {
        let prefs = Preferences.shared
        let saved = prefs.translatedHosts
        defer { prefs.translatedHosts = saved }
        prefs.translatedHosts = ["comic.test"]
        #expect(prefs.keepsTranslating("www.comic.test") && prefs.keepsTranslating("comic.test"))
        #expect(!prefs.keepsTranslating("m.comic.test") && !prefs.keepsTranslating("comic.example") && !prefs.keepsTranslating(nil))
        #expect(UserDefaults.standard.stringArray(forKey: "translatedHosts") == ["comic.test"])
    }

    @Test func aPageTranslatesByItselfOnlyOnAKeptSiteInAWindowThatMayAndNotYetTranslated() {
        func decides(_ host: String? = "comic.test", kept: [String] = ["comic.test"], isPrivate: Bool = false, translation: Tab.Translation = .original) -> Bool {
            Tab.translatesByItself(host: host, kept: kept, isPrivate: isPrivate, translation: translation)
        }
        #expect(decides())
        #expect(decides("www.comic.test"))
        #expect(!decides("m.comic.test"), "another host of the site")
        #expect(!decides(kept: []), "a site that is not kept")
        #expect(!decides("other.test"))
        #expect(!decides(nil))
        #expect(!decides(isPrivate: true), "a private window")
        #expect(!decides(translation: .translating) && !decides(translation: .translated), "already under way, or done")
    }

    @Test func aPageSpendsOneAllowanceInAllAndTheFollowUpsGetWhatIsLeft() {
        func pieces(_ count: Int, size: Int, from first: Int = 0) -> [ClaudeTranslation.Piece] { (0..<count).map { (id: first + $0, text: String(repeating: "w", count: size)) } }
        // 140,000 characters in the first pass leave 10,000: of 20 pieces of 1000, ten go and ten are left out, and the page is used up.
        let first = ClaudeTranslation.limited(pieces(140, size: 1000))
        #expect(first.leftOut == 0 && !first.spent.exhausted && first.spent.characters == 140_000)
        let second = ClaudeTranslation.limited(pieces(20, size: 1000, from: 140), after: first.spent)
        #expect(second.batches.flatMap { $0 }.count == 10 && second.leftOut == 10)
        #expect(second.spent.exhausted && second.spent.characters == 150_000)
        // Used up, nothing more goes, however little it is.
        let third = ClaudeTranslation.limited(pieces(1, size: 1), after: second.spent)
        #expect(third.batches.isEmpty && third.leftOut == 1)
        // The batches are shared as well: with one left, the second of two batches is left out.
        let almost = ClaudeTranslation.Budget(characters: 0, batches: ClaudeTranslation.maxBatches - 1)
        let batches = ClaudeTranslation.limited(pieces(ClaudeTranslation.batchPieces + 1, size: 1), after: almost)
        #expect(batches.batches.count == 1 && batches.leftOut == 1 && batches.spent.batches == ClaudeTranslation.maxBatches && batches.spent.exhausted)
        // A piece too long for a batch is left out, but it does not use the page up.
        let long = ClaudeTranslation.limited(pieces(1, size: ClaudeTranslation.batchCharacters + 1))
        #expect(long.leftOut == 1 && !long.spent.exhausted)
        // Used up stays used up.
        #expect(ClaudeTranslation.limited([], after: second.spent).spent.exhausted)
    }

    @MainActor @Test func followUpsSayNothingWhenAllIsTranslatedOrNothingFoundAndNeverTheSameTwice() {
        var state = PageTranslator.FollowUpState()
        #expect(state.message(for: .translated) == nil)
        #expect(state.message(for: .nothingToTranslate) == nil)
        let failed = PageTranslator.statusMessage(for: .claudeFailed)
        #expect(state.message(for: .claudeFailed) == failed)
        #expect(state.message(for: .claudeFailed) == nil, "the same again")
        #expect(state.message(for: .translatedPartly) == PageTranslator.statusMessage(for: .translatedPartly))
        #expect(state.message(for: .claudeFailed) == failed, "another in between")
        #expect(state.say(nil) == nil)
    }

    @Test func aSiteMaySendThreeHundredThousandCharactersAndOneTwentyBatchesInAnyTenMinutes() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var window = ClaudeWindow()
        #expect(window.remaining(for: "comic.test", at: start) == (300_000, 120))
        window.record(characters: 100_000, batches: 30, for: "comic.test", at: start)
        window.record(characters: 150_000, batches: 80, for: "comic.test", at: start.addingTimeInterval(300))
        #expect(window.remaining(for: "comic.test", at: start.addingTimeInterval(301)) == (50_000, 10))
        #expect(!window.isUsedUp("comic.test", at: start.addingTimeInterval(301)))
        // The first goes out of the window as the clock goes on: it slides, it does not start over.
        #expect(window.remaining(for: "comic.test", at: start.addingTimeInterval(601)) == (150_000, 40))
        #expect(window.remaining(for: "comic.test", at: start.addingTimeInterval(901)) == (300_000, 120))
        // Either one used up is used up.
        window.record(characters: 0, batches: 120, for: "batches.test", at: start)
        window.record(characters: 300_000, batches: 1, for: "characters.test", at: start)
        #expect(window.isUsedUp("batches.test", at: start) && window.isUsedUp("characters.test", at: start))
        // One site's is not another's.
        #expect(window.remaining(for: "other.test", at: start) == (300_000, 120))
        // Nothing negative, whatever was spent (the user's own presses are not held to it).
        window.record(characters: 500_000, batches: 500, for: "press.test", at: start)
        #expect(window.remaining(for: "press.test", at: start) == (0, 0))
    }

    @Test func theUserIsToldOnceForASiteInEachWindow() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var window = ClaudeWindow()
        let told = [window.tellsPaused("comic.test", at: start), window.tellsPaused("comic.test", at: start.addingTimeInterval(1)),
                    window.tellsPaused("comic.test", at: start.addingTimeInterval(599)), window.tellsPaused("other.test", at: start.addingTimeInterval(1)),
                    window.tellsPaused("comic.test", at: start.addingTimeInterval(601))]
        #expect(told == [true, false, false, true, true], "told once, not again in the window, another site, the next window")
    }

    @MainActor @Test func theSitesAreKeyedByHostWithoutWWW() {
        #expect(AutomaticClaude.site(of: "WWW.Comic.test") == "comic.test" && AutomaticClaude.site(of: "mail.comic.test") == "mail.comic.test")
        #expect(AutomaticClaude.site(of: nil) == nil && AutomaticClaude.site(of: "") == nil)
    }

    @Test func aRunIsHeldToTheSmallerOfThePageAndTheWindow() {
        let page = ClaudeTranslation.Budget(characters: 100_000, batches: 10)
        // The page has 50,000 characters left and the window 20,000: the window is what is nearer.
        let byWindow = page.narrowed(toCharacters: 20_000, batches: 100)
        #expect(byWindow.byWindow)
        let pieces = (0..<40).map { (id: $0, text: String(repeating: "w", count: 1000)) }
        let sent = ClaudeTranslation.limited(pieces, after: byWindow.budget)
        #expect(sent.batches.flatMap { $0 }.count == 20 && sent.spent.spent(since: byWindow.budget).characters == 20_000 && sent.spent.exhausted)
        // The page has less left than the window: the page's.
        let byPage = page.narrowed(toCharacters: 200_000, batches: 100)
        #expect(!byPage.byWindow && byPage.budget == page)
        // A run that is the user's is given the page's alone: the caller does not narrow it.
        #expect(ClaudeTranslation.limited(pieces, after: page).batches.flatMap { $0 }.count == 40)
    }

    @MainActor @Test func theFollowUpsStopWhereTheLanguageCannotBeTranslatedHere() {
        for outcome in [PageTranslator.Outcome.needsDownload, .unsupported, .sensitivePage] { #expect(!PageTranslator.followsOn(after: outcome)) }
        for outcome in [PageTranslator.Outcome.translated, .nothingToTranslate, .failed, .claudeFailed, .translatedPartly, .engineFailed] { #expect(PageTranslator.followsOn(after: outcome)) }
    }
}

// MARK: A page, with the script alone

extension SharedAgentState {
    @MainActor @Suite
    struct KeepTranslatingScriptTests {
        private func load(_ html: String) async throws -> (WKWebView, NSWindow) {
            let view = WKWebView()
            let window = OffscreenWindow(view)
            view.loadHTMLString(html, baseURL: nil)
            for _ in 0..<80 where view.isLoading || view.url == nil { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(200))
            return (view, window)
        }

        private func text(_ view: WKWebView, _ id: String) async throws -> String {
            try await view.callAsyncJavaScript("return document.getElementById(id).textContent", arguments: ["id": id], contentWorld: .page) as? String ?? ""
        }

        private func page(_ view: WKWebView, _ script: String) async throws {
            _ = try await view.callAsyncJavaScript(script, contentWorld: .page)
        }

        private func poll(_ view: WKWebView) async throws -> Double? {
            try await view.callAsyncJavaScript(PageTranslator.pollScript, contentWorld: .defaultClient) as? Double
        }

        private func follow(_ view: WKWebView, _ fake: FakeClaude, budget: ClaudeTranslation.Budget) async -> (outcome: PageTranslator.Outcome, budget: ClaudeTranslation.Budget) {
            let saved = ClaudeTranslation.makeRun
            ClaudeTranslation.makeRun = { _ in fake.run }
            defer { ClaudeTranslation.makeRun = saved }
            return await PageTranslator.translateWithClaude(view, model: "haiku", within: budget, collecting: PageTranslator.claudeFollowScript, while: { true }, permitted: { true })
        }

        private func firstPass(_ view: WKWebView, _ fake: FakeClaude) async -> (outcome: PageTranslator.Outcome, budget: ClaudeTranslation.Budget) {
            let saved = ClaudeTranslation.makeRun
            ClaudeTranslation.makeRun = { _ in fake.run }
            defer { ClaudeTranslation.makeRun = saved }
            return await PageTranslator.translateWithClaude(view, model: "haiku", within: ClaudeTranslation.Budget(), collecting: PageTranslator.claudeCollectScript,
                                                            while: { true }, permitted: { true })
        }

        @Test func aFollowUpCollectsOnlyWhatIsNewAndNumbersItAfterTheOthers() async throws {
            let (view, window) = try await load("<p id=a>The first sentence is here.</p>")
            defer { window.close() }
            let fake = FakeClaude.uppercasing()
            #expect(await firstPass(view, fake).outcome == .translated)
            try await page(view, "document.body.insertAdjacentHTML('beforeend', '<p id=b>A second sentence arrives.</p>')")
            let result = await follow(view, fake, budget: ClaudeTranslation.Budget())
            #expect(result.outcome == .translated)
            #expect(fake.textsAsked == ["The first sentence is here.", "A second sentence arrives."], "earlier text is not sent twice")
            #expect(fake.requests.map { FakeClaude.texts(in: $0).keys.sorted() } == [[0], [1]], "ids continue after the existing ones")
            let (a, b) = (try await text(view, "a"), try await text(view, "b"))
            #expect(a == "THE FIRST SENTENCE IS HERE." && b == "A SECOND SENTENCE ARRIVES.")
            await PageTranslator.showOriginal(view)
            let (restoredA, restoredB) = (try await text(view, "a"), try await text(view, "b"))
            #expect(restoredA == "The first sentence is here." && restoredB == "A second sentence arrives.", "Show Original restores them all")
        }

        @Test func nothingNewIsNothingToTranslateAndOurOwnWritesAreNotNew() async throws {
            let (view, window) = try await load("<p id=a>The first sentence is here.</p>")
            defer { window.close() }
            let fake = FakeClaude.uppercasing()
            _ = await firstPass(view, fake)
            let again = await follow(view, fake, budget: ClaudeTranslation.Budget())
            #expect(again.outcome == .nothingToTranslate && fake.calls == 1, "what we wrote is not collected again")
            #expect(again.budget == ClaudeTranslation.Budget(), "nothing was sent, nothing is used")
        }

        @Test func aNodeTheSiteChangedIsFreshAndOneWeWroteIsNot() async throws {
            let (view, window) = try await load("<p id=a>The first sentence is here.</p><p id=b>The other sentence is here.</p>")
            defer { window.close() }
            let fake = FakeClaude.uppercasing()
            _ = await firstPass(view, fake)
            try await page(view, "document.getElementById('a').firstChild.nodeValue = 'The site wrote something else.'")
            let result = await follow(view, fake, budget: ClaudeTranslation.Budget())
            #expect(result.outcome == .translated)
            #expect(Array(fake.textsAsked.suffix(1)) == ["The site wrote something else."] && fake.calls == 2)
            #expect(try await text(view, "a") == "THE SITE WROTE SOMETHING ELSE.")
            await PageTranslator.showOriginal(view)
            #expect(try await text(view, "a") == "The site wrote something else.", "the site's latest text is the original")
        }

        @Test func aTranslationDoesNotOverwriteWhatTheSiteWroteWhileItWasAwayAsking() async throws {
            let (view, window) = try await load("<p id=a>The first sentence is here.</p>")
            defer { window.close() }
            let fake = FakeClaude(delay: .milliseconds(600)) { texts in FakeClaude.json(texts.mapValues { $0.uppercased() }) }
            let saved = ClaudeTranslation.makeRun
            ClaudeTranslation.makeRun = { _ in fake.run }
            defer { ClaudeTranslation.makeRun = saved }
            let work = Task { await PageTranslator.translateWithClaude(view, model: "haiku", while: { true }) }
            try await Task.sleep(for: .milliseconds(250))
            try await page(view, "document.getElementById('a').firstChild.nodeValue = 'The site wrote something else.'")
            _ = await work.value
            #expect(try await text(view, "a") == "The site wrote something else.")
        }

        @Test func theObserverNotesTheSitesChangesAndNotOurOwnWriting() async throws {
            let (view, window) = try await load("<p id=a>The first sentence is here.</p>")
            defer { window.close() }
            let fake = FakeClaude.uppercasing()
            _ = await firstPass(view, fake)
            #expect(try await poll(view) == nil, "nothing is watched before the observer is there")
            _ = try await view.callAsyncJavaScript(PageTranslator.observeScript, contentWorld: .defaultClient)
            #expect(try await poll(view) ?? -1 >= 1000, "what came while it was translated is looked for at once")
            _ = await follow(view, fake, budget: ClaudeTranslation.Budget())
            #expect(try await poll(view) == -1, "looked at, so clean")
            // Our own writing, as the apply script does it, is not a change.
            _ = try await view.callAsyncJavaScript(PageTranslator.applyScript, arguments: ["texts": ["0": "OWN WRITING"], "remember": false], contentWorld: .defaultClient)
            try await Task.sleep(for: .milliseconds(150))
            #expect(try await text(view, "a") == "OWN WRITING")
            #expect(try await poll(view) == -1, "our own writes make no work")
            // The site's is: text added, and text changed.
            try await page(view, "document.body.insertAdjacentHTML('beforeend', '<p>Some new words arrive.</p>')")
            try await Task.sleep(for: .milliseconds(150))
            #expect(try await poll(view) ?? -1 >= 0)
            _ = await follow(view, fake, budget: ClaudeTranslation.Budget())
            #expect(try await poll(view) == -1)
            try await page(view, "document.getElementById('a').firstChild.nodeValue = 'The site changed this.'")
            try await Task.sleep(for: .milliseconds(150))
            #expect(try await poll(view) ?? -1 >= 0)
        }

        @Test func aFollowUpUsesTheSameFiltersAsTheFirstPass() async throws {
            let (view, window) = try await load("<p id=a>The first sentence is here.</p>")
            defer { window.close() }
            let fake = FakeClaude.uppercasing()
            _ = await firstPass(view, fake)
            try await page(view, """
                document.body.insertAdjacentHTML('beforeend', `
                <p>Visible new words.</p><p hidden>Hidden attribute words.</p><p style="display:none">Display none words.</p>
                <p style="visibility:hidden">Visibility hidden words.</p><div aria-hidden="true"><p>Aria hidden words.</p></div>
                <pre>code block words here</pre><span class=notranslate>Brand words here</span><div contenteditable>rich editor words</div>
                <input type=text value="typed field value words"><textarea>draft text words</textarea>`)
                """)
            let result = await follow(view, fake, budget: ClaudeTranslation.Budget())
            #expect(result.outcome == .translated)
            #expect(Array(fake.textsAsked.suffix(1)) == ["Visible new words."] && fake.calls == 2)
        }

        @Test func showOriginalAndANewCollectionLeaveWhatTheSiteWroteSinceAlone() async throws {
            for restoreBy in ["show", "collect"] {
                let (view, window) = try await load("<p id=a>The first sentence is here.</p><p id=b>The other sentence is here.</p>")
                defer { window.close() }
                let fake = FakeClaude.uppercasing()
                _ = await firstPass(view, fake)
                try await page(view, "document.getElementById('a').firstChild.nodeValue = 'The site wrote something else.'")
                if restoreBy == "show" {
                    await PageTranslator.showOriginal(view)
                } else {
                    _ = try await view.callAsyncJavaScript(PageTranslator.claudeCollectScript, contentWorld: .defaultClient)
                }
                #expect(try await text(view, "a") == "The site wrote something else.", "\(restoreBy): the site's text stays")
                #expect(try await text(view, "b") == "The other sentence is here.", "\(restoreBy): what we wrote is put back")
            }
        }

        @Test func aNodeReadAgainIsPutBackAsTheLatestReadHadIt() async throws {
            let (view, window) = try await load("<p id=a>The first sentence is here.</p>")
            defer { window.close() }
            let fake = FakeClaude.uppercasing()
            _ = await firstPass(view, fake)
            try await page(view, "document.getElementById('a').firstChild.nodeValue = 'The site wrote something else.'")
            _ = await follow(view, fake, budget: ClaudeTranslation.Budget())
            #expect(try await text(view, "a") == "THE SITE WROTE SOMETHING ELSE.")
            await PageTranslator.showOriginal(view)
            #expect(try await text(view, "a") == "The site wrote something else.")
        }

        @Test func wordsWrittenAgainAreFilledInFromWhatWasTranslatedAndNotSent() async throws {
            let (view, window) = try await load("<p id=a>The first sentence is here.</p>")
            defer { window.close() }
            let fake = FakeClaude.uppercasing()
            _ = await firstPass(view, fake)
            try await page(view, "document.getElementById('a').textContent = 'The first sentence is here.'")
            let again = await follow(view, fake, budget: ClaudeTranslation.Budget())
            #expect(again.outcome == .nothingToTranslate && fake.calls == 1)
            #expect(try await text(view, "a") == "THE FIRST SENTENCE IS HERE.")
            #expect(again.budget == ClaudeTranslation.Budget())
            await PageTranslator.showOriginal(view)
            #expect(try await text(view, "a") == "The first sentence is here.")
        }

        @Test func onlyTranslationsThatPassedTheChecksAreKeptForTheWordsWrittenAgain() async throws {
            let (view, window) = try await load("<p id=a>The first sentence is here.</p>")
            defer { window.close() }
            // The answer brings an address of its own: it is not used, and not kept.
            let fake = FakeClaude { texts in FakeClaude.json(texts.mapValues { _ in "Write to leak@evil.test now" }) }
            _ = await firstPass(view, fake)
            #expect(try await text(view, "a") == "The first sentence is here.")
            try await page(view, "document.getElementById('a').textContent = 'The first sentence is here.'")
            _ = await follow(view, fake, budget: ClaudeTranslation.Budget())
            #expect(fake.calls == 2, "asked again, as nothing was kept")
            #expect(try await text(view, "a") == "The first sentence is here.")
        }

        @Test func theFirstPassAndAFollowUpSendTheSameThingsFromTheSameMarkup() async throws {
            func markup(_ word: String) -> String {
                """
                <p>Visible \(word) words.</p><p hidden>Hidden \(word) attribute words.</p><p style="display:none">Display \(word) none words.</p>
                <p style="visibility:hidden">Visibility \(word) hidden words.</p><div aria-hidden="true"><p>Aria \(word) hidden words.</p></div>
                <pre>code \(word) block words</pre><span class=notranslate>Brand \(word) words here</span><div contenteditable>rich \(word) editor words</div>
                <div role=textbox>aria \(word) textbox words</div><datalist><option>Suggestion \(word) words</option></datalist>
                <input type=text value="typed \(word) field words"><textarea>draft \(word) text words</textarea><details><summary>Closed \(word) summary</summary><p>Closed \(word) details words.</p></details>
                """
            }
            let (view, window) = try await load("<p id=a>The first sentence is here.</p>" + markup("one"))
            defer { window.close() }
            let fake = FakeClaude.uppercasing()
            _ = await firstPass(view, fake)
            let first = fake.textsAsked
            try await page(view, "document.body.insertAdjacentHTML('beforeend', `\(markup("two"))`)")
            _ = await follow(view, fake, budget: ClaudeTranslation.Budget())
            let second = Array(fake.textsAsked.dropFirst(first.count))
            #expect(first == ["The first sentence is here.", "Visible one words.", "Closed one summary"], "\(first)")
            #expect(second == first.dropFirst().map { $0.replacingOccurrences(of: "one", with: "two") }, "\(second)")
        }

        @Test func aPasswordFieldThatAppearsLaterSendsNothingMore() async throws {
            let (view, window) = try await load("<p id=a>The first sentence is here.</p>")
            defer { window.close() }
            let fake = FakeClaude.uppercasing()
            _ = await firstPass(view, fake)
            try await page(view, "document.body.insertAdjacentHTML('beforeend', '<p id=b>A second sentence arrives.</p><input type=password>')")
            let result = await follow(view, fake, budget: ClaudeTranslation.Budget())
            #expect(result.outcome == .sensitivePage && fake.calls == 1, "decided in the run that would have collected")
            #expect(result.budget == ClaudeTranslation.Budget(), "nothing used")
            #expect(try await text(view, "b") == "A second sentence arrives.")
        }

        @Test func theNodesHeldAreCappedAndTheWatchEndsAtTheCap() async throws {
            let (view, window) = try await load("<p id=a>The first sentence is here.</p>")
            defer { window.close() }
            _ = await firstPass(view, FakeClaude.uppercasing())
            _ = try await view.callAsyncJavaScript(PageTranslator.observeScript, contentWorld: .defaultClient)
            // Fills what is held to the brim with nodes of its own, then adds text of the page's.
            _ = try await view.callAsyncJavaScript("const t = globalThis.changmunTranslation; while (t.nodes.length < 19999) { const n = document.createTextNode('x'); t.nodes.push(n); t.originals.push('x'); t.texts.push('x'); t.written.set(n, 'x'); }",
                                                   contentWorld: .defaultClient)
            try await page(view, "document.body.insertAdjacentHTML('beforeend', '<p>First new words.</p><p>Second new words.</p><p>Third new words.</p>')")
            let result = try await view.callAsyncJavaScript(PageTranslator.claudeFollowScript, contentWorld: .defaultClient) as? [String: Any]
            #expect(result?["texts"] as? [String] == ["First new words."], "room for one")
            #expect(try await view.callAsyncJavaScript("return globalThis.changmunTranslation.nodes.length", contentWorld: .defaultClient) as? Int == PageTranslator.maxTrackedNodes)
            #expect(try await poll(view) == nil, "nothing more is looked for")
        }
    }
}

// MARK: A tab

extension SharedAgentState {
    @MainActor @Suite
    struct KeepTranslatingTabTests {
        @MainActor private final class Saved {
            let engine = Preferences.shared.translationEngine
            let hosts = Preferences.shared.translatedHosts
            let detector = AIAvailability.detector
            let makeRun = ClaudeTranslation.makeRun
            let interval = PageTranslator.pollInterval
            let quiet = PageTranslator.quietMilliseconds
            let retry = Tab.languageRetryDelay
            let window = AutomaticClaude.shared.window
            let clock = AutomaticClaude.shared.now
            func restore() {
                AutomaticClaude.shared.window = window
                AutomaticClaude.shared.now = clock
                Preferences.shared.translationEngine = engine
                Preferences.shared.translatedHosts = hosts
                AIAvailability.detector = detector
                ClaudeTranslation.makeRun = makeRun
                PageTranslator.pollInterval = interval
                PageTranslator.quietMilliseconds = quiet
                Tab.languageRetryDelay = retry
            }
        }

        /// A tab of a window, with its page in a window off every screen, Claude chosen and standing in for by `fake`, the sites in `kept`
        /// kept, and everything the status line said.
        @MainActor private final class Site {
            let saved = Saved()
            let browser: Browser
            let tab: Tab
            let view: WKWebView
            let window: NSWindow
            var messages: [String] = []
            private var watch: AnyCancellable?

            init(kept: [String], fake: FakeClaude, isPrivate: Bool = false, freshWindow: Bool = true) {
                if freshWindow { AutomaticClaude.shared.window = ClaudeWindow() }
                Preferences.shared.translationEngine = .claude
                Preferences.shared.translatedHosts = kept
                AIAvailability.detector = { .ready }
                ClaudeTranslation.makeRun = { _ in fake.run }
                PageTranslator.pollInterval = .milliseconds(80)
                PageTranslator.quietMilliseconds = 80
                Tab.languageRetryDelay = .milliseconds(300)
                browser = Browser(isPrivate: isPrivate)
                browser.focused()
                tab = browser.openTab(url: nil, activate: true)
                view = tab.wake()
                window = OffscreenWindow(view)
                watch = browser.overlay.$statusMessage.sink { [weak self] in if let message = $0 { self?.messages.append(message) } }
            }

            func close() {
                window.close()
                browser.windowClosed()
                saved.restore()
            }

            /// Loads a page of the site and waits until it has been shown.
            func load(_ html: String, host: String = "comic.test", path: String = "1") async {
                let before = tab.page
                view.loadHTMLString(html, baseURL: URL(string: "https://\(host)/\(path)"))
                _ = await waitUntil(30) { self.tab.page > before && !self.view.isLoading }
            }

            func translated() async -> Bool {
                await waitUntil(30) { self.tab.translation == .translated && !self.tab.translatesWithClaude && self.tab.translating == nil }
            }

            func text(_ id: String) async -> String {
                (try? await view.callAsyncJavaScript("return document.getElementById(id)?.textContent ?? ''", arguments: ["id": id], contentWorld: .page) as? String) ?? ""
            }

            func becomes(_ id: String, _ expected: String) async -> Bool {
                let end = Date().addingTimeInterval(20)
                while Date() < end {
                    if await text(id) == expected { return true }
                    try? await Task.sleep(for: .milliseconds(40))
                }
                return await text(id) == expected
            }

            func append(_ html: String) async {
                _ = try? await view.callAsyncJavaScript("document.body.insertAdjacentHTML('beforeend', html)", arguments: ["html": html], contentWorld: .page)
            }

            /// Waits for the time the follow-ups need to be seen to have run, a good many times over.
            func settle(_ milliseconds: Int = 800) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        }

        /// A page in a language that is not the user's, whichever that is, and another sentence of it for each name.
        private var foreignText: String {
            PageTranslator.target.languageCode == "en" ? "자전거는 19세기에 발명되어 전 세계로 널리 퍼졌고, 오늘날 많은 사람이 탄다." : "The bicycle was invented in the nineteenth century and became popular all over the world."
        }

        private func foreign(_ name: String) -> String {
            PageTranslator.target.languageCode == "en" ? "새로운 이야기가 올라왔어요 \(name)" : "A new story was posted \(name)"
        }

        /// What is left in the page of a piece of text: "[x] " before it.
        private func tagged(_ text: String) -> String { "[x] " + text }

        private func tagging(delay: Duration = .zero) -> FakeClaude {
            FakeClaude(delay: delay) { texts in FakeClaude.json(texts.mapValues { "[x] " + $0 }) }
        }

        /// Whether the task is over within ten seconds.
        private func ended(_ task: Task<Void, Never>?) async -> Bool {
            guard let task else { return true }
            let over = Flag()
            over.on = false
            Task { await task.value; over.on = true }
            return await waitUntil(10) { over.on }
        }

        // The next page

        @Test func aKeptSiteTranslatesTheNextPageByItself() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>", path: "1")
            #expect(await site.translated())
            #expect(await site.text("a") == tagged(foreignText) && fake.calls == 1, "the first page, nobody pressed the button")
            await site.load("<p id=a>\(foreignText) Chapter two.</p>", path: "2")
            #expect(await site.becomes("a", tagged(foreignText + " Chapter two.")))
            #expect(await site.translated() && fake.calls == 2)
        }

        @Test func aSiteThatIsNotKeptDoesNotTranslateTheNextPage() async {
            let fake = tagging()
            let site = Site(kept: ["other.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>", path: "1")
            #expect(await waitUntil(30) { site.tab.foreignLanguage != nil }, "the page was found foreign, and offered")
            await site.settle()
            #expect(site.tab.translation == .original && site.tab.translating == nil && fake.calls == 0)
            // A translation of the user's own on such a site is a one-off: new text is not translated, and nothing is watched.
            site.tab.toggleTranslation()
            #expect(await site.translated() && fake.calls == 1 && site.tab.following == nil)
            await site.append("<p id=b>\(foreign("later"))</p>")
            await site.settle()
            #expect(await site.text("b") == foreign("later") && fake.calls == 1)
            await site.load("<p id=a>\(foreignText) Chapter two.</p>", path: "2")
            #expect(await waitUntil(30) { site.tab.foreignLanguage != nil })
            await site.settle()
            #expect(site.tab.translation == .original && fake.calls == 1)
        }

        @Test func anotherHostOfAKeptSiteIsNotTranslatedByItself() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>", host: "mail.comic.test")
            #expect(await waitUntil(30) { site.tab.foreignLanguage != nil })
            await site.settle()
            #expect(site.tab.translation == .original && fake.calls == 0)
            await site.load("<p id=a>\(foreignText)</p>", host: "www.comic.test")
            #expect(await site.becomes("a", tagged(foreignText)), "with www it is the same host")
        }

        @Test func aPrivateWindowNeverTranslatesByItselfAndNeverSavesASite() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake, isPrivate: true)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await waitUntil(30) { site.tab.foreignLanguage != nil })
            await site.settle()
            #expect(site.tab.translation == .original && site.tab.translating == nil && fake.calls == 0 && !site.tab.keepsTranslating)
            site.tab.setKeepsTranslating(true, host: "private.test")
            #expect(Preferences.shared.translatedHosts == ["comic.test"], "nothing is written from a private window")
            site.tab.setKeepsTranslating(false, host: "comic.test")
            #expect(Preferences.shared.translatedHosts == ["comic.test"])
        }

        @Test func aPageInTheUsersOwnLanguageIsNeverTranslatedOrSent() async throws {
            let own: String
            switch PageTranslator.target.languageCode {
            case "en": own = "The bicycle was invented in the nineteenth century and became popular all over the world."
            case "ko": own = "자전거는 19세기에 발명되어 전 세계로 널리 퍼졌고, 오늘날 많은 사람이 탄다."
            default: return
            }
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(own)</p>")
            await site.settle(1200)
            #expect(site.tab.foreignLanguage == nil && site.tab.translation == .original && fake.calls == 0)
            // Text that comes late, in the user's language, is looked at once more and still not sent.
            await site.load("<p id=a>.</p><script>setTimeout(() => { document.getElementById('a').textContent = '\(own)'; }, 100)</script>", path: "2")
            await site.settle(1200)
            #expect(site.tab.translation == .original && fake.calls == 0 && site.tab.following == nil)
        }

        @Test func aKeptSiteLooksOnceMoreWhenTheTextCameLate() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            Tab.languageRetryDelay = .milliseconds(800)
            await site.load("<p id=a>.</p><script>setTimeout(() => { document.getElementById('a').textContent = '\(foreignText)'; }, 150)</script>")
            #expect(await site.becomes("a", tagged(foreignText)) && fake.calls == 1)
        }

        @Test func anAutomaticRunThatFindsNothingSaysNothing() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            // The text is all in a block of code, which is not translated: the page is foreign, and nothing in it is to be translated.
            await site.load("<pre id=a>\(foreignText)</pre>")
            #expect(await waitUntil(30) { site.tab.foreignLanguage != nil })
            await site.settle()
            #expect(site.tab.translation == .original && fake.calls == 0)
            #expect(site.messages.isEmpty, "\(site.messages)")
            // What the button says to the same page.
            site.tab.toggleTranslation()
            #expect(await waitUntil(30) { site.tab.translation == .original && site.tab.translating == nil })
            #expect(site.messages == [String(localized: "No text in another language to translate")])
        }

        // Show Original

        @Test func showOriginalStopsTheFollowUpsOfThatPageOnlyAndTheNextPageTranslatesAgain() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            site.tab.toggleTranslation()
            #expect(site.tab.translation == .original && site.tab.following == nil)
            #expect(await site.becomes("a", foreignText))
            await site.append("<p id=b>\(foreign("after"))</p>")
            await site.settle()
            #expect(fake.calls == 1 && site.tab.translation == .original)
            #expect(await site.text("b") == foreign("after"), "no follow-up work on that page")
            await site.load("<p id=a>\(foreignText) Chapter two.</p>", path: "2")
            #expect(await site.becomes("a", tagged(foreignText + " Chapter two.")))
            #expect(await site.translated() && fake.calls == 2)
        }

        // New text

        @Test func appendedTextIsTranslatedAndEarlierTextIsNotSentTwice() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            await site.append("<p id=b>\(foreign("one"))</p>")
            #expect(await site.becomes("b", tagged(foreign("one"))))
            await site.append("<p id=c>\(foreign("two"))</p>")
            #expect(await site.becomes("c", tagged(foreign("two"))))
            await site.settle()
            #expect(fake.textsAsked == [foreignText, foreign("one"), foreign("two")], "each piece of text was sent once")
            #expect(site.tab.translation == .translated)
            // Show Original puts all of it back.
            site.tab.toggleTranslation()
            #expect(await site.becomes("c", foreign("two")))
            #expect(await site.text("b") == foreign("one"))
            #expect(await site.text("a") == foreignText)
        }

        @Test func ourOwnWritesProduceNoFurtherWork() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            await site.settle(1500)
            #expect(fake.calls == 1, "a page left alone is not asked about again")
            await site.append("<p id=b>\(foreign("one"))</p>")
            #expect(await site.becomes("b", tagged(foreign("one"))))
            await site.settle(1500)
            #expect(fake.calls == 2 && fake.textsAsked.count == 2, "the writing of a follow-up is no new text")
            let quiet = try? await site.view.callAsyncJavaScript(PageTranslator.pollScript, contentWorld: .defaultClient) as? Double
            #expect(quiet == -1, "nothing is waiting to be looked at")
        }

        @Test func aSiteChangingATextItHasShownIsPickedUp() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p><p id=b>\(foreign("fixed"))</p>")
            #expect(await site.translated())
            _ = try? await site.view.callAsyncJavaScript("document.getElementById('a').firstChild.nodeValue = text", arguments: ["text": foreign("changed")], contentWorld: .page)
            #expect(await site.becomes("a", tagged(foreign("changed"))))
            await site.settle()
            #expect(fake.textsAsked == [foreignText, foreign("fixed"), foreign("changed")], "the text that stood is not sent again")
            #expect(fake.calls == 2)
        }

        @Test func aFollowUpWithClaudeSaysSoAndSaysNothingWhenItTranslatedAll() async {
            let fake = tagging(delay: .milliseconds(400))
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            site.messages = []
            await site.append("<p id=b>\(foreign("one"))</p>")
            #expect(await waitUntil(30) { site.tab.translatesWithClaude }, "the button's text about Anthropic shows")
            #expect(site.tab.translation == .translated)
            #expect(await site.becomes("b", tagged(foreign("one"))))
            #expect(await waitUntil(10) { !site.tab.translatesWithClaude })
            #expect(site.messages.isEmpty, "\(site.messages)")
        }

        @Test func followUpsThatFindNothingSayNothing() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            site.messages = []
            await site.append("<p id=b>12</p><div style='display:none'>hidden words here</div><pre>code words</pre>")
            await site.settle()
            #expect(fake.calls == 1 && site.messages.isEmpty && site.tab.translation == .translated)
        }

        @Test func followUpsThatFailSayItOnceInARow() async {
            let broken = FakeClaude { _ in throw ClaudeTranslation.Failure.exited(1) }
            let working = tagging()
            var current = working
            let site = Site(kept: ["comic.test"], fake: working)
            defer { site.close() }
            ClaudeTranslation.makeRun = { _ in current.run }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            current = broken
            site.messages = []
            await site.append("<p>\(foreign("one"))</p>")
            #expect(await waitUntil(30) { !site.messages.isEmpty })
            await site.settle()
            await site.append("<p>\(foreign("two"))</p>")
            await site.settle(1200)
            let said = PageTranslator.statusMessage(for: .claudeFailed) ?? ""
            #expect(site.messages.filter { $0 == said }.count == 1 && broken.calls >= 2, "\(site.messages)")
        }

        // The page's allowance

        @Test func theFirstPassAndTheFollowUpsShareWhatAPageMaySend() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            let word = PageTranslator.target.languageCode == "en" ? "가나다라마바사아자차 " : "bicycle story "
            func paragraph(_ tag: String) -> (Int) -> String { { number in "<p>\(String(("\(tag)\(number) " + String(repeating: word, count: 200)).prefix(1000)))</p>" } }
            await site.load("<p id=a>\(foreignText)</p>" + (0..<139).map(paragraph("first")).joined())
            #expect(await site.translated())
            #expect(!site.tab.translationBudget.exhausted && site.tab.translationBudget.characters > 130_000, "\(site.tab.translationBudget)")
            site.messages = []
            await site.append((0..<20).map(paragraph("later")).joined())
            let partly = PageTranslator.statusMessage(for: .translatedPartly) ?? ""
            #expect(await waitUntil(30) { site.messages.contains(partly) })
            #expect(site.tab.translationBudget.exhausted)
            #expect(await ended(site.tab.following), "the loop stops")
            let sent = fake.textsAsked.reduce(0) { $0 + $1.count }
            #expect(sent <= ClaudeTranslation.maxPageCharacters && sent > 145_000, "\(sent) characters in all")
            // A page that goes on adding text is not sent any more, and it is not said again.
            let calls = fake.calls
            await site.append("<p>\(foreign("more"))</p>")
            await site.settle()
            #expect(fake.calls == calls && site.messages.filter { $0 == partly }.count == 1)
            #expect(site.tab.translation == .translated)
        }

        @Test func theBatchesOfAPageAreSharedToo() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            site.tab.translationBudget.batches = ClaudeTranslation.maxBatches - 1
            await site.append("<p id=b>\(foreign("last"))</p>")
            #expect(await site.becomes("b", tagged(foreign("last"))))
            await site.append("<p id=c>\(foreign("over"))</p>")
            let partly = PageTranslator.statusMessage(for: .translatedPartly) ?? ""
            #expect(await waitUntil(30) { site.messages.contains(partly) })
            #expect(await site.text("c") == foreign("over") && fake.calls == 2)
            #expect(await ended(site.tab.following))
        }

        @Test func aNewPageStartsWithAllOfItsAllowance() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            site.tab.translationBudget = ClaudeTranslation.Budget(characters: 150_000, batches: 60, exhausted: true)
            await site.load("<p id=a>\(foreignText) Chapter two.</p>", path: "2")
            #expect(await site.becomes("a", tagged(foreignText + " Chapter two.")))
            #expect(await site.translated() && !site.tab.translationBudget.exhausted && site.tab.following != nil)
        }

        // What stops it

        @Test func aPasswordFieldThatAppearsLaterStopsSendingToClaude() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            await site.append("<p id=b>\(foreign("secret"))</p><input type=password>")
            await site.settle(1500)
            #expect(fake.calls == 1, "not a word of it went to Claude")
            #expect(await site.text("b") != tagged(foreign("secret")))
            let said = site.messages
            #expect(said.contains(String(localized: "This page has a password or payment field, so it is translated on this Mac and not sent to Claude."))
                    || said.contains(String(localized: "This page has a password or payment field, so it isn’t sent to Claude, and this Mac can’t translate it: that needs macOS 26 or later.")), "\(said)")
            // And not later either, with the field gone.
            _ = try? await site.view.callAsyncJavaScript("document.querySelector('input').remove()", contentWorld: .page)
            await site.append("<p id=c>\(foreign("later"))</p>")
            await site.settle(1500)
            #expect(fake.calls == 1)
        }

        @Test func switchingTheSettingOffStopsTheWorkAndLeavesThePage() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            #expect(site.tab.following != nil)
            site.tab.setKeepsTranslating(false, host: "comic.test")
            #expect(Preferences.shared.translatedHosts.isEmpty && site.tab.following == nil)
            #expect(site.tab.translation == .translated, "the page is left as it is")
            #expect(await site.text("a") == tagged(foreignText))
            await site.append("<p id=b>\(foreign("one"))</p>")
            await site.settle()
            #expect(fake.calls == 1 && site.tab.translation == .translated)
            #expect(await site.text("b") == foreign("one"))
        }

        @Test func removingTheSiteInSettingsStopsItToo() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            let loop = site.tab.following
            Preferences.shared.translatedHosts = []
            await site.append("<p id=b>\(foreign("one"))</p>")
            #expect(await ended(loop), "the loop ends by itself")
            #expect(fake.calls == 1 && site.tab.translation == .translated)
        }

        @Test func switchingTheSettingOffWhileAFollowUpIsUnderWayEndsItAndItsAnswerIsNotUsed() async {
            let fake = tagging(delay: .milliseconds(1200))
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            await site.append("<p id=b>\(foreign("one"))</p>")
            #expect(await waitUntil(30) { fake.calls == 2 })
            site.tab.setKeepsTranslating(false, host: "comic.test")
            await site.settle(2000)
            #expect(await site.text("b") == foreign("one"), "the answer was not used")
            #expect(!site.tab.translatesWithClaude)
        }

        @Test func turningItOnForAForeignPageStartsTranslatingIt() async {
            let fake = tagging()
            let site = Site(kept: [], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await waitUntil(30) { site.tab.foreignLanguage != nil })
            await site.settle(500)
            #expect(site.tab.translation == .original && fake.calls == 0)
            site.tab.setKeepsTranslating(true, host: "comic.test")
            #expect(Preferences.shared.translatedHosts == ["comic.test"])
            #expect(await site.translated() && fake.calls == 1 && site.tab.following != nil)
            #expect(await site.text("a") == tagged(foreignText))
            // Turned on for a page already translated once: it is followed from now.
            site.tab.setKeepsTranslating(false, host: "comic.test")
            await site.append("<p id=b>\(foreign("one"))</p>")
            await site.settle()
            #expect(fake.calls == 1)
            site.tab.setKeepsTranslating(true, host: "comic.test")
            #expect(await site.becomes("b", tagged(foreign("one"))))
        }

        @Test func theRouteIsAskedAgainForEveryFollowUp() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            Preferences.shared.translationEngine = .onDevice
            #expect(site.tab.translationRoute() == .onDevice)
            site.messages = []
            await site.append("<p id=b>\(foreign("one"))</p>")
            // The follow-up went on this Mac: it either translated the text there, or said why it could not (no model, an older macOS).
            let answered = await waitUntil(30) { !site.messages.isEmpty }
            let text = await site.text("b")
            #expect(answered || text != foreign("one"), "the follow-up ran: it said something or the text changed")
            #expect(fake.calls == 1 && text != tagged(foreign("one")), "this Mac was chosen: Claude is not asked")
        }

        // The site's window

        /// A page of many paragraphs of about a thousand characters each, the first of them in a language that is not the user's.
        private func bigPage(_ paragraphs: Int = 100, name: String = "") -> String {
            let word = PageTranslator.target.languageCode == "en" ? "가나다라마바사아자차 " : "bicycle story "
            let filler = { (number: Int) in "<p>" + String(("\(name)\(number) " + String(repeating: word, count: 200)).prefix(998)).trimmingCharacters(in: .whitespaces) + "</p>" }
            return "<p id=a>\(foreignText)</p>" + (1..<paragraphs).map(filler).joined()
        }

        private func sent(_ fake: FakeClaude) -> Int { fake.textsAsked.reduce(0) { $0 + $1.count } }

        /// Waits until the stand-in has not been asked for a good while.
        private func quiet(_ fake: FakeClaude) async {
            var last = -1
            var still = 0
            while still < 12 {
                try? await Task.sleep(for: .milliseconds(100))
                if fake.calls == last { still += 1 } else { last = fake.calls; still = 0 }
            }
        }

        private var paused: String { PageTranslator.pausedMessage }

        @Test func aPageThatLoadsItselfAgainAndAgainStaysWithinTheWindowAndStops() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            // What a page that reloads itself does: each time a page of its own, with the page's whole allowance, and nobody pressed anything.
            for number in 1...7 {
                await site.load(bigPage(name: "\(number)-"), path: "\(number)")
                await quiet(fake)
            }
            #expect(sent(fake) <= ClaudeWindow.maxCharacters, "\(sent(fake)) characters in all")
            #expect(sent(fake) > 250_000, "it did send, up to the window: \(sent(fake))")
            #expect(fake.calls <= ClaudeWindow.maxBatches)
            #expect(site.messages.filter { $0 == paused }.count == 1, "said once: \(site.messages)")
            let before = sent(fake)
            await site.load(bigPage(name: "more-"), path: "8")
            await quiet(fake)
            #expect(sent(fake) <= ClaudeWindow.maxCharacters && sent(fake) - before < 1000, "what was left of the window, no more")
            #expect(site.messages.filter { $0 == paused }.count == 1)
        }

        @Test func twoTabsOnOneSiteShareTheWindow() async {
            let fake = tagging()
            let first = Site(kept: ["comic.test"], fake: fake)
            let second = Site(kept: ["comic.test"], fake: fake, freshWindow: false)
            defer { first.close() }
            defer { second.close() }
            await first.load(bigPage(name: "a1-"), path: "1")
            await quiet(fake)
            await second.load(bigPage(name: "b1-"), path: "2")
            await quiet(fake)
            await first.load(bigPage(name: "a2-"), path: "3")
            await quiet(fake)
            await second.load(bigPage(name: "b2-"), path: "4")
            await quiet(fake)
            await first.load(bigPage(name: "a3-"), path: "5")
            await quiet(fake)
            #expect(sent(fake) <= ClaudeWindow.maxCharacters, "\(sent(fake)) characters in all, from two tabs")
            #expect(sent(fake) > 250_000)
            #expect((first.messages + second.messages).filter { $0 == paused }.count == 1)
        }

        @Test func aPressOfTranslateIsNotHeldToTheWindowAndStillCountsInIt() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            let shared = AutomaticClaude.shared
            shared.window.record(characters: 0, batches: ClaudeWindow.maxBatches, for: "comic.test", at: shared.now())
            await site.load(bigPage(name: "x-"))
            await quiet(fake)
            #expect(fake.calls == 0 && site.tab.translation == .original, "nothing nobody asked for goes while the window is used up")
            #expect(site.messages.contains(paused))
            site.tab.toggleTranslation()
            #expect(await site.translated())
            #expect(sent(fake) > 90_000, "the whole page, as the user asked: \(sent(fake))")
            #expect(shared.window.remaining(for: "comic.test", at: shared.now()).characters <= ClaudeWindow.maxCharacters - 90_000, "and it counted")
        }

        @Test func aWindowThatHasPassedLetsAutomaticWorkGoOn() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            let shared = AutomaticClaude.shared
            let start = Date()
            shared.now = { start }
            shared.window.record(characters: ClaudeWindow.maxCharacters, batches: ClaudeWindow.maxBatches, for: "comic.test", at: start)
            await site.load("<p id=a>\(foreignText)</p>", path: "1")
            await site.settle()
            #expect(fake.calls == 0)
            shared.now = { start.addingTimeInterval(ClaudeWindow.span + 1) }
            await site.load("<p id=a>\(foreignText) Two.</p>", path: "2")
            #expect(await site.becomes("a", tagged(foreignText + " Two.")))
        }

        // The page's allowance

        @Test func theButtonStartsThePageOverAndAnAutomaticRunDoesNot() async {
            let fake = tagging()
            let site = Site(kept: [], fake: fake)
            defer { site.close() }
            await site.load(bigPage(120, name: "p-"))
            #expect(await waitUntil(30) { site.tab.foreignLanguage != nil })
            site.tab.toggleTranslation()
            #expect(await site.translated())
            let once = sent(fake)
            #expect(once > 100_000)
            site.tab.toggleTranslation()
            #expect(site.tab.translation == .original)
            #expect(await site.becomes("a", foreignText))
            site.tab.toggleTranslation()
            #expect(await site.translated())
            #expect(sent(fake) - once > 100_000, "as in 0.13.0, the whole page again: \(sent(fake) - once)")
        }

        @Test func whatWasSentBeforeShowOriginalCountsAgainstThePage() async {
            let fake = tagging(delay: .milliseconds(300))
            let site = Site(kept: [], fake: fake)
            defer { site.close() }
            await site.load(bigPage(60, name: "c-"))
            #expect(await waitUntil(30) { site.tab.foreignLanguage != nil })
            site.tab.toggleTranslation()
            #expect(await waitUntil(30) { fake.calls >= 2 })
            site.tab.toggleTranslation()
            #expect(site.tab.translation == .original)
            #expect(await waitUntil(30) { site.tab.translationBudget.characters > 0 }, "\(site.tab.translationBudget)")
            #expect(site.tab.translationBudget.batches > 0)
        }

        @Test func aFollowUpThatWasStoppedDoesNotTouchWhatALaterTranslationSays() async {
            let fake = tagging(delay: .milliseconds(1500))
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            await site.append("<p id=b>\(foreign("one"))</p>")
            #expect(await waitUntil(30) { site.tab.translatesWithClaude })
            let old = site.tab.following
            site.tab.toggleTranslation()
            site.tab.toggleTranslation()
            #expect(site.tab.translation == .translating && site.tab.translatesWithClaude, "the later translation is under way")
            let budget = site.tab.translationBudget
            #expect(await ended(old))
            #expect(site.tab.translatesWithClaude, "the button still says the text is going to Anthropic")
            #expect(site.tab.translationBudget.characters >= budget.characters)
            #expect(await site.translated())
        }

        // A password field seen once

        @Test func aPasswordFieldSeenOnTheFirstPassKeepsLaterTextFromClaudeWhenItIsGone() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p><input type=password>")
            #expect(await waitUntil(30) { site.tab.sensitiveSeen })
            #expect(await waitUntil(30) { site.tab.translation != .translating })
            #expect(fake.calls == 0)
            // The field goes. Whether this Mac translated the page or could not, the page is followed from here.
            _ = try? await site.view.callAsyncJavaScript("document.querySelector('input').remove()", contentWorld: .page)
            _ = try? await site.view.callAsyncJavaScript(PageTranslator.collectScript, contentWorld: .defaultClient)
            site.tab.translation = .translated
            site.tab.followTranslation(from: site.tab.foreignLanguage ?? Locale.Language(identifier: "und"))
            await site.append("<p id=b>\(foreign("later"))</p>")
            await site.settle(1500)
            #expect(fake.calls == 0, "not a word of it went to Claude")
            site.tab.following?.cancel()
        }

        @Test func aPasswordFieldSeenOnAFollowUpKeepsLaterTextFromClaudeToo() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            await site.append("<p id=b>\(foreign("secret"))</p><input type=password>")
            #expect(await waitUntil(30) { site.tab.sensitiveSeen })
            _ = try? await site.view.callAsyncJavaScript("document.querySelector('input').remove()", contentWorld: .page)
            await site.append("<p id=c>\(foreign("later"))</p>")
            await site.settle(1500)
            #expect(fake.calls == 1)
        }

        // A tab nobody looks at, refusals, a site that rewrites itself

        @Test func aTabThatIsNotShownIsNotLookedAtUntilItIs() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            let other = site.browser.openTab(url: nil, activate: true)
            #expect(!site.browser.isShown(site.tab))
            await site.append("<p id=b>\(foreign("one"))</p>")
            await site.settle(1200)
            #expect(fake.calls == 1 && site.tab.translatesWithClaude == false, "nothing is sent from a tab in the background")
            #expect(await site.text("b") == foreign("one"))
            site.browser.activate(site.tab.id)
            #expect(await site.becomes("b", tagged(foreign("one"))))
            _ = other
        }

        @Test func aRefusalOfAnAutomaticTranslationIsSaidOncePerTab() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            AIAvailability.detector = { .none }
            let refusal = PageTranslator.statusMessage(for: .claudeUnavailable)
            for number in 1...3 {
                await site.load("<p id=a>\(foreignText) \(number)</p>", path: "\(number)")
                await site.settle(600)
            }
            #expect(site.messages.filter { $0 == refusal }.count == 1, "\(site.messages)")
            #expect(fake.calls == 0)
            site.tab.toggleTranslation()
            #expect(site.messages.filter { $0 == refusal }.count == 2, "the button says it each time")
        }

        @Test func aSiteThatWritesTheSameWordsAgainIsNotSentThemAgain() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p><div id=live>\(foreign("live"))</div>")
            #expect(await site.translated())
            for _ in 0..<3 {
                // A new text node each time, as `textContent` makes them.
                _ = try? await site.view.callAsyncJavaScript("document.getElementById('live').textContent = text", arguments: ["text": foreign("live")], contentWorld: .page)
                #expect(await site.becomes("live", tagged(foreign("live"))))
                await site.settle(400)
            }
            #expect(fake.textsAsked == [foreignText, foreign("live")], "sent once: \(fake.textsAsked)")
            // New words are sent.
            _ = try? await site.view.callAsyncJavaScript("document.getElementById('live').textContent = text", arguments: ["text": foreign("other")], contentWorld: .page)
            #expect(await site.becomes("live", tagged(foreign("other"))))
            // And Show Original puts the site's words back.
            site.tab.toggleTranslation()
            #expect(await site.becomes("live", foreign("other")))
        }

        @Test func aTabThatGoesToSleepEndsTheWatch() async {
            let fake = tagging()
            let site = Site(kept: ["comic.test"], fake: fake)
            defer { site.close() }
            await site.load("<p id=a>\(foreignText)</p>")
            #expect(await site.translated())
            let loop = site.tab.following
            site.tab.sleep()
            #expect(site.tab.following == nil && site.tab.translationBudget == ClaudeTranslation.Budget())
            #expect(await ended(loop))
            #expect(fake.calls == 1)
        }

        @Test func theWatchDoesNotKeepTheTabAlive() async {
            let fake = tagging()
            weak var weakTab: Tab?
            var loop: Task<Void, Never>?
            do {
                let site = Site(kept: ["comic.test"], fake: fake)
                await site.load("<p id=a>\(foreignText)</p>")
                #expect(await site.translated())
                weakTab = site.tab
                loop = site.tab.following
                site.close()
            }
            #expect(await ended(loop), "the loop ends when the tab is gone")
            #expect(await waitUntil(10) { weakTab == nil })
        }
    }
}
