import Foundation
import SwiftUI
import Testing
@testable import Changmun

/// What VoiceOver is told: the words made for each part of the browser, the announcements, and the strings in every language.
/// (The tests run without the app's language tables, so the words are the English ones.)
@MainActor
struct AccessibilityTests {
    // MARK: Words

    @Test func aSavedPageSaysWhetherItIsStillToBeRead() {
        #expect(Accessibility.readingValue(read: false, site: "example.com", added: "Yesterday").hasPrefix(String(localized: "Unread")))
        #expect(Accessibility.readingValue(read: true, site: "example.com", added: "Yesterday").hasPrefix(String(localized: "Read")))
        #expect(Accessibility.readingValue(read: true, site: "", added: "").hasSuffix(String(localized: "Read")))
    }

    @Test func partsOfSpeechAreJoinedWithoutGaps() {
        #expect(Accessibility.join(["a", nil, "", "b"]) == "a, b")
        #expect(Accessibility.join([nil, ""]) == "")
        #expect(Accessibility.join([]) == "")
    }

    @Test func aButtonsNameIsItsHelpWithoutTheShortcut() {
        #expect(Accessibility.label(fromHelp: "Back (⌘[)") == "Back")
        #expect(Accessibility.label(fromHelp: "Close Tab (⌘W)") == "Close Tab")
        #expect(Accessibility.label(fromHelp: "Close (esc)") == "Close")
        #expect(Accessibility.label(fromHelp: "New Space…") == "New Space")
        #expect(Accessibility.label(fromHelp: "Downloads") == "Downloads")
        #expect(Accessibility.label(fromHelp: "Mute (⌃⌘M)") == "Mute")
        // Only the shortcut at the end goes, not words in parentheses before the end.
        #expect(Accessibility.label(fromHelp: "Turn off (for now) ads (⌘D)") == "Turn off (for now) ads")
    }

    @Test func aTabSaysWhatItIsDoing() {
        #expect(Accessibility.tabValue(.init()) == "")
        #expect(Accessibility.tabValue(.init(loading: true)) == "Loading")
        #expect(Accessibility.tabValue(.init(playingAudio: true)) == "Playing audio")
        // A muted tab that plays is said to be muted, not to be playing.
        #expect(Accessibility.tabValue(.init(playingAudio: true, muted: true)) == "Muted")
        #expect(Accessibility.tabValue(.init(asleep: true, pinned: true)) == "Sleeping, Pinned")
        #expect(Accessibility.tabValue(.init(loading: true, split: true, group: "Work")) == "Loading, In group Work, Split View")
    }

    @Test func aBookmarkIsNamedByItsTitleOrItsSite() {
        #expect(Accessibility.bookmarkLabel(title: "Swift", url: "https://swift.org/") == "Swift")
        #expect(Accessibility.bookmarkLabel(title: "  ", url: "https://www.swift.org/blog") == "swift.org")
        #expect(Accessibility.bookmarkLabel(title: "", url: "not an address") == "not an address")
        #expect(Accessibility.bookmarkValue(.closed) == "Not open")
        #expect(Accessibility.bookmarkValue(.open) == "Open")
        #expect(Accessibility.bookmarkValue(.shown) == "Open")
    }

    @Test func foldersAndGroupsSayTheirStateAndSize() {
        #expect(Accessibility.folderValue(open: true, bookmarks: 3) == "Expanded, 3 bookmarks")
        #expect(Accessibility.folderValue(open: false, bookmarks: 1) == "Collapsed, 1 bookmark")
        #expect(Accessibility.folderValue(open: false, bookmarks: nil) == "Collapsed")
        #expect(Accessibility.groupValue(open: true, tabs: 2) == "Expanded, 2 tabs")
        #expect(Accessibility.groupValue(open: false, tabs: 1) == "Collapsed, 1 tab")
        #expect(Accessibility.toggleAction(open: true) == "Collapse")
        #expect(Accessibility.toggleAction(open: false) == "Expand")
    }

