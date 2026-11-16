import Foundation
import Testing
@testable import Changmun

/// Search engines the user adds: what makes an address one, which words go to which engine, and a damaged value falling back.
struct CustomSearchEngineTests {
    private func engine(_ keyword: String, _ template: String, name: String = "Engine") -> CustomSearchEngine {
        CustomSearchEngine(name: name, keyword: keyword, template: template)
    }

    @Test func anAddressNeedsHttpsOneStopForTheWordsAndASite() {
        #expect(SearchTemplate.problem("https://en.wikipedia.org/w/index.php?search=%s") == nil)
        #expect(SearchTemplate.problem("HTTPS://example.com/%s") == nil)
        #expect(SearchTemplate.problem("https://example.com/search/%s/results") == nil)
        #expect(SearchTemplate.problem("http://example.com/?q=%s") == .notHTTPS)
        #expect(SearchTemplate.problem("example.com/?q=%s") == .notHTTPS)
        #expect(SearchTemplate.problem("javascript:alert(%s)") == .notHTTPS)
        #expect(SearchTemplate.problem("https://example.com/?q=") == .noPlaceholder)
        #expect(SearchTemplate.problem("https://example.com/?q=%S") == .noPlaceholder)
        #expect(SearchTemplate.problem("https://example.com/?q=%s&r=%s") == .manyPlaceholders)
        #expect(SearchTemplate.problem("https:///?q=%s") == .noHost)
        #expect(SearchTemplate.problem("https://?q=%s") == .noHost)
        #expect(SearchTemplate.problem("https://%s.example.com/") == .placeholderInHost)
        #expect(SearchTemplate.problem("https://%s") == .placeholderInHost)
        #expect(SearchTemplate.problem("https://example.com%s") == .placeholderInHost)
        #expect(SearchTemplate.problem("") == .notHTTPS)
    }

