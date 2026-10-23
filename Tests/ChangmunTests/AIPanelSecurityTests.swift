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

    @Test func aLinkNamesItsHostUnlessItsWordsAreThatAddress() {
        #expect(plain("[Continue](https://evil.example/c?d=1)") == "Continue (evil.example)")
        #expect(plain("[Continue](https://evil.example:8443/c)") == "Continue (evil.example:8443)")
        #expect(plain("[example.com/page](https://example.com/page)") == "example.com/page")
        #expect(plain("[https://example.com/a](https://example.com/a)") == "https://example.com/a")
        #expect(plain("[www.example.com](https://example.com)") == "www.example.com")
        #expect(plain("[example.com](https://www.example.com)") == "example.com")
        #expect(plain("[ Example.COM ](https://example.com)") == " Example.COM ", "the words are the host, however written")
        for tricky in ["Visit bank.com (secure)", "go to evil.example now", "notevil.example", "bank.com.evil.net", "bank.com@evil.net", "evil.example.", "example.com:444"] {
            let host = tricky.hasPrefix("example.com") ? "example.com" : tricky.contains("bank.com") ? "bank.com" : "evil.example"
            #expect(plain("[\(tricky)](https://\(host)/)") == "\(tricky) (\(host))", "\(tricky) is not the address \(host)")
        }
        #expect(plain("[bank.com.evil.net](https://bank.com/)") == "bank.com.evil.net (bank.com)")
        #expect(plain("[bank.com@evil.net](https://evil.net/)") == "bank.com@evil.net (evil.net)", "a user name in the words is not the destination")
        #expect(plain("[bank.com](https://bank.com.evil.net/)") == "bank.com (bank.com.evil.net)")
        #expect(plain("[bank.com/login](http://bank.com/login)") == "bank.com/login", "the same host, whatever the scheme")
    }

    @Test func aLookAlikeHostIsShownInItsAsciiForm() throws {
        let url = try #require(URL(string: "https://bаnk.com/login"))   // Cyrillic а
        let host = try #require(ChatLinks.host(of: url))
        #expect(host.hasPrefix("xn--") && host.allSatisfy(\.isASCII), Comment(rawValue: host))
        #expect(plain("[bаnk.com](https://bаnk.com/login)") == "bаnk.com (\(host))", "Unicode words never stand for the address")
        #expect(plain("[bank.com](https://bаnk.com/login)") == "bank.com (\(host))")
        #expect(ChatLinks.host(of: URL(string: "http://Example.COM:8080/")!) == "example.com:8080")
        #expect(ChatLinks.host(of: URL(string: "https://example.com:443/")!) == "example.com")
    }

    @Test func onceASiteWasReadALinkToAnyOtherSiteAsksWhateverPartCarriesTheData() {
        let read = ["a.example"], open = ["b.example", "http://c.example", "d.example:8443"]
        func asks(_ link: String, read: [String] = read, open: [String] = open) -> Bool {
            ChatLinks.needsConfirmation(URL(string: link)!, read: read, open: open)
        }
        #expect(asks("https://evil.example/x/SECRETDATA"), "in the path")
        #expect(asks("https://SECRETDATA.evil.example/"), "in a subdomain")
        #expect(asks("https://evil.example/?q=SECRETDATA") && asks("https://evil.example/#SECRETDATA"))
        #expect(asks("https://evil.example/"), "even a short address: the site itself is new")
        #expect(!asks("https://a.example/anything?q=" + String(repeating: "x", count: 200)), "a site that was read")
        #expect(!asks("https://b.example/") && !asks("http://c.example/x") && !asks("https://d.example:8443/"), "a site open in the window")
        #expect(asks("http://a.example/") && asks("https://c.example/") && asks("https://d.example/"), "another scheme or port is another site")
        #expect(asks("https://x.a.example/") && asks("https://a.example.evil.net/"), "a neighbour of a read site is not it")
        #expect(!asks("https://evil.example/x", read: []), "nothing read, nothing to carry")
        #expect(!asks("https://xn--e1a.example/", read: ["xn--e1a.example"]), "sites are compared in their ASCII form")
        #expect(!ChatLinks.needsConfirmation(URL(string: "https://а.example/")!, read: ["xn--80a.example"], open: []), "Unicode and ASCII forms are one site")
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

    @Test func bareAddressesWaitedTextAndTitlesAreCutToo() {
        func kept(_ text: String, _ tool: String, title: String? = nil) -> ChatItem { ChatHistory.persistable(ChatItem(kind: .tool, text: text, title: title, tool: tool)) }
        #expect(kept("Go to · bank.com/login?token=SECRET", "navigate").text == "Go to · bank.com/login")
        #expect(kept("Go to · cats and dogs #secret", "navigate").text == "Go to · cats and dogs ")
        #expect(kept("Open new tab · bank.com?x=SECRET#y", "open_tab").text == "Open new tab · bank.com")
        #expect(kept("Go to · https://bank.com/a?b=c", "navigate").text == "Go to · https://bank.com/a")
        let wait = kept("Wait · Your code is 123456", "wait_for")
        #expect(!wait.text.contains("123456") && wait.text.hasPrefix("Wait · ") && wait.text.contains("19"))
        #expect(kept("Read page", "read_page", title: "Reading bank.com/login?token=SECRET and https://x.example/?q=1 today").title == "Reading bank.com/login and https://x.example/ today")
        #expect(kept("Read page", "read_page", title: "Is this the right plan?").title == "Is this the right plan?", "a question is a question")
        #expect(kept("Click", "click", title: "Choose item #3").title == "Choose item #3")
    }

    @Test func aTemporaryFileLeftByACutShortWriteIsRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("ai-chats.json")
        let stale = folder.appendingPathComponent(".ai-chats.json.\(UUID().uuidString).tmp"), other = folder.appendingPathComponent("keep.tmp")
        try Data("old".utf8).write(to: stale)
        try Data("x".utf8).write(to: other)
        let history = ChatHistory(file: file)
        #expect(!FileManager.default.fileExists(atPath: stale.path) && FileManager.default.fileExists(atPath: other.path))
        try Data("old".utf8).write(to: stale)
        history.clear()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
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
