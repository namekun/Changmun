import AppKit
import Combine
import WebKit

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case running, finished, failed(String), cancelled
    }

    let id = UUID()
    let started = Date()
    /// From a private window: only private windows list it.
    let isPrivate: Bool
    @Published var filename: String
    @Published var destination: URL?
    @Published var progress: Double = 0
    @Published var state: State = .running
    /// Finished while nobody was looking: the download button wears a dot until the list is opened.
    @Published var seen = false
    @Published var bytes: Int64?
    weak var download: WKDownload?
    private var observation: NSKeyValueObservation?

    convenience init(_ download: WKDownload, isPrivate: Bool) {
        self.init(filename: download.originalRequest?.url?.lastPathComponent ?? "다운로드", progress: download.progress, isPrivate: isPrivate)
        self.download = download
    }

    init(filename: String, progress: Progress, isPrivate: Bool) {
        self.isPrivate = isPrivate
        self.filename = filename
        observation = progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in
                guard let self, value - self.progress >= 0.01 || value >= 1 else { return }
                self.progress = value
            }
        }
    }

    var isDone: Bool { state != .running }
}

/// Downloads in this session, saved to the folder chosen in Settings (or wherever the user picks each time).
@MainActor
final class Downloads: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = Downloads()

    @Published private(set) var items: [DownloadItem] = []
    /// Shown at the bottom of the sidebar: running downloads, and finished ones for a few seconds after.
    @Published private(set) var shelf: [DownloadItem] = []
    static let shelfTime: Duration = .seconds(8)
    private var relays: [UUID: AnyCancellable] = [:]

    func track(_ download: WKDownload, isPrivate: Bool) {
        download.delegate = self
        add(DownloadItem(download, isPrivate: isPrivate))
    }

    func add(_ item: DownloadItem) {
        relays[item.id] = item.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        items.insert(item, at: 0)
        shelf.insert(item, at: 0)
    }

    func items(isPrivate: Bool) -> [DownloadItem] {
        items.filter { $0.isPrivate == isPrivate }
    }

    func shelf(isPrivate: Bool) -> [DownloadItem] {
        shelf.filter { $0.isPrivate == isPrivate }
    }

    /// The share done of the running downloads, or nil when none is running.
    static func progress(of items: [DownloadItem]) -> Double? {
        let running = items.filter { !$0.isDone }
        guard !running.isEmpty else { return nil }
        return running.map(\.progress).reduce(0, +) / Double(running.count)
    }

    func markSeen(isPrivate: Bool) {
        for item in items(isPrivate: isPrivate) where item.isDone && !item.seen { item.seen = true }
    }

    func dismiss(_ item: DownloadItem) {
        shelf.removeAll { $0 === item }
    }

    func clearFinished() {
        items.removeAll { $0.isDone }
        shelf.removeAll { $0.isDone }
        relays = relays.filter { id, _ in items.contains { $0.id == id } }
    }

    private func settle(_ item: DownloadItem?) {
        guard let item else { return }
        Task {
            try? await Task.sleep(for: Self.shelfTime)
            dismiss(item)
        }
    }

    private func item(_ download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    static func uniqueURL(in folder: URL, for filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(filename)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            n += 1
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        return candidate
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let item = item(download)
        item?.filename = suggestedFilename
        let prefs = Preferences.shared
        var destination: URL
        if prefs.askWhereToSave {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            panel.directoryURL = prefs.downloadFolder
            guard panel.runModal() == .OK, let chosen = panel.url else {
                item?.state = .cancelled
                item.map(dismiss)
                return nil
            }
            try? FileManager.default.removeItem(at: chosen)
            destination = chosen
        } else {
            destination = Self.uniqueURL(in: prefs.downloadFolder, for: suggestedFilename)
        }
        item?.filename = destination.lastPathComponent
        item?.destination = destination
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        item(download)?.progress = 1
        item(download)?.bytes = download.progress.completedUnitCount
        item(download)?.state = .finished
        settle(item(download))
        NSSound(named: "Glass")?.play()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        guard let item = item(download) else { return }
        item.state = cancelled ? .cancelled : .failed(error.localizedDescription)
        if cancelled { dismiss(item) } else { settle(item) }
    }
}
