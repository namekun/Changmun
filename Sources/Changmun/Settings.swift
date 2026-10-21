import AppKit
import LocalAuthentication
import SwiftUI
import WebKit

/// The pages in the settings sidebar, in groups.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, tabs, privacy, extensions, ai, advanced

    static let groups: [[SettingsPage]] = [[.general, .appearance, .tabs], [.privacy, .extensions, .ai], [.advanced]]

    var id: String { rawValue }

    var name: String {
        switch self {
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .tabs: String(localized: "Tabs")
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
        case .privacy:
            [String(localized: "Clear History"), String(localized: "Ad Blocking"), String(localized: "Saved Passwords"),
             String(localized: "Pop-ups"), String(localized: "Camera & Microphone")]
        case .extensions:
            [String(localized: "Install"), String(localized: "Safari Content Blockers")]
        case .ai:
            [String(localized: "Model"), String(localized: "Claude Code"), String(localized: "AI Chat")]
        case .advanced:
            [String(localized: "Shortcuts"), String(localized: "Developer Mode"), String(localized: "Check for Updates")]
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
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
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
        case .privacy: PrivacySettings(prefs: prefs)
        case .extensions: ExtensionSettings()
        case .ai: AISettings(prefs: prefs)
        case .advanced: AdvancedSettings(prefs: prefs)
        }
    }
}

private struct Caption: View {
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

// MARK: General

struct GeneralSettings: View {
    @ObservedObject var prefs: Preferences
    @State private var isDefaultBrowser = false

