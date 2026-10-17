import AppKit
import SwiftUI

@MainActor
final class ImportModel: ObservableObject {
    enum Step { case welcome, choose, importing, done }

    @Published var step: Step = .welcome
    @Published var sources: [ImportSource] = []
    @Published var selected: Set<String> = []
    @Published var options = ImportOptions()
    @Published var status = ""
    @Published var reports: [ImportReport] = []

    init() {
        sources = BrowserDiscovery.sources()
        selected = Set(sources.filter(\.suggested).map(\.id))
    }

    var needsSecrets: Bool {
        (options.passwords || options.cookies) && sources.contains { selected.contains($0.id) && $0.supportsSecrets }
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
                }
            }
            .frame(width: 540)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .animation(.easeOut(duration: 0.22), value: model.step)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.primary)
            Text("Changmun에 오신 걸 환영해요")
                .font(.system(size: 22, weight: .semibold))
            Text("Safari와 같은 WebKit 엔진이라 가볍고, 오른쪽 AI 패널(⌘E)에 말하면 AI가 페이지를 읽고 대신 클릭하고 입력해요.\n쓰던 브라우저의 북마크, 방문 기록, 비밀번호, 로그인 상태를 가져올까요?")
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(Color.primary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("나중에") { finish() }.buttonStyle(SecondaryButton())
                Spacer()
                Button("가져오기") { model.step = .choose }.buttonStyle(PrimaryButton())
            }
            .padding(.top, 10)
        }
        .padding(28)
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("어디서 가져올까요?").font(.system(size: 18, weight: .semibold))
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
                Toggle("북마크", isOn: $model.options.bookmarks)
                Toggle("방문 기록", isOn: $model.options.history)
                Toggle("비밀번호", isOn: $model.options.passwords)
                Toggle("로그인 상태(쿠키)", isOn: $model.options.cookies)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12.5))
            if model.needsSecrets {
                Label("비밀번호와 로그인 상태는 각 브라우저가 키체인에 잠가 둬서, macOS가 접근 허용을 물어봐요. 로그인 암호를 넣고 '허용'을 눌러 주세요. 가져온 비밀번호는 이 Mac의 키체인에만 저장돼요.", systemImage: "key")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("뒤로") { model.step = .welcome }.buttonStyle(SecondaryButton())
                Spacer()
                Button("가져오기 시작") { model.start() }
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
            Text(model.status.isEmpty ? "준비 중…" : model.status)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("다 가져왔어요").font(.system(size: 18, weight: .semibold))
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
            Text("가져온 북마크는 왼쪽 사이드바의 폴더에 있어요. 로그인 칸에서는 주소 옆 열쇠 버튼으로 비밀번호를 채울 수 있어요.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.reports.contains(where: { $0.problems.contains { $0.contains("전체 디스크") } }) {
                    Button("전체 디스크 접근 설정 열기") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .buttonStyle(SecondaryButton())
                }
                Spacer()
                Button("시작하기") { finish() }.buttonStyle(PrimaryButton())
            }
            .padding(.top, 6)
        }
        .padding(24)
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
                Text(source.supportsSecrets ? "북마크 · 기록 · 비밀번호 · 쿠키" : "북마크 · 기록 (전체 디스크 접근 권한 필요)")
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
