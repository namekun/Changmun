import AppKit
import SwiftUI

enum SpaceSheetMode: Hashable {
    case new
    case edit(UUID)
}

/// A space's symbol or emoji.
struct SpaceIcon: View {
    let space: Space
    var size: CGFloat = 13

    var body: some View {
        if space.isEmoji {
            // An emoji keeps its own colours, whatever the row around it is tinted.
            Text(space.symbol).font(.system(size: size)).foregroundStyle(.primary)  // design-exempt: drawn to the size of the plate it sits on
        } else {
            Image(systemName: space.symbol).font(.system(size: size, weight: .medium))  // design-exempt: drawn to the size of the plate it sits on
        }
    }
}

/// The space's colour over the sidebar's glass, faint enough to read as a tint.
struct SpaceGlass: View {
    let tint: SpaceTint
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        tint.color.opacity(scheme == .dark ? 0.11 : 0.12).allowsHitTesting(false)
    }
}

/// The sidebar's list slides in from the side the new space is on; with Reduce Motion it fades.
struct SpaceSlide: ViewModifier {
    let spaceID: UUID
    let direction: Int
    @State private var offset: CGFloat = 0
    @State private var opacity = 1.0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .opacity(opacity)
            .clipped()
            .onChange(of: spaceID) {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    offset = Motion.reduced ? 0 : CGFloat(direction) * 40
                    opacity = 0
                }
                DispatchQueue.main.async {
                    withAnimation(Motion.standard) {
                        offset = 0
                        opacity = 1
                    }
                }
            }
    }
}

/// The bottom row of the sidebar: the space shown by its symbol and name in plain ink, the others as symbols, and a plus to make one.
struct SpaceSwitcher: View {
    @ObservedObject var browser: Browser

