import AppKit
import SwiftUI

/// The app's other windows (settings, history, downloads), each made once and brought back on request.
@MainActor
enum Panels {
    private static var windows: [String: NSWindow] = [:]

    static func show<V: View>(_ id: String, title: String, size: NSSize, resizable: Bool = true, @ViewBuilder content: () -> V) {
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .resizable, .miniaturizable] : [.titled, .closable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Changmun." + id)
        if !window.setFrameUsingName("Changmun." + id) { window.center() }
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: History

struct HistoryView: View {
    @State private var search = ""
    @State private var visits: [Library.Visit] = []

    private var days: [(day: Date, visits: [Library.Visit])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visits) { calendar.startOfDay(for: $0.lastVisit) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("방문 기록 검색", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            List {
                ForEach(days, id: \.day) { day in
                    Section(day.day.formatted(.dateTime.year().month().day().weekday(.wide))) {
                        ForEach(day.visits) { visit in
                            HistoryRow(visit: visit)
                                .contextMenu {
                                    Button("새 탭에서 열기") { open(visit) }
                                    Button("주소 복사") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(visit.url, forType: .string)
                                    }
                                    Divider()
                                    Button("기록에서 지우기") {
                                        Library.shared.deleteHistory(url: visit.url)
                                        reload()
                                    }
                                }
                                .onTapGesture(count: 2) { open(visit) }
                        }
                    }
                }
            }
            .overlay { if visits.isEmpty { Text(search.isEmpty ? "방문 기록이 없어요" : "찾는 기록이 없어요").foregroundStyle(.secondary) } }
            HStack {
                Text("두 번 클릭하면 새 탭에서 열려요. 기간별로 지우기는 설정 › 개인정보에서 할 수 있어요.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear(perform: reload)
        .onChange(of: search) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: Library.didChange)) { _ in reload() }
    }

    private func reload() {
        visits = Library.shared.history(matching: search, limit: 1000)
    }

    private func open(_ visit: Library.Visit) {
        Browser.shared.openBookmark(visit.url, key: nil)
        NSApp.windows.first { $0 is BrowserWindow }?.makeKeyAndOrderFront(nil)
    }
}

struct HistoryRow: View {
    let visit: Library.Visit

    var body: some View {
        HStack(spacing: 10) {
            Text(visit.lastVisit.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            SiteIcon(url: visit.url, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(visit.title.isEmpty ? visit.url : visit.title).lineLimit(1)
                Text(URL(string: visit.url)?.host() ?? visit.url).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .help(visit.url)
    }
}

// MARK: Downloads

struct DownloadsView: View {
    @ObservedObject var downloads = Downloads.shared

    var body: some View {
        VStack(spacing: 0) {
            List(downloads.items) { item in
                DownloadRow(item: item)
            }
            .overlay { if downloads.items.isEmpty { Text("이번에 받은 파일이 없어요").foregroundStyle(.secondary) } }
            HStack {
                Button("다운로드 폴더 열기") { NSWorkspace.shared.open(Preferences.shared.downloadFolder) }
                Spacer()
                Button("끝난 항목 지우기") { downloads.clearFinished() }.disabled(!downloads.items.contains { $0.state != .running })
            }
            .padding(10)
        }
        .frame(minWidth: 440, minHeight: 300)
    }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let destination = item.destination, item.state == .finished {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: destination.path)).resizable()
                } else {
                    Image(systemName: "arrow.down.circle").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .running:
                    ProgressView(value: item.progress).controlSize(.small)
                case .finished:
                    Text("완료").font(.system(size: 11)).foregroundStyle(.secondary)
                case .cancelled:
                    Text("취소됨").font(.system(size: 11)).foregroundStyle(.secondary)
                case .failed(let reason):
                    Text("실패: \(reason)").font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if item.state == .running {
                Button { item.download?.cancel { _ in } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("취소")
            } else if let destination = item.destination, item.state == .finished {
                Button { NSWorkspace.shared.activateFileViewerSelecting([destination]) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.borderless).help("Finder에서 보기")
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: Find in page

struct FindBar: View {
    @ObservedObject var browser: Browser
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            TextField("페이지에서 찾기", text: $browser.findText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 180)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    browser.find(backwards: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(.escape) {
                    browser.hideFindBar()
                    return .handled
                }
            if let matches = browser.findMatches, !browser.findText.isEmpty {
                Text(matches == 0 ? "없음" : "\(matches)개")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(matches == 0 ? Color.red : Theme.secondary)
            }
            BarButton(symbol: "chevron.up", help: "이전 (⌘⇧G)") { browser.find(backwards: true) }.disabled(browser.findText.isEmpty)
            BarButton(symbol: "chevron.down", help: "다음 (⌘G)") { browser.find() }.disabled(browser.findText.isEmpty)
            BarButton(symbol: "xmark", help: "닫기 (esc)") { browser.hideFindBar() }
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card).shadow(color: .black.opacity(0.18), radius: 10, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .padding(10)
        .onAppear { focused = true }
        .onChange(of: browser.findFocusRequest) { focused = true }
        .onChange(of: browser.findText) { browser.find() }
    }
}
