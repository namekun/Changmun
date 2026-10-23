import AppKit
import Foundation
import Testing
@testable import Changmun

@MainActor
struct AIPanelSecurityTests {
    // MARK: Markdown nesting

    private func quoteDepth(_ blocks: [MarkdownBlock]) -> Int {
        blocks.map { block -> Int in
            if case .quote(let inner) = block { return 1 + quoteDepth(inner) }
            return 0
        }.max() ?? 0
    }

    @Test func aThousandsDeepQuoteIsCutAndFast() {
        let start = Date()
        let line = parseDepth(String(repeating: ">", count: 50_000) + " text")
        let lines = parseDepth(String(repeating: ">\n", count: 50_000))
        let nested = parseDepth((0..<5000).map { String(repeating: ">", count: $0 % 200 + 1) + " x" }.joined(separator: "\n"))
        #expect(line <= ChatMarkdown.maxQuoteDepth && lines <= ChatMarkdown.maxQuoteDepth && nested <= ChatMarkdown.maxQuoteDepth)
        #expect(Date().timeIntervalSince(start) < 3, "no parse of this takes seconds")
    }

    private func parseDepth(_ text: String) -> Int { quoteDepth(ChatMarkdown.parse(text)) }

    @Test func quotesWithinTheLimitStillNest() {
        #expect(parseDepth("> a\n> > b") == 2)
        #expect(parseDepth("> > > > > > deep") == ChatMarkdown.maxQuoteDepth)
    }

    @Test func deepIndentedListsStayWithinTheListDepth() {
        let start = Date()
        let text = (0..<3000).map { String(repeating: " ", count: $0 + 1) + "- item \($0)" }.joined(separator: "\n")
        let blocks = ChatMarkdown.parse(text)
        let depths = blocks.compactMap { block -> Int? in
            if case .list(let entries) = block { return entries.map(\.depth).max() }
            return nil
        }
        #expect(!depths.isEmpty && depths.allSatisfy { $0 <= ChatMarkdown.maxListDepth })
        #expect(Date().timeIntervalSince(start) < 3)
    }

    // MARK: Links

    private func plain(_ text: String) -> String { String(ChatMarkdown.inline(text).characters) }
    private func links(_ text: String) -> [URL] { ChatMarkdown.inline(text).runs.compactMap(\.link) }

    @Test func onlyWebLinksWithoutAUserNameStayLinks() {
        #expect(links("[a](https://example.com/x)").count == 1 && links("[a](http://example.com)").count == 1)
        for bad in ["javascript:alert(1)", "file:///etc/hosts", "ftp://example.com", "https://user@example.com/", "https://user:pw@example.com/", "https:///nohost", "relative/path"] {
            #expect(links("[a](\(bad))").isEmpty, "\(bad) is not a link")
        }
    }

    @Test func aLinkNamesItsHostUnlessItsWordsShowIt() {
        #expect(plain("[Continue](https://evil.example/c?d=1)") == "Continue (evil.example)")
        #expect(plain("[Continue](https://evil.example:8443/c)") == "Continue (evil.example:8443)")
        #expect(plain("[example.com/page](https://example.com/page)") == "example.com/page")
        #expect(plain("[https://example.com/a](https://example.com/a)") == "https://example.com/a")
        #expect(plain("[notevil.example](https://evil.example/)") == "notevil.example (evil.example)", "the end of a longer name is not the name")
        #expect(plain("[example.com.evil.net](https://example.com/)") == "example.com.evil.net (example.com)", "the start of a longer name is not the name")
        #expect(plain("[www.example.com](https://www.example.com)") == "www.example.com")
        #expect(plain("[go to evil.example now](https://evil.example/)") == "go to evil.example now")
        #expect(ChatLinks.textShows("Visit Example.COM.", host: "example.com"))
        #expect(!ChatLinks.textShows("", host: "example.com") && !ChatLinks.textShows("a", host: ""))
    }

