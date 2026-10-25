import AppKit
import SwiftUI

// MARK: Views

/// The past chats of the panel, and one opened to read. Reading is all: to go on, the user starts a new chat.
struct ChatHistoryView: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var history: ChatHistory

    var body: some View {
        VStack(spacing: 0) {
            if history.saveFailed {
                Text("Couldn’t save chat history").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.waitingText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 6)
            }
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
            .foregroundStyle(prominent ? Theme.waitingText : Theme.primary)
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
