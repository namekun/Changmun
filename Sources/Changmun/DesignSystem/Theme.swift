import AppKit
import SwiftUI

/// Nunsseop's look: a dark gray (or, in light mode, light gray) ground, ink at a few fixed opacities, hairlines,
/// and colour only where it means something: orange when something needs you, green while work is going on.
/// The page sits on a lighter card with its bar, filling the window beside the sidebar, so a dark site never runs into it.
enum Theme {
    private static let lightGround = NSColor(red: 0.925, green: 0.925, blue: 0.93, alpha: 1)
    private static let darkGround = NSColor(white: 0.13, alpha: 1)
    static let background = dynamic(light: lightGround, dark: darkGround)
    static let card = dynamic(light: .white, dark: NSColor(white: 0.2, alpha: 1))
    static let cardEdge = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.07))
    static let page = Color.white

    /// White on black, black on white.
    static func ink(_ opacity: Double) -> Color {
        dynamic(light: NSColor(white: 0, alpha: opacity), dark: NSColor(white: 1, alpha: opacity))
    }

    /// Quieter text and lines are drawn stronger when the user has asked for more contrast (System Settings › Accessibility › Display).
    static func boosted(_ opacity: Double, highContrast: Bool) -> Double { highContrast ? min(1, opacity * 0.6 + 0.4) : opacity }

    static func inkText(_ opacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let name = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let dark = name == .darkAqua || name == .accessibilityHighContrastDarkAqua
            let high = name == .accessibilityHighContrastAqua || name == .accessibilityHighContrastDarkAqua
            return NSColor(white: dark ? 1 : 0, alpha: boosted(opacity, highContrast: high))
        })
    }

    static let primary = ink(1)
    static let body = ink(0.9)
    static let secondary = inkText(0.6)
    /// For icons and marks that carry no words: at 0.5 it is too light to read as text (use `secondary`).
    static let tertiary = inkText(0.5)
    static let hairline = inkText(0.24)
    static let pill = ink(0.16)
    static let field = ink(0.1)
    static let selected = ink(0.08)
    static let hoverTab = ink(0.07)
    static let pressed = ink(0.13)
    /// A selected row stands up from the glass: white with a soft shadow on light, a brighter film on dark.
    static let selectedFill = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.14))
    static let selectedEdge = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.08))
    static let selectedShadow = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: .clear)
    /// Shadows of the two raised levels (see `e2` and `e3`): a blue-tinted ink on light, black on dark, where it has to be stronger to show.
    static let chipShadow = dynamic(light: NSColor(red: 0.12, green: 0.16, blue: 0.24, alpha: 0.12), dark: NSColor(white: 0, alpha: 0.35))
    static let modalShadow = dynamic(light: NSColor(red: 0.12, green: 0.16, blue: 0.24, alpha: 0.22), dark: NSColor(white: 0, alpha: 0.55))
    /// What a bar, card or sheet dims the page by: a light one for a bar over the page, a heavier one for a window-sized modal.
    static let scrim = Color.black.opacity(0.2)
    static let scrimModal = Color.black.opacity(0.32)
    static let track = ink(0.15)
    static let meter = ink(0.75)
    static let waiting = Color(red: 1.0, green: 0.62, blue: 0.2)
    /// The orange for text and small glyphs: `waiting` is too light to read on the light ground (about 2:1), so light mode gets a deeper one (4.5:1 or better on the ground and on a tinted chip).
    static let waitingText = dynamic(light: NSColor(red: 0.58, green: 0.30, blue: 0, alpha: 1), dark: NSColor(red: 1.0, green: 0.62, blue: 0.2, alpha: 1))

    /// Errors and success, for text and small glyphs: the light ones are deep enough for 4.5:1 on white, the ground and a tinted chip.
    static let danger = dynamic(light: NSColor(red: 0.74, green: 0.12, blue: 0.10, alpha: 1), dark: NSColor(red: 1.0, green: 0.45, blue: 0.42, alpha: 1))
    static let success = dynamic(light: NSColor(red: 0.06, green: 0.42, blue: 0.20, alpha: 1), dark: NSColor(red: 0.36, green: 0.84, blue: 0.52, alpha: 1))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

