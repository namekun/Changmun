import AppKit
import SwiftUI

// MARK: ⌘K

/// The list of what the user has: open tabs (of every space), spaces, a few commands, bookmarks and history, found by typing a few letters.
/// The command bar (⌘L, ⌘T) is for going somewhere new, a page or a search; this is for finding what is already open or kept.
struct QuickFind: View {
    @ObservedObject var browser: Browser
    var area = PageArea.window
    @State private var text = ""
    /// What the field shows: `text` with the syllable an input method is still composing, which the binding doesn't hold until it is settled.
    @State private var shown = ""
    @State private var selection = 0
    @State private var pointer = PointerMovement()
    /// What the library found for `found`, off the main thread: bookmarks and history.
    @State private var bookmarks: [Library.Entry] = []
    @State private var visits: [Library.Entry] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var announceTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var items: [QuickFindItem] {
        QuickFindList.items(for: shown, in: browser, bookmarks: bookmarks, visits: visits)
    }

    var body: some View {
        let items = items
        ZStack(alignment: .top) {
            Theme.scrim
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.symbolToolbar)
                        .foregroundStyle(Theme.secondary)
                        .decorative()
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .font(.heading)
                        .foregroundStyle(Theme.primary)
                        .focused($focused)
                        .accessibilityLabel(placeholder)
                        .accessibilityHint(String(localized: "Type to see suggestions. Use the up and down arrow keys to choose one, and Return to open it"))
                        .onSubmit { submit() }
                        .onChange(of: text) { syncShown() }
                        .onChange(of: shown) {
                            selection = 0
                            search()
                        }
                        // Composing text reaches the field editor at once (and the binding only when it is settled); only this field's own editor.
                        .onReceive(NotificationCenter.default.publisher(for: NSText.didChangeNotification)) { note in
                            if let editor = CommandBar.ownEditor(note.object as? NSResponder, in: browser.window, placeholder: placeholder) {
                                shown = CommandBar.shownText(editor: editor.string, binding: text)
                            }
                        }
                    Keycap("esc")
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .frame(height: 46)
                .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Theme.field))
                if items.isEmpty {
                    Text("No matches").font(.secondary).foregroundStyle(Theme.secondary).frame(height: 34)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(Array(items.enumerated()), id: \.element.identity) { index, item in
                                    QuickFindRow(item: item, selected: index == selection, keepsIcons: !browser.isPrivate) { run($0) }
                                        .onContinuousHover(coordinateSpace: .global) { phase in
                                            if case .active(let point) = phase, pointer.moved(to: point) { selection = index }
                                        }
                                        .id(item.identity)
                                }
                            }
                        }
                        .frame(maxHeight: 4 * 88)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: selection) {
                            if items.indices.contains(selection) { proxy.scrollTo(items[selection].identity) }
                        }
                    }
                }
            }
            .padding(8)
            .frame(width: min(620, max(320, area.width - 32)))
            .floatingPanel(radius: Metrics.panelRadius, modal: true)
            .padding(.top, 96)
            .padding(.leading, area.leading)
            .padding(.trailing, area.trailing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Search"))
            .accessibilityAddTraits(.isModal)
            .onKeyPress(.downArrow) { selection = max(0, min(selection + 1, items.count - 1)); return .handled }
            .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
            .onKeyPress(.escape) { dismiss(); return .handled }
        }
        .onChange(of: items) { old, new in selection = QuickFindList.keptSelection(selection, old: old, new: new) }
        // The number of rows is said once the typing pauses, not at every letter.
        .onChange(of: items.count) { _, count in
            announceTask?.cancel()
            announceTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                if !Task.isCancelled { Announcer.announce(Accessibility.resultsCount(count), whileTyping: true) }
            }
        }
        .onDisappear {
            searchTask?.cancel()
            announceTask?.cancel()
            // The keyboard goes back to the page it was on before the list opened, unless something else (the command bar, the find bar) has it by now.
            DispatchQueue.main.async {
                guard let window = browser.window, window.firstResponder == nil || window.firstResponder === window, browser.commandBar == nil,
                      !browser.quickFind, !browser.findBarVisible, !browser.showOnboarding, let page = browser.active?.webView, page.window === window else { return }
                window.makeFirstResponder(page)
            }
        }
        .onAppear {
            browser.window?.makeFirstResponder(nil)
            DispatchQueue.main.async { focused = true }
        }
    }

    /// What the field says while it is empty, which is also what tells it from the other fields of the window.
    private var placeholder: String { String(localized: "Search tabs, spaces and commands") }

    private var fieldEditor: NSTextView? {
        CommandBar.ownEditor(browser.window?.firstResponder, in: browser.window, placeholder: placeholder)
    }

    private func syncShown() {
        shown = CommandBar.shownText(editor: fieldEditor?.string, binding: text)
    }

    private func dismiss() {
        browser.quickFind = false
    }

    /// Bookmarks and history for the words, off the main thread. Another profile's favorites stay out, and a private window has no history.
    private func search() {
        searchTask?.cancel()
        let query = shown.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            bookmarks = []
            visits = []
            return
        }
        let hiding = CommandBar.hiddenFavorites(browser)
        let history = !browser.isPrivate
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let found = await Library.shared.inBackground { $0.searchKinds(query, limit: 8, hiding: hiding, history: history) }
            guard !Task.isCancelled else { return }
            bookmarks = found.bookmarks
            visits = found.visits
        }
    }

    private func run(_ item: QuickFindItem) {
        QuickFindList.run(item, in: browser)
    }

    /// Return opens the highlighted row, but not while an input method is still composing (that Return only settles the syllable).
    private func submit() {
        guard browser.quickFind, fieldEditor?.hasMarkedText() != true else { return }
        let list = items
        guard list.indices.contains(selection) else { return }
        run(list[selection])
    }
}

