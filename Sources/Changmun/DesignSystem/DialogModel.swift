import Foundation

/// What a dialog says and offers, apart from how it looks, so that the rules for its buttons are plain data a test can check:
/// which one Return presses, which one Esc presses, and how each is drawn.
struct DialogButton: Equatable {
    enum Role: Equatable {
        /// Does what the dialog is about.
        case normal
        /// Says no and leaves things as they were; Esc presses it.
        case cancel
        /// Deletes: drawn in the danger colour, and never the button Return presses.
        case destructive
    }

    var title: String
    var role: Role = .normal
    /// Return presses this one: the safe choice (a destructive button is never taken for it).
    var isDefault = false
}

/// What sits in the box under the message.
enum DialogDetail: Equatable {
    /// Text, whole and scrollable, for what the user has to be able to read to the end (an address, a list of what is granted).
    case text(String)
}

struct DialogField: Equatable {
    var placeholder: String
    var text = ""
    /// A password: its characters are never shown and never logged.
    var isSecure = false
}

struct DialogSpec: Equatable {
    var title: String
    var message: String?
    var detail: DialogDetail?
    var fields: [DialogField] = []
    /// A pop-up list to pick one entry from (the account to sign in with), and what it is called for VoiceOver.
    var choices: [String] = []
    var choicesLabel = ""
    /// The words of a checkbox ("Remember for this site"); nil for none.
    var remember: String?
    /// From left to right.
    var buttons: [DialogButton]
    /// One line about where the question comes from, when that is not the page in front ("From a tab in the background").
    var note: String?
    /// Asked by a page, a server, an extension or the AI, not by the user's own action: its buttons that say yes wake up a moment after the sheet
    /// is on screen, and a click on one counts only if it began after that (a click meant for what was under the sheet is not an answer).
    var guarded = false

    enum Style: Equatable { case primary, secondary, danger }
    enum Key: Equatable { case `return`, escape }

    /// The button Return presses: the one marked as the default (a destructive one never is); with none marked, the Cancel button when
    /// something is destructive, else the last one that is not a Cancel.
    var defaultIndex: Int? {
        if let marked = buttons.firstIndex(where: { $0.isDefault && $0.role != .destructive }) { return marked }
        if buttons.contains(where: { $0.role == .destructive }) { return cancelIndex }
        return buttons.lastIndex { $0.role != .cancel } ?? buttons.indices.last
    }

    /// The button Esc presses: the Cancel button, or the only button there is (a notice that can only be closed).
    var cancelIndex: Int? {
        buttons.firstIndex { $0.role == .cancel } ?? (buttons.count == 1 ? 0 : nil)
    }

    /// The button that says no and leaves everything as it was: always live.
    func isSafe(_ index: Int) -> Bool { buttons.indices.contains(index) && index == cancelIndex }

    func button(for key: Key) -> Int? {
        switch key {
        case .return: defaultIndex
        case .escape: cancelIndex
        }
    }

    /// The filled ink button is always the one Return presses, so what stands out is what the key does. Deleting is red and never filled in ink;
    /// everything else is grey.
    func style(of index: Int) -> Style {
        guard buttons.indices.contains(index) else { return .secondary }
        if buttons[index].role == .destructive { return .danger }
        return index == defaultIndex ? .primary : .secondary
    }

    /// Deleting what cannot be brought back: Cancel is what Return does, and Delete is red.
    static func confirmDelete(_ title: String, _ message: String) -> DialogSpec {
        DialogSpec(title: title, message: message,
                   buttons: [DialogButton(title: String(localized: "Cancel"), role: .cancel, isDefault: true), DialogButton(title: String(localized: "Delete"), role: .destructive)])
    }

    /// A site's host as the page's origin says it, cleaned of what hides or reorders text. When it is long it is cut from the left, not from the end:
    /// the end is the domain the site really belongs to, and a long subdomain must not push it out of sight ("…aaaa.evil.example").
    static func host(_ text: String, limit: Int = 48) -> String {
        guard !text.isEmpty else { return String(localized: "This page") }
        let longest = 400
        let scalars = Array(text.unicodeScalars)
        var cleaned = Array(Approvals.shown(String(String.UnicodeScalarView(scalars.suffix(longest))), limit: longest).text.unicodeScalars)
        var cut = scalars.count > longest
        if cleaned.count > limit {
            cleaned = Array(cleaned.suffix(limit))
            cut = true
        }
        return (cut ? "…" : "") + String(String.UnicodeScalarView(cleaned))
    }

    /// A name that comes from outside the app (a site's host, a program's name) is cleaned of what hides or reorders text, cut to `limit`
    /// characters, and marked when it was cut.
    static func name(_ text: String, limit: Int = 60) -> String {
        let shown = Approvals.shown(text, limit: limit)
        return shown.cut > 0 ? shown.text + "…" : shown.text
    }
}

/// What the user chose.
struct DialogResult: Equatable {
    var button: Int
    var fields: [String]
    var remembered: Bool
    /// The entry picked from `choices`.
    var picked: Int
}

/// What a question is about, for questions that arrive in a crowd: the same `group` and `kind` is one question (a page's many requests that
/// need the same login share one answer), the same group with another kind is asked after it, and another group is refused while one is up.
struct DialogKey: Hashable {
    var group: String
    var kind: String
}

/// Whether a press of a button counts. A question that is guarded keeps its buttons that say yes shut until it has been on screen for a moment;
/// then a click counts only if it began after that, and a key (Return, Space) or an assistive technology's press counts. The safe button always does.
enum DialogGate {
    static func mayPress(guarded: Bool, safe: Bool, shownAt: Date?, mouseDownAt: Date?, mouseUpAt: Date?, keyDown: (at: Date, isRepeat: Bool)?, now: Date) -> Bool {
        guard guarded, !safe else { return true }
        guard let shownAt else { return false }
        switch ApprovalKeys.activation(mouseUpAt: mouseUpAt, keyDown: keyDown, now: now) {
        case .mouse: return ApprovalKeys.mayClickYes(shownAt: shownAt, mouseDownAt: mouseDownAt, now: now)
        case .repeatedKey: return false
        case .keyboard, .noEvent: return ApprovalKeys.yesArmed(shownFor: now.timeIntervalSince(shownAt))
        }
    }
}
