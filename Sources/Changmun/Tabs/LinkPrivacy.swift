import Foundation
import WebKit

/// The parameters sites and advertisers add to an address to follow a click around the web. They tell the page nothing it needs, so they are
/// taken out before the page loads. The list is exact names and a few prefixes, kept to names that mean nothing else: an ambiguous one
/// (`ref`, `source`, `id`, `cid`, `campaign`, `spm`) stays, because a site may use it for the page itself.
enum TrackingParameters {
    /// Lower case; names are compared without regard to case and percent-encoding.
    static let names: Set<String> = [
        // Google, Microsoft, Yandex and the other ad networks' click identifiers
        "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "li_fat_id",
        // Facebook, Instagram
        "fbclid", "igshid", "igsh",
        // Mailchimp, HubSpot, Marketo, Vero, Omeda, Adobe, Pinterest and others' email and campaign links
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "vero_id", "oly_enc_id", "oly_anon_id", "s_cid", "sccid",
        "rb_clickid", "wickedid", "ef_id", "epik",
        // Google Analytics' client and cross-domain linker ids, and the Drip/Customer.io style visitor id
        "_ga", "_gl", "__s",
    ]

    /// Names that begin with one of these: Google Analytics' campaign tags and HubSpot ads.
    static let prefixes = ["utm_", "hsa_"]

    static func isTracking(_ name: String) -> Bool {
        let name = (name.removingPercentEncoding ?? name).lowercased()
        return names.contains(name) || prefixes.contains { name.hasPrefix($0) }
    }

    /// The address without its tracking parameters; the address itself when it has none, is not http(s), or can't be read. Everything else is
    /// kept as it was written: the other parameters in their order and encoding, the fragment, the user info and the port. A query that is
    /// left empty goes with its "?".
    static func strip(_ url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host()?.isEmpty == false else { return url }
        let text = url.absoluteString
        let fragmentStart = text.firstIndex(of: "#") ?? text.endIndex
        guard let mark = text[..<fragmentStart].firstIndex(of: "?") else { return url }
        let items = text[text.index(after: mark)..<fragmentStart].split(separator: "&", omittingEmptySubsequences: false)
        let kept = items.filter { item in
            !isTracking(String(item.prefix { $0 != "=" }))
        }
        guard kept.count != items.count else { return url }
        let query = kept.joined(separator: "&")
        return URL(string: String(text[..<mark]) + (query.isEmpty ? "" : "?" + query) + String(text[fragmentStart...])) ?? url
    }
}

/// Prefer secure connections: an http address is tried over https first. The choice is a pure function of the address, so every way into a
/// tab (a click, a redirect, the address bar, the AI's tools) answers the same.
enum HTTPSFirst {
    /// Tests only: hosts treated as public, with their "http" and "https" ports standing for 80 and 443, so that a local server can play a site.
    struct Override: Equatable {
        var hosts: Set<String>
        var plainPort: Int
        var securePort: Int
    }

    /// Tests only (the headless test copy sets it): see `Override`.
    @MainActor static var testOverride: Override?

    /// Names that only mean something on a local network or on this Mac, which a certificate authority can't vouch for.
    static let localSuffixes = ["localhost", "local", "test", "internal", "lan", "home", "corp", "intranet", "home.arpa", "invalid", "example"]

    /// How long the secure attempt gets before the site counts as unreachable over https.
    static let timeout: TimeInterval = 10

    /// The errors of a secure attempt that mean the site isn't there over https: nothing listens, or nothing answers. A certificate error is
    /// never one of them, and neither is a host that isn't found or a failed handshake: those stay errors, never an http page.
    static let fallbackCodes: Set<Int> = [NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost]