    @Test func theConnectionIsSaidInWords() {
        #expect(Accessibility.connectionValue(scheme: "https", unverified: false, choseToGoOn: false) == "Secure connection")
        #expect(Accessibility.connectionValue(scheme: "http", unverified: false, choseToGoOn: false) == "Connection is not secure")
        #expect(Accessibility.connectionValue(scheme: "https", unverified: true, choseToGoOn: false) == "Certificate not verified")
        #expect(Accessibility.connectionValue(scheme: "https", unverified: true, choseToGoOn: true) == "Certificate not verified, you chose to go on")
        #expect(Accessibility.connectionValue(scheme: "about", unverified: false, choseToGoOn: false) == nil)
        #expect(Accessibility.connectionValue(scheme: nil, unverified: false, choseToGoOn: false) == nil)
    }

    @Test func progressIsSaidAsAPercentWithinZeroAndAHundred() {
        #expect(Accessibility.loadingValue(progress: 0.4) == "40 percent")
        #expect(Accessibility.loadingValue(progress: 0.005) == "1 percent")
        #expect(Accessibility.loadingValue(progress: -1) == "0 percent")
        #expect(Accessibility.loadingValue(progress: 7) == "100 percent")
        #expect(Accessibility.percentValue(0.5) == "50 percent")
    }

    @Test func downloadsAreCounted() {
        #expect(Accessibility.downloadsValue(active: 0) == nil)
        #expect(Accessibility.downloadsValue(active: 1) == "1 download in progress")
        #expect(Accessibility.downloadsValue(active: 3) == "3 downloads in progress")
    }

    @Test func aSuggestionSaysWhatItDoesAndToWhat() {
        #expect(Accessibility.suggestionLabel(.open("swift.org")) == "Open swift.org")
        #expect(Accessibility.suggestionLabel(.search("swift")) == "Search for swift")
        #expect(Accessibility.suggestionLabel(.ask("what is swift")) == "Ask AI: what is swift")
        #expect(Accessibility.suggestionLabel(.tab(title: "Docs", host: "swift.org", space: nil)) == "Switch to tab Docs")
        #expect(Accessibility.suggestionLabel(.tab(title: "Docs", host: "swift.org", space: "Work")) == "Switch to tab Docs in Work")
        #expect(Accessibility.suggestionLabel(.page(title: "Swift", host: "swift.org")) == "Open Swift")
        #expect(Accessibility.suggestionLabel(.page(title: "", host: "swift.org")) == "Open swift.org")
        #expect(Accessibility.suggestionValue(.tab(title: "Docs", host: "swift.org", space: nil)) == "swift.org")
        #expect(Accessibility.suggestionValue(.page(title: "Swift", host: "")) == nil)
        #expect(Accessibility.suggestionValue(.search("swift")) == nil)
    }

    @Test func theNumberOfSuggestionsAndMatchesIsSaid() {
        #expect(Accessibility.resultsCount(0) == "No suggestions")
        #expect(Accessibility.resultsCount(1) == "1 suggestion")
        #expect(Accessibility.resultsCount(7) == "7 suggestions")
        #expect(Accessibility.findMatches(0) == "None")
        #expect(Accessibility.findMatches(1) == "1 match")
        #expect(Accessibility.findMatches(12) == "12 matches")
    }

    @Test func theConversationNamesWhoSpoke() {
        #expect(Accessibility.youSaid("hello") == "You said: hello")
        #expect(Accessibility.aiSaid == "AI said")
        // The time worked is the value, which changes; the name stays the same.
        #expect(Accessibility.workingValue(elapsed: "12s", step: "Reading the page") == "12s, Reading the page")
        #expect(Accessibility.workingValue(elapsed: nil, step: nil) == "")
    }

    @Test func aDividerMovesByAStepAndStaysWithinItsRange() {
        #expect(Accessibility.adjusted(250, .increment, step: 20, in: 200...420) == 270)
        #expect(Accessibility.adjusted(250, .decrement, step: 20, in: 200...420) == 230)
        #expect(Accessibility.adjusted(410, .increment, step: 20, in: 200...420) == 420)
        #expect(Accessibility.adjusted(205, .decrement, step: 20, in: 200...420) == 200)
        #expect(Accessibility.widthValue(252.4) == "252 points")
    }

