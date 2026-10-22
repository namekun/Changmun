import Foundation
import Testing
@testable import Changmun

@MainActor
struct AIAvailabilityTests {
    /// A folder standing in for the places commands live in, with the named commands in it as executable files.
    private func folder(with commands: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ai-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for command in commands {
            let file = url.appendingPathComponent(command)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return url.path
    }

    @Test func claudeCodeFoundMeansTheAIIsReadyWhateverElseIsThere() throws {
        let bin = try folder(with: ["codex", "gemini"])
        defer { try? FileManager.default.removeItem(atPath: bin) }
        #expect(AIAvailability.detect(claude: { "/somewhere/claude" }, folders: [bin]) == .ready)
        #expect(AIAvailability.detect(claude: { "/somewhere/claude" }, folders: []) == .ready)
    }

    @Test func withoutClaudeCodeTheOtherToolsFoundAreNamedAsComing() throws {
        let bin = try folder(with: ["codex", "opencode", "ls-is-not-a-tool"])
        defer { try? FileManager.default.removeItem(atPath: bin) }
        #expect(AIAvailability.detect(claude: { nil }, folders: [bin]) == .supportComing(["Codex", "opencode"]))
        let all = try folder(with: ["gemini", "codex", "opencode"])
        defer { try? FileManager.default.removeItem(atPath: all) }
        #expect(AIAvailability.detect(claude: { nil }, folders: ["/nonexistent", all]) == .supportComing(["Codex", "Gemini CLI", "opencode"]))
    }

    @Test func nothingFoundMeansNone() throws {
        let bin = try folder(with: [])
        defer { try? FileManager.default.removeItem(atPath: bin) }
        #expect(AIAvailability.detect(claude: { nil }, folders: [bin]) == .none)
        #expect(AIAvailability.detect(claude: { nil }, folders: ["/nonexistent"]) == .none)
    }

    @Test func aFileThatIsNotExecutableOrIsAFolderIsNotATool() throws {
        let bin = try folder(with: [])
        defer { try? FileManager.default.removeItem(atPath: bin) }
        try Data().write(to: URL(fileURLWithPath: bin).appendingPathComponent("codex"))
        try FileManager.default.createDirectory(atPath: bin + "/gemini", withIntermediateDirectories: false)
        #expect(AIAvailability.detect(claude: { nil }, folders: [bin]) == .none)
    }

    @Test func theInstallerFoldersAreSearchedInsideTheGivenHome() {
        let folders = AIAvailability.searchFolders(home: "/Users/someone")
        #expect(folders.contains("/Users/someone/.npm-global/bin"))
        #expect(folders.contains("/Users/someone/.bun/bin"))
        #expect(folders.contains("/Users/someone/.opencode/bin"))
        #expect(folders.contains("/opt/homebrew/bin") && folders.contains("/usr/local/bin") && folders.contains("/Users/someone/.local/bin"))
    }

    @Test func theDetectorFollowsTheClaudeLocatorTheChatUses() {
        let saved = ChatStore.claudeLocator
        defer { ChatStore.claudeLocator = saved }
        ChatStore.claudeLocator = { "/somewhere/claude" }
        #expect(AIAvailability.detect(folders: []) == .ready)
        ChatStore.claudeLocator = { nil }
        #expect(AIAvailability.detect(folders: []) == .none)
    }

    @Test func thePanelStartsReadyAndFollowsWhatIsFoundWhenItLooksAgain() {
        let saved = AIAvailability.detector
        defer { AIAvailability.detector = saved }
        let chat = ChatStore()
        #expect(chat.availability == .ready, "nothing changes for someone who has it, before anything is looked up")
        AIAvailability.detector = { .none }
        chat.refreshAvailability()
        #expect(chat.availability == .none)
        AIAvailability.detector = { .ready }
        chat.refreshAvailability()
        #expect(chat.availability == .ready, "installing Claude Code, or fixing its path, is seen on the next look")
    }
}
