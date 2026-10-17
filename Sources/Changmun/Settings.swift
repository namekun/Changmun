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
                        Browser.shared.showOnboarding = true
                        NSApp.windows.first { $0 is BrowserWindow }?.makeKeyAndOrderFront(nil)
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
                    Slider(value: $prefs.sidebarWidth, in: 200...360, step: 4).frame(width: 220)
                }
                Picker("기본 확대", selection: $prefs.defaultZoom) {
                    ForEach([0.75, 0.9, 1, 1.1, 1.25, 1.5], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }
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
                    if let current = Browser.shared.active?.url?.host(), !prefs.neverSleepHosts.contains(current) {
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
            Section {
                Toggle("광고·추적 차단", isOn: $prefs.blockTrackers)
                Caption(text: "잘 알려진 광고·추적 서비스 \(ContentBlocker.hosts.count)곳을 다른 사이트에서 불러오지 못하게 막아요.")
            }
            Section {
                LabeledContent("저장된 비밀번호") {
                    HStack {
                        Text("\(passwordCount)개").foregroundStyle(.secondary)
                        Button("관리…") { showPasswords = true }
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
        if clearHistory { done.append("방문 기록 \(Library.shared.clearHistory(since: since))개") }
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
                Picker("주소창 위치", selection: $prefs.addressBar) {
                    Text("개발자 모드에 맞춤 (지금: \(Preferences.onTop(.automatic, developerMode: prefs.developerMode) ? "위" : "사이드바"))").tag(AddressBarChoice.automatic)
                    Text("왼쪽 사이드바").tag(AddressBarChoice.sidebar)
                    Text("위").tag(AddressBarChoice.top)
                }
                .pickerStyle(.radioGroup)
                Caption(text: "위에 두면 전체 주소가 보이고 그 자리에서 바로 고칠 수 있어요 (⌘L).")
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
                Caption(text: "켜면 주소창이 기본으로 위에 놓여요. 웹 인스펙터는 언제든 F12(네트워크 탭)나 ⌥⌘I로 열 수 있어요.")
            }
        }
        .formStyle(.grouped)
    }
}
