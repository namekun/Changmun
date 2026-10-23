import AppKit
import SwiftUI
import WebKit

/// The questions of the panel's AI that wait in the panel itself, above the composer, instead of on the window: the Stop button next to
/// them stays usable, and the page can be looked at while the user decides. `Approvals.route` says which questions come here.
@MainActor
final class ApprovalCards: ObservableObject {
    static let shared = ApprovalCards()

    struct Card: Identifiable {
        let id: UUID
        let prompt: Approvals.Prompt
        let buttons: [(Approvals.Choice, String)]
        weak var browser: Browser?
        /// When the question was made; when its card was first in front is `ApprovalCards.visibleSince`.
        let shownAt = Date()
        /// Answers the question; the card goes with it.
        let answer: (Approvals.Choice) -> Void
        /// The panel closed with the question open: asks it on the window instead.
        let moveToSheet: () -> Void
    }

    /// Oldest first: the AI may ask for several things at once, and they are answered in the order they came.
    @Published private(set) var cards: [Card] = []
    private var monitor: Any?
    /// Keyboard focus is on the card itself (set by the card), which the keys that say yes may then act from.
    var cardFocused = false
    /// When the mouse button last went down in the app: a click on a button that says yes counts only if it began after the card was armed.
    private(set) var lastMouseDown: Date?
    /// When each card became the first one of its panel, the one on show: the keys and the buttons that say yes are armed a moment after
    /// that, not after the question was made (a second question must not wake up already armed when the first is answered).
    private var frontSince: [UUID: Date] = [:]

    func visibleSince(_ id: UUID) -> Date {
        frontSince[id] ?? cards.first { $0.id == id }?.shownAt ?? Date()
    }

    func add(_ card: Card) {
        if cards.isEmpty { cardFocused = false }
        let alone = card.browser.map { first(for: $0) == nil } ?? true
        cards.append(card)
        if alone { frontSince[card.id] = Date() }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                if event.type == .leftMouseDown {
                    self?.lastMouseDown = Date()
                    return event
                }
                return self?.keyDown(event) ?? event
            }
        }
    }

    func remove(_ id: UUID) {
        let browser = cards.first { $0.id == id }?.browser
        cards.removeAll { $0.id == id }
        frontSince[id] = nil
        // The next question of that panel comes to the front now.
        if let browser, let next = first(for: browser), frontSince[next.id] == nil { frontSince[next.id] = Date() }
        // The focus was on the card that went: the next one starts without it.
        cardFocused = false
        if cards.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            lastMouseDown = nil
        }
    }

    func first(for browser: Browser) -> Card? {
        cards.first { $0.browser === browser }
    }

    /// The panel of `browser` went away: what it was asking is asked on the window.
    func moveToSheet(for browser: Browser) {
        for card in cards where card.browser === browser {
            remove(card.id)
            card.moveToSheet()
        }
    }

    private func keyDown(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, let card = cards.first(where: { $0.browser?.window === window }) else { return event }
        // Keys that belong to what the user is doing stay theirs: typing in a page, or in a field that has text in it.
        var responder = window.firstResponder
        var inPage = false
        while let current = responder, !inPage {
            inPage = current is WKWebView
            responder = current.nextResponder
        }
        let typed = (window.firstResponder as? NSTextView).map { !$0.string.isEmpty } ?? false
        // The keys that say yes work only from the panel: its box, or the card (but not from a text field elsewhere, like the address bar).
        let inPanel = window.firstResponder is ComposerTextView || (cardFocused && !(window.firstResponder is NSText))
        guard let choice = ApprovalKeys.choice(keyCode: event.keyCode, flags: event.modifierFlags, offered: card.prompt.choices,
                                               inPage: inPage, typed: typed, inPanel: inPanel, shownFor: Date().timeIntervalSince(visibleSince(card.id))) else { return event }
        // A key held down answers once, and its repeats are not taken for more (nor passed on to the box).
        if event.isARepeat { return nil }
        card.answer(choice)
        return nil
    }
}

/// What the keys answer: Return no (the safe one), ⌘Return yes once, ⌥⌘Return yes for the chat, Esc no. The keys that say yes answer only
/// when keyboard focus is in the panel (its box or the card): never from the address bar, the sidebar, the find bar or the page.
enum ApprovalKeys {
    /// How long after a card came up the keys that say yes do nothing: a key pressed for something else a moment ago can't answer it.
    static let yesDelay: TimeInterval = 0.5

