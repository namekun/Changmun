import AppKit
import Foundation
import Testing
@testable import Changmun

/// The decisions of the panel that need no shared state: the AI button, Esc, the card's time, the nearly full chat, the approvals control,
/// the history search and the commands an error row copies.
@MainActor
struct AIPanelPureFixesTests {
    @Test func theAIButtonSaysWhenTheAIWorksOrHasAnsweredWithItsPanelClosed() {
        #expect(AIButton.shows(isOn: false, running: false, answerWaiting: false) == .idle)
        #expect(AIButton.shows(isOn: false, running: true, answerWaiting: false) == .working)
        #expect(AIButton.shows(isOn: false, running: true, answerWaiting: true) == .working, "a run under way comes first")
        #expect(AIButton.shows(isOn: false, running: false, answerWaiting: true) == .answered)
        #expect(AIButton.shows(isOn: true, running: true, answerWaiting: true) == .idle, "the open panel shows it itself")
        #expect(AIButton.help(.working) != AIButton.help(.idle) && AIButton.help(.answered) != AIButton.help(.idle))
        #expect(AIButton.value(.answered, isOn: false).hasSuffix("Answer waiting"))
    }

    @Test func escStopsARunAndDoesNotCloseThePanelRightAfter() {
        #expect(ChatPanel.escape(running: true, draftEmpty: true, sinceStop: nil) == .stop)
        #expect(ChatPanel.escape(running: false, draftEmpty: true, sinceStop: 0.2) == .ignore, "the second Esc of a double press")
        #expect(ChatPanel.escape(running: false, draftEmpty: true, sinceStop: ChatPanel.escapeAfterStop + 0.1) == .close)
        #expect(ChatPanel.escape(running: false, draftEmpty: true, sinceStop: nil) == .close)
        #expect(ChatPanel.escape(running: false, draftEmpty: false, sinceStop: nil) == .pass, "text in the box is the box's")
    }

    @Test func theCardSaysThatNoAnswerIsNoAndCountsDownOnlyAtTheEnd() {
        let line = ApprovalDeadline.text(remaining: 80, total: 90, reduceMotion: false)
        #expect(line == Approvals.noAnswerLine(90) && line.contains("Don’t Allow"))
        #expect(ApprovalDeadline.text(remaining: 12.3, total: 90, reduceMotion: false) == "Not allowed in \(ElapsedText.text(seconds: 13)) unless you answer.")
        #expect(ApprovalDeadline.text(remaining: 12.3, total: 90, reduceMotion: true) == "Not allowed in \(ElapsedText.text(seconds: 15)) unless you answer.", "in steps of five without motion")
        #expect(ApprovalDeadline.text(remaining: -1, total: 90, reduceMotion: false).contains(ElapsedText.text(seconds: 0)))
    }

    @Test func aNearlyFullChatIsSaidInWordsFrom85Percent() {
        #expect(!ContextUsage(used: 160_000, window: 200_000).nearlyFull)
        #expect(ContextUsage(used: 170_000, window: 200_000).nearlyFull)
        #expect(ContextUsage(used: 250_000, window: 200_000).nearlyFull)
    }

    @Test func theApprovalsControlSaysWhatItIsAndWarnsOfTheWeakestMode() {
        for mode in AIApprovalMode.allCases {
            let help = ComposerControlsRow.approvalsHelp(mode)
            #expect(help.contains("how much the AI asks before it acts") && help.hasSuffix(mode.title))
        }
        #expect(ComposerControlsRow.warning(choosing: .irreversibleOnly)?.contains("Instructions hidden in a web page") == true)
        #expect(ComposerControlsRow.warning(choosing: .afterReading) == nil && ComposerControlsRow.warning(choosing: .everyAction) == nil)
    }

