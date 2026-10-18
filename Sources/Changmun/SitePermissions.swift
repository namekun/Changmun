import AppKit
import WebKit

/// Camera and microphone decisions per site: asked once with an option to remember, changed in Settings.
@MainActor
final class SitePermissions: ObservableObject {
    static let shared = SitePermissions()

    enum Device: String, CaseIterable {
        case camera, microphone

        var name: String { self == .camera ? "카메라" : "마이크" }
    }

    enum Decision: String, CaseIterable {
        case ask, allow, deny

        var name: String {
            switch self {
            case .ask: "묻기"
            case .allow: "허용"
            case .deny: "차단"
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
        var forHost = stored[host] ?? [:]
        forHost[device.rawValue] = decision == .ask ? nil : decision.rawValue
        stored[host] = forHost.isEmpty ? nil : forHost
        UserDefaults.standard.set(stored, forKey: "sitePermissions")
    }

    func forget(_ host: String) {
        stored[host] = nil
        UserDefaults.standard.set(stored, forKey: "sitePermissions")
    }

    /// `remember` false (a private window) never offers to keep the answer, which would record the site.
    func decide(host: String, type: WKMediaCaptureType, remember: Bool = true) -> WKPermissionDecision {
        let devices: [Device] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        default: [.camera, .microphone]
        }
        let decisions = devices.map { decision(host, $0) }
        if decisions.contains(.deny) { return .deny }
        if decisions.allSatisfy({ $0 == .allow }) { return .grant }

        let alert = NSAlert()
        alert.messageText = "\(host)에서 \(devices.map(\.name).joined(separator: "와 "))를 쓰려고 해요"
        alert.addButton(withTitle: "차단")
        alert.addButton(withTitle: "허용")
        alert.showsSuppressionButton = remember
        alert.suppressionButton?.title = "이 사이트에서는 기억하기"
        let allowed = alert.runModal() == .alertSecondButtonReturn
        if alert.suppressionButton?.state == .on {
            for device in devices { set(allowed ? .allow : .deny, host: host, device: device) }
        }
        return allowed ? .grant : .deny
    }
}