    var body: some View {
        // Centred while it fits; with many spaces it scrolls sideways, to the one shown.
        ViewThatFits(in: .horizontal) {
            row.frame(maxWidth: .infinity)
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .onAppear { scroller.scrollTo(browser.spaceID, anchor: .center) }
                    .onChange(of: browser.spaceID) { _, id in withAnimation(Motion.standard) { scroller.scrollTo(id, anchor: .center) } }
            }
        }
        .animation(Motion.standard, value: browser.spaceID)
        .animation(Motion.standard, value: browser.spaces.spaces)
    }

    private var row: some View {
        let spaces = browser.spaces.spaces
        return HStack(spacing: 4) {
            ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                Group {
                    if space.id == browser.spaceID {
                        chip(space)
                    } else {
                        dot(space, number: index + 1)
                    }
                }
                .id(space.id)
                .dropDestination(for: SidebarDrop.self) { items, _ in SidebarDrag.drop(items.texts, onSpace: space.id, browser: browser) }
                .contextMenu {
                    Button("Edit Space…") { browser.spaceSheet = .edit(space.id) }
                    if spaces.count > 1 {
                        Divider()
                        Button("Delete Space…") { Self.confirmDelete(space, in: browser) }
                    }
                }
            }
            BarButton(symbol: "plus", help: String(localized: "New Space…")) { browser.spaceSheet = .new }
        }
    }

    private func chip(_ space: Space) -> some View {
        HStack(spacing: 4) {
            icon(space)
            Text(space.name).font(.secondary).lineLimit(1)
        }
        .foregroundStyle(Theme.primary)
        .padding(.horizontal, 8)
        .frame(height: Metrics.control)
        .help(Accessibility.spaceHelp(space.name, isProfile: space.isProfile))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(space.name)
        .accessibilityValue(Accessibility.spaceValue(isProfile: space.isProfile) ?? "")
        .accessibilityAddTraits([.isButton, .isSelected])
    }

    private func dot(_ space: Space, number: Int) -> some View {
        Button {
            withAnimation(Motion.standard) { browser.switchSpace(to: space.id) }
        } label: {
            icon(space)
                .frame(minWidth: 18, idealWidth: Metrics.control, maxWidth: Metrics.control, minHeight: Metrics.control, maxHeight: Metrics.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(FillStyle(radius: nil))
        .foregroundStyle(Theme.secondary)
        .help(Accessibility.spaceHelp(number <= 9 ? "\(space.name)  ⌃\(number)" : space.name, isProfile: space.isProfile))
        .accessibilityLabel(space.name)
        .accessibilityValue(Accessibility.spaceValue(isProfile: space.isProfile) ?? "")
    }

    /// A profile's symbol wears a small key: its logins and cookies are its own.
    private func icon(_ space: Space) -> some View {
        SpaceIcon(space: space)
            .overlay(alignment: .bottomTrailing) {
                if space.isProfile {
                    Image(systemName: "key")
                        .font(.system(size: 7, weight: .bold))  // design-exempt: a badge drawn on the space's icon
                        .foregroundStyle(Theme.secondary)
                        .padding(4)
                        .background(Circle().fill(Theme.selectedFill))
                        .offset(x: 5, y: 5)
                }
            }
    }

    /// Asks over this window before a space goes; a profile's cookies and site data go with it.
    static func confirmDelete(_ space: Space, in browser: Browser) {
        // Its favorites go to the first space left.
        let heir = DialogSpec.name(browser.spaces.spaces.first { $0.id != space.id }?.name ?? "")
        let message = space.isProfile
            ? String(localized: "Its tabs are closed, and the cookies, logins and site data it kept are erased. Its favorites move to “\(heir)”. Bookmarks stay in the library.")
            : String(localized: "Its tabs are closed. Its favorites move to “\(heir)”. Bookmarks stay in the library.")
        let window = browser.window
        Task { @MainActor in
            if await Dialog.present(in: window, .confirmDelete(String(localized: "Delete the space “\(DialogSpec.name(space.name))”?"), message))?.button == 1 {
                Browser.deleteSpace(space.id, from: browser.spaces)
            }
        }
    }
}

/// Making a space, or changing one's name, symbol and colour (not whether it is a profile) over the window.
struct SpaceSheet: View {
    @ObservedObject var browser: Browser
    let mode: SpaceSheetMode
    @State private var name: String
    @State private var symbol: String
    @State private var tint: SpaceTint
    @State private var isProfile: Bool
    @State private var showsEmoji: Bool
    @FocusState private var focused: Bool

    init(browser: Browser, mode: SpaceSheetMode) {
        self.browser = browser
        self.mode = mode
        if case .edit(let id) = mode {
            let space = browser.spaces.space(id)
            _name = State(initialValue: space.name)
            _symbol = State(initialValue: space.symbol)
            _tint = State(initialValue: space.tint)
            _isProfile = State(initialValue: space.isProfile)
            _showsEmoji = State(initialValue: space.isEmoji)
        } else {
            _name = State(initialValue: "")
            _symbol = State(initialValue: Space.symbols[0])
            _tint = State(initialValue: SpaceTint.allCases[browser.spaces.spaces.count % 7])
            _isProfile = State(initialValue: false)
            _showsEmoji = State(initialValue: false)
        }
    }

    private var editing: Bool { if case .edit = mode { true } else { false } }
    private var preview: Space { Space(name: name, symbol: symbol, tint: tint, isProfile: isProfile) }

    var body: some View {
        ZStack {
            Theme.scrim
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(alignment: .leading, spacing: 16) {
                Text(editing ? "Edit Space" : "New Space")
                    .font(.title)
                    .frame(maxWidth: .infinity)
                header
                iconPicker
                colors
                profileToggle
                comparison
                HStack(spacing: 8) {
                    Spacer()
                    Button(action: close) { Text("Cancel") }
                        .buttonStyle(SecondaryButton(size: .regular))
                    Button(action: save) { Text(editing ? "Save" : "Create") }
                        .buttonStyle(PrimaryButton(size: .regular))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 440)
            .floatingPanel(radius: Metrics.panelRadius, modal: true)
            .onKeyPress(.escape) { close(); return .handled }
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            SpaceIcon(space: preview, size: 26)
                .foregroundStyle(tint.color)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous).fill(tint.color.opacity(0.18)))
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.caption).foregroundStyle(Theme.secondary)
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title)
                    .focused($focused)
                    .accessibilityLabel(String(localized: "Name"))
                    .onSubmit(save)
                    .padding(.horizontal, 8)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).fill(Theme.selectedFill))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).strokeBorder(focused ? tint.color : Theme.selectedEdge, lineWidth: focused ? 1.5 : 0.5))
            }
        }
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Icon").font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                Picker("", selection: $showsEmoji) {
                    Text("Symbol").tag(false)
                    Text("Emoji").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(String(localized: "Icon"))
                .frame(width: 130)
                .onChange(of: showsEmoji) { symbol = (showsEmoji ? Space.emoji : Space.symbols)[0] }
            }
            HStack(spacing: 4) {
                ForEach(showsEmoji ? Space.emoji : Space.symbols, id: \.self) { item in
                    Button { symbol = item } label: {
                        SpaceIcon(space: Space(name: "", symbol: item, tint: tint), size: 14)
                            .foregroundStyle(symbol == item ? tint.color : Theme.secondary)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(symbol == item ? tint.color.opacity(0.14) : Theme.field))
                            .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).strokeBorder(symbol == item ? tint.color : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(symbol == item ? .isSelected : [])
                }
            }
        }
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Color").font(.caption).foregroundStyle(Theme.secondary)
                Text("· tints the sidebar glass").font(.caption).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 8) {
                ForEach(SpaceTint.allCases) { item in
                    Button { tint = item } label: {
                        Circle().fill(item.color)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(Theme.primary, lineWidth: tint == item ? 2 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.name)
                    .accessibilityAddTraits(tint == item ? .isSelected : [])
                }
            }
            .padding(.leading, 4)
        }
    }

    private var profileToggle: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep logins and cookies separate (profile)").font(.bodyStrong)
                Text("Cookies and site data are kept apart, so you log in again here.").font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isProfile).toggleStyle(.switch).labelsHidden().disabled(editing)
                .accessibilityLabel(String(localized: "Keep logins and cookies separate (profile)"))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Theme.field))
        .help(editing ? String(localized: "Whether a space is a profile is fixed when it is made.") : "")
    }

    /// What the two kinds keep apart and what they share; the one that matches the switch is lit.
    private var comparison: some View {
        HStack(alignment: .top, spacing: 8) {
            card(String(localized: "Space"), on: !isProfile, [String(localized: "Own tabs, favorites and folders"), String(localized: "Cookies and logins shared"),
                                                               String(localized: "History and passwords shared")])
            card(String(localized: "Profile"), on: isProfile, [String(localized: "Own tabs, favorites and folders"), String(localized: "Own cookies and logins"),
                                                                String(localized: "History and passwords shared")])
        }
    }

    private func card(_ title: String, on: Bool, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.secondaryStrong).foregroundStyle(on ? tint.color : Theme.secondary)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "checkmark").font(.symbolInline).foregroundStyle(Theme.success).padding(.top, 4)
                    Text(line).font(.caption).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(on ? tint.color.opacity(0.14) : Theme.field))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(on ? tint.color.opacity(0.7) : .clear, lineWidth: 1.5))
    }

    private func close() { browser.spaceSheet = nil }

    private func save() {
        switch mode {
        case .new:
            let space = browser.spaces.add(name: name, symbol: symbol, tint: tint, isProfile: isProfile)
            close()
            withAnimation(Motion.standard) { browser.switchSpace(to: space.id) }
        case .edit(let id):
            browser.spaces.update(id, name: name, symbol: symbol, tint: tint)
            close()
        }
    }
}
