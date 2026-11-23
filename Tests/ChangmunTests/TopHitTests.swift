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
        library.addBookmark(url: "https://nytimes.com/", title: "NYT", folder: "")
        let sites = library.sites()
        #expect(sites.hit(for: "git", history: false) == nil, "the history stays out")
        #expect(sites.hit(for: "n", history: false)?.host == "nytimes.com")
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

    /// On the main thread, as the Privacy settings and the History window clear it.
    @Test @MainActor func aClearedHistoryLeavesNoSite() throws {
        let library = library()
        try visit(library, "https://github.com/")
        var told = false
        let observer = NotificationCenter.default.addObserver(forName: Library.historyDidShrink, object: nil, queue: nil) { _ in told = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        library.clearHistory(since: .distantPast)
        #expect(told, "said before clearing returns, so the sites read before are dropped at once")
        #expect(library.sites().hit(for: "git") == nil)
    }

    // MARK: Someone else's name

    /// Any page the user was sent to is in the history, redirects included: a stranger's host that starts with a well-known name must
    /// not be offered for that name.
    @Test func aNameIsOnlyCompletedIntoItsOwnDomainNotIntoAStrangersSubdomain() throws {
        let library = library()
        try visit(library, "https://github.com.evil.example/login", times: 50)
        try visit(library, "https://naver.evil.com/", times: 50)
        let sites = library.sites()
        #expect(sites.hit(for: "github.com") == nil, "the whole name typed is never completed into evil.example")
        #expect(sites.hit(for: "git") == nil)
        #expect(sites.hit(for: "github.com.") == nil)
        #expect(sites.hit(for: "naver") == nil, "naver.com never visited: nothing, rather than naver.evil.com")
        #expect(sites.hit(for: "www.naver") == nil)
        #expect(sites.hit(for: "github.com.e")?.host == "github.com.evil.example", "typed into its own domain, it is that site")
        #expect(sites.hit(for: "naver.ev")?.host == "naver.evil.com")
        try visit(library, "https://github.com/", times: 1)
        #expect(library.sites().hit(for: "git")?.host == "github.com", "the real site, however much less visited")
        #expect(library.sites().hit(for: "github.com") == nil)
    }

    /// The host is cut from the address as text: a user name in front of it must not make it read as the name typed.
    @Test func anAddressWithAUserNameIsNoSite() throws {
        let library = library()
        try visit(library, "https://github.com@evil.example/", times: 50)
        try visit(library, "https://naver.com:pw@evil.example/", times: 50)
        let sites = library.sites()
        #expect(sites.hit(for: "github.com") == nil)
        #expect(sites.hit(for: "git") == nil)
        #expect(sites.hit(for: "naver.com") == nil)
        #expect(!SiteIndex.isHostName("github.com@evil.example"))
        #expect(SiteIndex.isHostName("localhost:3000") && SiteIndex.isHostName("[::1]:8080") && SiteIndex.isHostName("네이버.한국"))
    }

    @Test func aSubdomainIsCompletedOnceTheTypingReachesItsDomain() throws {
        let library = library()
        try visit(library, "https://mail.google.com/mail/u/0/", times: 9)
        try visit(library, "https://shop.naver.co.kr/", times: 9)
        try visit(library, "https://naver.co.kr.evil.example/", times: 9)
        let sites = library.sites()
        #expect(sites.hit(for: "mail.goo")?.host == "mail.google.com")
        #expect(sites.hit(for: "mail") == nil, "all of it is in front of google.com")
        #expect(sites.hit(for: "shop.nav")?.host == "shop.naver.co.kr", "co.kr is a suffix: naver.co.kr is the domain")
        #expect(sites.hit(for: "shop.naver.co")?.host == "shop.naver.co.kr")
        #expect(sites.hit(for: "naver.co.kr") == nil)
        #expect(sites.hit(for: "nav") == nil)
    }

    @Test func aSiteUnderAPrivateSuffixIsCompletedFromItsOwnName() throws {
        // github.io and tistory.com are suffixes: each user's site is a domain of its own, so its first label reaches into it.
        // The last-two-labels guess before the Public Suffix List took github.io for the domain and completed none of these.
        let library = library()
        try visit(library, "https://foo.github.io/", times: 9)
        try visit(library, "https://alice.tistory.com/", times: 9)
        let sites = library.sites()
        #expect(sites.hit(for: "foo")?.host == "foo.github.io")
        #expect(sites.hit(for: "foo").flatMap { SiteIndex.completion(of: "foo", to: $0) } == ".github.io")
        #expect(sites.hit(for: "ali")?.host == "alice.tistory.com")
    }

    @Test func theRegistrableDomainIsThePublicSuffixAndOneLabel() {
        #expect(SiteIndex.registrableStart("alice.github.io") == 0, "github.io is a suffix (the PSL's private section)")
        #expect(SiteIndex.registrableStart("blog.alice.github.io") == "blog.".utf8.count)
        #expect(SiteIndex.registrableStart("github.io") == 0, "a suffix itself is a domain whole")
        #expect(SiteIndex.registrableStart("github.com") == 0)
        #expect(SiteIndex.registrableStart("github.com.evil.example") == "github.com.".utf8.count)
        #expect(SiteIndex.registrableStart("mail.google.com") == "mail.".utf8.count)
        #expect(SiteIndex.registrableStart("shop.naver.co.kr") == "shop.".utf8.count)
        #expect(SiteIndex.registrableStart("naver.co.kr") == 0)
        #expect(SiteIndex.registrableStart("bbc.co.uk") == 0)
        #expect(SiteIndex.registrableStart("news.bbc.co.uk") == "news.".utf8.count)
        #expect(SiteIndex.registrableStart("a.b.example.com.au") == "a.b.".utf8.count)
        #expect(SiteIndex.registrableStart("github.com.evil.example:8443") == "github.com.".utf8.count, "a port doesn't count")
        #expect(SiteIndex.registrableStart("localhost") == 0)
        #expect(SiteIndex.registrableStart("localhost:3000") == 0)
        #expect(SiteIndex.registrableStart("192.168.0.10") == 0)
        #expect(SiteIndex.registrableStart("192.168.0.10:8080") == 0)
        #expect(SiteIndex.registrableStart("[::1]:8080") == 0)
    }

    // MARK: The name typed whole

    @Test func aNameTypedWholeOpensAsTypedThoughALongerOneStartsWithIt() throws {
        let library = library()
        try visit(library, "https://github.com/", times: 1)
        try visit(library, "https://github.community/", times: 40)
        try visit(library, "http://localhost:3000/", times: 40)
        var sites = library.sites()
        #expect(sites.hit(for: "github.com") == nil, "not github.com|munity")
        #expect(sites.hit(for: "github.c")?.host == "github.community", "a name not yet whole is still completed")
        #expect(sites.hit(for: "localhost")?.host == "localhost:3000", "localhost itself never visited")
        try visit(library, "http://localhost/", times: 1)
        sites = library.sites()
        #expect(sites.hit(for: "localhost") == nil)
        library.addBookmark(url: "https://gitlab.com/", title: "GitLab", folder: "")
        try visit(library, "https://gitlab.company.example/", times: 40)
        #expect(library.sites().hit(for: "gitlab.com") == nil, "a bookmarked name counts too")
    }

    // MARK: What Return opens

    @Test @MainActor func whileTheNameIsFilledInReturnOpensTheSitesFrontPage() {
        let browser = Browser()
        let deep = SiteIndex.Site(host: "github.com", url: "https://www.github.com/namekun/Changmun/issues?q=1#top", title: "Issues", score: 9)
        var typed = TypedText("git")
        #expect(CommandBar.topHit(typed, browser: browser, in: index(deep).hit)?.url == deep.url, "nothing filled in: the busiest page, as listed")
        typed.complete(to: "github.com")
        let front = CommandBar.topHit(typed, browser: browser, in: index(deep).hit)
        #expect(front?.url == "https://www.github.com/", "the scheme and name it was visited at")
        #expect(CommandBar.topHit(typed, browser: browser, in: index(github).hit) == github, "a front page is itself")
        _ = typed.keep()
        #expect(CommandBar.topHit(typed, browser: browser, in: index(github).hit) == nil, "kept, the name is typed whole and opens as it is")
    }

    // MARK: Pasting

    @Test @MainActor func pastedWordsKeepTheSearchFirstAndTheSiteBelowIt() {
        let browser = Browser()
        var typed = TypedText()
        _ = typed.changed(from: "", to: "git", by: .pasted)
        #expect(typed.pasted)
        let top = CommandBar.topHit(typed, browser: browser, in: index(github).hit)
        let list = CommandBar.suggestions(shown: typed.words, pages: [], searches: [], browser: browser, mode: .newTab, top: top, topFirst: !typed.pasted)
        #expect(Array(list.prefix(3)) == [.search("git"), .top(url: "https://github.com/", title: "GitHub"), .ask("git")])
        _ = typed.changed(from: "git", to: "gith", by: .typed)
        #expect(!typed.pasted, "typing on puts the site first again")
    }

    // MARK: The list

    private func index(_ sites: SiteIndex.Site...) -> SiteIndex { SiteIndex(visited: sites) }
    private let github = SiteIndex.Site(host: "github.com", url: "https://github.com/", title: "GitHub", score: 9, root: true)

    @Test @MainActor func theTopHitComesFirstThenTheSearchAndTheAI() {
        let browser = Browser()
        let typed = TypedText("git")
        let top = CommandBar.topHit(typed, browser: browser, in: index(github).hit)
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
        let top = CommandBar.topHit(typed, browser: browser, in: index(github).hit)
        #expect(top == nil)
        #expect(CommandBar.suggestions(shown: typed.words, pages: [], searches: [], browser: browser, mode: .newTab, top: top).first == .search("git hub"))
    }

    @Test @MainActor func aPrivateWindowPutsNoVisitedSiteFirst() {
        let browser = Browser(isPrivate: true)
        let typed = TypedText("git")
        let top = CommandBar.topHit(typed, browser: browser, in: index(github).hit)
        #expect(top == nil)
        #expect(CommandBar.suggestions(shown: typed.words, pages: [], searches: [], browser: browser, mode: .newTab, top: top) == [.search("git")])
    }

    @Test @MainActor func afterADeletionTheFirstRowIsWhatTheFieldShows() {
        let browser = Browser()
        var typed = TypedText("git")
        typed.complete(to: "github.com")
        _ = typed.changed(from: "github.com", to: "git")
        #expect(typed.deleting, "Delete takes the filled-in name away")
        #expect(CommandBar.topHit(typed, browser: browser, in: index(github).hit) == nil)
        _ = typed.changed(from: "git", to: "gith")
        #expect(CommandBar.topHit(typed, browser: browser, in: index(github).hit) == github, "typing on brings it back")
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

    /// → (or End, or a click) keeps the filled-in name: from then on it is what was typed, so Backspace takes a letter off it and the
    /// rows are for the whole name, not for the letter before it.
    @Test @MainActor func aKeptNameIsTypedTextAndBackspaceDoesNotBringItBack() throws {
        let (_, editor) = try editor("g")
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        var typed = TypedText()
        _ = typed.changed(from: "", to: "g", by: .typed)
        #expect(CommandBar.fill(editor, with: "ithub.com"))
        typed.complete(to: editor.string)
        #expect(!CommandBar.movedOff(editor, typed), "filled in and selected")
        editor.moveRight(nil)
        #expect(CommandBar.movedOff(editor, typed), "→ put the caret after it")
        let kept = typed.keep()
        #expect(kept)
        #expect(typed.words == "github.com" && typed.completed == nil)
        #expect(!CommandBar.movedOff(editor, typed), "nothing filled in any more")
        editor.deleteBackward(nil)
        _ = typed.changed(from: "github.com", to: editor.string, by: .deleted)
        #expect(typed.words == "github.co" && typed.deleting, "Backspace, and nothing is filled in again")
        var unsaid = TypedText("github.com")
        _ = unsaid.changed(from: "github.com", to: "github.co")
        #expect(unsaid.deleting, "also when the editor didn't say how")
    }

    /// The editor's storage says what an edit did: ⌘L's address all selected and replaced by "h" is typing, though "h" is how it starts.
    @Test @MainActor func typingOverASelectionIsTypingAndOnlyTakingOutIsDeleting() throws {
        let (_, editor) = try editor("https://example.com/")
        let storage = try #require(editor.textStorage)
        var edits: [TypedText.Edit?] = []
        var event: NSEvent?
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { _ in
            MainActor.assumeIsolated { edits.append(CommandBar.edit(storage, event: event)) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        editor.selectAll(nil)
        editor.insertText("h", replacementRange: editor.selectedRange())
        editor.insertText("t", replacementRange: editor.selectedRange())
        editor.deleteBackward(nil)
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        #expect(edits == [.typed, .typed, .deleted, .deleted])
        var typed = TypedText("https://example.com/")
        _ = typed.changed(from: "https://example.com/", to: "h", by: edits[0])
        #expect(!typed.deleting, "the first letter over the address goes forward")
        event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)
        editor.insertText("github", replacementRange: editor.selectedRange())
        #expect(edits.last == .pasted, "⌘V")
        event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime - 30,
                                 windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)
        editor.insertText("x", replacementRange: editor.selectedRange())
        #expect(edits.last == .typed, "an event handled long before says nothing of this edit")
    }

    @Test @MainActor func nothingIsFilledInWhileASyllableIsBeingComposed() throws {
        let (_, editor) = try editor("")
        editor.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(!CommandBar.mayFill(editor, after: editor.string))
    }
}
