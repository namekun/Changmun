import AppKit
import LocalAuthentication
import SwiftUI
import WebKit

struct SettingsView: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        TabView {
            GeneralSettings(prefs: prefs).tabItem { Label("일반", systemImage: "gearshape") }
            LooksSettings(prefs: prefs).tabItem { Label("탭·모양", systemImage: "macwindow") }
            PrivacySettings(prefs: prefs).tabItem { Label("개인정보", systemImage: "hand.raised") }
            ExtensionSettings().tabItem { Label("확장", systemImage: "puzzlepiece.extension") }
            AISettings(prefs: prefs).tabItem { Label("AI", systemImage: "sparkles") }
            AdvancedSettings(prefs: prefs).tabItem { Label("고급", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 580, height: 500)
    }
}

private struct Caption: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

struct GeneralSettings: View {
    @ObservedObject var prefs: Preferences
    @State private var isDefaultBrowser = false

    var body: some View {
        Form {
            Section {
                Picker("검색 엔진", selection: $prefs.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                Toggle("입력하는 동안 검색어 추천 받기", isOn: $prefs.searchSuggestions)
                    .help("명령 막대에 입력한 글자를 검색 엔진에 보내 추천을 받아요. 개인 창에서는 보내지 않아요.")
                Picker("시작할 때", selection: $prefs.restoreTabs) {
                    Text("지난 탭 다시 열기").tag(true)
                    Text("새 탭으로 시작").tag(false)
                }
            }
            Section {
                LabeledContent("다운로드 폴더") {
                    HStack {
                        Text(prefs.downloadFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                        Button("변경…", action: chooseFolder)
                    }
                }
                Toggle("다운로드할 때마다 저장 위치 묻기", isOn: $prefs.askWhereToSave)
            }
            Section {
                LabeledContent("기본 브라우저") {
                    if isDefaultBrowser {
                        Text("Changmun을 쓰고 있어요").foregroundStyle(.secondary)
                    } else {
                        Button("기본 브라우저로 설정", action: makeDefault)
                    }
                }
                LabeledContent("다른 브라우저") {
                    Button("북마크·기록·비밀번호 가져오기…") {
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

// MARK: Tabs and looks

struct LooksSettings: View {
    @ObservedObject var prefs: Preferences
    @State private var newHost = ""

    var body: some View {
        Form {
            Section {
                Picker("테마", selection: $prefs.appearance) {
                    Text("시스템").tag(AppAppearance.system)
                    Text("라이트").tag(AppAppearance.light)
                    Text("다크").tag(AppAppearance.dark)
                }
                .pickerStyle(.segmented)
                LabeledContent("사이드바 폭") {
                    Slider(value: $prefs.sidebarWidth, in: Preferences.sidebarWidths, step: 4).frame(width: 220)
                }
                Picker("기본 확대", selection: $prefs.defaultZoom) {
                    ForEach([0.75, 0.9, 1, 1.1, 1.25, 1.5], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }
                Toggle("다른 탭으로 가면 재생 중인 영상을 화면 속 화면으로", isOn: $prefs.autoPictureInPicture)
            }
            Section {
                Picker("안 보는 탭 재우기", selection: $prefs.sleepMinutes) {
                    Text("끄기").tag(0)
                    Text("10분 뒤").tag(10)
                    Text("20분 뒤").tag(20)
                    Text("1시간 뒤").tag(60)
                }
                Caption(text: "재운 탭은 메모리를 비우고, 다시 볼 때 방문 기록과 함께 다시 불러와요. 메모리가 부족해지면 이 설정과 상관없이 재워요.")
            }
            Section("탭 정리") {
                Toggle("새 탭을 맞는 그룹에 자동으로 넣기", isOn: $prefs.groupNewTabs)
                Picker("오래 안 본 탭 보관", selection: $prefs.archiveHours) {
                    Text("끄기").tag(0)
                    Text("12시간 뒤").tag(12)
                    Text("하루 뒤").tag(24)
                    Text("일주일 뒤").tag(168)
                    Text("30일 뒤").tag(720)
                }
                Caption(text: "사이드바의 정리 버튼은 그룹에 없는 탭을 묶어요. Apple Intelligence가 켜져 있으면 이 Mac 안에서 주제별로 묶고, 아니면 같은 사이트와 한 탭에서 열어 간 탭끼리 묶어요. 보관한 탭은 방문 기록 › 보관한 탭에서 다시 열 수 있어요.")
            }
            Section("재우지 않을 사이트") {
                ForEach(prefs.neverSleepHosts, id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Button(role: .destructive) { prefs.neverSleepHosts.removeAll { $0 == host } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("예: music.youtube.com", text: $newHost)
                        .onSubmit(addHost)
                    Button("추가", action: addHost).disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let current = Browser.recent?.active?.url?.host(), !prefs.neverSleepHosts.contains(current) {
                        Button("지금 사이트") { prefs.neverSleepHosts.append(current) }
                    }
                }
                Caption(text: "음악·회의처럼 계속 켜 둘 사이트예요. 하위 도메인도 포함돼요.")
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
        var name: String { ["hour": "지난 1시간", "today": "오늘", "all": "전체"][rawValue]! }
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

    var body: some View {
        Form {
            Section("기록 지우기") {
                Picker("기간", selection: $range) {
                    ForEach(Range.allCases) { Text($0.name).tag($0) }
                }
                Toggle("방문 기록", isOn: $clearHistory)
                Toggle("쿠키·캐시 등 사이트 데이터 (로그인이 풀려요)", isOn: $clearSiteData)
                HStack {
                    if let cleared { Caption(text: cleared) }
                    Spacer()
                    Button("지우기…") { confirming = true }.disabled(!clearHistory && !clearSiteData)
                }
            }
            .confirmationDialog("\(range.name)의 \([clearHistory ? "방문 기록" : nil, clearSiteData ? "사이트 데이터" : nil].compactMap { $0 }.joined(separator: "과 "))를 지울까요?",
                                isPresented: $confirming) {
                Button("지우기", role: .destructive, action: clear)
            }
            AdBlockSection(prefs: prefs)
            Section {
                LabeledContent("저장된 비밀번호") {
                    HStack {
                        Text("\(passwordCount)개").foregroundStyle(.secondary)
                        Button("관리…") { showPasswords = true }
                    }
                }
                ForEach(prefs.neverSaveLoginHosts, id: \.self) { host in
                    HStack {
                        Text(host).lineLimit(1)
                        Spacer()
                        Caption(text: "저장 묻지 않음")
                        Button { prefs.neverSaveLoginHosts.removeAll { $0 == host } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("팝업") {
                Caption(text: "사이트가 클릭 없이 여는 팝업은 막고 페이지 위에 알려 줘요. '이 사이트는 항상 허용'을 고른 사이트는 여기에 남아요.")
                ForEach(prefs.popupHosts, id: \.self) { host in
                    HStack {
                        Text(host).lineLimit(1)
                        Spacer()
                        Caption(text: "팝업 허용")
                        Button { prefs.popupHosts.removeAll { $0 == host } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("카메라·마이크") {
                if permissions.stored.isEmpty {
                    Caption(text: "사이트가 처음 요청할 때 묻고, '기억하기'를 고르면 여기에 남아요.")
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
            done.append("방문 기록 \(Library.shared.clearHistory(since: since))개")
            // Remembered zoom sizes and closed windows name the sites too.
            if range == .all { prefs.siteZoom = [:] }
            Browser.closedWindows = []
        }
        if clearSiteData {
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: since) {}
            done.append("사이트 데이터")
        }
        cleared = "지웠어요: " + done.joined(separator: ", ")
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
                Text("저장된 비밀번호").font(.headline)
                Spacer()
                TextField("검색", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            .padding(14)
            List {
                ForEach(shown) { login in
                    HStack {
                        SiteIcon(url: "https://\(login.host)/", size: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(login.host)
                            Text(login.username.isEmpty ? "(아이디 없음)" : login.username).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if copied == login.id { Text("복사했어요").font(.system(size: 11)).foregroundStyle(.secondary) }
                        Button("비밀번호 복사") { Task { await copy(login) } }.buttonStyle(.borderless)
                        Button(role: .destructive) { deleting = login } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            .overlay { if logins.isEmpty { Text("저장된 비밀번호가 없어요").foregroundStyle(.secondary) } }
            HStack {
                Caption(text: "복사하려면 Touch ID나 Mac 암호로 확인해야 해요. 비밀번호는 이 Mac의 키체인에만 있어요.")
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 540, height: 440)
        .confirmationDialog("\(deleting?.host ?? "")의 비밀번호를 지울까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("지우기", role: .destructive) {
                if let login = deleting { Logins.delete(host: login.host, username: login.username) }
                logins = Logins.all()
                deleting = nil
            }
        }
    }

    private func copy(_ login: Logins.Saved) async {
        if !unlocked {
            let context = LAContext()
            unlocked = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "저장된 비밀번호를 복사하려면 확인이 필요해요")) == true
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
        Section("광고 차단") {
            Toggle("광고·추적 차단", isOn: $prefs.blockTrackers)
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
                    TextField("필터 목록 주소 추가 (예: 한국 광고 목록)", text: $newList).onSubmit(addList)
                    Button("추가", action: addList).disabled(URL(string: newList)?.scheme?.hasPrefix("http") != true)
                }
                HStack {
                    Caption(text: [blocker.status, blocker.lastUpdated.map { "마지막 업데이트 " + $0.formatted(date: .abbreviated, time: .shortened) }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    Spacer()
                    if blocker.working { ProgressView().controlSize(.small) }
                    Button("지금 업데이트") { Task { await blocker.update() } }.disabled(blocker.working)
                }
                if !prefs.adBlockAllowlist.isEmpty {
                    ForEach(prefs.adBlockAllowlist, id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Text("차단 안 함").foregroundStyle(.secondary)
                            Button { blocker.toggleSite(host) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                }
                Caption(text: "목록은 4일마다 새로 받아요. 사이트가 깨지면 주소창의 방패 버튼으로 그 사이트만 끌 수 있어요.")
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
                Caption(text: "웹 확장은 macOS 15.4 이상에서 쓸 수 있어요.")
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
        Section("Safari 콘텐츠 차단기") {
            if host.blockers.isEmpty {
                Caption(text: "설치된 콘텐츠 차단기가 없어요.")
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
            Caption(text: "차단기 앱이 저장해 둔 규칙을 읽어 와요. 처음 켤 때 macOS가 다른 앱의 데이터에 접근해도 되는지 물어요. 차단기 앱에서 규칙을 바꾸면 Changmun을 다시 켤 때 반영돼요.")
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
                    Caption(text: "아직 확장이 없어요. App Store의 Safari 확장이나 Chrome 웹 스토어의 확장을 설치할 수 있어요.")
                }
                ForEach(host.found) { source in
                    ExtensionRow(host: host, source: source)
                }
            }
            Section("설치") {
                HStack {
                    Button("App Store에서 Safari 확장 찾기…") { NSWorkspace.shared.open(SafariExtensionGallery.url) }
                    Spacer()
                    Button("폴더에서 불러오기…", action: chooseFolder)
                }
                HStack {
                    TextField("Chrome 웹 스토어 주소 또는 확장 ID", text: $storeAddress)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(installFromStore)
                    if let id = ChromeWebStore.extensionID(from: storeAddress), host.installing.contains(id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("설치", action: installFromStore).disabled(ChromeWebStore.extensionID(from: storeAddress) == nil)
                    }
                }
                if let error = host.storeErrors[ChromeWebStore.extensionID(from: storeAddress) ?? storeAddress] {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }
                Caption(text: "App Store에서 받은 Safari 확장은 여기에 저절로 나타나요. Chrome 웹 스토어 페이지를 열면 페이지 위에 'Changmun에 추가'가 떠요. 네이티브 앱과 주고받는 기능 등 일부는 동작하지 않을 수 있어요.")
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
        panel.message = "manifest.json이 들어 있는 확장 폴더를 고르세요"
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
                    Text(source.kind == .safari ? "Safari 확장"
                         : ExtensionHost.isFromChromeWebStore(source) ? "Chrome 웹 스토어"
                         : source.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let item, item.context.optionsPageURL != nil {
                Button("설정") { host.openOptions(item) }.buttonStyle(.borderless)
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
    @State private var status = "확인하는 중…"

    var body: some View {
        Form {
            Section {
                Picker("모델", selection: $prefs.aiModel) {
                    Text("Sonnet (빠르고 균형 잡힘)").tag("sonnet")
                    Text("Opus (가장 똑똑함, 느림)").tag("opus")
                    Text("Haiku (가장 빠름)").tag("haiku")
                }
            }
            Section {
                Toggle("다른 탭을 쓰거나, 새 주소를 열거나, 입력하기 전에 묻기", isOn: $prefs.aiApprovals)
                if prefs.aiApprovals {
                    Caption(text: "보고 있는 탭과 이미 아는 주소에서는 묻지 않아요.")
                } else {
                    Caption(text: "끄면 웹 페이지에 숨은 지시로 AI가 다른 탭이나 앞서 읽은 내용을 밖으로 보낼 수 있어요.", color: .orange)
                }
            }
            Section("Claude Code") {
                LabeledContent("claude CLI") { Text(status).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing) }
                TextField("경로 직접 지정 (비워 두면 자동으로 찾기)", text: $prefs.claudePath)
                Caption(text: "AI 패널은 이 Mac의 Claude Code 로그인(구독)을 써요.")
            }
            Section {
                LabeledContent("AI 대화") {
                    Button("대화 지우기") { ChatStore.shared.reset() }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: prefs.claudePath) { status = await Self.checkClaude() }
    }

    static func checkClaude() async -> String {
        guard let path = await MainActor.run(body: { ChatStore.claudePath() }) else { return "찾지 못했어요. Claude Code를 설치하거나 경로를 지정하세요." }
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
        return version.map { "\($0)\n\(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))" } ?? "실행하지 못했어요: \(path)"
    }
}

// MARK: Advanced

struct AdvancedSettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Picker("주소창", selection: $prefs.addressBar) {
                    Text("개발자 모드에 맞춤 (지금: \(Preferences.onTop(.automatic, developerMode: prefs.developerMode) ? "전체 주소" : "사이트와 제목"))").tag(AddressBarChoice.automatic)
                    Text("사이트와 제목").tag(AddressBarChoice.sidebar)
                    Text("전체 주소").tag(AddressBarChoice.top)
                }
                .pickerStyle(.radioGroup)
                Caption(text: "전체 주소는 그 자리에서 바로 고칠 수 있어요 (⌘L). 사이트와 제목은 ⌘L로 검색 창에서 고쳐요.")
            }
            Section {
                Picker("단축키", selection: $prefs.shortcuts) {
                    Text("Safari식").tag(ShortcutScheme.safari)
                    Text("Chrome식").tag(ShortcutScheme.chrome)
                }
                .pickerStyle(.segmented)
                Caption(text: prefs.shortcuts == .safari
                        ? "사이드바 ⌘⇧L · 강력 새로고침 ⌥⌘R · 콘솔 ⌥⌘C · 다운로드 ⌥⌘L"
                        : "사이드바 ⌘S · 강력 새로고침 ⌘⇧R · 콘솔 ⌥⌘J · 다운로드 ⌘⇧J · 탭 이동 ⌥⌘← ⌥⌘→")
            }
            Section {
                Toggle("개발자 모드", isOn: $prefs.developerMode)
                Caption(text: "켜면 주소창이 기본으로 전체 주소를 보여 줘요. 웹 인스펙터는 언제든 F12(네트워크 탭)나 ⌥⌘I로 열 수 있어요.")
            }
        }
        .formStyle(.grouped)
    }
}