/// One device pixel thick.
struct Hairline: View {
    var vertical = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        let thickness = 1 / max(1, scale)
        Rectangle().fill(Theme.hairline)
            .frame(width: vertical ? thickness : nil, height: vertical ? nil : thickness)
            .accessibilityHidden(true)
    }
}

/// Sizes on a 4 pt grid, and spacing on an 8 pt grid with a 4 pt half step for tight gaps inside a component (scripts/test-scripts.sh checks it).
/// Rows share one height, and a row inside another steps in by one icon column, so its icon lines up with the text above it.
enum Metrics {
    /// From the window's edge to the sidebar's contents and to the AI panel's.
    static let inset: CGFloat = 8
    static let row: CGFloat = 28
    static let rowGap: CGFloat = 4
    static let rowPadding: CGFloat = 8
    static let icon: CGFloat = 16
    static let iconGap: CGFloat = 8
    static let indent: CGFloat = icon + iconGap
    /// Between the sidebar's parts: favorites, pinned folders, tabs, bookmarks.
    static let section: CGFloat = 16
    static let tile: CGFloat = 36
    /// Buttons and fields in a bar.
    static let control: CGFloat = 28
    /// Small buttons inside a row.
    static let action: CGFloat = 20
    /// Corner radii are 4, 8, 12 or 16, or a capsule: a keycap; a row or a small control; a field, card or button; a panel or modal.
    static let keycapRadius: CGFloat = 4
    static let rowRadius: CGFloat = 8
    static let fieldRadius: CGFloat = 12
    static let cardRadius: CGFloat = 12
    static let panelRadius: CGFloat = 16
}

/// Six sizes, three weights. A size has its regular or medium face and, where a line needs to stand out, a semibold one.
/// Nothing the app writes is smaller than `caption`; sizes under 11 are only for a badge drawn inside an icon (marked `design-exempt`).
extension Font {
    static let caption = Font.system(size: 11, weight: .medium)
    static let captionStrong = Font.system(size: 11, weight: .semibold)
    static let secondary = Font.system(size: 12)
    static let secondaryStrong = Font.system(size: 12, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let title = Font.system(size: 15, weight: .semibold)
    static let heading = Font.system(size: 20, weight: .semibold)
    static let display = Font.system(size: 28, weight: .semibold)
    static let row = body
    static let rowSelected = bodyStrong

    /// SF Symbols: 11 beside text, 13 in a bar, 16 leading a row, 20 in an empty state; always medium.
    static let symbolInline = Font.system(size: 11, weight: .medium)
    static let symbolToolbar = Font.system(size: 13, weight: .medium)
    static let symbolRow = Font.system(size: 16, weight: .medium)
    static let symbolEmpty = Font.system(size: 20, weight: .medium)
}

/// Springs without overshoot: they settle smoothly and, when interrupted, turn around from where they are. With
/// Reduce Motion on, things fade instead of moving.
@MainActor
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var standard: Animation { reduced ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1) }
    static var quick: Animation { reduced ? .easeOut(duration: 0.1) : .spring(response: 0.2, dampingFraction: 1) }
    /// For a change only the pointer should animate: a tab chosen with ⌘1-9, ⌃Tab or the command bar just happens, and the sidebar does
    /// not scroll or shuffle its rows to follow it.
    static var pointer: Animation? {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel, .swipe: standard
        default: nil
        }
    }
    /// A button sinking under the finger: quick, and without overshoot on the way back.
    static var press: Animation { .easeOut(duration: 0.1) }

    /// In from an edge and back out the same way.
    static func slide(_ edge: Edge) -> AnyTransition {
        reduced ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// A panel grows out of where it is anchored (a bar opening under the address, a card over the page).
    static func pop(_ anchor: UnitPoint) -> AnyTransition {
        reduced ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: anchor))
    }
}
