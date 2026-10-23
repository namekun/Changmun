import AppKit
import Combine
import Foundation
import Testing
@testable import Changmun

extension SharedAgentState {
    /// Where the panel's AI is asked (in the panel, or on the window), what the keys answer, and what the user can take back.
    @MainActor @Suite
    struct ApprovalCardTests {
        private func open(_ addresses: [String]) -> (Browser, [Tab]) {
            let browser = Browser()
            browser.focused()
            return (browser, addresses.map { browser.openTab(url: URL(string: $0), activate: false) })
        }

        /// Runs `body` with approvals on, no stand to answer for the user, and the card waiting questions short.
        private func withoutStand(_ body: () async -> Void) async {
            let before = Preferences.shared.aiApprovals, timeout = Approvals.timeout
            Preferences.shared.aiApprovals = true
            defer { Preferences.shared.aiApprovals = before; Approvals.timeout = timeout }
            await Approvals.$stand.withValue(nil) { await body() }
        }

        // MARK: Routing

        @Test func onlyThePanelsOwnReversibleQuestionsWithThePanelOpenGoToTheCard() {
            let panel = ChatStore.caller
            #expect(Approvals.route(caller: panel, irreversible: false, accounts: [], panelOpen: true) == .card)
            #expect(Approvals.route(caller: panel, irreversible: false, accounts: ["a"], panelOpen: true) == .card, "one account is no choice")
            #expect(Approvals.route(caller: panel, irreversible: false, accounts: [], panelOpen: false) == .sheet, "the panel is closed")
            #expect(Approvals.route(caller: panel, irreversible: true, accounts: [], panelOpen: true) == .sheet, "what can't be undone stays on the window")
            #expect(Approvals.route(caller: panel, irreversible: false, accounts: ["a", "b"], panelOpen: true) == .sheet, "a list of accounts stays on the window")
            #expect(Approvals.route(caller: panel, irreversible: false, accounts: [], panelOpen: true, signIn: true) == .sheet, "a sign-in is asked on the window, one account or none")
            #expect(Approvals.route(caller: panel, irreversible: false, accounts: ["a"], panelOpen: true, signIn: true) == .sheet)
            for caller in [bridgeCaller(), "cli", "mcp-1", ""] {
                #expect(Approvals.route(caller: caller, irreversible: false, accounts: [], panelOpen: true) == .sheet, "\(caller) is not the panel")
            }
        }

