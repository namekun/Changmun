import AppKit
import Foundation
import Testing
@testable import Changmun

/// The address bar's top hit and the name it fills in: typing the start of a site's name puts the site first, where Return opens it.
struct TopHitTests {
    private func library() -> Library {
        Library(path: FileManager.default.temporaryDirectory.appendingPathComponent("tophit-\(UUID().uuidString).sqlite").path)
    }

    private func visit(_ library: Library, _ url: String, times: Int = 1, daysAgo: Double = 0) throws {
        _ = try library.importHistory([(url: url, title: url, visits: times, lastVisit: Date().addingTimeInterval(-daysAgo * 86400))])
    }

    // MARK: The sites

    @Test func theStartOfAVisitedSitesNameIsAHitAndReturnOpensItsFrontPage() throws {
        let library = library()
        try visit(library, "https://github.com/", times: 3)
        try visit(library, "https://github.com/namekun/Changmun", times: 40)
        let sites = library.sites()
        let hit = try #require(sites.hit(for: "git"))
        #expect(hit.url == "https://github.com/", "the front page, which was visited, over the busier page")
        #expect(hit.host == "github.com")
        #expect(sites.hit(for: "GIT")?.url == "https://github.com/", "any case")
        #expect(SiteIndex.completion(of: "git", to: hit) == "hub.com")
        #expect(SiteIndex.completion(of: "Git", to: hit) == "hub.com")
    }

    @Test func wordsAWordInsideANameAPathOrTheWholeNameAreNoHit() throws {
        let library = library()
        try visit(library, "https://github.com/", times: 5)
        try visit(library, "https://www.nike.com/shoes", times: 5)
        let sites = library.sites()
        #expect(sites.hit(for: "git hub") == nil, "two words are a search")
        #expect(sites.hit(for: "git ") == nil, "a space after the word too")
        #expect(sites.hit(for: "nike shoes") == nil)
        #expect(sites.hit(for: "hub") == nil, "only the start of the name")
        #expect(sites.hit(for: "shoes") == nil, "never the path")
        #expect(sites.hit(for: "github.com/name") == nil)
        #expect(sites.hit(for: "https://git") == nil)
        #expect(sites.hit(for: "github.com") == nil, "the whole name opens as typed")
        #expect(sites.hit(for: "github.co")?.host == "github.com", "but an address that is the start of a longer name is completed")
        #expect(sites.hit(for: "") == nil)
    }

    @Test func wwwIsNotPartOfTheName() throws {
        let library = library()
        try visit(library, "https://www.naver.com/", times: 2)
        let sites = library.sites()
        let hit = try #require(sites.hit(for: "naver"))
        #expect(hit.url == "https://www.naver.com/" && hit.host == "naver.com")
        #expect(SiteIndex.completion(of: "naver", to: hit) == ".com")
        #expect(sites.hit(for: "www.nav")?.host == "naver.com")
        #expect(SiteIndex.completion(of: "www.nav", to: hit) == "er.com")
        #expect(sites.hit(for: "www.") == nil)
    }

    @Test func theMostVisitedSiteWins() throws {
        let library = library()
        try visit(library, "https://gitlab.com/", times: 2, daysAgo: 200)
        try visit(library, "https://github.com/", times: 30)
        try visit(library, "https://github.com/a", times: 30)
        #expect(library.sites().hit(for: "git")?.host == "github.com")
        #expect(library.sites().hit(for: "gitl")?.host == "gitlab.com")
    }

    @Test func withoutItsFrontPageASiteOpensItsShortestBookmarkElseItsBusiestPage() throws {
        let library = library()
        try visit(library, "https://github.com/namekun/Changmun/issues", times: 9)
        try visit(library, "https://github.com/namekun", times: 2)
        #expect(library.sites().hit(for: "git")?.url == "https://github.com/namekun/Changmun/issues")
        library.addBookmark(url: "https://github.com/namekun/Changmun", title: "Changmun", folder: "Work")
        library.addBookmark(url: "https://github.com/namekun/Changmun/pulls", title: "Pulls", folder: "Work")
        #expect(library.sites().hit(for: "git")?.url == "https://github.com/namekun/Changmun")
    }

