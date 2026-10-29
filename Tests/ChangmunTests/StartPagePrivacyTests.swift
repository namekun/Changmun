import AppKit
import Foundation
import Testing
@testable import Changmun

/// The start page shows history-derived things (recent pages, closed tabs, the reading list, frequent sites). None of it may reach the AI, an MCP
/// client, the command line, an extension or a picture of the window: a start tab is a blank "New Tab" to every one of them.
extension SharedAgentState {
    @MainActor @Suite(.serialized)
    struct StartPagePrivacyTests {
        /// Words that only the start page would show.
        private static let secrets = ["SECRET-RECENT-PAGE", "SECRET-CLOSED-TAB", "SECRET-READING-ITEM", "secret-frequent.example"]

        private func seeded() -> (Browser, Tab) {
            let b = Browser(spaces: Sandbox().store())
            b.focused()
            b.startPageStore = StartPageStore(defaults: UserDefaults(suiteName: "start-privacy-\(UUID().uuidString)")!,
                                              folder: FileManager.default.temporaryDirectory.appendingPathComponent("start-privacy-\(UUID().uuidString)"))
            let library = Library(path: FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString).sqlite").path)
            library.recordVisit(url: "https://secret-frequent.example/", title: "SECRET-RECENT-PAGE")
            library.addToReadingList(url: "https://secret-frequent.example/read", title: "SECRET-READING-ITEM", added: Date())
            b.closedTabs.append(Browser.ClosedTab(url: URL(string: "https://secret-frequent.example/closed"), title: "SECRET-CLOSED-TAB", index: 0, space: b.spaceID))
            b.openNewTab()
            return (b, b.active!)
        }

        private func text(_ result: ToolResult) -> String {
            result.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }

