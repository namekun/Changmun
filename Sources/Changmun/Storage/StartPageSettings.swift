import Foundation

/// Stored settings are read leniently: a missing key, a value of another type or a name a version of the app doesn't know (an older or newer one wrote
/// it, or the file is damaged) takes that one value back to its default, and does not throw away everything else (nor the picture, with the settings).
private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// An item of a stored layout that may be one this version doesn't know: it then reads as nil and is left out.
private struct LenientItem: Decodable {
    let item: StartItem?
    init(from decoder: Decoder) throws { item = try? StartItem(from: decoder) }
}

/// How the start page looks: the three styles, what each shows and in which order, the background, and where a new tab opens.
/// All of it is plain data with pure changes, so the page, its popover and the settings page share one model and it can be tested alone.

enum StartStyle: String, Codable, CaseIterable, Sendable {
    case dashboard, quiet, aiFirst
}

/// The parts the page can show besides its search field, which is always first.
enum StartSection: String, Codable, CaseIterable, Sendable {
    case aiSuggestions, favorites, continueViewing, readingList, frequent
}

/// What a section's `option` means (0 is the default of each):
/// favorites: 0 one row, 1 two rows · continueViewing: 0 closed tabs and recent pages, 1 closed tabs only ·
/// readingList: 0 unread only, 1 all · frequent: 0 four sites, 1 eight · aiSuggestions: no option.
struct StartItem: Codable, Equatable, Sendable {
    var section: StartSection
    var enabled: Bool
    var option: Int = 0
}

extension StartLayout {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = container.lenient(.items, [LenientItem]()).compactMap(\.item)
    }
}

extension StartItem {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        section = try container.decode(StartSection.self, forKey: .section)
        enabled = container.lenient(.enabled, false)
        option = container.lenient(.option, 0)
    }
}

/// The sections of one style in their order, each on or off.
struct StartLayout: Codable, Equatable, Sendable {
    var items: [StartItem]

    /// Every section exactly once: unknown or repeated ones from an older or damaged file dropped, missing ones added off at the end.
    func normalized() -> StartLayout {
        var seen = Set<StartSection>()
        var kept = items.filter { seen.insert($0.section).inserted }
        for section in StartSection.allCases where !seen.contains(section) { kept.append(StartItem(section: section, enabled: false)) }
        return StartLayout(items: kept)
    }

    func item(_ section: StartSection) -> StartItem? { items.first { $0.section == section } }

    func toggled(_ section: StartSection) -> StartLayout {
        var copy = self
        if let index = copy.items.firstIndex(where: { $0.section == section }) { copy.items[index].enabled.toggle() }
        return copy
    }

    func setting(_ section: StartSection, option: Int) -> StartLayout {
        var copy = self
        if let index = copy.items.firstIndex(where: { $0.section == section }) { copy.items[index].option = max(0, option) }
        return copy
    }

    /// `section` moved to `index` in the list (clamped).
    func moving(_ section: StartSection, to index: Int) -> StartLayout {
        guard let from = items.firstIndex(where: { $0.section == section }) else { return self }
        var copy = self
        let item = copy.items.remove(at: from)
        copy.items.insert(item, at: min(max(index, 0), copy.items.count))
        return copy
    }

    /// One step up (−1) or down (+1), as ⌥↑ and ⌥↓ do it.
    func moving(_ section: StartSection, by offset: Int) -> StartLayout {
        guard let from = items.firstIndex(where: { $0.section == section }) else { return self }
        return moving(section, to: from + offset)
    }

    /// The sections that are on, in order.
    var shown: [StartItem] { items.filter(\.enabled) }
}

enum StartBackgroundKind: String, Codable, CaseIterable, Sendable {
    /// The space's colour as a soft glow (the default), a plain page, one of the swatches, the user's picture, or nothing at all.
    case spaceGlow, plain, color, image, none
}

struct StartBackground: Codable, Equatable, Sendable {
    /// The swatches the page offers; `custom` uses `customHex`.
    static let swatches = ["slate", "blue", "coral", "green", "purple", "amber", "teal", "pink"]

    var kind: StartBackgroundKind = .spaceGlow
    var colorID: String = "slate"
    var customHex: String?
    /// The file name of the picture's copy in the app's folder (see `StartPageFiles`), never the original's path.
    var imageFile: String?
    /// 0…1: how much the picture is blurred, and how much it is dimmed (dark mode) or paled (light mode) before the page is drawn over it.
    var blur: Double = 0
    var dim: Double = 0.4

    func clamped() -> StartBackground {
        var copy = self
        copy.blur = min(max(blur, 0), 1)
        copy.dim = min(max(dim, 0), 1)
        if kind == .image, imageFile == nil { copy.kind = .spaceGlow }
        return copy
    }
}