    @Test func everyReasonIsSaidInWords() {
        let problems: [CustomSearchEngine.Problem] = [.noName, .noKeyword, .badKeyword, .keywordTaken, .alreadyAdded,
                                                      .template(.notHTTPS), .template(.noPlaceholder), .template(.manyPlaceholders),
                                                      .template(.noHost), .template(.placeholderInHost)]
        for problem in problems { #expect(problem.reason.count > 10, "\(problem)") }
        #expect(CustomSearchEngine.Problem.template(.noPlaceholder).reason.contains("%s"))
    }

    @Test func aKeywordIsOneLowerCaseWord() {
        for good in ["w", "wiki", "map2", "my-engine", "my_engine", "위키", "x" + String(repeating: "y", count: 15)] { #expect(CustomSearchEngine.isKeyword(good), "\(good)") }
        for bad in ["", "Wiki", "two words", "a:b", "a/b", "a.b", "a%s", "x" + String(repeating: "y", count: 16), "wiki\n"] { #expect(!CustomSearchEngine.isKeyword(bad), "\(bad)") }
    }

    @Test func anEngineNeedsANameAKeywordNobodyHasAndAnAddressNobodyHas() {
        let wiki = engine("wiki", "https://en.wikipedia.org/w/index.php?search=%s")
        func problem(name: String = "Maps", keyword: String = "maps", template: String = "https://maps.example/?q=%s", ignoring: UUID? = nil) -> CustomSearchEngine.Problem? {
            CustomSearchEngine.problem(name: name, keyword: keyword, template: template, among: [wiki], ignoring: ignoring)
        }
        #expect(problem() == nil)
        #expect(problem(name: "  ") == .noName)
        #expect(problem(keyword: "") == .noKeyword)
        #expect(problem(keyword: "Maps") == .badKeyword)
        #expect(problem(keyword: "wiki") == .keywordTaken)
        #expect(problem(template: "http://maps.example/?q=%s") == .template(.notHTTPS))
        #expect(problem(template: wiki.template) == .alreadyAdded)
        #expect(problem(template: SearchEngine.google.template) == .alreadyAdded, "a built-in engine's address is one already")
        #expect(problem(name: "Wiki", keyword: "wiki", template: "https://x.example/?q=%s", ignoring: wiki.id) == nil, "editing an engine does not collide with itself")
    }

    @Test func aKeywordSendsTheWordsAfterItToThatEngine() {
        let wiki = engine("wiki", "https://en.wikipedia.org/w/index.php?search=%s")
        let google = SearchTemplate.google
        func pick(_ query: String) -> (template: String, terms: String) { SearchRouting.pick(query, default: google, engines: [wiki]) }
        #expect(pick("wiki swift language") == (wiki.template, "swift language"))
        #expect(pick("WIKI  swift ") == (wiki.template, "swift"))
        #expect(pick("wiki\tswift").template == wiki.template)
        #expect(pick("wiki").template == google, "a keyword alone is a search for the word")
        #expect(pick("wiki   ").template == google)
        #expect(pick("wikipedia swift").template == google)
        #expect(pick("swift wiki").template == google)
        #expect(pick("swift concurrency") == (google, "swift concurrency"))
        #expect(SearchRouting.pick("wiki swift", default: google, engines: []).template == google)
    }

    @Test func aBuiltInEnginesKeywordSearchesWithItAndAnAddedEnginesKeywordComesFirst() {
        let google = SearchTemplate.google
        #expect(SearchRouting.pick("n 돼지국밥", default: google, engines: []) == (SearchEngine.naver.template, "돼지국밥"))
        #expect(SearchRouting.pick("D privacy", default: google, engines: []).template == SearchEngine.duckDuckGo.template)
        #expect(SearchRouting.pick("n", default: google, engines: []).template == google, "a keyword alone is a search for the letter")
        let mine = engine("n", "https://news.example/?q=%s")
        #expect(SearchRouting.pick("n 돼지국밥", default: google, engines: [mine]).template == mine.template)
        #expect(!SearchRouting.allowsSuggestions(for: "n 돼지국밥", defaultTemplate: google, engines: []),
                "words for another engine aren't sent to the default engine for suggestions")
    }

    @Test func aDamagedStoredValueFallsBackToTheDefaultEngine() {
        #expect(SearchTemplate.valid(nil) == SearchTemplate.google)
        #expect(SearchTemplate.valid("") == SearchTemplate.google)
        #expect(SearchTemplate.valid("http://insecure.example/?q=%s") == SearchTemplate.google)
        #expect(SearchTemplate.valid("https://example.com/?q=") == SearchTemplate.google)
        #expect(SearchTemplate.valid("https://%s.evil.example/") == SearchTemplate.google)
        for builtIn in SearchEngine.allCases { #expect(SearchTemplate.valid(builtIn.template) == builtIn.template, "\(builtIn)") }
        #expect(SearchTemplate.valid("https://maps.example/?q=%s") == "https://maps.example/?q=%s")
    }

    @Test func storedEnginesAreCheckedWhenRead() throws {
        let suite = "changmun-engines-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CustomSearchEngine.stored(in: defaults).isEmpty)

        let good = engine("wiki", "https://en.wikipedia.org/w/index.php?search=%s", name: "Wikipedia")
        CustomSearchEngine.store([good], in: defaults)
        #expect(CustomSearchEngine.stored(in: defaults) == [good])

        defaults.set(Data("not json".utf8), forKey: CustomSearchEngine.defaultsKey)
        #expect(CustomSearchEngine.stored(in: defaults).isEmpty)
        defaults.set("a string", forKey: CustomSearchEngine.defaultsKey)
        #expect(CustomSearchEngine.stored(in: defaults).isEmpty)

        // One entry is not an object, one has an address that is not https, one repeats a keyword, one has a keyword with a space: only the good one stays.
        let damaged = """
        [{"id":"\(good.id)","name":"Wikipedia","keyword":"wiki","template":"\(good.template)"},
         "junk",
         {"id":"\(UUID())","name":"Insecure","keyword":"ins","template":"http://insecure.example/?q=%s"},
         {"id":"\(UUID())","name":"Again","keyword":"wiki","template":"https://again.example/?q=%s"},
         {"id":"\(UUID())","name":"Spaced","keyword":"two words","template":"https://spaced.example/?q=%s"},
         {"id":"not-a-uuid","name":"No id","keyword":"noid","template":"https://noid.example/?q=%s"}]
        """
        defaults.set(Data(damaged.utf8), forKey: CustomSearchEngine.defaultsKey)
        #expect(CustomSearchEngine.stored(in: defaults) == [good])
    }

    @Test func suggestionsStayForTheBuiltInEnginesAndNeverGoToACustomOne() {
        let wiki = engine("wiki", "https://en.wikipedia.org/w/index.php?search=%s")
        let google = SearchTemplate.google
        // A built-in engine is the default: as before, also with engines added.
        for builtIn in SearchEngine.allCases {
            #expect(SearchRouting.allowsSuggestions(for: "swift", defaultTemplate: builtIn.template, engines: []))
            #expect(SearchRouting.allowsSuggestions(for: "swift", defaultTemplate: builtIn.template, engines: [wiki]))
        }
        // A custom engine is the default: none.
        #expect(!SearchRouting.allowsSuggestions(for: "swift", defaultTemplate: wiki.template, engines: [wiki]))
        // Words that go to a custom engine by its keyword are not sent to the built-in one.
        #expect(!SearchRouting.allowsSuggestions(for: "wiki swift", defaultTemplate: google, engines: [wiki]))
        #expect(SearchRouting.allowsSuggestions(for: "wiki", defaultTemplate: google, engines: [wiki]))
    }

    @Test func theBuiltInSearchesAreUnchanged() {
        #expect(AddressInput.searchURL("a&b=c")!.absoluteString.hasSuffix("q=a%26b%3Dc"))
        #expect(AddressInput.resolve("example.com")?.absoluteString == "https://example.com")
    }
}

struct SearchEngineMenuTests {
    @Test func theMenuShowsTheAddedEngineSearchesGoToAndOtherwiseTheBuiltInOne() {
        let wiki = CustomSearchEngine(name: "Wikipedia", keyword: "w", template: "https://en.wikipedia.org/w/index.php?search=%s")
        #expect(SearchEngineChoice.current(template: wiki.template, builtIn: .google, custom: [wiki]) == .custom(wiki.id))
        #expect(SearchEngineChoice.current(template: SearchEngine.naver.template, builtIn: .naver, custom: [wiki]) == .builtIn(.naver))
        #expect(SearchEngineChoice.current(template: wiki.template, builtIn: .bing, custom: []) == .builtIn(.bing),
                "an engine that was removed is not shown as the default")
        #expect(SearchEngineChoice.current(template: nil, builtIn: .duckDuckGo, custom: [wiki]) == .builtIn(.duckDuckGo))
    }
}

/// The command bar's row of other engines under a search, and ⌘ with a number for one of them.
struct QuickSearchTests {
    @Test func theRowOffersEveryEngineInTheListButTheOneTheSearchGoesTo() {
        let wiki = CustomSearchEngine(name: "Wikipedia", keyword: "wiki", template: "https://en.wikipedia.org/w/index.php?search=%s")
        let listed = SearchEngine.listed(removed: [SearchEngine.bing.rawValue])
        let names = QuickSearch.chips(besides: SearchEngine.google.template, custom: [wiki], builtIns: listed).map(\.name)
        #expect(names == [SearchEngine.naver.name, SearchEngine.duckDuckGo.name, "Wikipedia"], "Bing was taken out of the list")
        #expect(QuickSearch.chips(besides: wiki.template, custom: [wiki]).map(\.id) == SearchEngine.allCases.map(\.rawValue))
        let news = CustomSearchEngine(name: "News", keyword: "n", template: "https://news.example/?q=%s")
        #expect(QuickSearch.all(custom: [news]).first { $0.id == SearchEngine.naver.rawValue }?.keyword == "",
                "a keyword an added engine has taken is not shown for the built-in engine")
    }

    @Test func aBuiltInEngineTakenOutOfTheListHasNoKeyword() {
        let listed = SearchEngine.listed(removed: [SearchEngine.naver.rawValue])
        #expect(SearchRouting.pick("n 돼지국밥", default: SearchTemplate.google, engines: [], builtIns: listed) == (SearchTemplate.google, "n 돼지국밥"))
        #expect(SearchRouting.pick("d 돼지국밥", default: SearchTemplate.google, engines: [], builtIns: listed).template == SearchEngine.duckDuckGo.template)
    }

    @Test func theAddMenuOffersPresetsNotInTheListEachWithAKeywordNoOtherUses() {
        let all = SearchEnginePresets.available(besides: [], builtIns: SearchEngine.allCases)
        #expect(all.count == SearchEnginePresets.all.count)
        for preset in all { #expect(CustomSearchEngine.problem(name: preset.name, keyword: preset.keyword, template: preset.template, among: []) == nil, "\(preset.name)") }
        guard let youTube = all.first(where: { $0.template.contains("youtube.com") }) else { Issue.record("no YouTube preset"); return }
        let mine = CustomSearchEngine(name: "Mine", keyword: "wiki", template: "https://mine.example/?q=%s")
        let offered = SearchEnginePresets.available(besides: [youTube, mine], builtIns: SearchEngine.allCases)
        #expect(!offered.contains { $0.template == youTube.template }, "one in the list is not offered again")
        #expect(offered.first { $0.template.contains("wikipedia.org") }?.keyword == "wiki2", "a keyword in use gets a number")
    }

    @MainActor @Test func commandAndANumberSearchesWithThatEngineOnlyWhileTheBarShowsTheRow() throws {
        let b = Browser()
        defer { b.windowClosed() }
        let engines = QuickSearch.chips(besides: SearchEngine.google.template, custom: [])
        let chips = CommandBarChips(engines: engines, terms: "돼지국밥", mode: .newTab)
        b.commandBarChips = chips
        #expect(!b.searchWithChip(number: 1), "with the bar closed, ⌘1 is the first tab's")
        b.commandBar = .newTab
        b.commandBarChips = chips
        let before = b.tabs.count
        #expect(!b.searchWithChip(number: 9), "no engine at that number: the tab's")
        #expect(b.searchWithChip(number: 1))
        #expect(b.tabs.count == before + 1)
        let url = try #require(b.tabs.last?.url)
        #expect(url.host() == "search.naver.com" && url.query()?.contains("%EB%8F%BC%EC%A7%80%EA%B5%AD%EB%B0%A5") == true)
        #expect(b.commandBar == nil && b.commandBarChips == nil, "the bar closes and forgets its row")
    }
}


/// Taking a built-in engine out of the list and putting it back, in the app's own settings (restored after).
extension SharedAgentState {
    @MainActor @Suite(.serialized)
    struct SearchEngineListTests {
        @Test func theDefaultEngineStaysAndAnotherComesAndGoes() {
            let prefs = Preferences.shared
            let saved = (prefs.searchEngine, prefs.removedSearchEngines, UserDefaults.standard.string(forKey: "searchURL"), prefs.customSearchEngines)
            defer {
                prefs.customSearchEngines = saved.3
                prefs.searchEngine = saved.0
                prefs.removedSearchEngines = saved.1
                UserDefaults.standard.set(saved.2, forKey: "searchURL")
            }
            prefs.customSearchEngines = []
            prefs.removedSearchEngines = []
            prefs.defaultEngineChoice = .builtIn(.google)
            prefs.setListed(.google, false)
            #expect(SearchEngine.listed().contains(.google), "the engine searches go to can't be taken out")
            prefs.setListed(.bing, false)
            #expect(!SearchEngine.listed().contains(.bing) && AddressInput.searchTemplate == SearchEngine.google.template)
            prefs.setListed(.bing, true)
            #expect(SearchEngine.listed().contains(.bing))
            // An added engine is the default and the built-in one it falls back to is taken out: removing the added one brings that back.
            let mine = CustomSearchEngine(name: "Mine", keyword: "mine", template: "https://mine.example/?q=%s")
            prefs.save(mine)
            prefs.useAsDefault(mine)
            prefs.setListed(.google, false)
            #expect(!SearchEngine.listed().contains(.google) && prefs.searchEngine != .google && AddressInput.searchTemplate == mine.template)
            prefs.remove(mine)
            #expect(SearchEngine.listed().contains(prefs.searchEngine) && AddressInput.searchTemplate == prefs.searchEngine.template)
        }
    }
}
