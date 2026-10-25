import AppKit
import Foundation
import Testing
@testable import Changmun

@MainActor
private func card(_ browser: Browser?, moved: (() -> Void)? = nil) -> ApprovalCards.Card {
    ApprovalCards.Card(id: UUID(), prompt: Approvals.Prompt(message: "m", detail: "d", choices: [.deny, .once]), buttons: [(.deny, "No"), (.once, "Yes")],
                       browser: browser, answer: { _ in }, moveToSheet: { moved?() })
}

/// What sits around the AI panel's box: the effort, the approval modes, the title, the working line, the context ring, and the pages
/// a message went with.
@MainActor
struct AIControlsPureTests {
    // MARK: Effort

    @Test func noEffortFlagIsPassedUnlessOneWasChosen() {
        #expect(AIEffort.arguments(for: "").isEmpty, "auto: claude does as it always did")
        #expect(AIEffort.arguments(for: "bogus").isEmpty, "a value claude doesn't know is not passed")
        #expect(AIEffort.arguments(for: "High").isEmpty, "the levels are written in lower case")
        for level in ["low", "medium", "high", "xhigh", "max"] {
            #expect(AIEffort.arguments(for: level) == ["--effort", level])
        }
        #expect(AIEffort.allCases.map(\.rawValue) == ["low", "medium", "high", "xhigh", "max"])
    }

    @Test func theCommandLineHasTheEffortOnlyWhenChosen() {
        func line(effort: String, resume: String? = nil, stream: Bool = false) -> [String] {
            ChatStore.arguments(prompt: "hi", streamInput: stream, model: "opus", effort: effort, config: "/tmp/c.json", sessionID: resume)
        }
        let auto = line(effort: "")
        #expect(!auto.contains("--effort"))
        #expect(auto.starts(with: ["-p", "hi", "--output-format", "stream-json"]) && auto.contains("--model") && auto.contains("--system-prompt"))
        let high = line(effort: "high")
        let at = high.firstIndex(of: "--effort")
        #expect(at != nil && high[at! + 1] == "high" && high[at! - 2] == "--model" && high[at! - 1] == "opus")
        #expect(high.filter { $0 != "--effort" && $0 != "high" } == auto, "nothing else changes")
        #expect(line(effort: "", resume: "abc").suffix(2) == ["--resume", "abc"])
        #expect(line(effort: "max", stream: true).starts(with: ["-p", "--input-format", "stream-json"]))
    }

    @Test func onlyAModelNameIsPassedOnTheCommandLine() {
        func line(_ model: String) -> [String] {
            ChatStore.arguments(prompt: "hi", streamInput: false, model: model, effort: "", config: "/tmp/c.json", sessionID: nil)
        }
        for good in ["sonnet", "opus", "haiku", "claude-sonnet-4-5", "claude-opus-4.1", "my_model-2", "a"] {
            #expect(line(good).contains("--model") && line(good).contains(good), "\(good)")
        }
        for bad in ["", "--dangerously-skip-permissions", "-x", " sonnet", "a b", "a;b", "a\nb", "sonnet\u{0}", ".hidden", "a/b", "ü"] {
            #expect(!line(bad).contains("--model"), "\(bad.debugDescription)")
            #expect(bad.isEmpty || !line(bad).contains(bad), "\(bad.debugDescription) is not passed at all")
        }
        #expect(AIModels.isPassable("sonnet") && !AIModels.isPassable("-p"))
    }

    @Test func aQuestionRevealsThePopOutWithoutTakingFocusFromAnotherApp() {
        #expect(ChatPopOut.reveal(miniaturized: false, appActive: true) == .init(restore: false, orderFront: true, askAttention: false))
        #expect(ChatPopOut.reveal(miniaturized: true, appActive: true) == .init(restore: true, orderFront: true, askAttention: false))
        #expect(ChatPopOut.reveal(miniaturized: false, appActive: false) == .init(restore: false, orderFront: false, askAttention: true), "another app is in front: only the Dock bounces")
        #expect(ChatPopOut.reveal(miniaturized: true, appActive: false) == .init(restore: true, orderFront: false, askAttention: true))
    }

