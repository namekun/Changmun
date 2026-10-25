import AppKit
import SwiftUI
import UniformTypeIdentifiers

// What sits around the AI panel's box: the "+" menu, the mic, and the row under it with the approval mode, the model with its effort,
// and how full the conversation is.

/// How hard the AI thinks (`claude --effort`). Not chosen (the preference is empty) leaves the flag out, so `claude` does as it always did.
enum AIEffort: String, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .xhigh: String(localized: "Extra High")
        case .max: String(localized: "Max")
        }
    }

    /// The arguments for the preference's value: none for "auto" (empty) and for anything that is not a level `claude` knows.
    static func arguments(for stored: String) -> [String] {
        AIEffort(rawValue: stored).map { ["--effort", $0.rawValue] } ?? []
    }

    /// The model chip's words: "Sonnet · High", or just "Sonnet" when the effort is left to `claude`.
    static func label(model: String, effort stored: String) -> String {
        let name = AIModels.name(of: model)
        return AIEffort(rawValue: stored).map { "\(name) · \($0.title)" } ?? name
    }
}

enum AIModels {
    static let all = ["sonnet", "opus", "haiku"]

    /// Whether a model may follow `--model`: a name of letters, digits, dots, underscores and hyphens that doesn't begin with a hyphen, so that
    /// nothing the preference holds can pass for another option of `claude`.
    static func isPassable(_ model: String) -> Bool {
        guard let first = model.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic || (48...57).contains(first.value) else { return false }
        return model.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || (48...57).contains($0.value) || ".-_".unicodeScalars.contains($0)) }
    }

    /// "sonnet" as it is called; a model name set some other way is shown as it is.
    static func name(of model: String) -> String {
        all.contains(model) ? model.prefix(1).uppercased() + model.dropFirst() : model
    }
}

/// How full the conversation's context is, from the token counts `claude` reports in its stream.
struct ContextUsage: Equatable {
    var used: Int
    var window: Int

    /// What a model's context window is taken to be until `claude` says (the result of a run names it).
    static let defaultWindow = 200_000

    /// 0...1.
    var fraction: Double { window > 0 ? min(Double(used) / Double(window), 1) : 0 }

    /// The input a request held: what was new, what was written to the cache and what was read from it. Nil when the usage says none of them.
    static func tokens(in usage: [String: Any]) -> Int? {
        let keys = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
        let counts = keys.compactMap { usage[$0] as? Int }
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    /// The largest context window a result's per-model usage names.
    static func window(inModelUsage models: [String: Any]) -> Int? {
        models.values.compactMap { ($0 as? [String: Any])?["contextWindow"] as? Int }.filter { $0 > 0 }.max()
    }

    /// "46k", "1.2M".
    static func short(_ tokens: Int) -> String {
        switch tokens {
        case ..<1000: "\(tokens)"
        case ..<1_000_000: "\(tokens / 1000)k"
        default: String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
    }

    var percentText: String { fraction.formatted(.percent.precision(.fractionLength(0))) }

    var tooltip: String {
        String(localized: "Context used: \(percentText) (\(Self.short(used)) of \(Self.short(window)) tokens)")
    }
}

/// How long a run has lasted, in the words of the user's language ("4s", "1m 5s").
enum ElapsedText {
    static func text(seconds: Int, locale: Locale = .current) -> String {
        let style = Duration.UnitsFormatStyle(allowedUnits: seconds >= 60 ? [.minutes, .seconds] : [.seconds], width: .narrow).locale(locale)
        return Duration.seconds(max(seconds, 0)).formatted(style)
    }
}

// MARK: Views

extension View {
    /// A menu that looks like the label it is given (the system's own menu styles take the label apart and draw it their way).
    func plainMenu(fixed: Bool = true) -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: fixed, vertical: false)
    }
}

private struct MenuLabel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) { content }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Theme.hoverTab))
            .contentShape(Capsule())
    }
}

