import AppKit
import SwiftUI

// MARK: Command bar

struct CommandBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var chat: ChatStore
    @ObservedObject private var prefs = Preferences.shared
    var area = PageArea.window
    let mode: CommandBarMode
    @State private var text = ""
    /// What the field shows: `text` with the syllable an input method is still composing, which the binding doesn't hold until it is settled.
    /// The list, its first row and what Return and a click run all follow this; it is never written back into the field.
    @State private var shown = ""
    @State private var selection = 0
    /// Where the pointer last was when it moved, so that a list changing under a resting pointer doesn't count as the pointer moving.
    @State private var pointer = PointerMovement()
    @StateObject private var source = SuggestionSource()
    @FocusState private var focused: Bool

    enum Suggestion: Hashable {
        case open(String)
        case search(String)
        case suggested(String)
        case ask(String)
        /// `space` names the space it is in when that isn't the one shown.
        case tab(id: Int, url: String, title: String, space: String?)
        case page(url: String, title: String)

        /// The item as the row it makes is named: a tab by its number alone.
        var identity: Suggestion {
            if case .tab(let id, _, _, _) = self { return .tab(id: id, url: "", title: "", space: nil) }
            return self
        }
    }

    /// Typing an address or words: open or search it, ask the AI, switch to a matching open tab, the engine's
    /// suggestions, then bookmarks and history. The local and remote parts arrive from `source` as they're ready.
    private var suggestions: [Suggestion] {
        let query = shown.trimmingCharacters(in: .whitespaces)
        if query.isEmpty || (mode == .editCurrent && query == browser.active?.url?.absoluteString) {
            return source.pages.map { .page(url: $0.url, title: $0.title) }
        }
        var list: [Suggestion] = [AddressInput.isAddress(query) ? .open(query) : .search(query)]
        if !browser.isPrivate { list.append(.ask(query)) }
        // The tabs of this space first, then those of the others, each with its space's name.
        let others = browser.tabs.filter { $0.spaceID != browser.spaceID }
        let tabs = Self.matchingTabs(browser.spaceTabs.filter { $0.id != browser.activeID }, query) + Self.matchingTabs(others, query)
        list += tabs.prefix(3).map { .tab(id: $0.id, url: $0.url?.absoluteString ?? "", title: $0.displayTitle,
                                          space: $0.spaceID == browser.spaceID ? nil : browser.spaces.space($0.spaceID).name) }
        list += source.searches.prefix(4).map { .suggested($0) }
        let open = Set(tabs.compactMap { $0.url?.absoluteString })
        list += source.pages.filter { !open.contains($0.url) }.prefix(6).map { .page(url: $0.url, title: $0.title) }
        return list
    }

    /// The row Return runs: the highlighted one, none when the highlight is past the end of the list.
    static func chosen(_ items: [Suggestion], at selection: Int) -> Suggestion? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    /// What names a row: the item it holds, and which of two equal items it is. An open tab is named by the tab and not by its title and
    /// address, which change under the list while the page loads: the row stays the same row.
    struct RowID: Hashable {
        let item: Suggestion
        let copy: Int
    }

    static func rowIDs(_ items: [Suggestion]) -> [RowID] {
        var seen: [Suggestion: Int] = [:]
        return items.map { item in
            let item = item.identity
            let copy = seen[item, default: 0]
            seen[item] = copy + 1
            return RowID(item: item, copy: copy)
        }
    }

    /// Where the highlight goes when the list becomes `new`: on the row that was highlighted, wherever it is now, else on the first.
    static func keptSelection(_ selection: Int, old: [Suggestion], new: [Suggestion]) -> Int {
        guard old.indices.contains(selection) else { return 0 }
        let kept = old[selection].identity
        return new.firstIndex { $0.identity == kept } ?? 0
    }

    /// Open tabs whose title or address holds every word.
    static func matchingTabs(_ tabs: [Tab], _ query: String) -> [Tab] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        return tabs.filter { tab in
            let haystack = (tab.title + " " + (tab.customTitle ?? "") + " " + (tab.url?.absoluteString ?? "")).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        let items = suggestions
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: mode == .editCurrent ? "link" : "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .focused($focused)
                        // The list as it is when Return is pressed: the field keeps the handler it was given when its text last changed, so
                        // the `items` of that render would hold the rows from before the local and engine results came in.
                        .onSubmit { run(Self.chosen(suggestions, at: selection)) }
                        .onChange(of: text) { syncShown() }
                        .onChange(of: shown) {
                            selection = 0
                            refresh()
                        }
                        // Composing text reaches the field editor at once (and the binding only when it is settled).
                        // Only the bar's own field: the window has one editor for all its fields, and the find bar's or another field's
                        // typing must not become the words the list is for.
                        .onReceive(NotificationCenter.default.publisher(for: NSText.didChangeNotification)) { note in
                            if let editor = Self.ownEditor(note.object as? NSResponder, in: browser.window, placeholder: placeholder) {
                                shown = Self.shownText(editor: editor.string, binding: text)
                            }
                        }
                    Keycap("esc")
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                if !items.isEmpty {
                    VStack(spacing: 2) {
                        // A row is what it holds, not the place it is at: when the list changes under a press, the row pressed is the same
                        // view still (or gone), never another item's.
                        ForEach(Array(zip(Self.rowIDs(items), items).enumerated()), id: \.element.0) { index, row in
                            SuggestionRow(item: row.1, selected: index == selection) { run($0) }
                                .onContinuousHover(coordinateSpace: .global) { phase in
                                    if case .active(let point) = phase, pointer.moved(to: point) { selection = index }
                                }
                        }
                    }
                }
            }
            .padding(10)
            .frame(width: min(620, max(320, area.width - 32)))
            .floatingPanel(radius: 16)
            .padding(.top, 96)
            .padding(.leading, area.leading)
            .padding(.trailing, area.trailing)
            .onKeyPress(.downArrow) { selection = max(0, min(selection + 1, items.count - 1)); return .handled }
            .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
            .onKeyPress(.escape) { dismiss(); return .handled }
        }
        .onChange(of: items) { old, new in keepSelection(old, new) }
        .onAppear {
            text = mode == .editCurrent ? (browser.active?.url?.absoluteString ?? "") : ""
            shown = text
            refresh()
            browser.window?.makeFirstResponder(nil)
            DispatchQueue.main.async { focused = true }
        }
    }

    /// What the field shows: the field editor's own text while it has the focus, composing text and all, else the binding.
    static func shownText(editor: String?, binding: String) -> String { editor ?? binding }

    /// What the field says while it is empty, which is also what tells it from the other fields of the window.
    private var placeholder: String {
        browser.isPrivate ? String(localized: "Search or enter an address") : String(localized: "Search, enter an address or ask AI")
    }

    /// `responder` if it is the editor of the bar's own field in `window`: the one editor a window has is lent to whichever field has the
    /// focus (the find bar's, a page's), and only while the bar's field (the one with this placeholder) is the one it serves is it the bar's.
    static func ownEditor(_ responder: NSResponder?, in window: NSWindow?, placeholder: String) -> NSTextView? {
        guard let editor = responder as? NSTextView, editor.isFieldEditor, window != nil, editor.window === window,
              (editor.delegate as? NSTextField)?.placeholderString == placeholder else { return nil }
        return editor
    }

    /// The field's editor while the field has the focus.
    private var fieldEditor: NSTextView? {
        Self.ownEditor(browser.window?.firstResponder, in: browser.window, placeholder: placeholder)
    }

    private func syncShown() {
        shown = Self.shownText(editor: fieldEditor?.string, binding: text)
    }

    /// Another profile's favorites aren't suggested here: they belong to a space with logins of its own.
    private var hiddenFavorites: [String] {
        browser.spaces.spaces.filter { $0.isProfile && $0.id != browser.spaceID }.map(\.favoritesFolder)
    }

    /// Bookmarks for an empty field (or the current address, untouched); otherwise a search as the user types.
    private func refresh() {
        let query = shown.trimmingCharacters(in: .whitespaces)
        if query.isEmpty || (mode == .editCurrent && query == browser.active?.url?.absoluteString) {
            source.update("", remote: false, hiding: hiddenFavorites)
        } else {
            source.update(shown, remote: prefs.searchSuggestions && !browser.isPrivate, hiding: hiddenFavorites)
        }
    }

    /// Results arrive while the user moves through them: the highlight stays on the same row, wherever it went.
    private func keepSelection(_ old: [Suggestion], _ new: [Suggestion]) {
        selection = Self.keptSelection(selection, old: old, new: new)
    }

    private func dismiss() {
        browser.commandBar = nil
    }

    private func run(_ item: Suggestion?) {
        switch item {
        case .open(let input), .search(let input), .suggested(let input):
            browser.open(input, in: mode)
        case .tab(let id, _, _, _):
            browser.activate(id)
            browser.commandBar = nil
        case .ask(let question):
            browser.commandBar = nil
            browser.showChat = true
            // Without the AI there is nothing to send to: the panel shows what is missing instead of a message that can only fail.
            chat.refreshAvailability()
            if chat.availability == .ready { chat.send(question) } else { chat.say(String(localized: "The AI panel needs Claude Code, so your question wasn't sent.")) }
        case .page(let url, _):
            browser.open(url, in: mode)
        case nil:
            break
        }
    }
}