    // MARK: Which window a card's keys come from

    @Test func aCardIsAnsweredOnlyFromTheWindowItIsShownIn() {
        let browser = Browser(), other = Browser()
        defer { browser.windowClosed(); other.windowClosed() }
        let browserWindow = NSWindow(), popOutWindow = NSWindow()
        let cards = [card(browser), card(other)]
        // Docked: the browser's own window.
        let docked: (Browser?) -> NSWindow? = { _ in browserWindow }
        #expect(ApprovalCards.card(in: cards, answeredFrom: browserWindow, host: docked)?.browser === browser)
        #expect(ApprovalCards.card(in: cards, answeredFrom: popOutWindow, host: docked) == nil)
        // Popped out: the pop-out window only, never the browser window the panel left.
        let popped: (Browser?) -> NSWindow? = { $0 === browser ? popOutWindow : browserWindow }
        #expect(ApprovalCards.card(in: cards, answeredFrom: popOutWindow, host: popped)?.browser === browser)
        #expect(ApprovalCards.card(in: [cards[0]], answeredFrom: browserWindow, host: popped) == nil, "Return or Esc in the browser window leaves the pop-out's card alone")
        #expect(ApprovalCards.card(in: cards, answeredFrom: browserWindow, host: popped)?.browser === other, "a card of another window's panel is not touched either")
        #expect(ApprovalCards.card(in: [card(nil)], answeredFrom: browserWindow) == nil, "a card with no browser has no window")
    }

