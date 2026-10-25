import AppKit
import SwiftUI

extension ChatStore {
    // MARK: Process setup

    static func contextLine(_ tab: Tab?) -> String {
        guard let tab else { return "[No open tab]" }
        return "[Current tab #\(tab.id), title set by the page \"\(title(tab))\", address \(address(tab))]"
    }

    /// The line for a message that waited in the queue: the tab the user was looking at when they wrote it, which may not be the one in front now.
    static func queuedContextLine(_ tab: Tab?, closed: Bool, moved: Int? = nil) -> String {
        if let moved { return "[The tab the user was looking at when they wrote this message (#\(moved)) has since gone to another site, so its title and address are not given. Use list_tabs and pass tab_id]" }
        guard let tab else { return closed ? "[The tab the user was looking at when they wrote this message has been closed]" : "[No open tab]" }
        return "[Tab the user was looking at when they wrote this message: #\(tab.id), title set by the page \"\(title(tab))\"\(name(tab)), address \(address(tab))]"
    }

    /// The tabs attached in the panel, on the line after the current tab; empty when there are none.
    static func attachedLine(_ tabs: [Tab], moved: [Int] = []) -> String {
        var line = ""
        if !tabs.isEmpty { line += "\n[Tabs the user attached: " + tabs.map { "#\($0.id) \"\(title($0))\"\(name($0)) \(address($0))" }.joined(separator: "; ") + "]" }
        if !moved.isEmpty { line += "\n[Tabs the user attached that have since gone to another site, so their titles and addresses are not given: " + moved.map { "#\($0)" }.joined(separator: ", ") + "]" }
        return line
    }

    private static func title(_ tab: Tab) -> Substring { oneLine(tab.pageTitle).prefix(80) }

    /// The name the user gave the tab, after its title, when they gave it one.
    static func name(_ tab: Tab) -> String { tab.customTitle.map { ", named by the user \"\(oneLine($0).prefix(80))\"" } ?? "" }

    private static func address(_ tab: Tab) -> Substring { oneLine(tab.url?.absoluteString ?? "about:blank").prefix(300) }

    /// Page-supplied text that can't end the bracket it sits in or start a new line of its own.
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "]", with: ")")
    }

    /// How the panel's tool calls are told apart from other MCP clients'.
    nonisolated static let caller = "panel"

    /// Proves a call named "panel" really comes from the panel's own `claude`: known only to this launch of the app
    /// and passed in the environment of the MCP server it starts, so no other client of the control server can claim it.
    nonisolated static let panelSecret = UUID().uuidString + UUID().uuidString
    nonisolated static let panelSecretVariable = "CHANGMUN_PANEL_SECRET"

    nonisolated static let runTokenVariable = "CHANGMUN_RUN_TOKEN"

    static func mcpConfig(runToken: String) -> Data {
        let server: [String: Any] = ["command": Bundle.main.executablePath ?? CommandLine.arguments[0], "args": ["--mcp", "--caller", caller],
                                     "env": [panelSecretVariable: panelSecret, runTokenVariable: runToken]]
        return try! JSONSerialization.data(withJSONObject: ["mcpServers": ["changmun": server]])
    }

    /// Where the MCP configs of this user's runs are written: a folder only they can open.
    static var configFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Changmun", isDirectory: true)
    }

    /// One run's MCP config, made with the owner's permissions from the start (never readable by others, even for a moment).
    static func writeMCPConfig(runToken: String = UUID().uuidString) throws -> URL {
        try FileManager.default.createDirectory(at: configFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configFolder.path)
        let file = configFolder.appendingPathComponent("mcp-\(getpid())-\(UUID().uuidString).json")
        guard let descriptor = DurableFile.createPrivate(at: file) else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        let data = mcpConfig(runToken: runToken)
        guard write(descriptor, (data as NSData).bytes, data.count) == data.count else {
            try? FileManager.default.removeItem(at: file)
            throw CocoaError(.fileWriteUnknown)
        }
        return file
    }

    /// Removes the configs of this app's runs and of apps that are no longer running, which a crash left behind.
    static func removeOldConfigs() {
        let files = (try? FileManager.default.contentsOfDirectory(at: configFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let parts = file.lastPathComponent.split(separator: "-")
            guard parts.count > 2, parts[0] == "mcp", let pid = Int32(parts[1]) else { continue }
            if pid == getpid() || (kill(pid, 0) != 0 && errno != EPERM) { try? FileManager.default.removeItem(at: file) }
        }
    }

    static var workingDirectory: URL {
        let url = Library.folder.appendingPathComponent("chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func claudePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [UserDefaults.standard.string(forKey: "claudePath"), "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The app's environment without what a Claude Code session that launched it left behind.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "CLAUDECODE" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        return env
    }
}
