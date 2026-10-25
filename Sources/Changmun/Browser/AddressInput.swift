import Foundation

/// Turns what was typed in the command bar into a page to load.
enum AddressInput {
    static var searchTemplate: String {
        UserDefaults.standard.string(forKey: "searchURL") ?? "https://www.google.com/search?q=%s"
    }

    static func resolve(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("about:") || lower.hasPrefix("file://") || lower.hasPrefix("data:") {
            return URL(string: text)
        }
        if text.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) != nil {
            return URL(string: text)
        }
        if !text.contains(" ") {
            if lower.hasPrefix("localhost") || lower.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil {
                return URL(string: "http://" + text)
            }
            if looksLikeHost(text) { return URL(string: "https://" + text) }
        }
        return searchURL(text)
    }

    static func searchURL(_ query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: encoded))
    }

    /// True when the input reads as an address rather than a search: `example.com`, `news.ycombinator.com/item?id=1`.
    static func isAddress(_ raw: String) -> Bool {
        guard let url = resolve(raw) else { return false }
        return url.absoluteString != searchURL(raw.trimmingCharacters(in: .whitespacesAndNewlines))?.absoluteString
    }

    private static func looksLikeHost(_ text: String) -> Bool {
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let parts = host.split(separator: ":").first?.split(separator: ".") ?? []
        guard parts.count >= 2, let tld = parts.last, tld.count >= 2 else { return false }
        return tld.allSatisfy(\.isLetter) && parts.allSatisfy { !$0.isEmpty }
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()
}
