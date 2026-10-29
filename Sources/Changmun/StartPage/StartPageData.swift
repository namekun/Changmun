import Foundation

/// What the start page shows and when, worked out from plain values so that the rules can be tested without a window:
/// which closed tabs and pages make the "Continue where you left off" cards, which sections are visible, in what arrangement,
/// what an icon without a good picture looks like, and how long ago something was.

// MARK: Cards

struct StartClosedTab: Equatable {
    var id: UUID
    var url: String?
    var title: String
    var closedAt: Date
    var space: UUID
}

struct StartContinueCard: Identifiable, Equatable {
    enum Kind: Equatable {
        case closedTab(UUID)
        case page
    }

    var kind: Kind
    var url: String
    var title: String
    var date: Date

    var id: String {
        switch kind {
        case .closedTab(let tab): "tab:" + tab.uuidString
        case .page: "page:" + url
        }
    }

    var isClosedTab: Bool { if case .closedTab = kind { true } else { false } }
}

/// A site that is visited often: its visits counted over all its pages.
struct StartFrequentSite: Identifiable, Equatable {
    var host: String
    var title: String
    var url: String
    var visits: Int

    var id: String { host }

    /// The pages of the history that are visited most (`url`, `title`, `visits`), brought together by site: the most visited site first, and a
    /// site is called by the title of its front page when it has one (cut at a dash or bar), by its address else.
    static func group(_ pages: [(url: String, title: String, visits: Int)]) -> [StartFrequentSite] {
        var order: [String] = []
        var sites: [String: StartFrequentSite] = [:]
        var best: [String: Int] = [:]
        var named: Set<String> = []
        for page in pages {
            guard let components = URLComponents(string: page.url), let host = components.host?.lowercased(), !host.isEmpty else { continue }
            let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if sites[site] == nil {
                order.append(site)
                sites[site] = StartFrequentSite(host: site, title: site, url: page.url, visits: 0)
            }
            sites[site]?.visits += page.visits
            let isFront = components.path.isEmpty || components.path == "/"
            if !named.contains(site), isFront, let name = shortTitle(page.title) {
                sites[site]?.title = name
                named.insert(site)
            }
            if page.visits > best[site, default: -1] {
                best[site] = page.visits
                sites[site]?.url = page.url
            }
        }
        return order.compactMap { sites[$0] }.sorted { $0.visits != $1.visits ? $0.visits > $1.visits : $0.host < $1.host }
    }

    /// "GitHub: Let's build from here" is "GitHub"; nil for an empty title.
    static func shortTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for separator in [" - ", " | ", " — ", " · ", ": "] {
            if let range = trimmed.range(of: separator), range.lowerBound > trimmed.startIndex {
                return String(trimmed[..<range.lowerBound])
            }
        }
        return trimmed
    }
}

enum StartPageData {
    /// The cards of "Continue where you left off" that fit one row on a wide page.
    static let cardLimit = 4
    static let readingLimit = 4
    static let readingAllLimit = 6

    /// An address as two pages that are the same one share it (no fragment, no slash at the end of the path); other text is its own.
    static func key(_ address: String) -> String { ReadingList.key(for: address) ?? address }

    /// The closed tabs of this space, newest first, then (unless `closedOnly`) the pages most recently visited: no page twice, none that is
    /// open now, none that is on a card already, none the user took off the page (`hidden` holds `key`s). Nothing at all in a private window.
    /// `closed` is in the order the browser keeps it, the most recently closed last; `history` newest first.
    static func continueCards(closed: [StartClosedTab], history: [Library.Visit], open: [String], space: UUID, closedOnly: Bool,
                              limit: Int = cardLimit, hidden: Set<String> = [], isPrivate: Bool) -> [StartContinueCard] {
        guard !isPrivate, limit > 0 else { return [] }
        var taken = Set(open.map(key)).union(hidden)
        var cards: [StartContinueCard] = []
        for tab in closed.reversed() where tab.space == space {
            guard let url = tab.url?.nonEmpty, url.hasPrefix("http"), taken.insert(key(url)).inserted else { continue }
            cards.append(StartContinueCard(kind: .closedTab(tab.id), url: url, title: tab.title.isEmpty ? url : tab.title, date: tab.closedAt))
            if cards.count == limit { return cards }
        }
        guard !closedOnly else { return cards }
        for visit in history {
            guard visit.url.hasPrefix("http"), taken.insert(key(visit.url)).inserted else { continue }
            cards.append(StartContinueCard(kind: .page, url: visit.url, title: visit.title.isEmpty ? visit.url : visit.title, date: visit.lastVisit))
            if cards.count == limit { break }
        }
        return cards
    }

