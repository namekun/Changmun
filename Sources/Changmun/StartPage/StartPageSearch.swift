import AppKit
import SwiftUI

/// The start page's search field: the command bar's field, with its list under it. What is typed brings the same suggestions (`CommandBar.suggestions`),
/// Return opens the highlighted one the way the command bar does (`CommandBar.run`), ⌘Return in a new tab, Esc clears.
struct StartSearchBox: View {
    @ObservedObject var browser: Browser
    @ObservedObject var chat: ChatStore
    /// Where a typed address or search goes: a new tab, or the tab that shows this page (see `CommandBarMode`).
    var mode: CommandBarMode = .newTab
    /// The smaller field under the AI box of the AI-first page.
    var compact = false
    /// Whether something is typed: the page behind steps back while it is.
    @Binding var typing: Bool
    /// Changes when the field should have the keyboard (⌘L, ⇧⇥ from the first section, a new page).
    var focusRequest = 0
    /// The keyboard leaves the field for the sections (↓ or ⇥ with nothing to choose from).
    var leave: (_ backwards: Bool) -> Void = { _ in }
    @ObservedObject private var prefs = Preferences.shared
    @State private var text = ""
    /// What the field shows, composing syllable and all (see `CommandBar.shown`).
    @State private var shown = ""
    @State private var selection = 0
    @State private var pointer = PointerMovement()
    @StateObject private var source = SuggestionSource()
    @FocusState private var focused: Bool
    @State private var announceTask: Task<Void, Never>?

    private var placeholder: String {
        if compact { return String(localized: "Or search or enter an address") }
        return browser.isPrivate ? String(localized: "Search or enter an address") : String(localized: "Search, enter an address or ask AI")
    }

    private var query: String { shown.trimmingCharacters(in: .whitespaces) }

    private var items: [CommandBar.Suggestion] {
        query.isEmpty ? [] : CommandBar.suggestions(shown: shown, pages: source.pages, searches: source.searches, browser: browser, mode: mode)
    }

    var body: some View {
        let items = items
        // The list floats over the sections under the field, which step back; it does not push them down.
        field(height: compact ? 38 : 46)
            .overlay(alignment: .top) {
                if !items.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(Array(zip(CommandBar.rowIDs(items), items).enumerated()), id: \.element.0) { index, row in
                            SuggestionRow(item: row.1, selected: index == selection, fetchesIcons: false) { run($0) }
                                .onContinuousHover(coordinateSpace: .global) { phase in
                                    if case .active(let point) = phase, pointer.moved(to: point) { selection = index }
                                }
                        }
                    }
                    .padding(6)
                    .floatingPanel(radius: 12)
                    .offset(y: (compact ? 38 : 46) + 8)
                }
            }
            .zIndex(10)
        .onKeyPress(.downArrow) {
            guard !items.isEmpty else { return .ignored }
            selection = max(0, min(selection + 1, items.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !items.isEmpty else { return .ignored }
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            guard !text.isEmpty else { return .ignored }
            clear()
            return .handled
        }
        .onKeyPress(.tab) {
            guard items.isEmpty else { return .ignored }
            leave(NSEvent.modifierFlags.contains(.shift))
            return .handled
        }
        .onKeyPress(.return) {
            // ⌘Return: in a new tab, whatever the page would do.
            guard NSEvent.modifierFlags.contains(.command), let item = CommandBar.chosen(items, at: selection) else { return .ignored }
            CommandBar.run(item, browser: browser, chat: chat, mode: .newTab)
            return .handled
        }
        .onChange(of: items) { old, new in selection = CommandBar.keptSelection(selection, old: old, new: new) }
        .onChange(of: items.count) { _, count in
            announceTask?.cancel()
            guard !query.isEmpty else { return }
            announceTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                if !Task.isCancelled { Announcer.announce(Accessibility.resultsCount(count), whileTyping: true) }
            }
        }
        .onChange(of: focusRequest) { focused = true }
        .onChange(of: query.isEmpty) { _, empty in typing = !empty }
        .onDisappear {
            announceTask?.cancel()
            typing = false
        }
    }

    private func field(height: CGFloat) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.secondary).decorative()
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 14 : 16, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .focused($focused)
                .accessibilityLabel(placeholder)
                .accessibilityHint(String(localized: "Type to see suggestions. Use the up and down arrow keys to choose one, and Return to open it"))
                // The list as it is when Return is pressed: the field keeps the handler it had when its text last changed.
                .onSubmit { run(CommandBar.chosen(currentItems, at: selection)) }
                .onChange(of: text) { syncShown() }
                .onChange(of: shown) {
                    selection = 0
                    refresh()
                }
                // Composing text reaches the field editor at once (the binding only when it is settled), as in the command bar.
                .onReceive(NotificationCenter.default.publisher(for: NSText.didChangeNotification)) { note in
                    guard browser.commandBar == nil,
                          let editor = CommandBar.ownEditor(note.object as? NSResponder, in: browser.window, placeholder: placeholder) else { return }
                    shown = CommandBar.shownText(editor: editor.string, binding: text)
                }
            Keycap(text.isEmpty ? "⌘L" : "esc")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: height)
        .startPlate(radius: 10, fill: Theme.field)
    }

    private var currentItems: [CommandBar.Suggestion] { items }

    private var fieldEditor: NSTextView? {
        CommandBar.ownEditor(browser.window?.firstResponder, in: browser.window, placeholder: placeholder)
    }

    private func syncShown() {
        shown = CommandBar.shownText(editor: fieldEditor?.string, binding: text)
    }

    private func refresh() {
        let word = query
        source.update(word, remote: !word.isEmpty && prefs.searchSuggestions && !browser.isPrivate, hiding: CommandBar.hiddenFavorites(browser))
    }

    private func clear() {
        text = ""
        shown = ""
    }

    private func run(_ item: CommandBar.Suggestion?) {
        CommandBar.run(item, browser: browser, chat: chat, mode: mode)
        if item != nil { clear() }
    }
}