    static func normalized(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    /// Hosts that stay http without a try: a name with no dot, the local and test names, and every IP address (a public one has no certificate
    /// that names it, so a try would only end in a certificate warning where the page used to load).
    static func staysPlain(_ host: String) -> Bool {
        let host = normalized(host)
        if host.isEmpty || host.contains(":") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, let last = labels.last else { return true }
        if last.allSatisfy(\.isNumber) || last.hasPrefix("0x") { return true }
        return localSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The https address to try for an http one, or nil to leave it as it is: another scheme, a host that stays plain, a port other than 80, a host
    /// the user already went on with over http (`plainHosts`, normalized).
    static func secureURL(for url: URL, plainHosts: Set<String> = [], override: Override? = nil) -> URL? {
        guard url.scheme?.lowercased() == "http", let host = url.host().map(normalized), !host.isEmpty, !plainHosts.contains(host) else { return nil }
        let forced = override?.hosts.contains(host) == true
        if let port = url.port, port != (forced ? override?.plainPort ?? 80 : 80) { return nil }
        if !forced && staysPlain(host) { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        components.port = forced ? override.flatMap { $0.securePort == 443 ? nil : $0.securePort } : nil
        return components.url
    }

    /// Whether a failed secure attempt is retried over http: the error is one of `fallbackCodes`, and it is the attempt's own address that failed
    /// (not a page it was sent on to).
    static func fallsBack(domain: String, code: Int, failing: URL?, upgraded: URL) -> Bool {
        guard domain == NSURLErrorDomain, fallbackCodes.contains(code), let failing else { return false }
        return failing.scheme?.lowercased() == upgraded.scheme?.lowercased() && failing.host()?.lowercased() == upgraded.host()?.lowercased()
            && (failing.port ?? 443) == (upgraded.port ?? 443)
    }
}

/// What a navigation to an address becomes: the address without tracking parameters, over https when that is tried first.
enum LinkRewrite {
    struct Result: Equatable {
        /// What to load.
        var url: URL
        /// The http address to go back to if the secure attempt finds no site; nil when the address isn't tried over https.
        var plain: URL?
    }

    static func rewrite(_ url: URL, stripsTracking: Bool, upgrades: Bool, plainHosts: Set<String> = [], override: HTTPSFirst.Override? = nil) -> Result? {
        let cleaned = stripsTracking ? TrackingParameters.strip(url) : url
        if upgrades, let secure = HTTPSFirst.secureURL(for: cleaned, plainHosts: plainHosts, override: override) { return Result(url: secure, plain: cleaned) }
        return cleaned == url ? nil : Result(url: cleaned, plain: nil)
    }

    /// Whether a navigation the page started may be rewritten, and the page's own frame is then what navigates (a navigation the app issues in
    /// its place would be the browser's: no initiator, so a site's SameSite cookies and Sec-Fetch-Site would no longer tell a cross-site link
    /// from the user typing the address). Only a link the user pressed, in the page itself and for the page itself, a plain GET. A redirect, a
    /// script's navigation, a form, a reload and back or forward are loaded as they are; so is a user's click that cannot be told from a script's
    /// (`userInitiated` is false where WebKit's flag can't be read). A load the browser starts itself (the address bar, a bookmark, a link opened
    /// in a new tab, the AI's tools) has no page to speak for and is rewritten before it begins.
    static func mayRewriteInPage(type: WKNavigationType, userInitiated: Bool, sourceIsMainFrame: Bool, targetIsMainFrame: Bool, isPlainGET: Bool) -> Bool {
        type == .linkActivated && userInitiated && sourceIsMainFrame && targetIsMainFrame && isPlainGET
    }
}

/// The hosts whose secure attempt found no site: not tried over https again for a while. Kept in memory only, apart for each website data store
/// (a profile space has its own) and for private windows, and forgotten after `lifetime`, so that a connection that was blocked once doesn't keep a
/// host on http for the whole run.
struct PlainHostMemory {
    static let lifetime: TimeInterval = 15 * 60

    private struct Key: Hashable {
        var store: UUID?
        var isPrivate: Bool
        var host: String
    }

    private var entries: [Key: Date] = [:]

    mutating func insert(host: String, store: UUID?, isPrivate: Bool, now: Date = Date()) {
        entries = entries.filter { now.timeIntervalSince($0.value) < Self.lifetime }
        entries[Key(store: store, isPrivate: isPrivate, host: HTTPSFirst.normalized(host))] = now
    }

    func hosts(store: UUID?, isPrivate: Bool, now: Date = Date()) -> Set<String> {
        Set(entries.filter { $0.key.store == store && $0.key.isPrivate == isPrivate && now.timeIntervalSince($0.value) < Self.lifetime }.map(\.key.host))
    }
}
