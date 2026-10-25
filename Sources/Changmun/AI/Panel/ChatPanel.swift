import AppKit
import SwiftUI

// MARK: Panel

struct ChatPanel: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var browser: Browser
    /// The panel is in the window it was popped out into, not in the browser window.
    var inWindow = false
    @State private var draft = ""
    @State private var draftHeight: CGFloat = 16
    @ObservedObject private var prefs = Preferences.shared
    @State private var edit: ComposerEdit?
    /// Changes to bring the cursor back to the box.
    @State private var focus = 0
    /// The "@word" the cursor is at the end of, and which of the tabs that fit it is marked.
    @State private var mention: ComposerMention.Token?
    @State private var mentionSelection = 0
    /// Where the "@" is that Esc closed the list of, so that it stays closed while that "@" is the one being typed.
    @State private var mentionClosed: Int?
    /// How high the box and what is under it are, which the list of tabs stands over.
    @State private var composerHeight: CGFloat = 60
    @State private var pageKind = PageKind.general
    /// Until the AI is ready there is nothing to type to.
    private var ready: Bool { chat.availability == .ready && !chat.showHistory }
    @ObservedObject private var cards = ApprovalCards.shared
    /// A question of the AI is waiting in this panel.
    private var approvalPending: Bool { cards.first(for: browser) != nil }

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(chat: chat, history: chat.history, browser: browser, inWindow: inWindow, close: dismiss)
            // What the chat has read, under the title (nothing there until it has read something).
            ReadSitesRow()
            if chat.showHistory {
                ChatHistoryView(chat: chat, history: chat.history)
            } else {
                ChatTranscript(chat: chat) {
                    ChatEmptyState(availability: chat.availability, several: chat.attachedTabs.count >= 2, kind: pageKind) { fill($0) }
                }
            }
            ApprovalCardHost(browser: browser)
            attachments
            if !chat.queue.isEmpty { queued }
            if let notice = chat.notice {
                Text(notice).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.waitingText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.bottom, 6)
            }
            // A run under way can always be stopped.
            composer.disabled(!ready && !chat.isRunning).opacity(ready || chat.isRunning ? 1 : 0.4)
        }
        .background {
            if chat.items.isEmpty, !browser.isPrivate, let tab = Browser.recent?.active { PageKindProbe(tab: tab, kind: $pageKind) }
        }
        .overlay(alignment: .bottom) {
            if let tabs = mentionTabs {
                TabMentionList(tabs: tabs, selection: mentionSelection, pick: pickMention).padding(.bottom, composerHeight + 4)
            }
        }
        .onAppear { chat.refreshAvailability(); takePrefill() }
        .onChange(of: chat.prefill) { takePrefill() }
        .onChange(of: prefs.claudePath) { chat.refreshAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in chat.refreshAvailability() }
        .modifier(ImageDrop(chat: chat))
    }

    /// The tabs and images attached as context, each removable; the "+" in the box adds more.
    private var attachments: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                // The tab the AI takes as current is the one in front when the message goes out.
                if !browser.isPrivate, let current = Browser.recent?.active { CurrentTabChip(tab: current) }
                ForEach(chat.attachedTabs) { tab in
                    AttachedTabChip(tab: tab) { chat.detach(tab.id) }
                }
                ChatImageChips(chat: chat)
            }
        }
        .scrollIndicators(.never)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    /// The messages waiting for the run under way to end, each removable.
    private var queued: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(chat.queue) { message in
                        QueuedChip(text: message.text) { chat.removeQueued(message.id) }
                    }
                }
            }
            .scrollIndicators(.never)
            // The run before them failed or was cut short: they go only when the user says so.
            if chat.queueHeld && !chat.isRunning {
                Button { chat.sendQueued() } label: {
                    Text("Send Queued").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.primary)
                        .padding(.horizontal, 8).frame(height: 22).background(Capsule().fill(Theme.pill))
                }
                .buttonStyle(.plain)
                .help("The last run didn't finish, so these wait for you")
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                ComposerPlusMenu(chat: chat, browser: browser).padding(.bottom, 3)
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Ask about this page, or give it a task")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.faint)
                            .allowsHitTesting(false)
                    }
                    // While the AI works, Return queues the message for when it is done and ⌘Return steers it now.
                    ComposerField(text: $draft, height: $draftHeight, edit: $edit, focus: focus, onChange: composerChanged, onKey: composerKey) { text, command in
                        send(text, steering: command)
                    }
                }
                .frame(height: draftHeight)
                .padding(.vertical, 3)
                if ComposerMicButton.available { ComposerMicButton().padding(.bottom, 3) }
                if chat.isRunning {
                    ComposerStopButton { chat.stop() }.padding(.bottom, 3)
                } else {
                    Keycap("↵").opacity(draft.isEmpty ? 0.5 : 1).padding(.bottom, 5)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
            .padding(.bottom, chat.isRunning ? 2 : 4)
            if chat.isRunning {
                Text("↵ queues it for when the AI is done · ⌘↵ steers it now")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.faint)
                    .padding(.bottom, 4)
            }
            ComposerControlsRow(prefs: prefs, chat: chat)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
    }

    /// Closes the panel: the window it was popped out into, or the panel in the browser window.
    private func dismiss() {
        if inWindow { ChatPopOut.shared.close(dock: false) } else { browser.closeChat() }
    }

    private func send(_ text: String, steering: Bool = false) {
        guard steering ? chat.steer(text) : chat.submit(text) else { return }
        ComposerHistory.shared.add(text)
        draft = ""
    }

    /// A suggestion goes into the box to be changed or sent, not out.
    private func fill(_ text: String) {
        draft = text
        focus += 1
    }

    /// What came to the panel from outside (a selection quoted from a page) goes at the end of the box.
    private func takePrefill() {
        guard let text = chat.prefill else { return }
        chat.prefill = nil
        draft = draft.isEmpty ? text : draft + "\n\n" + text
        focus += 1
    }

    // MARK: "@" for a tab

    /// The tabs to offer while an "@word" is being typed (none left to offer is an empty list, not nil); nil when none is.
    private var mentionTabs: [Tab]? {
        guard ready, !approvalPending, !browser.isPrivate, let mention, mentionClosed != mention.range.location else { return nil }
        let open = browser.tabs.filter { browser.isVisibleToAI($0) && !chat.attachedIDs.contains($0.id) }
        return ComposerMention.filter(open, query: mention.query)
    }

    private func composerChanged(_ text: String, _ caret: Int) {
        let token = ComposerMention.token(in: text, caret: caret)
        if token != mention { mentionSelection = 0 }
        mention = token
        if mentionClosed != token?.range.location { mentionClosed = nil }
    }

    /// Takes the tab as "+ Add Tab" does (the same attach, and so the same approvals), and the "@word" out of the text.
    private func pickMention(_ tab: Tab) {
        guard let mention else { return }
        chat.attach([tab])
        edit = ComposerEdit(range: ComposerMention.removalRange(for: mention, in: draft), text: "")
        self.mention = nil
    }

    /// The keys the box hands the panel: choosing from the list of tabs, Esc to stop or close, ↑ ↓ for earlier messages.
    private func composerKey(_ key: ComposerKey) -> Bool {
        if let tabs = mentionTabs {
            let count = tabs.count
            switch key {
            case .up where count > 0:
                mentionSelection = (mentionSelection + count - 1) % count
                return true
            case .down where count > 0:
                mentionSelection = (mentionSelection + 1) % count
                return true
            case .returnKey where count > 0, .tab where count > 0:
                pickMention(tabs[min(mentionSelection, count - 1)])
                return true
            case .escape:
                mentionClosed = mention?.range.location
                return true
            default:
                break
            }
        }
        switch key {
        case .escape:
            // The same as the stop button.
            if chat.isRunning { chat.stop(); return true }
            if draft.isEmpty { dismiss(); return true }
            return false
        case .up:
            guard let text = ComposerHistory.shared.older(current: draft) else { return false }
            draft = text
            return true
        case .down:
            guard let text = ComposerHistory.shared.newer(current: draft) else { return false }
            draft = text
            return true
        default:
            return false
        }
    }
}