    @Test func theKeysThatSayYesWakeAfterTheCardAndAfterItsWindowBecameKey() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let shown = now.addingTimeInterval(-10)
        #expect(ApprovalKeys.armedFor(shownAt: shown, windowKeyAt: nil, now: now) == 10, "the window was key all along: the card's own time")
        #expect(ApprovalKeys.armedFor(shownAt: shown, windowKeyAt: now.addingTimeInterval(-20), now: now) == 10, "an earlier key time changes nothing")
        let justKey = ApprovalKeys.armedFor(shownAt: shown, windowKeyAt: now.addingTimeInterval(-0.1), now: now)
        #expect(abs(justKey - 0.1) < 0.0001 && !ApprovalKeys.yesArmed(shownFor: justKey), "a window that has just become key can't be answered with yes yet")
        #expect(ApprovalKeys.yesArmed(shownFor: ApprovalKeys.armedFor(shownAt: shown, windowKeyAt: now.addingTimeInterval(-0.6), now: now)))
        #expect(ApprovalKeys.armedFor(shownAt: now, windowKeyAt: now.addingTimeInterval(-5), now: now) == 0, "and the card's own time counts too")
    }

    @Test func theKeysThatSayYesNeedTheBoxOrACardFocusedInThatSameWindow() {
        let here = NSWindow(), elsewhere = NSWindow()
        #expect(ApprovalCards.inPanel(composerFocused: true, cardFocusWindow: nil, eventWindow: here, firstResponderIsText: true))
        #expect(ApprovalCards.inPanel(composerFocused: false, cardFocusWindow: here, eventWindow: here, firstResponderIsText: false))
        #expect(!ApprovalCards.inPanel(composerFocused: false, cardFocusWindow: elsewhere, eventWindow: here, firstResponderIsText: false), "the card was focused in another window")
        #expect(!ApprovalCards.inPanel(composerFocused: false, cardFocusWindow: nil, eventWindow: here, firstResponderIsText: false))
        #expect(!ApprovalCards.inPanel(composerFocused: false, cardFocusWindow: here, eventWindow: here, firstResponderIsText: true), "a text field elsewhere in the window is not the card")
    }

    @Test func aCardsFocusIsRecordedForTheWindowItIsShownInNotWhicheverIsKey() {
        let browser = Browser()
        let popOut = ChatPopOut.shared
        defer { popOut.close(dock: false); browser.windowClosed() }
        browser.showChat = false
        popOut.open(for: browser)
        let cards = ApprovalCards.shared
        defer { cards.noteCardFocus(false, in: nil) }
        cards.noteCardFocus(true, of: card(browser))
        #expect(popOut.window != nil && cards.focusedWindow === popOut.window)
        cards.noteCardFocus(false, of: card(browser))
        #expect(cards.focusedWindow == nil)
        cards.noteCardFocus(true, of: card(nil))
        #expect(cards.focusedWindow == nil, "a card with no window has none to record")
    }

    @Test func theFocusOfACardIsForgottenWhenItsWindowStopsBeingKey() {
        let cards = ApprovalCards.shared
        let window = NSWindow(), other = NSWindow()
        cards.noteCardFocus(true, in: window)
        #expect(cards.focusedWindow === window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        #expect(cards.focusedWindow === window, "another window resigning changes nothing")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(cards.focusedWindow == nil)
        cards.noteCardFocus(true, in: window)
        cards.noteCardFocus(false, in: window)
        #expect(cards.focusedWindow == nil)
    }

    @Test func theModelChipSaysTheEffortOnlyWhenThereIsOne() {
        #expect(AIEffort.label(model: "sonnet", effort: "") == "Sonnet")
        #expect(AIEffort.label(model: "sonnet", effort: "high") == "Sonnet · High")
        #expect(AIEffort.label(model: "opus", effort: "xhigh") == "Opus · Extra High")
        #expect(AIEffort.label(model: "claude-x", effort: "bogus") == "claude-x", "a model set some other way is shown as it is")
    }

    // MARK: Approval modes

    @Test func theOldSwitchBecomesAMode() {
        #expect(AIApprovalMode.initial(stored: nil, legacy: nil) == .afterReading, "new installs ask as before")
        #expect(AIApprovalMode.initial(stored: nil, legacy: true) == .afterReading)
        #expect(AIApprovalMode.initial(stored: nil, legacy: false) == .irreversibleOnly)
        #expect(AIApprovalMode.initial(stored: "everyAction", legacy: false) == .everyAction, "the mode chosen later wins")
        #expect(AIApprovalMode.initial(stored: "irreversibleOnly", legacy: false) == .irreversibleOnly)
        #expect(AIApprovalMode.initial(stored: "irreversibleOnly", legacy: nil) == .irreversibleOnly)
        #expect(AIApprovalMode.initial(stored: "irreversibleOnly", legacy: true) == .afterReading, "an older version turned asking back on: that wins")
        #expect(AIApprovalMode.initial(stored: "everyAction", legacy: true) == .everyAction)
        #expect(AIApprovalMode.initial(stored: "nonsense", legacy: false) == .afterReading, "a mode key that doesn't read is the default, never the weakest mode")
        #expect(AIApprovalMode.initial(stored: "nonsense", legacy: nil) == .afterReading)
        #expect(AIApprovalMode.initial(stored: "", legacy: false) == .afterReading)
        #expect(AIApprovalMode.initial(stored: 2, legacy: false) == .afterReading, "a key that holds something else than a string is still a key")
        #expect(AIApprovalMode.initial(stored: ["irreversibleOnly"], legacy: false) == .afterReading)
        #expect(AIApprovalMode.initial(stored: true, legacy: nil) == .afterReading)
    }

    @Test func usingAPageIsAskedAboutPerMode() {
        #expect(!Approvals.asksForInteraction(.irreversibleOnly, readOtherSites: true))
        #expect(!Approvals.asksForInteraction(.irreversibleOnly, readOtherSites: false))
        #expect(Approvals.asksForInteraction(.afterReading, readOtherSites: true))
        #expect(!Approvals.asksForInteraction(.afterReading, readOtherSites: false))
        #expect(Approvals.asksForInteraction(.everyAction, readOtherSites: true))
        #expect(Approvals.asksForInteraction(.everyAction, readOtherSites: false))
        #expect(AIApprovalMode.afterReading.asksAboutOtherSites && AIApprovalMode.everyAction.asksAboutOtherSites && !AIApprovalMode.irreversibleOnly.asksAboutOtherSites)
    }

    // MARK: Title, elapsed time, context

    @Test func theChatIsNamedByWhatTheUserFirstWrote() {
        #expect(ChatTitle.text(first: nil) == "New chat" && ChatTitle.text(first: "") == "New chat" && ChatTitle.text(first: "  \n ") == "New chat")
        #expect(ChatTitle.text(first: "Compare these two phones") == "Compare these two phones")
        #expect(ChatTitle.text(first: "Line one\nline two") == "Line one line two", "on one line")
        let long = String(repeating: "word ", count: 30)
        let cut = ChatTitle.text(first: long)
        #expect(cut.hasSuffix("…") && cut.count <= ChatTitle.limit + 1 && !cut.contains(" …"))
        #expect(ChatTitle.text(of: []) == "New chat")
        #expect(ChatTitle.text(of: [ChatItem(kind: .note, text: "x"), ChatItem(kind: .user, text: "first"), ChatItem(kind: .user, text: "second")]) == "first")
    }

    @Test func elapsedTimeIsToldInTheUsersLanguage() {
        let english = Locale(identifier: "en")
        #expect(ElapsedText.text(seconds: 0, locale: english) == "0s")
        #expect(ElapsedText.text(seconds: 4, locale: english) == "4s")
        #expect(ElapsedText.text(seconds: 59, locale: english) == "59s")
        #expect(ElapsedText.text(seconds: 65, locale: english) == "1m 5s")
        #expect(ElapsedText.text(seconds: 600, locale: english).hasPrefix("10m"))
        #expect(ElapsedText.text(seconds: -3, locale: english) == "0s", "a clock that went back shows no negative time")
        #expect(ElapsedText.text(seconds: 4, locale: Locale(identifier: "ko")) == "4초")
    }

    @Test func contextUsageIsInputPlusCacheAgainstTheWindow() {
        #expect(ContextUsage.tokens(in: ["input_tokens": 3, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 45_000, "output_tokens": 99]) == 46_003, "output is not context")
        #expect(ContextUsage.tokens(in: ["input_tokens": 12]) == 12)
        #expect(ContextUsage.tokens(in: ["output_tokens": 5]) == nil && ContextUsage.tokens(in: [:]) == nil)
        let models: [String: Any] = ["a": ["contextWindow": 200_000], "b": ["contextWindow": 1_000_000], "c": ["costUSD": 1.0]]
        #expect(ContextUsage.window(inModelUsage: models) == 1_000_000)
        #expect(ContextUsage.window(inModelUsage: [:]) == nil)
        let usage = ContextUsage(used: 46_000, window: 200_000)
        #expect(usage.fraction == 0.23 && usage.percentText == "23%")
        #expect(ContextUsage(used: 300_000, window: 200_000).fraction == 1, "never over the ring")
        #expect(ContextUsage(used: 5, window: 0).fraction == 0)
        #expect(ContextUsage.short(900) == "900" && ContextUsage.short(46_000) == "46k" && ContextUsage.short(1_250_000) == "1.2M")
        #expect(usage.tooltip.contains("23%") && usage.tooltip.contains("46k") && usage.tooltip.contains("200k"))
    }

    // MARK: What was attached

    @Test func aPageIsKeptAsItsTitleAndSiteOnly() throws {
        let page = AttachedPage(title: "Phones", host: "shop.example", tabID: 7)
        let item = ChatItem(kind: .user, text: "hi", pages: [page])
        let json = try #require(String(data: JSONEncoder().encode(item), encoding: .utf8))
        #expect(json.contains("shop.example") && json.contains("Phones") && !json.contains("tabID") && !json.contains("7"))
        let back = try JSONDecoder().decode(ChatItem.self, from: JSONEncoder().encode(item))
        #expect(back.pages == [AttachedPage(title: "Phones", host: "shop.example")] && back.pages[0].tabID == nil)
        let old = try JSONDecoder().decode(ChatItem.self, from: Data(#"{"kind":"user","text":"old"}"#.utf8))
        #expect(old.pages.isEmpty && old.text == "old", "a chat kept before pages existed still reads")
    }
}

extension SharedAgentState {
    @MainActor @Suite
    struct AIControlsTests {
        private func open(_ addresses: [String]) -> (Browser, [Tab]) {
            let browser = Browser()
            browser.focused()
            return (browser, addresses.map { browser.openTab(url: URL(string: $0), activate: false) })
        }

        /// Runs `body` in a mode, every question answered by `answer`; the stand has what was asked.
        private func mode(_ mode: AIApprovalMode, answer: @escaping (Approvals.Prompt) -> Approvals.Choice = { _ in .once }, _ body: (Approvals.Stand) async throws -> Void) async rethrows {
            let before = Preferences.shared.aiApprovalMode
            Preferences.shared.aiApprovalMode = mode
            defer { Preferences.shared.aiApprovalMode = before }
            let stand = Approvals.Stand(answer)
            try await Approvals.$stand.withValue(stand) { try await body(stand) }
        }

        // MARK: The preference

        @Test func theOldSwitchAndTheModeStayInStep() {
            let before = Preferences.shared.aiApprovalMode
            defer { Preferences.shared.aiApprovalMode = before }
            Preferences.shared.aiApprovals = false
            #expect(Preferences.shared.aiApprovalMode == .irreversibleOnly && !Preferences.shared.aiApprovals)
            Preferences.shared.aiApprovals = true
            #expect(Preferences.shared.aiApprovalMode == .afterReading && Preferences.shared.aiApprovals)
            Preferences.shared.aiApprovalMode = .everyAction
            #expect(Preferences.shared.aiApprovals)
            Preferences.shared.aiApprovals = true
            #expect(Preferences.shared.aiApprovalMode == .everyAction, "on is on: the stricter mode is not weakened")
            Preferences.shared.aiApprovals = false
            #expect(Preferences.shared.aiApprovalMode == .irreversibleOnly)
            #expect(UserDefaults.standard.object(forKey: "aiApprovals") as? Bool == false, "an older version reads the switch")
            Preferences.shared.aiApprovalMode = .afterReading
            #expect(UserDefaults.standard.string(forKey: "aiApprovalMode") == "afterReading" && UserDefaults.standard.object(forKey: "aiApprovals") as? Bool == true)
        }

        // MARK: Each mode

        @Test func afterReadingAsksOnlyOnceAnotherSiteWasRead() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await mode(.afterReading) { stand in
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: panel))
                #expect(stand.asked.isEmpty, "nothing read: not asked")
                Approvals.noteRead(tabs[0], caller: panel)
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 1 && stand.asked[0].parts?.readLine.contains("a.example") == true)
            }
        }

        @Test func askingBeforeEveryActionAsksEvenWhenNothingElseWasRead() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await mode(.everyAction) { stand in
                #expect(await Approvals.allowInteraction(.type("hello"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 1, "asked with nothing read")
                let first = stand.asked[0]
                #expect(first.choices == [.deny, .once, .site], "the site for the chat is offered where it was")
                #expect(first.parts?.readLine == "" && !first.detail.contains("Read earlier") && first.parts?.site == "b.example" && first.parts?.text == "hello")
                #expect(first.parts?.why == "You chose to be asked before every action.")
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 2, "once is once")
            }
            await mode(.everyAction, answer: { _ in .deny }) { stand in
                #expect(!(await Approvals.allowInteraction(.type("hello"), on: tabs[1], caller: panel)))
                #expect(!(await Approvals.allowInteraction(.type("hello"), on: tabs[1], caller: panel)))
                #expect(stand.asked.count == 2, "no is asked again")
            }
        }

        @Test func allowingASiteForTheChatHoldsUntilAnotherSiteIsRead() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await mode(.everyAction, answer: { $0.choices.contains(.site) ? .site : .once }) { stand in
                #expect(await Approvals.allowInteraction(.type("one"), on: tabs[1], caller: panel))
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 1, "allowed for the chat: not asked again")
                #expect(Approvals.sitesAllowed(caller: panel) == ["b.example"], "listed, to take back")
                Approvals.noteRead(tabs[0], caller: panel)
                #expect(await Approvals.allowInteraction(.type("two"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 2 && stand.asked[1].parts?.readLine.contains("a.example") == true, "reading another site takes the allowance back")
                Approvals.revoke(site: "b.example", caller: panel)
                #expect(await Approvals.allowInteraction(.type("three"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 3)
            }
        }

        @Test func askingOnlyForWhatCantBeUndoneAsksAboutNoUseOfAPage() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await mode(.irreversibleOnly) { stand in
                Approvals.noteRead(tabs[0], caller: panel)
                #expect(await Approvals.allowInteraction(.type("hi"), on: tabs[1], caller: panel))
                #expect(await Approvals.allowTab(tabs[0], caller: panel))
                #expect(await Approvals.allowNavigation(URL(string: "https://x.example/page?q=1")!, caller: panel))
                #expect(Approvals.mayShow(tabs[0], caller: panel))
                #expect(stand.asked.isEmpty)
            }
        }

        @Test func otherTabsAndAddressesAreAskedAboutInTheTwoModesThatAsk() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            for asking in [AIApprovalMode.afterReading, .everyAction] {
                await mode(asking, answer: { _ in .deny }) { stand in
                    #expect(!(await Approvals.allowTab(tabs[1], caller: panel)), "\(asking)")
                    #expect(!(await Approvals.allowNavigation(URL(string: "https://never-seen.example/page?q=1")!, caller: panel)), "\(asking)")
                    #expect(stand.asked.count == 2)
                }
            }
        }

        @Test func whatCantBeUndoneIsAskedEveryTimeInEveryMode() async {
            let (browser, tabs) = open(["https://a.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            for each in AIApprovalMode.allCases {
                await mode(each, answer: { $0.irreversible ? .once : .deny }) { stand in
                    #expect(await Approvals.allowAction(.high, "Place order", on: tabs[0], caller: panel), "\(each)")
                    #expect(await Approvals.allowAction(.high, "Place order", on: tabs[0], caller: panel), "\(each): asked again")
                    #expect(stand.asked.count == 2 && stand.asked.allSatisfy { $0.irreversible && $0.choices == [.deny, .once] }, "\(each): no site for the chat")
                    let markup = await Approvals.allowAction(.low, "Accept all", on: tabs[0], caller: panel, markupOnly: true)
                    #expect(markup && stand.asked.count == 3 && stand.asked[2].irreversible && stand.asked[2].choices == [.deny, .once], "\(each): a banner only the page's markup calls one")
                }
            }
        }

        @Test func aSettingIsAskedAboutInEveryModeWithTheSiteForTheChatOffered() async {
            let (browser, tabs) = open(["https://a.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            for each in AIApprovalMode.allCases {
                await mode(each, answer: { _ in .once }) { stand in
                    #expect(await Approvals.allowAction(.low, "Save settings", on: tabs[0], caller: panel), "\(each)")
                    #expect(stand.asked.count == 1 && !stand.asked[0].irreversible && stand.asked[0].choices == [.deny, .once, .site], "\(each)")
                }
            }
        }

        @Test func signingInIsNotAskedTwiceBySayingEveryActionAsks() async {
            let (browser, tabs) = open(["https://a.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await mode(.everyAction) { stand in
                #expect(await Approvals.allowInteraction(.act("Signing in"), on: tabs[0], caller: panel, everyActionAsks: false))
                #expect(stand.asked.isEmpty, "the sign-in asks on its own")
                Approvals.noteRead(sites: ["other.example"], caller: panel)
                #expect(await Approvals.allowInteraction(.act("Signing in"), on: tabs[0], caller: panel, everyActionAsks: false))
                #expect(stand.asked.count == 1, "after reading another site it is asked as it always was")
            }
        }

        // MARK: The stream

        @Test func theContextRingFollowsTheUsageTheStreamReports() {
            let chat = ChatStore()
            #expect(chat.contextUsage == nil, "unknown: the ring is not shown")
            chat.handle(["type": "assistant", "message": ["id": "m1", "content": [], "usage": ["input_tokens": 4, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 9000, "output_tokens": 50]]])
            #expect(chat.contextUsage == ContextUsage(used: 10_004, window: ContextUsage.defaultWindow))
            chat.handle(["type": "assistant", "message": ["id": "m2", "content": [], "usage": ["input_tokens": 6, "cache_read_input_tokens": 20_000]]])
            #expect(chat.contextUsage?.used == 20_006, "the latest request is how full it is now, not the total")
            chat.handle(["type": "result", "usage": ["input_tokens": 99_999], "modelUsage": ["claude-sonnet": ["contextWindow": 1_000_000]]])
            #expect(chat.contextUsage == ContextUsage(used: 20_006, window: 1_000_000), "the window the result names replaces the default")
            chat.reset()
            #expect(chat.contextUsage == nil && chat.contextWindow == nil)
        }

        @Test func aResultAloneStillGivesTheRingSomethingToShow() {
            let chat = ChatStore()
            chat.handle(["type": "result", "usage": ["input_tokens": 10, "cache_read_input_tokens": 2000]])
            #expect(chat.contextUsage?.used == 2010)
            chat.handle(["type": "result", "usage": ["output_tokens": 3]])
            #expect(chat.contextUsage?.used == 2010, "a result without counts changes nothing")
        }

        @Test func aRunKnowsWhenItBegan() {
            let chat = ChatStore()
            #expect(chat.runStarted == nil)
            chat.isRunning = true
            let began = chat.runStarted
            #expect(began != nil)
            chat.isRunning = true
            #expect(chat.runStarted == began, "setting it again is not a new run")
            chat.isRunning = false
            #expect(chat.runStarted == nil)
        }

        // MARK: The pages a message went with

        @Test func aMessageCarriesTheCardsOfTheTabsItWentWith() {
            let (browser, tabs) = open(["https://www.front.example/a?q=secret#frag", "https://other.example/x", "about:blank"])
            defer { browser.windowClosed() }
            tabs[0].title = "Front page"
            tabs[1].title = "Other page"
            let cards = AttachedPage.cards(front: tabs[0], attached: [tabs[1], tabs[0], tabs[2]])
            #expect(cards == [AttachedPage(title: "Front page", host: "front.example", tabID: tabs[0].id), AttachedPage(title: "Other page", host: "other.example", tabID: tabs[1].id)],
                    "the front tab first, once, www dropped, no address beyond the site, nothing for a blank page")
            #expect(AttachedPage.cards(front: nil, attached: []).isEmpty)

            let chat = ChatStore()
            chat.launch = { _, _ in true }
            defer { chat.reset() }
            chat.attach([tabs[1]])
            Browser.recent?.activate(tabs[0].id)
            chat.send("compare these")
            let user = chat.items.first { $0.kind == .user }
            #expect(user?.pages.map(\.host).contains("other.example") == true && user?.pages.allSatisfy { !$0.title.isEmpty } == true)
        }

        @Test func thePagesOfAMessageAreKeptInTheHistoryAsWordsOnly() throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("chats-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let history = ChatHistory(file: file)
            let id = UUID()
            history.record(id: id, started: Date(), items: [ChatItem(kind: .user, text: "hi", pages: [AttachedPage(title: "Phones", host: "shop.example", tabID: 3)]), ChatItem(kind: .assistant, text: "ok")])
            #expect(history.chats[0].items[0].pages == [AttachedPage(title: "Phones", host: "shop.example")], "no tab to find an icon in")
            let again = ChatHistory(file: file)
            #expect(again.chats.first?.id == id && again.chats[0].items[0].pages == [AttachedPage(title: "Phones", host: "shop.example")])
        }

        // MARK: The window

        @Test func poppingOutHidesThePanelInTheBrowserAndClosingDocksItBack() {
            let (browser, _) = open(["https://a.example/"])
            let popOut = ChatPopOut.shared
            defer { popOut.close(dock: false); browser.windowClosed() }
            browser.showChat = true
            popOut.open(for: browser)
            #expect(popOut.isPoppedOut(for: browser) && popOut.panelBrowser === browser && !browser.showChat, "not shown in the browser window")
            browser.showChat = true
            #expect(!browser.showChat, "asking for the panel while it is out brings the window forward instead of showing a second one")
            popOut.close(dock: true)
            #expect(popOut.window == nil && popOut.panelBrowser == nil && browser.showChat, "closing the window docks it back")
            popOut.open(for: browser)
            popOut.close(dock: false)
            #expect(!browser.showChat && !popOut.isPoppedOut(for: browser), "the panel's own close button closes it for good")
        }

        @Test func theQuestionsOfAPoppedOutPanelStayOnCardsInItsWindow() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            let popOut = ChatPopOut.shared
            defer { popOut.close(dock: false); browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            browser.showChat = false
            popOut.open(for: browser)
            let before = Preferences.shared.aiApprovalMode
            Preferences.shared.aiApprovalMode = .afterReading
            defer { Preferences.shared.aiApprovalMode = before }
            let stand = Approvals.Stand { _ in .once }
            stand.holds = true
            await Approvals.$stand.withValue(stand) {
                Approvals.noteRead(tabs[0], caller: panel)
                let task = Task { await Approvals.allowInteraction(.type("hi"), on: tabs[1], caller: panel) }
                #expect(await waitUntil(5) { !ApprovalCards.shared.cards.isEmpty })
                #expect(ApprovalCards.shared.first(for: browser) != nil, "a card for the panel in the window, not a sheet on the browser")
                #expect(ApprovalCards.hostWindow(for: browser) === popOut.window && popOut.window != nil, "its keys come from the pop-out window")
                Approvals.release(.once)
                #expect(await task.value)
            }
            #expect(ApprovalCards.shared.cards.isEmpty)
        }

        @Test func closingThePopOutMovesAWaitingQuestionToASheet() async {
            let (browser, _) = open(["https://a.example/"])
            let popOut = ChatPopOut.shared
            defer { popOut.close(dock: false); browser.windowClosed() }
            browser.showChat = false
            popOut.open(for: browser)
            var moved = 0
            let waiting = card(browser) { moved += 1 }
            ApprovalCards.shared.add(waiting)
            defer { ApprovalCards.shared.remove(waiting.id) }
            #expect(ApprovalCards.shared.first(for: browser)?.id == waiting.id)
            popOut.close(dock: false)
            #expect(moved == 1, "asked on the browser window instead")
            #expect(ApprovalCards.shared.cards.isEmpty, "and no longer on a card in a panel that is gone")
            #expect(ApprovalCards.hostWindow(for: browser) === browser.window, "docked or closed again: the browser's own window")
        }

        @Test func theAIButtonsReadAsOnWhileThePanelIsOut() {
            let (browser, _) = open(["https://a.example/"])
            let popOut = ChatPopOut.shared
            defer { popOut.close(dock: false); browser.windowClosed() }
            var told = 0
            let listener = browser.objectWillChange.sink { told += 1 }
            defer { listener.cancel() }
            browser.showChat = false
            let base = told
            popOut.open(for: browser)
            #expect(browser.panelShown && told > base, "the buttons are told to look again")
            let opened = told
            popOut.close(dock: false)
            #expect(!browser.panelShown && told > opened)
            browser.showChat = true
            #expect(browser.panelShown)
        }
    }
}
