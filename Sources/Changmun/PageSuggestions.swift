import SwiftUI
import WebKit

/// What kind of page is in front, told cheaply (from its address and a few things in the page, with no AI call) so that the panel's
/// suggestions fit it. A guess: it only picks which suggestions are shown, and tapping one only fills the box.
enum PageKind: Equatable {
    case general, video, article, product, form, search

    /// What the page says about itself, read by `probe`.
    struct Signals: Equatable {
        var ogType = ""
        var ldTypes: [String] = []
        /// Videos on the page that are big enough to be the page's point.
        var videos = 0
        /// The most fields (text, email, number, date, choices...) any one form that isn't a search has.
        var fields = 0
        var articleCharacters = 0

        init(ogType: String = "", ldTypes: [String] = [], videos: Int = 0, fields: Int = 0, articleCharacters: Int = 0) {
            self.ogType = ogType
            self.ldTypes = ldTypes
            self.videos = videos
            self.fields = fields
            self.articleCharacters = articleCharacters
        }

        init(_ answer: [String: Any]) {
            self.init(ogType: (answer["og"] as? String ?? "").lowercased(), ldTypes: answer["types"] as? [String] ?? [],
                      videos: (answer["videos"] as? NSNumber)?.intValue ?? 0, fields: (answer["fields"] as? NSNumber)?.intValue ?? 0,
                      articleCharacters: (answer["articleChars"] as? NSNumber)?.intValue ?? 0)
        }
    }

    /// The kind of page at this address, with what `probe` found in it when that is known. The address decides first (a results
    /// page or a video page is known by where it is), then what the page says it is, then what it looks like.
    static func classify(url: URL?, signals: Signals?) -> PageKind {
        guard let url, url.scheme == "http" || url.scheme == "https" else { return .general }
        if isSearch(url) { return .search }
        if isVideo(url) { return .video }
        if isProduct(url) { return .product }
        guard let signals else { return .general }
        let types = Set(signals.ldTypes.map { $0.lowercased() })
        if signals.ogType.hasPrefix("video") || types.contains("videoobject") { return .video }
        if signals.ogType == "product" || !types.isDisjoint(with: ["product", "productgroup", "individualproduct"]) { return .product }
        if signals.ogType == "article" || !types.isDisjoint(with: ["article", "newsarticle", "blogposting"]) { return .article }
        if signals.fields >= 3 { return .form }
        if signals.videos >= 1 { return .video }
        if signals.articleCharacters >= 1500 { return .article }
        return .general
    }

    private static func host(_ url: URL) -> String { (url.host() ?? "").lowercased() }

    private static func hostIs(_ url: URL, _ names: [String]) -> Bool {
        let host = host(url)
        return names.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func hasQuery(_ url: URL, _ names: [String]) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { names.contains($0.name) && !($0.value ?? "").isEmpty }
    }

    static func isSearch(_ url: URL) -> Bool {
        let path = url.path.lowercased(), host = host(url)
        if host.contains("google.") || hostIs(url, ["bing.com", "brave.com", "ecosia.org", "kagi.com"]) {
            return path == "/search" && hasQuery(url, ["q"])
        }
        if hostIs(url, ["duckduckgo.com"]) { return hasQuery(url, ["q"]) }
        if hostIs(url, ["naver.com"]) && host.hasPrefix("search.") { return hasQuery(url, ["query"]) }
        if hostIs(url, ["daum.net"]) && host.hasPrefix("search.") { return hasQuery(url, ["q"]) }
        if hostIs(url, ["yahoo.com", "yahoo.co.jp"]) && host.hasPrefix("search.") { return hasQuery(url, ["p"]) }
        if hostIs(url, ["baidu.com"]) { return path == "/s" && hasQuery(url, ["wd"]) }
        if hostIs(url, ["yandex.com", "yandex.ru"]) { return path.hasPrefix("/search") && hasQuery(url, ["text"]) }
        if hostIs(url, ["youtube.com"]) { return path == "/results" && hasQuery(url, ["search_query"]) }
        return false
    }

    static func isVideo(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if hostIs(url, ["youtube.com"]) { return (path == "/watch" && hasQuery(url, ["v"])) || path.hasPrefix("/shorts/") }
        if hostIs(url, ["youtu.be"]) { return path.count > 1 }
        if hostIs(url, ["vimeo.com"]) { return path.dropFirst().first?.isNumber == true }
        if hostIs(url, ["twitch.tv"]) { return path.hasPrefix("/videos/") }
        if hostIs(url, ["bilibili.com", "dailymotion.com"]) { return path.hasPrefix("/video/") }
        if hostIs(url, ["netflix.com"]) { return path.hasPrefix("/watch/") }
        if hostIs(url, ["tv.naver.com"]) { return path.hasPrefix("/v/") }
        return false
    }

