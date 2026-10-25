import AppKit
import SwiftUI

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
