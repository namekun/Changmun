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
    @State private var selection = 0
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
    }

    /// Typing an address or words: open or search it, ask the AI, switch to a matching open tab, the engine's
    /// suggestions, then bookmarks and history. The local and remote parts arrive from `source` as they're ready.
    private var suggestions: [Suggestion] {
        let query = text.trimmingCharacters(in: .whitespaces)
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
                    TextField(browser.isPrivate ? String(localized: "Search or enter an address") : String(localized: "Search, enter an address or ask AI"), text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .focused($focused)
                        .onSubmit { run(items.indices.contains(selection) ? items[selection] : nil) }
                        .onChange(of: text) {
                            selection = 0
                            refresh()
                        }
                    Keycap("esc")
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                if !items.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            SuggestionRow(item: item, selected: index == selection)
                                .onTapGesture { run(item) }
                                .onHover { if $0 { selection = index } }
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
            refresh()
            NSApp.keyWindow?.makeFirstResponder(nil)
            DispatchQueue.main.async { focused = true }
        }
    }

    /// Another profile's favorites aren't suggested here: they belong to a space with logins of its own.
    private var hiddenFavorites: [String] {
        browser.spaces.spaces.filter { $0.isProfile && $0.id != browser.spaceID }.map(\.favoritesFolder)
    }

    /// Bookmarks for an empty field (or the current address, untouched); otherwise a search as the user types.
    private func refresh() {
        let query = text.trimmingCharacters(in: .whitespaces)
        if query.isEmpty || (mode == .editCurrent && query == browser.active?.url?.absoluteString) {
            source.update("", remote: false, hiding: hiddenFavorites)
        } else {
            source.update(text, remote: prefs.searchSuggestions && !browser.isPrivate, hiding: hiddenFavorites)
        }
    }

    /// Results arrive while the user moves through them: the highlight stays on the same row, wherever it went.
    private func keepSelection(_ old: [Suggestion], _ new: [Suggestion]) {
        if old.indices.contains(selection), let index = new.firstIndex(of: old[selection]) {
            selection = index
        } else {
            selection = 0
        }
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

struct SuggestionRow: View {
    let item: CommandBar.Suggestion
    let selected: Bool

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