    @Test func aLinkThatCarriesDataAsksOnlyWhenTheChatHasReadASite() {
        let long = URL(string: "https://evil.example/c?d=" + String(repeating: "a", count: 80))!
        let fragment = URL(string: "https://evil.example/c#" + String(repeating: "b", count: 70))!
        let short = URL(string: "https://example.com/search?q=cats")!
        #expect(ChatLinks.needsConfirmation(long, chatHasRead: true) && ChatLinks.needsConfirmation(fragment, chatHasRead: true))
        #expect(!ChatLinks.needsConfirmation(long, chatHasRead: false), "nothing read, nothing to carry")
        #expect(!ChatLinks.needsConfirmation(short, chatHasRead: true))
        #expect(!ChatLinks.needsConfirmation(URL(string: "https://example.com/" + String(repeating: "p", count: 200))!, chatHasRead: true), "a long path alone is no data")
    }

    // MARK: History

    @Test func theKeptStepLeavesOutWhatWasTypedAndTheQueryOfAnAddress() {
        let typed = ChatHistory.persistable(ChatItem(kind: .tool, text: "Type [3] · hunter2 and more", tool: "type_text"))
        #expect(!typed.text.contains("hunter2") && typed.text.hasPrefix("Type [3] · ") && typed.text.contains("16"))
        let chosen = ChatHistory.persistable(ChatItem(kind: .tool, text: "Choose [1] · Gold plan", tool: "select_option"))
        #expect(!chosen.text.contains("Gold"))
        let go = ChatHistory.persistable(ChatItem(kind: .tool, text: "Go to · https://a.example/x/y?token=abc#frag", title: "Opening https://b.example/?q=1 now", tool: "navigate"))
        #expect(go.text == "Go to · https://a.example/x/y" && go.title == "Opening https://b.example/ now")
        let open = ChatHistory.persistable(ChatItem(kind: .tool, text: "Open new tab · http://a.example/", tool: "open_tab"))
        #expect(open.text == "Open new tab · http://a.example/")
        let user = ChatItem(kind: .user, text: "see https://a.example/?q=1")
        #expect(ChatHistory.persistable(user) == user, "what the user wrote is theirs to keep")
    }

    @Test func theHistoryFileIsMadePrivateFromTheStartAndReplacedWhole() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("ai-chats.json")
        #expect(ChatHistory.write(Data("one".utf8), to: file) && ChatHistory.write(Data("two".utf8), to: file))
        #expect(try Data(contentsOf: file) == Data("two".utf8))
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["ai-chats.json"], "no temporary file is left")
    }

    @Test func aFailedWriteIsReported() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let history = ChatHistory(file: blocker.appendingPathComponent("ai-chats.json"))
        #expect(!history.saveFailed)
        history.record(id: UUID(), started: Date(), items: [ChatItem(kind: .user, text: "hi")])
        #expect(history.saveFailed, "the folder can't be made, and the panel says so")
        history.clear()
        #expect(history.saveFailed)
    }

    // MARK: Images and the run

    @Test func aPictureClaimingAnAbsurdSizeIsTurnedAwayWithoutATrap() {
        #expect(ImageIntake.exceedsPixelLimit(width: Int.max, height: 2))
        #expect(ImageIntake.exceedsPixelLimit(width: Int.max, height: Int.max))
        #expect(ImageIntake.exceedsPixelLimit(width: 100_000, height: 100_000))
        #expect(!ImageIntake.exceedsPixelLimit(width: 1920, height: 1080))
    }

    @Test func whatClaudeSaidIsCutToItsEnd() {
        let long = String(repeating: "x", count: 10_000) + "THE END"
        let capped = ChatStore.capped(long)
        #expect(capped.utf8.count <= ChatStore.maxErrorBytes + 3 && capped.hasSuffix("THE END") && capped.hasPrefix("…"))
        #expect(ChatStore.capped("short") == "short")
        let wide = String(repeating: "한", count: 5000)
        #expect(ChatStore.capped(wide).utf8.count <= ChatStore.maxErrorBytes + 3 && !ChatStore.capped(wide).contains("\u{FFFD}"))
    }

    // MARK: Paste

    @Test func plainTextThatReadsLikeAFileAddressIsNotAFile() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("aip-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("file:///etc/hosts", forType: .string)
        #expect(ImageIntake.fileURLs(on: board).isEmpty && ImageIntake.sources(on: board).isEmpty && !ImageIntake.hasPicture(board))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aip-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        board.clearContents()
        board.writeObjects([file as NSURL])
        #expect(ImageIntake.fileURLs(on: board).count == 1, "a file the Finder put there is one")
    }
}
