import AppKit
import SwiftUI

// MARK: Downloads

/// The download button: the arrow, and the list in a popover. How the files come along is said in words: on the shelf, or, with the sidebar
/// hidden and no shelf to show it, as the share done beside the arrow.
struct DownloadButton: View {
    @ObservedObject var browser: Browser
    let arrowEdge: Edge
    /// Beside the address, where there is no shelf.
    var showsProgress = false
    @ObservedObject private var downloads = Downloads.shared

    /// "42%" while something runs; nil when nothing does.
    static func progressText(_ items: [DownloadItem]) -> String? {
        Downloads.progress(of: items).map { "\(Int(($0 * 100).rounded()))%" }
    }

    var body: some View {
        let items = downloads.items(for: browser)
        HStack(spacing: 0) {
            BarButton(symbol: "arrow.down", help: String(localized: "Downloads"),
                      value: Accessibility.downloadsValue(active: items.filter { $0.state == .running }.count) ?? "") { browser.showDownloads.toggle() }
                .popover(isPresented: $browser.showDownloads, arrowEdge: arrowEdge) {
                    DownloadList(browser: browser)
                }
            if showsProgress, let text = Self.progressText(items) {
                Text(verbatim: text).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary).decorative()
            }
        }
    }
}

struct DownloadList: View {
    let browser: Browser
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        let items = downloads.items(for: browser)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.bodyStrong).foregroundStyle(Theme.primary)
                Spacer()
                BarButton(symbol: "folder", help: String(localized: "Open Downloads Folder")) { Outside.open(Preferences.shared.downloadFolder) }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 40)
            if items.isEmpty {
                Text("No downloads this session")
                    .font(.secondary)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
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
                        .font(.secondary)
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                }
            }
        }
        .frame(width: 320)
    }

    private func rows(_ items: [DownloadItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { DownloadRow(item: $0) }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

/// Files that are coming in, at the bottom of the sidebar, each a line of words; a finished one stays until it is closed.
struct DownloadShelf: View {
    let browser: Browser
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        let items = Array(downloads.shelf(for: browser).prefix(3))
        VStack(spacing: 0) {
            ForEach(items) { item in
                DownloadRow(item: item, onShelf: true).transition(Motion.slide(.bottom))
            }
        }
        .padding(.horizontal, Metrics.inset)
        .animation(Motion.standard, value: items.map(\.id))
    }
}

struct DownloadRow: View {
    static let height: CGFloat = 40
    @ObservedObject var item: DownloadItem
    /// On the shelf: one line of words, "name · 42% · Downloading" or "name · 2.1 MB · Done", without the file's icon.
    var onShelf = false
    @State private var hover = false

    private var file: URL? { item.state == .finished ? item.destination : nil }

    /// The shelf's line: the name, how far it has come (or its size, or why it stopped), and in a word where it is.
    static func shelfLine(_ item: DownloadItem) -> String {
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        let parts: [String] = switch item.state {
        case .running where !item.sizeKnown: [item.filename, size(item.bytes ?? 0), String(localized: "Downloading")]
        case .running: [item.filename, "\(Int((item.progress * 100).rounded()))%", String(localized: "Downloading")]
        case .finished: [item.filename] + (item.bytes.map { [size($0)] } ?? []) + [String(localized: "Done")]
        case .cancelled: [item.filename, String(localized: "Cancelled")]
        case .failed(let reason): [item.filename, String(localized: "Failed: \(reason)")]
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if onShelf {
                HStack(spacing: Metrics.iconGap) {
                    Text(verbatim: Self.shelfLine(item))
                        .font(.row.monospacedDigit())
                        .foregroundStyle(failed ? Theme.waitingText : Theme.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    action
                }
                .frame(height: Metrics.row)
            } else {
                HStack(spacing: Metrics.iconGap) {
                    Group {
                        if let file {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable()
                        } else {
                            Image(systemName: item.state == .running ? "arrow.down.circle" : "exclamationmark.circle")
                                .font(.symbolEmpty)
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                    .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.filename)
                            .font(.row)
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        detail
                    }
                    Spacer(minLength: 0)
                    action
                }
                .frame(height: Self.height)
            }
        }
        .padding(.leading, Metrics.rowPadding)
        .padding(.trailing, 4)
        .rowChrome(hover: hover && file != nil)
        .onHover { hover = $0 }
        .onTapGesture { open() }
        .accessibleButton(onShelf ? Self.shelfLine(item) : item.filename, value: onShelf ? nil : downloadValue, actions: downloadActions) { open() }
        .modifier(FileDrag(file: file))
        .contextMenu {
            if let file {
                Button("Open") { Outside.open(file) }
                Button("Show in Finder") { Outside.reveal([file]) }
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

    private var failed: Bool {
        if case .failed = item.state { true } else { false }
    }

    /// Cancel while it runs, Try Again when it broke off; under the pointer, on the shelf a finished or failed row's × and in the list Show in Finder.
    @ViewBuilder private var action: some View {
        if item.state == .running {
            HoverAction(symbol: "xmark", help: String(localized: "Cancel")) { item.cancel() }
        } else if item.resumeData != nil {
            HoverAction(symbol: "arrow.clockwise", help: String(localized: "Try Again")) { Downloads.shared.retry(item) }
            // Closed on the shelf, it stays in the list, where Try Again still is.
            if hover, onShelf { HoverAction(symbol: "xmark", help: String(localized: "Close")) { Downloads.shared.dismiss(item) } }
        } else if hover, onShelf {
            HoverAction(symbol: "xmark", help: String(localized: "Close")) { Downloads.shared.dismiss(item) }
        } else if hover, let file {
            HoverAction(symbol: "magnifyingglass", help: String(localized: "Show in Finder")) { Outside.reveal([file]) }
        }
    }

    /// How far it has come, or why it stopped.
    private var downloadValue: String? {
        switch item.state {
        case .running: Accessibility.percentValue(item.progress)
        case .failed(let message): message
        case .finished, .cancelled: nil
        }
    }

    private var downloadActions: [AccessibleButton.Action] {
        var actions: [AccessibleButton.Action] = []
        if item.state == .running { actions.append(.init(String(localized: "Cancel")) { item.cancel() }) }
        if item.resumeData != nil { actions.append(.init(String(localized: "Try Again")) { Downloads.shared.retry(item) }) }
        if let file { actions.append(.init(String(localized: "Show in Finder")) { Outside.reveal([file]) }) }
        if onShelf, item.isDone { actions.append(.init(String(localized: "Close")) { Downloads.shared.dismiss(item) }) }
        return actions
    }

    @ViewBuilder private var detail: some View {
        switch item.state {
        case .running where !item.sizeKnown:
            Text(String(localized: "Downloading · \(ByteCountFormatter.string(fromByteCount: item.bytes ?? 0, countStyle: .file))"))
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
        case .running:
            HStack(spacing: 8) {
                Meter(fraction: item.progress)
                Text("\(Int((item.progress * 100).rounded()))%")
                    .font(.captionStrong.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
        case .finished:
            Text(item.bytes.map { String(localized: "Done · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))") } ?? String(localized: "Done"))
                .font(.caption).foregroundStyle(Theme.secondary)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(Theme.secondary)
        case .failed(let reason):
            Text("Failed: \(reason)").font(.caption).foregroundStyle(Theme.waitingText).lineLimit(1)
        }
    }

    private func open() {
        guard let file else { return }
        guard FileManager.default.fileExists(atPath: file.path) else { return NSSound.beep() }
        if Downloads.opensOnClick(file) {
            Outside.open(file)
        } else {
            Outside.reveal([file])
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
