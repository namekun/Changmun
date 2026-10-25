import AppKit
import SwiftUI

/// A finished conversation as it is kept: what the user wrote, what the AI answered, its step titles and the errors. Nothing of the
/// pages beyond what the transcript itself shows.
struct StoredChat: Codable, Identifiable, Equatable {
    var id: UUID
    var started: Date
    var updated: Date
    var items: [ChatItem]

    /// The first thing the user wrote, on one line.
    var title: String {
        let first = items.first { $0.kind == .user }?.text ?? ""
        return String(first.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(80))
    }

    /// The conversation as text: what the user wrote quoted, the answers as written.
    var plainText: String {
        items.compactMap { item in
            switch item.kind {
            case .user: item.text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            case .assistant: item.text
            case .error, .note: item.text
            case .tool: nil
            }
        }.joined(separator: "\n\n")
    }
}

/// The conversations the AI panel keeps, newest first, in one JSON file in the profile's folder. The panel only reads them back; a chat
/// is never resumed from here, because the AI's session has no memory of what it was allowed to read.
@MainActor
final class ChatHistory: ObservableObject {
    nonisolated static let maxChats = 200
    static let shared = ChatHistory(file: Library.folder.appendingPathComponent("ai-chats.json"))

    @Published private(set) var chats: [StoredChat] = []
    /// The last write to the file failed: what is shown may not be what is on disk (a delete may not have taken).
    @Published private(set) var saveFailed = false
    private let file: URL
    private let limit: Int
    /// False when the file is there but couldn't be read, or couldn't be kept as it was before starting over: nothing is written over it.
    private var writable = true

    private struct Stored: Codable {
        var version = 1
        var chats: [StoredChat]

        init(chats: [StoredChat]) { self.chats = chats }

        /// Decodes the chats one by one: one that doesn't decode doesn't take the rest with it.
        var skipped = 0
        enum CodingKeys: String, CodingKey { case version, chats }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? values.decode(Int.self, forKey: .version)) ?? 1
            let all = try values.decode([Browser.Lossy<StoredChat>].self, forKey: .chats)
            chats = all.compactMap(\.value)
            skipped = all.count - chats.count
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(version, forKey: .version)
            try values.encode(chats, forKey: .chats)
        }
    }

    init(file: URL, limit: Int = ChatHistory.maxChats) {
        self.file = file
        self.limit = limit
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch Library.FileRead(file) {
        case .missing:
            break
        case .unreadable:
            writable = false
        case .data(let data):
            if let stored = try? decoder.decode(Stored.self, from: data) {
                chats = stored.chats
                if stored.skipped > 0 { writable = Library.keepDamaged(file) }
            } else {
                writable = Library.keepDamaged(file)
            }
        }
        Self.removeStaleTemporaries(beside: file)
    }

    static func removeStaleTemporaries(beside file: URL) { DurableFile.removeStaleTemporaries(beside: file) }

    /// Keeps the conversation (or replaces what was kept of it). A conversation with no message of the user is nothing to keep.
    func record(id: UUID, started: Date, items: [ChatItem], now: Date = Date()) {
        guard items.contains(where: { $0.kind == .user }) else { return }
        // Pictures are not kept: a message that had some says so instead.
        let kept = items.map { item -> ChatItem in
            guard !item.images.isEmpty else { return item }
            var item = item
            item.text += "\n[" + String(localized: "Images attached: \(item.images.count)") + "]"
            item.images = []
            return item
        }
        let chat = StoredChat(id: id, started: started, updated: now, items: kept.map(Self.persistable))
        if let index = chats.firstIndex(where: { $0.id == id }) { chats[index] = chat } else { chats.append(chat) }
        chats.sort { $0.updated > $1.updated }
        if chats.count > limit { chats.removeLast(chats.count - limit) }
        save()
    }

    func delete(_ id: UUID) {
        guard chats.contains(where: { $0.id == id }) else { return }
        chats.removeAll { $0.id == id }
        save()
    }

    func clear() {
        chats.removeAll()
        save()
        Self.removeStaleTemporaries(beside: file)
    }

    /// What is kept of a step: an address without its query and fragment (which carry what a page put in them, written with a scheme or
    /// not), and what was typed, chosen or waited for as only how long it was. The panel shows the whole step while the chat is open; this
    /// is what goes to the file.
    static func persistable(_ item: ChatItem) -> ChatItem {
        guard item.kind == .tool else { return item }
        var item = item
        if let separator = item.text.range(of: " · ") {
            let head = String(item.text[..<separator.lowerBound]), argument = item.text[separator.upperBound...]
            switch item.tool {
            case "type_text", "select_option":
                item.text = head + " · " + String(localized: "typed \(argument.count) characters")
            case "wait_for":
                item.text = head + " · " + String(localized: "\(argument.count) characters")
            case "navigate", "open_tab":
                item.text = head + " · " + String(argument.prefix { $0 != "?" && $0 != "#" })
            default: break
            }
        }
        item.text = strippingQueries(item.text)
        item.title = item.title.map(strippingQueries)
        return item
    }

    /// The text with every address cut before its "?" or "#": one with a scheme anywhere in it, and a bare one ("bank.com/login?…") that is a
    /// word of its own.
    static func strippingQueries(_ text: String) -> String {
        guard text.contains("?") || text.contains("#") else { return text }
        var result = text
        if let regex = try? NSRegularExpression(pattern: "https?://[^\\s\"”)]*", options: .caseInsensitive) {
            // From the end, so the places found first stay where they were.
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: result), let cut = result[range].firstIndex(where: { $0 == "?" || $0 == "#" }) else { continue }
                result.removeSubrange(cut..<range.upperBound)
            }
        }
        return result.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            guard let cut = word.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return String(word) }
            let before = word[..<cut]
            // Words like "What?" or "#3" are words; "bank.com/login?x" and "a.b#c" are addresses.
            return before.contains { $0 == "." || $0 == "/" } ? String(before) : String(word)
        }.joined(separator: " ")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard writable, let data = try? encoder.encode(Stored(chats: chats)) else { saveFailed = true; return }
        saveFailed = !Self.write(data, to: file)
    }

    static func write(_ data: Data, to file: URL) -> Bool { DurableFile.write(data, to: file) }
}
