import AppKit
import SwiftUI

enum AddressBarChoice: String, CaseIterable, Identifiable {
    /// On top in developer mode, in the sidebar otherwise.
    case automatic
    case sidebar
    case top

    var id: String { rawValue }
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
        case .naver: "네이버"
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
    @Published var restoreTabs: Bool { didSet { defaults.set(restoreTabs, forKey: "restoreTabs") } }
    @Published var downloadFolder: URL { didSet { defaults.set(downloadFolder.path, forKey: "downloadFolder") } }
    @Published var askWhereToSave: Bool { didSet { defaults.set(askWhereToSave, forKey: "askWhereToSave") } }

    // MARK: Tabs and looks

    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            NSApp?.appearance = appearance.nsAppearance
        }
    }
    @Published var sidebarWidth: Double { didSet { defaults.set(sidebarWidth, forKey: "sidebarWidth") } }
    @Published var defaultZoom: Double { didSet { defaults.set(defaultZoom, forKey: "defaultZoom") } }
    /// Minutes before a background tab sleeps; 0 never.
    @Published var sleepMinutes: Int { didSet { defaults.set(sleepMinutes, forKey: "sleepTabsAfterMinutes") } }
    @Published var neverSleepHosts: [String] { didSet { defaults.set(neverSleepHosts, forKey: "neverSleepHosts") } }

    // MARK: Privacy

    @Published var blockTrackers: Bool {
        didSet {
            defaults.set(blockTrackers, forKey: "blockTrackers")
            Task { await AdBlocker.shared.apply(enabled: blockTrackers) }
        }
    }
    @Published var customFilterLists: [String] { didSet { defaults.set(customFilterLists, forKey: "customFilterLists") } }
    @Published var disabledFilterLists: [String] { didSet { defaults.set(disabledFilterLists, forKey: "disabledFilterLists") } }
    /// Sites where ads aren't blocked.
    @Published var adBlockAllowlist: [String] { didSet { defaults.set(adBlockAllowlist, forKey: "adBlockAllowlist") } }

    // MARK: Extensions

    @Published var extensionFolders: [String] { didSet { defaults.set(extensionFolders, forKey: "extensionFolders") } }
    @Published var enabledExtensions: [String] { didSet { defaults.set(enabledExtensions, forKey: "enabledExtensions") } }

    // MARK: AI

    @Published var aiModel: String { didSet { defaults.set(aiModel, forKey: "aiModel") } }
    @Published var aiApprovals: Bool { didSet { defaults.set(aiApprovals, forKey: "aiApprovals") } }
    @Published var claudePath: String { didSet { defaults.set(claudePath.isEmpty ? nil : claudePath, forKey: "claudePath") } }

    // MARK: Advanced

    @Published var developerMode: Bool { didSet { defaults.set(developerMode, forKey: "developerMode") } }
    @Published var addressBar: AddressBarChoice { didSet { defaults.set(addressBar.rawValue, forKey: "addressBar") } }
    @Published var shortcuts: ShortcutScheme { didSet { defaults.set(shortcuts.rawValue, forKey: "shortcuts") } }

    private init() {
        let d = UserDefaults.standard
        let template = d.string(forKey: "searchURL")
        searchEngine = SearchEngine.allCases.first { $0.template == template } ?? .google
        restoreTabs = d.object(forKey: "restoreTabs") as? Bool ?? true
        downloadFolder = d.string(forKey: "downloadFolder").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        askWhereToSave = d.bool(forKey: "askWhereToSave")
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        sidebarWidth = d.object(forKey: "sidebarWidth") as? Double ?? 252
        defaultZoom = d.object(forKey: "defaultZoom") as? Double ?? 1
        sleepMinutes = d.object(forKey: "sleepTabsAfterMinutes") as? Int ?? 20
        neverSleepHosts = d.stringArray(forKey: "neverSleepHosts") ?? []
        blockTrackers = d.object(forKey: "blockTrackers") as? Bool ?? true
        customFilterLists = d.stringArray(forKey: "customFilterLists") ?? []
        disabledFilterLists = d.stringArray(forKey: "disabledFilterLists") ?? []
        adBlockAllowlist = d.stringArray(forKey: "adBlockAllowlist") ?? []
        extensionFolders = d.stringArray(forKey: "extensionFolders") ?? []
        enabledExtensions = d.stringArray(forKey: "enabledExtensions") ?? []
        aiModel = d.string(forKey: "aiModel") ?? "sonnet"
        aiApprovals = d.object(forKey: "aiApprovals") as? Bool ?? true
        claudePath = d.string(forKey: "claudePath") ?? ""
        developerMode = d.bool(forKey: "developerMode")
        addressBar = AddressBarChoice(rawValue: d.string(forKey: "addressBar") ?? "") ?? .automatic
        shortcuts = ShortcutScheme(rawValue: d.string(forKey: "shortcuts") ?? "") ?? .safari
    }

    var addressBarOnTop: Bool { Self.onTop(addressBar, developerMode: developerMode) }

    nonisolated static func onTop(_ choice: AddressBarChoice, developerMode: Bool) -> Bool {
        choice == .top || (choice == .automatic && developerMode)
    }

    /// Whether a background tab on this host may give up its web process.
    nonisolated static func canSleep(host: String?, neverSleep: [String]) -> Bool {
        guard let host = host?.lowercased() else { return true }
        return !neverSleep.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
