import AppKit
import SwiftUI

@MainActor
final class ImportModel: ObservableObject {
    enum Step { case welcome, choose, importing, done, ai }

    @Published var step: Step = .welcome
    @Published var sources: [ImportSource] = []
    @Published var selected: Set<String> = []
    @Published var options = ImportOptions()
    @Published var status = ""
    @Published var reports: [ImportReport] = []
    @Published var ai = AIAvailability.none

    init() {
        sources = BrowserDiscovery.sources()
        selected = Set(sources.filter(\.suggested).map(\.id))
    }

    var needsSecrets: Bool {
        (options.passwords || options.cookies) && sources.contains { selected.contains($0.id) && $0.supportsSecrets }
    }

    /// The last step, for every way through onboarding: what the AI needs, looked up as it opens.
    func showAI() {
        ai = AIAvailability.detector()
        step = .ai
    }

    /// What came over from all the browsers together.
    var totals: ImportReport {
        var total = ImportReport(source: "")
        for report in reports {
            total.bookmarks += report.bookmarks
            total.readingList += report.readingList
            total.history += report.history
            total.passwords += report.passwords
            total.keptPasswords += report.keptPasswords
            total.cookies += report.cookies
        }
        return total
    }

    /// The numbers the last screen shows, in order, for what there is.
    var stats: [(label: String, value: Int)] {
        let total = totals
        return [(String(localized: "Bookmarks"), total.bookmarks), (String(localized: "Reading List"), total.readingList), (String(localized: "History"), total.history),
                (String(localized: "Passwords"), total.passwords), (String(localized: "Cookies"), total.cookies)].filter { $0.1 > 0 }.map { (label: $0.0, value: $0.1) }
    }

    func start() {
        let chosen = sources.filter { selected.contains($0.id) }
        let options = options
        step = .importing
        reports = []
        Task {
            for source in chosen {
                let report = await Task.detached(priority: .userInitiated) {
                    await ImportRunner.run(source, options: options) { message in
                        Task { @MainActor in self.status = message }
                    }
                }.value
                reports.append(report)
            }
            ai = AIAvailability.detector()
            step = .done
        }
    }
}

struct OnboardingView: View {
    private static var scrollerGutter: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
    @ObservedObject var browser: Browser
    @StateObject private var model = ImportModel()
    @State private var choosing = false

