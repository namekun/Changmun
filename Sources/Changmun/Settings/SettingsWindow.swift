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
        case .startPage: String(localized: "New Tab & Start Page")
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

    /// What the sidebar search looks through besides the page's name: the labels of its settings.
    private var settings: [String] {
        switch self {
        case .general:
            [String(localized: "Search Engine"), String(localized: "Get search suggestions as you type"), String(localized: "On Startup"),
             String(localized: "Downloads Folder"), String(localized: "Ask where to save each download"),
             String(localized: "Default Browser"), String(localized: "Other Browsers")]
        case .appearance:
            [String(localized: "Theme"), String(localized: "Address Bar Position"), String(localized: "Address Bar"),
             String(localized: "Sidebar Width"), String(localized: "Default Zoom")]
        case .tabs:
            [String(localized: "Play video in Picture in Picture when you switch to another tab"), String(localized: "Sleep inactive tabs"),
             String(localized: "Sites that never sleep"), String(localized: "Tab Cleanup"),
             String(localized: "Automatically put new tabs in the right group"), String(localized: "Archive tabs you haven’t viewed in a while")]
        case .startPage:
            [String(localized: "Style"), String(localized: "Sections"), String(localized: "Background"), String(localized: "New Tabs Open")]
        case .privacy:
            [String(localized: "Clear History"), String(localized: "Ad Blocking"), String(localized: "Saved Passwords"),
             String(localized: "Pop-ups"), String(localized: "Camera & Microphone")]
        case .extensions:
            [String(localized: "Install"), String(localized: "Safari Content Blockers")]
        case .ai:
            [String(localized: "Model"), String(localized: "Claude Code"), String(localized: "AI Chat")]
        case .advanced:
            [String(localized: "Shortcuts"), String(localized: "Developer Mode"),
             String(localized: "Check for updates automatically"), String(localized: "Download and install updates automatically")]
        }
    }

    func matches(_ query: String) -> Bool {
        ([name] + settings).contains { $0.localizedCaseInsensitiveContains(query) }
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
                Text(page.name).font(.title2.bold()).padding(.horizontal, 20).padding(.top, 6)
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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).decorative()
            TextField("Search", text: $query).textFieldStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10).padding(.bottom, 6)
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
        text.font(.system(size: 11.5)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}
