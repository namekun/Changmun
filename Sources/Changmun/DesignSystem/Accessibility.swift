import AppKit
import SwiftUI

/// What VoiceOver says about the browser's parts, composed in small functions that know nothing of views so they can be tested and
/// translated in one place. A part's label is what it is (a tab's title), its value what state it is in; whether it is selected goes in a
/// trait, and what pressing it does in a hint or an action.
enum Accessibility {
    /// A button's name from the help text it shows on hover: the words before the shortcut in parentheses, and without a trailing ellipsis
    /// ("Back (⌘[)" is "Back", "New Space…" is "New Space"). The help itself stays as it is, which VoiceOver reads after the name.
    static func label(fromHelp help: String) -> String {
        var text = help
        if text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) { text = String(text[..<open.lowerBound]) }
        while text.hasSuffix("…") || text.hasSuffix(".") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Pieces of speech put one after another: VoiceOver pauses at each comma.
    static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: Tabs and bookmarks

    /// What a tab is doing, besides being the one shown (which is a trait).
    struct TabFacts: Equatable {
        var loading = false
        var playingAudio = false
        var muted = false
        var asleep = false
        /// It is a bookmark's tab: kept in the favorites or a pinned folder.
        var pinned = false
        var split = false
        var group: String?
    }

    static func tabValue(_ facts: TabFacts) -> String {
        join([
            facts.loading ? String(localized: "Loading") : nil,
            facts.muted ? String(localized: "Muted") : facts.playingAudio ? String(localized: "Playing audio") : nil,
            facts.asleep ? String(localized: "Sleeping") : nil,
            facts.pinned ? String(localized: "Pinned") : nil,
            facts.group.map { String(localized: "In group \($0)") },
            facts.split ? String(localized: "Split View") : nil,
        ])
    }

    /// A bookmark or favorite's name: its title, or its site when it has none.
    static func bookmarkLabel(title: String, url: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return URL(string: url)?.host().map(DisplayHost.trimmed) ?? url
    }

    /// Whether the bookmark's own tab is open.
    static func bookmarkValue(_ state: BookmarkTabState) -> String {
        state == .closed ? String(localized: "Not open") : String(localized: "Open")
    }

    static func bookmarkCount(_ count: Int) -> String {
        count == 1 ? String(localized: "\(count) bookmark") : String(localized: "\(count) bookmarks")
    }

    static func tabCount(_ count: Int) -> String {
        count == 1 ? String(localized: "\(count) tab") : String(localized: "\(count) tabs")
    }

    static func expansion(_ open: Bool) -> String { open ? String(localized: "Expanded") : String(localized: "Collapsed") }

    /// A folder row: open or closed, and how many bookmarks it holds (nil: not said).
    static func folderValue(open: Bool, bookmarks: Int?) -> String {
        join([expansion(open), bookmarks.map(bookmarkCount)])
    }

    static func groupValue(open: Bool, tabs: Int) -> String { join([expansion(open), tabCount(tabs)]) }

    /// Whether a list that opens and closes is shown, and what pressing it does.
    static func toggleAction(open: Bool) -> String { open ? String(localized: "Collapse") : String(localized: "Expand") }

    static func spaceValue(isProfile: Bool) -> String? { isProfile ? String(localized: "Separate logins and cookies") : nil }

    // MARK: The page bar

    /// What a saved page says besides its title: whether it is still to be read, where it is from and how long ago it was saved.
    static func readingValue(read: Bool, site: String, added: String) -> String {
        join([read ? String(localized: "Read") : String(localized: "Unread"), site, added])
    }

    static func shownValue(_ shown: Bool) -> String { shown ? String(localized: "Shown") : String(localized: "Hidden") }

    static func onOffValue(_ on: Bool) -> String { on ? String(localized: "Turned on") : String(localized: "Turned off") }

