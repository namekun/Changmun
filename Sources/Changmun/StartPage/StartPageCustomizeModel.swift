import AppKit
import Combine
import SwiftUI

extension StartStyle {
    var title: String {
        switch self {
        case .dashboard: String(localized: "Dashboard")
        case .quiet: String(localized: "Quiet")
        case .aiFirst: String(localized: "AI First")
        }
    }

    var detail: String {
        switch self {
        case .dashboard: String(localized: "Continue viewing, the reading list and frequent sites at a glance")
        case .quiet: String(localized: "Just the search field and your favorites, in the middle")
        case .aiFirst: String(localized: "A big prompt box comes first")
        }
    }
}

extension StartSection {
    var title: String {
        switch self {
        case .aiSuggestions: String(localized: "AI Suggestions")
        case .favorites: String(localized: "Favorites")
        case .continueViewing: String(localized: "Continue Viewing")
        case .readingList: String(localized: "Reading List")
        case .frequent: String(localized: "Frequently Visited")
        }
    }

    var symbol: String {
        switch self {
        case .aiSuggestions: "sparkle"
        case .favorites: "star"
        case .continueViewing: "arrow.uturn.backward"
        case .readingList: "book"
        case .frequent: "chart.bar"
        }
    }

    /// What a section's option is called and what it can be (the first is the default); nil for a section without one.
    var optionChoices: (title: String, choices: [String])? {
        switch self {
        case .aiSuggestions: nil
        case .favorites: (String(localized: "Rows"), [String(localized: "One row"), String(localized: "Two rows")])
        case .continueViewing: (String(localized: "Show"), [String(localized: "Closed tabs and recent pages"), String(localized: "Closed tabs only")])
        case .readingList: (String(localized: "Show"), [String(localized: "Unread only"), String(localized: "All")])
        case .frequent: (String(localized: "Sites"), [String(localized: "4 sites"), String(localized: "8 sites")])
        }
    }

    var optionCount: Int { optionChoices?.choices.count ?? 0 }
}

extension NewTabOpens {
    var title: String {
        switch self {
        case .startPage: String(localized: "Start Page")
        case .commandBar: String(localized: "Command Bar")
        case .blank: String(localized: "Blank Page")
        case .address: String(localized: "Address")
        }
    }

    var detail: String? {
        switch self {
        case .startPage: String(localized: "⌘T opens a new tab with the start page. The search field is ready to type in.")
        case .commandBar: String(localized: "⌘T opens the command bar over a blank page, as before.")
        case .blank: String(localized: "⌘T opens an empty page.")
        case .address: nil
        }
    }
}

/// What the Customize popover and the Settings page do with the store: every change applies at once. A plain object with its dependencies handed
/// in (the Undo toast, the picture import, the announcements), so that it can be tested without a window.
@MainActor
final class StartPageCustomizeModel: ObservableObject {
    enum ImageState: Equatable {
        case idle
        case working
        case failed
    }

    /// The height of a row in the list of sections, which a drag counts in.
    nonisolated static let rowHeight: CGFloat = 38

    let store: StartPageStore
    private let offerUndo: (String, @escaping () -> Void) -> Void
    private let importImage: (URL) async -> Bool
    private let announce: (String) -> Void
    private let hidden: StartHiddenItems
    private var watch: AnyCancellable?

    /// The section whose options are open: one at a time.
    @Published var expanded: StartSection?
    /// The row being dragged.
    @Published var dragging: StartSection?
    /// The address as typed in the field, and what it came to when last checked (nil: not checked since it was changed).
    @Published var address: String
    @Published private(set) var addressState: StartAddressCheck?
    @Published private(set) var imageState = ImageState.idle

