import AppKit
import SwiftUI

/// A row's fill: selected, pressed, a drop landing in it, hovered, or none (tiles have a resting fill).
struct RowChrome: ViewModifier {
    let hover: Bool
    var selected = false
    var target = false
    var radius = Metrics.rowRadius
    var resting: Color = .clear
    @StateObject private var press = PressState()
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    func body(content: Content) -> some View {
        let pressed = press.isPressed
        content
            .background {
                if selected {
                    SelectedBackground(radius: radius, pressed: pressed)
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(target || pressed ? Theme.pressed : hover ? Theme.hoverTab : resting)
                }
            }
            .contentShape(Rectangle())
            .pressArea(press)
            // With Differentiate Without Color on, a selected row is told from the others by a mark and not by its fill alone.
            .overlay(alignment: .leading) {
                if selected && withoutColor { Capsule().fill(Theme.primary).frame(width: 3, height: 14).padding(.leading, 1) }  // grid-exempt: optical nudge of 1 pt
            }
    }
}

extension View {
    func rowChrome(hover: Bool, selected: Bool = false, target: Bool = false, radius: CGFloat = Metrics.rowRadius, resting: Color = .clear) -> some View {
        modifier(RowChrome(hover: hover, selected: selected, target: target, radius: radius, resting: resting))
    }

    /// A line where a dragged item would land: above a row, or before a tile.
    func dropLine(_ shown: Bool, edge: Edge = .top) -> some View {
        overlay(alignment: edge == .top ? .top : .leading) {
            if shown {
                let line = Capsule().fill(Theme.primary)
                Group {
                    if edge == .top {
                        line.frame(height: 2).padding(.horizontal, 4).offset(y: -2)
                    } else {
                        line.frame(width: 2).padding(.vertical, 4).offset(x: -5)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// "Open in" another browser on this Mac: for a site that only works in one of them.
struct OpenInMenu: View {
    let url: URL

    var body: some View {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url).filter {
            Bundle(url: $0)?.bundleIdentifier?.hasPrefix("io.github.namekun.Changmun") != true
        }
        if !apps.isEmpty {
            Menu("Open In") {
                ForEach(apps, id: \.self) { app in
                    Button(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")) {
                        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
        }
    }
}

/// "…" on a hovered row: the same menu as a right-click, for people who don't think to right-click.
struct MoreButton<Items: View>: View {
    /// In a row it is a small filled square; in a bar, a plain button the size of the bar's others.
    var inBar = false
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu(content: items) {
            Image(systemName: "ellipsis").font(inBar ? .symbolToolbar : .symbolInline)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: inBar ? Metrics.control : Metrics.action, height: inBar ? Metrics.control : Metrics.action)
        .background(RoundedRectangle(cornerRadius: inBar ? Metrics.rowRadius : 6, style: .continuous).fill(inBar ? .clear : Theme.field))
        .foregroundStyle(Theme.secondary)
        .help("More")
        .accessibilityLabel(String(localized: "More"))
    }
}

/// Bars and cards that float over the page (the command bar, find, a link preview): the same glass as the window,
/// with an edge and a soft shadow.
struct FloatingPanel: ViewModifier {
    let radius: CGFloat
    var modal = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // With Reduce Transparency on the page doesn't show through the panel.
        Group {
            if reduceTransparency { content.background(Theme.card, in: shape) } else { content.background(.regularMaterial, in: shape) }
        }
        .overlay(shape.strokeBorder(Theme.cardEdge, lineWidth: 0.5))
            .e2(!modal)
            .e3(modal)
    }
}

extension View {
    func floatingPanel(radius: CGFloat, modal: Bool = false) -> some View { modifier(FloatingPanel(radius: radius, modal: modal)) }
}

/// The app's three shadows. e1 lifts a selected row off the glass, e2 a chip, a popover or a bar over the page, e3 a modal.
extension View {
    func e1(_ shown: Bool = true) -> some View { shadow(color: shown ? Theme.selectedShadow : .clear, radius: 1, y: 1) }
    func e2(_ shown: Bool = true) -> some View { shadow(color: shown ? Theme.chipShadow : .clear, radius: 12, y: 4) }
    func e3(_ shown: Bool = true) -> some View { shadow(color: shown ? Theme.modalShadow : .clear, radius: 32, y: 16) }
}

/// A selected row or tile, raised a little off the glass.
struct SelectedBackground: View {
    var radius: CGFloat = Metrics.rowRadius
    var pressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(pressed ? Theme.pressed : Theme.selectedFill)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.selectedEdge, lineWidth: 0.5))
            .e1(!pressed)
    }
}

/// The window's ground: the desktop shows through it, blurred, as in Finder's sidebar.
struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A key as a keycap, quiet next to what it opens.
struct Keycap: View {
    let key: String
    /// On a button the ink fills (a PrimaryButton), the cap is drawn in the ground's colour.
    let onFill: Bool
    init(_ key: String, onFill: Bool = false) {
        self.key = key
        self.onFill = onFill
    }

    var body: some View {
        Text(verbatim: key).font(.caption).foregroundStyle(onFill ? Theme.background.opacity(0.8) : Theme.ink(0.7))
            .padding(.horizontal, 4).frame(minWidth: 20, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: Metrics.keycapRadius, style: .continuous).fill(onFill ? Theme.background.opacity(0.2) : Theme.field))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// The 3 pt bar, white on a faint track.
struct Meter: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.meter).frame(width: max(3, geo.size.width * min(1, max(0.05, fraction))))
            }
        }
        .frame(height: 3)
        .animation(Motion.standard, value: fraction)
    }
}

