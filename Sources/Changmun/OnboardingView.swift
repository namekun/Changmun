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
            step = .done
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var browser: Browser
    @StateObject private var model = ImportModel()

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 0) {
                switch model.step {
                case .welcome: welcome
                case .choose: choose
                case .importing: importing
                case .done: done
                case .ai: ai
                }
            }
            .frame(width: 540)
            .floatingPanel(radius: 18)
            .animation(Motion.standard, value: model.step)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.primary)
            Text("Welcome to Changmun")
                .font(.system(size: 22, weight: .semibold))
            Text("It runs on the same WebKit engine as Safari, so it's light, and when you talk to the AI panel (⌘E), the AI reads the page and clicks and types for you.\nWould you like to bring over the bookmarks, history, passwords and login state from the browser you used before?")
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(Color.primary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Later") { model.showAI() }.buttonStyle(SecondaryButton())
                Spacer()
                Button("Import") { model.step = .choose }.buttonStyle(PrimaryButton())
            }
            .padding(.top, 10)
        }
        .padding(28)
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where would you like to import from?").font(.system(size: 18, weight: .semibold))
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.sources) { source in
                        SourceRow(source: source, isOn: model.selected.contains(source.id)) {
                            if model.selected.contains(source.id) { model.selected.remove(source.id) } else { model.selected.insert(source.id) }
                        }
                    }
                }
            }
            .frame(maxHeight: 230)
            Divider().opacity(0.5)
            HStack(spacing: 16) {
                Toggle("Bookmarks", isOn: $model.options.bookmarks)
                Toggle("History", isOn: $model.options.history)
                Toggle("Passwords", isOn: $model.options.passwords)
                Toggle("Login state (cookies)", isOn: $model.options.cookies)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12.5))
            if model.needsSecrets {
                Label("Each browser locks passwords and login state in the Keychain, so macOS will ask for permission. Enter your login password and click 'Allow'. Imported passwords are stored only in this Mac's Keychain.", systemImage: "key")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Back") { model.step = .welcome }.buttonStyle(SecondaryButton())
                Spacer()
                Button("Start Import") { model.start() }
                    .buttonStyle(PrimaryButton())
                    .disabled(model.selected.isEmpty || model.options == ImportOptions(bookmarks: false, history: false, passwords: false, cookies: false))
            }
            .padding(.top, 4)
        }
        .padding(24)
    }

    private var importing: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(model.status.isEmpty ? String(localized: "Preparing…") : model.status)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("All done").font(.system(size: 18, weight: .semibold))
            ForEach(Array(model.reports.enumerated()), id: \.offset) { _, report in
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.source).font(.system(size: 13, weight: .medium))
                    Text(report.summary).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    ForEach(report.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.hoverTab))
            }
            Text("Imported bookmarks are behind the bookmark button at the bottom of the sidebar; pin the folders you use to keep them above your tabs. On login forms, use the key button next to the address to fill in a password.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.reports.contains(where: { $0.problems.contains(ImportRunner.fullDiskAccessProblem) }) {
                    Button("Open Full Disk Access Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .buttonStyle(SecondaryButton())
                }
                Spacer()
                Button("Get Started") { model.showAI() }.buttonStyle(PrimaryButton())
            }
            .padding(.top, 6)
        }
        .padding(24)
    }

    private var ai: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.primary)
            AIGuidance(availability: model.ai)
            HStack {
                Spacer()
                Button("Done") { finish() }.buttonStyle(PrimaryButton())
            }
            .padding(.top, 10)
        }
        .padding(28)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        browser.showOnboarding = false
        if browser.tabs.isEmpty { browser.commandBar = .newTab }
    }
}

struct SourceRow: View {
    let source: ImportSource
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isOn ? Theme.primary : Theme.faint)
            AppIcon(browser: source.browser)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                Text(source.supportsSecrets ? String(localized: "Bookmarks · History · Passwords · Cookies") : String(localized: "Bookmarks · History (Full Disk Access required)"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background { if isOn { SelectedBackground(radius: 10) } }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

/// The browser's own app icon when it's in /Applications.
struct AppIcon: View {
    let browser: String

    var body: some View {
        let names = ["Chrome": "Google Chrome", "Edge": "Microsoft Edge", "Brave": "Brave Browser"]
        let path = "/Applications/\(names[browser] ?? browser).app"
        if FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 26, height: 26)
        } else {
            Image(systemName: "globe").font(.system(size: 18)).frame(width: 26, height: 26).foregroundStyle(Theme.secondary)
        }
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(Capsule().fill(Theme.primary))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
    }
}

struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(Capsule().fill(Theme.field))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
