import SwiftUI

/// The other engines a search can go to just this once, under the search row: a click, or ⌘ and its number while the bar is open,
/// searches the words with that engine and leaves the default as it is. Each shows its keyword, which does the same typed before the words.
struct EngineChips: View {
    let engines: [QuickSearch.Engine]
    let pick: (QuickSearch.Engine) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("Search with").font(.secondary).foregroundStyle(Theme.secondary).padding(.trailing, 4).decorative()
            ForEach(Array(engines.prefix(9).enumerated()), id: \.element) { index, engine in
                Button { pick(engine) } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: engine.name).font(.secondary).foregroundStyle(Theme.primary)
                        if !engine.keyword.isEmpty { Text(verbatim: engine.keyword).font(.caption).foregroundStyle(Theme.tertiary) }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(Theme.field))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Search with \(engine.name) (⌘\(index + 1))"))
                .accessibilityLabel(String(localized: "Search with \(engine.name)"))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }
}

/// What the command bar's engine row offers while it is shown, for ⌘ and a number: the engines in order, the words, and where the search opens.
struct CommandBarChips: Equatable {
    let engines: [QuickSearch.Engine]
    let terms: String
    let mode: CommandBarMode
}

extension Browser {
    /// ⌘ and `number` while the command bar shows its engine row: that engine searches the words, in place of the tab ⌘number would show.
    /// False when the bar or the row isn't there, or has no engine at that number.
    func searchWithChip(number: Int) -> Bool {
        guard commandBar != nil, let chips = commandBarChips, chips.engines.prefix(9).indices.contains(number - 1),
              let url = AddressInput.searchURL(chips.terms, template: chips.engines[number - 1].template) else { return false }
        open(url.absoluteString, in: chips.mode)
        return true
    }
}
