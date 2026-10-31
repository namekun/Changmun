import Foundation
import WebKit

extension ToolCatalog {
    // MARK: Reading as structured data and as Markdown

    /// The most read_structured answers, in characters.
    static let structuredChars = 12000
    static let defaultMarkdownChars = 12000, markdownCharRange = 200...60000

    @MainActor
    static func readStructured(_ webView: WKWebView) async -> ToolResult {
        await run(PageScripts.readStructured, ["maxChars": structuredChars], in: webView, timeout: readTimeout)
    }

    /// The page's Markdown version on its own site when it points to one and gives it, else the page converted from its DOM.
    @MainActor
    static func readMarkdown(_ webView: WKWebView, maxChars: Int) async -> ToolResult {
        if let own = await siteMarkdown(webView, maxChars: maxChars) { return own }
        let tracking: [String: Any] = ["maxChars": maxChars, "names": TrackingParameters.names.sorted(), "prefixes": TrackingParameters.prefixes]
        return await run(PageScripts.readMarkdown, tracking, in: webView, timeout: readTimeout)
    }

    /// The first Markdown version the page declares that is on the page's own site (as the approvals know sites; https, or the page's
    /// own scheme), fetched from inside the page. nil when there is none, it is on another site, or fetching it fails in any way.
    @MainActor
    private static func siteMarkdown(_ webView: WKWebView, maxChars: Int) async -> ToolResult? {
        let found = await run(PageScripts.markdownAlternates, [:], in: webView, timeout: 5)
        guard !found.isError, let text = found.content.first?["text"] as? String,
              let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let page = (json["url"] as? String).flatMap(URL.init(string:)), let site = Approvals.site(of: page), Approvals.hasSite(site),
              let scheme = page.scheme?.lowercased(),
              let href = (json["links"] as? [String])?.compactMap(URL.init(string:)).first(where: { link in
                  Approvals.site(of: link) == site && ["https", scheme].contains(link.scheme?.lowercased() ?? "")
              }) else { return nil }
        let fetched = await run(PageScripts.fetchMarkdown, ["href": href.absoluteString, "maxChars": maxChars], in: webView, timeout: 8)
        guard !fetched.isError, let answer = fetched.content.first?["text"] as? String, !answer.isEmpty else { return nil }
        return fetched
    }
}
