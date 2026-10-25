import Foundation
import Testing
@testable import Changmun

/// What `claude` printed for a run with no login, captured with an empty config folder (`claude -p hi --output-format stream-json --verbose`):
/// exit code 1, nothing on stderr, and on stdout an assistant message flagged as an API error, then the error result.
private let notLoggedInAssistant: [String: Any] = [
    "type": "assistant", "error": "authentication_failed", "is_api_error_message": true,
    "message": ["role": "assistant", "content": [["type": "text", "text": "Not logged in · Please run /login"]]],
]
private let notLoggedInResult: [String: Any] = [
    "type": "result", "is_error": true, "subtype": "success", "terminal_reason": "api_error", "result": "Not logged in · Please run /login",
]

struct AIFailureTests {
    @Test func notBeingSignedInIsTold() {
        let failure = AIFailure.classify("Not logged in · Please run /login", code: "authentication_failed")
        #expect(failure.kind == .login && failure.offersLoginCommand && !failure.offersSettings)
        #expect(failure.details == "Not logged in · Please run /login", "the CLI's words are kept for the Details")
        #expect(AIFailure.classify("Not logged in · Please run /login").kind == .login, "the words alone are enough")
        #expect(AIFailure.classify("Invalid API key · Please run /login").kind == .login)
        #expect(AIFailure.classify("OAuth token has expired. Please obtain a new token or refresh your existing token.").kind == .login)
        #expect(AIFailure.classify("anything", status: 401).kind == .login)
    }

    @Test func aUsageLimitSaysWhenItResetsIfTheMessageDoes() {
        #expect(AIFailure.classify("You've hit your limit · resets 3pm (Asia/Seoul)").resets == "3pm (Asia/Seoul)")
        #expect(AIFailure.classify("5-hour limit reached ∙ resets 11:30pm").resets == "11:30pm")
        #expect(AIFailure.classify("Your usage limit will reset at 4am. Try later.").resets == "4am")
        let old = AIFailure.classify("Claude AI usage limit reached|1760000000")
        #expect(old.kind == .usageLimit && old.resets != nil, "the old timestamp form becomes a time")
        #expect(AIFailure.classify("Claude usage limit reached.").resets == nil)
        for text in ["Credit balance is too low", "API Error: 429 rate_limit_error: This request would exceed your rate limit", "Too many requests"] {
            #expect(AIFailure.classify(text).kind == .usageLimit, "\(text)")
        }
        #expect(AIFailure.classify("x", code: "rate_limit").kind == .usageLimit && AIFailure.classify("x", status: 429).kind == .usageLimit)
        #expect(AIFailure.classify("not a limit").resets == nil, "only a limit has a reset time")
    }

    @Test func networkAndBusyAreToldApart() {
        for text in ["API Error: Unable to connect to API (ENOTFOUND)", "getaddrinfo ENOTFOUND api.anthropic.com", "fetch failed", "Request timed out", "ECONNRESET", "The Internet connection appears to be offline."] {
            #expect(AIFailure.classify(text).kind == .network, "\(text)")
        }
        for text in ["API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}", "Service Unavailable", "502 Bad Gateway"] {
            #expect(AIFailure.classify(text).kind == .overloaded, "\(text)")
        }
        #expect(AIFailure.classify("x", status: 503).kind == .overloaded && AIFailure.classify("x", code: "server_error").kind == .overloaded)
    }

    @Test func anythingElseIsOtherAndKeepsItsWords() {
        let failure = AIFailure.classify("Something odd happened\nsecond line")
        #expect(failure.kind == .other && failure.details == "Something odd happened\nsecond line" && failure.explanation == "Something odd happened")
        #expect(!failure.offersLoginCommand && !failure.offersSettings)
    }

    @Test func aFailureSurvivesBeingKept() throws {
        let item = ChatItem(kind: .error, text: "x", failure: AIFailure(kind: .usageLimit, details: "limit", resets: "3pm"))
        let back = try JSONDecoder().decode(ChatItem.self, from: JSONEncoder().encode(item))
        #expect(back.failure == item.failure && back.text == "x")
    }
}

