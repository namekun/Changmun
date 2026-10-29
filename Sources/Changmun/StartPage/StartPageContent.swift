import AppKit
import CryptoKit
import SwiftUI

/// What the user took off the page with the ✕ of a card or row. No address or site is stored as such: only salted hashes, with the random salt kept
/// next to them on this Mac (so a short, guessable key can be tried against the list; it is not a secret). It is wiped when history or site data is
/// cleared, on "Reset to Defaults", and pruned at page load of everything that no history, closed tab or site on the page matches any more.
/// At most `limit` entries, the oldest dropped. A private window neither reads nor writes it.
struct StartHiddenList: Codable, Equatable {
    static let limit = 500

    var salt: Data
    /// Oldest first.
    var hashes: [String]

    static func fresh() -> StartHiddenList {
        StartHiddenList(salt: Data((0..<16).map { _ in UInt8.random(in: 0...255) }), hashes: [])
    }

    /// The salted SHA-256 of a normalised key, in hex.
    static func digest(_ key: String, salt: Data) -> String {
        SHA256.hash(data: salt + Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The keys: a page by its address as `ReadingList.key` writes it (no fragment, no slash at the end), a site by its lower-case host.
    static func pageKey(_ address: String) -> String { "page:" + StartPageData.key(address) }
    static func siteKey(_ host: String) -> String { "site:" + host.lowercased() }

    func contains(_ key: String) -> Bool { hashes.contains(Self.digest(key, salt: salt)) }

    mutating func hide(_ key: String) {
        let hash = Self.digest(key, salt: salt)
        guard !hashes.contains(hash) else { return }
        hashes.append(hash)
        if hashes.count > Self.limit { hashes.removeFirst(hashes.count - Self.limit) }
    }

    /// Only what one of `keys` still matches stays.
    func pruned(keeping keys: [String]) -> StartHiddenList {
        let current = Set(keys.map { Self.digest($0, salt: salt) })
        return StartHiddenList(salt: salt, hashes: hashes.filter(current.contains))
    }
}

@MainActor
final class StartHiddenItems: ObservableObject {
    static let shared = StartHiddenItems()
    static let defaultsKey = "startPageHiddenItems"
    /// Where the list was kept before it was hashed: raw addresses, which are not to stay on disk.
    static let legacyKey = "startPageHidden"

    @Published private(set) var list: StartHiddenList?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.removeObject(forKey: Self.legacyKey)
        list = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(StartHiddenList.self, from: $0) }.map {
            // A list longer than `limit` (a damaged or edited file) is cut to its newest entries.
            StartHiddenList(salt: $0.salt, hashes: Array($0.hashes.suffix(StartHiddenList.limit)))
        }
    }

    var count: Int { list?.hashes.count ?? 0 }

    func isHidden(page address: String) -> Bool { list?.contains(StartHiddenList.pageKey(address)) == true }
    func isHidden(site host: String) -> Bool { list?.contains(StartHiddenList.siteKey(host)) == true }

    func hide(page address: String) { hide(StartHiddenList.pageKey(address)) }
    func hide(site host: String) { hide(StartHiddenList.siteKey(host)) }

    private func hide(_ key: String) {
        var next = list ?? .fresh()
        next.hide(key)
        save(next)
    }

    /// Drops what no page, closed tab or site in `pages` and `sites` is any more.
    func prune(pages: [String], sites: [String]) {
        guard let list else { return }
        let next = list.pruned(keeping: pages.map(StartHiddenList.pageKey) + sites.map(StartHiddenList.siteKey))
        if next.hashes.count != list.hashes.count { save(next.hashes.isEmpty ? nil : next) }
    }

    /// Everything shown again, and nothing left on disk (not the salt either).
    func showAll() {
        defaults.removeObject(forKey: Self.defaultsKey)
        list = nil
    }

    private func save(_ next: StartHiddenList?) {
        list = next
        if let next, let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.defaultsKey) } else { defaults.removeObject(forKey: Self.defaultsKey) }
    }
}

/// Which windows show a start page now, for the menu's "Customize Start Page…" to know where to open the popover, and the signal that asks for it.
@MainActor
enum StartPageUI {
    static let customizeRequested = Notification.Name("ChangmunStartPageCustomize")
    /// The test copy's way to see the page of a fresh profile without emptying the one it has.
    static var showsAsEmpty = false
    private static var shown: [ObjectIdentifier: Int] = [:]

