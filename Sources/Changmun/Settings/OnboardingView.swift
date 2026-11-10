import AppKit
import SwiftUI

@MainActor
final class ImportModel: ObservableObject {
    enum Step { case welcome, importing, done, ai }

    @Published var step: Step = .welcome
    @Published var sources: [ImportSource] = []
    @Published var selected: Set<String> = []
    @Published var options = ImportOptions()
    @Published var status = ""
    @Published var reports: [ImportReport] = []
    @Published var ai = AIAvailability.none
    /// Which browser of the run is being imported, how many there are, and whether the user asked to stop after the one in hand.
    @Published private(set) var position = 0
    @Published private(set) var total = 0
    @Published private(set) var stopping = false
    /// The run ended early at the user's word: the browsers after the last report were not imported.
    @Published private(set) var stopped = false
    /// Try Again has run since the import began.
    @Published private(set) var triedAgain = false

    /// The first run (nothing has been imported or skipped yet) ends on the last screen; a run from Settings or the sidebar goes back to where the user was.
    let firstRun: Bool

    typealias Runner = @Sendable (ImportSource, ImportOptions, @escaping @Sendable (String) -> Void) async -> ImportReport
    /// How one browser is imported; a test hands in a made-up one.
    var runner: Runner = { source, options, progress in await ImportRunner.run(source, options: options, progress: progress) }

    init(firstRun: Bool = !UserDefaults.standard.bool(forKey: "onboarded"), sources: [ImportSource]? = nil) {
        self.firstRun = firstRun
        self.sources = sources ?? BrowserDiscovery.sources()
        selected = Set(self.sources.filter(\.suggested).map(\.id))
    }

    /// Esc and the left-hand button of the first screen: the first run goes on to its last screen, a later one leaves.
    func skip(leave: () -> Void) {
        if firstRun { showAI() } else { leave() }
    }

    /// Whether a run can still be cut short: only between browsers, since a browser that is half imported would leave a half-written library.
    var canStop: Bool { step == .importing && !stopping && position + 1 < total }

    func stop() {
        guard canStop else { return }
        stopping = true
    }

    var needsSecrets: Bool {
        (options.passwords || options.cookies) && sources.contains { selected.contains($0.id) && $0.supportsSecrets }
    }

    /// The last step, for every way through onboarding: what the AI needs, looked up as it opens.
    func showAI() {
        ai = AIAvailability.detector()
        step = .ai
    }