    /// Whether a card shown this long has its buttons that say yes live: for the keys and for the mouse.
    static func yesArmed(shownFor: TimeInterval) -> Bool { shownFor >= yesDelay }

    /// Whether a click on a button that says yes counts: the card is armed, and the press began after it was (a press that began on
    /// something else while the card was still new, or before it was there, is not an answer to it).
    static func mayClickYes(shownAt: Date, mouseDownAt: Date?, now: Date) -> Bool {
        guard let mouseDownAt else { return false }
        return yesArmed(shownFor: now.timeIntervalSince(shownAt)) && yesArmed(shownFor: mouseDownAt.timeIntervalSince(shownAt))
    }

    static func choice(keyCode: UInt16, flags: NSEvent.ModifierFlags, offered: [Approvals.Choice], inPage: Bool, typed: Bool, inPanel: Bool, shownFor: TimeInterval) -> Approvals.Choice? {
        // In a page, Return and Esc are the page's, and ⌘Return sends what the user wrote there.
        guard !inPage else { return nil }
        let held = flags.intersection([.command, .option, .shift, .control])
        let choice: Approvals.Choice
        switch (keyCode, held) {
        case (53, []): return offered.contains(.deny) ? .deny : nil
        case (36, []), (76, []): choice = .deny
        case (36, [.command]), (76, [.command]): choice = .once
        case (36, [.command, .option]), (76, [.command, .option]): choice = .site
        default: return nil
        }
        // A message being written in the composer is sent by Return, not answered by it.
        guard !typed, offered.contains(choice) else { return nil }
        guard choice == .deny || inPanel else { return nil }
        return choice == .deny || yesArmed(shownFor: shownFor) ? choice : nil
    }
}

/// Between the conversation and the composer: the first question waiting in this window's panel.
struct ApprovalCardHost: View {
    @ObservedObject private var cards = ApprovalCards.shared
    let browser: Browser

    var body: some View {
        VStack(spacing: 0) {
            if let card = cards.first(for: browser) {
                ApprovalCardView(card: card, waiting: cards.cards.filter { $0.browser === browser }.count - 1)
                    .id(card.id)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
            }
        }
        .onDisappear { ApprovalCards.shared.moveToSheet(for: browser) }
    }
}

struct ApprovalCardView: View {
    let card: ApprovalCards.Card
    /// How many more questions are waiting behind this one.
    let waiting: Int
    @FocusState private var focused: Bool
    /// The buttons that say yes wake up a moment after the card comes: a click meant for what was under it is not an answer.
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.waiting)
                Text(verbatim: card.prompt.message).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let parts = card.prompt.parts {
                Text(verbatim: parts.site).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(2)
                if !parts.readLine.isEmpty {
                    Text(verbatim: parts.readLine).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                excerpt(label: parts.label, text: parts.text)
                Text(verbatim: parts.why).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                excerpt(label: "", text: card.prompt.detail)
            }
            if waiting > 0 {
                Text("\(waiting) more waiting").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.faint)
            }
            buttons
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.waiting.opacity(0.6), lineWidth: 1))
        .shadow(color: Theme.cardShadow, radius: 6, y: 2)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onChange(of: focused) { ApprovalCards.shared.cardFocused = focused }
        .task {
            let wait = ApprovalKeys.yesDelay - Date().timeIntervalSince(ApprovalCards.shared.visibleSince(card.id))
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            armed = true
        }
    }

    /// The exact text, whole: scrollable when long, never cut here.
    private func excerpt(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !label.isEmpty {
                Text(verbatim: label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            ScrollView {
                Text(verbatim: text).font(.system(size: 12)).foregroundStyle(Theme.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 110)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
        }
    }

    private var buttons: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(card.buttons.filter { $0.0 != .site }, id: \.0) { choice, title in
                    button(choice, title)
                }
            }
            ForEach(card.buttons.filter { $0.0 == .site }, id: \.0) { choice, title in
                button(choice, title)
            }
        }
    }

    private func button(_ choice: Approvals.Choice, _ title: String) -> some View {
        let live = choice == .deny || armed
        return Button {
            guard choice == .deny || ApprovalKeys.mayClickYes(shownAt: ApprovalCards.shared.visibleSince(card.id), mouseDownAt: ApprovalCards.shared.lastMouseDown, now: Date()) else { return }
            card.answer(choice)
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: title).font(.system(size: 11.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Keycap(choice == .deny ? "↵" : choice == .once ? "⌘↵" : "⌥⌘↵")
            }
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(choice == .deny ? Theme.pill : Theme.hoverTab))
            .opacity(live ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!live)
    }
}
