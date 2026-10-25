import Foundation

/// How an address is named as a "site": what the AI's approvals, reads and attachments are remembered by.
package enum Site {
    /// Stands for a frame that has no site to name (a sandboxed frame, one that could not be asked): a site of its own.
    package nonisolated static let unknownFrame = "\u{1}unknown-frame"
    /// Stands for an image the user added from outside the browser (a file, the clipboard): a source of its own, which no tab is on.
    package nonisolated static let addedImage = "\u{1}added-image"

    /// The site an address is on, as what was read and allowed is remembered: its exact host, lowercased and in the ASCII form
    /// of an international name (www.example.com and shop.example.com are two sites, so are two sites on one hosting service),
    /// with the port when it isn't the scheme's own (another port is another site), and with "http://" in front for an
    /// unencrypted page (http and https are two sites); a page with no host (a file:, data: or blob: page) is a site by its
    /// scheme; nil for a blank page.
    package nonisolated static func site(of url: URL?) -> String? {
        guard let url else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        guard var host = URLComponents(string: url.absoluteString)?.encodedHost?.lowercased(), !host.isEmpty else { return scheme.isEmpty || scheme == "about" ? nil : scheme + ":" }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let written = host.contains(":") ? "[\(host)]" : host, prefix = scheme == "http" ? "http://" : ""
        guard let port = url.port, !(port == 443 && scheme == "https"), !(port == 80 && scheme == "http") else { return prefix + written }
        return "\(prefix)\(written):\(port)"
    }

    /// The host name of a site as `site(of:)` writes it (without "http://" and the port): nil for a site that has none.
    package nonisolated static func hostname(ofSite site: String) -> String? {
        guard hasSiteSyntax(site) else { return nil }
        var rest = Substring(site)
        if rest.hasPrefix("http://") { rest = rest.dropFirst(7) }
        if rest.hasPrefix("[") { return rest.firstIndex(of: "]").map { String(rest[rest.index(after: rest.startIndex)..<$0]) } }
        return rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    nonisolated private static func hasSiteSyntax(_ site: String) -> Bool {
        !site.isEmpty && site != unknownFrame && site != addedImage && !(site.hasSuffix(":") && site.dropLast().allSatisfy(\.isLetter))
    }

    /// The site an origin names ("https://example.com:8443"): "" for an origin that has none (a sandboxed frame, a data: page).
    package nonisolated static func site(ofOrigin origin: String) -> String {
        site(of: URL(string: origin)) ?? ""
    }

    /// Whether a site is one a user could allow for a chat: not "" and not a page that only has a scheme (file:).
    package nonisolated static func hasSite(_ site: String) -> Bool {
        !site.isEmpty && !(site.hasSuffix(":") && site.dropLast().allSatisfy(\.isLetter))
    }
}