    init(store: StartPageStore? = nil, expanded: StartSection? = nil,
         offerUndo: @escaping (String, @escaping () -> Void) -> Void = { _, _ in },
         importImage: ((URL) async -> Bool)? = nil, announce: ((String) -> Void)? = nil, hidden: StartHiddenItems? = nil) {
        self.hidden = hidden ?? StartHiddenItems.shared
        let store = store ?? StartPageStore.shared
        self.store = store
        self.expanded = expanded
        self.offerUndo = offerUndo
        self.importImage = importImage ?? { await store.chooseImage(from: $0) }
        self.announce = announce ?? { Announcer.announce($0) }
        address = store.settings.address
        if store.settings.newTab == .address, !store.settings.address.isEmpty { addressState = StartAddressCheck.check(store.settings.address) }
        watch = store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var settings: StartPageSettings { store.settings }
    var items: [StartItem] { store.settings.current.items }

    // MARK: Style and sections

    func setStyle(_ style: StartStyle) {
        guard style != settings.style else { return }
        expanded = nil
        store.setStyle(style)
        announce(String(localized: "\(style.title), selected"))
    }

    func toggle(_ section: StartSection) {
        store.toggle(section)
        let on = settings.current.item(section)?.enabled == true
        if !on, expanded == section { expanded = nil }
        announce("\(section.title), \(Accessibility.onOffValue(on))")
    }

    func toggleOptions(_ section: StartSection) {
        guard section.optionChoices != nil else { return }
        expanded = expanded == section ? nil : section
    }

    func option(_ section: StartSection) -> Int { settings.current.item(section)?.option ?? 0 }

    func setOption(_ section: StartSection, _ option: Int) {
        guard section.optionChoices != nil, (0..<section.optionCount).contains(option) else { return }
        store.setOption(section, option)
    }

    /// The next choice of a section's option, round to the first: for a control that steps through them.
    func cycleOption(_ section: StartSection) {
        guard section.optionCount > 0 else { return }
        setOption(section, (option(section) + 1) % section.optionCount)
    }

    /// 1-based place in the list, and how long the list is, as VoiceOver says it ("4 of 5").
    func position(of section: StartSection) -> Int { (items.firstIndex { $0.section == section } ?? 0) + 1 }

    func reorderLabel(_ section: StartSection) -> String { String(localized: "Reorder \(section.title)") }

    func reorderValue(_ section: StartSection) -> String { String(localized: "\(position(of: section)) of \(items.count)") }

    /// One step up (−1) or down (+1), by ⌥↑ and ⌥↓ or the rotor's actions: the new place is announced.
    func move(_ section: StartSection, by offset: Int) {
        let before = position(of: section)
        store.move(section, by: offset)
        let after = position(of: section)
        if after != before { announce("\(section.title), \(reorderValue(section))") }
    }

    /// What ⌥↑ and ⌥↓ mean for the handle of a row: a step up or down, and nothing for the arrows without ⌥.
    static func step(up: Bool, option: Bool) -> Int? { option ? (up ? -1 : 1) : nil }

    /// Where a row dragged from `start` by `translation` points down belongs: the place it is over, kept in the list.
    nonisolated static func dragIndex(start: Int, translation: CGFloat, rowHeight: CGFloat = 38, count: Int) -> Int {
        min(max(start + Int((translation / rowHeight).rounded()), 0), max(count - 1, 0))
    }

    func beginDrag(_ section: StartSection) {
        dragging = section
        expanded = nil
    }

    /// The row is over place `index`: the list (and the page behind it) rearranges at once.
    func drag(_ section: StartSection, over index: Int) {
        guard position(of: section) - 1 != index else { return }
        store.move(section, to: index)
    }

    func endDrag(_ section: StartSection) {
        dragging = nil
        announce("\(section.title), \(reorderValue(section))")
    }

    // MARK: Background

    /// A tile of the background row. The picture's tile asks for a picture first when there is none (the caller opens the panel when this answers true).
    @discardableResult
    func selectBackground(_ kind: StartBackgroundKind) -> Bool {
        if kind == .image, settings.background.imageFile == nil { return true }
        var background = settings.background
        background.kind = kind
        store.setBackground(background)
        return false
    }

    func setColor(_ id: String) {
        var background = settings.background
        background.kind = .color
        background.colorID = id
        store.setBackground(background)
    }

    func setCustomColor(hex: String) {
        guard StartSwatch.parseHex(hex) != nil else { return }
        var background = settings.background
        background.kind = .color
        background.colorID = "custom"
        background.customHex = hex
        store.setBackground(background)
    }

    func setBlur(_ value: Double) {
        var background = settings.background
        background.blur = value
        store.setBackground(background)
    }

    func setDim(_ value: Double) {
        var background = settings.background
        background.dim = value
        store.setBackground(background)
    }

    /// Takes a picture the user chose: shows that it works on it, and on success makes the background that picture. A picture that can't be used
    /// leaves the background as it was and says so.
    func chooseImage(_ url: URL) async {
        imageState = .working
        let done = await importImage(url)
        guard done else {
            imageState = .failed
            announce(String(localized: "Couldn’t use that image"))
            return
        }
        imageState = .idle
        if store.settings.background.imageFile != nil {
            var background = store.settings.background
            background.kind = .image
            store.setBackground(background)
        }
    }

    /// The picture goes: its copy too, and the background is the space's glow again.
    func removeImage() {
        if let url = StartPageFiles.imageURL(settings.background.imageFile) { try? FileManager.default.removeItem(at: url) }
        var background = settings.background
        background.kind = .spaceGlow
        background.imageFile = nil
        store.setBackground(background)
        imageState = .idle
    }

    // MARK: New tabs

    func setNewTab(_ opens: NewTabOpens) {
        store.setNewTab(opens)
        if opens == .address, !address.isEmpty { commitAddress() }
    }

    /// The address is checked when the user is done with it (Return, or the field loses the keyboard), not while it is typed. A bare host gets https.
    func commitAddress() {
        var typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let check = StartAddressCheck.check(typed)
        if let url = check.url, !typed.contains("://") { typed = url.absoluteString }
        address = typed
        store.setAddress(typed)
        addressState = StartAddressCheck.check(typed)
        switch addressState {
        case .invalid: announce(String(localized: "That isn’t a valid address"))
        default: break
        }
    }

    func addressEdited() { addressState = nil }

    /// "Use https://" on an address that is plain http.
    func useHTTPS() {
        guard address.lowercased().hasPrefix("http://") else { return }
        address = "https://" + address.dropFirst("http://".count)
        commitAddress()
    }

    // MARK: Reset

    /// Everything back to the defaults at once, with no question, and "Undo" in the window's notice to take it back. What was taken off the page
    /// with a card's ✕ is forgotten too, and Undo does not bring it back: the list is wiped, not kept, because it names sites.
    func reset() {
        let before = store.reset()
        hidden.showAll()
        address = ""
        addressState = nil
        expanded = nil
        imageState = .idle
        offerUndo(String(localized: "Reset the start page to its defaults")) { [store] in store.restore(before) }
    }

    func restoreAddressFromStore() {
        address = store.settings.address
        addressState = store.settings.newTab == .address && !address.isEmpty ? StartAddressCheck.check(address) : nil
    }
}
