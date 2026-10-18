import AppKit
import SwiftUI

/// The app's other windows (settings, history), each made once and brought back on request.
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
        let browser = Browser.recent ?? BrowserWindow.open()
        browser.openBookmark(visit.url, key: nil)
        browser.window?.makeKeyAndOrderFront(nil)
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

/// The download button: a ring while files come in, a dot once one finished unseen, and the list in a popover.
struct DownloadButton: View {
    @ObservedObject var browser: Browser
    let arrowEdge: Edge
    @ObservedObject private var downloads = Downloads.shared
    @State private var hover = false

    var body: some View {
        let items = downloads.items(isPrivate: browser.isPrivate)
        let progress = Downloads.progress(of: items)
        let unseen = items.contains { $0.state == .finished && !$0.seen }
        Button { browser.showDownloads.toggle() } label: {
            ZStack {
                if let progress {
                    Circle().stroke(Theme.track, lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.04, progress))
                        .stroke(Theme.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold))
                } else {
                    Image(systemName: "arrow.down.circle").font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: progress == nil ? nil : 15, height: progress == nil ? nil : 15)
            .frame(width: 28, height: 28)
            .overlay(alignment: .topTrailing) {
                if unseen { Circle().fill(Theme.working).frame(width: 6, height: 6).padding(5) }
            }
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover || browser.showDownloads ? Theme.field : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hover || progress != nil ? Theme.primary : Theme.dim)
        .onHover { hover = $0 }
        .help("다운로드")
        .popover(isPresented: $browser.showDownloads, arrowEdge: arrowEdge) {
            DownloadList(isPrivate: browser.isPrivate)
        }
        .animation(.easeOut(duration: 0.2), value: progress == nil)
    }
}

struct DownloadList: View {
    let isPrivate: Bool
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        let items = downloads.items(isPrivate: isPrivate)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("다운로드").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                Spacer()
                BarButton(symbol: "folder", help: "다운로드 폴더 열기") { NSWorkspace.shared.open(Preferences.shared.downloadFolder) }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 40)
            if items.isEmpty {
                Text("이번에 받은 파일이 없어요")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
            } else {
                Group {
                    if items.count > 6 {
                        ScrollView { rows(items) }.frame(height: 6 * DownloadRow.height + 12)
                    } else {
                        rows(items)
                    }
                }
                if items.contains(where: \.isDone) {
                    Hairline()
                    Button("끝난 항목 지우기") { downloads.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                }
            }
        }
        .frame(width: 320)
        .onAppear { downloads.markSeen(isPrivate: isPrivate) }
        .onChange(of: items.filter(\.isDone).count) { downloads.markSeen(isPrivate: isPrivate) }
    }

    private func rows(_ items: [DownloadItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { DownloadRow(item: $0) }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }
}

/// Files that are coming in, at the bottom of the sidebar; each stays a few seconds after it finishes.
struct DownloadShelf: View {
    let browser: Browser
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        let items = Array(downloads.shelf(isPrivate: browser.isPrivate).prefix(3))
        VStack(spacing: 0) {
            ForEach(items) { item in
                DownloadRow(item: item).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .animation(.easeOut(duration: 0.2), value: items.map(\.id))
    }
}

struct DownloadRow: View {
    static let height: CGFloat = 42
    @ObservedObject var item: DownloadItem
    @State private var hover = false

    private var file: URL? { item.state == .finished ? item.destination : nil }

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let file {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable()
                } else {
                    Image(systemName: item.state == .running ? "arrow.down.circle" : "exclamationmark.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.faint)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            Spacer(minLength: 0)
            if item.state == .running {
                HoverAction(symbol: "xmark", help: "취소") { item.download?.cancel { _ in } }
            } else if hover, let file {
                HoverAction(symbol: "magnifyingglass", help: "Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover && file != nil ? Theme.hoverTab : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { open() }
        .onDrag { file.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
        .contextMenu {
            if let file {
                Button("열기") { open() }
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                Button("경로 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            }
            if item.state == .running {
                Button("취소") { item.download?.cancel { _ in } }
            }
        }
        .help(file.map { "\($0.path)\n누르면 열려요. 끌어서 다른 앱에 넣을 수 있어요." } ?? item.filename)
    }

    @ViewBuilder private var detail: some View {
        switch item.state {
        case .running:
            HStack(spacing: 6) {
                Meter(fraction: item.progress)
                Text("\(Int((item.progress * 100).rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
        case .finished:
            Text(item.bytes.map { "완료 · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "완료")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
        case .cancelled:
            Text("취소됨").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint)
        case .failed(let reason):
            Text("실패: \(reason)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.waiting).lineLimit(1)
        }
    }

    private func open() {
        guard let file else { return }
        item.seen = true
        Downloads.shared.dismiss(item)
        NSWorkspace.shared.open(file)
    }
}

// MARK: Find in page

struct FindBar: View {
    let browser: Browser
    @ObservedObject var overlay: PageOverlay
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            TextField("페이지에서 찾기", text: $overlay.findText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.primary)
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
            if let matches = overlay.findMatches, !overlay.findText.isEmpty {
                Text(matches == 0 ? "없음" : "\(matches)개")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(matches == 0 ? Theme.waiting : Theme.secondary)
            }
            BarButton(symbol: "chevron.up", help: "이전 (⌘⇧G)") { browser.find(backwards: true) }.disabled(overlay.findText.isEmpty)
            BarButton(symbol: "chevron.down", help: "다음 (⌘G)") { browser.find() }.disabled(overlay.findText.isEmpty)
            BarButton(symbol: "xmark", help: "닫기 (esc)") { browser.hideFindBar() }
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.background))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .padding(10)
        .onAppear { focused = true }
        .onChange(of: overlay.findFocusRequest) { focused = true }
        .onChange(of: overlay.findText) { browser.find() }
    }
}
