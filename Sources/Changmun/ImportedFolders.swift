import Foundation

/// How imported bookmark folders are named. The folder name is the stored key (the library's `folder`, the spaces' pinned and
/// open lists, a bookmark tab's `bookmarkKey`), so it never depends on the language: the part naming where in the other browser
/// a folder was ("<Browser> Bookmarks Bar", "Arc Sidebar", "Safari / Favorites") is always the English word, and only what is
/// shown is translated. Older versions stored the label of the language the import ran in; `canonicalKey` maps those back.
/// A folder that matches the pattern is taken for an imported one: it is what the importer made, and a user folder that happens
/// to look the same can't be told apart.
enum ImportedFolders {
    static let barLabel = "Bookmarks Bar", otherLabel = "Other Bookmarks", mobileLabel = "Mobile Bookmarks"
    static let sidebarLabel = "Sidebar", favoritesLabel = "Favorites", menuLabel = "Bookmarks Menu"

    /// The stored name of the folder an import puts a Chromium browser's bookmarks bar (or the other roots) in.
    static func chromiumRoot(_ browser: String, _ label: String) -> String { browser + " " + label }

    /// What a canonical label reads as in the language the app runs in. The literals are what the strings tables are checked against.
    static func localized(_ label: String) -> String {
        switch label {
        case barLabel: String(localized: "Bookmarks Bar")
        case otherLabel: String(localized: "Other Bookmarks")
        case mobileLabel: String(localized: "Mobile Bookmarks")
        case sidebarLabel: String(localized: "Sidebar")
        case favoritesLabel: String(localized: "Favorites")
        case menuLabel: String(localized: "Bookmarks Menu")
        default: label
        }
    }

    private enum Scope {
        /// Any browser read from a Chromium profile, with the browser's name in front ("Chrome Bookmarks Bar").
        case chromium
        /// Arc's sidebar, which is not in its Bookmarks file.
        case arc
        /// Safari's two lists, which are the second part of the key ("Safari / Favorites").
        case safari
    }

    /// Each label, and what earlier versions stored for it in the other six languages (ko, ja, zh-Hans, es, de, fr), as in their strings
    /// tables. The English label is the same in every table, and is the canonical name.
    private static let sections: [(label: String, scope: Scope, earlier: [String])] = [
        (barLabel, .chromium, ["북마크 바", "ブックマークバー", "书签栏", "Barra de marcadores", "Lesezeichenleiste", "Barre de signets"]),
        (otherLabel, .chromium, ["기타 북마크", "その他のブックマーク", "其他书签", "Otros marcadores", "Weitere Lesezeichen", "Autres signets"]),
        (mobileLabel, .chromium, ["모바일 북마크", "モバイルのブックマーク", "移动设备书签", "Marcadores del móvil", "Mobile Lesezeichen", "Signets mobiles"]),
        (sidebarLabel, .arc, ["사이드바", "サイドバー", "边栏", "Barra lateral", "Seitenleiste", "Barre latérale"]),
        (favoritesLabel, .safari, ["즐겨찾기", "お気に入り", "个人收藏", "Favoritos", "Favoriten", "Favoris"]),
        (menuLabel, .safari, ["북마크 메뉴", "ブックマークメニュー", "书签菜单", "Menú Marcadores", "Lesezeichen-Menü", "Menu des signets"]),
    ]

    /// Every label of every language that earlier versions stored, by its canonical label.
    static var earlierLabels: [String: [String]] { Dictionary(uniqueKeysWithValues: sections.map { ($0.label, $0.earlier) }) }

    /// Where a key names an imported section: which part of the key holds it, the browser in front of it in that part (empty for
    /// Safari's), and the canonical label. With `earlier`, the labels of the other languages count too.
    private static func section(in parts: [String], earlier: Bool) -> (index: Int, head: String, label: String, found: String)? {
        for section in sections {
            for found in [section.label] + (earlier ? section.earlier : []) {
                switch section.scope {
                case .safari:
                    if parts.count > 1, parts[0] == "Safari", parts[1] == found { return (1, "", section.label, found) }
                case .arc:
                    if parts[0] == "Arc " + found { return (0, "Arc", section.label, found) }
                case .chromium:
                    let suffix = " " + found
                    guard parts[0].hasSuffix(suffix) else { continue }
                    let head = String(parts[0].dropLast(suffix.count))
                    if !head.isEmpty, head != "Safari", head != "Changmun" { return (0, head, section.label, found) }
                }
            }
        }
        return nil
    }

    /// The key an earlier version stored under another language's label, in the canonical form; nil when it is canonical already (or no import's).
    static func canonicalKey(_ key: String) -> String? {
        var parts = key.components(separatedBy: " / ")
        guard let hit = section(in: parts, earlier: true), hit.found != hit.label else { return nil }
        parts[hit.index] = hit.head.isEmpty ? hit.label : hit.head + " " + hit.label
        return parts.joined(separator: " / ")
    }

    /// What the user sees for a stored key: the section part in the current language, every other part as it is.
    static func displayKey(_ key: String, translate: (String) -> String = localized) -> String {
        var parts = key.components(separatedBy: " / ")
        guard let hit = section(in: parts, earlier: false) else { return key }
        parts[hit.index] = hit.head.isEmpty ? translate(hit.label) : hit.head + " " + translate(hit.label)
        return parts.joined(separator: " / ")
    }
}
