import AppKit
import LocalAuthentication
import SwiftUI
import WebKit

import AppKit
import LocalAuthentication
import SwiftUI
import WebKit

/// The pages in the settings sidebar, in groups.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, tabs, startPage, privacy, extensions, ai, advanced

    static let groups: [[SettingsPage]] = [[.general, .appearance, .tabs, .startPage], [.privacy, .extensions, .ai], [.advanced]]

    var id: String { rawValue }

    var name: String {
        switch self {
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .tabs: String(localized: "Tabs")
        case .startPage: String(localized: "Start Page")
        case .privacy: String(localized: "Privacy")
        case .extensions: String(localized: "Extensions")
        case .ai: String(localized: "AI")
        case .advanced: String(localized: "Advanced")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "macwindow"
        case .tabs: "square.on.square"
        case .startPage: "square.grid.2x2"
        case .privacy: "hand.raised"
        case .extensions: "puzzlepiece.extension"
        case .ai: "sparkles"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    /// What the sidebar search looks through besides the page's name: the label of every setting the page shows, written as the page writes it. The
    /// search finds each in the language the app is shown in and in English. A test reads the pages' source and fails for a label that is not here.
    var settings: [LocalizedStringResource] {
        switch self {
        case .general:
            ["Search", "Search Engine", "Get search suggestions as you type", "On Startup", "Downloads", "Downloads Folder", "Ask where to save each download",
             "Translation", "Translate pages with", "Model", "Browser", "Quit when the last window is closed", "Default Browser", "Other Browsers"]
        case .appearance:
            ["Theme", "Display", "Default Zoom"]
        case .tabs:
            ["Behavior", "Play video in Picture in Picture when you switch to another tab", "Sleep inactive tabs", "Sites that never sleep", "Tab Archive",
             "Close and archive tabs not viewed for…"]
        case .startPage:
            ["New Tabs Open"]
        case .privacy:
            ["Clear History", "Time Range", "Browsing History", "Site data such as cookies and cache (signs you out of sites)", "Stay signed in after quitting",
             "Ad Blocking", "Block ads and trackers", "Add filter list URL (e.g. a Korean ad list)", "Remove tracking from links", "Prefer secure connections",
             "Saved Passwords", "Require Touch ID to fill passwords", "Pop-ups", "Camera & Microphone"]
        case .extensions:
            ["Install", "Chrome Web Store URL or extension ID", "Safari Content Blockers"]
        case .ai:
            ["Model", "Effort", "Approvals", "Claude Code", "claude CLI", "Path override (leave empty to detect automatically)", "Keep chat history", "AI Chat"]
        case .advanced:
            ["Shortcuts", "Check for updates automatically", "Download and install updates automatically"]
        }
    }

    func matches(_ query: String) -> Bool {
        ([name] + settings.flatMap { [String(localized: $0), $0.key] }).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @AppStorage("settingsPage") private var pageName = SettingsPage.general.rawValue
    @State private var query = ""

    private var page: SettingsPage { SettingsPage(rawValue: pageName) ?? .general }
    private var search: String { query.trimmingCharacters(in: .whitespaces) }
    private var shown: [SettingsPage] { search.isEmpty ? SettingsPage.allCases : SettingsPage.allCases.filter { $0.matches(search) } }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsPage?>(get: { page }, set: { if let new = $0 { pageName = new.rawValue } })) {
                ForEach(SettingsPage.groups, id: \.first) { group in
                    let pages = group.filter(shown.contains)
                    if !pages.isEmpty {
                        Section {
                            ForEach(pages) { Label($0.name, systemImage: $0.symbol).tag($0) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) { searchField }
            .overlay { if shown.isEmpty { Text("No matching settings").foregroundStyle(.secondary) } }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                Text(page.name).font(.title2.bold()).padding(.horizontal, 20).padding(.top, 8)  // grid-exempt: lines up with the grouped Form's own inset
                detail
            }
            .navigationTitle("")
        }
        .frame(width: 720, height: 520)
        .onChange(of: query) {
            if let first = shown.first, !shown.contains(page) { pageName = first.rawValue }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).decorative()
            TextField("Search", text: $query).textFieldStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
        .padding(.horizontal, 10).padding(.bottom, 8)  // grid-exempt: lines up with the sidebar list's own inset
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case .general: GeneralSettings(prefs: prefs)
        case .appearance: AppearanceSettings(prefs: prefs)
        case .tabs: TabSettings(prefs: prefs)
        case .startPage: StartPageSettingsView()
        case .privacy: PrivacySettings(prefs: prefs)
        case .extensions: ExtensionSettings()
        case .ai: AISettings(prefs: prefs)
        case .advanced: AdvancedSettings(prefs: prefs)
        }
    }
}

struct Caption: View {
    let text: Text
    var color: Color = .secondary

    init(text: LocalizedStringKey, color: Color = .secondary) {
        self.text = Text(text)
        self.color = color
    }

    init(verbatim: String, color: Color = .secondary) {
        text = Text(verbatim: verbatim)
        self.color = color
    }

    var body: some View {
        text.font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}
