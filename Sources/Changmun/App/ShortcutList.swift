import AppKit
import SwiftUI

struct ShortcutRow: Identifiable, Equatable {
    var title: String
    var keys: String
    var id: String { title + "\n" + keys }
}

struct ShortcutGroup: Identifiable, Equatable {
    var title: String
    var rows: [ShortcutRow]
    var id: String { title }
}

/// What the Keyboard Shortcuts window lists. The keys are read from the menu itself, so the list cannot say anything the menu does not (and
/// follows the Safari or Chrome scheme the menu was built for); only the gestures, which no menu holds, are written out here.
enum ShortcutList {
    private static let f12 = String(Character(UnicodeScalar(NSF12FunctionKey)!))
    private static let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    private static let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))

    /// One group per menu, of the items that have keys. The same title with two keys is one row, and the nine numbered tabs (or spaces) are one.
    @MainActor
    static func groups(in menu: NSMenu) -> [ShortcutGroup] {
        menu.items.compactMap { top in
            guard let submenu = top.submenu else { return nil }
            var rows: [ShortcutRow] = []
            for item in submenu.items where !item.keyEquivalent.isEmpty {
                guard let keys = keys(of: item) else { continue }
                if let numbered = numberedTitle(of: item) {
                    if item.tag == 1 { rows.append(ShortcutRow(title: numbered, keys: keys + "–")) }
                    if item.tag == 9, let index = rows.firstIndex(where: { $0.title == numbered }) { rows[index].keys += item.keyEquivalent }
                } else if let index = rows.firstIndex(where: { $0.title == item.title }) {
                    rows[index].keys += " · " + keys
                } else {
                    rows.append(ShortcutRow(title: item.title, keys: keys))
                }
            }
            return rows.isEmpty ? nil : ShortcutGroup(title: submenu.title, rows: rows)
        }
    }

    @MainActor
    private static func numberedTitle(of item: NSMenuItem) -> String? {
        switch item.action {
        case #selector(AppDelegate.selectNumberedTab(_:)): String(localized: "Go to Tab 1–9")
        case #selector(AppDelegate.selectNumberedSpace(_:)): String(localized: "Go to Space 1–9")
        default: nil
        }
    }

    /// The gestures nobody can find in a menu.
    static var gestures: [ShortcutRow] {
        [ShortcutRow(title: String(localized: "Open a link in a background tab"), keys: String(localized: "⌘-click or middle-click")),
         ShortcutRow(title: String(localized: "Open a link in a new tab and go to it"), keys: String(localized: "⇧⌘-click")),
         ShortcutRow(title: String(localized: "Preview a link without leaving the page"), keys: String(localized: "⇧-click")),
         ShortcutRow(title: String(localized: "Back and forward"), keys: String(localized: "Mouse side buttons")),
         ShortcutRow(title: String(localized: "Switch space"), keys: String(localized: "Swipe with two fingers over the sidebar")),
         ShortcutRow(title: String(localized: "Rename a tab"), keys: String(localized: "Double-click it")),
         ShortcutRow(title: String(localized: "Open what you typed in a new tab"), keys: String(localized: "⌘Return in the search field"))]
    }

    /// A key equivalent as it is drawn in a menu: ⌃⌥⇧⌘ and then the key.
    static func keys(of item: NSMenuItem) -> String? {
        let key: String
        switch item.keyEquivalent {
        case "": return nil
        case f12: key = "F12"
        case left: key = "←"
        case right: key = "→"
        case "\t": key = "⇥"
        case let other: key = other.uppercased()
        }
        let mask = item.keyEquivalentModifierMask
        let marks = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return marks.filter { mask.contains($0.0) }.map(\.1).joined() + key
    }

    /// The guide on GitHub, in the language the app is shown in when the guide has been translated to it.
    static let guideLanguages = ["ko", "ja", "zh-Hans", "es", "de", "fr"]

    static func guideURL(localizations: [String] = Bundle.main.preferredLocalizations) -> URL {
        let base = "https://github.com/namekun/Changmun/blob/main/GUIDE"
        for language in localizations {
            let parts = language.split(separator: "-").map(String.init)
            let code = parts.first == "zh" ? "zh-Hans" : parts.first
            if let code, guideLanguages.contains(code) { return URL(string: "\(base).\(code).md")! }
            if code == "en" { break }
        }
        return URL(string: "\(base).md")!
    }
}