    @Test func theHistoryIsSearchedByTitleAndWordsInAnyCase() {
        let now = Date()
        let chats = [
            StoredChat(id: UUID(), started: now, updated: now, items: [ChatItem(kind: .user, text: "Compare flights to Jeju"), ChatItem(kind: .assistant, text: "The cheapest is Tuesday.")]),
            StoredChat(id: UUID(), started: now, updated: now, items: [ChatItem(kind: .user, text: "Résumé this page"), ChatItem(kind: .tool, text: "Reading tuesday.example")]),
        ]
        #expect(ChatHistorySearch.matching(chats, query: "  ").count == 2)
        #expect(ChatHistorySearch.matching(chats, query: "jeju").map(\.id) == [chats[0].id])
        #expect(ChatHistorySearch.matching(chats, query: "tuesday").map(\.id) == [chats[0].id], "steps are not searched")
        #expect(ChatHistorySearch.matching(chats, query: "resume page").map(\.id) == [chats[1].id], "every word, any accents")
        #expect(ChatHistorySearch.matching(chats, query: "jeju page").isEmpty)
    }

    @Test func anOutdatedClaudeIsToldAndTheCopiedCommandsCanBePastedAsTheyAre() {
        let failure = AIFailure.classify("The AI response didn't finish (exit code 1).\nerror: unknown option '--effort'")
        #expect(failure.kind == .outdated && failure.title == "Claude Code may need updating")
        #expect(failure.command(claude: "/Users/me/.local/bin/claude") == "/Users/me/.local/bin/claude update")
        #expect(AIFailure.classify("error: unrecognized option --setting-sources").kind == .outdated)
        #expect(AIFailure.classify("Tool failed: unexpected argument 'x' in the page's script").kind != .outdated, "the words inside other text")
        #expect(AIFailure.classify("The form said: error: unknown option").kind != .outdated, "not on a line of its own")
        #expect(AIFailure.classify("unknown argument").kind != .outdated)
        #expect(AIFailure.classify("error: unknown option '--x'", code: "rate_limit").kind == .usageLimit, "the API's own code comes first")
        #expect(AIFailure.classify("error: unknown option '--x'", status: 529).kind == .overloaded)
        let login = AIFailure.classify("Not logged in · Please run /login", code: "authentication_failed")
        #expect(login.command(claude: nil) == "claude")
        #expect(login.command(claude: "/Users/me/.local/bin/claude") == "/Users/me/.local/bin/claude", "the path the app runs, which the shell may not find by name")
        #expect(login.command(claude: "/Users/me/My Tools/claude") == "'/Users/me/My Tools/claude'")
        #expect(AIFailure.shellQuoted("/a/it's/claude") == #"'/a/it'\''s/claude'"#)
        #expect(AIFailure.classify("Overloaded").command(claude: "/x/claude") == nil)
    }

    @Test func aQuestionNobodyAnsweredIsItsOwnStepOutcome() {
        #expect(StepOutcome.of(error: true, text: ToolCatalog.unansweredText) == .unanswered)
        #expect(StepOutcome.of(error: true, text: ToolCatalog.refusedText) == .denied)
        #expect(StepOutcome.unanswered.isProblem)
    }
}

extension SharedAgentState {
    @MainActor @Suite
    struct AIPanelFixesTests {
        private func open(_ addresses: [String]) -> (Browser, [Tab]) {
            let browser = Browser()
            browser.focused()
            return (browser, addresses.map { browser.openTab(url: URL(string: $0), activate: false) })
        }

        private func standIn() -> (chat: ChatStore, launched: () -> [String]) {
            let chat = ChatStore()
            chat.history = ChatHistory(file: FileManager.default.temporaryDirectory.appendingPathComponent("chats-\(UUID().uuidString).json"))
            let box = Launches()
            chat.launch = { message, _ in box.messages.append(message); return true }
            return (chat, { box.messages })
        }

        private final class Launches { var messages: [String] = [] }

        private func text(_ result: ToolResult) -> String { result.content.compactMap { $0["text"] as? String }.joined() }

        // MARK: Timeout

