import AppKit
import SwiftUI

/// What the panel's head calls the chat: the first thing the user wrote, on one line and cut short.
enum ChatTitle {
    static let limit = 40

    /// `first` is the user's first message (or nil/empty before there is one: "New chat").
    static func text(first: String?, limit: Int = limit) -> String {
        let line = (first ?? "").split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return String(localized: "New chat") }
        guard line.count > limit else { return line }
        return String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func text(of items: [ChatItem]) -> String {
        text(first: items.first { $0.kind == .user }?.text)
    }
}

/// The panel's head: the chat's title with the menu of recent chats, and the buttons for a new chat, for popping the panel out into a
/// window (or docking it back) and for closing it.
struct ChatHeader: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var history: ChatHistory
    @ObservedObject var browser: Browser
    /// The panel is in its own window.
    let inWindow: Bool
    let close: () -> Void

    /// Chats of the menu: the latest ones other than the one on screen.
    static let recentCount = 8

    private var title: String {
        if chat.showHistory {
            return chat.openedHistory.flatMap { id in history.chats.first { $0.id == id } }.map { ChatTitle.text(first: $0.title) } ?? String(localized: "Chat History")
        }
        return ChatTitle.text(of: chat.items)
    }

    var body: some View {
        HStack(spacing: 4) {
            titleMenu
            Spacer(minLength: 0)
            BarButton(symbol: "square.and.pencil", help: String(localized: "New Chat (⌘⇧E)")) { chat.reset() }
            if inWindow {
                BarButton(symbol: "arrow.down.left.square", help: String(localized: "Dock back in the browser window")) { ChatPopOut.shared.close(dock: true) }
            } else {
                BarButton(symbol: "arrow.up.right.square", help: String(localized: "Open in its own window")) { ChatPopOut.shared.open(for: browser) }
            }
            BarButton(symbol: "xmark", help: String(localized: "Close (⌘E)"), action: close)
        }
        .padding(.horizontal, 6)
        // In its own window the title starts past the window buttons, and the empty part of the row moves the window.
        .padding(.leading, inWindow ? BrowserWindow.windowButtonsTrailing - Metrics.inset - 6 : 0)
        // Level with the page card's bar beside it.
        .frame(height: BrowserWindow.pageBarHeight)
        .background { if inWindow { WindowDragArea() } }
    }

    private var titleMenu: some View {
        Menu {
            if chat.showHistory {
                Button("Back to Chat", systemImage: "arrow.uturn.backward") {
                    chat.showHistory = false
                    chat.openedHistory = nil
                }
                Divider()
            }
            let recent = history.chats.filter { $0.id != chat.recordID }.prefix(Self.recentCount)
            if !recent.isEmpty {
                Section("Recent Chats") {
                    ForEach(recent) { stored in
                        Button(ChatTitle.text(first: stored.title)) {
                            chat.showHistory = true
                            chat.openedHistory = stored.id
                        }
                    }
                }
            }
            Button("Show All Chats", systemImage: "clock.arrow.circlepath") {
                chat.showHistory = true
                chat.openedHistory = nil
            }
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 6)
            .frame(height: Metrics.control)
            .contentShape(Rectangle())
        }
        .plainMenu(fixed: false)
        .help("Recent Chats")
        .accessibilityLabel(Text("Chat: \(title)"))
    }
}