/// A site icon in its own colours; on black, a mostly dark one (GitHub, Threads) sits on a small white plate.
struct IconImage: View {
    let image: NSImage
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let plate = scheme == .dark && image.isMostlyDark
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .padding(plate ? size * 0.1 : 0)  // grid-exempt: a share of the icon size, not a gap
            .background { if plate { RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(.white) } }
            .frame(width: size, height: size)
    }
}

@MainActor private var darkIcons: [ObjectIdentifier: Bool] = [:]

extension NSImage {
    /// Whether the icon's visible pixels are dark on average (it would vanish on black).
    @MainActor var isMostlyDark: Bool {
        if let known = darkIcons[ObjectIdentifier(self)] { return known }
        let side = 16
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var total = 0.0, weight = 0.0
        for x in 0..<side {
            for y in 0..<side {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.3 else { continue }
                total += (0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent) * c.alphaComponent
                weight += c.alphaComponent
            }
        }
        let dark = weight > 0 && total / weight < 0.28
        darkIcons[ObjectIdentifier(self)] = dark
        return dark
    }
}

/// A small button inside a row: closing a tab, muting it.
struct HoverAction: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.symbolInline)
                .frame(width: Metrics.action, height: Metrics.action)
                .contentShape(Rectangle())
        }
        .buttonStyle(FillStyle(resting: Theme.field, hoverFill: Theme.pill, radius: Metrics.rowRadius))
        .foregroundStyle(Theme.secondary)
        .help(help)
        .accessibilityLabel(Accessibility.label(fromHelp: help))
    }
}

/// How tall a filled button is, from the grid: 32 where it is the page's one action, 28 in a bar or sheet, 24 inside a card.
enum ButtonSize {
    case large, regular, small

    var height: CGFloat {
        switch self {
        case .large: 32
        case .regular: Metrics.control
        case .small: 24
        }
    }

    var font: Font {
        switch self {
        case .large: .bodyStrong
        case .regular: .secondaryStrong
        case .small: .captionStrong
        }
    }
}

extension View {
    /// Pressed, a button settles to 97% in 100 ms; with Reduce Motion on only its fill changes.
    func pressScale(_ pressed: Bool) -> some View {
        scaleEffect(pressed && !Motion.reduced ? 0.97 : 1)
            .animation(Motion.reduced ? nil : Motion.press, value: pressed)
    }
}

/// A plain button that settles to 97% while it is pressed: a chip, a tile.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.pressScale(configuration.isPressed)
    }
}

/// The one filled button: ink on the ground, radius 12.
struct PrimaryButton: ButtonStyle {
    var size = ButtonSize.large
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 16)
            .frame(height: size.height)
            .background(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).fill(Theme.primary))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .pressScale(configuration.isPressed)
    }
}

/// The quieter button beside it: the field's fill with ink on it.
struct SecondaryButton: ButtonStyle {
    var size = ButtonSize.large
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 16)
            .frame(height: size.height)
            .background(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).fill(configuration.isPressed ? Theme.pressed : Theme.field))
            .opacity(enabled ? 1 : 0.4)
            .pressScale(configuration.isPressed)
    }
}

/// The filled button for deleting: the one place red is for, with the ground's colour on it.
struct DangerButton: ButtonStyle {
    var size = ButtonSize.large
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 16)
            .frame(height: size.height)
            .background(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).fill(Theme.danger))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .pressScale(configuration.isPressed)
    }
}

/// A button's fill: resting, hovered, and darker the moment it is pressed. A nil radius makes a capsule.
struct FillStyle: ButtonStyle {
    var resting: Color = .clear
    var hoverFill: Color = Theme.field
    var radius: CGFloat? = Metrics.rowRadius

    func makeBody(configuration: Configuration) -> some View {
        Filled(style: self, label: configuration.label, pressed: configuration.isPressed)
    }

    private struct Filled: View {
        let style: FillStyle
        let label: Configuration.Label
        let pressed: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let fill = pressed ? Theme.pressed : hover && enabled ? style.hoverFill : style.resting
            label
                .background {
                    if let radius = style.radius {
                        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
                    } else {
                        Capsule().fill(fill)
                    }
                }
                .onHover { hover = $0 }
        }
    }
}