        @Test func aQuestionThatRanOutOfTimeIsNotAllowedAndTheAIIsToldNobodyAnswered() async {
            let address = URL(string: "https://never-\(UUID().uuidString.lowercased()).example/a?b=1")!
            let caller = bridgeCaller()
            Approvals.forgetReads(caller: caller)
            defer { Approvals.forgetReads(caller: caller) }
            let was = Approvals.timeout
            defer { Approvals.timeout = was }
            await asking({ _ in .deny }) { stand in
                let outcome = Approvals.Outcome()
                await Approvals.$outcome.withValue(outcome) {
                    #expect(!(await Approvals.allowNavigation(address, caller: caller)))
                    #expect(!outcome.unanswered && text(ToolCatalog.declined) == ToolCatalog.refusedText, "a no is a no")
                    #expect(ToolCatalog.declinedTab.contains("declined"))
                    stand.holds = true
                    Approvals.timeout = 0.2
                    #expect(!(await Approvals.allowNavigation(address, caller: caller)), "no answer in time is not allowed")
                    #expect(outcome.unanswered && ToolCatalog.declined.isError && text(ToolCatalog.declined) == ToolCatalog.unansweredText)
                    #expect(ToolCatalog.declinedTab.contains("didn't answer in time"))
                    // Withdrawn by the Stop button: that is not a question that ran out of time.
                    Approvals.timeout = 30
                    let task = Task { await Approvals.allowNavigation(address, caller: caller) }
                    #expect(await waitUntil(5) { stand.asked.count == 3 })
                    Approvals.cancelPending(caller: caller)
                    #expect(!(await task.value))
                }
                #expect(!Approvals.lastWentUnanswered, "outside a tool call there is nothing to tell")
            }
            #expect(text(ToolCatalog.declined) == ToolCatalog.refusedText)
        }

        @Test func theStopButtonIsNotTakenForATimeout() async {
            let address = URL(string: "https://never-\(UUID().uuidString.lowercased()).example/a?b=2")!
            let caller = bridgeCaller()
            defer { Approvals.forgetReads(caller: caller) }
            await asking({ _ in .deny }) { stand in
                stand.holds = true
                let outcome = Approvals.Outcome()
                outcome.unanswered = true
                await Approvals.$outcome.withValue(outcome) {
                    let task = Task { await Approvals.allowNavigation(address, caller: caller) }
                    #expect(await waitUntil(5) { !stand.asked.isEmpty })
                    Approvals.cancelPending(caller: caller)
                    #expect(!(await task.value))
                    #expect(!outcome.unanswered, "each question starts again, and a stop is not a timeout")
                }
            }
        }

        // MARK: Words on the cards

