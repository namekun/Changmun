import Foundation
import WebKit

/// What the pages of a site loaded just before it lost cookies, for the cookie log: when a sign-in is dropped (Naver's, while browsing), the
/// request whose answer took the cookies away is among the last ones its pages made. The app sees no response headers of a page's requests,
/// but every page keeps a list of what it loaded and when (Resource Timing), which a script in the app's own world can read.
///
/// Only with the cookie log naming sites (`CookieLog.namesSites`), and only the host and the path of each request: no query, no fragment.
@MainActor
enum ResourceTrail {
    /// How far back the trail goes, in milliseconds.
    nonisolated static let window = 3_000

    /// The registrable domain a cookie's domain belongs to (".naver.com" → "naver.com").
    nonisolated static func site(ofCookieDomain domain: String) -> String {
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return PublicSuffix.list?.registrableDomain(host.lowercased()) ?? host.lowercased()
    }

    /// The script, run in the app's world: the page's own load and its requests of the last `window` ms, oldest first, as
    /// [ms before now, kind, host, path].
    static let script = """
    (() => {
      const now = performance.now();
      const cut = u => { try { const x = new URL(u); return [x.host, x.pathname]; } catch { return ['', '']; } };
      return performance.getEntries()
        .filter(e => (e.entryType === 'resource' || e.entryType === 'navigation') && now - (e.startTime + e.duration) <= \(window))
        .map(e => [Math.round(now - e.startTime), e.entryType === 'navigation' ? 'page' : e.initiatorType, ...cut(e.name)]);
    })()
    """

    /// The lines for the tabs of persistent stores showing a page of one of `sites`.
    static func lines(for sites: Set<String>) async -> [String] {
        var lines: [String] = []
        for browser in Browser.all where !browser.isPrivate {
            for tab in browser.tabs {
                guard let webView = tab.webView, webView.configuration.websiteDataStore.isPersistent,
                      let host = webView.url?.host()?.lowercased(), sites.contains(site(ofCookieDomain: host)) else { continue }
                let entries = (try? await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)) as? [[Any]] ?? []
                lines += format(tab: tab.id, page: host, entries)
            }
        }
        return lines
    }

    nonisolated static func format(tab: Int, page: String, _ entries: [[Any]]) -> [String] {
        guard !entries.isEmpty else { return ["trail tab=\(tab) page=\(page) nothing loaded in the last \(window)ms"] }
        return entries.map { entry in
            let ago = (entry.first as? NSNumber)?.intValue ?? 0
            let kind = entry.count > 1 ? "\(entry[1])" : "?"
            let host = entry.count > 2 ? "\(entry[2])" : ""
            let path = entry.count > 3 ? "\(entry[3])" : ""
            return "trail tab=\(tab) page=\(page) -\(ago)ms \(kind) \(host)\(path)"
        }
    }
}
