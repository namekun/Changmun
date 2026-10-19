import AppKit
import Combine
import UniformTypeIdentifiers
import WebKit

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case running, finished, failed(String), cancelled
    }

    let id = UUID()
    let started = Date()
    let isPrivate: Bool
    /// The private window it came from: only that window lists it, and closing the window forgets it.
    weak var owner: Browser?
    /// The profile space it came from, so a resumed download uses the same cookies.
    var space: Space?
    @Published var filename: String
    @Published var destination: URL?
    @Published var progress: Double = 0
    @Published var state: State = .running
    /// Finished while nobody was looking: the download button wears a dot until the list is opened.
    @Published var seen = false
    /// Bytes so far while running (shown when the size isn't known), the file size once finished.
    @Published var bytes: Int64?
    @Published var sizeKnown = true
    /// Under the pointer on the shelf: it stays there until the pointer leaves.
    var isHovered = false
    weak var download: WKDownload?
    /// What WebKit kept of a download that broke off, to pick it up from there.
    var resumeData: Data?
    /// Where it came from and goes, kept for a resumed download's quarantine.
    var origin: (file: URL?, page: URL?, destination: URL?)?
    private var observation: NSKeyValueObservation?

    convenience init(_ download: WKDownload, owner: Browser?) {
        self.init(filename: download.originalRequest?.url?.lastPathComponent ?? String(localized: "Download"), progress: download.progress, isPrivate: owner?.isPrivate == true)
        self.download = download
        if isPrivate { self.owner = owner }
    }

    init(filename: String, progress: Progress, isPrivate: Bool) {
        self.isPrivate = isPrivate
        self.filename = filename
        watch(progress)
    }

    func watch(_ progress: Progress) {
        observation = progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted, done = progress.completedUnitCount, known = progress.totalUnitCount > 0
            Task { @MainActor in self?.update(fraction: fraction, bytes: done, sizeKnown: known) }
        }
    }

    /// Redraws on a 1% step (or 256 KB when the size is unknown), not on every packet.
    func update(fraction: Double, bytes done: Int64, sizeKnown known: Bool) {
        guard state == .running else { return }
        if known != sizeKnown { sizeKnown = known }
        if known {
            if abs(fraction - progress) >= 0.01 || fraction >= 1 { progress = fraction }
        } else if done - (bytes ?? 0) >= 256 << 10 {
            bytes = done
        }
    }

    var isDone: Bool { state != .running }

    func cancel() {
        if let download {
            download.cancel { _ in }
        } else {
            state = .cancelled
            Downloads.shared.dismiss(self)
        }
    }
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
    /// Where each download came from and goes, kept apart from the list so a forgotten item still gets quarantined.
    private var origins: [ObjectIdentifier: (file: URL?, page: URL?, destination: URL?)] = [:]

    func track(_ download: WKDownload, from tab: Tab) {
        download.delegate = self
        let owner = tab.browser
        origins[ObjectIdentifier(download)] = tab.isPrivate ? (nil, nil, nil) : (download.originalRequest?.url, download.webView?.url, nil)
        let item = DownloadItem(download, owner: tab.isPrivate ? owner : nil)
        item.space = Self.spaceToKeep(for: tab)
        add(item)
    }

    func add(_ item: DownloadItem) {
        relays[item.id] = item.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        items.insert(item, at: 0)
        shelf.insert(item, at: 0)
    }

    func items(for browser: Browser) -> [DownloadItem] {
        items.filter { Self.belongs($0, to: browser) }
    }

    func shelf(for browser: Browser) -> [DownloadItem] {
        shelf.filter { Self.belongs($0, to: browser) }
    }

    static func belongs(_ item: DownloadItem, to browser: Browser) -> Bool {
        browser.isPrivate ? item.owner === browser : !item.isPrivate
    }

    /// A private window closed: its downloads leave the list (the files stay where they were saved).
    func forget(_ browser: Browser) {
        remove { $0.isPrivate && ($0.owner == nil || $0.owner === browser) }
    }

    /// The share done of the running downloads, or nil when none is running.
    static func progress(of items: [DownloadItem]) -> Double? {
        let running = items.filter { !$0.isDone }
        guard !running.isEmpty else { return nil }
        return running.map(\.progress).reduce(0, +) / Double(running.count)
    }

    func markSeen(for browser: Browser) {
        for item in items(for: browser) where item.isDone && !item.seen { item.seen = true }
    }

    func dismiss(_ item: DownloadItem) {
        shelf.removeAll { $0 === item }
    }

    func clearFinished(for browser: Browser) {
        remove { $0.isDone && Self.belongs($0, to: browser) }
    }

    private func remove(where match: (DownloadItem) -> Bool) {
        items.removeAll(where: match)
        shelf.removeAll(where: match)
        relays = relays.filter { id, _ in items.contains { $0.id == id } }
    }

    private func settle(_ item: DownloadItem?) {
        guard let item else { return }
        Task {
            try? await Task.sleep(for: Self.shelfTime)
            while item.isHovered { try? await Task.sleep(for: .seconds(1)) }
            // Picked up again meanwhile (Try Again): it stays while it runs.
            if item.isDone { dismiss(item) }
        }
    }

    /// Marks a downloaded file the way Safari does, so Gatekeeper checks it before it first runs.
    static func quarantine(_ file: URL, from source: URL?, page: URL?) {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Changmun",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let source { properties[kLSQuarantineDataURLKey as String] = source }
        if let page { properties[kLSQuarantineOriginURLKey as String] = page }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var url = file
        try? url.setResourceValues(values)
    }

    /// Apps, scripts and installers are shown in Finder on a click instead of being opened.
    static func opensOnClick(_ file: URL) -> Bool {
        let type = (try? file.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: file.pathExtension)
        let risky: [UTType] = [.executable, .script, .application, .applicationBundle, .shellScript]
            + ["com.apple.installer-package-archive", "com.sun.java-archive"].compactMap { UTType($0) }
        if let type, risky.contains(where: type.conforms) { return false }
        // Automator workflows and Terminal settings run commands but have no registered type without their apps.
        if ["workflow", "action", "terminal"].contains(file.pathExtension.lowercased()) { return false }
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder)
        return !(exists && !isFolder.boolValue && FileManager.default.isExecutableFile(atPath: file.path))
    }

    private func item(_ download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    static var folder: URL {
        guard Headless.isOn else { return Preferences.shared.downloadFolder }
        let url = Library.folder.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
        if prefs.askWhereToSave && !Headless.isOn {
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
            destination = Self.uniqueURL(in: Self.folder, for: suggestedFilename)
        }
        item?.filename = destination.lastPathComponent
        item?.destination = destination
        origins[ObjectIdentifier(download)]?.destination = destination
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let origin = origins.removeValue(forKey: ObjectIdentifier(download)), let destination = origin.destination {
            Self.quarantine(destination, from: origin.file, page: origin.page)
        }
        item(download)?.progress = 1
        item(download)?.bytes = download.progress.completedUnitCount
        item(download)?.state = .finished
        if let id = item(download)?.id { resumers[id] = nil }
        settle(item(download))
        if !Headless.isOn { NSSound(named: "Glass")?.play() }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let origin = origins.removeValue(forKey: ObjectIdentifier(download))
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        guard let item = item(download) else { return }
        resumers[item.id] = nil
        item.state = cancelled ? .cancelled : .failed(error.localizedDescription)
        if !cancelled {
            item.resumeData = resumeData
            item.origin = origin
        }
        if cancelled { dismiss(item) } else { settle(item) }
    }

    /// Web views that picked up a broken-off download, kept until it ends.
    private var resumers: [UUID: WKWebView] = [:]

    /// A private window's download never has a space: it resumes in that window's own non-persistent store.
    static func spaceToKeep(for tab: Tab) -> Space? {
        tab.isPrivate ? nil : tab.browser?.spaces.space(tab.spaceID)
    }

    /// A private download resumes in its window's configuration; any other in the default one, or its profile's if that
    /// space still exists (a deleted profile's store is never made again).
    static func resumeConfiguration(for item: DownloadItem, spaces: SpaceStore? = nil) -> WKWebViewConfiguration {
        if item.isPrivate, let owner = item.owner { return owner.configuration }
        let spaces = spaces ?? .shared
        guard !item.isPrivate, let space = item.space, spaces.contains(space.id) else { return Browser.configuration }
        return Profiles.configuration(for: spaces.space(space.id), base: Browser.configuration)
    }

    /// Picks a download that broke off up again from where it stopped.
    func retry(_ item: DownloadItem) {
        guard let data = item.resumeData, !item.isPrivate || item.owner != nil else { return }
        item.resumeData = nil
        let webView = WKWebView(frame: .zero, configuration: Self.resumeConfiguration(for: item))
        resumers[item.id] = webView
        Task {
            let download = await webView.resumeDownload(fromResumeData: data)
            download.delegate = self
            origins[ObjectIdentifier(download)] = item.origin ?? (nil, nil, nil)
            item.download = download
            item.state = .running
            item.watch(download.progress)
            if !shelf.contains(where: { $0 === item }) { shelf.insert(item, at: 0) }
        }
    }
}