        @Test func aStandStillAnswersForTheUserAndNoCardIsMade() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            browser.showChat = true
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ _ in .once }) { stand in
                Approvals.noteRead(tabs[0], caller: panel)
                #expect(await Approvals.allowInteraction(.type("hi"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 1 && stand.asked[0].parts?.text == "hi" && ApprovalCards.shared.cards.isEmpty)
            }
        }

        @Test func aQuestionOfAnotherCallerWithNoWindowIsRefusedAndNeverShownInThePanel() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            browser.showChat = true
            let caller = bridgeCaller()
            Approvals.forgetReads(caller: caller)
            defer { Approvals.forgetReads(caller: caller) }
            await withoutStand {
                Approvals.noteRead(tabs[0], caller: caller)
                #expect(!(await Approvals.allowInteraction(.type("hi"), on: tabs[1], caller: caller)), "no window to ask on")
                #expect(ApprovalCards.shared.cards.isEmpty)
            }
        }

        // MARK: The card

        /// Starts a question of the panel's AI and waits for its card.
        private func ask(_ interaction: Approvals.Interaction, on tab: Tab, mark: Approvals.Mark? = nil) async -> (Task<Bool, Never>, ApprovalCards.Card)? {
            let task = Task { await Approvals.allowInteraction(interaction, on: tab, caller: ChatStore.caller, mark: mark) }
            guard await waitUntil(5, { !ApprovalCards.shared.cards.isEmpty }) else { task.cancel(); return nil }
            return (task, ApprovalCards.shared.cards[0])
        }

        @Test func theCardHoldsTheQuestionWholeAndTheAnswersCarryIt() async {
            let (browser, tabs) = open(["https://a.example/", "https://shop.example/"])
            defer { browser.windowClosed() }
            browser.showChat = true
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await withoutStand {
                Approvals.noteRead(tabs[0], caller: panel)
                let long = String(repeating: "word ", count: 120)
                guard let (task, card) = await ask(.type(long), on: tabs[1]) else { Issue.record("no card"); return }
                guard let parts = card.prompt.parts else { Issue.record("no parts"); return }
                #expect(parts.site == "shop.example" && parts.readLine.contains("a.example") && parts.text.hasPrefix("word word"))
                #expect(parts.text.contains("more characters are not shown"), "said to be cut, not cut silently")
                #expect(card.prompt.choices == [.deny, .once], "a cut text can't be allowed for the chat")
                #expect(card.buttons.map(\.0) == [.deny, .once] && browser.showChat)
                card.answer(.once)
                #expect(await task.value)
                #expect(ApprovalCards.shared.cards.isEmpty)

                guard let (second, again) = await ask(.type("short"), on: tabs[1]) else { Issue.record("no card"); return }
                #expect(again.prompt.choices == [.deny, .once, .site] && again.prompt.parts?.text == "short")
                again.answer(.site)
                #expect(await second.value)
                #expect(await Approvals.allowInteraction(.type("more"), on: tabs[1], caller: panel), "allowed for the chat: not asked again")
                #expect(ApprovalCards.shared.cards.isEmpty)
            }
        }

        @Test func noAnswersAndStopAndTheTimeoutAllMeanNo() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            browser.showChat = true
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await withoutStand {
                Approvals.noteRead(tabs[0], caller: panel)
                guard let (denied, card) = await ask(.type("x"), on: tabs[1]) else { Issue.record("no card"); return }
                card.answer(.deny)
                #expect(!(await denied.value))

                guard let (stopped, _) = await ask(.type("x"), on: tabs[1]) else { Issue.record("no card"); return }
                Approvals.cancelPending(caller: panel)
                #expect(!(await stopped.value), "the Stop button answers no")
                #expect(ApprovalCards.shared.cards.isEmpty)

                Approvals.timeout = 0.2
                guard let (late, _) = await ask(.type("x"), on: tabs[1]) else { Issue.record("no card"); return }
                #expect(!(await late.value), "no answer in time is no")
                #expect(ApprovalCards.shared.cards.isEmpty)
            }
        }

        @Test func thePageIsOutlinedWhileTheCardWaitsAndNotAfter() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            browser.showChat = true
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await withoutStand {
                Approvals.noteRead(tabs[0], caller: panel)
                var shown = 0, cleared = 0
                let mark = Approvals.Mark(show: { shown += 1 }, clear: { cleared += 1 })
                guard let (task, card) = await ask(.act("Clicking “Go”"), on: tabs[1], mark: mark) else { Issue.record("no card"); return }
                let drawn = await waitUntil { shown == 1 }
                #expect(drawn && cleared == 0)
                card.answer(.deny)
                _ = await task.value
                #expect(cleared == 1)
            }
        }

        @Test func thePanelClosingWithAQuestionOpenMovesItToTheWindowWhichRefusesWithoutOne() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            browser.showChat = true
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await withoutStand {
                Approvals.noteRead(tabs[0], caller: panel)
                guard let (task, _) = await ask(.type("x"), on: tabs[1]) else { Issue.record("no card"); return }
                ApprovalCards.shared.moveToSheet(for: browser)
                #expect(ApprovalCards.shared.cards.isEmpty)
                #expect(!(await task.value), "there is no window in a test to show the sheet on, so it is no")
            }
        }

        @Test func aLowTierQuestionGoesToTheCardAndAHighTierOneDoesNot() async {
            let (browser, tabs) = open(["https://a.example/"])
            defer { browser.windowClosed() }
            browser.showChat = true
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await withoutStand {
                let high = Task { await Approvals.allowAction(.high, "Pay now", on: tabs[0], caller: panel) }
                #expect(!(await high.value) && ApprovalCards.shared.cards.isEmpty, "the window is asked, and there is none")
                let low = Task { await Approvals.allowAction(.low, "Accept all", on: tabs[0], caller: panel) }
                guard await waitUntil(5, { !ApprovalCards.shared.cards.isEmpty }) else { Issue.record("no card"); low.cancel(); return }
                let card = ApprovalCards.shared.cards[0]
                #expect(card.prompt.choices == [.deny, .once, .site] && card.prompt.parts?.text == "“Accept all”" && card.prompt.parts?.site == "a.example")
                card.answer(.site)
                #expect(await low.value)
                #expect(Approvals.sitesAllowed(caller: panel) == ["a.example"])
            }
        }

        // MARK: Keys

        @Test func theKeysAnswerAsTheCardSays() {
            let all: [Approvals.Choice] = [.deny, .once, .site]
            func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], offered: [Approvals.Choice] = all, inPage: Bool = false, typed: Bool = false, inPanel: Bool = true, after: TimeInterval = 5) -> Approvals.Choice? {
                ApprovalKeys.choice(keyCode: code, flags: flags, offered: offered, inPage: inPage, typed: typed, inPanel: inPanel, shownFor: after)
            }
            #expect(key(36) == .deny && key(76) == .deny, "Return is the safe one")
            #expect(key(36, .command) == .once)
            #expect(key(36, [.command, .option]) == .site)
            #expect(key(53) == .deny)
            #expect(key(36, [.command, .option], offered: [.deny, .once]) == nil, "not offered, not answered")
            #expect(key(36, [.command, .shift]) == nil && key(36, .option) == nil && key(36, .control) == nil && key(0) == nil)
            #expect(key(36, .command, inPage: true) == nil && key(36, inPage: true) == nil && key(53, inPage: true) == nil, "a page's keys are the page's")
            #expect(key(36, typed: true) == nil && key(36, .command, typed: true) == nil, "a message being written is sent, not answered")
            #expect(key(53, typed: true) == .deny)
            #expect(key(36, .command, after: 0.1) == nil && key(36, [.command, .option], after: 0.1) == nil, "a key pressed just before can't say yes")
            #expect(key(36, after: 0.1) == .deny && key(53, after: 0) == .deny)
            #expect(key(36, offered: [.deny]) == .deny && key(36, .command, offered: [.deny]) == nil, "a notice can only be closed")
            #expect(ApprovalKeys.yesArmed(shownFor: 0.49) == false && ApprovalKeys.yesArmed(shownFor: ApprovalKeys.yesDelay) == true, "the buttons that say yes wake up with the keys")
            let shown = Date(timeIntervalSince1970: 1000)
            #expect(ApprovalKeys.mayClickYes(shownAt: shown, mouseDownAt: shown.addingTimeInterval(0.6), now: shown.addingTimeInterval(0.7)))
            #expect(!ApprovalKeys.mayClickYes(shownAt: shown, mouseDownAt: shown.addingTimeInterval(0.1), now: shown.addingTimeInterval(0.7)), "a press that began while the card was new")
            #expect(!ApprovalKeys.mayClickYes(shownAt: shown, mouseDownAt: shown.addingTimeInterval(-1), now: shown.addingTimeInterval(0.7)), "a press that began before the card was there")
            #expect(!ApprovalKeys.mayClickYes(shownAt: shown, mouseDownAt: nil, now: shown.addingTimeInterval(5)) && !ApprovalKeys.mayClickYes(shownAt: shown, mouseDownAt: shown.addingTimeInterval(0.2), now: shown.addingTimeInterval(0.3)))
            #expect(key(36, .command, inPanel: false) == nil && key(76, .command, inPanel: false) == nil, "yes once from outside the panel is nothing")
            #expect(key(36, [.command, .option], inPanel: false) == nil && key(76, [.command, .option], inPanel: false) == nil, "yes for the chat from outside the panel is nothing")
            #expect(key(36, .command, inPanel: true) == .once && key(36, [.command, .option], inPanel: true) == .site)
            #expect(key(36, inPanel: false) == .deny && key(53, inPanel: false) == .deny, "no may be said from anywhere but a page")
        }

        // MARK: What was read and allowed

        @Test func revokingTakesBackTheSiteForTheNextActionAndOnlyForThatCaller() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/", "https://c.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller, mcp = bridgeCaller()
            for caller in [panel, mcp] { Approvals.forgetReads(caller: caller) }
            defer { for caller in [panel, mcp] { Approvals.forgetReads(caller: caller) } }
            await asking({ prompt in prompt.choices.contains(.site) ? .site : .once }) { stand in
                for caller in [panel, mcp] { Approvals.noteRead(tabs[0], caller: caller) }
                #expect(Approvals.sitesRead(caller: panel) == ["a.example"] && Approvals.sitesAllowed(caller: panel).isEmpty)
                // A site allowed for typing and another allowed for the actions of the low tier, by both callers.
                for caller in [panel, mcp] {
                    #expect(await Approvals.allowInteraction(.type("x"), on: tabs[1], caller: caller))
                    #expect(await Approvals.allowAction(.low, "Save", on: tabs[2], caller: caller))
                }
                #expect(stand.asked.count == 4)
                #expect(Approvals.sitesAllowed(caller: panel) == ["b.example", "c.example"])
                for caller in [panel, mcp] {
                    #expect(await Approvals.allowInteraction(.type("y"), on: tabs[1], caller: caller))
                    #expect(await Approvals.allowAction(.low, "Save", on: tabs[2], caller: caller))
                }
                #expect(stand.asked.count == 4, "allowed: not asked")

                Approvals.revoke(site: "b.example", caller: panel)
                Approvals.revoke(site: "c.example", caller: panel)
                #expect(Approvals.sitesAllowed(caller: panel).isEmpty && Approvals.sitesRead(caller: panel) == ["a.example"], "reads are not taken back")
                #expect(await Approvals.allowInteraction(.type("z"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 5 && stand.asked[4].parts?.text == "z", "asked again")
                #expect(await Approvals.allowAction(.low, "Save", on: tabs[2], caller: panel))
                #expect(stand.asked.count == 6, "asked again")

                #expect(Approvals.sitesAllowed(caller: mcp) == ["b.example", "c.example"])
                #expect(await Approvals.allowInteraction(.type("z"), on: tabs[1], caller: mcp))
                #expect(await Approvals.allowAction(.low, "Save", on: tabs[2], caller: mcp))
                #expect(stand.asked.count == 6, "the other caller keeps what it was allowed")
            }
        }

        @Test func anAllowanceThatReadingAnotherSiteVoidedIsNotListedAsAllowed() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/", "https://c.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ prompt in prompt.choices.contains(.site) ? .site : .once }) { _ in
                Approvals.noteRead(tabs[0], caller: panel)
                #expect(await Approvals.allowInteraction(.type("x"), on: tabs[1], caller: panel))
                #expect(Approvals.sitesAllowed(caller: panel) == ["b.example"])
                Approvals.noteRead(tabs[2], caller: panel)
                #expect(Approvals.sitesAllowed(caller: panel).isEmpty, "it would be asked again")
                Approvals.forgetReads(caller: panel)
                #expect(Approvals.sitesRead(caller: panel).isEmpty && Approvals.sitesAllowed(caller: panel).isEmpty)
            }
        }

        @Test func theListChangesAreAnnounced() {
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            let (browser, tabs) = open(["https://a.example/"])
            defer { browser.windowClosed() }
            var count = 0
            let subscription = Approvals.changes.sink { count += 1 }
            defer { subscription.cancel() }
            Approvals.noteRead(tabs[0], caller: panel)
            Approvals.noteRead(tabs[0], caller: panel)
            #expect(count == 1, "a site read again is no change")
            Approvals.revoke(site: "a.example", caller: panel)
            #expect(count == 2)
        }
    }
}
