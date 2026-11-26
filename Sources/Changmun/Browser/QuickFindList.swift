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
        case .sleepTabs:
            // They sleep as each one's media state comes back, so there is no count to say; the message says whether any can.
            guard browser.tabs.contains(where: { !browser.isShown($0) && !$0.isStart && $0.webView != nil }) else {
                return browser.flashStatus(String(localized: "No background tabs are awake"))
            }
            browser.sleepIdleTabs(olderThan: 0)
            browser.flashStatus(String(localized: "Putting background tabs to sleep"))
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
    /// Other spaces shown for words; with nothing typed they are all shown (a window has few), so that every one can be reached by the arrow keys.
    static let spaceLimit = 4
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

    /// What the library found, and the words it was asked about: a result is only ever shown for those words (`items`), so one that arrives late,
    /// or has not yet been replaced after another letter was typed, can't put the previous words' rows in front of Return.
    struct Found: Equatable {
        var query: String
        var bookmarks: [Library.Entry] = []
        var visits: [Library.Entry] = []
    }

    /// The words of a query as one string, which is what `Found` is for.
    static func normalized(_ query: String) -> String { words(query).joined(separator: " ") }

    /// What the window shows for `query`. `found` is what the library found (off the main thread, so it comes when it comes); the tabs, spaces and
    /// commands are in memory and are worked out here.
    ///
    /// A space or a command whose name starts with the words comes before the tabs (a tab that holds "work" in its address must not stand
    /// between the user and the space called Work, nor "split" and Split View); the others of them follow the tabs.
    ///
    /// Only this window's tabs are ever looked at, so a private window's tabs are not in another window's list, and its list has no other
    /// window's tabs. A private window also has no spaces to go to and no history.
    @MainActor
    static func items(for query: String, in browser: Browser, found: Found? = nil) -> [QuickFindItem] {
        let words = words(query)
        let typed = words.joined(separator: " ")
        let candidates = browser.tabs.filter { $0.id != browser.activeID && !$0.isStart }
        // A tab that is open is not offered again as the page it shows.
        let open = Set(browser.tabs.compactMap { $0.url?.absoluteString })

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
        let tabRows: [QuickFindItem] = tabs.prefix(tabLimit).map { tab in
            .tab(id: tab.id, title: tab.displayTitle.isEmpty ? (tab.url?.host() ?? "") : tab.displayTitle, url: tab.url?.absoluteString ?? "",
                 space: tab.spaceID == browser.spaceID || browser.isPrivate ? nil : browser.spaces.space(tab.spaceID).name,
                 sleeping: tab.webView == nil && tab.url != nil)
        }

        var spaceRows: [(row: QuickFindItem, name: String)] = []
        if !browser.isPrivate {
            spaceRows = browser.spaces.spaces.filter { $0.id != browser.spaceID && (words.isEmpty || matches($0.name, words)) }
                .map { (.space(id: $0.id, name: $0.name, symbol: $0.symbol), $0.name) }
        }
        let splitShown = browser.shownSplit != nil
        var commandRows: [(row: QuickFindItem, name: String)] = []
        for command in QuickFindCommand.allCases {
            let title = command.title(splitShown: splitShown)
            if words.isEmpty || matches(title, words) { commandRows.append((.command(command, title: title), title)) }
        }

        guard !words.isEmpty else { return tabRows + spaceRows.map(\.row) + commandRows.map(\.row) }
        // The name the words are the start of, the whole name first.
        func leads(_ entry: (row: QuickFindItem, name: String)) -> Bool { Library.fold(entry.name).hasPrefix(typed) }
        let starting = (spaceRows + commandRows).filter(leads)
        let leading = starting.filter { Library.fold($0.name) == typed } + starting.filter { Library.fold($0.name) != typed }
        var list = leading.map(\.row) + tabRows
        list += spaceRows.filter { !leads($0) }.prefix(spaceLimit).map(\.row) + commandRows.filter { !leads($0) }.map(\.row)
        // The library's rows are for the words they were found for.
        if let found, found.query == typed {
            var seen = open
            list += found.bookmarks.filter { seen.insert($0.url).inserted }.prefix(bookmarkLimit).map { .bookmark(url: $0.url, title: $0.title) }
            if !browser.isPrivate {
                list += found.visits.filter { seen.insert($0.url).inserted }.prefix(visitLimit).map { .visit(url: $0.url, title: $0.title) }
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

    /// The highlight after an arrow key (`delta` 1 down, -1 up): it stops at the ends.
    static func moved(_ selection: Int, by delta: Int, in count: Int) -> Int {
        max(0, min(selection + delta, count - 1))
    }

    /// The row Return runs: the highlighted one, none when the highlight is past the end of the list, nor while an input method is still
    /// composing (that Return only settles the syllable).
    static func chosen(_ items: [QuickFindItem], at selection: Int, composing: Bool = false) -> QuickFindItem? {
        !composing && items.indices.contains(selection) ? items[selection] : nil
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
