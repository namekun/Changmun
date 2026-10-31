import AppKit
import SwiftUI

/// The small parts the start page is made of: a site's tile, the cards and rows of its sections, the chips of the AI. Each is a button for
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
    var actions: [AccessibleButton.Action] = []
    let activate: (_ inNewTab: Bool) -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                if focused { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .contentShape(Rectangle())
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
    func startItem(_ label: String, value: String? = nil, hint: String? = nil, focused: Bool = false, radius: CGFloat = 12,
                   actions: [AccessibleButton.Action] = [], activate: @escaping (_ inNewTab: Bool) -> Void) -> some View {
        modifier(StartItemButton(label: label, value: value, hint: hint, focused: focused, radius: radius, actions: actions, activate: activate))
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

    private static let letterColors: [Color] = [
        Color(red: 0.36, green: 0.52, blue: 0.86), Color(red: 0.86, green: 0.46, blue: 0.36), Color(red: 0.33, green: 0.66, blue: 0.48), Color(red: 0.62, green: 0.46, blue: 0.88),
        Color(red: 0.88, green: 0.66, blue: 0.28), Color(red: 0.26, green: 0.66, blue: 0.72), Color(red: 0.86, green: 0.42, blue: 0.60), Color(red: 0.46, green: 0.52, blue: 0.62),
    ]

    var body: some View {
        let style = StartIconStyle.style(pixelWidth: image.map { Int($0.representations.map(\.pixelsWide).max() ?? Int($0.size.width)) })
        let radius = size * 0.24
        ZStack {
            switch style {
            case .full:
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(plate ? size * 0.2 : 0)
                }
            case .plate:
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: size * 0.42, height: size * 0.42)
                }
            case .letter:
                Text(verbatim: StartIconStyle.letter(for: url))
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Self.letterColors[StartIconStyle.colorIndex(for: url, count: Self.letterColors.count)])
            }
        }
        .frame(width: size, height: size)
        .background { if style != .letter { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(plate || style == .plate ? Color.white : .clear) } }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay { if plate { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.black.opacity(scheme == .dark ? 0 : 0.08), lineWidth: 0.5) } }
        .shadow(color: plate && scheme == .light ? Color.black.opacity(0.08) : .clear, radius: 3, y: 1)
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
            Text(verbatim: name).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1).startHalo()
                .frame(width: width - 4)
        }
        .frame(width: width)
        .padding(.vertical, 2)
        .onHover { hover = $0 }
        .startItem(name, value: URL(string: entry.url)?.host().map(DisplayHost.trimmed), focused: focused, radius: 12, activate: open)
    }
}

/// A dashed tile where a favorite will be.
struct StartEmptyFavorite: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .overlay { Image(systemName: "plus").font(.system(size: size * 0.32, weight: .regular)).foregroundStyle(Theme.faint) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: Continue

struct StartContinueCardView: View {
    let card: StartContinueCard
    let tint: SpaceTint
    var focused = false
    let now: Date
    let open: (_ inNewTab: Bool) -> Void
    let hide: () -> Void
    @State private var hover = false

    var body: some View {
        let host = URL(string: card.url)?.host().map(DisplayHost.trimmed) ?? card.url
        let when = StartPageTime.label(card.date, now: now)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                StartIcon(url: card.url, size: 32)
                Spacer(minLength: 8)
                if card.isClosedTab {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .bold))
                        Text("Closed Tab").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(tint.color)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(tint.color.opacity(0.16)))
                } else {
                    Text(verbatim: when).font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
            }
            Text(verbatim: card.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                .lineLimit(2).multilineTextAlignment(.leading).padding(.top, 10)
            Spacer(minLength: 6)
            Text(verbatim: card.isClosedTab ? "\(host) · \(when)" : host).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 130, alignment: .topLeading)
        .startPlate(radius: 12, fill: hover ? Theme.ink(0.08) : Theme.ink(0.045))
        .overlay(alignment: .topTrailing) { if hover { HideButton(action: hide).padding(6) } }
        .onHover { hover = $0 }
        .startItem(card.title, value: Accessibility.join([card.isClosedTab ? String(localized: "Closed Tab") : nil, host, when]),
                   hint: card.isClosedTab ? String(localized: "Reopens the tab") : nil, focused: focused, radius: 12,
                   actions: [AccessibleButton.Action(String(localized: "Hide from This Page"), hide)], activate: open)
    }
}

/// A row of the same card, for the narrow pages.
struct StartContinueRowView: View {
    let card: StartContinueCard
    let tint: SpaceTint
    var focused = false
    let now: Date
    let open: (_ inNewTab: Bool) -> Void
    let hide: () -> Void
    @State private var hover = false

