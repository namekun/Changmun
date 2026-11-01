import Foundation

/// What translation with Claude that nobody asked for (a kept site's pages as they open, the text they add) may send for one site in
/// any ten minutes, in all tabs together: a page that reloads itself, or goes to new addresses by itself, starts each page with all of the
/// page's allowance, and this is what holds it. Only what the clock says is counted; nothing is stored.
struct ClaudeWindow: Equatable {
    nonisolated static let span: TimeInterval = 600
    nonisolated static let maxCharacters = 300_000
    nonisolated static let maxBatches = 120

    private struct Spend: Equatable {
        var at: Date
        var characters: Int
        var batches: Int
    }

    private var spends: [String: [Spend]] = [:]
    private var told: [String: Date] = [:]

    /// What is left for the site at `now`.
    func remaining(for site: String, at now: Date) -> (characters: Int, batches: Int) {
        let recent = (spends[site] ?? []).filter { now.timeIntervalSince($0.at) < Self.span }
        return (max(Self.maxCharacters - recent.reduce(0) { $0 + $1.characters }, 0), max(Self.maxBatches - recent.reduce(0) { $0 + $1.batches }, 0))
    }

    mutating func record(characters: Int, batches: Int, for site: String, at now: Date) {
        guard characters > 0 || batches > 0 else { return }
        spends[site] = (spends[site] ?? []).filter { now.timeIntervalSince($0.at) < Self.span } + [Spend(at: now, characters: characters, batches: batches)]
    }

    /// Whether the site's allowance is used up at `now`: nothing automatic goes to Claude.
    func isUsedUp(_ site: String, at now: Date) -> Bool {
        let left = remaining(for: site, at: now)
        return left.characters <= 0 || left.batches <= 0
    }

    /// True once for a site in each window: the user is told once that it is paused, not at every page.
    mutating func tellsPaused(_ site: String, at now: Date) -> Bool {
        if let before = told[site], now.timeIntervalSince(before) < Self.span { return false }
        told[site] = now
        return true
    }
}

/// The window all tabs share, with the clock it goes by (tests put their own).
@MainActor
final class AutomaticClaude {
    static let shared = AutomaticClaude()

    var window = ClaudeWindow()
    var now: () -> Date = { Date() }

    /// The key of a site: its host without "www.".
    static func site(of host: String?) -> String? { host.flatMap { $0.isEmpty ? nil : Preferences.siteKey($0) } }
}

extension ClaudeTranslation.Budget {
    /// The page's allowance as it is for a run that may send no more than `characters` and `batches`: the page's own, or what is left in the
    /// window, whichever is less; and whether it was the window that is the less.
    func narrowed(toCharacters characters: Int, batches: Int) -> (budget: ClaudeTranslation.Budget, byWindow: Bool) {
        let roomCharacters = max(ClaudeTranslation.maxPageCharacters - self.characters, 0)
        let roomBatches = max(ClaudeTranslation.maxBatches - self.batches, 0)
        var narrowed = self
        narrowed.characters = ClaudeTranslation.maxPageCharacters - min(roomCharacters, characters)
        narrowed.batches = ClaudeTranslation.maxBatches - min(roomBatches, batches)
        return (narrowed, characters < roomCharacters || batches < roomBatches)
    }

    /// What was spent after `earlier`.
    func spent(since earlier: ClaudeTranslation.Budget) -> (characters: Int, batches: Int) {
        (max(characters - earlier.characters, 0), max(batches - earlier.batches, 0))
    }
}
