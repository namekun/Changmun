import AppKit
import SwiftUI

/// The small parts the start page is made of: a site's tile and the place of one to come. Each is a button for
/// VoiceOver and for the keyboard (the page keeps the keyboard's place, see `StartPageCursor`), and none of them asks a site for anything.

// MARK: Buttons

/// A part that is pressed: named for VoiceOver (a button, with its state as a value and what else it does as actions), drawn with a ring when
/// the keyboard is on it, and a click on it activates it (a ⌘-click asks for a new tab).
struct StartItemButton: ViewModifier {
    let label: String
    var value: String?
    var hint: String?
    var focused = false
    var radius: CGFloat = 12
    /// A tile sinks a little under the pointer; a row only changes its fill.
    var tile = false
    var actions: [AccessibleButton.Action] = []
    let activate: (_ inNewTab: Bool) -> Void
    @StateObject private var press = PressState()

    func body(content: Content) -> some View {
        content
            .overlay {
                if focused { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .contentShape(Rectangle())
            .pressArea(press)
            .pressScale(tile && press.isPressed)
            .onTapGesture { activate(Browser.commandClick) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value ?? "")
            .accessibilityHint(hint ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { activate(false) }
            .accessibilityActions { ForEach(actions) { action in Button(action.name, action: action.run) } }
    }
}

extension View {
    func startItem(_ label: String, value: String? = nil, hint: String? = nil, focused: Bool = false, radius: CGFloat = 12, tile: Bool = false,
                   actions: [AccessibleButton.Action] = [], activate: @escaping (_ inNewTab: Bool) -> Void) -> some View {
        modifier(StartItemButton(label: label, value: value, hint: hint, focused: focused, radius: radius, tile: tile, actions: actions, activate: activate))
    }
}

// MARK: Icons

/// A site's tile: its saved icon when that is good enough, a small one on a plate, else the first letter of the site. It reads what is kept
/// already and never asks the site for an icon, so showing the page sends no request.
struct StartIcon: View {
    let url: String
    let size: CGFloat
    /// The tile is a white plate of its own (a favorite's); else the icon stands where it is.
    var plate = true
    @State private var image: NSImage?
    @Environment(\.colorScheme) private var scheme

    /// The same eight colours as a space's tint, so a site's letter and a space are drawn from one palette.
    private static let letterColors = SpaceTint.allCases.map(\.color)

    var body: some View {
        let style = StartIconStyle.style(pixelWidth: image.map { Int($0.representations.map(\.pixelsWide).max() ?? Int($0.size.width)) })
        let radius = size * 0.24
        ZStack {
            switch style {
            case .full:
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(plate ? size * 0.2 : 0)  // grid-exempt: a share of the icon size, not a gap
                }
            case .plate:
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: size * 0.42, height: size * 0.42)
                }
            case .letter:
                Text(verbatim: StartIconStyle.letter(for: url))
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded)).foregroundStyle(.white)  // design-exempt: a share of the tile's size
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Self.letterColors[StartIconStyle.colorIndex(for: url, count: Self.letterColors.count)])
            }
        }
        .frame(width: size, height: size)
        .background { if style != .letter { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(plate || style == .plate ? Color.white : .clear) } }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay { if plate { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.black.opacity(scheme == .dark ? 0 : 0.08), lineWidth: 0.5) } }
        .e1(plate && scheme == .light)
        .onAppear { image = Browser.savedIcon(for: url) }
        .onChange(of: url) { image = Browser.savedIcon(for: url) }
        .accessibilityHidden(true)
    }
}

// MARK: Favorites

struct StartFavoriteTile: View {
    let entry: Library.Entry
    let size: CGFloat
    /// The room one tile has along the row: the icon and its name under it.
    let width: CGFloat
    var focused = false
    let open: (_ inNewTab: Bool) -> Void
    @State private var hover = false

    var body: some View {
        let name = Accessibility.bookmarkLabel(title: entry.title, url: entry.url)
        VStack(spacing: 8) {
            StartIcon(url: entry.url, size: size)
                .scaleEffect(hover ? 1.04 : 1)
                .animation(Motion.quick, value: hover)
            Text(verbatim: name).font(.secondary).foregroundStyle(Theme.secondary).lineLimit(1)
                .frame(width: width - 4)
        }
        .frame(width: width)
        .padding(.vertical, 4)
        .onHover { hover = $0 }
        .startItem(name, value: URL(string: entry.url)?.host().map(DisplayHost.trimmed), focused: focused, radius: Metrics.cardRadius, tile: true, activate: open)
    }
}

/// A dashed tile where a favorite will be.
struct StartEmptyFavorite: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .overlay { Image(systemName: "plus").font(.system(size: size * 0.32, weight: .regular)).foregroundStyle(Theme.tertiary) }  // design-exempt: a share of the tile's size
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