    /// What will come over with what is ticked, in words: passwords and sign-ins only from a browser that has them to give.
    var willCome: String {
        var items: [String] = []
        let secrets = sources.contains { selected.contains($0.id) && $0.supportsSecrets }
        if options.bookmarks { items.append(String(localized: "bookmarks")) }
        if options.history { items.append(String(localized: "history")) }
        if options.passwords, secrets { items.append(String(localized: "passwords")) }
        if options.cookies, secrets { items.append(String(localized: "sign-ins")) }
        return items.isEmpty ? String(localized: "Nothing will come over") : String(localized: "Will come over: \(AIGuidance.list(items))")
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

    /// What was ticked and brought nothing, so the last screen says so instead of leaving it out: "Passwords: none found".
    var nothingFound: [String] {
        let total = totals
        let ran = Set(reports.map(\.source))
        let secrets = sources.contains { selected.contains($0.id) && ran.contains($0.title) && $0.supportsSecrets }
        var kinds: [(String, Bool)] = [(String(localized: "Bookmarks"), options.bookmarks && total.bookmarks == 0),
                                       (String(localized: "History"), options.history && total.history == 0),
                                       (String(localized: "Passwords"), options.passwords && secrets && total.passwords == 0),
                                       (String(localized: "Cookies"), options.cookies && secrets && total.cookies == 0)]
        if total.readingList > 0 { kinds[0].1 = false }
        return kinds.filter(\.1).map { String(localized: "\($0.0): none found") }
    }

    /// The numbers the last screen shows, in order, for what there is.
    var stats: [(label: String, value: Int)] {
        let total = totals
        return [(String(localized: "Bookmarks"), total.bookmarks), (String(localized: "Reading List"), total.readingList), (String(localized: "History"), total.history),
                (String(localized: "Passwords"), total.passwords), (String(localized: "Cookies"), total.cookies)].filter { $0.1 > 0 }.map { (label: $0.0, value: $0.1) }
    }

    @discardableResult
    func start() -> Task<Void, Never> { run(sources.filter { selected.contains($0.id) }, keeping: []) }

    /// Imports again the browsers whose files could not be read for want of Full Disk Access; what the others brought stays.
    @discardableResult
    func tryAgain() -> Task<Void, Never> {
        triedAgain = true
        let failed = Set(reports.filter(\.needsFullDiskAccess).map(\.source))
        return run(sources.filter { selected.contains($0.id) && failed.contains($0.title) }, keeping: reports.filter { !failed.contains($0.source) })
    }

    /// Quit and Reopen is offered once Try Again still couldn't read a browser: macOS usually lets the app use Full Disk Access only after it
    /// is opened again.
    var offersReopen: Bool { Self.offersReopen(triedAgain: triedAgain, needsAccess: reports.contains(where: \.needsFullDiskAccess)) }

    nonisolated static func offersReopen(triedAgain: Bool, needsAccess: Bool) -> Bool { triedAgain && needsAccess }

    /// Quits, and opens the app again once it has ended: two copies at once would share one library. A quit the user called off (downloads
    /// still running) opens nothing a minute later.
    func quitAndReopen() {
        guard !Headless.isOn, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", #"for _ in $(seq 300); do /bin/kill -0 "$1" 2>/dev/null || exec /usr/bin/open "$2"; sleep 0.2; done"#, "sh",
                            String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        guard (try? reopen.run()) != nil else { return }
        NSApp.terminate(nil)
    }

    @discardableResult
    private func run(_ chosen: [ImportSource], keeping kept: [ImportReport]) -> Task<Void, Never> {
        let options = options
        let runner = runner
        step = .importing
        reports = kept
        total = chosen.count
        position = 0
        stopping = false
        stopped = false
        return Task {
            for (index, source) in chosen.enumerated() {
                if stopping {
                    stopped = true
                    break
                }
                position = index
                let report = await Task.detached(priority: .userInitiated) {
                    await runner(source, options) { message in
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
    @State private var isDefaultBrowser = DefaultBrowser.isSet

    var body: some View {
        ZStack {
            Theme.scrimModal.contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 0) {
                switch model.step {
                case .welcome: welcome
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
                Text("Bring your bookmarks and history over from Safari, Chrome, Arc, Brave, Edge, Vivaldi, Opera and other Chromium browsers. Passwords and sign-ins come from the Chromium ones, and sign-ins go to your default profile only.")
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
            Text(verbatim: model.willCome).font(.secondary).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            HStack {
                Button(model.firstRun ? "Later" : "Cancel") { model.skip(leave: leave) }
                    .buttonStyle(QuietLinkStyle(font: .body))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import") { model.start() }
                    .buttonStyle(PrimaryButton())
                    .disabled(model.selected.isEmpty || model.options == ImportOptions(bookmarks: false, history: false, passwords: false, cookies: false))
            }
        }
        .padding(32)
    }

    private var importing: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(model.status.isEmpty ? String(localized: "Preparing…") : model.status)
                .font(.body)
                .foregroundStyle(Theme.secondary)
            if model.stopping {
                Text("Stopping after this browser…").font(.secondary).foregroundStyle(Theme.secondary)
            } else if model.canStop {
                Button("Stop After This Browser") { model.stop() }
                    .buttonStyle(QuietLinkStyle(font: .body))
                    .keyboardShortcut(.cancelAction)
            } else {
                Text("This can't be stopped partway, so your library is never left half written.").font(.caption).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 56)
    }

    /// The last screen of the first run, for every way through: with Claude Code, that everything is ready and how to start; without it, that the browser
    /// works now and the AI will turn on after Claude Code is installed. Never a warning, and never a dead end: it says how, and has Start. After an
    /// import from Settings or the sidebar it is only what came over, and Done.
    private var finished: some View {
        let ready = model.ai == .ready
        return VStack(alignment: .leading, spacing: 16) {
            appIcon
            if model.firstRun {
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
                tips
            } else {
                Text("Import finished").font(.heading).foregroundStyle(Theme.primary).accessibilityAddTraits(.isHeader)
            }
            if !model.reports.isEmpty || model.stopped { imported }
            if model.reports.contains(where: \.needsFullDiskAccess) {
                Text("macOS usually lets Changmun use Full Disk Access only after it is reopened. If Try Again still can't read it, quit and reopen Changmun.")
                    .font(.secondary).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                if model.reports.contains(where: \.needsFullDiskAccess) {
                    Button("Open Full Disk Access Settings") {
                        Outside.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .buttonStyle(SecondaryButton())
                    if model.offersReopen {
                        Button("Quit and Reopen") { model.quitAndReopen() }.buttonStyle(SecondaryButton())
                    } else {
                        Button("Try Again") { model.tryAgain() }.buttonStyle(SecondaryButton())
                    }
                }
                Spacer()
                if model.firstRun, !ready {
                    Button("How to install") { Outside.open(AIAvailability.claudeURL) }.buttonStyle(QuietLinkStyle(font: .body))
                }
                Button(model.firstRun ? "Start" : "Done") { finish() }
                    .buttonStyle(PrimaryButton())
                    .keyboardShortcut(model.firstRun ? nil : .cancelAction)
            }
            .padding(.top, 8)
        }
        .padding(32)
    }

    /// Three more things worth knowing on the first day, and the default browser, which is asked once here and again in Settings.
    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([String(localized: "⌘L searches and goes anywhere."), String(localized: "The row at the bottom of the sidebar switches spaces."),
                     String(localized: "The AI asks before anything risky.")], id: \.self) { line in
                Text(Self.keycapped(line)).font(.secondary).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !isDefaultBrowser {
                Button("Make Changmun the default browser") { DefaultBrowser.make { isDefaultBrowser = DefaultBrowser.isSet } }
                    .buttonStyle(SecondaryButton())
                    .padding(.top, 8)
            }
        }
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
            ForEach(model.nothingFound, id: \.self) { line in
                Text(verbatim: line).font(.caption).foregroundStyle(Theme.secondary)
            }
            if model.totals.keptPasswords > 0 {
                Text("Kept your newer passwords \(model.totals.keptPasswords.formatted())").font(.caption).foregroundStyle(Theme.secondary)
            }
            if model.stopped {
                Text("You stopped the import, so the browsers after these were not imported.").font(.caption).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(model.reports.flatMap(\.problems).enumerated()), id: \.offset) { _, problem in
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.waitingText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The text with its keys ("⌘E", "⌘L") drawn as keycaps, as they are on the keys of the app.
    private static func keycapped(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for key in ["⌘E", "⌘L"] {
            if let range = result.range(of: key) {
                result[range].backgroundColor = Theme.field
                result[range].foregroundColor = Theme.ink(0.7)
            }
        }
        return result
    }

    /// Where Esc and the first screen's Cancel go in a later run: back to the page the user was on.
    private func leave() { browser.showOnboarding = false }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        browser.showOnboarding = false
        if model.firstRun, browser.tabs.isEmpty { browser.openNewTab(.windowOpen) }
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