        @Test func everyCardSaysDontAllowAndCarriesItsDeadline() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            browser.showChat = true
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ _ in .deny }) { stand in
                stand.holds = true
                let tab = Task { await Approvals.allowTab(tabs[1], caller: panel) }
                guard await waitUntil(5, { !ApprovalCards.shared.cards.isEmpty }) else { Issue.record("no card"); return }
                let card = ApprovalCards.shared.cards[0]
                #expect(card.buttons.map(\.1) == ["Don’t Allow", "Allow"], "the tab stays allowed on its site: not \"once\"")
                #expect(card.deadline.map { $0 > card.shownAt } == true)
                card.answer(.deny)
                #expect(!(await tab.value))

                let address = Task { await Approvals.allowNavigation(URL(string: "https://never-\(UUID().uuidString.lowercased()).example/x?y=1")!, caller: panel) }
                guard await waitUntil(5, { !ApprovalCards.shared.cards.isEmpty }) else { Issue.record("no card"); return }
                let second = ApprovalCards.shared.cards[0]
                #expect(second.buttons.first?.1 == "Don’t Allow" && !second.prompt.detail.contains("Deny"))
                #expect(second.prompt.detail.contains("Choose Don’t Allow"))
                second.answer(.deny)
                _ = await address.value

                Approvals.noteRead(tabs[0], caller: panel)
                let use = Task { await Approvals.allowInteraction(.type("x"), on: tabs[1], caller: panel) }
                guard await waitUntil(5, { !ApprovalCards.shared.cards.isEmpty }) else { Issue.record("no card"); return }
                #expect(ApprovalCards.shared.cards[0].buttons.prefix(2).map(\.1) == ["Don’t Allow", "Allow Once"])
                ApprovalCards.shared.cards[0].answer(.deny)
                _ = await use.value
            }
        }

        // MARK: Allowances

        @Test func tabsAndAddressesAllowedAreListedRevocableAndGoWithANewChat() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/", "https://c.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            let address = URL(string: "https://never-\(UUID().uuidString.lowercased()).example/p?q=1")!
            await asking({ _ in .once }) { stand in
                #expect(await Approvals.allowTab(tabs[1], caller: panel))
                #expect(await Approvals.allowNavigation(address, caller: panel))
                Approvals.allowOpened(tabs[2], at: URL(string: "https://c.example/")!, caller: panel)
                #expect(stand.asked.count == 2)
                let listed = Approvals.tabsAllowed(caller: panel)
                #expect(listed.count == 1 && Approvals.describeTab(listed[0]).contains("b.example"), "what the AI opened itself is not listed")
                #expect(Approvals.addressesAllowed(caller: panel) == [address.absoluteString])

                #expect(await Approvals.allowTab(tabs[1], caller: panel))
                #expect(stand.asked.count == 2, "allowed: not asked again")
                Approvals.revoke(tab: listed[0], caller: panel)
                #expect(await Approvals.allowTab(tabs[1], caller: panel))
                #expect(stand.asked.count == 3, "revoked: asked again")
                Approvals.revoke(address: address.absoluteString, caller: panel)
                #expect(await Approvals.allowNavigation(address, caller: panel))
                #expect(stand.asked.count == 4)

                Approvals.forgetReads(caller: panel)
                #expect(Approvals.tabsAllowed(caller: panel).isEmpty && Approvals.addressesAllowed(caller: panel).isEmpty)
                #expect(await Approvals.allowTab(tabs[1], caller: panel))
                #expect(await Approvals.allowNavigation(address, caller: panel))
                #expect(await Approvals.allowTab(tabs[2], caller: panel))
                #expect(stand.asked.count == 7, "a new chat asks again about every tab and address, the AI's own tabs too")
            }
        }

        @Test func aNewChatClearsTheTabsAndAddressesAllowed() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            let chat = ChatStore()
            defer { chat.reset() }
            await asking({ _ in .once }) { stand in
                #expect(await Approvals.allowTab(tabs[1], caller: ChatStore.caller))
                chat.reset()
                #expect(await Approvals.allowTab(tabs[1], caller: ChatStore.caller))
                #expect(stand.asked.count == 2)
            }
        }

        // MARK: Stop

        @Test func stopSaysSoAndHoldsWhatWasWaitingToBeSentOrRemoved() {
            let (chat, launched) = standIn()
            chat.submit("first")
            chat.submit("second")
            chat.submit("third")
            chat.stop()
            #expect(!chat.isRunning && chat.queue.map(\.text) == ["second", "third"] && chat.queueHeld)
            #expect(chat.items.last?.kind == .note && chat.items.last?.text.hasPrefix("Stopped") == true)
            chat.stop()
            #expect(chat.items.filter { $0.kind == .note }.count == 1, "nothing ran: nothing to say")
            chat.sendQueued()
            #expect(launched() == ["first", "second"] && chat.queue.map(\.text) == ["third"])
            chat.endRun()
            #expect(launched().last == "third")
        }

        // MARK: The AI button

        @Test func anAnswerThatCameWithNoPanelShowingWaitsForThePanel() {
            let saved = ChatStore.panelVisible
            defer { ChatStore.panelVisible = saved }
            let (chat, _) = standIn()
            ChatStore.panelVisible = { true }
            chat.submit("seen")
            chat.endRun()
            #expect(!chat.answerWaiting)
            ChatStore.panelVisible = { false }
            chat.submit("unseen")
            chat.endRun()
            #expect(chat.answerWaiting)
            chat.reset()
            #expect(!chat.answerWaiting)
        }
    }
}
