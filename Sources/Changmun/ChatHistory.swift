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
    private let file: URL
    private let limit: Int

    private struct Stored: Codable {
        var version = 1
        var chats: [StoredChat]
    }

    init(file: URL, limit: Int = ChatHistory.maxChats) {
        self.file = file
        self.limit = limit
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        chats = (try? Data(contentsOf: file)).flatMap { try? decoder.decode(Stored.self, from: $0) }?.chats ?? []
    }

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
        let chat = StoredChat(id: id, started: started, updated: now, items: kept)
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
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Stored(chats: chats)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

// MARK: Views

/// The past chats of the panel, and one opened to read. Reading is all: to go on, the user starts a new chat.
struct ChatHistoryView: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var history: ChatHistory

    var body: some View {
        if let id = chat.openedHistory, let stored = history.chats.first(where: { $0.id == id }) {
            ChatHistoryDetail(chat: stored, back: { chat.openedHistory = nil }, delete: {
                chat.openedHistory = nil
                history.delete(id)
            })
        } else {
            ChatHistoryList(chat: chat, history: history)
        }
    }
}

private struct HistoryAction: View {
    let title: String
    let symbol: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(prominent ? Theme.waiting : Theme.primary)
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(Theme.pill))
        }
        .buttonStyle(.plain)
    }
}

private struct ChatHistoryList: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var history: ChatHistory
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chat History").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                Spacer()
                if !history.chats.isEmpty && !confirmClear {
                    HistoryAction(title: String(localized: "Clear All"), symbol: "trash") { confirmClear = true }
                }
            }
            .padding(.horizontal, 6).padding(.top, 8)
            if confirmClear {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Delete all saved chats? This can't be undone.").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        HistoryAction(title: String(localized: "Cancel"), symbol: "xmark") { confirmClear = false }
                        HistoryAction(title: String(localized: "Delete All"), symbol: "trash", prominent: true) {
                            history.clear()
                            confirmClear = false
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.selected))
            }
            if history.chats.isEmpty {
                Text("No saved chats yet").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 6).padding(.top, 4)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(history.chats) { stored in
                        SavedChatRow(stored: stored, open: { chat.openedHistory = stored.id }, delete: { history.delete(stored.id) })
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

private struct SavedChatRow: View {
    let stored: StoredChat
    let open: () -> Void
    let delete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stored.title.isEmpty ? String(localized: "Untitled chat") : stored.title)
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                    Text(stored.updated.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: delete) {
                Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hover ? 1 : 0)
            .help("Delete this chat")
            .accessibilityLabel(Text("Delete this chat"))
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.hoverTab : .clear))
        .onHover { hover = $0 }
    }
}

private struct ChatHistoryDetail: View {
    let chat: StoredChat
    let back: () -> Void
    let delete: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button(action: back) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Text("Chat History").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.secondary)
                    .frame(height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                HistoryAction(title: copied ? String(localized: "Copied") : String(localized: "Copy All"), symbol: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(chat.plainText, forType: .string)
                    copied = true
                }
                HistoryAction(title: String(localized: "Delete"), symbol: "trash", prominent: true, action: delete)
            }
            .padding(.horizontal, 6).padding(.top, 8)
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text("Read-only — start a new chat to continue").font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.selected))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(ChatLayout.rows(chat.items, running: false)) { row in
                        ChatRowView(row: row, chat: nil, retrying: nil)
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
    }
}