extension SharedAgentState {
    @MainActor
    struct AIPanelRowsTests {
        private func standIn() -> (chat: ChatStore, launched: () -> [String], prompts: () -> [String]) {
            let chat = ChatStore()
            chat.history = ChatHistory(file: FileManager.default.temporaryDirectory.appendingPathComponent("chats-\(UUID().uuidString).json"))
            let box = Launches()
            chat.launch = { box.messages.append($0); box.prompts.append($1); return true }
            return (chat, { box.messages }, { box.prompts })
        }

        private final class Launches { var messages: [String] = []; var prompts: [String] = [] }

        private func toolUse(_ id: String, _ name: String, _ input: [String: Any] = [:]) -> [String: Any] {
            ["type": "assistant", "message": ["id": "m-\(id)", "content": [["type": "tool_use", "id": id, "name": "mcp__changmun__" + name, "input": input]]]]
        }

        private func toolResult(_ id: String, _ text: String, error: Bool = false) -> [String: Any] {
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "is_error": error, "content": [["type": "text", "text": text]]]]]]
        }

        // MARK: Errors

        @Test func notBeingSignedInIsOneErrorRowOfTheRightKindAndTheApiMessageIsNotAnAnswer() {
            let (chat, _, _) = standIn()
            chat.submit("hi")
            chat.handle(notLoggedInAssistant)
            chat.handle(notLoggedInResult)
            chat.endRun()
            #expect(chat.items.map(\.kind) == [.user, .error], "not shown once as an answer and again as an error: \(chat.items.map(\.text))")
            #expect(chat.items.last?.failure?.kind == .login && chat.items.last?.text == "Not logged in · Please run /login")
        }

        @Test func aFailedResultIsClassifiedByItsOwnWordsWhateverCameBefore() {
            let (chat, _, _) = standIn()
            chat.submit("hi")
            chat.handle(notLoggedInAssistant)
            chat.endRun()
            #expect(chat.items.last?.kind != .error, "endRun alone adds nothing")
            chat.submit("again")
            chat.handle(["type": "result", "is_error": true, "result": "API Error: Unable to connect to API (ENOTFOUND)"])
            #expect(chat.items.last?.failure?.kind == .network)
        }

        @Test func tryAgainSendsTheLastMessageAgainWithoutShowingItTwice() {
            let (chat, launched, prompts) = standIn()
            chat.submit("first")
            chat.handle(["type": "system", "subtype": "init", "session_id": "s1"])
            chat.handle(["type": "result", "is_error": true, "result": "Overloaded"])
            chat.endRun()
            chat.submit("compare the prices")
            chat.handle(["type": "result", "is_error": true, "result": "API Error: 529 overloaded_error"])
            chat.endRun()
            #expect(chat.items.last?.failure?.kind == .overloaded)
            chat.retryLast()
            #expect(launched() == ["first", "compare the prices", "compare the prices"] && chat.isRunning)
            #expect(prompts().last?.contains("failed, so the user is asking again") == true && prompts().last?.contains("Earlier messages of this chat are not available") == true)
            #expect(chat.items.filter { $0.kind == .user }.map(\.text) == ["first", "compare the prices"], "the message is not shown twice")
            #expect(chat.items.filter { $0.kind == .error }.count == 1, "the failed row of this attempt went; the older one stays")
            chat.retryLast()
            #expect(launched().count == 3, "nothing is sent again while it runs")
        }

        // MARK: Steps

        @Test func eachStepIsMarkedWithHowItWentFromTheToolResult() {
            let (chat, _, _) = standIn()
            chat.submit("do it")
            chat.handle(toolUse("t1", "read_page"))
            chat.handle(toolUse("t2", "click", ["element_id": 3]))
            chat.handle(toolUse("t3", "navigate", ["url": "https://a.example/"]))
            chat.handle(toolUse("t4", "close_tab", ["tab_id": 9]))
            chat.handle(toolResult("t1", "page text"))
            chat.handle(toolResult("t2", "The user declined this in Changmun. Don't retry it.", error: true))
            chat.handle(toolResult("t3", "Couldn't load", error: true))
            #expect(chat.items.filter { $0.kind == .tool }.map(\.outcome) == [.ok, .denied, .failed, nil], "a step with no result yet has no outcome")
            chat.handle(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t4", "content": "Closed tab #9."]]]])
            #expect(chat.items.last?.outcome == .ok, "a result whose content is a string works too")
            #expect(chat.items.filter { $0.kind == .tool }.map(\.tool) == ["read_page", "click", "navigate", "close_tab"])
        }

        private func step(_ tool: String, _ outcome: StepOutcome? = .ok) -> ChatItem {
            ChatItem(kind: .tool, text: tool, tool: tool, outcome: outcome)
        }

        @Test func afterTheRunTheStepsFoldIntoOneRowAndTheFailedOnesStayOutside() {
            let user = ChatItem(kind: .user, text: "go")
            let items = [user, step("read_page"), step("click", .denied), step("scroll"), step("read_page"), ChatItem(kind: .assistant, text: "done")]
            let rows = ChatLayout.rows(items, running: false)
            guard case .folded(_, let folded) = rows[1] else { Issue.record("not folded: \(rows)"); return }
            #expect(folded.map(\.text) == ["read_page", "scroll", "read_page"])
            #expect(rows.count == 4 && rows[2] == .item(items[2]) && rows[3] == .item(items[5]), "the declined step is a row of its own, in front of the answer")
            let single = ChatLayout.rows([user, step("read_page"), ChatItem(kind: .assistant, text: "ok")], running: false)
            #expect(single.count == 3 && single[1] == .item(single.compactMap { if case .item(let i) = $0, i.kind == .tool { i } else { nil } }[0]), "one step is a chip, not a fold")
        }

        @Test func whileTheRunLastsOnlyTheLatestStepsShowAndFailuresAlwaysDo() {
            let steps = (0..<8).map { step("read_page_\($0)") }
            let rows = ChatLayout.rows([ChatItem(kind: .user, text: "go")] + steps, running: true)
            guard case .live(_, let hidden, let shown) = rows[1] else { Issue.record("\(rows)"); return }
            #expect(hidden == 4 && shown.map(\.text) == steps.suffix(4).map(\.text))
            let few = ChatLayout.rows([ChatItem(kind: .user, text: "go")] + steps.prefix(5), running: true)
            if case .live(_, let none, let all) = few[1] { #expect(none == 0 && all.count == 5, "up to five are all shown") } else { Issue.record("\(few)") }
            var withFailure = steps
            withFailure[1] = step("click", .failed)
            if case .live(_, let n, let kept) = ChatLayout.rows([ChatItem(kind: .user, text: "go")] + withFailure, running: true)[1] {
                #expect(n == 3 && kept.map(\.text).contains("click"), "a failed step is not counted among those left out")
            }
            if case .live = ChatLayout.rows([ChatItem(kind: .user, text: "go"), step("a"), step("b")], running: false)[1] { Issue.record("a run that is over is not live") }
        }

        @Test func aTurnThatChangedTabsEndsWithWhatItDid() {
            let items = [ChatItem(kind: .user, text: "tidy"), step("open_tab"), step("open_tab"), step("close_tab"), step("close_tab", .failed), step("navigate"),
                         ChatItem(kind: .assistant, text: "done"), ChatItem(kind: .user, text: "thanks"), ChatItem(kind: .assistant, text: "welcome")]
            let rows = ChatLayout.rows(items, running: false)
            let summaries = rows.compactMap { row -> TurnSummary? in if case .summary(let s) = row { s } else { nil } }
            #expect(summaries.count == 1 && summaries[0].opened == 2 && summaries[0].closed == 1 && summaries[0].navigated == 1 && summaries[0].turn == 1, "only works that worked count: \(summaries)")
            guard case .summary = rows[rows.firstIndex { $0 == .item(items[6]) }! + 1] else { Issue.record("the line follows the answer of its turn"); return }
            let live = ChatLayout.rows(Array(items.prefix(6)), running: true)
            #expect(!live.contains { if case .summary = $0 { true } else { false } }, "none until the run is over")
            #expect(!summaries[0].text.isEmpty)
        }

        // MARK: Tabs the AI closed

        @Test func tabsTheAIClosedCanBeBroughtBackWhileTheyAreStillAmongTheClosedOnes() {
            let browser = Browser()
            browser.focused()
            defer { browser.windowClosed() }
            let keep = browser.openTab(url: URL(string: "https://keep.example/"), activate: false)
            let first = browser.openTab(url: URL(string: "https://one.example/"), activate: false)
            let second = browser.openTab(url: URL(string: "https://two.example/"), activate: false)
            let (chat, _, _) = standIn()
            chat.submit("close them")
            for tab in [first, second] {
                browser.close(tab.id)
                chat.noteClosed(browser.closedTabs.last!.id, in: browser)
            }
            #expect(chat.canReopen(turn: 1) && !chat.canReopen(turn: 2))
            chat.reopenClosed(turn: 1)
            #expect(browser.tabs.map(\.url?.host) == [keep.url?.host, "one.example", "two.example"], "back in their places: \(browser.tabs.map(\.url?.host))")
            #expect(!chat.canReopen(turn: 1) && browser.closedTabs.isEmpty)
            #expect(!browser.reopenClosedTab(id: UUID()))
        }

        // MARK: History

        private func tempFile() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("chats-\(UUID().uuidString).json") }

        @Test func chatsAreKeptNewestFirstAndComeBackFromTheFile() throws {
            let file = tempFile()
            defer { try? FileManager.default.removeItem(at: file) }
            let history = ChatHistory(file: file)
            let step = ChatItem(kind: .tool, text: "Read page", symbol: "doc.text", title: "Reading", tool: "read_page", outcome: .ok)
            let id = UUID()
            history.record(id: id, started: Date(timeIntervalSinceNow: -100), items: [ChatItem(kind: .user, text: "old"), step], now: Date(timeIntervalSinceNow: -100))
            history.record(id: UUID(), started: Date(), items: [ChatItem(kind: .user, text: "new\nline"), ChatItem(kind: .error, text: "x", failure: .init(kind: .network, details: "x"))])
            history.record(id: UUID(), started: Date(), items: [ChatItem(kind: .assistant, text: "no user message")])
            #expect(history.chats.map(\.title) == ["new line", "old"], "newest first; a chat with no message of the user is not kept")
            let again = ChatHistory(file: file)
            #expect(again.chats.map(\.title) == ["new line", "old"] && again.chats[1].items[1].outcome == .ok && again.chats[0].items[1].failure?.kind == .network)
            again.record(id: id, started: Date(), items: [ChatItem(kind: .user, text: "old"), ChatItem(kind: .assistant, text: "more")])
            #expect(again.chats.count == 2 && again.chats[0].items.count == 2 && again.chats[0].id == id, "the same chat is replaced, and moves to the top")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "only the user can read it")
        }

        @Test func theOldestChatsArePrunedPastTheLimitAndSingleChatsCanBeDeletedOrAllCleared() {
            let file = tempFile()
            defer { try? FileManager.default.removeItem(at: file) }
            let history = ChatHistory(file: file, limit: 3)
            var ids: [UUID] = []
            for number in 0..<5 {
                ids.append(UUID())
                history.record(id: ids[number], started: Date(), items: [ChatItem(kind: .user, text: "chat \(number)")], now: Date(timeIntervalSinceNow: Double(number)))
            }
            #expect(history.chats.map(\.title) == ["chat 4", "chat 3", "chat 2"])
            history.delete(ids[3])
            #expect(ChatHistory(file: file, limit: 3).chats.map(\.title) == ["chat 4", "chat 2"], "deleted for good")
            history.clear()
            #expect(history.chats.isEmpty && ChatHistory(file: file).chats.isEmpty)
            #expect(ChatHistory.maxChats == 200)
        }

        @Test func aDamagedFileIsNoHistoryRatherThanACrash() throws {
            let file = tempFile()
            defer { try? FileManager.default.removeItem(at: file) }
            try Data("not json".utf8).write(to: file)
            #expect(ChatHistory(file: file).chats.isEmpty)
        }

        @Test func aChatIsKeptWhenItsRunEndsAndStartsAnotherAfterNewChat() {
            let (chat, _, _) = standIn()
            chat.submit("first question")
            chat.handle(["type": "assistant", "message": ["id": "m1", "content": [["type": "text", "text": "an answer"]]]])
            chat.endRun()
            #expect(chat.history.chats.count == 1 && chat.history.chats[0].items.map(\.text) == ["first question", "an answer"])
            chat.submit("second")
            chat.endRun()
            #expect(chat.history.chats.count == 1 && chat.history.chats[0].items.count == 3, "the same chat, updated")
            chat.reset()
            chat.submit("another chat")
            chat.endRun()
            #expect(chat.history.chats.map(\.title) == ["another chat", "first question"])
        }

        @Test func nothingIsKeptWhenTurnedOffOrAfterAPrivateWindowWasInFront() {
            let before = Preferences.shared.aiKeepHistory
            defer { Preferences.shared.aiKeepHistory = before }
            Preferences.shared.aiKeepHistory = false
            let (off, _, _) = standIn()
            off.submit("hello")
            off.endRun()
            #expect(off.history.chats.isEmpty)
            Preferences.shared.aiKeepHistory = true

            let (chat, _, _) = standIn()
            chat.submit("in the open")
            chat.endRun()
            #expect(chat.history.chats.count == 1)
            let hidden = Browser(isPrivate: true)
            hidden.focused()
            defer { hidden.windowClosed() }
            chat.submit("in private")
            chat.endRun()
            #expect(chat.history.chats.isEmpty, "what was kept of this chat goes too, and nothing more is kept")
            chat.reset()
            #expect(chat.history.chats.isEmpty)
            hidden.windowClosed()
            chat.submit("open again")
            chat.endRun()
            #expect(chat.history.chats.map(\.title) == ["open again"], "a new chat is kept again")
        }

        @Test func aMessageWrittenInAPrivateWindowKeepsTheChatPrivateWhenItIsSentLaterFromAnotherWindow() {
            let normal = Browser()
            normal.focused()
            defer { normal.windowClosed() }
            let (queued, launched, _) = standIn()
            queued.submit("in the open")
            let hidden = Browser(isPrivate: true)
            hidden.focused()
            defer { hidden.windowClosed() }
            #expect(queued.submit("written in private"), "queued while the run lasts")
            hidden.windowClosed()
            #expect(Browser.current === normal)
            queued.endRun()
            #expect(launched() == ["in the open", "written in private"], "sent now, with a normal window in front")
            queued.endRun()
            #expect(queued.history.chats.isEmpty, "a chat that ever had a private message is never kept")

            let (steered, _, _) = standIn()
            steered.submit("in the open")
            steered.handle(["type": "system", "subtype": "init", "session_id": "s-private"])
            let hiddenAgain = Browser(isPrivate: true)
            hiddenAgain.focused()
            defer { hiddenAgain.windowClosed() }
            #expect(steered.steer("redirect, written in private"))
            hiddenAgain.windowClosed()
            steered.endRun()
            #expect(steered.history.chats.isEmpty)

            let (open, _, _) = standIn()
            open.submit("in the open")
            open.submit("also in the open")
            open.endRun()
            open.endRun()
            #expect(open.history.chats.count == 1 && open.history.chats[0].items.count == 2)
        }

        @Test func aPrivateMessageThatWaitsInTheQueueDeletesWhatWasKeptAtOnce() {
            let normal = Browser()
            normal.focused()
            defer { normal.windowClosed() }
            let (chat, _, _) = standIn()
            chat.submit("first")
            chat.endRun()
            #expect(chat.history.chats.count == 1)
            chat.submit("second")
            let hidden = Browser(isPrivate: true)
            hidden.focused()
            defer { hidden.windowClosed() }
            chat.submit("third, private")
            #expect(chat.history.chats.isEmpty, "gone when the message is written, not when it goes out")
        }

        @Test func aChatReadsBackAsText() {
            let stored = StoredChat(id: UUID(), started: Date(), updated: Date(), items: [
                ChatItem(kind: .user, text: "q1\nq2"), step("read_page"), ChatItem(kind: .assistant, text: "the **answer**"), ChatItem(kind: .error, text: "boom"),
            ])
            #expect(stored.plainText == "> q1\n> q2\n\nthe **answer**\n\nboom")
        }
    }
}