    /// The saved pages the section shows: the unread ones (or all of them), newest first as the list keeps them, and how many are unread.
    static func readingItems(_ items: [ReadingItem], all: Bool, isPrivate: Bool) -> (shown: [ReadingItem], unread: Int) {
        guard !isPrivate else { return ([], 0) }
        let unread = items.filter { !$0.read }
        let shown = all ? Array(items.prefix(readingAllLimit)) : Array(unread.prefix(readingLimit))
        return (shown, unread.count)
    }

    static func frequentSites(_ sites: [StartFrequentSite], eight: Bool, hidden: Set<String> = [], isPrivate: Bool) -> [StartFrequentSite] {
        guard !isPrivate else { return [] }
        return Array(sites.filter { !hidden.contains(hiddenKey(site: $0.host)) }.prefix(eight ? 8 : 4))
    }

    static func hiddenKey(site host: String) -> String { "site:" + host }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension Library {
    /// The most visited pages (`url`, `title`, `visits`), for the start page's "Frequently visited"; a bounded read, like the rest of the library's.
    func frequentPages(limit: Int = 300) -> [(url: String, title: String, visits: Int)] {
        let rows = (try? db?.query("SELECT url, title, visits FROM history ORDER BY visits DESC, last_visit DESC LIMIT ?", [limit])) ?? []
        return rows.compactMap { row in
            guard let url = row[0] as? String else { return nil }
            return (url, row[1] as? String ?? "", Int(row[2] as? Int64 ?? 0))
        }
    }
}

// MARK: Which part of the page is shown

/// What the page has to show, counted after the limits and what was taken off it.
struct StartPageContents: Equatable {
    var isPrivate = false
    var aiReady = false
    var favorites = 0
    var continueCards = 0
    var reading = 0
    var frequent = 0
    /// Anything of the user's at all: favorites, history, saved pages, closed tabs. Nothing is a fresh profile.
    var hasData = false
}

enum StartPageMode: Equatable {
    /// The search field and these sections, in this order.
    case sections([StartSection])
    /// A fresh profile: the first steps instead of empty sections.
    case firstRun
    case privateNotice
}

enum StartPageRules {
    /// A private window shows only its notice; a profile with nothing in it the first steps (but the AI-first page, whose box doesn't
    /// need data, stays what it is); else the sections that are on and have something to show. Favorites are always shown when on.
    static func mode(layout: StartLayout, style: StartStyle, contents: StartPageContents) -> StartPageMode {
        if contents.isPrivate { return .privateNotice }
        if !contents.hasData && style != .aiFirst { return .firstRun }
        let shown = layout.shown.map(\.section).filter { section in
            switch section {
            case .aiSuggestions: contents.aiReady
            case .favorites: true
            case .continueViewing: contents.continueCards > 0
            case .readingList: contents.reading > 0
            case .frequent: contents.frequent > 0
            }
        }
        return .sections(shown)
    }

    /// Why a section that is on is not on the page yet, for the popover's row ("Nothing here yet"): it is on, and has nothing to show.
    static func isEmpty(_ section: StartSection, contents: StartPageContents) -> Bool {
        switch section {
        case .aiSuggestions: !contents.aiReady || contents.isPrivate
        case .favorites: false
        case .continueViewing: contents.continueCards == 0
        case .readingList: contents.reading == 0
        case .frequent: contents.frequent == 0
        }
    }
}

// MARK: Arrangement

/// How the sections lie on the page, from top to bottom.
enum StartPageRow: Equatable {
    /// A section on its own, at the page's width.
    case full(StartSection)
    /// Two half-width sections side by side.
    case pair(StartSection, StartSection)
    /// A half-width section that has no neighbour: it spreads over the width and flows its rows into two columns.
    case wide(StartSection)
}

enum StartPageArrangement {
    static func isHalf(_ section: StartSection) -> Bool { section == .readingList || section == .frequent }