    static func isProduct(_ url: URL) -> Bool {
        let path = url.path.lowercased(), host = host(url)
        if host.contains("amazon.") { return path.contains("/dp/") || path.contains("/gp/product/") }
        if hostIs(url, ["coupang.com"]) { return path.hasPrefix("/vp/products/") }
        if host.contains("ebay.") { return path.hasPrefix("/itm/") }
        if host.contains("aliexpress.") { return path.contains("/item/") }
        if hostIs(url, ["etsy.com"]) { return path.contains("/listing/") }
        if hostIs(url, ["walmart.com"]) { return path.hasPrefix("/ip/") }
        if hostIs(url, ["11st.co.kr"]) { return path.hasPrefix("/products/") }
        if hostIs(url, ["gmarket.co.kr"]) { return host.hasPrefix("item.") }
        if hostIs(url, ["naver.com"]) { return path.contains("/products/") && (host.hasPrefix("smartstore.") || host.hasPrefix("brand.")) }
        if hostIs(url, ["danawa.com"]) { return host.hasPrefix("prod.") }
        return false
    }

    /// Reads a few things from the page (in the app's own world, so the page's scripts can't answer in its place; nothing is changed
    /// and nothing leaves the Mac).
    static let probe = """
    const q = s => document.querySelector(s);
    const meta = k => { const e = q('meta[property="' + k + '"],meta[name="' + k + '"]'); return e ? (e.content || '') : ''; };
    const types = [];
    const walk = n => {
      if (!n || typeof n !== 'object' || types.length > 40) return;
      if (Array.isArray(n)) return n.forEach(walk);
      if (n['@type']) [].concat(n['@type']).forEach(t => types.push(String(t)));
      if (n['@graph']) walk(n['@graph']);
    };
    for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
      if (s.textContent.length < 300000) { try { walk(JSON.parse(s.textContent)); } catch (e) {} }
    }
    const shown = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const videos = [...document.querySelectorAll('video')].filter(v => { const r = v.getBoundingClientRect(); return r.width >= 320 && r.height >= 180; }).length;
    const skip = ['hidden', 'submit', 'button', 'reset', 'image', 'checkbox', 'radio', 'password', 'search', 'file'];
    let fields = 0;
    for (const f of document.forms) {
      if (f.getAttribute('role') === 'search') continue;
      const n = [...f.querySelectorAll('input,textarea,select')].filter(e => !e.disabled && !skip.includes((e.type || '').toLowerCase()) && shown(e)).length;
      fields = Math.max(fields, n);
    }
    const article = q('article');
    return { og: meta('og:type'), types: types, videos: videos, fields: fields, articleChars: article ? (article.innerText || '').length : 0 };
    """

    /// The kind of the tab's page: by its address at once, and again with what is in the page once that has loaded.
    @MainActor
    static func detect(_ tab: Tab, probing: Bool) async -> PageKind {
        guard probing, !tab.isPrivate, let webView = tab.webView else { return classify(url: tab.url, signals: nil) }
        let answer = try? await webView.callAsyncJavaScript(probe, contentWorld: .defaultClient) as? [String: Any]
        return classify(url: tab.url, signals: answer.map(Signals.init))
    }

    /// The suggestions for this kind of page: two that fit it and one more that is always of use.
    var prompts: [String] {
        switch self {
        case .general:
            [String(localized: "Summarize this page in three lines"), String(localized: "Pick out only the important links on this page"),
             String(localized: "Sort out my open tabs and tell me about them")]
        case .video:
            [String(localized: "Summarize this video's description and comments"), String(localized: "Pull out the links mentioned in the description"),
             String(localized: "Sort out my open tabs and tell me about them")]
        case .article:
            [String(localized: "Summarize this article in three lines"), String(localized: "List the key points of this article"),
             String(localized: "Pick out only the important links on this page")]
        case .product:
            [String(localized: "Compare this product with similar ones"), String(localized: "Sum up the specs and reviews of this product"),
             String(localized: "Summarize this page in three lines")]
        case .form:
            [String(localized: "Help me fill this form"), String(localized: "Explain what this form is asking for"),
             String(localized: "Summarize this page in three lines")]
        case .search:
            [String(localized: "Open the top 3 results and compare"), String(localized: "Summarize what the top results say"),
             String(localized: "Sort out my open tabs and tell me about them")]
        }
    }
}

/// Works out the kind of the tab in front for the panel's suggestions, and keeps it up to date as that tab loads and moves. It draws nothing.
struct PageKindProbe: View {
    @ObservedObject var tab: Tab
    @Binding var kind: PageKind

    private struct Page: Equatable {
        var id: Int
        var url: URL?
        var loading: Bool
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: Page(id: tab.id, url: tab.url, loading: tab.isLoading)) {
                kind = await PageKind.detect(tab, probing: false)
                guard !tab.isLoading else { return }
                // A page that builds itself after it has loaded (a single-page site) is given a moment.
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                kind = await PageKind.detect(tab, probing: true)
            }
    }
}
