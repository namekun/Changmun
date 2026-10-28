import Foundation
import Network

extension ControlServer {
    /// Tests only: the privacy settings of links and connections. "tracking" and "https" set the two switches; "keptHosts" the sites that keep their
    /// tracking parameters; "override" ({"hosts", "plain", "secure"}, or null) lets a local server play a public site (see HTTPSFirst.Override);
    /// "forgetPlainHosts" empties the hosts that were found not to speak https. The answer says how things stand.
    func handlePrivacyTestRequest(_ request: HTTPRequest, on connection: NWConnection) -> Bool {
        guard Headless.isTestCopy, request.method == "POST", request.path == "/privacy",
              let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return false }
        Task { @MainActor in
            let prefs = Preferences.shared
            if let on = body["tracking"] as? Bool { prefs.removeTrackingFromLinks = on }
            if let on = body["https"] as? Bool { prefs.preferSecureConnections = on }
            if let hosts = body["keptHosts"] as? [String] { prefs.trackingKeptHosts = hosts }
            if body.keys.contains("override") {
                let value = body["override"] as? [String: Any]
                HTTPSFirst.testOverride = value.flatMap { value in
                    (value["hosts"] as? [String]).map { HTTPSFirst.Override(hosts: Set($0), plainPort: value["plain"] as? Int ?? 80, securePort: value["secure"] as? Int ?? 443) }
                }
            }
            if body["forgetPlainHosts"] as? Bool == true { PlainHosts.normal = []; PlainHosts.privateWindows = [] }
            self.respond(connection, status: "200 OK", body: ["tracking": prefs.removeTrackingFromLinks, "https": prefs.preferSecureConnections,
                                                              "keptHosts": prefs.trackingKeptHosts, "plainHosts": PlainHosts.normal.sorted()])
        }
        return true
    }
}