/// Whether the pointer moved. A list that changes under a resting pointer makes the row now below it "hovered" without any movement,
/// and that must not take the highlight (and with it what Return runs) from where the user put it.
struct PointerMovement {
    private var last: CGPoint?

    /// True when `point` is not where the pointer was last seen. The first sighting only notes the place.
    mutating func moved(to point: CGPoint) -> Bool {
        defer { last = point }
        guard let last else { return false }
        return last != point
    }
}

/// A click on a row: the item it went down on is the one it runs, if it comes up on the row still, whatever the list has become between.
/// Results arrive, and an input method that was composing a syllable settles it as the mouse goes down, so the list under the pointer can change
/// before the click is done.
struct RowPress<Item: Equatable> {
    private(set) var item: Item?

    mutating func began(on current: Item) {
        if item == nil { item = current }
    }

    mutating func ended(inside: Bool) -> Item? {
        defer { item = nil }
        return inside ? item : nil
    }
}

struct SuggestionRow: View {
    let item: CommandBar.Suggestion
    let selected: Bool
    let run: (CommandBar.Suggestion) -> Void
    @State private var press = RowPress<CommandBar.Suggestion>()
    @State private var size = CGSize.zero

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 20)
            label
            Spacer(minLength: 0)
            if selected { Keycap("↵") }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background { if selected { SelectedBackground() } }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in press.began(on: item) }
            .onEnded { value in
                if let pressed = press.ended(inside: CGRect(origin: .zero, size: size).contains(value.location)) { run(pressed) }
            })
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .open: Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
        case .search, .suggested: Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
        case .tab(_, let url, _, _): SiteIcon(url: url, size: 16)
        case .ask: Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
        case .page(let url, _): SiteIcon(url: url, size: 16)
        }
    }

    @ViewBuilder private var label: some View {
        switch item {
        case .open(let text):
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
        case .search(let text):
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
            Text("Search").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint)
        case .suggested(let text):
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
        case .tab(_, let url, let title, let space):
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
            Text(space.map { String(localized: "Switch to Tab in \($0)") } ?? String(localized: "Switch to Tab")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint)
            Text(URL(string: url)?.host() ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1)
        case .ask(let text):
            Text("Ask AI").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
        case .page(let url, let title):
            Text(title.isEmpty ? url : title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
            Text(URL(string: url)?.host() ?? url).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1)
        }
    }
}