extension StartBackground {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        kind = container.lenient(.kind, kind)
        colorID = container.lenient(.colorID, colorID)
        customHex = container.lenient(.customHex, customHex)
        imageFile = container.lenient(.imageFile, imageFile)
        blur = container.lenient(.blur, blur)
        dim = container.lenient(.dim, dim)
    }
}

/// Where ⌘T and a new tab go.
enum NewTabOpens: String, Codable, CaseIterable, Sendable {
    case startPage, commandBar, blank, address
}

struct StartPageSettings: Codable, Equatable, Sendable {
    var style: StartStyle = .dashboard
    /// What each style shows is remembered per style.
    var dashboard: StartLayout = Self.defaultLayout(.dashboard)
    var quiet: StartLayout = Self.defaultLayout(.quiet)
    var aiFirst: StartLayout = Self.defaultLayout(.aiFirst)
    var background = StartBackground()
    var newTab: NewTabOpens = .startPage
    /// The custom address for `newTab == .address`, as typed.
    var address: String = ""

    static let `default` = StartPageSettings()

    static func defaultLayout(_ style: StartStyle) -> StartLayout {
        func layout(_ on: Set<StartSection>, order: [StartSection]) -> StartLayout {
            StartLayout(items: order.map { StartItem(section: $0, enabled: on.contains($0)) })
        }
        switch style {
        case .dashboard:
            return layout([.aiSuggestions, .favorites, .continueViewing, .readingList],
                          order: [.aiSuggestions, .favorites, .continueViewing, .readingList, .frequent])
        case .quiet:
            return layout([.favorites], order: [.favorites, .continueViewing, .readingList, .frequent, .aiSuggestions])
        case .aiFirst:
            return layout([.aiSuggestions, .favorites], order: [.aiSuggestions, .favorites, .continueViewing, .readingList, .frequent])
        }
    }

    func layout(_ style: StartStyle) -> StartLayout {
        switch style {
        case .dashboard: dashboard
        case .quiet: quiet
        case .aiFirst: aiFirst
        }
    }

    func with(layout: StartLayout, for style: StartStyle) -> StartPageSettings {
        var copy = self
        switch style {
        case .dashboard: copy.dashboard = layout
        case .quiet: copy.quiet = layout
        case .aiFirst: copy.aiFirst = layout
        }
        return copy
    }

    /// The layout of the style in use.
    var current: StartLayout { layout(style) }

    /// What a damaged or older file may hold, made whole again.
    func normalized() -> StartPageSettings {
        var copy = self
        copy.dashboard = dashboard.normalized()
        copy.quiet = quiet.normalized()
        copy.aiFirst = aiFirst.normalized()
        copy.background = background.clamped()
        return copy
    }
}

extension StartPageSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        style = container.lenient(.style, style)
        dashboard = container.lenient(.dashboard, dashboard)
        quiet = container.lenient(.quiet, quiet)
        aiFirst = container.lenient(.aiFirst, aiFirst)
        background = container.lenient(.background, background)
        newTab = container.lenient(.newTab, newTab)
        address = container.lenient(.address, address)
    }
}

/// What the custom address of "New tabs open" comes to.
enum StartAddressCheck: Equatable, Sendable {
    case empty
    case invalid
    /// A page that isn't encrypted: allowed, with a note.
    case insecure(URL)
    case ok(URL)

    var url: URL? {
        switch self {
        case .ok(let url), .insecure(let url): url
        case .empty, .invalid: nil
        }
    }

    static let maxLength = 2048

    /// A bare host gets https; only http and https, with a host and no spaces or user name and password, and of a sensible length, are addresses.
    /// "://" means a scheme only before any "/", "?" or "#": `example.com/?u=http://x` is a bare host with a query.
    static func check(_ typed: String) -> StartAddressCheck {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        guard text.count <= maxLength, !text.contains(where: \.isWhitespace) else { return .invalid }
        let hasScheme = text.range(of: "://").map { !text[..<$0.lowerBound].contains { "/?#".contains($0) } } ?? false
        let withScheme = hasScheme ? text : "https://" + text
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil,
              let host = url.host(), !host.isEmpty, host.contains(".") || host == "localhost" else { return .invalid }
        return scheme == "https" ? .ok(url) : .insecure(url)
    }
}

/// Where the user's background picture lives: one copy, shrunk, in the app's own folder.
enum StartPageFiles {
    /// In the user's data folder (see `DataFolder`): a test copy or the test runner has a folder of its own, never the app's.
    static func folder() -> URL {
        Library.folder.appendingPathComponent("StartPage", isDirectory: true)
    }

    /// The copy of the picture for a stored file name; nil for names that aren't plain file names.
    static func imageURL(_ file: String?, in folder: URL = folder()) -> URL? {
        guard let file, !file.isEmpty, !file.contains("/"), !file.hasPrefix(".") else { return nil }
        return folder.appendingPathComponent(file)
    }
}
