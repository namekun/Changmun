import AppKit
import SwiftUI

/// One row of the transcript, whatever it is made of.
struct ChatRowView: View {
    let row: ChatRowModel
    /// The panel's chat; nil for a saved chat, which can be neither retried nor have its tabs reopened.
    var chat: ChatStore?
    /// The error row that can be tried again: the last one, when nothing is running.
    var retrying: UUID?

    var body: some View {
        switch row {
        case .item(let item):
            ChatRow(item: item, retry: item.id == retrying ? { chat?.retryLast() } : nil)
        case .live, .folded:
            ChatStepsRow(row: row)
        case .summary(let summary):
            TurnSummaryRow(summary: summary, chat: chat)
        }
    }
}

struct ChatRow: View {
    let item: ChatItem
    var retry: (() -> Void)?

    var body: some View {
        switch item.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                // The pages the message went with, above its words.
                if !item.pages.isEmpty {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(Array(item.pages.enumerated()), id: \.offset) { AttachedPageCard(page: $0.element) }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.leading, 40)
                }
                HStack {
                    Spacer(minLength: 40)
                    Text(item.text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.field))
                        .accessibilityLabel(Accessibility.youSaid(item.text))
                }
                .modifier(SentImages(images: item.images))
            }
        case .assistant:
            AnswerRow(text: item.text)
        case .tool:
            StepChip(item: item)
        case .note:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11))
                Text(item.text).textSelection(.enabled)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.secondary)
        case .error:
            ChatErrorRow(item: item, retry: retry)
        }
    }
}

/// An answer, drawn as Markdown, with a Copy button that shows while the pointer is over it. Links open in a new tab.
struct AnswerRow: View {
    let text: String
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MarkdownView(text: text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.body)
                .textSelection(.enabled)
            CopyTextButton(text: text).opacity(hover ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hover = $0 }
        .environment(\.openURL, OpenURLAction { url in ChatLinks.open(url) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Accessibility.aiSaid)
    }
}

/// The panel's transcript: the rows, the AI's working line, and scrolling that follows the end only while the user is at the end.
struct ChatTranscript<Empty: View>: View {
    @ObservedObject var chat: ChatStore
    @ViewBuilder var empty: () -> Empty
    /// False once the user has scrolled up from the end; a new message of theirs puts it back.
    @State private var following = true

    var body: some View {
        let allRows = ChatLayout.rows(chat.items, running: chat.isRunning)
        // The steps of the run under way are in the working line, to open there.
        let live = chat.isRunning ? allRows.last { if case .live = $0 { true } else { false } } : nil
        let rows = allRows.filter { $0.id != live?.id }
        let retrying = chat.isRunning ? nil : chat.items.last(where: { $0.kind == .error })?.id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.items.isEmpty { empty() }
                    ForEach(rows) { row in
                        ChatRowView(row: row, chat: chat, retrying: retrying).id(row.id)
                    }
                    if chat.isRunning { Working(started: chat.runStarted, step: chat.step, steps: live).id("typing") }
                }
                .padding(.vertical, 12)
                .background(ScrollEndWatcher(atEnd: $following))
            }
            .scrollIndicators(.never)
            .onChange(of: chat.items) {
                if chat.items.last?.kind == .user { following = true }
                guard following else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    if chat.isRunning { proxy.scrollTo("typing", anchor: .bottom) } else if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

/// Tells whether the user has scrolled away from the end of the scroll view it sits in. Only the user's own scrolling counts (a wheel or
/// trackpad event is under way), so content growing or the panel scrolling by itself never turns it off.
private struct ScrollEndWatcher: NSViewRepresentable {
    @Binding var atEnd: Bool

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) {
        view.report = { atEnd = $0 }
    }

    final class Watcher: NSView {
        var report: (Bool) -> Void = { _ in }
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                guard NSApp.currentEvent?.type == .scrollWheel else { return }
                MainActor.assumeIsolated { self?.measure() }
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        private func measure() {
            guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let bounds = scroll.contentView.bounds
            report(document.isFlipped ? bounds.maxY >= document.frame.height - 24 : bounds.minY <= 24)
        }
    }
}
