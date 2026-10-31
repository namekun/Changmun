import Foundation
import WebKit

extension ToolCatalog {
    // MARK: Reading as structured data and as Markdown

    /// The most read_structured answers, in characters.
    static let structuredChars = 12000
    static let defaultMarkdownChars = 12000, markdownCharRange = 200...60000

    @MainActor
    static func readStructured(_ webView: WKWebView) async -> ToolResult {
        withoutHiddenCharacters(await run(PageScripts.readStructured, ["maxChars": structuredChars], in: webView, timeout: readTimeout))
    }

    /// The page's Markdown version on its own site when it points to one and gives it, else the page converted from its DOM. `approvedHost`
    /// is the site the tab was on when the call was allowed: a tab that has gone elsewhere gets no request for the old page's alternate.
    @MainActor
    static func readMarkdown(_ tab: Tab, _ webView: WKWebView, maxChars: Int, session: Session, approvedHost: String?) async -> ToolResult {
        if let own = await siteMarkdown(tab, webView, maxChars: maxChars, session: session, approvedHost: approvedHost) { return withoutHiddenCharacters(own) }
        if session.stopped { return stopped }
        let tracking: [String: Any] = ["maxChars": maxChars, "names": TrackingParameters.names.sorted(), "prefixes": TrackingParameters.prefixes]
        return withoutHiddenCharacters(await run(PageScripts.readMarkdown, tracking, in: webView, timeout: readTimeout))
    }

    /// An answer without the characters that are invisible or let text pass for other text (`Approvals.isHidden`), apart from line breaks and
    /// tabs. The scripts blank the controls they know of; this is the rule for the rest, and it also covers a Markdown version the site gave.
    /// It takes the joiners with it: a family or a flag made of several emoji is shown as the emoji it is made of, and a variation
    /// selector (the one that asks for a colour emoji) is gone.
    nonisolated static func withoutHiddenCharacters(_ result: ToolResult) -> ToolResult {
        guard !result.isError, let text = result.content.first?["text"] as? String else { return result }
        var visible = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar == "\n" || scalar == "\t" || scalar == "\r" || !Approvals.isHidden(scalar) { visible.append(scalar) }
        return .text(String(visible))
    }

    /// The first Markdown version the page declares that is on the page's own site (as the approvals know sites; https, or the page's
    /// own scheme) and has a file name of a text (.md, .markdown or .txt: a page can't have a path like /logout fetched with the
    /// reader's cookies), fetched from inside the page. nil when there is none, it is on another site, or fetching it fails in any way.
    @MainActor
    private static func siteMarkdown(_ tab: Tab, _ webView: WKWebView, maxChars: Int, session: Session, approvedHost: String?) async -> ToolResult? {
        let found = await run(PageScripts.markdownAlternates, [:], in: webView, timeout: 5)
        guard !session.stopped, Approvals.site(of: tab.url) == approvedHost,
              !found.isError, let text = found.content.first?["text"] as? String,
              let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let page = (json["url"] as? String).flatMap(URL.init(string:)), let site = Approvals.site(of: page), Approvals.hasSite(site),
              let scheme = page.scheme?.lowercased(),
              let href = (json["links"] as? [String])?.compactMap(URL.init(string:)).first(where: { link in
                  Approvals.site(of: link) == site && ["https", scheme].contains(link.scheme?.lowercased() ?? "")
                      && [".md", ".markdown", ".txt"].contains { link.path(percentEncoded: false).lowercased().hasSuffix($0) }
              }) else { return nil }
        let fetched = await run(PageScripts.fetchMarkdown, ["href": href.absoluteString, "maxChars": maxChars], in: webView, timeout: 8)
        guard !session.stopped, !fetched.isError, let answer = fetched.content.first?["text"] as? String, !answer.isEmpty else { return nil }
        return fetched
    }
}