    var body: some View {
        Form {
            Section("Search") {
                Picker("Search Engine", selection: $prefs.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                Toggle("Get search suggestions as you type", isOn: $prefs.searchSuggestions)
                    .help("What you type in the command bar is sent to your search engine to get suggestions. Nothing is sent in private windows.")
                Picker("On Startup", selection: $prefs.restoreTabs) {
                    Text("Reopen last session’s tabs").tag(true)
                    Text("Start with a new tab").tag(false)
                }
            }
            Section("Downloads") {
                LabeledContent("Downloads Folder") {
                    HStack {
                        Text(prefs.downloadFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                        Button("Change…", action: chooseFolder)
                    }
                }
                Toggle("Ask where to save each download", isOn: $prefs.askWhereToSave)
            }
            Section("Browser") {
                LabeledContent("Default Browser") {
                    if isDefaultBrowser {
                        Text("Changmun is your default browser").foregroundStyle(.secondary)
                    } else {
                        Button("Make Default Browser", action: makeDefault)
                    }
                }
                LabeledContent("Other Browsers") {
                    Button("Import Bookmarks, History, and Passwords…") {
                        let browser = Browser.recent ?? BrowserWindow.open()
                        browser.showOnboarding = true
                        browser.window?.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: checkDefault)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.downloadFolder
        if panel.runModal() == .OK, let url = panel.url { prefs.downloadFolder = url }
    }

    private func checkDefault() {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        isDefaultBrowser = handler?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func makeDefault() {
        for scheme in ["http", "https"] {
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { _ in
                DispatchQueue.main.async { checkDefault() }
            }
        }
    }
}

// MARK: Appearance

struct AppearanceSettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section("Theme") {
                HStack(spacing: 28) {
                    ForEach(AppAppearance.allCases) { ThemeTile(choice: $0, selection: $prefs.appearance) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section("Address Bar") {
                Picker("Address Bar Position", selection: $prefs.toolbarPlace) {
                    Text("Above the Page").tag(ToolbarPlace.page)
                    Text("In the Sidebar").tag(ToolbarPlace.sidebar)
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Address Bar")
                    addressBarChoice(.automatic) {
                        Text("Match developer mode (currently: \(Preferences.onTop(.automatic, developerMode: prefs.developerMode) ? String(localized: "Full Address") : String(localized: "Site and Title")))")
                    }
                    addressBarChoice(.sidebar) { Text("Site and Title") }
                    addressBarChoice(.top) { Text("Full Address") }
                }
                Caption(text: "A full address can be edited right in place (⌘L). With site and title, ⌘L opens the search field to edit it.")
            }
            Section("Display") {
                LabeledContent("Sidebar Width") {
                    Slider(value: $prefs.sidebarWidth, in: Preferences.sidebarWidths, step: 4).frame(width: 220)
                }
                Picker("Default Zoom", selection: $prefs.defaultZoom) {
                    ForEach([0.75, 0.9, 1, 1.1, 1.25, 1.5], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension AppearanceSettings {
    /// A radio row, with the radio on the left of its text.
    private func addressBarChoice(_ choice: AddressBarChoice, @ViewBuilder label: () -> some View) -> some View {
        Button { prefs.addressBar = choice } label: {
            HStack(spacing: 8) {
                Image(systemName: prefs.addressBar == choice ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(prefs.addressBar == choice ? Color.accentColor : .secondary)
                label()
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(prefs.addressBar == choice ? .isSelected : [])
    }
}

/// One theme as a small picture of the window in it; the system theme is cut across, half light and half dark.
private struct ThemeTile: View {
    let choice: AppAppearance
    @Binding var selection: AppAppearance

    private struct Slant: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.width * 0.62, y: 0))
            path.addLine(to: CGPoint(x: rect.width, y: 0))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width * 0.46, y: rect.height))
            path.closeSubpath()
            return path
        }
    }

    var body: some View {
        Button { selection = choice } label: {
            VStack(spacing: 6) {
                picture
                    .frame(width: 104, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: selection == choice ? 3 : 0))
                label
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == choice ? .isSelected : [])
    }

    @ViewBuilder private var label: some View {
        switch choice {
        case .system: Text("System")
        case .light: Text("Light")
        case .dark: Text("Dark")
        }
    }

    @ViewBuilder private var picture: some View {
        switch choice {
        case .system:
            ZStack {
                window(dark: false)
                window(dark: true).mask(Slant())
            }
        case .light: window(dark: false)
        case .dark: window(dark: true)
        }
    }

    private func window(dark: Bool) -> some View {
        let sidebar = dark ? Color(white: 0.13) : Color(white: 0.86)
        let page = dark ? Color(white: 0.17) : Color(white: 0.93)
        let bar = dark ? Color(white: 0.27) : Color.white
        return HStack(spacing: 0) {
            VStack(alignment: .leading) {
                HStack(spacing: 3) {
                    Circle().fill(.red); Circle().fill(.yellow); Circle().fill(.green)
                }
                .frame(height: 4.5)
                .padding(.top, 6)
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(width: 30)
            .background(sidebar)
            VStack(spacing: 5) {
                Spacer().frame(height: 3)
                ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 2.5).fill(bar).frame(height: 10) }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(page)
        }
    }
}

// MARK: Tabs

struct TabSettings: View {
    @ObservedObject var prefs: Preferences
    @State private var newHost = ""

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Play video in Picture in Picture when you switch to another tab", isOn: $prefs.autoPictureInPicture)
                Picker("Sleep inactive tabs", selection: $prefs.sleepMinutes) {
                    Text("Off").tag(0)
                    Text("After 10 minutes").tag(10)
                    Text("After 20 minutes").tag(20)
                    Text("After 1 hour").tag(60)
                }
                Caption(text: "Sleeping tabs free their memory and reload with their history when you go back to them. When memory runs low, tabs sleep regardless of this setting.")
            }
            Section("Sites that never sleep") {
                ForEach(prefs.neverSleepHosts, id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Button(role: .destructive) { prefs.neverSleepHosts.removeAll { $0 == host } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("e.g. music.youtube.com", text: $newHost)
                        .onSubmit(addHost)
                    Button("Add", action: addHost).disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let current = Browser.recent?.active?.url?.host(), !prefs.neverSleepHosts.contains(current) {
                        Button("Current Site") { prefs.neverSleepHosts.append(current) }
                    }
                }
                Caption(text: "For sites you keep open, like music or meetings. Subdomains are included.")
            }
            Section("Tab Cleanup") {
                Toggle("Automatically put new tabs in the right group", isOn: $prefs.groupNewTabs)
                Picker("Archive tabs you haven’t viewed in a while", selection: $prefs.archiveHours) {
                    Text("Off").tag(0)
                    Text("After 12 hours").tag(12)
                    Text("After 1 day").tag(24)
                    Text("After 1 week").tag(168)
                    Text("After 30 days").tag(720)
                }
                Caption(text: "The Tidy button in the sidebar groups tabs that aren’t in a group yet. With Apple Intelligence on, tabs are grouped by topic on this Mac; otherwise tabs from the same site, or opened from one another, are grouped together. You can reopen archived tabs from History › Archived Tabs.")
            }
        }
        .formStyle(.grouped)
    }

    private func addHost() {
        let host = newHost.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
        guard !host.isEmpty, !prefs.neverSleepHosts.contains(host) else { return }
        prefs.neverSleepHosts.append(host)
        newHost = ""
    }
}

// MARK: Privacy

struct PrivacySettings: View {
    enum Range: String, CaseIterable, Identifiable {
        case hour, today, all
        var id: String { rawValue }
        var name: String {
            switch self {
            case .hour: String(localized: "Past Hour")
            case .today: String(localized: "Today")
            case .all: String(localized: "All Time")
            }
        }
        var since: Date {
            switch self {
            case .hour: Date().addingTimeInterval(-3600)
            case .today: Calendar.current.startOfDay(for: Date())
            case .all: .distantPast
            }
        }
    }

    @ObservedObject var prefs: Preferences
    @ObservedObject private var permissions = SitePermissions.shared
    @State private var range = Range.hour
    @State private var clearHistory = true
    @State private var clearSiteData = false
    @State private var confirming = false
    @State private var cleared: String?
    @State private var showPasswords = false
    @State private var passwordCount = 0

    private var clearTarget: String {
        switch (clearHistory, clearSiteData) {
        case (true, true): String(localized: "browsing history and site data")
        case (true, false): String(localized: "browsing history")
        default: String(localized: "site data")
        }
    }

    var body: some View {
        Form {
            Section("Clear History") {
                Picker("Time Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.name).tag($0) }
                }
                Toggle("Browsing History", isOn: $clearHistory)
                Toggle("Site data such as cookies and cache (signs you out of sites)", isOn: $clearSiteData)
                HStack {
                    if let cleared { Caption(verbatim: cleared) }
                    Spacer()
                    Button("Clear…") { confirming = true }.disabled(!clearHistory && !clearSiteData)
                }
            }
            .confirmationDialog("Clear \(clearTarget)? (\(range.name))",
                                isPresented: $confirming) {
                Button("Clear", role: .destructive, action: clear)
            }
            AdBlockSection(prefs: prefs)
            Section {
                LabeledContent("Saved Passwords") {
                    HStack {
                        Text(passwordCount == 1 ? String(localized: "\(passwordCount) password") : String(localized: "\(passwordCount) passwords")).foregroundStyle(.secondary)
                        Button("Manage…") { showPasswords = true }
                    }
                }
                ForEach(prefs.neverSaveLoginHosts, id: \.self) { host in
                    HStack {
                        Text(host).lineLimit(1)
                        Spacer()
                        Caption(text: "Never ask to save")
                        Button { prefs.neverSaveLoginHosts.removeAll { $0 == host } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Pop-ups") {
                Caption(text: "Pop-ups that a site opens without a click are blocked, and you’re told about it over the page. Sites you chose “Always allow for this site” on stay here.")
                ForEach(prefs.popupHosts, id: \.self) { host in
                    HStack {
                        Text(host).lineLimit(1)
                        Spacer()
                        Caption(text: "Pop-ups allowed")
                        Button { prefs.popupHosts.removeAll { $0 == host } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Camera & Microphone") {
                if permissions.stored.isEmpty {
                    Caption(text: "Sites ask the first time they request access. If you choose “Remember”, they stay here.")
                }
                ForEach(permissions.stored.keys.sorted(), id: \.self) { host in
                    HStack {
                        Text(host).lineLimit(1)
                        Spacer()
                        ForEach(SitePermissions.Device.allCases, id: \.self) { device in
                            Picker(device.name, selection: Binding(get: { permissions.decision(host, device) },
                                                                   set: { permissions.set($0, host: host, device: device) })) {
                                ForEach(SitePermissions.Decision.allCases, id: \.self) { Text($0.name).tag($0) }
                            }
                            .fixedSize()
                        }
                        Button { permissions.forget(host) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { passwordCount = Logins.all().count }
        .sheet(isPresented: $showPasswords, onDismiss: { passwordCount = Logins.all().count }) { PasswordsSheet() }
    }

    private func clear() {
        let since = range.since
        var done: [String] = []
        if clearHistory {
            let removed = Library.shared.clearHistory(since: since)
            done.append(removed == 1 ? String(localized: "\(removed) history item") : String(localized: "\(removed) history items"))
            // Remembered zoom sizes and closed windows name the sites too.
            if range == .all { prefs.siteZoom = [:] }
            Browser.closedWindows = []
        }
        if clearSiteData {
            for store in [WKWebsiteDataStore.default()] + Profiles.stores(SpaceStore.shared.spaces) {
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: since) {}
            }
            done.append(String(localized: "Site data"))
        }
        cleared = String(localized: "Cleared: \(done.joined(separator: ", "))")
    }
}

struct PasswordsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logins = Logins.all()
    @State private var search = ""
    @State private var unlocked = false
    @State private var copied: String?
    @State private var deleting: Logins.Saved?

    private var shown: [Logins.Saved] {
        let q = search.lowercased()
        return q.isEmpty ? logins : logins.filter { $0.host.lowercased().contains(q) || $0.username.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Saved Passwords").font(.headline)
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            .padding(14)
            List {
                ForEach(shown) { login in
                    HStack {
                        SiteIcon(url: "https://\(login.host)/", size: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(login.host)
                            Text(login.username.isEmpty ? String(localized: "(No username)") : login.username).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if copied == login.id { Text("Copied").font(.system(size: 11)).foregroundStyle(.secondary) }
                        Button("Copy Password") { Task { await copy(login) } }.buttonStyle(.borderless)
                        Button(role: .destructive) { deleting = login } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            .overlay { if logins.isEmpty { Text("No saved passwords").foregroundStyle(.secondary) } }
            HStack {
                Caption(text: "Copying requires Touch ID or your Mac password. Passwords are stored only in this Mac’s keychain.")
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 540, height: 440)
        .confirmationDialog("Delete the password for \(deleting?.host ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let login = deleting { Logins.delete(host: login.host, username: login.username) }
                logins = Logins.all()
                deleting = nil
            }
        }
    }

    private func copy(_ login: Logins.Saved) async {
        if !unlocked {
            let context = LAContext()
            unlocked = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Authentication is required to copy the saved password"))) == true
        }
        guard unlocked, let password = Logins.password(host: login.host, username: login.username) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
        copied = login.id
    }
}

struct AdBlockSection: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var blocker = AdBlocker.shared
    @State private var newList = ""

    var body: some View {
        Section("Ad Blocking") {
            Toggle("Block ads and trackers", isOn: $prefs.blockTrackers)
            if prefs.blockTrackers {
                ForEach(blocker.lists) { list in
                    HStack {
                        Toggle(list.name, isOn: Binding(
                            get: { !prefs.disabledFilterLists.contains(list.id) },
                            set: { on in
                                prefs.disabledFilterLists.removeAll { $0 == list.id }
                                if !on { prefs.disabledFilterLists.append(list.id) }
                                Task { await blocker.update() }
                            }))
                        .lineLimit(1)
                        if list.id.hasPrefix("custom-") {
                            Button { prefs.customFilterLists.removeAll { $0 == list.url }; Task { await blocker.recompile() } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    TextField("Add filter list URL (e.g. a Korean ad list)", text: $newList).onSubmit(addList)
                    Button("Add", action: addList).disabled(URL(string: newList)?.scheme?.hasPrefix("http") != true)
                }
                HStack {
                    Caption(verbatim: [blocker.status, blocker.lastUpdated.map { String(localized: "Last updated \($0.formatted(date: .abbreviated, time: .shortened))") }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    Spacer()
                    if blocker.working { ProgressView().controlSize(.small) }
                    Button("Update Now") { Task { await blocker.update() } }.disabled(blocker.working)
                }
                if !prefs.adBlockAllowlist.isEmpty {
                    ForEach(prefs.adBlockAllowlist, id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Text("Not blocked").foregroundStyle(.secondary)
                            Button { blocker.toggleSite(host) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                }
                Caption(text: "Lists are re-downloaded every 4 days. If a site breaks, you can turn blocking off for just that site with the shield button in the address bar.")
            }
        }
    }

    private func addList() {
        let url = newList.trimmingCharacters(in: .whitespaces)
        guard URL(string: url)?.scheme?.hasPrefix("http") == true, !prefs.customFilterLists.contains(url) else { return }
        prefs.customFilterLists.append(url)
        newList = ""
        Task { await blocker.update() }
    }
}

// MARK: Extensions

struct ExtensionSettings: View {
    var body: some View {
        if #available(macOS 15.4, *) {
            ExtensionList(host: ExtensionHost.shared, blockers: ContentBlockerHost.shared)
        } else {
            Form {
                Caption(text: "Web extensions are available on macOS 15.4 or later.")
                ContentBlockerSection(host: ContentBlockerHost.shared)
            }
            .formStyle(.grouped)
        }
    }
}

/// Safari content blockers (Unicorn, AdGuard…): their rules, applied alongside the built-in ad blocking.
struct ContentBlockerSection: View {
    @ObservedObject var host: ContentBlockerHost

    var body: some View {
        Section("Safari Content Blockers") {
            if host.blockers.isEmpty {
                Caption(text: "No content blockers installed.")
            }
            ForEach(host.blockers) { blocker in
                HStack(spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled").frame(width: 24, height: 24).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(blocker.name).lineLimit(1)
                        if let status = host.status[blocker.bundleID] {
                            Text(status).font(.system(size: 11)).foregroundStyle(status.hasPrefix("[ERROR]") ? .red : .secondary).lineLimit(3)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { host.isEnabled(blocker) }, set: { on in Task { await host.setEnabled(blocker, on) } }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            Caption(text: "Reads the rules saved by the blocker app. The first time you turn one on, macOS asks whether Changmun may access another app’s data. If you change the rules in the blocker app, they take effect the next time you launch Changmun.")
        }
    }
}

@available(macOS 15.4, *)
struct ExtensionList: View {
    @ObservedObject var host: ExtensionHost
    let blockers: ContentBlockerHost
    @State private var storeAddress = ""

    var body: some View {
        Form {
            Section {
                if host.found.isEmpty {
                    Caption(text: "No extensions yet. You can install Safari extensions from the App Store or extensions from the Chrome Web Store.")
                }
                ForEach(host.found) { source in
                    ExtensionRow(host: host, source: source)
                }
            }
            Section("Install") {
                HStack {
                    Button("Find Safari Extensions on the App Store…") { NSWorkspace.shared.open(SafariExtensionGallery.url) }
                    Spacer()
                    Button("Load from Folder…", action: chooseFolder)
                }
                HStack {
                    TextField("Chrome Web Store URL or extension ID", text: $storeAddress)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(installFromStore)
                    if let id = ChromeWebStore.extensionID(from: storeAddress), host.installing.contains(id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Install", action: installFromStore).disabled(ChromeWebStore.extensionID(from: storeAddress) == nil)
                    }
                }
                if let error = host.storeErrors[ChromeWebStore.extensionID(from: storeAddress) ?? storeAddress] {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }
                Caption(text: "Safari extensions you get from the App Store show up here automatically. When you open a Chrome Web Store page, an “Add to Changmun” button appears over the page. Some features, such as talking to native apps, may not work.")
            }
            ContentBlockerSection(host: blockers)
        }
        .formStyle(.grouped)
        .onAppear {
            host.rescan()
            blockers.rescan()
        }
    }

    private func installFromStore() {
        guard ChromeWebStore.extensionID(from: storeAddress) != nil else { return }
        let input = storeAddress
        Task { await host.installFromChromeWebStore(input) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose an extension folder that contains manifest.json")
        if panel.runModal() == .OK, let url = panel.url { Task { await host.addFolder(url) } }
    }
}

@available(macOS 15.4, *)
struct ExtensionRow: View {
    @ObservedObject var host: ExtensionHost
    let source: ExtensionSource

    var body: some View {
        let item = host.loaded.first { $0.id == source.id }
        HStack(spacing: 10) {
            if let icon = item?.context.webExtension.icon(for: CGSize(width: 24, height: 24)) {
                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
            } else {
                Image(systemName: "puzzlepiece.extension").frame(width: 24, height: 24).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item?.name ?? Self.name(source)).lineLimit(1)
                if let failure = host.failures[source.path] {
                    Text(failure).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text(source.kind == .safari ? String(localized: "Safari Extension")
                         : ExtensionHost.isFromChromeWebStore(source) ? String(localized: "Chrome Web Store")
                         : source.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let item, item.context.optionsPageURL != nil {
                Button("Settings") { host.openOptions(item) }.buttonStyle(.borderless)
            }
            if source.kind == .folder {
                Button { Task { await host.removeFolder(source) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            Toggle("", isOn: Binding(get: { host.isLoaded(source) }, set: { on in Task { await host.setEnabled(source, on) } }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    /// Before loading, the extension's name is the app that carries it (or the folder).
    static func name(_ source: ExtensionSource) -> String {
        let url = URL(fileURLWithPath: source.path)
        if source.kind == .safari, let bundle = Bundle(url: url) {
            return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        }
        return url.lastPathComponent
    }
}

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
            }
            Section {
                Toggle("Ask before using other tabs, opening new addresses, or using a page after reading other sites", isOn: $prefs.aiApprovals)
                if prefs.aiApprovals {
                    Caption(text: "It doesn’t ask for the tab you’re viewing or for addresses it already knows.")
                } else {
                    Caption(text: "If you turn this off, instructions hidden in a web page can make the AI send other tabs or content it read earlier to the outside.", color: .orange)
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
        let version = await Task.detached { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        return version.map { "\($0)\n\(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))" } ?? String(localized: "Couldn’t run it: \(path)")
    }
}

// MARK: Advanced

struct AdvancedSettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Shortcuts", selection: $prefs.shortcuts) {
                    Text("Safari-style").tag(ShortcutScheme.safari)
                    Text("Chrome-style").tag(ShortcutScheme.chrome)
                }
                .pickerStyle(.segmented)
                Caption(text: prefs.shortcuts == .safari
                        ? "Sidebar ⌘⇧L · Hard Reload ⌥⌘R · Console ⌥⌘C · Downloads ⌥⌘L"
                        : "Sidebar ⌘S · Hard Reload ⌘⇧R · Console ⌥⌘J · Downloads ⌘⇧J · Move Between Tabs ⌥⌘← ⌥⌘→")
            }
            Section {
                Toggle("Developer Mode", isOn: $prefs.developerMode)
                Caption(text: "When on, the address bar shows the full address by default. You can open the Web Inspector any time with F12 (Network tab) or ⌥⌘I.")
            }
            Section {
                Toggle("Check for Updates", isOn: $prefs.checkForUpdates)
                Caption(text: "Once a day, Changmun asks GitHub whether a newer version is out and tells you in the sidebar. Nothing else is sent.")
            }
        }
        .formStyle(.grouped)
    }
}
