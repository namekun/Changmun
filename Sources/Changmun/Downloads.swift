import AppKit
import WebKit

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case running, finished, failed(String), cancelled
    }

    let id = UUID()
    let started = Date()
    @Published var filename: String
    @Published var destination: URL?
    @Published var progress: Double = 0
    @Published var state: State = .running
    weak var download: WKDownload?
    private var observation: NSKeyValueObservation?

    init(_ download: WKDownload) {
        self.download = download
        filename = download.originalRequest?.url?.lastPathComponent ?? "다운로드"
        observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in self?.progress = value }
        }
    }
}

/// Downloads in this session, saved to the folder chosen in Settings (or wherever the user picks each time).
@MainActor
final class Downloads: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = Downloads()

    @Published private(set) var items: [DownloadItem] = []

    func track(_ download: WKDownload) {
        download.delegate = self
        items.insert(DownloadItem(download), at: 0)
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
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
        item(download)?.state = .finished
        NSSound(named: "Glass")?.play()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        item(download)?.state = cancelled ? .cancelled : .failed(error.localizedDescription)
    }
}
