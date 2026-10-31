import AppKit
import WebKit

/// Camera and microphone decisions per site: asked once with an option to remember, changed in Settings.
@MainActor
final class SitePermissions: ObservableObject {
    static let shared = SitePermissions()

    enum Device: String, CaseIterable {
        case camera, microphone

        var name: String { self == .camera ? String(localized: "Camera") : String(localized: "Microphone") }
    }

    enum Decision: String, CaseIterable {
        case ask, allow, deny

        var name: String {
            switch self {
            case .ask: String(localized: "Ask")
            case .allow: String(localized: "Allow")
            case .deny: String(localized: "Block")
            }
        }
    }

    /// host → device → decision.
    @Published private(set) var stored: [String: [String: String]]

    private init() {
        stored = UserDefaults.standard.dictionary(forKey: "sitePermissions") as? [String: [String: String]] ?? [:]
    }

    func decision(_ host: String, _ device: Device) -> Decision {
        Decision(rawValue: stored[host]?[device.rawValue] ?? "") ?? .ask
    }

    func set(_ decision: Decision, host: String, device: Device) {
        guard !host.isEmpty else { return }
        var forHost = stored[host] ?? [:]
        forHost[device.rawValue] = decision == .ask ? nil : decision.rawValue
        stored[host] = forHost.isEmpty ? nil : forHost
        UserDefaults.standard.set(stored, forKey: "sitePermissions")
    }

    func forget(_ host: String) {
        stored[host] = nil
        UserDefaults.standard.set(stored, forKey: "sitePermissions")
    }

    /// What a remembered decision comes to on a page whose certificate the user went on with though it could not be verified: a refusal stands, but an
    /// allowance is not applied there (the page is asked again each time, and nothing is kept).
    nonisolated static func effective(_ decision: Decision, unverified: Bool) -> Decision {
        unverified && decision == .allow ? .ask : decision
    }

    /// `remember` false (a private window) never offers to keep the answer, which would record the site. `unverified`: the page's certificate was not verified.
    /// What was decided, and whether it was the user who said no (a page that is told no is not to ask again in that load).
    struct Answer: Equatable {
        var decision: WKPermissionDecision
        var blockedByUser = false
    }

    /// The same site asking for the same device is one question, whatever the number of times it asks; it asking for another device waits for it;
    /// another site's question is refused while one is up, so a page cannot pile questions up. `ask` shows the sheet, on the window of the tab.
    func decide(host: String, type: WKMediaCaptureType, remember: Bool = true, unverified: Bool = false, background: Bool = false,
                ask: (DialogSpec, DialogKey) async -> DialogResult?) async -> Answer {
        let remember = remember && !unverified
        let devices: [Device] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        default: [.camera, .microphone]
        }
        let decisions = devices.map { Self.effective(decision(host, $0), unverified: unverified) }
        if decisions.contains(.deny) { return Answer(decision: .deny) }
        if decisions.allSatisfy({ $0 == .allow }) { return Answer(decision: .grant) }
        if Headless.isOn { return Answer(decision: .deny) }

        let key = Self.key(host: host, type: type)
        guard let answer = await ask(Self.spec(host: host, type: type, remember: remember, background: background), key) else { return Answer(decision: .deny) }
        let allowed = answer.button == 1
        if answer.remembered {
            for device in devices { set(allowed ? .allow : .deny, host: host, device: device) }
        }
        return Answer(decision: allowed ? .grant : .deny, blockedByUser: !allowed)
    }

    /// One site asking for one device (or both) is one question.
    static func key(host: String, type: WKMediaCaptureType) -> DialogKey {
        DialogKey(group: host, kind: type == .camera ? "camera" : type == .microphone ? "microphone" : "camera+microphone")
    }

    /// The question: the site is named by its host, cleaned and cut. Block is what Return does.
    static func spec(host: String, type: WKMediaCaptureType, remember: Bool, background: Bool = false) -> DialogSpec {
        let site = DialogSpec.host(host)
        let (title, message) = switch type {
        case .camera: (String(localized: "\(site) wants to use the camera"), String(localized: "If you allow it, this site can turn on the camera."))
        case .microphone: (String(localized: "\(site) wants to use the microphone"), String(localized: "If you allow it, this site can turn on the microphone."))
        default: (String(localized: "\(site) wants to use the camera and microphone"), String(localized: "If you allow it, this site can turn on the camera and microphone."))
        }
        return DialogSpec(title: title, message: message, remember: remember ? String(localized: "Remember for this site") : nil,
                          buttons: [DialogButton(title: String(localized: "Block"), role: .cancel, isDefault: true), DialogButton(title: String(localized: "Allow"))],
                          note: background ? String(localized: "From a tab in the background") : nil, guarded: true)
    }
}
