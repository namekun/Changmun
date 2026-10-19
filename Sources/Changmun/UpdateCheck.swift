import AppKit
import SwiftUI

/// Changmun comes from GitHub releases through Homebrew, so an update is only ever announced, never installed: once a
/// day it asks GitHub for the latest release and, when that is newer than this app, offers the command that upgrades.
@MainActor
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck()
    static let command = "brew upgrade --cask changmun"
    private static let endpoint = URL(string: "https://api.github.com/repos/namekun/Changmun/releases/latest")!
    private static let session = URLSession(configuration: .ephemeral)
    private let defaults = UserDefaults.standard
    /// Keeps a request that fails (offline) from being repeated every time the app comes to the front.
    private var lastAttempt: Date?
    private var asking = false

    /// The version waiting to be installed that the user hasn't dismissed.
    @Published private(set) var available: String?

    private init() {
        available = Self.announced(latest: defaults.string(forKey: "latestVersion"), current: Self.current, dismissed: defaults.string(forKey: "dismissedUpdate"))
    }

    nonisolated static var current: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    /// Asks GitHub when a day has passed since the last answer. Never in the headless app, and silent when anything goes wrong.
    func checkIfDue() {
        guard !Headless.isOn, !asking, Preferences.shared.checkForUpdates, let current = Self.current,
              Self.isDue(last: defaults.object(forKey: "lastUpdateCheck") as? Date, now: Date()),
              lastAttempt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true else { return }
        lastAttempt = Date()
        asking = true
        Task {
            let tag = await Self.latestTag()
            asking = false
            if let tag { received(tag, current: current) }
        }
    }

    /// The latest release's tag, as GitHub answered: only now does the day's wait start.
    func received(_ tag: String, current: String) {
        defaults.set(Date(), forKey: "lastUpdateCheck")
        let version = Self.numbers(tag).map { $0.map(String.init).joined(separator: ".") }
        defaults.set(version, forKey: "latestVersion")
        available = Self.announced(latest: version, current: current, dismissed: defaults.string(forKey: "dismissedUpdate"))
    }

    /// Hides this version; a newer one shows again.
    func dismiss() {
        guard let available else { return }
        defaults.set(available, forKey: "dismissedUpdate")
        self.available = nil
    }

    private static func latestTag() async -> String? {
        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return release["tag_name"] as? String
    }

    nonisolated static func isDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= 24 * 3600
    }

    /// "v0.4.0" or "0.4.0" as [0, 4, 0]; nil for anything else (a pre-release tag, a name).
    nonisolated static func numbers(_ version: String) -> [Int]? {
        let parts = version.drop { $0 == "v" }.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        return !parts.isEmpty && numbers.count == parts.count ? numbers : nil
    }

    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        guard var a = numbers(version), var b = numbers(current) else { return false }
        let length = max(a.count, b.count)
        a += Array(repeating: 0, count: length - a.count)
        b += Array(repeating: 0, count: length - b.count)
        return b.lexicographicallyPrecedes(a)
    }

    /// The latest known version when it is newer than this app and not the one dismissed.
    nonisolated static func announced(latest: String?, current: String?, dismissed: String?) -> String? {
        guard let latest, let current, latest != dismissed, isNewer(latest, than: current) else { return nil }
        return latest
    }
}

/// At the bottom of the sidebar while an update is out: copies the command that installs it, or goes away.
struct UpdateNotice: View {
    let version: String
    let dismiss: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowGap) {
            HStack(spacing: Metrics.iconGap) {
                Text("Changmun \(version) is out")
                    .font(.row)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                HoverAction(symbol: "xmark", help: String(localized: "Close"), action: dismiss)
            }
            .frame(height: Metrics.row)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(UpdateCheck.command, forType: .string)
                copied = true
            } label: {
                Text(copied ? "Copied" : "Copy").font(.rowSelected).padding(.horizontal, Metrics.rowPadding).frame(height: Metrics.action).contentShape(Rectangle())
            }
            .buttonStyle(FillStyle(resting: Theme.field, hoverFill: Theme.pill, radius: 6))
            .foregroundStyle(Theme.primary)
            .help(UpdateCheck.command)
        }
        .padding(.leading, Metrics.rowPadding)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
