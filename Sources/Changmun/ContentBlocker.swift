import Foundation
import WebKit

/// Blocks well-known third-party ad and tracking hosts with a WebKit content rule list.
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

    @MainActor private static var compiled: WKContentRuleList?

    /// Turns blocking on or off for every tab: they all share the app's user content controller.
    @MainActor
    static func apply(_ enabled: Bool) async {
        let controller = Browser.configuration.userContentController
        if let compiled { controller.remove(compiled) }
        guard enabled else { return }
        if compiled == nil {
            compiled = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "changmun-trackers-v1", encodedContentRuleList: rules)
        }
        if let compiled { controller.add(compiled) }
    }
}