    /// The dashboard and AI-first pages place the sections in order, and two half-width ones that follow each other side by side. The AI
    /// suggestions of the AI-first page are not among them: they belong to the prompt box above. The quiet page stacks all in one narrow column.
    static func rows(_ sections: [StartSection], style: StartStyle) -> [StartPageRow] {
        let sections = style == .aiFirst ? sections.filter { $0 != .aiSuggestions } : sections
        guard style == .dashboard || style == .aiFirst else { return sections.map { .full($0) } }
        var rows: [StartPageRow] = []
        var index = 0
        while index < sections.count {
            let section = sections[index]
            if style == .dashboard, isHalf(section) {
                if index + 1 < sections.count, isHalf(sections[index + 1]) {
                    rows.append(.pair(section, sections[index + 1]))
                    index += 2
                    continue
                }
                rows.append(.wide(section))
            } else {
                rows.append(.full(section))
            }
            index += 1
        }
        return rows
    }

    /// The favorites in one row or two: two rows are balanced (4 and 4, not 7 and 1).
    static func favoriteRows(count: Int, twoRows: Bool) -> [Range<Int>] {
        guard count > 0 else { return [] }
        guard twoRows, count > 1 else { return [0..<count] }
        let first = (count + 1) / 2
        return [0..<first, first..<count]
    }
}

// MARK: The AI's suggestions

struct StartAISuggestion: Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var symbol: String

    /// What the AI is asked: the title, as the user would type it.
    var prompt: String { title }
}

enum StartPageAI {
    /// Suggestions that fit what is open: ones about the tabs only when there are tabs (to compare, two; to group, three), else ones about the web.
    static func suggestions(tabs: Int, limit: Int) -> [StartAISuggestion] {
        var list: [StartAISuggestion] = []
        if tabs >= 1 {
            list.append(StartAISuggestion(id: "summarize", title: String(localized: "Sum up my open tabs"),
                                          detail: tabs == 1 ? String(localized: "Just the key points of the tab") : String(localized: "Just the key points of \(tabs) tabs"),
                                          symbol: "square.on.square"))
        }
        if tabs >= 2 {
            list.append(StartAISuggestion(id: "compare", title: String(localized: "Compare my open tabs"),
                                          detail: String(localized: "Prices, specs and pros and cons in a table"), symbol: "rectangle.on.rectangle"))
        }
        list.append(StartAISuggestion(id: "research", title: String(localized: "Look it up on the web and sum it up"),
                                      detail: String(localized: "Opens several sites and summarizes them"), symbol: "magnifyingglass"))
        if tabs >= 3 {
            list.append(StartAISuggestion(id: "group", title: String(localized: "Group my tabs by topic"),
                                          detail: String(localized: "Gathers related tabs into groups"), symbol: "bolt"))
        }
        if tabs < 2 {
            list.append(StartAISuggestion(id: "find", title: String(localized: "Find the best sites for a topic"),
                                          detail: String(localized: "Compares a few and picks the one to read"), symbol: "star"))
            list.append(StartAISuggestion(id: "explain", title: String(localized: "Explain something simply"),
                                          detail: String(localized: "Looks it up and explains it in plain words"), symbol: "text.bubble"))
        }
        return Array(list.prefix(limit))
    }
}

// MARK: Icons

enum StartIconStyle: Equatable {
    /// A good picture: the tile is filled with it.
    case full
    /// A small one: kept small on a white plate, so that it isn't blown up soft.
    case plate
    /// None: the first letter of the site.
    case letter

    /// By the widest side of the biggest picture the icon has, in pixels; nil when no icon is kept.
    static func style(pixelWidth: Int?) -> StartIconStyle {
        guard let pixelWidth else { return .letter }
        if pixelWidth >= 48 { return .full }
        return pixelWidth >= 12 ? .plate : .letter
    }

    /// The letter of a site's tile: the first letter or digit of its name, upper case ("?" if it has none).
    static func letter(for address: String) -> String {
        let host = URL(string: address)?.host() ?? address
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    }

    /// Which of `count` colours a site's letter tile has: the same one every time, whatever the process (`hashValue` is not).
    static func colorIndex(for address: String, count: Int) -> Int {
        let host = URL(string: address)?.host() ?? address
        let sum = host.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0xFFFFFF }
        return sum % max(1, count)
    }
}

// MARK: Time

enum StartPageTime {
    enum Bucket: Equatable {
        case minutes(Int)
        case today
        case yesterday
        case days(Int)
        case weeks(Int)
        case older
    }

