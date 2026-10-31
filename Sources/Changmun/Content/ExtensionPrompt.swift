import Foundation

/// What the questions about an extension's permissions say. Allow grants everything the extension asked for, so the question lists all of it:
/// every entry whole, broad patterns first. What cannot be shown whole (too many entries, or one too long) is counted and said, and then the
/// question has no Allow, only the safe answer.
enum ExtensionPrompt {
    /// How many entries, how many characters in all, and how long one entry may be, before the rest is not shown.
    static let maxItems = 300
    static let maxCharacters = 12_000
    static let itemLimit = 300

    /// A pattern that reaches every site, or every site of a scheme, which the question says in words.
    static func isAllSites(_ pattern: String) -> Bool {
        pattern == "<all_urls>" || ["*://*/", "http://*/", "https://*/"].contains { pattern.hasPrefix($0) }
    }

    /// A pattern that reaches a great many sites: all of them, a whole top-level domain ("*://*.com/*"), or any host of a scheme.
    static func isBroad(_ pattern: String) -> Bool {
        if isAllSites(pattern) { return true }
        guard let schemeEnd = pattern.range(of: "://") else { return false }
        let host = pattern[schemeEnd.upperBound...].prefix { $0 != "/" }
        return host == "*" || (host.hasPrefix("*.") && !host.dropFirst(2).contains("."))
    }

    /// The entries as lines (cleaned of what hides or reorders text), broad ones first, and how many could not be shown whole.
    static func listing(_ items: [String], separator: String = "\n") -> (text: String, hidden: Int) {
        let ordered = items.sorted { (isBroad($0) ? 0 : 1, $0) < (isBroad($1) ? 0 : 1, $1) }
        var shown: [String] = [], hidden = 0, characters = 0
        for item in ordered {
            let cleaned = Approvals.shown(item, limit: itemLimit)
            if cleaned.cut > 0 || shown.count >= maxItems || characters + cleaned.text.count > maxCharacters {
                hidden += 1
            } else {
                shown.append(cleaned.text)
                characters += cleaned.text.count
            }
        }
        return (shown.joined(separator: separator), hidden)
    }

    /// The buttons: the safe one first (what Return and Esc do), and Allow only when nothing is left out.
    private static func buttons(safe: String, allow: String, hidden: Int) -> [DialogButton] {
        [DialogButton(title: safe, role: .cancel, isDefault: true)] + (hidden == 0 ? [DialogButton(title: allow)] : [])
    }

    private static func notShown(_ hidden: Int) -> String {
        String(localized: "\(hidden) more are not shown here, so this can't be allowed.")
    }

    /// Turning an extension on, or allowing what an update adds: the sites and the permissions it asks for.
    static func permissionsSpec(name: String, hosts: [String], permissions: [String], updating: Bool) -> DialogSpec {
        let name = DialogSpec.name(name)
        let sites = listing(hosts)
        let granted = listing(permissions, separator: ", ")
        let hidden = sites.hidden + granted.hidden
        var lines: [String] = []
        if hosts.contains(where: isAllSites) {
            lines.append(String(localized: "It can read and change the content of all websites."))
        } else if !hosts.isEmpty {
            lines.append(String(localized: "It can read and change the content of the sites listed below."))
        }
        if hidden > 0 { lines.append(notShown(hidden)) }
        var detail: [String] = []
        if !sites.text.isEmpty { detail.append(sites.text) }
        if !granted.text.isEmpty { detail.append(String(localized: "Permissions: \(granted.text)")) }
        return DialogSpec(title: updating ? String(localized: "'\(name)' is updating and asks for more permissions") : String(localized: "Turn on '\(name)'?"),
                          message: lines.isEmpty ? nil : lines.joined(separator: " "),
                          detail: detail.isEmpty ? nil : .text(detail.joined(separator: "\n\n")),
                          buttons: buttons(safe: updating ? String(localized: "Use Previous Permissions Only") : String(localized: "Cancel"),
                                           allow: updating ? String(localized: "Allow") : String(localized: "Turn On"), hidden: hidden))
    }

    /// What an extension asks for while it runs: the sites, or the permissions, that Allow would give it, one to a line.
    static func askSpec(_ title: String, items: [String]) -> DialogSpec {
        let listed = listing(items)
        return DialogSpec(title: title, message: listed.hidden > 0 ? notShown(listed.hidden) : nil, detail: listed.text.isEmpty ? nil : .text(listed.text),
                          buttons: buttons(safe: String(localized: "Deny"), allow: String(localized: "Allow"), hidden: listed.hidden))
    }
}
