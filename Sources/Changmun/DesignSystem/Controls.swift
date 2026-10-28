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
                if selected && withoutColor { Capsule().fill(Theme.primary).frame(width: 3, height: 14).padding(.leading, 1) }
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
            Image(systemName: "ellipsis").font(.system(size: inBar ? 13 : 11, weight: .bold))
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            // With Reduce Transparency on the page doesn't show through the panel.
            .background { if reduceTransparency { shape.fill(Theme.card) } else { shape.fill(.regularMaterial) } }
            .overlay(shape.strokeBorder(Theme.cardEdge, lineWidth: 0.5))
            .shadow(color: Theme.cardShadow, radius: 16, y: 6)
    }
}

extension View {
    func floatingPanel(radius: CGFloat) -> some View { modifier(FloatingPanel(radius: radius)) }
}

/// A selected row or tile, raised a little off the glass.
struct SelectedBackground: View {
    var radius: CGFloat = Metrics.rowRadius
    var pressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(pressed ? Theme.pressed : Theme.selectedFill)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.selectedEdge, lineWidth: 0.5))
            .shadow(color: pressed ? .clear : Theme.selectedShadow, radius: 1, y: 1)
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
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(verbatim: key).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink(0.7))
            .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.field))
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
        .animation(.easeOut(duration: 0.2), value: fraction)
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
            .padding(plate ? size * 0.1 : 0)
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
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .frame(width: Metrics.action, height: Metrics.action)
                .contentShape(Rectangle())
        }
        .buttonStyle(FillStyle(resting: Theme.field, hoverFill: Theme.pill, radius: 6))
        .foregroundStyle(Theme.secondary)
        .help(help)
        .accessibilityLabel(Accessibility.label(fromHelp: help))
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