struct QuickFindRow: View {
    let item: QuickFindItem
    let selected: Bool
    /// False in a private window: no icon is saved to disk for its tabs.
    var keepsIcons = true
    let run: (QuickFindItem) -> Void
    @State private var press = RowPress<QuickFindItem>()
    @State private var size = CGSize.zero

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 20)
            label
            Spacer(minLength: 0)
            if selected { Keycap("↵") }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background { if selected { SelectedBackground() } }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in press.began(on: item) }
            .onEnded { value in
                if let pressed = press.ended(inside: CGRect(origin: .zero, size: size).contains(value.location)) { run(pressed) }
            })
        .accessibleButton(accessibilityLabel, value: accessibilityValue, hint: selected ? String(localized: "Return opens it") : nil, selected: selected) { run(item) }
    }

    private var accessibilityLabel: String {
        switch item {
        case .tab(_, let title, _, let space, _): Accessibility.suggestionLabel(.tab(title: title, host: "", space: space))
        case .space(_, let name, _): String(localized: "Switch to space \(name)")
        case .command(_, let title): title
        case .bookmark(let url, let title), .visit(let url, let title): Accessibility.suggestionLabel(.page(title: title, host: URL(string: url)?.host() ?? url))
        }
    }

    private var accessibilityValue: String? {
        switch item {
        case .tab(_, _, let url, _, _), .bookmark(let url, _), .visit(let url, _): URL(string: url)?.host()
        case .space, .command: nil
        }
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .tab(_, _, let url, _, _): SiteIcon(url: url, size: 16, keep: keepsIcons)
        case .bookmark(let url, _), .visit(let url, _): SiteIcon(url: url, size: 16, keep: keepsIcons)
        case .space(_, let name, let symbol): SpaceIcon(space: Space(name: name, symbol: symbol, tint: .gray), size: 14)
        case .command(let command, _): Image(systemName: command.symbol).font(.symbolToolbar).foregroundStyle(Theme.secondary)
        }
    }

    @ViewBuilder private var label: some View {
        switch item {
        case .tab(_, let title, let url, let space, let sleeping):
            Text(title).font(.bodyStrong).foregroundStyle(Theme.primary).lineLimit(1)
            Text(space.map { String(localized: "Switch to Tab in \($0)") } ?? String(localized: "Switch to Tab")).font(.secondary).foregroundStyle(Theme.secondary)
            Text(sleeping ? String(localized: "Sleeping") : (URL(string: url)?.host() ?? "")).font(.secondary).foregroundStyle(Theme.secondary).lineLimit(1)
        case .space(_, let name, _):
            Text(name).font(.bodyStrong).foregroundStyle(Theme.primary).lineLimit(1)
            Text("Switch to Space").font(.secondary).foregroundStyle(Theme.secondary)
        case .command(_, let title):
            Text(title).font(.bodyStrong).foregroundStyle(Theme.primary).lineLimit(1)
            Text("Command").font(.secondary).foregroundStyle(Theme.secondary)
        case .bookmark(let url, let title), .visit(let url, let title):
            Text(title.isEmpty ? url : title).font(.bodyStrong).foregroundStyle(Theme.primary).lineLimit(1)
            Text(item.isBookmark ? String(localized: "Bookmark") : String(localized: "History")).font(.secondary).foregroundStyle(Theme.secondary)
            Text(URL(string: url)?.host() ?? url).font(.secondary).foregroundStyle(Theme.secondary).lineLimit(1)
        }
    }
}

private extension QuickFindItem {
    var isBookmark: Bool {
        if case .bookmark = self { return true }
        return false
    }
}