    @Test func aPrivateWindowGoesByTheBookmarksAlone() throws {
        let library = library()
        try visit(library, "https://github.com/", times: 30)
        try visit(library, "https://naver.com/", times: 30)
        library.addBookmark(url: "https://news.ycombinator.com/", title: "HN", folder: "")
        let sites = library.sites()
        #expect(sites.hit(for: "git", history: false) == nil, "the history stays out")
        #expect(sites.hit(for: "n", history: false)?.host == "news.ycombinator.com")
        #expect(sites.hit(for: "n")?.host == "naver.com", "an ordinary window goes by the visits first")
    }

    @Test func anotherProfilesFavoritesAndPagesThatAreNotWebPagesAreNoHits() {
        let library = library()
        let other = Library.favoritesPrefix + "work"
        library.addBookmark(url: "https://intranet.example/", title: "Intranet", folder: other)
        library.addBookmark(url: "javascript:alert(1)", title: "Bookmarklet", folder: "")
        library.addBookmark(url: "file:///Users/me/notes.html", title: "Notes", folder: "")
        let sites = library.sites()
        #expect(sites.hit(for: "intra", history: false, hiding: [other]) == nil)
        #expect(sites.hit(for: "intra", history: false)?.host == "intranet.example")
        #expect(sites.hit(for: "java") == nil && sites.hit(for: "us") == nil && sites.hit(for: "aler") == nil)
    }

    @Test func aClearedHistoryLeavesNoSite() throws {
        let library = library()
        try visit(library, "https://github.com/")
        library.clearHistory(since: .distantPast)
        #expect(library.sites().hit(for: "git") == nil)
    }

    // MARK: The list

    private func index(_ sites: SiteIndex.Site...) -> SiteIndex { SiteIndex(visited: sites) }
    private let github = SiteIndex.Site(host: "github.com", url: "https://github.com/", title: "GitHub", score: 9, root: true)

    @Test @MainActor func theTopHitComesFirstThenTheSearchAndTheAI() {
        let browser = Browser()
        let typed = TypedText("git")
        let top = CommandBar.topHit(typed, sites: index(github), browser: browser)
        let pages = [Library.Entry(url: "https://github.com/", title: "GitHub"), Library.Entry(url: "https://git-scm.com/", title: "Git")]
        let list = CommandBar.suggestions(shown: typed.words, pages: pages, searches: [], browser: browser, mode: .newTab, top: top)
        #expect(Array(list.prefix(3)) == [.top(url: "https://github.com/", title: "GitHub"), .search("git"), .ask("git")])
        #expect(CommandBar.chosen(list, at: 0) == .top(url: "https://github.com/", title: "GitHub"), "Return opens the site")
        #expect(!list.contains(.page(url: "https://github.com/", title: "GitHub")), "and it isn't listed twice")
        #expect(list.contains(.page(url: "https://git-scm.com/", title: "Git")))
    }

    @Test @MainActor func twoWordsSearchFirst() {
        let browser = Browser()
        let typed = TypedText("git hub")
        let top = CommandBar.topHit(typed, sites: index(github), browser: browser)
        #expect(top == nil)
        #expect(CommandBar.suggestions(shown: typed.words, pages: [], searches: [], browser: browser, mode: .newTab, top: top).first == .search("git hub"))
    }

    @Test @MainActor func aPrivateWindowPutsNoVisitedSiteFirst() {
        let browser = Browser(isPrivate: true)
        let typed = TypedText("git")
        let top = CommandBar.topHit(typed, sites: index(github), browser: browser)
        #expect(top == nil)
        #expect(CommandBar.suggestions(shown: typed.words, pages: [], searches: [], browser: browser, mode: .newTab, top: top) == [.search("git")])
    }

