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
    func decide(host: String, type: WKMediaCaptureType, remember: Bool = true, unverified: Bool = false) -> WKPermissionDecision {
        let remember = remember && !unverified
        let devices: [Device] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        default: [.camera, .microphone]
        }
        let decisions = devices.map { Self.effective(decision(host, $0), unverified: unverified) }
        if decisions.contains(.deny) { return .deny }
        if decisions.allSatisfy({ $0 == .allow }) { return .grant }
        if Headless.isOn { return .deny }

        let alert = NSAlert()
        alert.messageText = switch type {
        case .camera: String(localized: "\(host) wants to use the camera")
        case .microphone: String(localized: "\(host) wants to use the microphone")
        default: String(localized: "\(host) wants to use the camera and microphone")
        }
        alert.addButton(withTitle: String(localized: "Block"))
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.showsSuppressionButton = remember
        alert.suppressionButton?.title = String(localized: "Remember for this site")
        let allowed = alert.runModal() == .alertSecondButtonReturn
        if alert.suppressionButton?.state == .on {
            for device in devices { set(allowed ? .allow : .deny, host: host, device: device) }
        }
        return allowed ? .grant : .deny
    }
}