struct MarkdownBlockTests {
    private func parse(_ text: String) -> [MarkdownBlock] { ChatMarkdown.parse(text) }

    private func struck(_ text: AttributedString) -> String {
        text.runs.filter { $0.inlinePresentationIntent?.contains(.strikethrough) == true }.map { String(text[$0.range].characters) }.joined()
    }

    @Test func aTildeForARangeIsNotAStrikethrough() {
        let ranges = ChatMarkdown.inline("3~5개, 10~20분 걸려요")
        #expect(String(ranges.characters) == "3~5개, 10~20분 걸려요")
        #expect(struck(ranges).isEmpty)
        let doubled = ChatMarkdown.inline("가격은 ~~만 원~~ 오천 원이에요")
        #expect(struck(doubled) == "만 원")
        let code = ChatMarkdown.inline("`a~b~c` 그리고 x~y~z")
        #expect(String(code.characters) == "a~b~c 그리고 x~y~z")
        #expect(struck(code).isEmpty)
    }

    @Test func paragraphsKeepTheirLineBreaksAndAreSeparatedByBlankLines() {
        #expect(parse("one\ntwo\n\nthree") == [.paragraph("one\ntwo"), .paragraph("three")])
        #expect(parse("").isEmpty && parse("\n\n").isEmpty)
    }

