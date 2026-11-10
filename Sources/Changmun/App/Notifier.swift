import AppKit
import UserNotifications

/// What the user has decided about notifications from this app, as the system keeps it.
enum NotifierAuthorization: Equatable {
    /// Never asked.
    case notAsked
    case allowed
    case refused
}

/// The system's notification centre, as far as the Notifier uses it: tests give it one that asks nobody anything.
@MainActor
protocol NotificationCentre: AnyObject {
    func authorization() async -> NotifierAuthorization
    /// Asks the user (a system prompt); whether they agreed.
    func requestAuthorization() async -> Bool
    func post(identifier: String, _ content: Notifier.Content, target: Notifier.Target) async
    func removeDelivered(identifier: String)
}

/// System notifications for what happens while the app is in the background: a download finished, the AI waiting for an answer. It does
/// nothing in a headless app or in anything that is not the user's own app (the tests), and asks for permission only the first time a
/// notification would be shown.
@MainActor
final class Notifier: ObservableObject {
    static let shared = Notifier()
    nonisolated static let appBundleID = "io.github.namekun.Changmun"
    static let approvalIdentifier = "ai-waiting"

    /// What the system last said, for Settings to tell the user when notifications are off.
    @Published private(set) var authorization: NotifierAuthorization = .notAsked

    struct Environment: Equatable {
        var headless: Bool
        var bundleID: String?
        var underTests: Bool

        static var current: Environment {
            Environment(headless: Headless.isOn, bundleID: Bundle.main.bundleIdentifier, underTests: NSClassFromString("XCTestCase") != nil)
        }

        /// Only the user's own app, with its windows: not a headless one (nobody is there to see it), not the test runner.
        var isUserApp: Bool { !headless && !underTests && bundleID == Notifier.appBundleID }
    }

    enum Event: Equatable {
        case downloadFinished(name: String, isPrivate: Bool)
        case approvalWaiting
    }

    struct Content: Equatable {
        var title: String
        var body: String?
    }

    /// Where a click on the notification goes: the window the thing happened in (by its number), and which part of it.
    enum Target: Equatable {
        case downloads(window: Int?)
        case approval(window: Int?)

        var userInfo: [String: Any] {
            switch self {
            case .downloads(let window): ["target": "downloads", "window": window ?? 0]
            case .approval(let window): ["target": "approval", "window": window ?? 0]
            }
        }

        init?(userInfo: [AnyHashable: Any]) {
            let number = userInfo["window"] as? Int
            let window = number == 0 ? nil : number
            switch userInfo["target"] as? String {
            case "downloads": self = .downloads(window: window)
            case "approval": self = .approval(window: window)
            default: return nil
            }
        }

        var window: Int? {
            switch self {
            case .downloads(let window), .approval(let window): window
            }
        }
    }

    private let environment: Environment
    private let isActive: @MainActor () -> Bool
    private let isEnabled: @MainActor () -> Bool
    private let makeCentre: @MainActor () -> NotificationCentre
    private var centre: NotificationCentre?

    init(environment: Environment = .current, isActive: (@MainActor () -> Bool)? = nil, isEnabled: (@MainActor () -> Bool)? = nil,
         centre: (@MainActor () -> NotificationCentre)? = nil) {
        self.environment = environment
        self.isActive = isActive ?? { NSApp?.isActive ?? false }
        self.isEnabled = isEnabled ?? { Preferences.shared.notifyInBackground }
        makeCentre = centre ?? { SystemNotificationCentre() }
    }

    /// What to show for an event, or nil for nothing: not in the wrong kind of app, not when the setting is off, and not while the app is in front
    /// (the sidebar and the approval card are in front of the user already). A private window's download is named by nothing but its kind.
    nonisolated static func content(for event: Event, appIsActive: Bool, enabled: Bool, environment: Environment) -> Content? {
        guard environment.isUserApp, enabled, !appIsActive else { return nil }
        switch event {
        case .downloadFinished(let name, let isPrivate):
            return Content(title: String(localized: "Download finished"), body: isPrivate ? nil : name)
        case .approvalWaiting:
            return Content(title: String(localized: "The AI is waiting for your answer"), body: nil)
        }
    }

