import AppKit
import SwiftUI

/// What went wrong with a run of the AI, in the user's terms.
enum AIErrorKind: String, Codable, Equatable {
    /// Claude Code isn't signed in (or its login no longer works).
    case login
    /// The plan's usage limit (or the account's credit) is used up.
    case usageLimit
    case network
    /// Anthropic's side is busy or failing for now.
    case overloaded
    /// There is no `claude` to run.
    case notInstalled
    /// `claude` didn't know an option the app passes: it is older than the app expects.
    case outdated
    case other
}

/// An error row's cause. The words of `claude` stay in `details`, for the Details disclosure; the row says it in the app's own words.
struct AIFailure: Codable, Equatable {
    var kind: AIErrorKind
    var details: String
    /// When a usage limit ends, as `claude` said it ("3pm (Asia/Seoul)") or as a time made from its timestamp.
    var resets: String? = nil

    /// Sorts what `claude -p --output-format stream-json` reports. `code` is the `error` field of its assistant event for an API error
    /// ("authentication_failed" when not signed in), `status` the result's `api_error_status`. Not being signed in, the only case seen
    /// first hand, arrives as the text "Not logged in · Please run /login" with code "authentication_failed"; the other phrases are
    /// the ones Claude Code is known to use, matched loosely.
    static func classify(_ text: String, code: String? = nil, status: Int? = nil) -> AIFailure {
        let lower = text.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { lower.contains($0) } }
        let kind: AIErrorKind
        let apiError = code != nil || status != nil
        if !apiError, isUnknownOption(text) {
            kind = .outdated
        } else if code == "rate_limit" || code == "billing_error" || status == 429
            || has(["usage limit", "rate limit", "rate_limit", "limit reached", "hit your limit", "credit balance", "quota", "too many requests"]) {
            kind = .usageLimit
        } else if code == "authentication_failed" || status == 401
            || has(["not logged in", "please run /login", "invalid api key", "invalid x-api-key", "authentication", "unauthorized", "oauth token", "token has expired"]) {
            kind = .login
        } else if code == "server_error" || [500, 502, 503, 504, 529].contains(status ?? 0)
            || has(["overloaded", "service unavailable", "bad gateway", "gateway timeout", "internal server error", "temporarily unavailable"]) {
            kind = .overloaded
        } else if has(["enotfound", "econnrefused", "econnreset", "etimedout", "enetunreach", "network", "unable to connect", "could not connect",
                       "connection error", "connection refused", "connection reset", "fetch failed", "timed out", "offline", "getaddrinfo", "socket hang up"]) {
            kind = .network
        } else {
            kind = .other
        }
        return AIFailure(kind: kind, details: text, resets: kind == .usageLimit ? resetTime(in: text) : nil)
    }

    /// `claude`'s own complaint about an option it doesn't know, on a line of its own as it writes it to stderr ("error: unknown option
    /// '--effort'"). The same words inside other text (a page, a tool's answer) are not it.
    static func isUnknownOption(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let line = line.trimmingCharacters(in: .whitespaces).lowercased()
            return line.hasPrefix("error: unknown option") || line.hasPrefix("error: unrecognized option")
        }
    }

    /// The time a limit ends, when the message gives it: "resets 3pm (Asia/Seoul)", "will reset at 3pm", or the older
    /// "usage limit reached|1760000000" with a timestamp.
    static func resetTime(in text: String) -> String? {
        if let stamp = firstGroup(#"\|(\d{10})\b"#, in: text), let seconds = TimeInterval(stamp) {
            return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
        }
        guard let when = firstGroup(#"resets?\s+(?:at\s+|on\s+)?([^\n.]+)"#, in: text, caseInsensitive: true)?.trimmingCharacters(in: .whitespaces),
              !when.isEmpty else { return nil }
        return when
    }

    private static func firstGroup(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    var title: String {
        switch kind {
        case .login: String(localized: "Claude Code isn't signed in")
        case .usageLimit: String(localized: "You've reached your Claude usage limit")
        case .network: String(localized: "Couldn't reach Claude")
        case .overloaded: String(localized: "Claude is busy right now")
        case .notInstalled: String(localized: "Couldn't find Claude Code")
        case .outdated: String(localized: "Claude Code may need updating")
        case .other: String(localized: "The AI request failed.")
        }
    }

    var explanation: String {
        switch kind {
        case .login: String(localized: "Open Terminal, run `claude` and sign in. Then try again.")
        case .usageLimit: resets.map { String(localized: "It resets \($0).") } ?? String(localized: "Try again after it resets.")
        case .network: String(localized: "Check your internet connection and try again.")
        case .overloaded: String(localized: "This is temporary. Try again in a moment.")
        case .notInstalled: String(localized: "Install it, or enter where it is in Settings › AI.")
        case .outdated: String(localized: "It didn't recognize an option Changmun uses. Copy the update command, run it in Terminal, then try again.")
        case .other: details.split(separator: "\n").first.map { String($0.prefix(160)) } ?? ""
        }
    }

    /// The row also offers to open Settings › AI.
    var offersSettings: Bool { kind == .notInstalled }
    /// The row also offers to copy the command that signs in.
    var offersLoginCommand: Bool { kind == .login }

    /// The command the row's Copy Command button copies, for pasting into Terminal as it is: `claude` by the path the app runs it from
    /// (the shell may not find it by its name), and for an old one the command that updates it. Nil when the row offers none.
    func command(claude: String?) -> String? {
        let program = claude.map(Self.shellQuoted) ?? "claude"
        switch kind {
        case .login: return program
        case .outdated: return program + " update"
        default: return nil
        }
    }

    /// A path as one word for the shell: as it is when it has nothing the shell would read otherwise, else in single quotes.
    static func shellQuoted(_ path: String) -> String {
        let plain = !path.isEmpty && path.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || (48...57).contains($0.value) || "/._-+".unicodeScalars.contains($0)) }
        return plain ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// An error in the transcript: what happened, what to do, and the CLI's own words under Details.
struct ChatErrorRow: View {
    let item: ChatItem
    /// Sends the message again; nil when it can't be (an older error, or a saved chat).
    var retry: (() -> Void)?
    @State private var showDetails = false
    @State private var copied = false

    private var failure: AIFailure { item.failure ?? AIFailure.classify(item.text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle").font(.symbolInline)
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.title).font(.secondaryStrong)
                    if !failure.explanation.isEmpty {
                        Text(failure.explanation).font(.secondary).opacity(0.85)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let retry { actionButton(String(localized: "Try Again"), "arrow.clockwise", retry) }
                if let command = failure.command(claude: ChatStore.claudeLocator()) {
                    actionButton(copied ? String(localized: "Copied") : String(localized: "Copy Command"), copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                    .help(command)
                }
                if failure.offersSettings {
                    actionButton(String(localized: "Open AI Settings"), "gearshape") {
                        UserDefaults.standard.set(SettingsPage.ai.rawValue, forKey: "settingsPage")
                        (NSApp.delegate as? AppDelegate)?.showSettings(nil)
                    }
                }
                if !failure.details.isEmpty {
                    Button { showDetails.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right").font(.symbolInline).rotationEffect(.degrees(showDetails ? 90 : 0))
                            Text("Details").font(.captionStrong)
                        }
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 8).frame(height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if showDetails {
                Text(failure.details)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(Theme.selected))
            }
        }
        .foregroundStyle(Theme.waitingText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(failure.title + (failure.explanation.isEmpty ? "" : ". " + failure.explanation))
    }

    private func actionButton(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.symbolInline)
                Text(title).font(.captionStrong)
            }
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(Theme.pill))
        }
        .buttonStyle(.plain)
    }
}
