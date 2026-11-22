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
    /// What the user typed of `shown`, which the list is for: the field may show the rest of a site's name filled in after it.
    @State private var typed = TypedText()
    /// How the field's text was last changed, until that change reaches `shown` (`CommandBar.edit`).
    @State private var edit: TypedText.Edit?
    @State private var selection = 0
    /// Where the pointer last was when it moved, so that a list changing under a resting pointer doesn't count as the pointer moving.
    @State private var pointer = PointerMovement()
    @StateObject private var source = SuggestionSource()
    @ObservedObject private var sites = SiteStore.shared
    @FocusState private var focused: Bool
    @State private var announceTask: Task<Void, Never>?

    enum Suggestion: Hashable {
        /// The site whose name what is typed is the start of (`SiteIndex`): first, so that Return opens it. A row of its own and not a `page`,
        /// so that the highlight on it never moves to the same page further down when it stops being the top hit.
        case top(url: String, title: String)
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
        Self.suggestions(shown: typed.words, pages: source.pages, searches: source.searches, browser: browser, mode: mode,
                         top: Self.topHit(typed, browser: browser) { sites.hit(for: $0, history: $1, hiding: $2) }, topFirst: !typed.pasted)
    }

    /// The list for what is typed, which the start page's search field shares: `pages` and `searches` are what the suggestion source has found,
    /// `top` the site whose name it is the start of (see `topHit`): first, or after the search for words that were pasted (as they were
    /// before; nothing is filled in after them either).
    static func suggestions(shown: String, pages: [Library.Entry], searches: [String], browser: Browser, mode: CommandBarMode,
                            top: SiteIndex.Site? = nil, topFirst: Bool = true) -> [Suggestion] {
        let query = shown.trimmingCharacters(in: .whitespaces)
        if query.isEmpty || (mode == .editCurrent && query == browser.active?.url?.absoluteString) {
            return pages.map { .page(url: $0.url, title: $0.title) }
        }
        var list: [Suggestion] = [AddressInput.isAddress(query) ? .open(query) : .search(query)]
        if let top { list.insert(.top(url: top.url, title: top.title), at: topFirst ? 0 : 1) }
        if !browser.isPrivate { list.append(.ask(query)) }
        // The tabs of this space first, then those of the others, each with its space's name.
        let others = browser.tabs.filter { $0.spaceID != browser.spaceID }
        let tabs = Self.matchingTabs(browser.spaceTabs.filter { $0.id != browser.activeID }, query) + Self.matchingTabs(others, query)
        list += tabs.prefix(3).map { .tab(id: $0.id, url: $0.url?.absoluteString ?? "", title: $0.displayTitle,
                                          space: $0.spaceID == browser.spaceID ? nil : browser.spaces.space($0.spaceID).name) }
        list += searches.prefix(4).map { .suggested($0) }
        let open = Set(tabs.compactMap { $0.url?.absoluteString } + [top?.url].compactMap { $0 })
        list += pages.filter { !open.contains($0.url) }.prefix(6).map { .page(url: $0.url, title: $0.title) }
        return list
    }

    /// The site to put first for what is typed, found by `hit` (`SiteIndex.hit`): none after a deletion (the user just took the filled-in
    /// name away, and Return then does what the field shows), and none from the history in a private window. While the field shows the
    /// name filled in, the site's front page: Return opens what the field shows, not one of the site's pages.
    static func topHit(_ typed: TypedText, browser: Browser, in hit: (String, Bool, [String]) -> SiteIndex.Site?) -> SiteIndex.Site? {
        guard !typed.deleting, let site = hit(typed.words, !browser.isPrivate, hiddenFavorites(browser)) else { return nil }
        return typed.completed == nil ? site : site.frontPage
    }

    /// Fills in `rest`, the rest of the top hit's name, after what the editor holds, selected: the next letter typed replaces it, Delete takes it
    /// away, and → or End keeps it. As if typed (the field's text is all of it), so that the field and its binding never disagree.
    /// Returns whether it was filled in.
    @discardableResult static func fill(_ editor: NSTextView, with rest: String) -> Bool {
        let end = NSRange(location: (editor.string as NSString).length, length: 0)
        guard editor.shouldChangeText(in: end, replacementString: rest) else { return false }
        editor.replaceCharacters(in: end, with: rest)
        editor.didChangeText()
        editor.setSelectedRange(NSRange(location: end.location, length: (rest as NSString).length))
        return true
    }

    /// Whether the filled-in name is no longer what is selected (→, End, a click moved the caret): it is kept then, as if typed.
    static func movedOff(_ editor: NSTextView, _ typed: TypedText) -> Bool {
        guard let full = typed.completed, editor.string == full else { return false }
        let start = (typed.words as NSString).length
        return editor.selectedRange() != NSRange(location: start, length: (full as NSString).length - start)
    }

    /// What an edit of the field's text did, read from its editor's storage as it is made: whether it put characters in or only took some
    /// out tells typing over a selection (⌘L's address, all of it selected, replaced by "h") from deleting, which the text before and after
    /// alone can't. Characters put in by ⌘V, or from a menu or a drop (the mouse), were pasted.
    static func edit(_ storage: NSTextStorage, event: NSEvent?) -> TypedText.Edit? {
        guard storage.editedMask.contains(.editedCharacters) else { return nil }
        guard storage.editedRange.length > 0 else { return storage.changeInLength < 0 ? .deleted : nil }
        // Only an event of this moment says how: one handled earlier stays the app's current event.
        guard let event, ProcessInfo.processInfo.systemUptime - event.timestamp < 1 else { return .typed }
        switch event.type {
        case .keyDown: return event.modifierFlags.contains(.command) ? .pasted : .typed
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged: return .pasted
        default: return .typed
        }
    }

    /// Whether the rest of a name may be filled in after `words` now: the editor still holds just them (no later letter has come), with the caret
    /// at their end, and no input method is composing (a Korean syllable is not finished).
    static func mayFill(_ editor: NSTextView, after words: String) -> Bool {
        editor.string == words && !editor.hasMarkedText() && editor.selectedRange() == NSRange(location: (words as NSString).length, length: 0)
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
            Theme.scrim
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: mode == .editCurrent ? "link" : "magnifyingglass")
                        .font(.symbolToolbar)
                        .foregroundStyle(Theme.secondary)
                        .decorative()
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .font(.heading)
                        .foregroundStyle(Theme.primary)
                        .focused($focused)
                        .accessibilityLabel(mode == .editCurrent ? String(localized: "Address") : placeholder)
                        .accessibilityHint(String(localized: "Type to see suggestions. Use the up and down arrow keys to choose one, and Return to open it"))
                        // The list as it is when Return is pressed: the field keeps the handler it was given when its text last changed, so
                        // the `items` of that render would hold the rows from before the local and engine results came in.
                        .onSubmit { submit(command: NSEvent.modifierFlags.contains(.command)) }
                        .onChange(of: text) { syncShown() }
                        .onChange(of: shown) { old, new in
                            defer { edit = nil }
                            // The filled-in name arriving is not new typing: the list stays that of the words.
                            guard typed.changed(from: old, to: new, by: edit) else { return }
                            selection = 0
                            refresh()
                            completeInline()
                        }
                        // How the field's text is being changed, said by its editor's storage before the change reaches `shown`.
                        .onReceive(NotificationCenter.default.publisher(for: NSTextStorage.didProcessEditingNotification)) { note in
                            if let storage = note.object as? NSTextStorage, let editor = fieldEditor, editor.textStorage === storage {
                                edit = Self.edit(storage, event: NSApp.currentEvent)
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { note in
                            if let editor = Self.ownEditor(note.object as? NSResponder, in: browser.window, placeholder: placeholder),
                               Self.movedOff(editor, typed) {
                                keepCompletion()
                            }
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
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .frame(height: 46)
                .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Theme.field))
                if !items.isEmpty {
                    VStack(spacing: 4) {
                        // A row is what it holds, not the place it is at: when the list changes under a press, the row pressed is the same
                        // view still (or gone), never another item's.
                        ForEach(Array(zip(Self.rowIDs(items), items).enumerated()), id: \.element.0) { index, row in
                            SuggestionRow(item: row.1, selected: index == selection) { run($0) }
                                .onContinuousHover(coordinateSpace: .global) { phase in
                                    if case .active(let point) = phase, pointer.moved(to: point) { selection = index }
                                }
                            if case .search = row.1, let chips = chips(for: items) {
                                EngineChips(engines: chips.engines) { engine in
                                    if let url = AddressInput.searchURL(chips.terms, template: engine.template) {
                                        browser.open(url.absoluteString, in: NSEvent.modifierFlags.contains(.command) ? .newTab : mode)
                                    }
                                }
                            }
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
            // What is behind the bar is not for a screen reader to wander into while it is open.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Search"))
            .accessibilityAddTraits(.isModal)
            .onKeyPress(.downArrow) { selection = max(0, min(selection + 1, items.count - 1)); return .handled }
            .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
            .onKeyPress(.escape) { dismiss(); return .handled }
            // End keeps the filled-in name as → does (which the field does by itself): the caret goes after it.
            .onKeyPress(.end) {
                guard typed.completed != nil, let editor = fieldEditor else { return .ignored }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                return .handled
            }
            // ⌘Return: in a new tab, whatever the bar would do.
            .onKeyPress(.return) {
                guard NSEvent.modifierFlags.contains(.command) else { return .ignored }
                return submit(command: true) ? .handled : .ignored
            }
        }
        .onChange(of: items) { old, new in keepSelection(old, new) }
        .onChange(of: chips(for: items), initial: true) { _, chips in browser.commandBarChips = chips }
        // The number of suggestions is said once the typing pauses, not at every letter.
        .onChange(of: items.count) { _, count in
            announceTask?.cancel()
            announceTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                if !Task.isCancelled { Announcer.announce(Accessibility.resultsCount(count), whileTyping: true) }
            }
        }
        .onDisappear {
            announceTask?.cancel()
            // The keyboard goes back to the page it was on before the bar opened, unless something else (the find bar, another field) has it by now.
            DispatchQueue.main.async {
                guard let window = browser.window, window.firstResponder == nil || window.firstResponder === window, browser.commandBar == nil,
                      !browser.findBarVisible, !browser.showOnboarding, let page = browser.active?.webView, page.window === window else { return }
                window.makeFirstResponder(page)
            }
        }
        .onAppear {
            text = mode == .editCurrent ? (browser.active?.url?.absoluteString ?? "") : ""
            shown = text
            typed = TypedText(text)
            refresh()
            sites.load()
            browser.window?.makeFirstResponder(nil)
            DispatchQueue.main.async { focused = true }
        }
    }

    /// The engine row under the search row: the other engines the words can go to just this once, none for an address or an empty field.
    private func chips(for items: [Suggestion]) -> CommandBarChips? {
        guard let query = items.lazy.compactMap({ if case .search(let query) = $0 { query } else { nil } }).first else { return nil }
        let builtIns = SearchEngine.listed(removed: prefs.removedSearchEngines)
        let routed = SearchRouting.pick(query, default: AddressInput.searchTemplate, engines: prefs.customSearchEngines)
        let engines = QuickSearch.chips(besides: routed.template, custom: prefs.customSearchEngines, builtIns: builtIns)
        return engines.isEmpty ? nil : CommandBarChips(engines: engines, terms: routed.terms, mode: mode)
    }

    /// What the field shows: the field editor's own text while it has the focus, composing text and all, else the binding.
    static func shownText(editor: String?, binding: String) -> String { editor ?? binding }

    /// What the field says while it is empty, which is also what tells it from the other fields of the window.
    private var placeholder: String {
        browser.isPrivate ? String(localized: "Search or enter an address") : String(localized: "Search, enter an address or ask AI")
    }

    /// `responder` if it is the editor of the bar's own field in `window`: the one editor a window has is lent to whichever field has the
    /// focus (the find bar's, a page's), and only while the bar's field (the one with this placeholder) is the one it serves is it the bar's.
    ///
    /// Why the placeholder: SwiftUI's TextField gives no handle on the NSTextField behind it. An `accessibilityIdentifier` does not reach it
    /// (tried: the field's identifier reads empty, and the Korean-composition check of scripts/test-command-bar.sh fails). Remembering
    /// the editor the focus callback finds would depend on the order SwiftUI sets the first responder and reports the focus in, and a
    /// wrong guess would read another field. So the check fails safe: a field whose placeholder can't be read (none, or an attributed
    /// one), or an empty one asked for, is nobody's, and the list then goes by the binding's text, never by another field's.
    static func ownEditor(_ responder: NSResponder?, in window: NSWindow?, placeholder: String) -> NSTextView? {
        guard !placeholder.isEmpty, let editor = responder as? NSTextView, editor.isFieldEditor, window != nil, editor.window === window,
              let shown = (editor.delegate as? NSTextField)?.placeholderString, shown == placeholder else { return nil }
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
    static func hiddenFavorites(_ browser: Browser) -> [String] {
        browser.spaces.spaces.filter { $0.isProfile && $0.id != browser.spaceID }.map(\.favoritesFolder)
    }

    private var hiddenFavorites: [String] { Self.hiddenFavorites(browser) }

    /// Bookmarks for an empty field (or the current address, untouched); otherwise a search as the user types.
    private func refresh() {
        let query = typed.words.trimmingCharacters(in: .whitespaces)
        if query.isEmpty || (mode == .editCurrent && query == browser.active?.url?.absoluteString) {
            source.update("", remote: false, hiding: hiddenFavorites)
        } else {
            source.update(typed.words, remote: prefs.searchSuggestions && !browser.isPrivate, hiding: hiddenFavorites, history: !browser.isPrivate)
        }
    }

    /// Typing forward fills in the rest of the top hit's name, once this change has been handled and if no other letter has come since.
    /// Not after a paste. The name is marked filled in once it is there: the selection moving on its way in is not the user keeping it.
    private func completeInline() {
        guard !typed.pasted, let site = Self.topHit(typed, browser: browser, in: { sites.hit(for: $0, history: $1, hiding: $2) }),
              let rest = SiteIndex.completion(of: typed.words, to: site) else { return }
        let words = typed.words
        DispatchQueue.main.async {
            guard typed.words == words, typed.completed == nil, let editor = fieldEditor, Self.mayFill(editor, after: words),
                  Self.fill(editor, with: rest) else { return }
            typed.complete(to: editor.string)
        }
    }

    /// The filled-in name kept: the list becomes that of the whole name, as typed.
    private func keepCompletion() {
        guard typed.keep() else { return }
        selection = 0
        refresh()
    }

    /// Results arrive while the user moves through them: the highlight stays on the same row, wherever it went.
    private func keepSelection(_ old: [Suggestion], _ new: [Suggestion]) {
        selection = Self.keptSelection(selection, old: old, new: new)
    }

    private func dismiss() {
        browser.commandBar = nil
    }

    private func run(_ item: Suggestion?) {
        Self.run(item, browser: browser, chat: chat, mode: mode)
    }

    /// Where Return opens the row: in the bar's own place, in a new tab with ⌘ held, nowhere while an input method is still composing
    /// (that Return only settles the syllable).
    static func returnMode(command: Bool, composing: Bool, mode: CommandBarMode) -> CommandBarMode? {
        guard !composing else { return nil }
        return command ? .newTab : mode
    }

    /// Opens the highlighted row. Whichever of the field's submit and the key press comes first closes the bar, so the other finds it gone.
    @discardableResult private func submit(command: Bool) -> Bool {
        guard browser.commandBar != nil,
              let route = Self.returnMode(command: command, composing: fieldEditor?.hasMarkedText() == true, mode: mode),
              let item = Self.chosen(suggestions, at: selection) else { return false }
        Self.run(item, browser: browser, chat: chat, mode: route)
        return true
    }

    /// What Return or a click does with a row, which the start page's search field shares.
    static func run(_ item: Suggestion?, browser: Browser, chat: ChatStore, mode: CommandBarMode) {
        switch item {
        case .open(let input), .search(let input), .suggested(let input):
            browser.open(input, in: mode)
        case .top(let url, _):
            browser.open(url, in: mode)
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

/// What the user typed into a field, apart from the rest of a site's name the field filled in after it (`CommandBar.fill`).
struct TypedText: Equatable {
    /// The user's own words, which the list is for.
    private(set) var words: String
    /// The whole field while it shows a filled-in name: the words and the rest of the name.
    private(set) var completed: String?
    /// The last change only took letters out (Delete, Backspace, the filled-in name deleted): nothing is filled in then, and the
    /// first row is what the field shows, not the site the user just took away.
    private(set) var deleting = false
    /// The words were pasted: nothing is filled in after them, and the search for them stays the first row, as before.
    private(set) var pasted = false

    /// How the field's text was changed (`CommandBar.edit`).
    enum Edit { case typed, deleted, pasted }

    init(_ words: String = "") { self.words = words }

    /// The field went from showing `old` to `new`, by `edit` when the field's editor said how. False when `new` is the filled-in name
    /// arriving, which changes nothing the list is for.
    mutating func changed(from old: String, to new: String, by edit: Edit? = nil) -> Bool {
        if new == completed { return false }
        // Not said (the text set from outside the editor): taking letters off the end leaves the start of what was there; a letter typed over
        // the filled-in part ("h" over "git|hub.com") does too, but goes on from the words.
        let edit = edit ?? (new != old && old.hasPrefix(new) && !(completed != nil && new.count > words.count) ? .deleted : .typed)
        deleting = edit == .deleted && new != old
        pasted = edit == .pasted
        words = new
        completed = nil
        return true
    }

    mutating func complete(to full: String) { completed = full }

    /// The filled-in name is kept (→, End, a click in the field): it is what was typed from now on, and Backspace takes a letter off it
    /// rather than bringing it back. Returns whether there was one.
    mutating func keep() -> Bool {
        guard let completed else { return false }
        words = completed
        self.completed = nil
        deleting = false
        pasted = false
        return true
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
    /// False on the start page: its list shows the icons that are kept and asks no site for one.
    var fetchesIcons = true
    let run: (CommandBar.Suggestion) -> Void
    @State private var press = RowPress<CommandBar.Suggestion>()
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
        .accessibleButton(Accessibility.suggestionLabel(kind), value: Accessibility.suggestionValue(kind), hint: selected ? String(localized: "Return opens it") : nil, selected: selected) { run(item) }
    }

    private var kind: Accessibility.SuggestionKind {
        switch item {
        case .open(let text): .open(text)
        case .search(let text), .suggested(let text): .search(text)
        case .ask(let text): .ask(text)
        case .tab(_, let url, let title, let space): .tab(title: title, host: URL(string: url)?.host() ?? "", space: space)
        case .page(let url, let title), .top(let url, let title): .page(title: title, host: URL(string: url)?.host() ?? url)
        }
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .open: Image(systemName: "arrow.up.right").font(.symbolToolbar).foregroundStyle(Theme.secondary)
        case .search, .suggested: Image(systemName: "magnifyingglass").font(.symbolToolbar).foregroundStyle(Theme.secondary)
        case .tab(_, let url, _, _): SiteIcon(url: url, size: 16, fetches: fetchesIcons)
        case .ask: Image(systemName: "sparkles").font(.symbolToolbar).foregroundStyle(Theme.primary)
        case .page(let url, _), .top(let url, _): SiteIcon(url: url, size: 16, fetches: fetchesIcons)
        }
    }

    @ViewBuilder private var label: some View {
        switch item {
        case .open(let text):
            Text(text).font(.bodyStrong).foregroundStyle(Theme.primary).lineLimit(1)
        case .search(let text):
            Text(text).font(.bodyStrong).foregroundStyle(Theme.primary).lineLimit(1)
            Text("Search").font(.secondary).foregroundStyle(Theme.secondary)
        case .suggested(let text):
            Text(text).font(.bodyStrong).foregroundStyle(Theme.primary).lineLimit(1)
        case .tab(_, let url, let title, let space):
            Text(title).font(.bodyStrong).foregroundStyle(Theme.primary).lineLimit(1)
            Text(space.map { String(localized: "Switch to Tab in \($0)") } ?? String(localized: "Switch to Tab")).font(.secondary).foregroundStyle(Theme.secondary)
            Text(URL(string: url)?.host() ?? "").font(.secondary).foregroundStyle(Theme.secondary).lineLimit(1)
        case .ask(let text):
            Text("Ask AI").font(.bodyStrong).foregroundStyle(Theme.secondary)
            Text(text).font(.bodyStrong).foregroundStyle(Theme.primary).lineLimit(1)
        case .page(let url, let title), .top(let url, let title):
            Text(title.isEmpty ? url : title).font(.bodyStrong).foregroundStyle(Theme.primary).lineLimit(1)
            Text(URL(string: url)?.host() ?? url).font(.secondary).foregroundStyle(Theme.secondary).lineLimit(1)
        }
    }
}