    /// The lock beside the address, for people who can't see its glyph. `scheme` is the page's.
    static func connectionValue(scheme: String?, unverified: Bool, choseToGoOn: Bool) -> String? {
        if choseToGoOn { return String(localized: "Certificate not verified, you chose to go on") }
        if unverified { return String(localized: "Certificate not verified") }
        switch scheme {
        case "https": return String(localized: "Secure connection")
        case "http": return String(localized: "Connection is not secure")
        default: return nil
        }
    }

    /// A share of something, in whole percent ("40 percent" for 0.4), kept within 0 and 100.
    static func percentValue(_ fraction: Double) -> String {
        let percent = Int((min(1, max(0, fraction)) * 100).rounded())
        return String(localized: "\(percent) percent")
    }

    /// How far a page has loaded.
    static func loadingValue(progress: Double) -> String { percentValue(progress) }

    static func downloadsValue(active: Int) -> String? {
        switch active {
        case ..<1: nil
        case 1: String(localized: "\(active) download in progress")
        default: String(localized: "\(active) downloads in progress")
        }
    }

    // MARK: The command bar

    enum SuggestionKind: Equatable {
        case open(String)
        case search(String)
        case ask(String)
        /// `space` names the space the tab is in, when that isn't the one shown.
        case tab(title: String, host: String, space: String?)
        case page(title: String, host: String)
    }

    /// A suggestion as one sentence: what it does, then to what.
    static func suggestionLabel(_ kind: SuggestionKind) -> String {
        switch kind {
        case .open(let text): String(localized: "Open \(text)")
        case .search(let text): String(localized: "Search for \(text)")
        case .ask(let text): String(localized: "Ask AI: \(text)")
        case .tab(let title, _, let space): space.map { String(localized: "Switch to tab \(title) in \($0)") } ?? String(localized: "Switch to tab \(title)")
        case .page(let title, let host): String(localized: "Open \(title.isEmpty ? host : title)")
        }
    }

    /// A suggestion's site, said after its name.
    static func suggestionValue(_ kind: SuggestionKind) -> String? {
        switch kind {
        case .tab(_, let host, _), .page(_, let host): host.isEmpty ? nil : host
        default: nil
        }
    }

    static func resultsCount(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "No suggestions")
        case 1: String(localized: "1 suggestion")
        default: String(localized: "\(count) suggestions")
        }
    }

    // MARK: Find and the AI panel

    static func findMatches(_ matches: Int) -> String {
        matches == 0 ? String(localized: "None") : matches == 1 ? String(localized: "\(matches) match") : String(localized: "\(matches) matches")
    }

    /// "You said" before the user's words, and "AI said" over the AI's answer, so a list of messages reads as a conversation.
    static func youSaid(_ text: String) -> String { String(localized: "You said: \(text)") }

    static var aiSaid: String { String(localized: "AI said") }

    /// What the AI is doing while it works: the time it has worked (kept out of the label, which would be read again every second) and its step.
    static func workingValue(elapsed: String?, step: String?) -> String { join([elapsed, step]) }

    // MARK: Dividers

    /// Where a divider is after VoiceOver's "increase" or "decrease", kept within what it may be.
    static func adjusted(_ value: Double, _ direction: AccessibilityAdjustmentDirection, step: Double, in range: ClosedRange<Double>) -> Double {
        switch direction {
        case .increment: min(range.upperBound, value + step)
        case .decrement: max(range.lowerBound, value - step)
        @unknown default: value
        }
    }

    static func widthValue(_ width: Double) -> String { String(localized: "\(Int(width.rounded())) points") }
}

extension SpaceTint {
    /// What the colour is called, for the picker's buttons: a colour alone says nothing to a screen reader.
    var name: String {
        switch self {
        case .blue: String(localized: "Blue")
        case .coral: String(localized: "Coral")
        case .green: String(localized: "Green")
        case .purple: String(localized: "Purple")
        case .amber: String(localized: "Amber")
        case .teal: String(localized: "Teal")
        case .pink: String(localized: "Pink")
        case .gray: String(localized: "Gray")
        }
    }
}

