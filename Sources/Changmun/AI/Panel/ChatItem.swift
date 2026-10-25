import AppKit
import SwiftUI

struct ChatItem: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case user, assistant, tool, error, note }
    var id = UUID()
    var kind: Kind
    var text: String
    /// For a tool step, the SF Symbol shown in its chip.
    var symbol: String? = nil
    /// For a tool step, the title the AI gave it: shown after `text` (what the app says), never in place of it.
    var title: String? = nil
    /// For the user's message, the pictures it went with (not kept in the history).
    var images: [ChatImage] = []
    /// For a tool step, the tool's name and how it went (nil until its result comes back).
    var tool: String? = nil
    var outcome: StepOutcome? = nil
    /// For an error, what went wrong in the user's terms; `text` keeps the words `claude` used.
    var failure: AIFailure? = nil
    /// For the user's message, the pages it went with when it was sent: the tab in front and the tabs attached.
    var pages: [AttachedPage] = []

    private enum CodingKeys: String, CodingKey { case kind, text, symbol, title, tool, outcome, failure, pages }

    init(kind: Kind, text: String, symbol: String? = nil, title: String? = nil, images: [ChatImage] = [], tool: String? = nil,
         outcome: StepOutcome? = nil, failure: AIFailure? = nil, pages: [AttachedPage] = []) {
        self.kind = kind
        self.text = text
        self.symbol = symbol
        self.title = title
        self.images = images
        self.tool = tool
        self.outcome = outcome
        self.failure = failure
        self.pages = pages
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        text = try values.decode(String.self, forKey: .text)
        symbol = try values.decodeIfPresent(String.self, forKey: .symbol)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        tool = try values.decodeIfPresent(String.self, forKey: .tool)
        outcome = try values.decodeIfPresent(StepOutcome.self, forKey: .outcome)
        failure = try values.decodeIfPresent(AIFailure.self, forKey: .failure)
        pages = try values.decodeIfPresent([AttachedPage].self, forKey: .pages) ?? []
    }
}

/// A page a message went with, as the card in the message shows it: its title and its site. Kept in the history as these two words and no
/// more (no address beyond the site, no icon).
struct AttachedPage: Codable, Equatable {
    var title: String
    var host: String
    /// While the tab is open, whose icon the card shows; not kept.
    var tabID: Int?

    private enum CodingKeys: String, CodingKey { case title, host }

    init(title: String, host: String, tabID: Int? = nil) {
        self.title = title
        self.host = host
        self.tabID = tabID
    }

    /// The cards for the tabs a message goes with, the one in front first: a tab without a site (a blank page) has no card, nor has one
    /// that is listed twice.
    @MainActor
    static func cards(front: Tab?, attached: [Tab]) -> [AttachedPage] {
        var seen = Set<Int>()
        return ([front].compactMap { $0 } + attached).compactMap { tab in
            guard seen.insert(tab.id).inserted, var host = tab.url?.host()?.lowercased(), !host.isEmpty else { return nil }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return AttachedPage(title: tab.displayTitle, host: host, tabID: tab.id)
        }
    }
}
