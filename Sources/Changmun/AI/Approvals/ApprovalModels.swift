import Foundation

/// How much the panel's AI asks before it acts, which the user picks under the composer and in Settings › AI. Whatever the mode, what
/// looks like paying, sending, posting or deleting (the high tier), a cookie banner the page only calls one, and signing in are asked
/// every time: a mode only changes how much is asked besides.
enum AIApprovalMode: String, CaseIterable, Identifiable {
    /// Other tabs, new addresses and the use of a page are asked about once the chat has read another site (what it always was).
    case afterReading
    /// As `afterReading`, and the use of a page is asked about even when the chat has read nothing else.
    case everyAction
    /// Only what can't be undone is asked.
    case irreversibleOnly

    var id: String { rawValue }

    /// Whether other tabs and new addresses are asked about (which `Approvals.mayShow`, `allowTab` and `allowNavigation` follow).
    var asksAboutOtherSites: Bool { self != .irreversibleOnly }

    /// What the preferences start with: the mode that was chosen, else the old on/off switch (on is the default mode, off is the last one).
    static func initial(stored: String?, legacy: Bool?) -> AIApprovalMode {
        if let stored, let mode = AIApprovalMode(rawValue: stored) { return mode }
        return legacy == false ? .irreversibleOnly : .afterReading
    }

    var title: String {
        switch self {
        case .afterReading: String(localized: "Ask after reading other sites")
        case .everyAction: String(localized: "Ask before every action")
        case .irreversibleOnly: String(localized: "Ask only for actions that can’t be undone")
        }
    }
}

extension Approvals {
    /// Whether using a page (typing, choosing, a click, a key) is asked about: never in the last mode, in the first after another
    /// site than the page's was read, and in the stricter one always.
    nonisolated static func asksForInteraction(_ mode: AIApprovalMode, readOtherSites: Bool) -> Bool {
        switch mode {
        case .irreversibleOnly: false
        case .afterReading: readOtherSites
        case .everyAction: true
        }
    }

    /// How an approval was answered. `site` (allow on this site for as long as the chat lasts) is offered to the chat panel and to any
    /// MCP client that the bridge named itself (its chat is its connection); any other caller is only ever asked each time.
    enum Choice {
        case deny, once, site
    }

    struct Prompt {
        var message: String
        var detail: String
        var choices: [Choice]
        /// The accounts the user is to pick one of (a sign-in with several saved logins); empty for any other question.
        var accounts: [String] = []
        /// Whether it is the question of what can't be undone (the high tier of `allowAction`), or of what only the page's markup
        /// puts in a cookie banner.
        var irreversible = false
        /// What a question about using a page is made of, for the card in the panel (`detail` says the same in one text).
        var parts: Parts?

        struct Parts: Equatable {
            var site: String
            /// "Read earlier in this chat: a.example, b.example", for the questions that depend on what was read.
            var readLine = ""
            /// What the text is: "Text to type:".
            var label: String = ""
            /// The text to type, the option, the action or the button, whole, or said to be cut.
            var text: String
            var why: String
        }
    }

    /// What a question shows on the page it is about while it waits: the AI's outline around the target, kept until it is answered.
    struct Mark {
        var show: @MainActor () async -> Void
        var clear: @MainActor () -> Void
    }

    /// Where a question is asked. The card in the chat panel is for the panel's own AI, with the panel open in front of the user, and
    /// not for what can't be undone (the sheet is meant to be more trouble: it blocks the window, and no key answers yes in it, so a
    /// keystroke meant for the composer or the page can't), nor for a choice among accounts (a list the sheet already has), nor for a
    /// sign-in (a saved login is filled in on a yes, so that is asked on the window too).
    enum Route: Equatable {
        case sheet, card
    }

    /// Answers questions in place of the window, and keeps what was asked, newest last.
    final class Stand {
        var answer: (Prompt) -> Choice
        /// Which account of a question's list the user picks (the index), for the questions that have one.
        var pick: (Prompt) -> Int = { _ in 0 }
        var asked: [Prompt] = []
        /// Holds each question until it is withdrawn or released, as a window would while the user thinks.
        var holds = false

        init(_ answer: @escaping (Prompt) -> Choice) {
            self.answer = answer
        }
    }

    /// What the AI does to a page.
    enum Interaction {
        /// Text typed into a field.
        case type(String)
        /// An option chosen from a list.
        case choose(String)
        /// Anything else (a click, a key, a hover, a drop), in the words of the progress line.
        case act(String)
    }
}