    static func appeared(in browser: Browser) { shown[ObjectIdentifier(browser), default: 0] += 1 }

    static func disappeared(from browser: Browser) {
        let id = ObjectIdentifier(browser)
        shown[id] = max(0, (shown[id] ?? 0) - 1)
        if shown[id] == 0 { shown[id] = nil }
    }

    static func isShown(in browser: Browser) -> Bool { shown[ObjectIdentifier(browser)] != nil }

    /// The View menu's item: the popover on the start page of the window in front, or the Settings page when that window shows none.
    static func customize(_ browser: Browser?) {
        // A private window draws no customize button for the popover to sit on (and no setting is changed from there): Settings is opened instead.
        if let browser, !browser.isPrivate, isShown(in: browser) {
            NotificationCenter.default.post(name: customizeRequested, object: browser, userInfo: ["open": true])
        } else {
            StartPageActions.openSettings(.startPage)
        }
    }
}

/// The history the page draws on, read off the main thread: the pages visited last and the sites visited most.
@MainActor
final class StartPageModel: ObservableObject {
    @Published private(set) var recent: [Library.Visit] = []
    @Published private(set) var frequent: [StartFrequentSite] = []
    @Published private(set) var historyCount = 0
    /// Counts the reads that have finished, so that what depends on a read can run after it.
    @Published private(set) var stamp = 0
    private var task: Task<Void, Never>?

    /// Nothing is read in a private window.
    func reload(isPrivate: Bool) {
        task?.cancel()
        guard !isPrivate else {
            recent = []
            frequent = []
            historyCount = 0
            return
        }
        task = Task {
            let read = await Library.shared.inBackground { ($0.history(limit: 40), $0.frequentPages(), $0.counts.history) }
            guard !Task.isCancelled else { return }
            recent = read.0
            frequent = StartFrequentSite.group(read.1)
            historyCount = read.2
            stamp += 1
        }
    }
}

/// The start page: the search field, the sections of the style and order the user chose, and the background. It is what a window or space with no tab
/// shows, and what a start tab shows (`mode` is then `.editCurrent`: what is typed or clicked goes to that tab).
struct StartPageContent: View {
    @ObservedObject var browser: Browser
    @ObservedObject var chat: ChatStore
    var mode: CommandBarMode
    @ObservedObject private var store = StartPageStore.shared
    @ObservedObject private var library = LibraryWatcher.shared
    @ObservedObject private var hidden = StartHiddenItems.shared
    @ObservedObject private var prefs = Preferences.shared
    @StateObject private var model = StartPageModel()
    @State private var typing = false
    @State private var cursor = StartPageCursor()
    @State private var customizing = false
    @State private var expand: StartSection?
    @State private var searchFocus = 0
    @State private var pointerInside = false
    @State private var now = Date()
    @FocusState private var pageFocused: Bool
    @AccessibilityFocusState private var pillFocused: Bool
    @Environment(\.colorScheme) private var scheme

    @MainActor
    init(browser: Browser, chat: ChatStore? = nil, mode: CommandBarMode = .newTab) {
        self.browser = browser
        self.chat = chat ?? ChatStore.shared
        self.mode = mode
    }

    // MARK: Data

    private var settings: StartPageSettings { store.settings }
    private var layout: StartLayout { settings.current }
    private var style: StartStyle { settings.style }
    private var tint: SpaceTint { browser.space.tint }
    private var narrowStyle: Bool { style != .dashboard }
    private func option(_ section: StartSection) -> Int { layout.item(section)?.option ?? 0 }

    /// Everything the sections show, worked out for a page `columns` cards wide.
    private struct PageData {
        var favorites: [Library.Entry] = []
        var cards: [StartContinueCard] = []
        var reading: [ReadingItem] = []
        var unread = 0
        var frequent: [StartFrequentSite] = []
        var chips: [StartAISuggestion] = []
        var contents = StartPageContents()
    }

