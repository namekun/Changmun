import Foundation
import SwiftUI

/// Where the start page's favorites go and how many fit, how a site's icon is drawn, and where the keyboard is: plain values, so that the
/// rules can be tested without a window.

enum StartPageArrangement {
    /// The widest the page's column gets, and the room left at its sides.
    static let column: CGFloat = 620
    static let pageMargin: CGFloat = 24
    /// A favorite's icon, and the room its tile takes along the row.
    static let favoriteSize: CGFloat = 66
    static let favoritePitch: CGFloat = 90

    /// How many favorites the page shows: the row never runs wider than the column, so what does not fit is left to the sidebar.
    static func favoritesShown(count: Int, pageWidth: CGFloat) -> Int {
        let width = min(column, pageWidth - 2 * pageMargin)
        return min(count, max(1, Int(width / favoritePitch)))
    }

    /// The favorites' tiles, row by row. A row holds what the column fits. When there are more favorites than that, the one row ends in a "+N" tile
    /// (in the place of the last favorite that would have fit) that shows them all; shown, they run on in more rows and the last tile folds them back.
    struct FavoriteLayout: Equatable {
        /// The tiles on each row, by index: a favorite's own, then (when there is one) the tile that expands or folds.
        var rows: [Range<Int>]
        /// How many favorites are shown, and how many are not (the number on the "+N" tile).
        var shown: Int
        var hidden: Int
        /// Everything is shown, and there is more than one row's worth: the last tile folds the rows back to one.
        var folds: Bool

        var tiles: Int { rows.last?.upperBound ?? 0 }
        var hasActionTile: Bool { hidden > 0 || folds }
    }

    static func favoriteLayout(count: Int, pageWidth: CGFloat, expanded: Bool) -> FavoriteLayout {
        let width = min(column, pageWidth - 2 * pageMargin)
        let fit = max(1, Int(width / favoritePitch))
        guard count > fit else { return FavoriteLayout(rows: count > 0 ? [0..<count] : [], shown: count, hidden: 0, folds: false) }
        if expanded {
            let rows = stride(from: 0, to: count + 1, by: fit).map { $0..<min($0 + fit, count + 1) }
            return FavoriteLayout(rows: rows, shown: count, hidden: 0, folds: true)
        }
        let shown = max(1, fit - 1)
        return FavoriteLayout(rows: [0..<(shown + 1)], shown: shown, hidden: count - shown, folds: false)
    }
}

// MARK: Icons

enum StartIconStyle: Equatable {
    /// A good picture: the tile is filled with it.
    case full
    /// A small one: kept small on a white plate, so that it isn't blown up soft.
    case plate
    /// None: the first letter of the site.
    case letter

    /// By the widest side of the biggest picture the icon has, in pixels; nil when no icon is kept.
    static func style(pixelWidth: Int?) -> StartIconStyle {
        guard let pixelWidth else { return .letter }
        if pixelWidth >= 48 { return .full }
        return pixelWidth >= 12 ? .plate : .letter
    }

    /// The letter of a site's tile: the first letter or digit of its name, upper case ("?" if it has none).
    static func letter(for address: String) -> String {
        let host = URL(string: address)?.host() ?? address
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    }

    /// Which of `count` colours a site's letter tile has: the same one every time, whatever the process (`hashValue` is not).
    static func colorIndex(for address: String, count: Int) -> Int {
        let host = URL(string: address)?.host() ?? address
        let sum = host.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0xFFFFFF }
        return sum % max(1, count)
    }
}

// MARK: Keyboard

/// Which keys the page leaves to the search field: while something is typed in it (its suggestions are up), the arrows choose a suggestion
/// and ⇥ is the field's, not the page's, which would otherwise take them first and move among the favorites behind the list.
enum StartPageKeys {
    static func leavesToSearch(_ key: KeyEquivalent, typing: Bool, inSearch: Bool) -> Bool {
        guard typing, inSearch else { return false }
        return [KeyEquivalent.upArrow, .downArrow, .leftArrow, .rightArrow, .tab].contains(key)
    }
}

/// Where the keyboard is among the favorites when it is not in the search field. Pure, so the moves can be tested: ⇥ and ↓ go from the field to
/// the first tile, ← and → along the row, and ↑, ⇥ past the row or ⇧⇥ back to the field.
struct StartPageCursor: Equatable {
    /// The favorite the keyboard is on; nil is the search field.
    var item: Int?

    /// ⇥ (or ⇧⇥): from the field to the first favorite, and from a favorite back to the field.
    func tab(count: Int, backwards: Bool) -> StartPageCursor {
        item == nil && count > 0 ? StartPageCursor(item: 0) : StartPageCursor()
    }

    enum Arrow { case left, right, up, down }

    /// An arrow: along the row, stopping at its ends; up goes back to the field, down from the field to the first favorite.
    func move(_ arrow: Arrow, count: Int) -> StartPageCursor {
        guard let item else { return arrow == .down && count > 0 ? StartPageCursor(item: 0) : self }
        switch arrow {
        case .left: return StartPageCursor(item: max(0, item - 1))
        case .right: return StartPageCursor(item: min(count - 1, item + 1))
        case .up: return StartPageCursor()
        case .down: return self
        }
    }
}
