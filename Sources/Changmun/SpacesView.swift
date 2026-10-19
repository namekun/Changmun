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
            Text(space.symbol).font(.system(size: size)).foregroundStyle(.primary)
        } else {
            Image(systemName: space.symbol).font(.system(size: size, weight: .medium))
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

/// The bottom row of the sidebar: the space shown as a chip with its name, the others as symbols, and a plus to make one.
struct SpaceSwitcher: View {
    @ObservedObject var browser: Browser

    var body: some View {
        let spaces = browser.spaces.spaces
        HStack(spacing: 2) {
            ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                Group {
                    if space.id == browser.spaceID {
                        chip(space)
                    } else {
                        dot(space, number: index + 1)
                    }
                }
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
        .frame(maxWidth: .infinity)
        .animation(Motion.standard, value: browser.spaceID)
        .animation(Motion.standard, value: spaces)
    }

    private func chip(_ space: Space) -> some View {
        HStack(spacing: 6) {
            icon(space)
            Text(space.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(Theme.primary)
        .padding(.horizontal, 10)
        .frame(height: Metrics.control)
        .background(Capsule().fill(Theme.selectedFill).overlay(Capsule().strokeBorder(Theme.selectedEdge, lineWidth: 0.5))
            .shadow(color: Theme.selectedShadow, radius: 1, y: 1))
        .help(space.name)
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
        .help(number <= 9 ? "\(space.name)  ⌃\(number)" : space.name)
    }

    /// A profile's symbol wears a small key: its logins and cookies are its own.
    private func icon(_ space: Space) -> some View {
        SpaceIcon(space: space)
            .overlay(alignment: .bottomTrailing) {
                if space.isProfile {
                    Image(systemName: "key.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .padding(2)
                        .background(Circle().fill(Theme.selectedFill))
                        .offset(x: 5, y: 5)
                }
            }
    }

    /// Asks over this window before a space goes; a profile's cookies and site data go with it.
    static func confirmDelete(_ space: Space, in browser: Browser) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete the space “\(space.name)”?")
        alert.informativeText = space.isProfile
            ? String(localized: "Its tabs are closed, and the cookies, logins and site data it kept are erased. Bookmarks stay in the library.")
            : String(localized: "Its tabs are closed. Bookmarks stay in the library.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Delete")).hasDestructiveAction = true
        let delete = { Browser.deleteSpace(space.id, from: browser.spaces) }
        if let window = browser.window {
            alert.beginSheetModal(for: window) { if $0 == .alertSecondButtonReturn { delete() } }
        } else if alert.runModal() == .alertSecondButtonReturn {
            delete()
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
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(alignment: .leading, spacing: 16) {
                Text(editing ? "Edit Space" : "New Space")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                header
                iconPicker
                colors
                profileToggle
                comparison
                HStack(spacing: 8) {
                    Spacer()
                    Button(action: close) { Text("Cancel").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).frame(height: Metrics.control) }
                        .buttonStyle(FillStyle(resting: Theme.field, hoverFill: Theme.pill))
                        .foregroundStyle(Theme.primary)
                    Button(action: save) {
                        Text(editing ? "Save" : "Create").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).frame(height: Metrics.control)
                            .foregroundStyle(.white)
                            .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(tint.color))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 440)
            .floatingPanel(radius: 16)
            .onKeyPress(.escape) { close(); return .handled }
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            SpaceIcon(space: preview, size: 26)
                .foregroundStyle(tint.color)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.color.opacity(0.18)))
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(Theme.secondary)
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($focused)
                    .onSubmit(save)
                    .padding(.horizontal, 10)
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
                .frame(width: 130)
                .onChange(of: showsEmoji) { symbol = (showsEmoji ? Space.emoji : Space.symbols)[0] }
            }
            HStack(spacing: 4) {
                ForEach(showsEmoji ? Space.emoji : Space.symbols, id: \.self) { item in
                    Button { symbol = item } label: {
                        SpaceIcon(space: Space(name: "", symbol: item, tint: tint), size: 14)
                            .foregroundStyle(symbol == item ? tint.color : Theme.secondary)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(symbol == item ? tint.color.opacity(0.14) : Theme.field))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(symbol == item ? tint.color : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Color").font(.caption).foregroundStyle(Theme.secondary)
                Text("· tints the sidebar glass").font(.caption).foregroundStyle(Theme.faint)
            }
            HStack(spacing: 10) {
                ForEach(SpaceTint.allCases) { item in
                    Button { tint = item } label: {
                        Circle().fill(item.color)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(Theme.primary, lineWidth: tint == item ? 2 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 4)
        }
    }

    private var profileToggle: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep logins and cookies separate (profile)").font(.system(size: 13, weight: .semibold))
                Text("Cookies and site data are kept apart, so you log in again here.").font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isProfile).toggleStyle(.switch).labelsHidden().disabled(editing)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
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
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? tint.color : Theme.secondary)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(SpaceTint.green.color).padding(.top, 3)
                    Text(line).font(.system(size: 11)).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? tint.color.opacity(0.14) : Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? tint.color.opacity(0.7) : .clear, lineWidth: 1.5))
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