    private func data(columns: Int) -> PageData {
        let isPrivate = browser.isPrivate
        var data = PageData()
        guard !StartPageUI.showsAsEmpty else {
            data.contents = StartPageContents(isPrivate: isPrivate, aiReady: !isPrivate && chat.availability == .ready)
            return data
        }
        data.favorites = isPrivate ? [] : library.favorites(in: browser.favoritesFolder)
        let closed = browser.closedTabs.map { StartClosedTab(id: $0.id, url: $0.url?.absoluteString, title: $0.title, closedAt: $0.closedAt, space: $0.space) }
        let cardCount = narrowStyle ? 3 : columns
        data.cards = StartPageData.continueCards(closed: closed, history: model.recent, open: browser.tabs.compactMap { $0.url?.absoluteString }, space: browser.spaceID,
                                                 closedOnly: option(.continueViewing) == 1, limit: cardCount, isHidden: { hidden.isHidden(page: $0) }, isPrivate: isPrivate)
        let reading = StartPageData.readingItems(library.readingList, all: option(.readingList) == 1, isPrivate: isPrivate)
        data.reading = reading.shown
        data.unread = reading.unread
        data.frequent = StartPageData.frequentSites(model.frequent, eight: option(.frequent) == 1, isHidden: { hidden.isHidden(site: $0) }, isPrivate: isPrivate)
        let aiReady = !isPrivate && chat.availability == .ready
        let tabs = browser.spaceTabs.count
        data.chips = aiReady ? StartPageAI.suggestions(tabs: tabs, limit: style == .aiFirst ? 4 : 3) : []
        data.contents = StartPageContents(isPrivate: isPrivate, aiReady: aiReady, favorites: data.favorites.count, continueCards: data.cards.count,
                                          reading: data.reading.count, frequent: data.frequent.count,
                                          hasData: !data.favorites.isEmpty || model.historyCount > 0 || !library.readingList.isEmpty || !closed.isEmpty)
        return data
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            let columns = geo.size.width >= 900 ? 4 : 3
            let page = data(columns: columns)
            let pageMode = StartPageRules.mode(layout: layout, style: style, contents: page.contents)
            let shapes = cursorShapes(pageMode, page, columns: columns)
            let onImage = settings.background.kind == .image && StartPageFiles.imageURL(settings.background.imageFile).map { FileManager.default.fileExists(atPath: $0.path) } == true
            ZStack(alignment: .bottomTrailing) {
                StartBackgroundView(background: browser.isPrivate ? StartBackground(kind: .plain) : settings.background, tint: tint)
                ScrollViewReader { proxy in
                    ScrollView {
                        content(pageMode, page, columns: columns, height: geo.size.height)
                            .frame(minHeight: geo.size.height)
                            .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: cursor) { _, new in
                        if let stop = new.stop { withAnimation(Motion.quick) { proxy.scrollTo(Self.scrollID(stop), anchor: nil) } }
                    }
                }
                if !browser.isPrivate { pill(height: geo.size.height, contents: page.contents, shown: pointerInside || cursor.stop?.part == .customize || customizing || !page.contents.hasData) }
            }
            .environment(\.startOnImage, onImage && !browser.isPrivate)
            .focusable()
            .focused($pageFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in handle(press, shapes: shapes, page: page) }
            .onContinuousHover { phase in
                switch phase {
                case .active: if !pointerInside { pointerInside = true }
                case .ended: pointerInside = false
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(browser.isPrivate ? String(localized: "Private Window") : String(localized: "Start Page"))
        }
        .onAppear {
            StartPageUI.appeared(in: browser)
            chat.refreshAvailability()
            model.reload(isPrivate: browser.isPrivate)
            now = Date()
            DispatchQueue.main.async { searchFocus += 1 }
        }
        .onDisappear { StartPageUI.disappeared(from: browser) }
        .onChange(of: model.stamp) { pruneHidden() }
        .onChange(of: browser.tabs.count) { model.reload(isPrivate: browser.isPrivate); now = Date() }
        .onChange(of: browser.addressFocusRequest) { cursor = StartPageCursor(); searchFocus += 1 }
        .onReceive(NotificationCenter.default.publisher(for: Library.didChange)) { _ in model.reload(isPrivate: browser.isPrivate) }
        .onReceive(NotificationCenter.default.publisher(for: StartPageUI.customizeRequested)) { note in
            guard note.object as? Browser === browser else { return }
            expand = (note.userInfo?["expand"] as? String).flatMap(StartSection.init(rawValue:))
            customizing = note.userInfo?["open"] as? Bool ?? true
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ pageMode: StartPageMode, _ page: PageData, columns: Int, height: CGFloat) -> some View {
        let centered = style != .dashboard || { if case .sections(let list) = pageMode { return !list.contains { $0 != .favorites && $0 != .aiSuggestions } } else { return true } }()
        VStack(spacing: 0) {
            if centered { Spacer(minLength: 40) } else { Color.clear.frame(height: 72) }
            switch pageMode {
            case .privateNotice:
                StartPrivateView(search: searchBox())
            case .firstRun:
                StartFirstRunView(browser: browser, aiReady: page.contents.aiReady, search: searchBox())
            case .sections(let list):
                sections(list, page, columns: columns)
            }
            Spacer(minLength: 90)
            if centered, style == .quiet || pageMode == .privateNotice || pageMode == .firstRun { hints }
        }
        .opacity(1)
    }

    private func searchBox(compact: Bool = false) -> AnyView {
        AnyView(StartSearchBox(browser: browser, chat: chat, mode: mode, compact: compact, typing: $typing, focusRequest: searchFocus) { backwards in
            cursor = cursor.tab(lastShapes, backwards: backwards)
            if cursor.stop != nil { pageFocused = true } else { searchFocus += 1 }
        })
    }

    @State private var lastShapes: [StartPageCursor.Shape] = []

    private var hints: some View {
        HStack(spacing: 6) {
            Text("New Tab").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.faint)
            Keycap("⌘T")
            if !browser.isPrivate {
                Text("AI").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.faint).padding(.leading, 8)
                Keycap("⌘E")
            }
        }
        .padding(.bottom, 28)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func sections(_ list: [StartSection], _ page: PageData, columns: Int) -> some View {
        let wideColumn: CGFloat = 984
        VStack(spacing: 0) {
            if style == .aiFirst, page.contents.aiReady { aiHero(page, showCards: list.contains(.aiSuggestions)) }
            if style == .quiet {
                HStack(spacing: 6) {
                    Circle().fill(tint.color).frame(width: 6, height: 6)
                    Text(verbatim: browser.space.name).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
                .padding(.bottom, 14)
                .opacity(browser.isPrivate ? 0 : 1)
            }
            VStack(spacing: 0) {
                searchBox(compact: style == .aiFirst && page.contents.aiReady).frame(maxWidth: 620)
                if style == .dashboard, list.contains(.aiSuggestions), !browser.showChat, !page.chips.isEmpty, !typing {
                    HStack(spacing: 8) {
                        ForEach(Array(page.chips.enumerated()), id: \.element.id) { index, chip in
                            StartAIChip(suggestion: chip, focused: isFocused(.aiSuggestions, index)) { ask(chip.prompt) }
                        }
                    }
                    .padding(.top, 14)
                    .id(Self.scrollID(.init(part: .section(.aiSuggestions), item: 0)))
                }
            }
            .zIndex(10)
            let rows = StartPageArrangement.rows(list.filter { $0 != .aiSuggestions || style != .dashboard }, style: style)
            VStack(spacing: style == .dashboard ? 40 : 34) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    switch row {
                    case .full(let section): sectionView(section, page, columns: columns, flow: .full)
                    case .pair(let a, let b):
                        HStack(alignment: .top, spacing: 48) {
                            sectionView(a, page, columns: columns, flow: .half)
                            sectionView(b, page, columns: columns, flow: .half)
                        }
                    case .wide(let section): sectionView(section, page, columns: columns, flow: .wide)
                    }
                }
            }
            .frame(maxWidth: style == .dashboard ? wideColumn : 620)
            .padding(.top, style == .dashboard ? 40 : 30)
            .opacity(typing ? 0.22 : 1)
            .allowsHitTesting(!typing)
            .animation(Motion.quick, value: typing)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: Sections

    private enum Flow { case full, half, wide }

    @ViewBuilder
    private func sectionView(_ section: StartSection, _ page: PageData, columns: Int, flow: Flow) -> some View {
        switch section {
        case .aiSuggestions:
            EmptyView()
        case .favorites: favoritesView(page)
        case .continueViewing: continueView(page, columns: columns)
        case .readingList: readingView(page, flow: flow)
        case .frequent: frequentView(page, flow: flow)
        }
    }

    private func favoritesView(_ page: PageData) -> some View {
        let two = option(.favorites) == 1
        let size: CGFloat = style == .dashboard ? (two ? 74 : 58) : style == .quiet ? (two ? 74 : 66) : (two ? 52 : 46)
        let pitch: CGFloat = style == .aiFirst ? 80 : size + (two ? 31 : 26)
        let rows = StartPageArrangement.favoriteRows(count: page.favorites.count, twoRows: two)
        return VStack(alignment: .leading, spacing: 12) {
            if style == .dashboard {
                StartHeading(title: String(localized: "Favorites"), linkTitle: String(localized: "Edit")) { expand = .favorites; customizing = true }
            }
            VStack(alignment: style == .dashboard ? .leading : .center, spacing: 10) {
                if page.favorites.isEmpty {
                    HStack(spacing: 20) { ForEach(0..<5, id: \.self) { _ in StartEmptyFavorite(size: size) } }
                    Text("Drag the sites you visit most to the favorites in the sidebar and they appear here as tiles.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, range in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(range, id: \.self) { index in
                                StartFavoriteTile(entry: page.favorites[index], size: size, width: pitch, focused: isFocused(.favorites, index)) { newTab in openFavorite(page.favorites[index], inNewTab: newTab) }
                                    .id(Self.scrollID(.init(part: .section(.favorites), item: index)))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: style == .dashboard ? .leading : .center)
        }
    }

    @ViewBuilder
    private func continueView(_ page: PageData, columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StartHeading(title: String(localized: "Continue Viewing"), linkTitle: String(localized: "Show History")) { StartPageActions.showHistory() }
            if style == .dashboard {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(page.cards.enumerated()), id: \.element.id) { index, card in
                        StartContinueCardView(card: card, tint: tint, focused: isFocused(.continueViewing, index), now: now,
                                              open: { newTab in openCard(card, inNewTab: newTab) }, hide: { if !browser.isPrivate { hidden.hide(page: card.url) } })
                            .id(Self.scrollID(.init(part: .section(.continueViewing), item: index)))
                    }
                    ForEach(page.cards.count..<max(page.cards.count, columns), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(page.cards.enumerated()), id: \.element.id) { index, card in
                        StartContinueRowView(card: card, tint: tint, focused: isFocused(.continueViewing, index), now: now,
                                             open: { newTab in openCard(card, inNewTab: newTab) }, hide: { if !browser.isPrivate { hidden.hide(page: card.url) } })
                            .id(Self.scrollID(.init(part: .section(.continueViewing), item: index)))
                    }
                }
                .startGroupPlate()
            }
        }
    }

    @ViewBuilder
    private func readingView(_ page: PageData, flow: Flow) -> some View {
        let all = option(.readingList) == 1
        VStack(alignment: .leading, spacing: 8) {
            StartHeading(title: String(localized: "Reading List"), detail: page.unread > 0 ? String(localized: "\(page.unread) unread") : nil,
                         linkTitle: all ? String(localized: "Unread Only") : String(localized: "Show All")) { store.setOption(.readingList, all ? 0 : 1) }
            rowsFlow(flow) {
                ForEach(Array(page.reading.enumerated()), id: \.element.id) { index, item in
                    StartReadingRow(item: item, focused: isFocused(.readingList, index), now: now) { newTab in browser.openReadingItem(item, inNewTab: newTab) }
                        .id(Self.scrollID(.init(part: .section(.readingList), item: index)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func frequentView(_ page: PageData, flow: Flow) -> some View {
        let more = option(.frequent) == 1
        let most = page.frequent.map(\.visits).max() ?? 1
        VStack(alignment: .leading, spacing: 8) {
            StartHeading(title: String(localized: "Frequently Visited"), linkTitle: more ? String(localized: "Show Fewer") : String(localized: "Show More")) { store.setOption(.frequent, more ? 0 : 1) }
            rowsFlow(flow) {
                ForEach(Array(page.frequent.enumerated()), id: \.element.id) { index, site in
                    StartFrequentRow(site: site, most: most, focused: isFocused(.frequent, index),
                                     open: { newTab in openSite(site, inNewTab: newTab) }, hide: { if !browser.isPrivate { hidden.hide(site: site.host) } })
                        .id(Self.scrollID(.init(part: .section(.frequent), item: index)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Rows in one column, or (a half-width section that has the page to itself) two.
    @ViewBuilder
    private func rowsFlow<Rows: View>(_ flow: Flow, @ViewBuilder _ rows: () -> Rows) -> some View {
        if flow == .wide {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 48, alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 0) { rows() }.startGroupPlate()
        } else {
            VStack(spacing: 0) { rows() }.startGroupPlate()
        }
    }

    // MARK: The AI's box (AI-first)

    @ViewBuilder
    private func aiHero(_ page: PageData, showCards: Bool) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "sparkle").font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(LinearGradient(colors: [tint.color.opacity(0.95), tint.color.opacity(0.65)], startPoint: .top, endPoint: .bottom)))
                .shadow(color: tint.color.opacity(0.35), radius: 12, y: 4)
                .decorative()
            Text("How can I help?").font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.primary).padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            Text("I can read your open tabs, compare them, and click through to finish the job.")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary).padding(.top, 6)
            StartAIPrompt(browser: browser, chat: chat, tint: tint, ask: ask)
                .frame(maxWidth: 680).padding(.top, 28)
            if showCards, !page.chips.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(page.chips.enumerated()), id: \.element.id) { index, chip in
                        StartAICard(suggestion: chip, tint: tint, focused: isFocused(.aiSuggestions, index)) { ask(chip.prompt) }
                    }
                }
                .frame(maxWidth: 680).padding(.top, 14)
            }
            Spacer().frame(height: 30)
        }
        .opacity(typing ? 0.22 : 1)
        .allowsHitTesting(!typing)
    }

    // MARK: The Customize button

    private func pill(height: CGFloat, contents: StartPageContents, shown: Bool) -> some View {
        Button { expand = nil; customizing = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                Text("Customize").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 13).frame(height: 30)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .overlay { if cursor.stop?.part == .customize { Capsule().strokeBorder(Color.accentColor, lineWidth: 2) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Customize Start Page"))
        .accessibilityHint(String(localized: "Opens the style, sections and background of this page"))
        .accessibilityFocused($pillFocused)
        .popover(isPresented: $customizing, arrowEdge: .bottom) {
            StartPageCustomizeView(browser: browser, expand: expand, pageHeight: height, contents: contents)
        }
        .padding(16)
        // Hidden, it is still there for a screen reader (a view with no opacity at all is left out of what it reads).
        .opacity(shown || NSWorkspace.shared.isVoiceOverEnabled ? 1 : 0.01)
        .allowsHitTesting(shown)
        .animation(Motion.quick, value: shown)
        .onChange(of: customizing) { _, now in
            if !now {
                cursor = StartPageCursor(stop: .init(part: .customize, item: 0))
                pillFocused = true
                pageFocused = true
            }
        }
    }

    // MARK: Hidden items

    /// What the user took off the page is kept only while a page, closed tab or site it names is still there to be shown.
    private func pruneHidden() {
        guard !browser.isPrivate else { return }
        let closed = Browser.all.flatMap(\.closedTabs).compactMap { $0.url?.absoluteString }
        hidden.prune(pages: model.recent.map(\.url) + closed, sites: model.frequent.map(\.host))
    }

    // MARK: Opening

    private func openFavorite(_ entry: Library.Entry, inNewTab: Bool) {
        browser.openBookmark(entry.url, key: Browser.bookmarkKey(url: entry.url, folder: browser.favoritesFolder), inNewTab: inNewTab)
    }

    private func openCard(_ card: StartContinueCard, inNewTab: Bool) {
        if case .closedTab(let id) = card.kind, browser.reopenClosedTab(id: id) { return }
        browser.open(card.url, in: inNewTab ? .newTab : mode)
    }

    private func openSite(_ site: StartFrequentSite, inNewTab: Bool) {
        browser.open(site.url, in: inNewTab ? .newTab : mode)
    }

    private func ask(_ text: String) {
        StartPageActions.ask(text, browser: browser, chat: chat)
    }

    // MARK: Keyboard

    private static func scrollID(_ stop: StartPageCursor.Stop) -> String { "\(stop.part)-\(stop.item)" }

    private func isFocused(_ section: StartSection, _ index: Int) -> Bool {
        cursor.stop == StartPageCursor.Stop(part: .section(section), item: index)
    }

    /// What each part of the page holds, for the keyboard.
    private func cursorShapes(_ pageMode: StartPageMode, _ page: PageData, columns: Int) -> [StartPageCursor.Shape] {
        var shapes: [StartPageCursor.Shape] = []
        if case .sections(let list) = pageMode {
            for section in list {
                switch section {
                case .aiSuggestions:
                    if style == .dashboard, browser.showChat || typing { continue }
                    shapes.append(.init(part: .section(.aiSuggestions), count: page.chips.count, columns: style == .aiFirst ? 2 : max(1, page.chips.count)))
                case .favorites:
                    let first = StartPageArrangement.favoriteRows(count: page.favorites.count, twoRows: option(.favorites) == 1).first?.count ?? 1
                    shapes.append(.init(part: .section(.favorites), count: page.favorites.count, columns: max(1, first)))
                case .continueViewing:
                    shapes.append(.init(part: .section(.continueViewing), count: page.cards.count, columns: style == .dashboard ? columns : 1))
                case .readingList:
                    shapes.append(.init(part: .section(.readingList), count: page.reading.count, columns: 1))
                case .frequent:
                    shapes.append(.init(part: .section(.frequent), count: page.frequent.count, columns: 1))
                }
            }
        }
        if !browser.isPrivate { shapes.append(.init(part: .customize, count: 1, columns: 1)) }
        DispatchQueue.main.async { if lastShapes != shapes { lastShapes = shapes } }
        return shapes
    }

    private func handle(_ press: KeyPress, shapes: [StartPageCursor.Shape], page: PageData) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .tab:
            guard !command else { return .ignored }
            cursor = cursor.tab(shapes, backwards: press.modifiers.contains(.shift))
            if cursor.stop != nil { pageFocused = true } else { searchFocus += 1 }
            return .handled
        case .escape:
            guard cursor.stop != nil else { return .ignored }
            cursor = StartPageCursor()
            searchFocus += 1
            return .handled
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            guard !press.modifiers.contains(.option) else { return .ignored }
            let arrow: StartPageCursor.Arrow = press.key == .leftArrow ? .left : press.key == .rightArrow ? .right : press.key == .upArrow ? .up : .down
            let wasInSearch = cursor.stop == nil
            if wasInSearch, arrow != .down { return .ignored }
            cursor = cursor.move(arrow, shapes)
            if cursor.stop != nil { pageFocused = true } else { searchFocus += 1 }
            return .handled
        case .return, .space:
            guard let stop = cursor.stop else { return .ignored }
            activate(stop, page: page, inNewTab: command)
            return .handled
        default:
            return .ignored
        }
    }

    private func activate(_ stop: StartPageCursor.Stop, page: PageData, inNewTab: Bool) {
        switch stop.part {
        case .customize:
            expand = nil
            customizing = true
        case .section(.aiSuggestions):
            if page.chips.indices.contains(stop.item) { ask(page.chips[stop.item].prompt) }
        case .section(.favorites):
            if page.favorites.indices.contains(stop.item) { openFavorite(page.favorites[stop.item], inNewTab: inNewTab) }
        case .section(.continueViewing):
            if page.cards.indices.contains(stop.item) { openCard(page.cards[stop.item], inNewTab: inNewTab) }
        case .section(.readingList):
            if page.reading.indices.contains(stop.item) { browser.openReadingItem(page.reading[stop.item], inNewTab: inNewTab) }
        case .section(.frequent):
            if page.frequent.indices.contains(stop.item) { openSite(page.frequent[stop.item], inNewTab: inNewTab) }
        }
    }
}

/// The AI-first page's box: what is typed goes to the AI as the panel's own box sends it (Return sends, ⌥Return breaks the line).
struct StartAIPrompt: View {
    @ObservedObject var browser: Browser
    @ObservedObject var chat: ChatStore
    let tint: SpaceTint
    let ask: (String) -> Void
    @ObservedObject private var prefs = Preferences.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("", text: $draft, prompt: Text("Sum up a page, look into a site, or hand it a task").foregroundStyle(Theme.dim), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.primary)
                .lineLimit(1...5)
                .focused($focused)
                .frame(minHeight: 40, alignment: .topLeading)
                .accessibilityLabel(String(localized: "Ask the AI"))
                .onSubmit(send)
            HStack(spacing: 8) {
                let tabs = browser.spaceTabs.count
                if tabs > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "square.on.square").font(.system(size: 10, weight: .medium))
                        Text(tabs == 1 ? String(localized: "1 open tab") : String(localized: "\(tabs) open tabs")).font(.system(size: 11.5))
                    }
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Capsule().fill(Theme.field))
                }
                Spacer()
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.card)
                        .frame(width: 30, height: 30).background(Circle().fill(Theme.primary))
                }
                .buttonStyle(.plain)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                .accessibilityLabel(String(localized: "Send"))
            }
        }
        .padding(14)
        .startPlate(radius: 14, fill: Theme.card, raised: true)
        .shadow(color: tint.color.opacity(0.18), radius: 16, y: 6)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        ask(text)
    }
}
