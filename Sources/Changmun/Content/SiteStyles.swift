import Foundation
import WebKit

/// CSS the user wrote for one site, put in every page of that site and the hosts under it (Arc's Boosts, without the scripts). It lives in the
/// defaults on this Mac and goes nowhere else.
struct SiteStyle: Codable, Equatable, Identifiable {
    var id = UUID()
    /// The site as `Preferences.siteKey` writes it: lower case, without "www.". It covers that host and every host under it.
    var host: String
    var css: String
    /// Off keeps the CSS in the list without putting it in any page.
    var isOn = true

    static let defaultsKey = "siteStyles"
    /// The most CSS one style, all styles together, and the styles can have. Every page's script carries the rules of every style (the page's
    /// own host picks among them), and the defaults hold them as one value. Measured with 100 styles of 50,000 characters: a 4.8 MB script
    /// and a 4.8 MB value, too much for either. A tenth of that (100 styles, 500,000 characters in all) is well inside what both take.
    static let maxLength = 50_000
    static let maxTotal = 500_000
    static let maxCount = 100

    init(id: UUID = UUID(), host: String, css: String, isOn: Bool = true) {
        self.id = id
        self.host = host
        self.css = css
        self.isOn = isOn
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        host = try values.decode(String.self, forKey: .host)
        css = try values.decode(String.self, forKey: .css)
        isOn = try values.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
    }

    /// What the defaults hold: the styles that can be used, and every entry that can't (damaged, hand-edited, or no longer accepted, as a
    /// site that has become a public suffix), each as the JSON it was. Those are not thrown away: they are written back with the styles,
    /// looked at again at every start, and the settings say they are there.
    struct Loaded {
        var styles: [SiteStyle]
        var setAside: [String]
    }