    @Test func fencedCodeKeepsEverythingInsideAsIsAndAnUnfinishedOneRunsToTheEnd() {
        #expect(parse("before\n```swift\nlet a = 1\n\n# not a heading\n- not a list\n```\nafter") ==
                [.paragraph("before"), .code(language: "swift", text: "let a = 1\n\n# not a heading\n- not a list"), .paragraph("after")])
        #expect(parse("```\nstreaming") == [.code(language: nil, text: "streaming")])
        #expect(parse("~~~sh\nls\n~~~") == [.code(language: "sh", text: "ls")])
        #expect(parse("````\n```\ninner\n```\n````") == [.code(language: nil, text: "```\ninner\n```")], "a longer fence is closed only by an equally long one")
        #expect(parse("```not a fence```") == [.paragraph("```not a fence```")])
    }

    @Test func listsBulletedNumberedAndNested() {
        #expect(parse("- a\n- b\n  - c\n    - d\n- e") == [.list([
            .init(depth: 0, marker: "•", text: "a"), .init(depth: 0, marker: "•", text: "b"), .init(depth: 1, marker: "•", text: "c"),
            .init(depth: 2, marker: "•", text: "d"), .init(depth: 0, marker: "•", text: "e"),
        ])])
        #expect(parse("1. one\n2. two\n10) ten") == [.list([.init(depth: 0, marker: "1.", text: "one"), .init(depth: 0, marker: "2.", text: "two"), .init(depth: 0, marker: "10)", text: "ten")])])
        #expect(parse("* a\n\n* b") == [.list([.init(depth: 0, marker: "•", text: "a"), .init(depth: 0, marker: "•", text: "b")])], "a blank line inside a list")
        #expect(parse("- a\n  more of a\n- b") == [.list([.init(depth: 0, marker: "•", text: "a\nmore of a"), .init(depth: 0, marker: "•", text: "b")])])
        #expect(parse("text\n- a") == [.paragraph("text"), .list([.init(depth: 0, marker: "•", text: "a")])])
        #expect(parse("-5 degrees") == [.paragraph("-5 degrees")], "a dash with no space is text")
    }

    @Test func headingsQuotesAndRules() {
        #expect(parse("# One\n## Two ##\n###### Six\n####### seven") == [.heading(level: 1, text: "One"), .heading(level: 2, text: "Two"), .heading(level: 6, text: "Six"), .paragraph("####### seven")])
        #expect(parse("#hashtag") == [.paragraph("#hashtag")])
        #expect(parse("> quoted\n> more\n\nplain") == [.quote([.paragraph("quoted\nmore")]), .paragraph("plain")])
        #expect(parse("> - a\n> - b") == [.quote([.list([.init(depth: 0, marker: "•", text: "a"), .init(depth: 0, marker: "•", text: "b")])])])
        #expect(parse("a\n\n---\n\nb") == [.paragraph("a"), .rule, .paragraph("b")])
        #expect(parse("***") == [.rule])
    }

    @Test func simpleTablesAreTablesAndOtherPipesAreText() {
        #expect(parse("| Name | Price |\n|---|:--:|\n| A | 1 |\n| B \\| x | 2 |\nafter") ==
                [.table(header: ["Name", "Price"], rows: [["A", "1"], ["B | x", "2"]]), .paragraph("after")])
        #expect(parse("a | b\n--|--\n1 | 2") == [.table(header: ["a", "b"], rows: [["1", "2"]])], "no outer pipes")
        #expect(parse("| a | b |\n|---|---|\n| only |") == [.table(header: ["a", "b"], rows: [["only", ""]])], "a short row is filled")
        #expect(parse("this | that") == [.paragraph("this | that")])
    }

    @Test func inlineStylingStillWorksAndLinksStayLinks() {
        let text = ChatMarkdown.inline("**bold** and [a link](https://example.com/) and `code`")
        #expect(String(text.characters) == "bold and a link (example.com) and code", "a link says where it goes")
        #expect(text.runs.contains { $0.link?.absoluteString == "https://example.com/" })
    }
}
