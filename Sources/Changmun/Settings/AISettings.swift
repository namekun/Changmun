import AppKit
import SwiftUI

// MARK: AI

struct AISettings: View {
    @ObservedObject var prefs: Preferences
    @State private var status = String(localized: "Checking…")

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $prefs.aiModel) {
                    Text("Sonnet (fast and balanced)").tag("sonnet")
                    Text("Opus (smartest, slower)").tag("opus")
                    Text("Haiku (fastest)").tag("haiku")
                }
                Picker("Effort", selection: $prefs.aiEffort) {
                    Text("Auto").tag("")
                    ForEach(AIEffort.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section {
                Picker("Approvals", selection: $prefs.aiApprovalMode) {
                    ForEach(AIApprovalMode.allCases) { Text($0.title).tag($0) }
                }
                switch prefs.aiApprovalMode {
                case .afterReading:
                    Caption(text: "It asks before using other tabs, opening new addresses, or using a page after reading other sites, but not for the tab you’re viewing or for addresses it already knows.")
                case .everyAction:
                    Caption(text: "It also asks before typing, choosing or clicking on a page when it has read nothing else, and you can allow a site until the chat is cleared.")
                case .irreversibleOnly:
                    Caption(text: "Instructions hidden in a web page can then make the AI send other tabs or content it read earlier to the outside.", color: Theme.waitingText)
                }
                Caption(text: "Either way, it asks every time before something that looks like it pays, orders, sends, posts, shares, grants access, deletes or cancels.")
                Caption(text: "It also asks before something that looks like a cookie banner or a setting (save, clear, reset, block), which you can allow for a site until the chat is cleared.")
            }
            Section("Claude Code") {
                LabeledContent("claude CLI") { Text(status).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing) }
                TextField("Path override (leave empty to detect automatically)", text: $prefs.claudePath)
                Caption(text: "The AI panel uses the Claude Code login (subscription) on this Mac.")
            }
            Section {
                Toggle("Keep chat history", isOn: $prefs.aiKeepHistory)
                Caption(text: "Finished chats can be read again from the clock button in the AI panel. Chats in private windows are never kept.")
                Caption(text: "The history stays on this Mac, and you can turn it off here.")
                LabeledContent("AI Chat") {
                    Button("Clear Chat") { ChatStore.shared.reset() }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: prefs.claudePath) { status = await Self.checkClaude() }
    }

    static func checkClaude() async -> String {
        guard let path = await MainActor.run(body: { ChatStore.claudePath() }) else { return String(localized: "Not found. Install Claude Code or specify the path.") }
        // The first run after an install can wait a good while on Gatekeeper.
        let result = await Task.detached { ProcessOutput.result(path, ["--version"], timeout: 15) }.value
        return describe(result, path: path)
    }

    static func describe(_ result: ProcessOutput.Result, path: String) -> String {
        switch result {
        case .output(let text): return "\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n\(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
        case .timedOut: return String(localized: "Didn’t answer in time: \(path)")
        case .failed: return String(localized: "Couldn’t run it: \(path)")
        }
    }
}