    /// The styles stored in the defaults. Each is checked again as it is read, so a damaged or hand-edited entry is put aside by itself and
    /// no other, and no entry that could cover a whole kind of site gets to be put in a page. The limits on how many and how much are for
    /// what is added, not for what is already there.
    nonisolated static func load(in defaults: UserDefaults = .standard) -> Loaded {
        guard let stored = defaults.object(forKey: defaultsKey) else { return Loaded(styles: [], setAside: []) }
        guard let data = stored as? Data, let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            let text = (stored as? Data).map { String(decoding: $0, as: UTF8.self) } ?? String(describing: stored)
            return Loaded(styles: [], setAside: [json(text) ?? "null"])
        }
        var loaded = Loaded(styles: [], setAside: [])
        for entry in entries {
            if JSONSerialization.isValidJSONObject(entry), let data = try? JSONSerialization.data(withJSONObject: entry),
               let style = try? JSONDecoder().decode(SiteStyle.self, from: data),
               entryProblem(host: style.host, css: style.css, among: loaded.styles, ignoring: style.id) == nil, normalizedHost(style.host) == style.host {
                loaded.styles.append(style)
            } else {
                loaded.setAside.append(json(entry) ?? "null")
            }
        }
        return loaded
    }

    nonisolated static func stored(in defaults: UserDefaults = .standard) -> [SiteStyle] { load(in: defaults).styles }

    nonisolated static func store(_ styles: [SiteStyle], setAside: [String] = [], in defaults: UserDefaults = .standard) {
        let kept = styles.compactMap { try? JSONEncoder().encode($0) }.compactMap { try? JSONSerialization.jsonObject(with: $0) }
        let aside = setAside.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
        let all = kept + aside
        defaults.set(all.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: all), forKey: defaultsKey)
    }

    /// Any JSON value, a bare string or number too, as text.
    private nonisolated static func json(_ value: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Sites

    /// The site a typed address or host names: what comes after "https://" up to the first "/", "?" or "#", without a port, "www." or
    /// capitals. nil when there is no host in it.
    nonisolated static func normalizedHost(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        guard let host = URLComponents(string: text.contains("://") ? text : "https://" + text)?.host, !host.isEmpty,
              let name = PublicSuffix.normalized(host), !name.isEmpty else { return nil }
        return Preferences.siteKey(name)
    }

    /// Whether the page's host is the site or under it. The page's host is read as `normalizedHost` reads one, and the page script does the
    /// same on `location.hostname` (see `script(for:)`).
    nonisolated static func applies(site: String, to pageHost: String?) -> Bool {
        guard let pageHost, let page = PublicSuffix.normalized(pageHost) else { return false }
        let key = Preferences.siteKey(page)
        return key == site || key.hasSuffix("." + site)
    }

    /// A name no one registers a name under ("com", "co.kr", "github.io") would put the style in every site below it. "localhost" and addresses
    /// are single hosts. Without the list of such names, a name of one label is taken for one.
    private nonisolated static func isTooBroad(_ site: String) -> Bool {
        if site == "localhost" || site.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        guard let list = PublicSuffix.list else { return !site.contains(".") }
        return list.isPublicSuffix(site)
    }

    // MARK: Checks

    enum Problem: Equatable {
        case noSite, badSite, tooBroad, alreadyStyled, noCSS, tooLong, tooMuch, tooMany

        var reason: String {
            switch self {
            case .noSite: String(localized: "Give the site: its address, such as example.com.")
            case .badSite: String(localized: "That is not a site address.")
            case .tooBroad: String(localized: "That covers every site under it. Give one site, such as example.com.")
            case .alreadyStyled: String(localized: "That site already has a style. Edit it instead.")
            case .noCSS: String(localized: "Write the CSS to apply.")
            case .tooLong: String(localized: "That is too much CSS: the limit is \(SiteStyle.maxLength) characters.")
            case .tooMuch: String(localized: "All the styles together can hold \(SiteStyle.maxTotal.formatted()) characters of CSS, and this would be more. Shorten it, or remove another style.")
            case .tooMany: String(localized: "You can keep up to \(SiteStyle.maxCount) site styles. Remove one to add another.")
            }
        }
    }

    /// Why the two fields can't be added as a style, or nil when they can. `ignoring` is the style being edited.
    nonisolated static func problem(host: String, css: String, among others: [SiteStyle], ignoring id: UUID? = nil) -> Problem? {
        if let problem = entryProblem(host: host, css: css, among: others, ignoring: id) { return problem }
        let others = others.filter { $0.id != id }
        if others.count >= maxCount { return .tooMany }
        if others.reduce(css.count, { $0 + $1.css.count }) > maxTotal { return .tooMuch }
        return nil
    }

    /// What makes an entry no style at all, apart from how many there are: the same for what is added and what is read.
    nonisolated static func entryProblem(host: String, css: String, among others: [SiteStyle], ignoring id: UUID? = nil) -> Problem? {
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noSite }
        guard let site = normalizedHost(host), site.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }),
              !site.hasPrefix("."), !site.contains("..") else { return .badSite }
        if isTooBroad(site) { return .tooBroad }
        if others.contains(where: { $0.id != id && $0.host == site }) { return .alreadyStyled }
        if css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noCSS }
        if css.count > maxLength { return .tooLong }
        return nil
    }

    // MARK: In the page

    /// The CSS of every style that is on and covers `host`, the one for the wider site first so that the one for the narrower site wins a tie.
    nonisolated static func css(for host: String?, in styles: [SiteStyle]) -> String {
        rules(of: styles).filter { applies(site: $0[0], to: host) }.map { $0[1] }.joined(separator: "\n")
    }

    /// Each style that is on as a (site, CSS) pair, the wider site first.
    nonisolated static func rules(of styles: [SiteStyle]) -> [[String]] {
        styles.filter(\.isOn).enumerated().sorted { ($0.element.host.count, $0.offset) < ($1.element.host.count, $1.offset) }.map { [$0.element.host, $0.element.css] }
    }

    /// The script that puts the CSS in a page: it looks at where it is first and does nothing anywhere else. The CSS goes in as a constructed
    /// style sheet, not a <style> element, which a page's Content-Security-Policy can refuse. Running it again with other rules is how the
    /// open pages follow a change: it replaces the sheet it made, or takes it away when no rule covers the page any more.
    nonisolated static func script(for styles: [SiteStyle]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: rules(of: styles), options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
        return """
        (() => {
          const rules = \(String(decoding: data, as: UTF8.self));
          const host = location.hostname.toLowerCase().replace(/\\.$/, '').replace(/^www\\./, '');
          const css = rules.filter(([site]) => host === site || host.endsWith('.' + site)).map(([, text]) => text).join('\\n');
          let sheet = globalThis.changmunSiteSheet;
          if (!css) {
            if (sheet) document.adoptedStyleSheets = document.adoptedStyleSheets.filter((other) => other !== sheet);
            return;
          }
          if (!sheet) sheet = globalThis.changmunSiteSheet = new CSSStyleSheet();
          sheet.replaceSync(css);
          if (!document.adoptedStyleSheets.includes(sheet)) document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        })();
        """
    }
}

/// The user's site styles, and the web views they are put in. The script that puts the CSS in runs in a world of its own, which keeps its
/// variables out of the page's reach, but the style sheet it makes is part of the page's document (`document.adoptedStyleSheets`): the page's
/// own scripts can read its rules, and can take it away by setting `adoptedStyleSheets` (turning the style off and on again puts it back).
/// A style is put in the main frame only: a site's style is for its pages, not for the widgets of it that other sites embed.
@MainActor
final class SiteStyles: ObservableObject {
    static let shared = SiteStyles()
    static let world = WKContentWorld.world(name: "ChangmunSiteStyles")

