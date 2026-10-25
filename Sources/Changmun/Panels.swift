import AppKit
import SwiftUI

/// The app's other windows (settings, history), each made once and brought back on request.
@MainActor
enum Panels {
    private static var windows: [String: NSWindow] = [:]

    static func window(_ id: String) -> NSWindow? { windows[id] }

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
            TextField("Search History", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            List {
                ForEach(days, id: \.day) { day in
                    Section(day.day.formatted(.dateTime.year().month().day().weekday(.wide))) {
                        ForEach(day.visits) { visit in
                            HistoryRow(visit: visit)
                                .contextMenu {
                                    Button("Open in New Tab") { open(visit) }
                                    Button("Copy Address") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(visit.url, forType: .string)
                                    }
                                    Divider()
                                    Button("Remove from History") {
                                        Library.shared.deleteHistory(url: visit.url)
                                        reload()
                                    }
                                }
                                .onTapGesture(count: 2) { open(visit) }
                        }
                    }
                }
            }
            .overlay { if visits.isEmpty { Text(search.isEmpty ? String(localized: "No history") : String(localized: "No matching history")).foregroundStyle(.secondary) } }
            HStack {
                Text("Double-click to open in a new tab. To clear history by time range, go to Settings › Privacy.")
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

// MARK: Archive

struct ArchiveView: View {
    @ObservedObject private var archive = TabArchive.shared
    @State private var search = ""

    var body: some View {
        let entries = archive.matching(search)
        VStack(spacing: 0) {
            TextField("Search Archived Tabs", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            List(entries) { entry in
                ArchiveRow(entry: entry)
                    .contextMenu {
                        Button("Reopen") { open(entry) }
                        Button("Copy Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.url, forType: .string)
                        }
                        Divider()
                        Button("Remove from Archive") { archive.remove(entry.id) }
                    }
                    .onTapGesture(count: 2) { open(entry) }
            }
            .overlay {
                if entries.isEmpty { Text(search.isEmpty ? String(localized: "No archived tabs") : String(localized: "No matching tabs")).foregroundStyle(.secondary) }
            }
            HStack {
                Text("Double-click to reopen. Set how long until tabs are archived in Settings › Tabs.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") { archive.removeAll() }.disabled(archive.entries.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 460, minHeight: 320)
    }

    private func open(_ entry: TabArchive.Entry) {
        let browser = Browser.recent ?? BrowserWindow.open()
        browser.reopen(entry)
        browser.window?.makeKeyAndOrderFront(nil)
    }
}

struct ArchiveRow: View {
    let entry: TabArchive.Entry

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(url: entry.url, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? entry.url : entry.title).lineLimit(1)
                Text([URL(string: entry.url)?.host(), entry.group].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(entry.archived.formatted(.relative(presentation: .named)))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .help(entry.url)
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

    var body: some View {
        let items = downloads.items(for: browser)
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
            .frame(width: Metrics.control, height: Metrics.control)
            .overlay(alignment: .topTrailing) {
                if unseen { Circle().fill(Theme.working).frame(width: 6, height: 6).padding(5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(FillStyle(resting: browser.showDownloads ? Theme.field : .clear))
        .foregroundStyle(progress != nil ? Theme.primary : Theme.secondary)
        .help("Downloads")
        .popover(isPresented: $browser.showDownloads, arrowEdge: arrowEdge) {
            DownloadList(browser: browser)
        }
        .animation(Motion.quick, value: progress == nil)
    }
}

struct DownloadList: View {
    let browser: Browser
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        let items = downloads.items(for: browser)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                Spacer()
                BarButton(symbol: "folder", help: String(localized: "Open Downloads Folder")) { NSWorkspace.shared.open(Preferences.shared.downloadFolder) }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 40)
            if items.isEmpty {
                Text("No downloads this session")
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
                    Button("Clear Finished") { downloads.clearFinished(for: browser) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                }
            }
        }
        .frame(width: 320)
        .onAppear { downloads.markSeen(for: browser) }
        .onChange(of: items.filter(\.isDone).count) { downloads.markSeen(for: browser) }
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
        let items = Array(downloads.shelf(for: browser).prefix(3))
        VStack(spacing: 0) {
            ForEach(items) { item in
                DownloadRow(item: item).transition(Motion.slide(.bottom))
            }
        }
        .padding(.horizontal, Metrics.inset)
        .animation(Motion.standard, value: items.map(\.id))
    }
}

struct DownloadRow: View {
    static let height: CGFloat = 40
    @ObservedObject var item: DownloadItem
    @State private var hover = false

    private var file: URL? { item.state == .finished ? item.destination : nil }

    var body: some View {
        HStack(spacing: Metrics.iconGap) {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .font(.row)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            Spacer(minLength: 0)
            if item.state == .running {
                HoverAction(symbol: "xmark", help: String(localized: "Cancel")) { item.cancel() }
            } else if item.resumeData != nil {
                HoverAction(symbol: "arrow.clockwise", help: String(localized: "Try Again")) { Downloads.shared.retry(item) }
            } else if hover, let file {
                HoverAction(symbol: "magnifyingglass", help: String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        }
        .padding(.leading, Metrics.rowPadding)
        .padding(.trailing, 4)
        .frame(height: Self.height)
        .rowChrome(hover: hover && file != nil)
        .onHover {
            hover = $0
            item.isHovered = $0
        }
        // A row that goes away under the pointer gets no "left": the shelf must not wait for it.
        .onDisappear { item.isHovered = false }
        .onTapGesture { open() }
        .modifier(FileDrag(file: file))
        .contextMenu {
            if let file {
                Button("Open") {
                    item.seen = true
                    NSWorkspace.shared.open(file)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            }
            if item.state == .running {
                Button("Cancel") { item.cancel() }
            }
            if item.resumeData != nil {
                Button("Try Again") { Downloads.shared.retry(item) }
            }
        }
        .help(file.map { "\($0.path)\n" + (Downloads.opensOnClick($0) ? String(localized: "Click to open it. You can drag it into another app.") : String(localized: "Click to show it in Finder. You can drag it into another app.")) } ?? item.filename)
    }

    @ViewBuilder private var detail: some View {
        switch item.state {
        case .running where !item.sizeKnown:
            Text(String(localized: "Downloading · \(ByteCountFormatter.string(fromByteCount: item.bytes ?? 0, countStyle: .file))"))
                .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondary)
        case .running:
            HStack(spacing: 6) {
                Meter(fraction: item.progress)
                Text("\(Int((item.progress * 100).rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
        case .finished:
            Text(item.bytes.map { String(localized: "Done · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))") } ?? String(localized: "Done"))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
        case .cancelled:
            Text("Cancelled").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint)
        case .failed(let reason):
            Text("Failed: \(reason)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.waitingText).lineLimit(1)
        }
    }

    private func open() {
        guard let file else { return }
        guard FileManager.default.fileExists(atPath: file.path) else { return NSSound.beep() }
        item.seen = true
        Downloads.shared.dismiss(item)
        if Downloads.opensOnClick(file) {
            NSWorkspace.shared.open(file)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
}

/// Lets a finished download be dragged into other apps; rows without a file don't start a drag.
private struct FileDrag: ViewModifier {
    let file: URL?

    func body(content: Content) -> some View {
        if let file, FileManager.default.fileExists(atPath: file.path) {
            content.onDrag { NSItemProvider(contentsOf: file) ?? NSItemProvider() }
        } else {
            content
        }
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
            TextField("Find on Page", text: $overlay.findText)
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
                Text(matches == 0 ? String(localized: "None") : matches == 1 ? String(localized: "\(matches) match") : String(localized: "\(matches) matches"))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(matches == 0 ? Theme.waitingText : Theme.secondary)
            }
            BarButton(symbol: "chevron.up", help: String(localized: "Previous (⌘⇧G)")) { browser.find(backwards: true) }.disabled(overlay.findText.isEmpty)
            BarButton(symbol: "chevron.down", help: String(localized: "Next (⌘G)")) { browser.find() }.disabled(overlay.findText.isEmpty)
            BarButton(symbol: "xmark", help: String(localized: "Close (esc)")) { browser.hideFindBar() }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 36)
        .floatingPanel(radius: Metrics.cardRadius)
        .padding(10)
        .onAppear { focused = true }
        .onChange(of: overlay.findFocusRequest) { focused = true }
        .onChange(of: overlay.findText) { browser.find() }
    }
}
