import AppKit
import SwiftUI

enum AddressBarChoice: String, CaseIterable, Identifiable {
    /// The whole address in developer mode, the site and the page's title otherwise.
    case automatic
    /// The site and the page's title; ⌘L edits it in the command bar. (Named for where it used to sit.)
    case sidebar
    /// The whole address, edited in place.
    case top

    var id: String { rawValue }
}

/// Where the address bar and the back and forward buttons sit: on the page card, as in Dia, or at the top of the
/// sidebar, as in Arc. With the sidebar hidden they are always on the page card.
enum ToolbarPlace: String, CaseIterable, Identifiable {
    case page
    case sidebar

    var id: String { rawValue }
}

/// Where the open tabs are: a column down the left (the sidebar), or a strip along the top of the window above the page bar.
enum TabLayout: String, CaseIterable, Identifiable {
    case sidebar
    case top

    var id: String { rawValue }

    /// What is stored; anything else (a value from a later version, nothing yet) is the sidebar.
    init(stored: String?) { self = stored.flatMap(TabLayout.init(rawValue:)) ?? .sidebar }
}

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
    @Published var toolbarPlace: ToolbarPlace { didSet { defaults.set(toolbarPlace.rawValue, forKey: "toolbarPlace") } }
    @Published var tabLayout: TabLayout { didSet { defaults.set(tabLayout.rawValue, forKey: "tabLayout") } }
    @Published var defaultZoom: Double { didSet { defaults.set(defaultZoom, forKey: "defaultZoom") } }
    /// Leaving a tab whose video is playing floats the video in picture in picture.
    @Published var autoPictureInPicture: Bool { didSet { defaults.set(autoPictureInPicture, forKey: "autoPictureInPicture") } }
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
    /// A newly opened tab joins the group it belongs in.
    @Published var groupNewTabs: Bool { didSet { defaults.set(groupNewTabs, forKey: "groupNewTabs") } }

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

    // MARK: Advanced

    @Published var developerMode: Bool { didSet { defaults.set(developerMode, forKey: "developerMode") } }
    @Published var addressBar: AddressBarChoice { didSet { defaults.set(addressBar.rawValue, forKey: "addressBar") } }
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
        // The address moved into the sidebar with the glass look; everyone starts there once, and can move it back.
        if !d.bool(forKey: "addressInSidebarOnce") {
            d.set(ToolbarPlace.sidebar.rawValue, forKey: "toolbarPlace")
            d.set(true, forKey: "addressInSidebarOnce")
        }
        toolbarPlace = ToolbarPlace(rawValue: d.string(forKey: "toolbarPlace") ?? "") ?? .sidebar
        tabLayout = TabLayout(stored: d.string(forKey: "tabLayout"))
        defaultZoom = d.object(forKey: "defaultZoom") as? Double ?? 1
        autoPictureInPicture = d.object(forKey: "autoPictureInPicture") as? Bool ?? true
        siteZoom = d.dictionary(forKey: "siteZoom") as? [String: Double] ?? [:]
        neverSaveLoginHosts = d.stringArray(forKey: "neverSaveLoginHosts") ?? []
        popupHosts = d.stringArray(forKey: "popupHosts") ?? []
        sleepMinutes = d.object(forKey: "sleepTabsAfterMinutes") as? Int ?? 20
        neverSleepHosts = d.stringArray(forKey: "neverSleepHosts") ?? []
        archiveHours = d.object(forKey: "archiveTabsAfterHours") as? Int ?? 0
        groupNewTabs = d.object(forKey: "groupNewTabs") as? Bool ?? true
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
        developerMode = d.bool(forKey: "developerMode")
        addressBar = AddressBarChoice(rawValue: d.string(forKey: "addressBar") ?? "") ?? .automatic
        shortcuts = ShortcutScheme(rawValue: d.string(forKey: "shortcuts") ?? "") ?? .safari
    }

    /// A privacy switch that is on until the user turns it off: nothing stored (everyone who had the app before it), or a value of another kind, is on.
    nonisolated static func privacySwitch(_ stored: Any?) -> Bool { stored as? Bool ?? true }

    var addressBarOnTop: Bool { Self.onTop(addressBar, developerMode: developerMode) }

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

    nonisolated static func onTop(_ choice: AddressBarChoice, developerMode: Bool) -> Bool {
        choice == .top || (choice == .automatic && developerMode)
    }

    /// Whether a background tab on this host may give up its web process.
    nonisolated static func canSleep(host: String?, neverSleep: [String]) -> Bool {
        guard let host = host?.lowercased() else { return true }
        return !neverSleep.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