    @Published private(set) var styles: [SiteStyle]
    /// The saved entries that can't be used (see `SiteStyle.Loaded`), kept until the user discards them.
    @Published private(set) var setAside: [String]
    private let defaults: UserDefaults
    /// Each web view configuration's scripts that this put in (none while no style is on), for as long as the configuration lives.
    private let installed = NSMapTable<WKUserContentController, NSMutableArray>.weakToStrongObjects()
    /// Whether to remove one script with WebKit's private call; a test turns it off to try the way without it.
    var usesPrivateRemoval = true
    /// The pages that are open, in every window. Tests that have no window say which they have.
    var openWebViews: () -> [WKWebView] = { Browser.all.flatMap(\.openTabs).compactMap(\.webView) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = SiteStyle.load(in: defaults)
        styles = loaded.styles
        setAside = loaded.setAside
    }

    /// Every web view configuration is made with this, so each page starts with the styles that are on.
    static func install(in controller: WKUserContentController) { shared.install(in: controller) }

    func install(in controller: WKUserContentController) {
        installed.setObject(NSMutableArray(), forKey: controller)
        addScript(to: controller)
    }

    /// The styles that cover a host, on or off.
    func styles(covering host: String?) -> [SiteStyle] {
        styles.filter { SiteStyle.applies(site: $0.host, to: host) }
    }

    /// Adds the style, or replaces the one with its id. The site is stored as `SiteStyle.normalizedHost` writes it. A style that can't be
    /// kept (see `SiteStyle.problem`) is not, and the answer says why.
    @discardableResult
    func save(_ style: SiteStyle) -> SiteStyle.Problem? {
        if let problem = SiteStyle.problem(host: style.host, css: style.css, among: styles, ignoring: style.id) { return problem }
        var style = style
        style.host = SiteStyle.normalizedHost(style.host) ?? style.host
        if let index = styles.firstIndex(where: { $0.id == style.id }) { styles[index] = style } else { styles.append(style) }
        commit()
        return nil
    }

    /// Changes the site and the CSS of the style with the id and nothing else: its switch stays as it is in the list now. A style that is gone
    /// (removed while it was being edited) is not made again.
    @discardableResult
    func update(_ id: UUID, host: String, css: String) -> SiteStyle.Problem? {
        guard var style = styles.first(where: { $0.id == id }) else { return nil }
        style.host = host
        style.css = css
        return save(style)
    }

    func discardSetAside() {
        guard !setAside.isEmpty else { return }
        setAside = []
        commit()
    }

    func remove(_ id: UUID) {
        styles.removeAll { $0.id == id }
        commit()
    }

    func setOn(_ isOn: Bool, for id: UUID) {
        guard let index = styles.firstIndex(where: { $0.id == id }), styles[index].isOn != isOn else { return }
        styles[index].isOn = isOn
        commit()
    }

    /// Turns every style that covers the host on or off together (the site settings' switch).
    func setOn(_ isOn: Bool, covering host: String?) {
        var changed = false
        for index in styles.indices where SiteStyle.applies(site: styles[index].host, to: host) && styles[index].isOn != isOn {
            styles[index].isOn = isOn
            changed = true
        }
        if changed { commit() }
    }

    private func commit() {
        SiteStyle.store(styles, setAside: setAside, in: defaults)
        refresh()
    }

    private func addScript(to controller: WKUserContentController) {
        guard styles.contains(where: \.isOn) else { return }
        let script = WKUserScript(source: SiteStyle.script(for: styles), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world)
        controller.addUserScript(script)
        installed.object(forKey: controller)?.add(script)
    }

    /// Takes out the script this put in, and no other: the page's other scripts (and an extension's) stay. WebKit has no public call to remove
    /// one script, so it is the private one when WebKit has it, else all are taken out and the others put back.
    private func removeScripts(from controller: WKUserContentController) {
        guard let ours = installed.object(forKey: controller) as? [WKUserScript], !ours.isEmpty else { return }
        installed.object(forKey: controller)?.removeAllObjects()
        let selector = NSSelectorFromString("_removeUserScript:")
        if usesPrivateRemoval && controller.responds(to: selector) {
            for script in ours { _ = controller.perform(selector, with: script) }
        } else {
            let others = controller.userScripts.filter { script in !ours.contains { $0 === script } }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
        }
    }

    /// The pages opened from now on get the new styles from their web view's scripts, and the pages open now are told.
    private func refresh() {
        for controller in installed.keyEnumerator().allObjects.compactMap({ $0 as? WKUserContentController }) {
            removeScripts(from: controller)
            addScript(to: controller)
        }
        let script = SiteStyle.script(for: styles)
        for webView in openWebViews() {
            webView.evaluateJavaScript(script, in: nil, in: Self.world) { _ in }
        }
    }
}