    func downloadFinished(_ item: DownloadItem) {
        let window = (item.isPrivate ? item.owner : Browser.recent)?.window?.windowNumber
        send(.downloadFinished(name: item.filename, isPrivate: item.isPrivate), target: .downloads(window: window), identifier: item.id.uuidString)
    }

    func approvalWaiting(in browser: Browser?) {
        send(.approvalWaiting, target: .approval(window: browser?.window?.windowNumber), identifier: Self.approvalIdentifier)
    }

    private func send(_ event: Event, target: Target, identifier: String) {
        Task { await deliver(event, target: target, identifier: identifier) }
    }

    /// Shows the notification when it is wanted: asking for permission first if the user was never asked, and saying nothing if they refused.
    /// Whether it was shown.
    @discardableResult
    func deliver(_ event: Event, target: Target, identifier: String) async -> Bool {
        guard environment.isUserApp,
              let content = Self.content(for: event, appIsActive: isActive(), enabled: isEnabled(), environment: environment) else { return false }
        let centre = centre ?? makeCentre()
        self.centre = centre
        var status = await centre.authorization()
        if status == .notAsked { status = await centre.requestAuthorization() ? .allowed : .refused }
        authorization = status
        guard status == .allowed else { return false }
        await centre.post(identifier: identifier, content, target: target)
        return true
    }

    /// Settings: what the system says now, so a refusal shows. Nothing is asked.
    func refreshAuthorization() {
        guard environment.isUserApp else { return }
        Task {
            let centre = centre ?? makeCentre()
            self.centre = centre
            authorization = await centre.authorization()
        }
    }

    /// The app came forward: a notice that the AI waits is out of date, since the question is in front of the user now.
    func appBecameActive() {
        centre?.removeDelivered(identifier: Self.approvalIdentifier)
    }

    /// The window the notification belongs to comes forward (the downloads list, for a download).
    static func open(_ target: Target) {
        let browser = Browser.all.first { target.window != nil && $0.window?.windowNumber == target.window } ?? Browser.recent ?? BrowserWindow.open()
        NSApp.activate()
        browser.window?.makeKeyAndOrderFront(nil)
        if case .downloads = target { browser.showDownloads = true }
    }
}

/// The real centre. Made only when a notification is about to be shown (or Settings looks), since asking the system for it in a process
/// that is not an app bundle fails.
@MainActor
final class SystemNotificationCentre: NSObject, NotificationCentre, UNUserNotificationCenterDelegate {
    private let centre = UNUserNotificationCenter.current()
    private var observer: NSObjectProtocol?

    override init() {
        super.init()
        centre.delegate = self
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Notifier.shared.appBecameActive() }
        }
    }

    func authorization() async -> NotifierAuthorization {
        switch await centre.notificationSettings().authorizationStatus {
        case .notDetermined: .notAsked
        case .denied: .refused
        default: .allowed
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await centre.requestAuthorization(options: [.alert])) ?? false
    }

    func post(identifier: String, _ content: Notifier.Content, target: Notifier.Target) async {
        let note = UNMutableNotificationContent()
        note.title = content.title
        if let body = content.body { note.body = body }
        note.userInfo = target.userInfo
        try? await centre.add(UNNotificationRequest(identifier: identifier, content: note, trigger: nil))
    }

    func removeDelivered(identifier: String) {
        centre.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let target = Notifier.Target(userInfo: response.notification.request.content.userInfo)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let target { Notifier.open(target) }
                completionHandler()
            }
        }
    }

    /// A notification is only posted while the app is in the background; one that arrives as the app comes forward is not shown over it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}
