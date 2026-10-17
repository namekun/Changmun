import AppKit
import WebKit

enum CommandBarMode: Equatable {
    case newTab
    case editCurrent
}

/// The window's tabs, which one is shown, and the panels around it.
@MainActor
final class Browser: ObservableObject {
    static let shared = Browser()

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeID: Int?
    @Published var showChat = false
    @Published var showSidebar = UserDefaults.standard.object(forKey: "showSidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSidebar, forKey: "showSidebar") }
    }
    @Published var commandBar: CommandBarMode?
    @Published var showOnboarding = false
    /// Bumped to put the cursor in the address bar on top (⌘L).
    @Published var addressFocusRequest = 0
    var favicons: [String: NSImage] = [:]
    private var missingIcons = Set<String>()
    private var nextID = 1
    private var sleepTimer: Timer?
    private var memoryPressure: DispatchSourceMemoryPressure?

    /// Background tabs not shown for this long give up their web process.
    var sleepAfter: TimeInterval {
        let minutes = UserDefaults.standard.double(forKey: "sleepTabsAfterMinutes")
        return (minutes > 0 ? minutes : 20) * 60
    }

    static let configuration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
        config.mediaTypesRequiringUserActionForPlayback = .audio
        // Lets the Web Inspector open inside the app (F12, "Inspect Element"); private, so only when WebKit has it.
        if config.preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        return config
    }()

    private static var safariVersion: String {
        let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        return info?["CFBundleShortVersionString"] as? String ?? "18.0"
    }

    var active: Tab? { tabs.first { $0.id == activeID } }

    func tab(_ id: Int?) -> Tab? {
        guard let id else { return active }
        return tabs.first { $0.id == id }
    }

    // MARK: Tabs

    @discardableResult
    func openTab(url: URL?, activate: Bool = true, after: Tab? = nil) -> Tab {
        let tab = Tab(id: takeID(), url: url, browser: self)
        insert(tab, after: after)
        if activate {
            self.activate(tab.id)
            commandBar = nil
        }
        return tab
    }

    func openTab(configuration: WKWebViewConfiguration, after: Tab?) -> Tab {
        let tab = Tab(id: takeID(), configuration: configuration, browser: self)
        insert(tab, after: after)
        activate(tab.id)
        return tab
    }

    func activate(_ id: Int) {
        guard let tab = tab(id) else { return }
        active?.lastShown = Date()
        activeID = id
        tab.lastShown = Date()
        tab.wake()
    }

    func close(_ id: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs.remove(at: index)
        closing.sleep()
        if activeID == id {
            if tabs.isEmpty {
                activeID = nil
                commandBar = .newTab
            } else {
                activate(tabs[min(index, tabs.count - 1)].id)
            }
        }
    }

    func selectTab(offset: Int) {
        guard let current = tabs.firstIndex(where: { $0.id == activeID }), !tabs.isEmpty else { return }
        activate(tabs[(current + offset + tabs.count) % tabs.count].id)
    }

    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        activate(number >= 9 ? tabs[tabs.count - 1].id : tabs[min(number - 1, tabs.count - 1)].id)
    }

    func open(_ input: String, in mode: CommandBarMode) {
        guard let url = AddressInput.resolve(input) else { return }
        if mode == .editCurrent, let active { active.load(url) } else { openTab(url: url) }
        commandBar = nil
    }

    /// Shows the tab already on that page, or opens one.
    func openBookmark(_ address: String) {
        if let open = tabs.first(where: { $0.url?.absoluteString == address }) {
            activate(open.id)
        } else if let url = URL(string: address) {
            openTab(url: url, after: active)
        }
    }

    // MARK: Icons

    private var iconFolder: URL {
        let url = Library.folder.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A site's icon for a page that may not be open, cached on disk by host.
    func icon(for address: String) async -> NSImage? {
        guard let url = URL(string: address), let host = url.host(), let scheme = url.scheme, scheme.hasPrefix("http") else { return nil }
        if let cached = favicons[host] { return cached }
        if missingIcons.contains(host) { return nil }
        let file = iconFolder.appendingPathComponent(host + ".png")
        if let image = NSImage(contentsOf: file) {
            favicons[host] = image
            return image
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = url.host(percentEncoded: true)
        components.port = url.port
        components.path = "/favicon.ico"
        missingIcons.insert(host)
        guard let iconURL = components.url,
              let (data, response) = try? await URLSession.shared.data(from: iconURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data), image.isValid else { return nil }
        missingIcons.remove(host)
        favicons[host] = image
        storeIcon(image, host: host)
        return image
    }

    func storeIcon(_ image: NSImage, host: String) {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: iconFolder.appendingPathComponent(host + ".png"))
    }

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func insert(_ tab: Tab, after: Tab?) {
        if let after, let index = tabs.firstIndex(where: { $0 === after }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
    }

    // MARK: Memory

    func startSleepingIdleTabs() {
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sleepIdleTabs(olderThan: self?.sleepAfter ?? 1200) }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.sleepIdleTabs(olderThan: 0) }
        }
        source.resume()
        memoryPressure = source
    }

    func sleepIdleTabs(olderThan age: TimeInterval) {
        let now = Date()
        for tab in tabs where tab.id != activeID && now.timeIntervalSince(tab.lastShown) >= age {
            guard let webView = tab.webView, webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none else { continue }
            webView.requestMediaPlaybackState { [weak self, weak tab] state in
                Task { @MainActor in
                    guard let self, let tab, tab.id != self.activeID, state != .playing else { return }
                    tab.sleep()
                }
            }
        }
    }

    // MARK: Session

    private struct SavedTab: Codable {
        var url: String?
        var title: String
        var state: Data?
    }

    private struct SavedSession: Codable {
        var tabs: [SavedTab]
        var active: Int?
    }

    private var sessionFile: URL { Library.folder.appendingPathComponent("session.json") }

    func saveSession() {
        let saved = SavedSession(
            tabs: tabs.map { SavedTab(url: $0.url?.absoluteString, title: $0.title, state: $0.sessionState) },
            active: tabs.firstIndex { $0.id == activeID }
        )
        try? JSONEncoder().encode(saved).write(to: sessionFile, options: .atomic)
    }

    /// Restores the last session asleep, apart from the tab that was shown.
    func restoreSession() {
        guard let data = try? Data(contentsOf: sessionFile),
              let saved = try? JSONDecoder().decode(SavedSession.self, from: data),
              !saved.tabs.isEmpty else {
            commandBar = .newTab
            return
        }
        for item in saved.tabs {
            tabs.append(Tab(id: takeID(), url: item.url.flatMap(URL.init(string:)), title: item.title, state: item.state, browser: self))
        }
        activate(tabs[min(saved.active ?? 0, tabs.count - 1)].id)
    }
}