    @Test @MainActor func afterADeletionTheFirstRowIsWhatTheFieldShows() {
        let browser = Browser()
        var typed = TypedText("git")
        typed.complete(to: "github.com")
        _ = typed.changed(from: "github.com", to: "git")
        #expect(typed.deleting, "Delete takes the filled-in name away")
        #expect(CommandBar.topHit(typed, sites: index(github), browser: browser) == nil)
        _ = typed.changed(from: "git", to: "gith")
        #expect(CommandBar.topHit(typed, sites: index(github), browser: browser) == github, "typing on brings it back")
    }

    /// The highlight was on the top hit, and the next letter (a space) makes it no hit: it doesn't move to the same page further down.
    @Test func theHighlightOnTheTopHitDoesNotFollowItsPageDownTheList() {
        let old: [CommandBar.Suggestion] = [.top(url: "https://github.com/", title: "GitHub"), .search("git"), .page(url: "https://git-scm.com/", title: "Git")]
        let new: [CommandBar.Suggestion] = [.search("git "), .ask("git "), .page(url: "https://github.com/", title: "GitHub")]
        #expect(CommandBar.keptSelection(0, old: old, new: new) == 0)
        // The sites were still loading when the words were typed: the top hit comes in above the highlighted search, which Return still runs.
        #expect(CommandBar.keptSelection(0, old: [.search("git"), .ask("git")], new: old) == 1, "a top hit that arrives later leaves the highlight where it was")
    }

    // MARK: Typing and the filled-in name

    @Test func typingForwardIsNotADeletionAndTheFilledInNameIsNotTyping() {
        var typed = TypedText()
        var changed = typed.changed(from: "", to: "g")
        #expect(changed && !typed.deleting)
        changed = typed.changed(from: "g", to: "gi")
        #expect(changed && !typed.deleting)
        typed.complete(to: "github.com")
        changed = typed.changed(from: "gi", to: "github.com")
        #expect(!changed, "the name arriving changes nothing the list is for")
        #expect(typed.words == "gi" && typed.completed == "github.com")
        changed = typed.changed(from: "github.com", to: "git")
        #expect(changed && !typed.deleting, "a letter typed over the filled-in part goes on from the words")
        #expect(typed.words == "git" && typed.completed == nil)
        changed = typed.changed(from: "git", to: "gi")
        #expect(changed && typed.deleting, "Backspace")
    }

    @Test func theFirstLetterOverTheWholeAddressIsTyping() {
        var typed = TypedText("https://example.com/")
        let changed = typed.changed(from: "https://example.com/", to: "g")
        #expect(changed && !typed.deleting, "⌘L selects the address, and the first letter replaces it")
        var composing = TypedText("ㄱ")
        _ = composing.changed(from: "ㄱ", to: "가")
        #expect(!composing.deleting, "an input method composing a syllable")
    }

    @MainActor private func editor(_ text: String) throws -> (NSTextField, NSTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let field = NSTextField(string: text)
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        return (field, editor)
    }

    @Test @MainActor func theRestOfTheNameIsFilledInSelectedAndIsTheFieldsText() throws {
        let (field, editor) = try editor("git")
        #expect(!CommandBar.mayFill(editor, after: "git"), "not while the words are selected rather than typed")
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(CommandBar.mayFill(editor, after: "git"))
        #expect(!CommandBar.mayFill(editor, after: "gi"), "a later letter has come")
        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        CommandBar.fill(editor, with: "hub.com")
        #expect(editor.string == "github.com")
        #expect(editor.selectedRange() == NSRange(location: 3, length: 7), "the next letter replaces it, Delete takes it away")
        #expect(changes == 1, "the field is told, as of typing, so its text and the binding agree")
        #expect(field.stringValue == "github.com")
        editor.insertText("h", replacementRange: editor.selectedRange())
        #expect(editor.string == "gith")
    }

    @Test @MainActor func nothingIsFilledInWhileASyllableIsBeingComposed() throws {
        let (_, editor) = try editor("")
        editor.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(!CommandBar.mayFill(editor, after: editor.string))
    }
}
