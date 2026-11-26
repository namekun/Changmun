import Foundation

/// What ⌘K can do besides finding a page. Each one is a menu command or a button the browser already has.
enum QuickFindCommand: Hashable, CaseIterable {
    case splitView
    case sleepTabs

    /// `splitShown`: a split is on screen, so the command ends it.
    func title(splitShown: Bool) -> String {
        switch self {
        case .splitView: splitShown ? String(localized: "Close Split View") : String(localized: "Split View")
        case .sleepTabs: String(localized: "Sleep Background Tabs")
        }
    }

    var symbol: String {
        switch self {
        case .splitView: "rectangle.split.2x1"
        case .sleepTabs: "moon.zzz"
        }
    }

    @MainActor func run(in browser: Browser) {
        switch self {
        case .splitView: browser.toggleSplit()
        // The tabs Changmun would put to sleep under memory pressure: not the ones on screen, playing, in use by the AI or set never to sleep.
        case .sleepTabs: browser.sleepIdleTabs(olderThan: 0)
        }
    }
}

/// The list the ⌘K window shows: the window's own tabs (the ones of every space it has), its spaces, a few commands, then bookmarks and history.
/// The address bar goes to a page or a search; this finds what the user already has.
enum QuickFindItem: Hashable {
    /// `space` names the space it is in when that isn't the one shown.
    case tab(id: Int, title: String, url: String, space: String?, sleeping: Bool)
    case space(id: UUID, name: String, symbol: String)
    case command(QuickFindCommand, title: String)
    case bookmark(url: String, title: String)
    case visit(url: String, title: String)

    /// The item as the row it makes is named: a tab by its number alone, which its title and address (changing as the page loads) are not part of.
    var identity: QuickFindItem {
        if case .tab(let id, _, _, _, _) = self { return .tab(id: id, title: "", url: "", space: nil, sleeping: false) }
        return self
    }
}

enum QuickFindList {
    static let tabLimit = 6
    static let spaceLimit = 2
    static let bookmarkLimit = 3
    static let visitLimit = 3

    /// The words of a query as they are looked for: any case, and every one of them has to be in the text.
    static func words(_ query: String) -> [String] {
        Library.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func matches(_ text: String, _ words: [String]) -> Bool {
        let text = Library.fold(text)
        return !words.isEmpty && words.allSatisfy { text.contains($0) }
    }

    /// What the window shows for `query`. `bookmarks` and `visits` are what the library found for the same words (off the main thread, so
    /// they come when they come); the tabs, spaces and commands are in memory and are worked out here.
    ///
    /// Only this window's tabs are ever looked at, so a private window's tabs are not in another window's list, and its list has no other
    /// window's tabs. A private window also has no spaces to go to and no history.
    @MainActor
    static func items(for query: String, in browser: Browser, bookmarks: [Library.Entry] = [], visits: [Library.Entry] = []) -> [QuickFindItem] {
        let words = words(query)
        let candidates = browser.tabs.filter { $0.id != browser.activeID && !$0.isStart }
        // A tab that is open is not offered again as the page it shows.
        let open = Set(browser.tabs.compactMap { $0.url?.absoluteString })
        var list: [QuickFindItem] = []

        let tabs: [Tab]
        if words.isEmpty {
            // Nothing typed: the tabs looked at last.
            tabs = candidates.sorted { $0.lastShown > $1.lastShown }
        } else {
            let hits = candidates.filter { matches($0.displayTitle + " " + $0.title + " " + ($0.url?.absoluteString ?? ""), words) }
            // This space's tabs first, those of the others after; each by the start of the title, then by when it was last looked at.
            tabs = hits.sorted { a, b in
                let (sa, sb) = (a.spaceID == browser.spaceID, b.spaceID == browser.spaceID)
                if sa != sb { return sa }
                let (pa, pb) = (startsTitle(a, words), startsTitle(b, words))
                if pa != pb { return pa }
                return a.lastShown > b.lastShown
            }
        }
        list += tabs.prefix(tabLimit).map { tab in
            .tab(id: tab.id, title: tab.displayTitle.isEmpty ? (tab.url?.host() ?? "") : tab.displayTitle, url: tab.url?.absoluteString ?? "",
                 space: tab.spaceID == browser.spaceID || browser.isPrivate ? nil : browser.spaces.space(tab.spaceID).name,
                 sleeping: tab.webView == nil && tab.url != nil)
        }

        if !browser.isPrivate {
            let spaces = browser.spaces.spaces.filter { $0.id != browser.spaceID && (words.isEmpty || matches($0.name, words)) }
            list += spaces.prefix(spaceLimit).map { .space(id: $0.id, name: $0.name, symbol: $0.symbol) }
        }

        let splitShown = browser.shownSplit != nil
        for command in QuickFindCommand.allCases {
            let title = command.title(splitShown: splitShown)
            if words.isEmpty || matches(title, words) { list.append(.command(command, title: title)) }
        }

        if !words.isEmpty {
            var seen = open
            let marks = bookmarks.filter { seen.insert($0.url).inserted }.prefix(bookmarkLimit)
            list += marks.map { .bookmark(url: $0.url, title: $0.title) }
            if !browser.isPrivate {
                list += visits.filter { seen.insert($0.url).inserted }.prefix(visitLimit).map { .visit(url: $0.url, title: $0.title) }
            }
        }
        return list
    }

    @MainActor private static func startsTitle(_ tab: Tab, _ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        return Library.fold(tab.displayTitle).hasPrefix(first)
    }

    /// Where the highlight goes when the list becomes `new`: on the row that was highlighted, wherever it is now, else on the first.
    static func keptSelection(_ selection: Int, old: [QuickFindItem], new: [QuickFindItem]) -> Int {
        guard old.indices.contains(selection) else { return 0 }
        let kept = old[selection].identity
        return new.firstIndex { $0.identity == kept } ?? 0
    }

    /// What Return or a click does with a row: it goes where it says, in this window. A page from the bookmarks or the history opens in a new tab,
    /// as the list is for what the user has, and the page they are on is left alone.
    @MainActor
    static func run(_ item: QuickFindItem?, in browser: Browser) {
        guard let item else { return }
        browser.quickFind = false
        switch item {
        case .tab(let id, _, _, _, _): browser.activate(id)
        case .space(let id, _, _): browser.switchSpace(to: id)
        case .command(let command, _): command.run(in: browser)
        case .bookmark(let url, _), .visit(let url, _): browser.open(url, in: .newTab)
        }
    }
}

extension Browser {
    /// ⌘K: opens the window's find-and-command list, or closes it. It takes the place of the address bar's list while it is open.
    func toggleQuickFind() {
        // Not while the welcome is up: it covers the window, and the list would be waiting behind it.
        if quickFind { quickFind = false } else if !showOnboarding { quickFind = true }
    }
}
