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

    private enum CodingKeys: String, CodingKey { case kind, text, symbol, title, tool, outcome, failure }
}