/// The row under the box: how much the AI asks before it acts, the model with its effort, and the context ring.
struct ComposerControlsRow: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var chat: ChatStore

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Approvals", selection: $prefs.aiApprovalMode) {
                    ForEach(AIApprovalMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                MenuLabel {
                    Image(systemName: "hand.raised").font(.system(size: 10, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
            }
            .plainMenu()
            .help(prefs.aiApprovalMode.title)
            .accessibilityLabel(Text("Approvals: \(prefs.aiApprovalMode.title)"))
            Spacer(minLength: 0)
            if !chat.showHistory, let usage = chat.contextUsage, usage.used > 0 {
                ContextRing(usage: usage)
            }
            Menu {
                Section("Model") {
                    Picker("Model", selection: $prefs.aiModel) {
                        Text("Sonnet (fast and balanced)").tag("sonnet")
                        Text("Opus (smartest, slower)").tag("opus")
                        Text("Haiku (fastest)").tag("haiku")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Effort") {
                    Picker("Effort", selection: $prefs.aiEffort) {
                        Text("Auto").tag("")
                        ForEach(AIEffort.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            } label: {
                MenuLabel {
                    Text(verbatim: AIEffort.label(model: prefs.aiModel, effort: prefs.aiEffort))
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
            }
            .plainMenu()
            .help("The model and effort for your next messages (also in Settings › AI)")
            .accessibilityLabel(Text("Model: \(AIEffort.label(model: prefs.aiModel, effort: prefs.aiEffort))"))
        }
    }
}

/// A small ring that fills as the conversation fills the model's context.
struct ContextRing: View {
    let usage: ContextUsage

    var body: some View {
        ZStack {
            Circle().stroke(Theme.hairline, lineWidth: 2)
            Circle().trim(from: 0, to: max(usage.fraction, 0.03))
                .stroke(usage.fraction > 0.8 ? Theme.waitingText : Theme.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .padding(.horizontal, 3)
        .help(usage.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usage.tooltip)
    }
}

/// The "+" in the box: more for the next message to go with.
struct ComposerPlusMenu: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var browser: Browser

    var body: some View {
        let tab = browser.active
        Menu {
            Menu("Add Tab…", systemImage: "square.on.square") {
                // A private window's tabs are not the AI's to read.
                let candidates = browser.tabs.filter { browser.isVisibleToAI($0) }
                ForEach(candidates.filter { !chat.attachedIDs.contains($0.id) }) { tab in
                    Button(tab.displayTitle) { chat.attach([tab]) }
                }
                if !browser.groups.isEmpty && !candidates.isEmpty {
                    Divider()
                    ForEach(browser.groups) { group in
                        Button(group.name, systemImage: "square.stack") { chat.attach(candidates.filter { $0.groupID == group.id }) }
                    }
                }
                Divider()
                Button("All Open Tabs") { chat.attach(candidates) }
            }
            Button("Attach Screenshot", systemImage: "camera.viewfinder") { Task { await chat.attachScreenshot(of: tab) } }
                .disabled(!chat.canAttachScreenshot(of: tab))
            Button("Add Image…", systemImage: "photo") { chat.chooseImages() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.pill))
                .contentShape(Circle())
        }
        .plainMenu()
        .help("Add tabs, a screenshot or images for the AI to look at")
    }
}

/// Starts the system's dictation in the box. It needs nothing of its own: the text comes into the box as if typed.
struct ComposerMicButton: View {
    var body: some View {
        Button(action: Self.startDictation) {
            Image(systemName: "mic")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dictate")
    }

    /// The action behind the Edit menu's "Start Dictation…", which the application answers for the text in front (it has no Swift name).
    private static let action = Selector(("startDictation:"))

    /// Whether the box can take dictation; the button isn't shown when it can't.
    static var available: Bool { NSApplication.instancesRespond(to: action) }

    @MainActor
    static func startDictation() {
        if let window = NSApp.keyWindow, let box = ComposerTextView.find(in: window) { window.makeFirstResponder(box) }
        NSApp.sendAction(action, to: nil, from: nil)
    }
}

/// The stop button in the box while the AI works (Esc does the same).
struct ComposerStopButton: View {
    let stop: () -> Void

    var body: some View {
        Button(action: stop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.primary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.pill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Stop generating")
        .accessibilityLabel(Text("Stop"))
    }
}

extension ChatStore {
    /// "Add Image…": the pictures the user picks go in as if they had dropped them.
    func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let sources = panel.urls.compactMap(ImageIntake.read)
            Task { @MainActor in self?.addImages(sources) }
        }
    }
}
