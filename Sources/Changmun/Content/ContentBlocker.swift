import Foundation
import WebKit

/// Well-known third-party ad and tracking hosts, always blocked along with the downloaded filter lists.
enum ContentBlocker {
    static let hosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com", "analytics.google.com",
        "scorecardresearch.com", "quantserve.com", "taboola.com", "outbrain.com", "criteo.com", "criteo.net",
        "adnxs.com", "amazon-adsystem.com", "adsrvr.org", "rubiconproject.com", "pubmatic.com", "openx.net",
        "casalemedia.com", "moatads.com", "smartadserver.com", "adform.net", "teads.tv", "hotjar.com",
    ]

    /// One rule per host, for third-party loads only, so the sites themselves still open.
    static var rules: String {
        let list = hosts.map { host -> [String: Any] in
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": ["url-filter": "^[^:]+://+([^:/]+\\.)?\(escaped)[/:]", "load-type": ["third-party"]],
                "action": ["type": "block"],
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: list)
        return String(data: data, encoding: .utf8)!
    }
}