        private func noSecrets(_ result: ToolResult, _ what: String) {
            let all = String(describing: result.content)
            for word in Self.secrets { #expect(!all.contains(word), Comment(rawValue: "\(what) shows \(word)")) }
            #expect(!result.content.contains { $0["type"] as? String == "image" }, Comment(rawValue: "\(what) has a picture"))
        }

        @Test func listTabsNamesAStartTabAsABlankNewTab() async {
            let (b, tab) = seeded()
            defer { b.windowClosed() }
            let result = await ToolCatalog.call("list_tabs", [:], caller: "start-test")
            noSecrets(result, "list_tabs")
            #expect(text(result).contains("#\(tab.id) New Tab — about:blank"), Comment(rawValue: text(result)))
        }

        @Test func listTabsDoesNotHoldAStartTabBackAsAnUnapprovedSite() async {
            let (b, tab) = seeded()
            defer { b.windowClosed() }
            _ = b.openTab(url: URL(string: "http://127.0.0.1:9/"))
            #expect(b.active !== tab)
            let result = await ToolCatalog.call("list_tabs", [:], caller: "start-test-2")
            #expect(text(result).contains("#\(tab.id) New Tab — about:blank"), "not “a tab on no page; its title and address are shown once you use it”")
        }

        @Test func readingAStartTabAnswersAsABlankPage() async {
            let (b, tab) = seeded()
            defer { b.windowClosed() }
            for name in ["read_page", "screenshot", "scroll", "wait_for", "go_back", "go_forward", "reload"] {
                let result = await ToolCatalog.call(name, ["tab_id": tab.id], caller: "start-test")
                noSecrets(result, name)
                #expect(!result.isError && text(result).contains("about:blank"), Comment(rawValue: "\(name): \(text(result))"))
            }
            let many = await ToolCatalog.call("read_tabs", ["tab_ids": [tab.id]], caller: "start-test")
            noSecrets(many, "read_tabs")
            #expect(text(many).contains("=== Tab #\(tab.id) ===") && text(many).contains("blank"))
            #expect(tab.webView == nil, "nothing was woken for it")
        }

        @Test func actingOnAStartTabFindsNothingToActOn() async {
            let (b, tab) = seeded()
            defer { b.windowClosed() }
            let arguments: [String: [String: Any]] = [
                "click": ["element_id": 1], "click_at": ["x": 10, "y": 10], "type_text": ["element_id": 1, "text": "x"], "press_key": ["key": "Enter"],
                "select_option": ["element_id": 1, "option": "x"], "hover": ["element_id": 1], "drag": ["from_element_id": 1, "to_element_id": 2],
            ]
            for (name, extra) in arguments {
                let result = await ToolCatalog.call(name, extra.merging(["tab_id": tab.id]) { $1 }, caller: "start-test")
                noSecrets(result, name)
                #expect(tab.webView == nil && tab.isStart, "\(name) left the start tab as it was")
            }
        }

        @Test func switchingToAndClosingAStartTabNeedNoQuestionAndLeaveNothingToReopen() async {
            let (b, tab) = seeded()
            defer { b.windowClosed() }
            let page = b.openTab(url: URL(string: "http://127.0.0.1:9/"))
            let shown = await ToolCatalog.call("switch_tab", ["tab_id": tab.id], caller: "start-test")
            #expect(!shown.isError && b.active === tab && tab.webView == nil)
            let closed = await ToolCatalog.call("close_tab", ["tab_id": tab.id], caller: "start-test")
            #expect(!closed.isError && !b.tabs.contains { $0 === tab } && b.active === page)
            #expect(b.closedTabs.allSatisfy { $0.title == "SECRET-CLOSED-TAB" }, "only what was seeded is in the closed tabs")
        }

        @Test func theAIPanelDoesNotAttachAPictureOfAStartTab() async {
            let (b, tab) = seeded()
            defer { b.windowClosed() }
            let chat = ChatStore()
            #expect(!chat.canAttachScreenshot(of: tab))
            let (data, frames) = await ChatStore.capturePage(tab)
            #expect(data == nil && frames.isEmpty)
            #expect(ChatStore.contextLine(tab).contains("about:blank") && !ChatStore.contextLine(tab).contains("SECRET"))
        }

        @Test func anExtensionSeesAStartTabWithNoAddressTitleOrPage() {
            let (b, tab) = seeded()
            defer { b.windowClosed() }
            // What the extensions API hands out for a tab is these three (see Tab: WKWebExtensionTab).
            #expect(tab.url == nil && tab.title.isEmpty && tab.webView == nil)
        }

        @Test func aPrivateWindowReadsNoHistoryForItsStartPage() {
            let hidden = Browser(isPrivate: true, spaces: Sandbox().store())
            hidden.focused()
            defer { hidden.windowClosed() }
            #expect(!hidden.startPageMayShowHistory)
            #expect(ToolCatalog.findTab(hidden.openStartTab().id) == nil, "and the AI can't see the window at all")
        }

        // MARK: Pictures

        /// Where a picture of a window or screen could be taken from. Only these files may do it, and the window picture is a test copy's alone.
        @Test func noCodeOutsideTheKnownOnesCapturesTheWindow() throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Changmun")
            let capture = try NSRegularExpression(pattern: #"takeSnapshot\((with|configuration)|cacheDisplay|bitmapImageRepForCachingDisplay|CGWindowListCreateImage|CGDisplayCreateImage|SCScreenshotManager|SCStream|createPDF|dataWithPDF|cacheDisplay"#)
            var files: [String: String] = [:]
            let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let file as URL in walker where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                if capture.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil { files[String(file.path.dropFirst(root.path.count + 1))] = source }
            }
            // The AI's screenshot and Save as PDF read a web view (a page), the window picture is the test copy's, and a control draws itself.
            #expect(Set(files.keys) == ["AI/Tools/ToolCatalog.swift", "Tabs/SavePage.swift", "Control/Headless.swift"], "\(files.keys.sorted())")
            for (name, source) in files where name == "AI/Tools/ToolCatalog.swift" || name == "Tabs/SavePage.swift" {
                #expect(!source.contains("cacheDisplay") && !source.contains("CGWindowList"), "\(name) captures a view of the window")
            }
            // Whoever calls WindowImage does it behind the test copy's check.
            let callers = try (FileManager.default.subpaths(atPath: root.path) ?? []).filter { $0.hasSuffix(".swift") && $0 != "Control/Headless.swift" }.filter {
                try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8).contains("WindowImage.png")
            }
            for name in callers {
                let source = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
                let uses = source.components(separatedBy: "WindowImage.png").count - 1
                let gated = source.components(separatedBy: "Headless.isTestCopy").count - 1
                #expect(gated >= uses, "\(name) takes a window picture outside the test copy")
            }
            #expect(!callers.isEmpty)
        }
    }
}