    // MARK: Announcements

    @Test func theSameWordsAreNotSaidTwiceInARow() {
        var gate = AnnouncementGate()
        let start = Date()
        let first = gate.allows("Saved", important: false, typing: false, now: start)
        let again = gate.allows("Saved", important: false, typing: false, now: start.addingTimeInterval(1))
        let other = gate.allows("Something else", important: false, typing: false, now: start.addingTimeInterval(1.1))
        // After a while the same words may be said again.
        let later = gate.allows("Something else", important: false, typing: false, now: start.addingTimeInterval(10))
        #expect(first && !again && other && later)
    }

    @Test func nothingIsSaidOverSomeoneTypingUnlessItMatters() {
        var gate = AnnouncementGate()
        let now = Date()
        let quiet = gate.allows("Saved", important: false, typing: true, now: now)
        let urgent = gate.allows("Approval needed", important: true, typing: true, now: now)
        // What was left out was not said, so it is not remembered as said.
        let afterwards = gate.allows("Saved", important: false, typing: false, now: now)
        #expect(!quiet && urgent && afterwards)
    }

    @Test func emptyWordsAreNotAnnounced() {
        var gate = AnnouncementGate()
        let empty = gate.allows("", important: true, typing: false)
        let blank = gate.allows("   ", important: true, typing: false)
        #expect(!empty && !blank)
    }

    @Test func theAnnouncerHandsWhatItAllowsToItsDestination() {
        var said: [(String, Bool)] = []
        let before = Announcer.deliver
        Announcer.deliver = { said.append(($0, $1)) }
        defer { Announcer.deliver = before }
        let text = "Test announcement \(UUID().uuidString)"
        Announcer.announce(text)
        Announcer.announce(text)
        #expect(said.count == 1 && said[0].0 == text && said[0].1 == false)
        #expect(Announcer.recent.last == text)
        let urgent = "Urgent \(UUID().uuidString)"
        Announcer.announce(urgent, important: true)
        #expect(said.last?.0 == urgent && said.last?.1 == true)
    }

    // MARK: Looks