    /// How long ago: within the hour in minutes, later today by the time of day, then yesterday, days up to a week, weeks up to five, then a date.
    static func bucket(_ date: Date, now: Date, calendar: Calendar = .current) -> Bucket {
        let seconds = now.timeIntervalSince(date)
        if seconds < 3600 { return .minutes(max(0, Int(seconds / 60))) }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if calendar.isDateInYesterday(date) || calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day == 1 { return .yesterday }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return .days(max(2, days)) }
        if days < 35 { return .weeks(days / 7) }
        return .older
    }

    /// "8 min. ago", "today 9:12 AM", "yesterday", "2 days ago", "last week", in the language of `locale`.
    static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let relative = RelativeDateTimeFormatter()
        relative.locale = locale
        relative.calendar = calendar
        relative.dateTimeStyle = .named
        relative.unitsStyle = .short
        switch bucket(date, now: now, calendar: calendar) {
        case .minutes(let minutes):
            return minutes < 1 ? relative.localizedString(for: now, relativeTo: now) : relative.localizedString(from: DateComponents(minute: -minutes))
        case .today:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true
            return formatter.string(from: date)
        case .yesterday: return relative.localizedString(from: DateComponents(day: -1))
        case .days(let days): return relative.localizedString(from: DateComponents(day: -days))
        case .weeks(let weeks): return relative.localizedString(from: DateComponents(weekOfYear: -weeks))
        case .older:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }
}

// MARK: Keyboard

/// Where the keyboard is on the page when it is not in the search field: a part (a section or the Customize button) and an item in it.
/// Pure, so the moves can be tested: ⇥ and ⇧⇥ go from part to part, the arrows within one and on into the next.
struct StartPageCursor: Equatable {
    enum Part: Hashable {
        case section(StartSection)
        case customize
    }

    struct Stop: Equatable {
        var part: Part
        var item: Int
    }

    /// What each part holds: how many items, and how many in a row (arrows left and right move one, up and down a row).
    struct Shape: Equatable {
        var part: Part
        var count: Int
        var columns: Int
    }

    var stop: Stop?

    /// The parts from top to bottom; the Customize button is the last.
    static func order(_ shapes: [Shape]) -> [Shape] { shapes.filter { $0.count > 0 } }

    /// ⇥ (or ⇧⇥): the first item of the next part; past the last, back to the search field (nil).
    func tab(_ shapes: [Shape], backwards: Bool) -> StartPageCursor {
        let shapes = Self.order(shapes)
        guard !shapes.isEmpty else { return StartPageCursor(stop: nil) }
        guard let stop, let current = shapes.firstIndex(where: { $0.part == stop.part }) else {
            return StartPageCursor(stop: Stop(part: (backwards ? shapes.last : shapes.first)!.part, item: 0))
        }
        let next = current + (backwards ? -1 : 1)
        return shapes.indices.contains(next) ? StartPageCursor(stop: Stop(part: shapes[next].part, item: 0)) : StartPageCursor(stop: nil)
    }

    enum Arrow { case left, right, up, down }

    /// An arrow: along the part's rows; off the top of the first part the keyboard goes back to the search field (nil), off the bottom of
    /// the last it stays; between parts up goes to the last item of the one before, down to the first of the next.
    func move(_ arrow: Arrow, _ shapes: [Shape]) -> StartPageCursor {
        let shapes = Self.order(shapes)
        guard let stop, let current = shapes.firstIndex(where: { $0.part == stop.part }) else {
            return arrow == .down && !shapes.isEmpty ? StartPageCursor(stop: Stop(part: shapes[0].part, item: 0)) : self
        }
        let shape = shapes[current]
        let columns = max(1, shape.columns)
        var item = stop.item
        switch arrow {
        case .left: item -= 1
        case .right: item += 1
        case .up: item -= columns
        case .down: item += columns
        }
        if shape.count > 0, item >= 0, item < shape.count { return StartPageCursor(stop: Stop(part: shape.part, item: item)) }
        switch arrow {
        case .left, .right:
            return self
        case .up:
            if current == 0 { return StartPageCursor(stop: nil) }
            let before = shapes[current - 1]
            return StartPageCursor(stop: Stop(part: before.part, item: before.count - 1))
        case .down:
            // Down from a short last row stays in the part when there is a row below, else goes on.
            if stop.item + columns >= shape.count, stop.item / columns < (shape.count - 1) / columns {
                return StartPageCursor(stop: Stop(part: shape.part, item: shape.count - 1))
            }
            if current + 1 < shapes.count { return StartPageCursor(stop: Stop(part: shapes[current + 1].part, item: 0)) }
            return self
        }
    }
}
