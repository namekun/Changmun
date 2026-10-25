import Foundation
import Sparkle

/// Updates arrive inside the app: Sparkle fetches the appcast (SUFeedURL in Info.plist, served by GitHub Pages), checks
/// the download against the EdDSA key in the app (SUPublicEDKey) and replaces the app. It starts at launch, except in the
/// headless app and anywhere the app has no feed (a bare binary, the tests), where there is nothing to update.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()
    private let updater: SPUUpdater?
    private let controller: SPUStandardUpdaterController?

    private init() {
        let configured = !Headless.isOn && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = configured ? SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil) : nil
        updater = controller?.updater
    }

    /// Starts the updater. Someone who turned the old once-a-day check off keeps it off; the old check's records go.
    func start() {
        guard let controller, let updater else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "checkForUpdates") as? Bool == false { updater.automaticallyChecksForUpdates = false }
        for key in ["checkForUpdates", "lastUpdateCheck", "latestVersion", "dismissedUpdate"] { defaults.removeObject(forKey: key) }
        controller.startUpdater()
    }

    var isAvailable: Bool { updater != nil }
    var canCheck: Bool { updater?.canCheckForUpdates ?? false }

    func checkForUpdates() { updater?.checkForUpdates() }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            updater?.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloads: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set {
            objectWillChange.send()
            updater?.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Sparkle offers the automatic install only while it checks automatically.
    var allowsAutomaticDownloads: Bool { updater?.allowsAutomaticUpdates ?? false }
}