    /// WCAG contrast of a gray ink of `alpha` (black on light, white on dark) over a flat gray.
    private func contrast(ink: Double, alpha: Double, over ground: Double) -> Double {
        func luminance(_ value: Double) -> Double { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let blended = ink * alpha + ground * (1 - alpha)
        let (a, b) = (luminance(blended) + 0.05, luminance(ground) + 0.05)
        return max(a, b) / min(a, b)
    }

    @Test func moreContrastMakesQuietTextAndLinesStronger() {
        for opacity in [0.24, 0.5, 0.55, 0.6, 0.9] {
            #expect(Theme.boosted(opacity, highContrast: false) == opacity)
            let boosted = Theme.boosted(opacity, highContrast: true)
            #expect(boosted > opacity && boosted <= 1)
        }
        #expect(Theme.boosted(1, highContrast: true) == 1)
        // The quiet text reaches 4.5:1 on the light and the dark ground with the boost, and the lines 3:1.
        for opacity in [0.5, 0.55, 0.6] {
            let boosted = Theme.boosted(opacity, highContrast: true)
            #expect(contrast(ink: 0, alpha: boosted, over: 0.925) >= 4.5)
            #expect(contrast(ink: 1, alpha: boosted, over: 0.13) >= 4.5)
        }
        let line = Theme.boosted(0.24, highContrast: true)
        #expect(contrast(ink: 0, alpha: line, over: 0.925) >= 3 && contrast(ink: 1, alpha: line, over: 0.13) >= 3)
    }

    // MARK: Languages

    private static let languages = ["ko", "ja", "zh-Hans", "es", "de", "fr"]
    private static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    private func table(_ language: String) throws -> [String: String] {
        try #require(NSDictionary(contentsOf: Self.resources.appendingPathComponent("\(language).lproj/Localizable.strings")) as? [String: String])
    }

    /// Everything the accessibility words say that is not already in the tables from before.
    private static let keys = [
        "Loading", "Muted", "Playing audio", "Sleeping", "Pinned", "In group %@", "Not open", "%lld bookmark", "%lld bookmarks", "%lld tab", "%lld tabs",
        "Expanded", "Collapsed", "Shown", "Hidden", "Turned on", "Turned off", "Secure connection", "Connection is not secure",
        "Certificate not verified, you chose to go on", "%lld percent", "%lld download in progress", "%lld downloads in progress", "Open %@", "Search for %@",
        "Ask AI: %@", "Switch to tab %@", "Switch to tab %@ in %@", "No suggestions", "1 suggestion", "%lld suggestions", "You said: %@", "AI said",
        "%lld points", "Address", "Edit Address", "Edit the address", "Return opens it", "Link Preview", "Certificate warning", "Approval needed",
        "Approval needed: %@", "Shortcut: Return", "Shortcut: Command Return", "Shortcut: Option Command Return", "Split View Divider", "AI Panel Width",
        "Translate", "Translating", "Ad blocking for this site", "Add to Favorites", "Separate logins and cookies", "New download finished",
        "Downloaded %@", "Couldn’t download %@", "Page translated", "Showing the original page", "%@. Undo is available in the sidebar.", "Remove %@",
        "This connection isn’t private. %@", "Opens in a new tab", "Reopens the tab", "%@ is muted", "%@ is not muted", "%@ is playing audio",
        "Blue", "Coral", "Green", "Purple", "Amber", "Teal", "Pink", "Gray", "Type an address or words to search for, then press Return",
        "Type to see suggestions. Use the up and down arrow keys to choose one, and Return to open it",
        "Previewing %@. Press Command Return to open it as a tab, or Escape to close it.",
    ]

    @Test func everyLanguageHasEveryWord() throws {
        for language in Self.languages {
            let words = try table(language)
            for key in Self.keys {
                let text = try #require(words[key], "\(language) lacks \"\(key)\"")
                #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty, "\(language): \"\(key)\" is empty")
            }
        }
    }

    @Test func theAsianLanguagesDoNotKeepTheEnglish() throws {
        for language in ["ko", "ja", "zh-Hans"] {
            let words = try table(language)
            for key in Self.keys where key != "Address" {
                #expect(words[key] != key, "\(language) left \"\(key)\" in English")
            }
        }
    }

    @Test func koreanSpeaksPolitelyInTheEverydayStyle() throws {
        let words = try table("ko")
        // Full sentences end in 요; none is in the formal ending.
        let sentences = [
            "Edit the address", "Return opens it", "Type an address or words to search for, then press Return", "Page translated", "Showing the original page",
            "Type to see suggestions. Use the up and down arrow keys to choose one, and Return to open it", "New download finished", "Not open",
            "%@. Undo is available in the sidebar.", "Approval needed", "Separate logins and cookies", "Connection is not secure",
            "Previewing %@. Press Command Return to open it as a tab, or Escape to close it.", "Couldn’t download %@", "Downloaded %@",
        ]
        for key in sentences {
            let text = try #require(words[key])
            #expect(text.hasSuffix("요") || text.hasSuffix("요."), "\"\(key)\" should end in 요: \(text)")
        }
        for key in Self.keys {
            let text = try #require(words[key])
            #expect(!text.contains("습니다") && !text.contains("합니다") && !text.contains("십시오"), "\"\(key)\" is formal: \(text)")
        }
    }

    @Test func placeholdersSurviveTranslation() throws {
        func specifiers(_ text: String) -> [String] {
            let pattern = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:lld|ld|d|@|lf|f)")
            return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]).replacingOccurrences(of: #"%\d+\$"#, with: "%", options: .regularExpression) }.sorted()
        }
        for language in Self.languages {
            let words = try table(language)
            for key in Self.keys {
                #expect(specifiers(key) == specifiers(try #require(words[key])), "\(language): \"\(key)\"")
            }
        }
    }
}
