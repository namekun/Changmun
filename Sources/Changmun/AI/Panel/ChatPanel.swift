import AppKit
import SwiftUI

// MARK: Panel

struct ChatPanel: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var browser: Browser
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
    @State private var modelMenu = false
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
            // The page bar's AI button already names the panel; its head says what the chat has read.
            HStack(spacing: 4) {
                ReadSitesRow()
                Spacer()
                BarButton(symbol: "clock.arrow.circlepath", help: String(localized: "Chat History")) {
                    chat.showHistory.toggle()
                    chat.openedHistory = nil
                }
                BarButton(symbol: "square.and.pencil", help: String(localized: "New Chat (⌘⇧E)")) { chat.reset() }
                BarButton(symbol: "xmark", help: String(localized: "Close (⌘E)")) { browser.showChat = false }
            }
            .padding(.horizontal, 6)
            // Level with the page card's bar beside it.
            .frame(height: BrowserWindow.pageBarHeight)
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
        .overlay {
            // A question waiting in the panel has its buttons above the box: nothing opens over them.
            if modelMenu && !approvalPending {
                Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { modelMenu = false }
                ModelList(prefs: prefs) { model in
                    prefs.aiModel = model
                    modelMenu = false
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.bottom, 32).padding(.leading, 4)
            }
        }
        .overlay(alignment: .bottom) {
            if let tabs = mentionTabs {
                TabMentionList(tabs: tabs, selection: mentionSelection, pick: pickMention).padding(.bottom, composerHeight + 4)
            }
        }
        .onAppear { chat.refreshAvailability(); takePrefill() }
        .onChange(of: chat.prefill) { takePrefill() }
        .onChange(of: approvalPending) { if approvalPending { modelMenu = false } }
        .onChange(of: prefs.claudePath) { chat.refreshAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in chat.refreshAvailability() }
        .modifier(ImageDrop(chat: chat))
    }

    /// The tabs attached as context, each removable, and the menu to add more.
    private var attachments: some View {
        HStack(spacing: 6) {
            Menu {
                // A private window's tabs are not the AI's to read.
                let candidates = browser.tabs.filter { browser.isVisibleToAI($0) }
                ForEach(candidates.filter { !chat.attachedIDs.contains($0.id) }) { tab in
                    Button(tab.displayTitle) { chat.attach([tab]) }
                }
                if !browser.groups.isEmpty && !candidates.isEmpty {
                    Divider()
                    ForEach(browser.groups) { group in
                        Button(group.name, systemImage: "square.stack") { chat.attach(candidates.filter { $0.groupID == group.id }) }
                    }
                }
                Divider()
                Button("All Open Tabs") { chat.attach(candidates) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    Text("Add Tab").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Theme.hoverTab))
            .disabled(!ready)
            .opacity(ready ? 1 : 0.4)
            .help("Give the AI more tabs to read")
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    // The tab the AI takes as current is the one in front when the message goes out.
                    if !browser.isPrivate, let current = Browser.recent?.active { CurrentTabChip(tab: current) }
                    ForEach(chat.attachedTabs) { tab in
                        AttachedTabChip(tab: tab) { chat.detach(tab.id) }
                    }
                    ChatImageChips(chat: chat, browser: browser)
                }
            }
            .scrollIndicators(.never)
        }
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
                if chat.isRunning {
                    Button { chat.stop() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill").font(.system(size: 8, weight: .bold))
                            Text("Stop").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(Theme.pill))
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                } else {
                    Keycap("↵").opacity(draft.isEmpty ? 0.5 : 1).padding(.bottom, 2)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
            .padding(.bottom, chat.isRunning ? 2 : 4)
            if chat.isRunning {
                Text("↵ queues it for when the AI is done · ⌘↵ steers it now")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.faint)
                    .padding(.bottom, 4)
            }
            HStack { ModelChip(prefs: prefs, open: $modelMenu); Spacer() }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
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
            if modelMenu { modelMenu = false; return true }
            // The same as the stop button.
            if chat.isRunning { chat.stop(); return true }
            if draft.isEmpty { browser.closeChat(); return true }
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
