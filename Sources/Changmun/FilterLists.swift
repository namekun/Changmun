import Foundation
import WebKit

/// Turns Adblock Plus–style filter lists (EasyList and friends) into WebKit content rules.
/// Only what WebKit can express faithfully is kept; anything else is skipped rather than guessed.
enum FilterConverter {
    struct Output {
        var network: [[String: Any]] = []
        var cosmetic: [[String: Any]] = []
        var skipped = 0
    }

    /// WebKit refuses a list over 150,000 rules.
    static let maxRules = 140_000

    private static let resourceTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "font": "font", "media": "media",
        "xmlhttprequest": "raw", "ping": "ping", "websocket": "websocket", "popup": "popup", "other": "raw",
    ]

    private static let ignoredOptions: Set<String> = ["match-case", "important", "all", "~match-case"]

    static func convert(_ text: String, allowlist: [String] = []) -> Output {
        var out = Output()
        var exceptions: [[String: Any]] = []
        var genericSelectors: [String] = []
        var domainSelectors: [String: [String]] = [:]

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            if let at = line.range(of: "##") {
                guard !line.contains("#@#"), !line.contains("#?#"), !line.contains("#$#") else { out.skipped += 1; continue }
                let domains = String(line[..<at.lowerBound])
                let selector = String(line[at.upperBound...])
                guard isSafeSelector(selector) else { out.skipped += 1; continue }
                if domains.isEmpty {
                    genericSelectors.append(selector)
                } else if !domains.contains("~") {
                    domainSelectors[domains, default: []].append(selector)
                } else {
                    out.skipped += 1
                }
                continue
            }
            if line.contains("#@#") || line.contains("#?#") || line.contains("#$#") || line.contains("$$") { out.skipped += 1; continue }
            if line.hasPrefix("@@") {
                if let rule = networkRule(String(line.dropFirst(2)), action: "ignore-previous-rules") { exceptions.append(rule) } else { out.skipped += 1 }
            } else if let rule = networkRule(line, action: "block") {
                out.network.append(rule)
            } else {
                out.skipped += 1
            }
        }
        out.network += exceptions

        for chunk in stride(from: 0, to: genericSelectors.count, by: 250) {
            let selectors = genericSelectors[chunk..<min(chunk + 250, genericSelectors.count)].joined(separator: ", ")
            out.cosmetic.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": selectors]])
        }
        for (domains, selectors) in domainSelectors.sorted(by: { $0.key < $1.key }) {
            let list = domains.split(separator: ",").map { "*" + $0.trimmingCharacters(in: .whitespaces).lowercased() }
            out.cosmetic.append(["trigger": ["url-filter": ".*", "if-domain": list], "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")]])
        }

        for host in allowlist where !host.isEmpty {
            let off: [String: Any] = ["trigger": ["url-filter": ".*", "if-domain": ["*" + host.lowercased()]], "action": ["type": "ignore-previous-rules"]]
            out.network.append(off)
            out.cosmetic.append(off)
        }
        if out.network.count > maxRules { out.network = Array(out.network.prefix(maxRules)) }
        return out
    }

    /// One network filter (without a leading `@@`) as a WebKit rule, or nil when WebKit can't express it.
    static func networkRule(_ filter: String, action: String) -> [String: Any]? {
        var pattern = filter
        var options: [String] = []
        if let dollar = filter.lastIndex(of: "$") {
            let tail = filter[filter.index(after: dollar)...]
            // Options WebKit can't express (csp=…, redirect=…, removeparam=…) make the whole filter unusable.
            guard !tail.isEmpty, tail.allSatisfy({ $0.isLetter || $0.isNumber || ",=~|.-_*".contains($0) }) else { return nil }
            pattern = String(filter[..<dollar])
            options = tail.split(separator: ",").map { $0.lowercased() }
        }
        guard !pattern.isEmpty || options.contains(where: { $0.hasPrefix("domain=") }) else { return nil }
        // /regex/ filters use syntax WebKit's matcher doesn't support.
        if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count > 1 { return nil }

        var trigger: [String: Any] = [:]
        var types: [String] = []
        for option in options {
            if ignoredOptions.contains(option) { continue }
            if option == "third-party" || option == "3p" { trigger["load-type"] = ["third-party"]; continue }
            if option == "~third-party" || option == "1p" || option == "first-party" { trigger["load-type"] = ["first-party"]; continue }
            if option.hasPrefix("domain=") {
                let list = option.dropFirst("domain=".count).split(separator: "|").map(String.init)
                let excluded = list.filter { $0.hasPrefix("~") }.map { "*" + $0.dropFirst() }
                let included = list.filter { !$0.hasPrefix("~") }.map { "*" + $0 }
                if !excluded.isEmpty && !included.isEmpty { return nil }
                if !included.isEmpty { trigger["if-domain"] = included } else { trigger["unless-domain"] = excluded }
                continue
            }
            if option == "document" && action == "ignore-previous-rules" { continue }
            guard let type = resourceTypes[option] else { return nil }
            if !types.contains(type) { types.append(type) }
        }
        if !types.isEmpty { trigger["resource-type"] = types }
        trigger["url-filter"] = urlFilter(pattern)
        return ["trigger": trigger, "action": ["type": action]]
    }

    /// ABP pattern → the regex subset WebKit accepts (no alternation or counted repetition).
    static func urlFilter(_ pattern: String) -> String {
        if pattern.isEmpty { return ".*" }
        var rest = Substring(pattern)
        var regex = ""
        if rest.hasPrefix("||") {
            rest = rest.dropFirst(2)
            regex = "^[^:]+://+([^:/]+\\.)?"
        } else if rest.hasPrefix("|") {
            rest = rest.dropFirst()
            regex = "^"
        }
        var anchoredEnd = false
        if rest.hasSuffix("|") {
            rest = rest.dropLast()
            anchoredEnd = true
        }
        for char in rest {
            switch char {
            case "*": regex += ".*"
            case "^": regex += "[/:?&=]"
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "$", "|": regex += "\\" + String(char)
            default: regex.append(char)
            }
        }
        if anchoredEnd { regex += "$" }
        return regex
    }

    /// Plain CSS only: procedural extensions (:has-text, :-abp-…, :xpath…) would make WebKit reject the whole list.
    static func isSafeSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count < 400 else { return false }
        let banned = [":-abp-", ":has-text", ":contains", ":xpath", ":matches-css", ":style(", ":upward", ":remove(", "[-ext-",
                      ":nth-ancestor", ":min-text-length", ":watch-attr", ":matches-path", ":matches-attr", ":others", ":if(", ":if-not",
                      "+js(", ":matches-media", ":spath"]
        if banned.contains(where: selector.contains) { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_#.[]=\"'^$*~|:() >+,@/%")
        return selector.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// The filter lists the app keeps, their downloads and the compiled rule lists in WebKit.
@MainActor
final class AdBlocker: ObservableObject {
    static let shared = AdBlocker()

    struct List: Identifiable, Codable, Hashable {
        var id: String
        var name: String
        var url: String
    }

    static let builtIn = [
        List(id: "easylist", name: "EasyList (광고)", url: "https://easylist.to/easylist/easylist.txt"),
        List(id: "easyprivacy", name: "EasyPrivacy (추적)", url: "https://easylist.to/easylist/easyprivacy.txt"),
    ]

    @Published private(set) var status = ""
    @Published private(set) var working = false
    @Published private(set) var ruleCount = 0
    @Published private(set) var lastUpdated: Date? = UserDefaults.standard.object(forKey: "filtersUpdated") as? Date

    private var applied: [WKContentRuleList] = []

    static var folder: URL {
        let url = Library.folder.appendingPathComponent("filters", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var lists: [List] { Self.builtIn + Preferences.shared.customFilterLists.map { List(id: Self.customID($0), name: $0, url: $0) } }

    /// A file name that stays the same for the same address across launches.
    nonisolated static func customID(_ url: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "custom-" + String(hash, radix: 36)
    }
    var enabledLists: [List] { lists.filter { !Preferences.shared.disabledFilterLists.contains($0.id) } }

    /// At launch: use what was compiled last time, then refresh lists older than four days.
    func start() async {
        // The fixed tracker list of earlier versions now lives inside these rules.
        try? await WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: "changmun-trackers-v1")
        guard Preferences.shared.blockTrackers else { return await apply(enabled: false) }
        if await loadCompiled() {
            if (lastUpdated ?? .distantPast) < Date().addingTimeInterval(-4 * 86_400) { await update() }
        } else {
            await update()
        }
    }

    func apply(enabled: Bool) async {
        if enabled { await start() } else {
            remove()
            status = "꺼져 있어요"
        }
    }

    /// Downloads every enabled list (keeping the old copy when a download fails) and recompiles.
    func update() async {
        guard !working else { return }
        working = true
        status = "필터 목록을 받는 중…"
        var failed: [String] = []
        for list in enabledLists {
            guard let url = URL(string: list.url) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 100 else { throw URLError(.badServerResponse) }
                try data.write(to: Self.folder.appendingPathComponent(list.id + ".txt"))
            } catch {
                failed.append(list.name)
            }
        }
        lastUpdated = Date()
        UserDefaults.standard.set(lastUpdated, forKey: "filtersUpdated")
        working = false
        await recompile()
        if !failed.isEmpty { status = "받지 못한 목록: " + failed.joined(separator: ", ") + " (이전 것을 써요)" }
    }

    /// Rebuilds the rule lists from the saved filter files, the built-in tracker list and the per-site exceptions.
    func recompile() async {
        working = true
        status = "규칙을 만드는 중…"
        let files = enabledLists.map { Self.folder.appendingPathComponent($0.id + ".txt") }
        let allowlist = Preferences.shared.adBlockAllowlist
        let converted = await Task.detached(priority: .userInitiated) { () -> (String, String, Int) in
            var text = ContentBlocker.hosts.map { "||\($0)^$third-party" }.joined(separator: "\n")
            for file in files {
                if let content = try? String(contentsOf: file, encoding: .utf8) { text += "\n" + content }
            }
            let output = FilterConverter.convert(text, allowlist: allowlist)
            let network = String(data: try! JSONSerialization.data(withJSONObject: output.network), encoding: .utf8)!
            let cosmetic = String(data: try! JSONSerialization.data(withJSONObject: output.cosmetic), encoding: .utf8)!
            return (network, cosmetic, output.network.count + output.cosmetic.count)
        }.value
        let store = WKContentRuleListStore.default()!
        var lists: [WKContentRuleList] = []
        var errors: [String] = []
        for (identifier, json) in [("changmun-network", converted.0), ("changmun-cosmetic", converted.1)] {
            do {
                if let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { lists.append(list) }
            } catch {
                errors.append(identifier.hasSuffix("cosmetic") ? "요소 숨김" : "네트워크")
            }
        }
        working = false
        ruleCount = converted.2
        if Preferences.shared.blockTrackers { install(lists) }
        status = errors.isEmpty ? "규칙 \(ruleCount.formatted())개 적용 중" : "[ERROR] \(errors.joined(separator: ", ")) 규칙을 만들지 못했어요"
    }

    private func loadCompiled() async -> Bool {
        let store = WKContentRuleListStore.default()!
        var lists: [WKContentRuleList] = []
        for identifier in ["changmun-network", "changmun-cosmetic"] {
            if let list = try? await store.contentRuleList(forIdentifier: identifier) { lists.append(list) }
        }
        guard !lists.isEmpty else { return false }
        install(lists)
        status = "적용 중"
        return true
    }

    private func install(_ lists: [WKContentRuleList]) {
        remove()
        let controller = Browser.configuration.userContentController
        for list in lists { controller.add(list) }
        applied = lists
    }

    private func remove() {
        let controller = Browser.configuration.userContentController
        for list in applied { controller.remove(list) }
        applied = []
    }

    /// Turns blocking off (or back on) for one site, then rebuilds the rules.
    func toggleSite(_ host: String) {
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var allowlist = Preferences.shared.adBlockAllowlist
        if let index = allowlist.firstIndex(of: site) { allowlist.remove(at: index) } else { allowlist.append(site) }
        Preferences.shared.adBlockAllowlist = allowlist
        Task { await recompile() }
    }

    func isAllowed(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return Preferences.shared.adBlockAllowlist.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