// MARK: - Announcements

/// What is said aloud once and not again: a short run of the same words is one announcement, and nothing is announced over a person who is
/// typing (the speech would talk over the field) unless it matters.
struct AnnouncementGate {
    private(set) var lastText: String?
    private(set) var lastAt = Date.distantPast
    /// The same words again within this many seconds are left out.
    var repeatWindow: TimeInterval = 2

    mutating func allows(_ text: String, important: Bool, typing: Bool, now: Date = Date()) -> Bool {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if typing && !important { return false }
        if text == lastText && now.timeIntervalSince(lastAt) < repeatWindow { return false }
        lastText = text
        lastAt = now
        return true
    }
}

@MainActor
enum Announcer {
    private static var gate = AnnouncementGate()
    /// What went out, newest last (the last few), for the test copy to look at.
    private(set) static var recent: [String] = []
    /// Where announcements go; a test puts its own here.
    static var deliver: (String, Bool) -> Void = { text, important in
        // Without an application (the unit tests') there is nobody to tell.
        guard NSApp != nil else { return }
        var announcement = AttributedString(text)
        announcement.accessibilitySpeechAnnouncementPriority = important ? .high : .low
        AccessibilityNotification.Announcement(announcement).post()
    }

    /// Whether a text field of the app has the keyboard: the field editor is the first responder.
    static var isTyping: Bool { (NSApp?.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor == true }

    /// `important` speaks over what is being said and over a person typing; `whileTyping` is for what answers the typing itself (the command
    /// bar's number of suggestions), which is only said in the pauses.
    static func announce(_ text: String, important: Bool = false, whileTyping: Bool = false) {
        guard gate.allows(text, important: important || whileTyping, typing: isTyping) else { return }
        recent.append(text)
        if recent.count > 20 { recent.removeFirst(recent.count - 20) }
        deliver(text, important)
    }
}

// MARK: - Views

/// What a part that is only a tap gesture says and does for VoiceOver, Voice Control, Switch Control and Full Keyboard Access: one element, a
/// button, with the name and state given here, which Return or Space (once it has the keyboard focus) and the accessibility press act on.
/// `actions` are the other things the part's menu does, named for the rotor.
struct AccessibleButton: ViewModifier {
    struct Action: Identifiable {
        let name: String
        let run: () -> Void
        var id: String { name }
    }

    let label: String
    var value: String?
    var hint: String?
    var selected = false
    /// It heads what follows (a group of tabs, a folder source): VoiceOver's headings rotor stops at it.
    var header = false
    var actions: [Action] = []
    /// False while the part holds a text field (its name being typed): then it is left as it is.
    var enabled = true
    let activate: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(value ?? "")
                .accessibilityHint(hint ?? "")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAddTraits(header ? .isHeader : [])
                .accessibilityAction(.default, activate)
                .accessibilityActions { ForEach(actions) { action in Button(action.name, action: action.run) } }
                .focusable(true, interactions: .activate)
                .onKeyPress(.return) {
                    activate()
                    return .handled
                }
                .onKeyPress(.space) {
                    activate()
                    return .handled
                }
        } else {
            content
        }
    }
}

extension View {
    func accessibleButton(_ label: String, value: String? = nil, hint: String? = nil, selected: Bool = false, header: Bool = false, enabled: Bool = true,
                          actions: [AccessibleButton.Action] = [], activate: @escaping () -> Void) -> some View {
        modifier(AccessibleButton(label: label, value: value, hint: hint, selected: selected, header: header, actions: actions, enabled: enabled, activate: activate))
    }

    /// A glyph that only repeats what is written beside it: left out of what VoiceOver reads.
    func decorative() -> some View { accessibilityHidden(true) }
}

extension AccessibleButton.Action {
    init(_ name: String, _ run: @escaping () -> Void) { self.init(name: name, run: run) }
}