    var body: some View {
        ZStack {
            Theme.scrimModal.contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 0) {
                switch model.step {
                case .welcome, .choose: welcome
                case .importing: importing
                case .done, .ai: finished
                }
            }
            .frame(width: 440)
            .floatingPanel(radius: Metrics.panelRadius, modal: true)
            .animation(Motion.standard, value: model.step)
        }
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52).decorative()
    }

    /// The first screen: one question, the browsers it can come from, and Later or Import.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            appIcon
            VStack(alignment: .leading, spacing: 8) {
                Text("Bring in what you use?").font(.heading).foregroundStyle(Theme.primary)
                    .accessibilityAddTraits(.isHeader)
                Text("Bring your bookmarks and history over. From Chrome and similar browsers, passwords and logins can come too.")
                    .font(.body).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.sources.isEmpty {
                Text("No other browser was found on this Mac.").font(.secondary).foregroundStyle(Theme.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.sources) { source in
                            SourceRow(source: source, isOn: model.selected.contains(source.id)) {
                                if model.selected.contains(source.id) { model.selected.remove(source.id) } else { model.selected.insert(source.id) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 232)
                // The scroll bar's gutter (where bars always show) lies in the card's margin, so the rows end where the buttons do.
                .padding(.trailing, -Self.scrollerGutter)
            }
            VStack(alignment: .leading, spacing: 8) {
                Button { choosing.toggle() } label: {
                    HStack(spacing: 4) {
                        Text("Choose what to bring")
                        Image(systemName: "chevron.right").font(.symbolInline).rotationEffect(.degrees(choosing ? 90 : 0))
                    }
                }
                .buttonStyle(QuietLinkStyle(font: .secondary))
                .accessibilityValue(Accessibility.expansion(choosing))
                if choosing {
                    HStack(spacing: 16) {
                        Toggle("Bookmarks", isOn: $model.options.bookmarks)
                        Toggle("History", isOn: $model.options.history)
                        Toggle("Passwords", isOn: $model.options.passwords)
                        Toggle("Login state (cookies)", isOn: $model.options.cookies)
                    }
                    .toggleStyle(.checkbox)
                    .font(.secondary)
                }
                if model.needsSecrets {
                    Label("Each browser locks passwords and login state in the Keychain, so macOS will ask for permission. Enter your login password and click 'Allow'. Imported passwords are stored only in this Mac's Keychain.", systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Later") { model.showAI() }.buttonStyle(QuietLinkStyle(font: .body))
                Spacer()
                Button("Import") { model.start() }
                    .buttonStyle(PrimaryButton())
                    .disabled(model.selected.isEmpty || model.options == ImportOptions(bookmarks: false, history: false, passwords: false, cookies: false))
            }
            .padding(.top, 8)
        }
        .padding(32)
    }

    private var importing: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(model.status.isEmpty ? String(localized: "Preparing…") : model.status)
                .font(.body)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    /// The last screen, for every way through: with Claude Code, that everything is ready and how to start; without it, that the browser works now and
    /// the AI will turn on after Claude Code is installed. Never a warning, and never a dead end: it says how, and has Start.
    private var finished: some View {
        let ready = model.ai == .ready
        return VStack(alignment: .leading, spacing: 16) {
            appIcon
            VStack(alignment: .leading, spacing: 8) {
                Text(ready ? "You're all set" : "You can browse right away").font(.heading).foregroundStyle(Theme.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(Self.keycapped(ready ? String(localized: "Tabs on the left, the AI on the right. Press ⌘E and try “Summarize this page”.")
                                          : String(localized: "The AI turns on once you install Claude Code. You don't have to now: press ⌘E any time and Changmun will show you how.")))
                    .font(.body).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !ready {
                    if case .supportComing(let found) = model.ai {
                        Text("Support for \(AIGuidance.list(found)) on this Mac is coming.").font(.secondary).foregroundStyle(Theme.secondary)
                    }
                    Text("Already installed? Enter where it is in Settings › AI.").font(.secondary).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.reports.isEmpty { imported }
            HStack(spacing: 16) {
                if model.reports.contains(where: { $0.problems.contains(ImportRunner.fullDiskAccessProblem) }) {
                    Button("Open Full Disk Access Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .buttonStyle(SecondaryButton())
                }
                Spacer()
                if !ready {
                    Button("How to install") { NSWorkspace.shared.open(AIAvailability.claudeURL) }.buttonStyle(QuietLinkStyle(font: .body))
                }
                Button("Start") { finish() }.buttonStyle(PrimaryButton())
            }
            .padding(.top, 8)
        }
        .padding(32)
    }

    /// What came over, as numbers; what could not, under them.
    private var imported: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.stats.isEmpty {
                Text(model.totals.summary).font(.secondary).foregroundStyle(Theme.secondary)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(Array(model.stats.enumerated()), id: \.offset) { _, stat in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: stat.value.formatted()).font(.heading).foregroundStyle(Theme.primary)
                            Text(verbatim: stat.label).font(.caption).foregroundStyle(Theme.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if model.totals.keptPasswords > 0 {
                Text("Kept your newer passwords \(model.totals.keptPasswords.formatted())").font(.caption).foregroundStyle(Theme.secondary)
            }
            ForEach(Array(model.reports.flatMap(\.problems).enumerated()), id: \.offset) { _, problem in
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.waitingText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The text with its "⌘E" drawn as a keycap, as it is on the keys of the app.
    private static func keycapped(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        if let range = result.range(of: "⌘E") {
            result[range].backgroundColor = Theme.field
            result[range].foregroundColor = Theme.ink(0.7)
        }
        return result
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        browser.showOnboarding = false
        if browser.tabs.isEmpty { browser.openNewTab(.windowOpen) }
    }
}

struct SourceRow: View {
    let source: ImportSource
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: source.title).font(.body).foregroundStyle(Theme.primary)
            Spacer()
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.symbolRow)
                .foregroundStyle(isOn ? Theme.primary : Theme.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).fill(Theme.field))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibleButton(source.title, value: Accessibility.onOffValue(isOn), selected: isOn, activate: toggle)
    }
}
