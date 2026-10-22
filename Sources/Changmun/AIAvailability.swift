import AppKit
import SwiftUI

/// What the AI can use on this Mac. Only Claude Code runs Changmun's AI; the other coding tools found are named as coming,
/// never as working.
@MainActor
enum AIAvailability: Equatable {
    case ready
    /// Claude Code is missing; these others are installed, and Changmun can't use them yet.
    case supportComing([String])
    case none

    static let claudeURL = URL(string: "https://claude.com/claude-code")!

    /// How the tools are looked for (tests and the headless app say what they find).
    static var detector: () -> AIAvailability = { detect() }

    private static let others = [("Codex", "codex"), ("Gemini CLI", "gemini"), ("opencode", "opencode")]

    /// Where the other tools put their commands: the usual places, then the folders of their own installers.
    static func searchFolders(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.opencode/bin"]
    }

    /// Looks at files only: no process is started and no login is checked.
    static func detect(claude: (() -> String?)? = nil, folders: [String]? = nil) -> AIAvailability {
        if (claude ?? ChatStore.claudeLocator)() != nil { return .ready }
        let folders = folders ?? searchFolders()
        let found = others.filter { _, command in
            folders.contains { folder in
                // A folder counts as executable too, so one named like a command is not the command.
                var isFolder: ObjCBool = false
                let path = "\(folder)/\(command)"
                return FileManager.default.isExecutableFile(atPath: path) && FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && !isFolder.boolValue
            }
        }.map(\.0)
        return found.isEmpty ? .none : .supportComing(found)
    }
}

/// What the AI needs from the user, in words; shown in onboarding and in the empty AI panel.
struct AIGuidance: View {
    let availability: AIAvailability
    var compact = false

    private var title: String {
        switch availability {
        case .ready: String(localized: "Claude Code is ready")
        case .supportComing: String(localized: "The AI panel works with Claude Code for now")
        case .none: String(localized: "The AI panel needs Claude Code")
        }
    }

    private var message: String {
        switch availability {
        case .ready: String(localized: "Press ⌘E any time to talk to the AI. It can read the page, click and type for you.")
        case .supportComing: String(localized: "Install Claude Code to turn it on.")
        case .none: String(localized: "Everything else in Changmun works without AI. To turn the AI panel on later, install Claude Code.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            Text(title).font(.system(size: compact ? 15 : 18, weight: .semibold)).foregroundStyle(compact ? Theme.primary : Color.primary)
            Text(message)
                .font(.system(size: compact ? 12 : 13.5, weight: compact ? .medium : .regular))
                .lineSpacing(compact ? 0 : 3)
                .foregroundStyle(compact ? Theme.secondary : Color.primary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            if case .supportComing(let found) = availability {
                Text("Found on this Mac, support coming: \(ListFormatter.localizedString(byJoining: found))")
                    .font(.system(size: compact ? 11.5 : 12.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if availability != .ready {
                Button("Get Claude Code") { NSWorkspace.shared.open(AIAvailability.claudeURL) }
                    .buttonStyle(SecondaryButton())
                    .padding(.top, 2)
            }
        }
    }
}

/// The panel before the first message: the suggestions, or what is missing for the AI to answer at all.
struct ChatEmptyState: View {
    var several = false
    let send: (String) -> Void
    @State private var availability = AIAvailability.detector()

    var body: some View {
        Group {
            if availability == .ready {
                ChatWelcome(several: several, send: send)
            } else {
                AIGuidance(availability: availability, compact: true).padding(.top, 4)
            }
        }
        .onAppear { availability = AIAvailability.detector() }
    }
}