    var body: some View {
        let host = URL(string: card.url)?.host().map(DisplayHost.trimmed) ?? card.url
        let when = StartPageTime.label(card.date, now: now)
        HStack(spacing: 10) {
            StartIcon(url: card.url, size: 22, plate: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: card.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                Text(verbatim: card.isClosedTab ? "\(host) · \(when)" : host).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            if hover {
                HideButton(action: hide)
            } else if card.isClosedTab {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .bold))
                    Text("Closed Tab").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(tint.color)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(tint.color.opacity(0.16)))
            } else {
                Text(verbatim: when).font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.hoverTab : .clear))
        .onHover { hover = $0 }
        .startItem(card.title, value: Accessibility.join([card.isClosedTab ? String(localized: "Closed Tab") : nil, host, when]),
                   hint: card.isClosedTab ? String(localized: "Reopens the tab") : nil, focused: focused, radius: 8,
                   actions: [AccessibleButton.Action(String(localized: "Hide from This Page"), hide)], activate: open)
    }
}

/// The ✕ a card shows under the pointer: takes it off the page.
struct HideButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.pressed))
        }
        .buttonStyle(.plain)
        .help("Hide from This Page")
        .accessibilityLabel(String(localized: "Hide from This Page"))
    }
}

// MARK: Reading list and frequent

struct StartReadingRow: View {
    let item: ReadingItem
    var focused = false
    let now: Date
    let open: (_ inNewTab: Bool) -> Void
    @State private var hover = false

    var body: some View {
        let site = ReadingList.siteName(of: item.url)
        let added = ReadingList.dateLabel(item.added, now: now)
        HStack(spacing: 10) {
            StartIcon(url: item.url, size: 22, plate: false)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: item.title).font(.system(size: 13, weight: item.read ? .regular : .semibold))
                        .foregroundStyle(item.read ? Theme.secondary : Theme.primary).lineLimit(1)
                    if !item.read { Circle().fill(Theme.primary).frame(width: 6, height: 6) }
                }
                Text(verbatim: "\(site) · \(added)").font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.hoverTab : .clear))
        .onHover { hover = $0 }
        .startItem(item.title, value: Accessibility.readingValue(read: item.read, site: site, added: added), focused: focused, radius: 8, activate: open)
    }
}

struct StartFrequentRow: View {
    let site: StartFrequentSite
    let most: Int
    var focused = false
    let open: (_ inNewTab: Bool) -> Void
    let hide: () -> Void
    @State private var hover = false

    var body: some View {
        let visits = site.visits == 1 ? String(localized: "1 visit") : String(localized: "\(site.visits) visits")
        HStack(spacing: 10) {
            StartIcon(url: site.url, size: 22, plate: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: site.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                Text(verbatim: site.host).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            if hover {
                HideButton(action: hide)
            } else {
                Capsule().fill(Theme.track).frame(width: 60, height: 3)
                    .overlay(alignment: .leading) { Capsule().fill(Theme.meter).frame(width: 60 * CGFloat(site.visits) / CGFloat(max(most, 1)), height: 3) }
                Text(verbatim: visits).font(.system(size: 11)).foregroundStyle(Theme.dim).frame(minWidth: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.hoverTab : .clear))
        .onHover { hover = $0 }
        .startItem(site.title, value: Accessibility.join([site.host, visits]), focused: focused, radius: 8,
                   actions: [AccessibleButton.Action(String(localized: "Hide from This Page"), hide)], activate: open)
    }
}

// MARK: The AI's chips and cards

struct StartAIChip: View {
    let suggestion: StartAISuggestion
    var focused = false
    let send: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.primary)
            Text(verbatim: suggestion.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.primary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .startPlate(radius: 14, fill: hover ? Theme.ink(0.1) : Theme.ink(0.05))
        .onHover { hover = $0 }
        .startItem(String(localized: "Ask AI: \(suggestion.title)"), focused: focused, radius: 14) { _ in send() }
    }
}

struct StartAICard: View {
    let suggestion: StartAISuggestion
    let tint: SpaceTint
    var focused = false
    let send: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: suggestion.symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(tint.color)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.color.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: suggestion.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                Text(verbatim: suggestion.detail).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
        .startPlate(radius: 10, fill: hover ? Theme.ink(0.09) : Theme.ink(0.045))
        .onHover { hover = $0 }
        .startItem(String(localized: "Ask AI: \(suggestion.title)"), value: suggestion.detail, focused: focused, radius: 10) { _ in send() }
    }
}

// MARK: Headings

struct StartHeading: View {
    let title: String
    var detail: String?
    var linkTitle: String?
    var link: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).startHalo()
                .accessibilityAddTraits(.isHeader)
            if let detail { Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(Theme.dim).startHalo() }
            Spacer(minLength: 8)
            if let linkTitle, let link {
                Button(action: link) { Text(verbatim: linkTitle).font(.system(size: 12)).foregroundStyle(Theme.secondary).startHalo() }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Accessibility.join([linkTitle, title]))
            }
        }
    }
}
