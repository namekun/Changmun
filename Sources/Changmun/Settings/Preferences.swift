import AppKit
import SwiftUI

enum ShortcutScheme: String, CaseIterable, Identifiable {
    case safari
    case chrome

    var id: String { rawValue }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, naver, duckDuckGo, bing

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: "Google"
        case .naver: String(localized: "Naver")
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        }
    }

    var template: String {
        switch self {
        case .google: "https://www.google.com/search?q=%s"
        case .naver: "https://search.naver.com/search.naver?query=%s"
        case .duckDuckGo: "https://duckduckgo.com/?q=%s"
        case .bing: "https://www.bing.com/search?q=%s"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Every setting, stored in UserDefaults under the keys the rest of the app reads.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    // MARK: General

    @Published var searchEngine: SearchEngine {
        didSet { defaults.set(searchEngine.template, forKey: "searchURL") }
    }
    /// Sends what is typed in the command bar to the search engine for suggestions (never from a private window).
    @Published var searchSuggestions: Bool { didSet { defaults.set(searchSuggestions, forKey: "searchSuggestions") } }
    @Published var restoreTabs: Bool { didSet { defaults.set(restoreTabs, forKey: "restoreTabs") } }
    @Published var downloadFolder: URL { didSet { defaults.set(downloadFolder.path, forKey: "downloadFolder") } }
    @Published var askWhereToSave: Bool { didSet { defaults.set(askWhereToSave, forKey: "askWhereToSave") } }
    /// Closing the last window ends the app (as it always has); off, the app stays open with no window, like Safari.
    @Published var quitWhenLastWindowCloses: Bool { didSet { defaults.set(quitWhenLastWindowCloses, forKey: "quitWhenLastWindowCloses") } }

    // MARK: Tabs and looks

    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            NSApp?.appearance = appearance.nsAppearance
        }
    }
    @Published var sidebarWidth: Double { didSet { defaults.set(sidebarWidth, forKey: "sidebarWidth") } }
    @Published var defaultZoom: Double { didSet { defaults.set(defaultZoom, forKey: "defaultZoom") } }
    /// Sites zoomed to something other than the default, by host.
    @Published var siteZoom: [String: Double] { didSet { defaults.set(siteZoom, forKey: "siteZoom") } }
    /// Sites never to offer saving a password for.
    @Published var neverSaveLoginHosts: [String] { didSet { defaults.set(neverSaveLoginHosts, forKey: "neverSaveLoginHosts") } }
    /// Sites whose own popups open as tabs instead of being blocked.
    @Published var popupHosts: [String] { didSet { defaults.set(popupHosts, forKey: "popupHosts") } }

    func allowsPopups(from host: String?) -> Bool { Self.matches(host, popupHosts) }

    func allowPopups(from host: String) { popupHosts = Self.adding(host, to: popupHosts) }

    /// The list with the host's site on it: lower case, without "www."; never an empty one.
    nonisolated static func adding(_ host: String, to sites: [String]) -> [String] {
        let site = (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host).lowercased()
        return site.isEmpty || sites.contains(site) ? sites : sites + [site]
    }

    /// The list without the host, or any site above it that covers it.
    nonisolated static func removing(_ host: String, from sites: [String]) -> [String] {
        let host = host.lowercased()
        return sites.filter { host != $0 && !host.hasSuffix("." + $0) }
    }

    /// The host is one of the sites, or under one of them.
    nonisolated static func matches(_ host: String?, _ sites: [String]) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return sites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func zoom(for host: String?) -> Double {
        host.flatMap { siteZoom[$0.lowercased()] } ?? defaultZoom
    }

    func setZoom(_ zoom: Double, for host: String) {
        siteZoom[host.lowercased()] = abs(zoom - defaultZoom) < 0.01 ? nil : zoom
    }
    /// Minutes before a background tab sleeps; 0 never.
    @Published var sleepMinutes: Int { didSet { defaults.set(sleepMinutes, forKey: "sleepTabsAfterMinutes") } }
    @Published var neverSleepHosts: [String] { didSet { defaults.set(neverSleepHosts, forKey: "neverSleepHosts") } }
    /// Hours before a tab not looked at is archived; 0 never.
    @Published var archiveHours: Int { didSet { defaults.set(archiveHours, forKey: "archiveTabsAfterHours") } }

    // MARK: Privacy

    @Published var blockTrackers: Bool {
        didSet {
            defaults.set(blockTrackers, forKey: "blockTrackers")
            Task { await AdBlocker.shared.apply(enabled: blockTrackers) }
        }
    }
    /// Keeps the sign-ins that sites meant to end when the browser closes (session cookies), in an encrypted file, until this is turned off.
    @Published var keepSessionCookies: Bool {
        didSet {
            defaults.set(keepSessionCookies, forKey: "keepSessionCookies")
            CookieJournal.shared.setEnabled(keepSessionCookies)
        }
    }
    /// Takes known tracking parameters out of an address before the page loads (see TrackingParameters); default on.
    @Published var removeTrackingFromLinks: Bool { didSet { defaults.set(removeTrackingFromLinks, forKey: "removeTrackingFromLinks") } }
    /// Tries an http address over https first, and goes back to http only when the site isn't there over https (see HTTPSFirst); default on.
    @Published var preferSecureConnections: Bool { didSet { defaults.set(preferSecureConnections, forKey: "preferSecureConnections") } }
    /// Sites whose addresses keep their tracking parameters (the site settings' switch).
    @Published var trackingKeptHosts: [String] { didSet { defaults.set(trackingKeptHosts, forKey: "trackingKeptHosts") } }
    /// Filling a saved password asks for Touch ID or the Mac's password first.
    @Published var requireAuthToFill: Bool { didSet { defaults.set(requireAuthToFill, forKey: "requireAuthToFill") } }
    @Published var customFilterLists: [String] { didSet { defaults.set(customFilterLists, forKey: "customFilterLists") } }
    @Published var disabledFilterLists: [String] { didSet { defaults.set(disabledFilterLists, forKey: "disabledFilterLists") } }
    /// Sites where ads aren't blocked.
    @Published var adBlockAllowlist: [String] { didSet { defaults.set(adBlockAllowlist, forKey: "adBlockAllowlist") } }

    // MARK: Extensions

    @Published var extensionFolders: [String] { didSet { defaults.set(extensionFolders, forKey: "extensionFolders") } }
    /// Safari content blockers whose rules Changmun applies, by bundle id.
    @Published var enabledContentBlockers: [String] { didSet { defaults.set(enabledContentBlockers, forKey: "enabledContentBlockers") } }
    @Published var enabledExtensions: [String] { didSet { defaults.set(enabledExtensions, forKey: "enabledExtensions") } }
    /// Per extension path, the permissions and match patterns the user approved.
    @Published var extensionGrants: [String: [String]] { didSet { defaults.set(extensionGrants, forKey: "extensionGrants") } }

    // MARK: AI

    @Published var aiModel: String { didSet { defaults.set(aiModel, forKey: "aiModel") } }
    /// How wide the AI panel is, dragged from its left edge.
    @Published var aiPanelWidth: Double { didSet { defaults.set(aiPanelWidth, forKey: "aiPanelWidth") } }
    /// How much the AI asks before it acts (default: after reading other sites). "aiApprovals", the on/off switch it replaces, is still
    /// written (on for the first two) so that an older version reads it right.
    @Published var aiApprovalMode: AIApprovalMode {
        didSet {
            defaults.set(aiApprovalMode.rawValue, forKey: "aiApprovalMode")
            defaults.set(aiApprovalMode != .irreversibleOnly, forKey: "aiApprovals")
        }
    }
    /// Whether the AI asks about other tabs, new addresses and the use of a page at all (any mode but the last). Setting it on from
    /// the last mode picks the default mode.
    var aiApprovals: Bool {
        get { aiApprovalMode != .irreversibleOnly }
        set { if newValue != aiApprovals { aiApprovalMode = newValue ? .afterReading : .irreversibleOnly } }
    }
    /// The effort the AI works with (`--effort`): one of `AIEffort`, or empty to leave it to `claude` as before.
    @Published var aiEffort: String { didSet { defaults.set(aiEffort.isEmpty ? nil : aiEffort, forKey: "aiEffort") } }
    /// Whether the AI panel keeps finished chats to read again (default on); private windows never are.
    @Published var aiKeepHistory: Bool { didSet { defaults.set(aiKeepHistory, forKey: "aiKeepHistory") } }
    @Published var claudePath: String { didSet { defaults.set(claudePath.isEmpty ? nil : claudePath, forKey: "claudePath") } }

    // MARK: Translation

    /// Who translates pages: this Mac (the default), or Claude, which is sent the page's text.
    @Published var translationEngine: TranslationEngine { didSet { defaults.set(translationEngine.rawValue, forKey: "translationEngine") } }
    /// The model Claude translates with (`--model`).
    @Published var translationModel: String { didSet { defaults.set(translationModel, forKey: "translationModel") } }
    /// Sites whose pages are translated as they open, and whose new text is translated too (the site settings' switch). Each is one
    /// host: `mail.example.com` is not `example.com`, and only "www." counts as the same host.
    @Published var translatedHosts: [String] { didSet { defaults.set(translatedHosts, forKey: "translatedHosts") } }

    func keepsTranslating(_ host: String?) -> Bool { Self.matchesExactly(host, translatedHosts) }

    /// The host in lower case without "www.": what a site is called in the lists that go by one host.
    nonisolated static func siteKey(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The host is one of the sites, with or without "www.", and no other host under them or above them.
    nonisolated static func matchesExactly(_ host: String?, _ sites: [String]) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let key = siteKey(host)
        return sites.contains { siteKey($0) == key }
    }

    /// The list without that host (and its "www." form), and without any other.
    nonisolated static func removingExactly(_ host: String, from sites: [String]) -> [String] {
        let key = siteKey(host)
        return sites.filter { siteKey($0) != key }
    }

    // MARK: Advanced

    @Published var developerMode: Bool { didSet { defaults.set(developerMode, forKey: "developerMode") } }
    @Published var shortcuts: ShortcutScheme { didSet { defaults.set(shortcuts.rawValue, forKey: "shortcuts") } }

    private init() {
        let d = UserDefaults.standard
        let template = d.string(forKey: "searchURL")
        searchEngine = SearchEngine.allCases.first { $0.template == template } ?? .google
        searchSuggestions = d.object(forKey: "searchSuggestions") as? Bool ?? true
        restoreTabs = d.object(forKey: "restoreTabs") as? Bool ?? true
        downloadFolder = d.string(forKey: "downloadFolder").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        askWhereToSave = d.bool(forKey: "askWhereToSave")
        quitWhenLastWindowCloses = d.object(forKey: "quitWhenLastWindowCloses") as? Bool ?? true
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        sidebarWidth = Self.clampedSidebarWidth(d.object(forKey: "sidebarWidth") as? Double ?? Self.defaultSidebarWidth)
        defaultZoom = d.object(forKey: "defaultZoom") as? Double ?? 1
        siteZoom = d.dictionary(forKey: "siteZoom") as? [String: Double] ?? [:]
        neverSaveLoginHosts = d.stringArray(forKey: "neverSaveLoginHosts") ?? []
        popupHosts = d.stringArray(forKey: "popupHosts") ?? []
        sleepMinutes = d.object(forKey: "sleepTabsAfterMinutes") as? Int ?? 20
        neverSleepHosts = d.stringArray(forKey: "neverSleepHosts") ?? []
        archiveHours = d.object(forKey: "archiveTabsAfterHours") as? Int ?? 0
        blockTrackers = d.object(forKey: "blockTrackers") as? Bool ?? true
        keepSessionCookies = CookieJournal.storedSetting()
        requireAuthToFill = d.object(forKey: "requireAuthToFill") as? Bool ?? true
        removeTrackingFromLinks = Self.privacySwitch(d.object(forKey: "removeTrackingFromLinks"))
        preferSecureConnections = Self.privacySwitch(d.object(forKey: "preferSecureConnections"))
        trackingKeptHosts = d.stringArray(forKey: "trackingKeptHosts") ?? []
        customFilterLists = d.stringArray(forKey: "customFilterLists") ?? []
        disabledFilterLists = d.stringArray(forKey: "disabledFilterLists") ?? []
        adBlockAllowlist = d.stringArray(forKey: "adBlockAllowlist") ?? []
        extensionFolders = d.stringArray(forKey: "extensionFolders") ?? []
        enabledContentBlockers = d.stringArray(forKey: "enabledContentBlockers") ?? []
        enabledExtensions = d.stringArray(forKey: "enabledExtensions") ?? []
        extensionGrants = d.dictionary(forKey: "extensionGrants") as? [String: [String]] ?? [:]
        aiModel = d.string(forKey: "aiModel") ?? "sonnet"
        aiPanelWidth = Self.clampedAIPanelWidth(d.object(forKey: "aiPanelWidth") as? Double ?? Self.defaultAIPanelWidth)
        aiApprovalMode = AIApprovalMode.initial(stored: d.object(forKey: "aiApprovalMode"), legacy: d.object(forKey: "aiApprovals") as? Bool)
        aiEffort = d.string(forKey: "aiEffort") ?? ""
        aiKeepHistory = d.object(forKey: "aiKeepHistory") as? Bool ?? true
        claudePath = d.string(forKey: "claudePath") ?? ""
        translationEngine = TranslationEngine.initial(stored: d.string(forKey: "translationEngine"))
        translationModel = TranslationEngine.model(stored: d.string(forKey: "translationModel"))
        translatedHosts = d.stringArray(forKey: "translatedHosts") ?? []
        developerMode = d.bool(forKey: "developerMode")
        shortcuts = ShortcutScheme(rawValue: d.string(forKey: "shortcuts") ?? "") ?? .safari
    }

    /// A privacy switch that is on until the user turns it off: nothing stored (everyone who had the app before it), or a value of another kind, is on.
    nonisolated static func privacySwitch(_ stored: Any?) -> Bool { stored as? Bool ?? true }

    static let defaultSidebarWidth = 252.0
    static let sidebarWidths = 200.0...420.0

    nonisolated static func clampedSidebarWidth(_ width: Double) -> Double {
        min(max(width, 200), 420)
    }

    static let defaultAIPanelWidth = 360.0
    static let aiPanelWidths = 300.0...560.0

    nonisolated static func clampedAIPanelWidth(_ width: Double) -> Double {
        min(max(width, 300), 560)
    }

    /// The panel's width as chosen, but never so wide that the page beside it (within `available`, both together) gets less than 320.
    nonisolated static func aiPanelWidth(_ chosen: Double, available: Double) -> Double {
        max(300, min(clampedAIPanelWidth(chosen), available - 320))
    }

    /// Whether a background tab on this host may give up its web process.
    nonisolated static func canSleep(host: String?, neverSleep: [String]) -> Bool {
        guard let host = host?.lowercased() else { return true }
        return !neverSleep.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
