import AppKit
import SwiftUI
import WebKit

/// Nunsseop's look: a dark gray (or, in light mode, light gray) ground, ink at a few fixed opacities, hairlines,
/// and colour only where it means something: orange when something needs you, green while work is going on.
/// The page sits on a lighter card with its bar, so a dark site never runs into the sidebar.
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

    static let primary = ink(1)
    static let body = ink(0.9)
    static let secondary = ink(0.6)
    static let dim = ink(0.55)
    static let faint = ink(0.5)
    static let hairline = ink(0.24)
    static let pill = ink(0.16)
    static let field = ink(0.1)
    static let selected = ink(0.08)
    static let hoverTab = ink(0.07)
    static let pressed = ink(0.13)
    /// A selected row stands up from the glass: white with a soft shadow on light, a brighter film on dark.
    static let selectedFill = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.14))
    static let selectedEdge = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.08))
    static let selectedShadow = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: .clear)
    static let cardShadow = dynamic(light: NSColor(red: 0.12, green: 0.16, blue: 0.24, alpha: 0.12), dark: NSColor(white: 0, alpha: 0.35))
    static let track = ink(0.15)
    static let meter = ink(0.75)
    static let waiting = Color(red: 1.0, green: 0.62, blue: 0.2)
    static let working = Color(red: 0.31, green: 0.82, blue: 0.47)

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

/// Sizes on a 4 pt grid. Rows share one height, and a row inside another steps in by one icon column, so its icon
/// lines up with the text above it.
enum Metrics {
    /// From the window's edge to the sidebar's contents and to the page card.
    static let inset: CGFloat = 8
    static let row: CGFloat = 28
    static let rowGap: CGFloat = 2
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
    static let rowRadius: CGFloat = 8
    static let fieldRadius: CGFloat = 10
    static let cardRadius: CGFloat = 12
}

extension Font {
    static let row = Font.system(size: 13)
    static let rowSelected = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 11, weight: .medium)
    static let captionStrong = Font.system(size: 11, weight: .semibold)
}

/// Springs without overshoot: they settle smoothly and, when interrupted, turn around from where they are. With
/// Reduce Motion on, things fade instead of moving.
@MainActor
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var standard: Animation { reduced ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1) }
    static var quick: Animation { reduced ? .easeOut(duration: 0.1) : .spring(response: 0.2, dampingFraction: 1) }

    /// In from an edge and back out the same way.
    static func slide(_ edge: Edge) -> AnyTransition {
        reduced ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// A panel grows out of where it is anchored (a bar opening under the address, a card over the page).
    static func pop(_ anchor: UnitPoint) -> AnyTransition {
        reduced ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: anchor))
    }
}

/// One row's pressed state. The tracker sets it, so a press redraws the row under the pointer and nothing else.
@MainActor
final class PressState: ObservableObject {
    @Published fileprivate(set) var isPressed = false
}

/// Darkens a row the moment the left button goes down on it. It only watches the events, leaving clicks, drags and
/// menus to the views as before; rows tell it where they are.
@MainActor
final class PressTracker {
    static let shared = PressTracker()
    private struct Area {
        weak var state: PressState?
        var frame: CGRect
        var window: Int?
    }
    private var areas: [ObjectIdentifier: Area] = [:]
    private var pressed: [PressState] = []
    private var start: CGPoint?

    private init() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            MainActor.assumeIsolated { PressTracker.shared.handle(event) }
            return event
        }
        // A menu that opens takes the mouse-up with it, as does a window that loses focus mid-press.
        for name in [NSMenu.didBeginTrackingNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PressTracker.shared.release() }
            }
        }
    }

    func place(_ state: PressState, frame: CGRect, window: Int?) {
        areas[ObjectIdentifier(state)] = Area(state: state, frame: frame, window: window)
    }

    func remove(_ state: PressState) {
        areas[ObjectIdentifier(state)] = nil
    }

    private func handle(_ event: NSEvent) {
        guard let window = event.window, let content = window.contentView else { return }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        switch event.type {
        case .leftMouseDown where !event.modifierFlags.contains(.control):
            release()
            start = point
            pressed = areas.values.compactMap { $0.window == window.windowNumber && $0.frame.contains(point) ? $0.state : nil }
            for state in pressed { state.isPressed = true }
        case .leftMouseDragged:
            // A drag has begun: the row is being carried, not pressed.
            if !pressed.isEmpty, let start, hypot(point.x - start.x, point.y - start.y) > 4 { release() }
        default:
            release()
        }
    }

    func release() {
        start = nil
        for state in pressed { state.isPressed = false }
        pressed = []
    }
}

/// Tells the tracker where a pressable view is.
private struct PressArea: ViewModifier {
    let state: PressState
    @Environment(\.windowNumber) private var window

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { PressTracker.shared.place(state, frame: $0, window: window) }
            .onDisappear { PressTracker.shared.remove(state) }
    }
}

extension View {
    func pressArea(_ state: PressState) -> some View { modifier(PressArea(state: state)) }
}

private struct WindowNumberKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    /// The window the view is in, to tell its presses from another window's.
    var windowNumber: Int? {
        get { self[WindowNumberKey.self] }
        set { self[WindowNumberKey.self] = newValue }
    }
}

/// A row's fill: selected, pressed, a drop landing in it, hovered, or none (tiles have a resting fill).
struct RowChrome: ViewModifier {
    let hover: Bool
    var selected = false
    var target = false
    var radius = Metrics.rowRadius
    var resting: Color = .clear
    @StateObject private var press = PressState()

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
    }
}

/// Bars and cards that float over the page (the command bar, find, a link preview): the same glass as the window,
/// with an edge and a soft shadow.
struct FloatingPanel: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
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

struct BrowserView: View {
    @ObservedObject var browser: Browser
    @ObservedObject var chat: ChatStore
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        let sidebar = browser.showSidebar && !browser.focusMode
        ZStack {
            WindowMaterial()
            if browser.focusMode { WindowDragArea() }
            HStack(spacing: 0) {
                if sidebar {
                    Sidebar(browser: browser)
                        .frame(width: prefs.sidebarWidth)
                        .overlay(alignment: .trailing) { SidebarResizeHandle(width: $prefs.sidebarWidth) }
                        .transition(Motion.slide(.leading))
                }
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if !browser.focusMode && !(sidebar && prefs.toolbarPlace == .sidebar) { PageBar(browser: browser) }
                        WebCard(browser: browser)
                    }
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Theme.cardEdge, lineWidth: 0.5))
                    // The shadow comes from a shape behind the card, not from the web views in it.
                    .background {
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                            .fill(Theme.card)
                            .shadow(color: Theme.cardShadow, radius: 14, y: 6)
                    }
                    if browser.showChat && !browser.focusMode {
                        ChatPanel(chat: chat, browser: browser)
                            .padding(.leading, Metrics.inset)
                            .frame(minWidth: 300, maxWidth: 360)
                            .transition(Motion.slide(.trailing))
                    }
                }
                .padding(.top, BrowserWindow.cardInset)
                .padding([.trailing, .bottom], Metrics.inset)
                .padding(.leading, sidebar ? 0 : Metrics.inset)
            }
            if let peek = browser.peek {
                PeekCard(tab: peek, browser: browser).transition(Motion.pop(.center))
            }
            if let switcher = browser.tabSwitcher {
                TabSwitcherView(browser: browser, switcher: switcher)
            }
            if let mode = browser.commandBar, !browser.showOnboarding {
                CommandBar(browser: browser, chat: chat, mode: mode).transition(Motion.pop(.top))
            }
            if browser.showOnboarding {
                OnboardingView(browser: browser)
            }
        }
        .ignoresSafeArea()
        .environment(\.windowNumber, browser.window?.windowNumber)
        .animation(Motion.standard, value: browser.showChat)
        .animation(Motion.standard, value: browser.showSidebar)
        .animation(Motion.standard, value: browser.focusMode)
        .animation(Motion.standard, value: prefs.addressBarOnTop)
        .animation(Motion.standard, value: prefs.toolbarPlace)
        .animation(Motion.standard, value: browser.fullScreen)
        .animation(Motion.quick, value: browser.commandBar)
        .animation(Motion.quick, value: browser.peek?.id)
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var library = LibraryWatcher.shared
    @State private var dropTarget: String?
    @State private var showLibrary = false
    @State private var bookmarkQuery = ""
    @State private var newTabHover = false

    var body: some View {
        VStack(spacing: 0) {
            if prefs.toolbarPlace == .sidebar {
                SidebarToolbar(browser: browser)
            } else {
                WindowDragArea().frame(height: browser.fullScreen ? 0 : BrowserWindow.windowButtonsBottom)
            }

            ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.rowGap) {
                    if !library.favorites.isEmpty {
                        favorites
                    }
                    pinned
                    // Tidying is offered where the tabs start, when the pointer is there.
                    HStack(spacing: Metrics.rowGap) {
                        NewTabRow { browser.commandBar = .newTab }
                        if browser.tidying || (newTabHover && browser.looseTabs.count > 1) { TidyButton(browser: browser) }
                    }
                    .onHover { newTabHover = $0 }
                    if let tidy = browser.lastTidy {
                        UndoNotice(message: tidy.message) { browser.undoTidy() }.transition(.opacity)
                    } else if let notice = browser.notice {
                        UndoNotice(message: notice.message) { browser.undoNotice() }.transition(.opacity)
                    }
                    ForEach(browser.listing) { item in
                        switch item {
                        case .tab(let tab):
                            tabRow(tab, depth: 0)
                        case .group(let group, let tabs):
                            TabGroupHeader(group: group, count: tabs.count, browser: browser,
                                           target: dropTarget == "group:\(group.id)" && SidebarDrag.carriesTab)
                                .dropDestination(for: SidebarDrop.self) { items, _ in
                                    SidebarDrag.drop(items.texts, onGroup: group.id, browser: browser)
                                } isTargeted: { target("group:\(group.id)", $0) }
                            ForEach(browser.shown(tabs, in: group)) { tab in
                                tabRow(tab, depth: 1)
                            }
                        }
                    }
                    // Below the last tab: a tab dropped here goes to the end of the list.
                    SectionGap()
                        .dropLine(dropTarget == "tabs:end" && SidebarDrag.carriesTab)
                        .dropDestination(for: SidebarDrop.self) { items, _ in
                            SidebarDrag.dropAtEnd(items.texts, browser: browser)
                        } isTargeted: { target("tabs:end", $0) }
                }
                .padding(.horizontal, Metrics.inset)
                .padding(.top, prefs.toolbarPlace == .sidebar ? Metrics.section : Metrics.inset)
                .padding(.bottom, Metrics.inset)
                .animation(Motion.standard, value: browser.tabs.map(\.id))
                .animation(Motion.standard, value: browser.groups)
                .animation(Motion.standard, value: browser.tabs.map(\.groupID))
                .animation(Motion.standard, value: browser.lastTidy)
                .animation(Motion.standard, value: browser.notice)
                .animation(Motion.standard, value: prefs.pinnedFolders)
                .animation(Motion.standard, value: prefs.openFolders)
                .animation(Motion.quick, value: dropTarget)
            }
            // A tab switched to from the keyboard or the command bar comes into view.
            .onChange(of: browser.activeID) { _, id in
                guard let id else { return }
                withAnimation(Motion.standard) { scroller.scrollTo("tab:\(id)") }
            }
            }

            DownloadShelf(browser: browser).padding(.bottom, Metrics.inset)
            // The rest of the browser, out of the way at the bottom: every bookmark, downloads, extensions and AI.
            HStack(spacing: Metrics.rowGap) {
                BarButton(symbol: "bookmark", help: String(localized: "Bookmarks")) { showLibrary.toggle() }
                    .popover(isPresented: $showLibrary, arrowEdge: .top) { allBookmarks }
                if prefs.toolbarPlace == .sidebar {
                    DownloadButton(browser: browser, arrowEdge: .top)
                    if #available(macOS 15.4, *), !browser.isPrivate { ExtensionButtons(browser: browser) }
                }
                MoreButton(inBar: true) {
                    Button("History") { NSApp.sendAction(#selector(AppDelegate.showHistory(_:)), to: nil, from: nil) }
                    Button("Archived Tabs") { NSApp.sendAction(#selector(AppDelegate.showArchive(_:)), to: nil, from: nil) }
                    Divider()
                    Button("Tidy Tabs") { browser.tidyTabs() }
                    Button("Split View") { browser.toggleSplit() }
                    Button("Focus Mode") { browser.focusMode = true }
                    Divider()
                    Button("Settings…") { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) }
                }
                Spacer(minLength: 0)
                if prefs.toolbarPlace == .sidebar {
                    if browser.isPrivate {
                        PrivateBadge()
                    } else {
                        AIButton(isOn: browser.showChat) { browser.showChat.toggle() }
                    }
                }
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.bottom, Metrics.inset)
        }
    }

    // MARK: Parts

    private var favorites: some View {
        // As many tiles a row as the sidebar's width holds: four at the default width, up to seven when wide.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 4)], spacing: 4) {
            ForEach(library.favorites, id: \.url) { entry in
                let key = Browser.bookmarkKey(url: entry.url, folder: Library.favoritesFolder)
                FavoriteTile(entry: entry, state: BookmarkTabState(key, browser)) {
                    browser.openBookmark(entry.url, key: key, inNewTab: Browser.commandClick)
                } menu: {
                    bookmarkMenu(url: entry.url, title: entry.title, folder: Library.favoritesFolder, key: key)
                }
                .dropLine(dropTarget == "fav:" + entry.url && SidebarDrag.dragging != .folder, edge: .leading)
                .draggable(SidebarDrag.favorite(entry.url))
                .dropDestination(for: SidebarDrop.self) { items, _ in
                    SidebarDrag.drop(items.texts, onFavorite: entry.url, browser: browser)
                } isTargeted: { target("fav:" + entry.url, $0) }
            }
        }
        // Between and after the tiles: dropped there, it goes to the end of the favorites.
        .dropDestination(for: SidebarDrop.self) { items, _ in
            SidebarDrag.drop(items.texts, onFavorite: nil, browser: browser)
        }
        .padding(.bottom, Metrics.section - Metrics.rowGap)
    }

    /// Folders kept under the favorites, opened where they are, then a gap before the tabs. A folder dropped in
    /// the gap is pinned at the end.
    @ViewBuilder private var pinned: some View {
        let folders = prefs.pinnedFolders.compactMap(library.folder)
        // Ids carry the part of the sidebar: a folder can show both pinned and under Bookmarks.
        ForEach(folders.flatMap { treeRows($0, depth: 0, scope: "pin:", pinned: true) }) { row in
            treeRow(row)
        }
        SectionGap()
            .dropLine(dropTarget == "pin:end" && SidebarDrag.dragging == .folder)
            .dropDestination(for: SidebarDrop.self) { items, _ in
                SidebarDrag.pin(items.texts, before: nil)
            } isTargeted: { target("pin:end", $0) }
    }

    /// Every imported bookmark, by browser and folder, in a popover over the sidebar's bottom bar; typing finds one.
    private var allBookmarks: some View {
        VStack(spacing: 0) {
            if library.sources.isEmpty {
                VStack(spacing: Metrics.section) {
                    Text("Bookmarks you bring over from another browser show up here.")
                        .font(.row)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                    Button("Import from Another Browser…") {
                        showLibrary = false
                        browser.showOnboarding = true
                    }
                }
                .padding(24)
                .frame(width: 320)
            } else {
                HStack(spacing: Metrics.iconGap) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    TextField("Search Bookmarks", text: $bookmarkQuery)
                        .textFieldStyle(.plain)
                        .font(.row)
                }
                .padding(.horizontal, 10)
                .frame(height: Metrics.control)
                .background(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).fill(Theme.field))
                .padding([.horizontal, .top], Metrics.inset)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Metrics.rowGap) {
                        if bookmarkQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                            bookmarkSources
                        } else {
                            ForEach(foundBookmarks) { row in treeRow(row) }
                        }
                    }
                    .padding(Metrics.inset)
                    .animation(Motion.standard, value: prefs.openFolders)
                }
                .frame(width: 320, height: 420)
            }
        }
    }

    private var bookmarkSources: some View {
        ForEach(library.sources, id: \.source) { group in
            let key = "source:" + group.source
            FolderRow(name: group.source, symbol: "books.vertical", count: group.folders.reduce(0) { $0 + $1.count },
                      isOpen: prefs.openFolders.contains(key)) {
                prefs.toggleOpen(key)
            } menu: {
                Button("Delete All \(group.source) Bookmarks…") {
                    confirmDelete(String(localized: "Delete all bookmarks imported from \(group.source)?")) { Library.shared.removeSource(group.source) }
                }
            }
            if prefs.openFolders.contains(key) {
                ForEach(group.folders.flatMap { treeRows($0, depth: 1, scope: "", pinned: false) }) { row in
                    treeRow(row)
                }
            }
        }
    }

    /// Bookmarks whose title or address holds every word typed, from every folder.
    private var foundBookmarks: [TreeRow] {
        let words = bookmarkQuery.lowercased().split(separator: " ")
        return Library.allFolders(library.sources).flatMap { folder in
            folder.entries.filter { entry in
                let text = (entry.title + " " + entry.url).lowercased()
                return words.allSatisfy { text.contains($0) }
            }.map { TreeRow.bookmark($0, folder: folder.key, depth: 0, scope: "found:") }
        }
        .prefix(200).map { $0 }
    }

    /// One row of a folder tree, with how far in it sits. The tree is laid out as a flat list so the lazy stack
    /// only builds the rows on screen, however big an open folder is.
    enum TreeRow: Identifiable {
        case folder(Library.Folder, depth: Int, scope: String, pinned: Bool)
        case bookmark(Library.Entry, folder: String, depth: Int, scope: String)

        /// Carries the part of the sidebar: a folder can show both pinned and under Bookmarks.
        var id: String {
            switch self {
            case .folder(let folder, _, let scope, _): scope + folder.key
            case .bookmark(let entry, let folder, _, let scope): scope + folder + "\n" + entry.url
            }
        }
    }

    /// A folder, and when it is open the folders and bookmarks inside it, each a step further in.
    private func treeRows(_ folder: Library.Folder, depth: Int, scope: String, pinned: Bool) -> [TreeRow] {
        var rows: [TreeRow] = [.folder(folder, depth: depth, scope: scope, pinned: pinned)]
        guard prefs.openFolders.contains(scope + folder.key) else { return rows }
        for child in folder.children { rows += treeRows(child, depth: depth + 1, scope: scope, pinned: pinned) }
        rows += folder.entries.map { .bookmark($0, folder: folder.key, depth: depth + 1, scope: scope) }
        return rows
    }

    @ViewBuilder private func treeRow(_ row: TreeRow) -> some View {
        switch row {
        case .folder(let folder, let depth, let scope, let pinned):
            folderRow(folder, depth: depth, scope: scope, pinned: pinned)
        case .bookmark(let entry, let folder, let depth, _):
            let key = Browser.bookmarkKey(url: entry.url, folder: folder)
            BookmarkRow(entry: entry, state: BookmarkTabState(key, browser)) {
                browser.openBookmark(entry.url, key: key, inNewTab: Browser.commandClick)
            } menu: {
                bookmarkMenu(url: entry.url, title: entry.title, folder: folder, key: key)
            }
            .padding(.leading, CGFloat(depth) * Metrics.indent)
            .draggable(SidebarDrag.bookmark(entry.url, in: folder))
        }
    }

    private func folderRow(_ folder: Library.Folder, depth: Int, scope: String, pinned: Bool) -> some View {
        let openKey = scope + folder.key
        let isPinned = prefs.pinnedFolders.contains(folder.key)
        let targetKey = scope + "folder:" + folder.key
        // Pinned folders reorder when a folder is dropped on one; a bookmark dropped on any folder moves in.
        let reorders = pinned && depth == 0
        let over = dropTarget == targetKey
        return FolderRow(name: folder.label, count: folder.count, isOpen: prefs.openFolders.contains(openKey), showCount: false,
                         target: over && SidebarDrag.dragging != .tab && SidebarDrag.dragging != .folder) {
            prefs.toggleOpen(openKey)
        } menu: {
            if isPinned {
                Button("Unpin from Sidebar") { prefs.unpinFolder(folder.key) }
            } else {
                Button("Pin to Sidebar") { prefs.pinFolder(folder.key) }
            }
            Divider()
            Button("Delete Folder…") {
                let count = folder.count
                let question = count == 1 ? String(localized: "Delete the folder “\(folder.label)” and its \(count) bookmark?")
                                          : String(localized: "Delete the folder “\(folder.label)” and its \(count) bookmarks?")
                confirmDelete(question) {
                    for inner in folder.flattened() { prefs.unpinFolder(inner.folder.key) }
                    Library.shared.removeFolder(folder.key)
                }
            }
        }
        .padding(.leading, CGFloat(depth) * Metrics.indent)
        .help(folder.key)
        .dropLine(reorders && over && SidebarDrag.dragging == .folder)
        .draggable(SidebarDrag.folder(folder.key))
        .dropDestination(for: SidebarDrop.self) { items, _ in
            if reorders, SidebarDrag.pin(items.texts, before: folder.key) { return true }
            return SidebarDrag.drop(items.texts, onFolder: folder.key)
        } isTargeted: { target(targetKey, $0) }
    }

    private func tabRow(_ tab: Tab, depth: Int) -> some View {
        SidebarTabRow(tab: tab, browser: browser, isActive: tab.id == browser.activeID) {
            browser.activate(tab.id)
        } close: {
            browser.close(tab.id)
        }
        .padding(.leading, CGFloat(depth) * Metrics.indent)
        .id("tab:\(tab.id)")
        .dropLine(dropTarget == "tab:\(tab.id)" && SidebarDrag.carriesTab)
        .draggable(SidebarDrag.tab(tab.id))
        .dropDestination(for: SidebarDrop.self) { items, _ in
            SidebarDrag.drop(items.texts, onTab: tab.id, browser: browser)
        } isTargeted: { target("tab:\(tab.id)", $0) }
    }

    // MARK: Menus

    /// The same items for a favorite and a bookmark, in the same order: the tab, then where it goes, then deleting.
    private func remove(url: String, title: String, folder: String, _ message: String) {
        Library.shared.removeBookmark(url: url, folder: folder)
        browser.offerUndo(message) { Library.shared.addBookmark(url: url, title: title, folder: folder) }
    }

    @ViewBuilder private func bookmarkMenu(url: String, title: String, folder: String, key: String) -> some View {
        let tab = browser.bookmarkTab(key)
        if let tab {
            Button("Close Tab") { browser.close(tab.id) }
        }
        if let tab, browser.split?.contains(tab.id) == true {
            Button("End Split View") { browser.unsplit() }
        } else if browser.activeID != nil && tab?.id != browser.activeID {
            Button("Show Side by Side with Current Tab") { browser.split(withBookmark: url, key: key) }
        }
        moveMenu(url: url, from: folder)
        Divider()
        if folder == Library.favoritesFolder {
            Button("Remove from Favorites") { remove(url: url, title: title, folder: folder, String(localized: "Removed from Favorites")) }
        } else {
            Button("Delete Bookmark") { remove(url: url, title: title, folder: folder, String(localized: "Deleted the bookmark")) }
        }
    }

    /// "Move To": the favorites and every imported folder, by the browser it came from.
    @ViewBuilder private func moveMenu(url: String, from: String) -> some View {
        Menu("Move To") {
            Button("Favorites") { Browser.moveBookmark(url: url, from: from, to: Library.favoritesFolder) }
                .disabled(from == Library.favoritesFolder)
            ForEach(library.sources, id: \.source) { group in
                Section(group.source) {
                    ForEach(group.folders.flatMap { $0.paths() }, id: \.key) { item in
                        Button(item.path) { Browser.moveBookmark(url: url, from: from, to: item.key) }
                            .disabled(item.key == from)
                    }
                }
            }
        }
    }

    /// Asks over this window (not the whole app) before deleting what can't be brought back.
    private func confirmDelete(_ message: String, then delete: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Delete")).hasDestructiveAction = true
        if let window = browser.window {
            alert.beginSheetModal(for: window) { if $0 == .alertSecondButtonReturn { delete() } }
        } else if alert.runModal() == .alertSecondButtonReturn {
            delete()
        }
    }

    private func target(_ key: String, _ inside: Bool) {
        if inside { dropTarget = key } else if dropTarget == key { dropTarget = nil }
    }
}

/// The space between two parts of the sidebar.
struct SectionGap: View {
    var body: some View {
        Color.clear
            .frame(height: Metrics.section - 2 * Metrics.rowGap)
            .contentShape(Rectangle())
    }
}

/// The sidebar's right edge: drag to resize, double-click for the default width.
struct SidebarResizeHandle: View {
    @Binding var width: Double
    @State private var start: Double?
    @State private var hover = false

    var body: some View {
        Rectangle()
            .fill(hover || start != nil ? Theme.hairline : .clear)
            .frame(width: 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .offset(x: 4)
            .onHover { inside in
                hover = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let base = start ?? width
                        start = base
                        width = Preferences.clampedSidebarWidth((base + drag.translation.width).rounded())
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { width = Preferences.defaultSidebarWidth }
            .help("Drag to resize the sidebar · double-click for default width")
    }
}

/// What the sidebar takes when something is dropped on it: one of its own rows (carried as text naming it), or a
/// link dragged from a page, the address or another app.
struct SidebarDrop: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { (drop: SidebarDrop) in URL(string: drop.text) ?? URL(fileURLWithPath: "/") },
                            importing: { (url: URL) in SidebarDrop(text: url.absoluteString) })
        ProxyRepresentation(exporting: \.text, importing: { SidebarDrop(text: $0) })
    }
}

extension Array where Element == SidebarDrop {
    var texts: [String] { map(\.text) }
}

/// Dragging tabs and favorites around the sidebar: the payload names what is dragged.
@MainActor
enum SidebarDrag {
    enum Kind { case tab, bookmark, folder }
    /// What the latest drag from the sidebar carries: set when the drag starts, so drop targets can show where it lands.
    private(set) static var dragging: Kind?

    static func tab(_ id: Int) -> String { dragging = .tab; return "changmun-tab:\(id)" }
    static func favorite(_ url: String) -> String { dragging = .bookmark; return "changmun-favorite:" + url }
    static func bookmark(_ url: String, in folder: String) -> String { dragging = .bookmark; return "changmun-bookmark:" + folder + "\n" + url }
    static func folder(_ key: String) -> String { dragging = .folder; return "changmun-folder:" + key }

    /// A web address dragged in from a page or another app.
    static func link(_ items: [String]) -> URL? {
        guard let item = items.first?.trimmingCharacters(in: .whitespacesAndNewlines), !item.hasPrefix("changmun-"),
              let url = URL(string: item), ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil else { return nil }
        return url
    }

    /// Nothing from the sidebar is being carried: a link from outside, which lands where a tab would.
    static var carriesTab: Bool { dragging == .tab || dragging == nil }

    static func folderKey(_ items: [String]) -> String? {
        guard let item = items.first, item.hasPrefix("changmun-folder:") else { return nil }
        return String(item.dropFirst("changmun-folder:".count))
    }

    /// A folder dropped among the pinned ones is pinned there (before `target`, or at the end).
    @discardableResult
    static func pin(_ items: [String], before target: String?) -> Bool {
        guard let key = folderKey(items) else { return false }
        dragging = nil
        withAnimation(Motion.standard) { Preferences.shared.pinFolder(key, before: target) }
        return true
    }

    /// A tab dropped below the list goes to its end, out of any group.
    static func dropAtEnd(_ items: [String], browser: Browser) -> Bool {
        defer { dragging = nil }
        if let url = link(items) {
            withAnimation(Motion.standard) { browser.moveTab(browser.openTab(url: url).id, to: nil) }
            return true
        }
        guard let id = tabID(items) else { return false }
        withAnimation(Motion.standard) {
            browser.moveTab(id, to: nil)
            browser.removeFromGroup(id)
        }
        return true
    }

    /// The bookmark (or favorite) being dragged, and the folder it is in.
    static func bookmark(_ items: [String]) -> (url: String, folder: String)? {
        guard let item = items.first else { return nil }
        if item.hasPrefix("changmun-favorite:") { return (String(item.dropFirst("changmun-favorite:".count)), Library.favoritesFolder) }
        guard item.hasPrefix("changmun-bookmark:") else { return nil }
        let rest = item.dropFirst("changmun-bookmark:".count)
        guard let newline = rest.firstIndex(of: "\n") else { return nil }
        return (String(rest[rest.index(after: newline)...]), String(rest[..<newline]))
    }

    /// A bookmark or favorite dropped on a folder moves into it.
    static func drop(_ items: [String], onFolder folder: String) -> Bool {
        defer { dragging = nil }
        if let url = link(items) {
            Library.shared.addBookmark(url: url.absoluteString, title: url.host() ?? url.absoluteString, folder: folder)
            return true
        }
        guard let (url, from) = bookmark(items), from != folder else { return false }
        Browser.moveBookmark(url: url, from: from, to: folder)
        return true
    }

    static func drop(_ items: [String], onTab target: Int, browser: Browser) -> Bool {
        defer { dragging = nil }
        if let url = link(items) {
            withAnimation(Motion.standard) {
                // Just above the tab it was dropped on, where the drop line showed, and into its group.
                let tab = browser.openTab(url: url)
                browser.moveTab(tab.id, to: nil)
                browser.dropTab(tab.id, on: target)
            }
            return true
        }
        guard let id = tabID(items) else { return false }
        withAnimation(Motion.standard) { browser.dropTab(id, on: target) }
        return true
    }

    static func drop(_ items: [String], onGroup group: UUID, browser: Browser) -> Bool {
        defer { dragging = nil }
        if let url = link(items) {
            withAnimation(Motion.standard) { browser.addTab(browser.openTab(url: url).id, to: group) }
            return true
        }
        guard let id = tabID(items) else { return false }
        withAnimation(Motion.standard) { browser.addTab(id, to: group) }
        return true
    }

    private static func tabID(_ items: [String]) -> Int? {
        guard let item = items.first, item.hasPrefix("changmun-tab:") else { return nil }
        return Int(item.dropFirst("changmun-tab:".count))
    }

    /// A favorite dropped on a favorite moves there; a bookmark from a folder or a tab dropped on one is pinned there.
    /// With no target, past the last tile, it goes to the end.
    static func drop(_ items: [String], onFavorite target: String?, browser: Browser) -> Bool {
        defer { dragging = nil }
        if let url = link(items) {
            let address = url.absoluteString
            if !Library.shared.isFavorite(address) { _ = Library.shared.toggleBookmark(url: address, title: url.host() ?? address) }
            Library.shared.moveFavorite(address, to: target)
            return true
        }
        if let (url, folder) = bookmark(items) {
            if folder != Library.favoritesFolder { Browser.moveBookmark(url: url, from: folder, to: Library.favoritesFolder) }
            Library.shared.moveFavorite(url, to: target)
            return true
        }
        if let id = tabID(items), let tab = browser.tab(id), let url = tab.url?.absoluteString {
            if !Library.shared.isFavorite(url) { _ = Library.shared.toggleBookmark(url: url, title: tab.title) }
            browser.bind(tab, to: Browser.bookmarkKey(url: url, folder: Library.favoritesFolder))
            Library.shared.moveFavorite(url, to: target)
            return true
        }
        return false
    }
}

/// The bookmarks as the sidebar shows them, read again off the main thread whenever the library changes. One for
/// the whole app, so showing and hiding the sidebar costs nothing.
@MainActor
final class LibraryWatcher: ObservableObject {
    static let shared = LibraryWatcher()
    @Published private(set) var favorites: [Library.Entry] = []
    @Published private(set) var sources: [(source: String, folders: [Library.Folder])] = []
    /// The favorites' addresses, for the star in the address bar.
    private(set) var favoriteURLs: Set<String> = []
    private var reading = false
    private var readAgain = false

    func folder(_ key: String) -> Library.Folder? {
        for source in sources {
            for folder in source.folders { if let found = folder.find(key) { return found } }
        }
        return nil
    }

    private init() {
        if let read = Library.shared.readBookmarks() { apply(read) }
        NotificationCenter.default.addObserver(forName: Library.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LibraryWatcher.shared.reload() }
        }
    }

    private func reload() {
        guard !reading else { readAgain = true; return }
        reading = true
        Task {
            // An unreadable library (locked, damaged, a full disk) keeps what is shown, and every tab keeps its bookmark.
            if let read = await Library.shared.inBackground({ $0.readBookmarks() }) { apply(read) }
            reading = false
            if readAgain {
                readAgain = false
                reload()
            }
        }
    }

    private func apply(_ read: (favorites: [Library.Entry], folders: [(name: String, entries: [Library.Entry])])) {
        let sources = Library.groupBySource(read.folders)
        if read.favorites != favorites {
            favorites = read.favorites
            favoriteURLs = Set(read.favorites.map(\.url))
        }
        if sources.map(\.source) != self.sources.map(\.source) || sources.map(\.folders) != self.sources.map(\.folders) { self.sources = sources }
        var keys = Set(read.favorites.map { Browser.bookmarkKey(url: $0.url, folder: Library.favoritesFolder) })
        for folder in read.folders { for entry in folder.entries { keys.insert(Browser.bookmarkKey(url: entry.url, folder: folder.name)) } }
        for browser in Browser.all { browser.releaseBookmarkTabs(keeping: keys) }
    }
}

/// The page bar's controls at the top of the sidebar, as in Arc: the sidebar switch and moving around beside the
/// window buttons, and the address below them.
struct SidebarToolbar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(spacing: Metrics.inset) {
            HStack(spacing: Metrics.rowGap) {
                Spacer(minLength: 0)
                BarButton(symbol: "sidebar.left", help: String(localized: "Hide Sidebar")) { browser.showSidebar.toggle() }
                if let tab = browser.active { NavigationButtons(tab: tab) } else { DisabledNavigationButtons() }
            }
            .padding(.leading, browser.fullScreen ? Metrics.inset : BrowserWindow.windowButtonsTrailing)
            .padding(.trailing, Metrics.inset)
            .frame(height: BrowserWindow.pageBarHeight)
            .padding(.top, BrowserWindow.cardInset)
            .background(WindowDragArea())
            Group {
                if let tab = browser.active {
                    if prefs.addressBarOnTop {
                        AddressField(tab: tab, browser: browser).id(tab.id)
                    } else {
                        AddressPill(tab: tab, compact: true, height: 32) { browser.commandBar = .editCurrent }
                    }
                } else {
                    AddressPlaceholder { browser.commandBar = .newTab }
                }
            }
            .padding(.horizontal, Metrics.inset)
        }
    }
}

/// The bar on top of the page card, as in Dia: the sidebar switch and moving around, the address with the page's title,
/// then what acts on the whole window.
struct PageBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        HStack(spacing: Metrics.rowGap) {
            if !browser.showSidebar && !browser.fullScreen { Color.clear.frame(width: BrowserWindow.windowButtonsTrailing - 2 * Metrics.inset) }
            BarButton(symbol: "sidebar.left", help: browser.showSidebar ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar")) { browser.showSidebar.toggle() }
            if let tab = browser.active { NavigationButtons(tab: tab) } else { DisabledNavigationButtons() }
            Group {
                if let tab = browser.active {
                    if prefs.addressBarOnTop {
                        AddressField(tab: tab, browser: browser).id(tab.id)
                    } else {
                        AddressPill(tab: tab) { browser.commandBar = .editCurrent }
                    }
                } else {
                    AddressPlaceholder { browser.commandBar = .newTab }
                }
            }
            .padding(.horizontal, Metrics.inset)
            if #available(macOS 15.4, *), !browser.isPrivate { ExtensionButtons(browser: browser) }
            DownloadButton(browser: browser, arrowEdge: .bottom)
            if browser.isPrivate {
                PrivateBadge()
            } else {
                AIButton(isOn: browser.showChat) { browser.showChat.toggle() }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: BrowserWindow.pageBarHeight)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.cardEdge).frame(height: 1) }
    }
}

struct NavigationButtons: View {
    @ObservedObject var tab: Tab

    var body: some View {
        BarButton(symbol: "chevron.left", help: String(localized: "Back (⌘[)")) { tab.webView?.goBack() }.disabled(!tab.canGoBack)
        BarButton(symbol: "chevron.right", help: String(localized: "Forward (⌘])")) { tab.webView?.goForward() }.disabled(!tab.canGoForward)
        BarButton(symbol: tab.isLoading ? "xmark" : "arrow.clockwise", help: String(localized: "Reload (⌘R)")) {
            if tab.isLoading { tab.webView?.stopLoading() } else { tab.webView?.reload() }
        }
    }
}

struct DisabledNavigationButtons: View {
    var body: some View {
        BarButton(symbol: "chevron.left", help: String(localized: "Back")) {}.disabled(true)
        BarButton(symbol: "chevron.right", help: String(localized: "Forward")) {}.disabled(true)
        BarButton(symbol: "arrow.clockwise", help: String(localized: "Reload")) {}.disabled(true)
    }
}

/// Nunsseop's search field: a softly filled rounded box; loading shows as its 3 pt bar along the bottom.
struct FieldBackground: View {
    @ObservedObject var tab: Tab
    var focused = false

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
            .fill(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: focused ? 0.5 : 0))
            .overlay(alignment: .bottom) {
                if tab.isLoading { Meter(fraction: tab.progress).padding(.horizontal, 10).padding(.bottom, 3).transition(.opacity) }
            }
            .animation(Motion.quick, value: tab.isLoading)
    }
}

struct AddressPill: View {
    @ObservedObject var tab: Tab
    /// In the narrow sidebar: the site alone, without the page's title or the ⌘L hint.
    var compact = false
    var height = Metrics.control
    let edit: () -> Void
    @ObservedObject private var library = LibraryWatcher.shared
    @State private var hover = false
    @StateObject private var press = PressState()

    private var pressed: Bool { press.isPressed }

    /// The page names itself, so its title sits behind a dot and may not start like the rest of an address ("/login", ".bank.com").
    /// Invisible characters (zero-width spaces, direction overrides, Hangul fillers) are taken out first, and stray
    /// marks are trimmed with the punctuation, so nothing can hide a leading "/".
    static func shownTitle(_ title: String, host: String?) -> String? {
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .privateUse, .unassigned, .surrogate, .lineSeparator, .paragraphSeparator]
        var visible = String.UnicodeScalarView()
        visible.append(contentsOf: title.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint && !hidden.contains($0.properties.generalCategory) })
        let marks: Set<Unicode.GeneralCategory> = [.nonspacingMark, .spacingMark, .enclosingMark]
        let trimmed = String(visible).drop {
            $0.isWhitespace || $0.isPunctuation || $0.isSymbol || $0.unicodeScalars.first.map { marks.contains($0.properties.generalCategory) } == true
        }
        guard !trimmed.isEmpty, String(trimmed) != host else { return nil }
        return String(trimmed)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.url?.scheme == "https" ? "lock.fill" : "globe")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            let host = tab.url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            Text(host ?? String(localized: "Enter Address"))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(Theme.primary)
                .layoutPriority(1)
            if !compact, let title = Self.shownTitle(tab.title, host: host) {
                Text(verbatim: "·").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.faint)
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 0)
            TranslateButton(tab: tab)
            LoginButton(tab: tab)
            PictureInPictureButton(tab: tab)
            if hover || AdBlocker.shared.isAllowed(tab.url?.host() ?? "") { AdBlockShield(tab: tab) }
            if hover || tab.url.map({ library.favoriteURLs.contains($0.absoluteString) }) == true { BookmarkStar(tab: tab) }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: height)
        .background(FieldBackground(tab: tab))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
                .fill(pressed ? Theme.hoverTab : hover ? Theme.ink(0.03) : .clear)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pressArea(press)
        .onTapGesture(perform: edit)
        .help("Edit Address (⌘L)")
    }
}

/// The whole address, edited in place.
struct AddressField: View {
    @ObservedObject var tab: Tab
    @ObservedObject var browser: Browser
    @State private var text = ""
    @FocusState private var focused: Bool

    private var current: String { tab.url?.absoluteString ?? "" }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.url?.scheme == "https" ? "lock.fill" : "globe")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.primary)
                .focused($focused)
                .onSubmit {
                    browser.open(text, in: .editCurrent)
                    focused = false
                }
                .onKeyPress(.escape) {
                    text = current
                    focused = false
                    return .handled
                }
            TranslateButton(tab: tab)
            LoginButton(tab: tab)
            PictureInPictureButton(tab: tab)
            AdBlockShield(tab: tab)
            BookmarkStar(tab: tab)
            Keycap(focused ? "↵" : "⌘L")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: Metrics.control)
        .background(FieldBackground(tab: tab, focused: focused))
        .onAppear { text = current }
        .onChange(of: tab.url) { if !focused { text = current } }
        .onChange(of: browser.addressFocusRequest) { focused = true }
        .onChange(of: focused) {
            if focused {
                DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
            } else {
                text = current
            }
        }
    }
}

struct AddressPlaceholder: View {
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
            Text("Search or enter address").font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .foregroundStyle(Theme.faint)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: Metrics.control)
        .background(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).fill(hover ? Theme.pill : Theme.field))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
    }
}

/// On a page in another language: translates it on this Mac, and brings the original back.
struct TranslateButton: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.foreignLanguage != nil || tab.translation != .original {
            Button { tab.toggleTranslation() } label: {
                Group {
                    if tab.translation == .translating {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "translate").font(.system(size: 10.5, weight: .semibold))
                    }
                }
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(tab.translation == .translated ? Theme.primary : Theme.dim)
            .help(tab.translation == .translated ? String(localized: "Show Original (⌥⌘T)") : String(localized: "Translate (⌥⌘T)"))
        }
    }
}

/// Ad blocking for the current site: filled while blocking, slashed when turned off here.
/// Shows while the tab plays sound (a video, most likely): floats it in picture in picture.
struct PictureInPictureButton: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.isPlayingAudio {
            Button { tab.pictureInPicture(.toggle) } label: {
                Image(systemName: "pip.enter").font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Picture in Picture (⌃⌘P)")
        }
    }
}

struct AdBlockShield: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        if prefs.blockTrackers, let host = tab.url?.host(), tab.url?.scheme?.hasPrefix("http") == true {
            let off = AdBlocker.shared.isAllowed(host)
            Button { AdBlocker.shared.toggleSite(host) } label: {
                Image(systemName: off ? "shield.slash" : "shield.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(off ? Theme.waiting : Theme.dim)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(off ? String(localized: "Turn on ad blocking for this site") : String(localized: "Turn off ad blocking for this site (if it breaks)"))
        }
    }
}

struct BookmarkStar: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var library = LibraryWatcher.shared

    var body: some View {
        let url = tab.url?.absoluteString ?? ""
        let marked = !url.isEmpty && library.favoriteURLs.contains(url)
        Button {
            guard !url.isEmpty else { return }
            let title = tab.title
            if !Library.shared.toggleBookmark(url: url, title: title) {
                tab.browser?.offerUndo(String(localized: "Removed from Favorites")) { _ = Library.shared.toggleBookmark(url: url, title: title) }
            }
        } label: {
            Image(systemName: marked ? "star.fill" : "star")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(marked ? Theme.primary : Theme.dim)
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(marked ? String(localized: "Remove from Favorites (⌘D)") : String(localized: "Add to Favorites (⌘D)"))
    }
}

/// Whether a bookmark's own tab is shown, open in the background, or not open.
enum BookmarkTabState {
    case closed, open, shown

    @MainActor
    init(_ key: String, _ browser: Browser) {
        guard let tab = browser.bookmarkTab(key) else { self = .closed; return }
        self = browser.isShown(tab) ? .shown : .open
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

struct FavoriteTile<MenuItems: View>: View {
    let entry: Library.Entry
    let state: BookmarkTabState
    let open: () -> Void
    @ViewBuilder let menu: () -> MenuItems
    @State private var hover = false

    var body: some View {
        SiteIcon(url: entry.url, size: 20)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.tile)
            .overlay(alignment: .bottom) {
                if state == .open { Circle().fill(Theme.dim).frame(width: 4, height: 4).padding(.bottom, 2) }
            }
            .rowChrome(hover: hover, selected: state == .shown, radius: Metrics.fieldRadius)
            .onTapGesture(perform: open)
            .onHover { hover = $0 }
            .contextMenu(menuItems: menu)
            .help(entry.title.isEmpty ? entry.url : entry.title)
    }
}

struct FolderRow<MenuItems: View>: View {
    let name: String
    var symbol = "folder"
    let count: Int
    let isOpen: Bool
    var showCount = true
    /// A bookmark is being dragged over it.
    var target = false
    let toggle: () -> Void
    @ViewBuilder let menu: () -> MenuItems
    @State private var hover = false

    var body: some View {
        HStack(spacing: Metrics.iconGap) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary).frame(width: Metrics.icon)
            Text(name).font(.row).foregroundStyle(Theme.body).lineLimit(1)
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                if showCount { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.faint).opacity(hover ? 0 : 1) }
                if hover { MoreButton(items: menu) }
            }
            .frame(minWidth: Metrics.action, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.faint)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .frame(width: Metrics.icon)
        }
        .padding(.leading, Metrics.rowPadding)
        .padding(.trailing, 4)
        .frame(height: Metrics.row)
        .rowChrome(hover: hover, target: target)
        .onHover { hover = $0 }
        .onTapGesture { withAnimation(Motion.standard) { toggle() } }
        .contextMenu(menuItems: menu)
    }
}

struct BookmarkRow<MenuItems: View>: View {
    let entry: Library.Entry
    let state: BookmarkTabState
    let open: () -> Void
    @ViewBuilder let menu: () -> MenuItems
    @State private var hover = false

    var body: some View {
        HStack(spacing: Metrics.iconGap) {
            SiteIcon(url: entry.url, size: Metrics.icon)
            Text(entry.title.isEmpty ? entry.url : entry.title)
                .font(state == .shown ? .rowSelected : .row)
                .foregroundStyle(state == .closed ? Theme.dim : Theme.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            ZStack {
                if hover {
                    MoreButton(items: menu)
                } else if state == .open {
                    Circle().fill(Theme.dim).frame(width: 4, height: 4)
                }
            }
            .frame(width: Metrics.action)
        }
        .padding(.leading, Metrics.rowPadding)
        .padding(.trailing, 4)
        .frame(height: Metrics.row)
        .rowChrome(hover: hover, selected: state == .shown)
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .contextMenu(menuItems: menu)
        .help(entry.url)
    }
}

/// A tab group in the tab list: click to fold it; its menu renames, ungroups or closes it. A tab dropped on it joins.
struct TabGroupHeader: View {
    let group: Browser.TabGroup
    let count: Int
    @ObservedObject var browser: Browser
    var target = false
    @State private var hover = false
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: Metrics.iconGap) {
            Image(systemName: "square.on.square").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary).frame(width: Metrics.icon)
            if browser.renamingGroup == group.id {
                TextField("Group name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.row)
                    .foregroundStyle(Theme.primary)
                    .focused($editing)
                    .onAppear {
                        name = group.name
                        // Focus taken in the same pass as the field appears is sometimes dropped.
                        DispatchQueue.main.async { editing = true }
                    }
                    .onSubmit(commit)
                    .onChange(of: editing) { if !editing { commit() } }
                    .onKeyPress(.escape) {
                        browser.renamingGroup = nil
                        return .handled
                    }
            } else {
                Text(group.name).font(.row).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.faint).opacity(hover ? 0 : 1)
                if hover && browser.renamingGroup != group.id { MoreButton { menu } }
            }
            .frame(minWidth: Metrics.action, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.faint)
                .rotationEffect(.degrees(group.isOpen ? 90 : 0))
                .frame(width: Metrics.icon)
        }
        .padding(.leading, Metrics.rowPadding)
        .padding(.trailing, 4)
        .frame(height: Metrics.row)
        .rowChrome(hover: hover, target: target)
        .onHover { hover = $0 }
        .onTapGesture {
            guard browser.renamingGroup != group.id else { return }
            withAnimation(Motion.standard) { browser.toggleGroup(group.id) }
        }
        .contextMenu { menu }
        .help(group.isOpen ? String(localized: "Collapse") : String(localized: "Expand"))
    }

    @ViewBuilder private var menu: some View {
        Button("Rename") { browser.renamingGroup = group.id }
        Button("Ungroup") { withAnimation(Motion.standard) { browser.ungroup(group.id) } }
        Divider()
        Button("Close All Tabs in Group") { withAnimation(Motion.standard) { browser.closeGroup(group.id) } }
    }

    private func commit() {
        guard browser.renamingGroup == group.id else { return }
        browser.rename(group.id, to: name)
        browser.renamingGroup = nil
    }
}

/// Sorts the tabs in no group into groups; a spinner while the model thinks.
struct TidyButton: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Button { browser.tidyTabs() } label: {
            Group {
                if browser.tidying {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: "wand.and.stars").font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: Metrics.row, height: Metrics.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(FillStyle(hoverFill: Theme.hoverTab))
        .foregroundStyle(Theme.secondary)
        .disabled(browser.tidying)
        .help("Tidy Tabs: group tabs that are not in a group by similarity")
    }
}

extension Browser.Tidy {
    var message: String {
        let count = tabs
        if made.isEmpty {
            return count == 1 ? String(localized: "Added \(count) tab to a group") : String(localized: "Added \(count) tabs to groups")
        }
        return count == 1 ? String(localized: "Tidied \(count) tab") : String(localized: "Tidied \(count) tabs")
    }
}

/// Under the new tab row for a few seconds after something that can be taken back.
struct UndoNotice: View {
    let message: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: Metrics.iconGap) {
            Text(message)
                .font(.row)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: undo) {
                Text("Undo").font(.rowSelected).padding(.horizontal, Metrics.rowPadding).frame(height: Metrics.action).contentShape(Rectangle())
            }
            .buttonStyle(FillStyle(resting: Theme.field, hoverFill: Theme.pill, radius: 6))
            .foregroundStyle(Theme.primary)
        }
        .padding(.leading, Metrics.rowPadding)
        .padding(.trailing, 4)
        .frame(height: Metrics.row)
    }
}

struct NewTabRow: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: Metrics.iconGap) {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: Metrics.icon)
            Text("New Tab").font(.row)
            Spacer()
        }
        .foregroundStyle(Theme.secondary)
        .padding(.leading, Metrics.rowPadding)
        .padding(.trailing, 4)
        .frame(height: Metrics.row)
        .rowChrome(hover: hover)
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .help("New Tab (⌘T)")
    }
}

struct SidebarTabRow: View {
    @ObservedObject var tab: Tab
    let browser: Browser
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: Metrics.iconGap) {
            Favicon(tab: tab)
            Text(tab.displayTitle)
                .font(isActive ? .rowSelected : .row)
                .lineLimit(1)
                .foregroundStyle(isActive || !tab.isAsleep ? Theme.primary : Theme.dim)
            Spacer(minLength: 0)
            if tab.isPlayingAudio || tab.isMuted {
                HoverAction(symbol: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            help: tab.isMuted ? String(localized: "Unmute (⌃⌘M)") : String(localized: "Mute (⌃⌘M)")) { tab.toggleMute() }
            }
            // One slot, always the same width, so the title doesn't move when the pointer comes and goes.
            ZStack {
                if hover {
                    HoverAction(symbol: "xmark", help: String(localized: "Close Tab (⌘W)"), action: close)
                } else if browser.split?.contains(tab.id) == true {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .help("Split View")
                }
            }
            .frame(width: Metrics.action)
        }
        .padding(.leading, Metrics.rowPadding)
        .padding(.trailing, 4)
        .frame(height: Metrics.row)
        .rowChrome(hover: hover, selected: isActive)
        .onHover { hover = $0 }
        .onTapGesture(perform: select)
        .contextMenu { menu }
        .help(tab.url?.absoluteString ?? "")
    }

    /// The tab, then where it goes, then closing it: the same order as a bookmark's menu.
    @ViewBuilder private var menu: some View {
        Button("Reload") {
            if tab.isAsleep { browser.activate(tab.id) } else { tab.webView?.reload() }
        }
        Button("Duplicate Tab") { browser.duplicate(tab.id) }
        Button("Move to New Window") { browser.moveToNewWindow(tab.id) }
        if let url = tab.url, url.scheme?.hasPrefix("http") == true {
            ShareLink(item: url)
            OpenInMenu(url: url)
        }
        Divider()
        if browser.split?.contains(tab.id) == true {
            Button("End Split View") { browser.unsplit() }
        } else if !isActive && browser.activeID != nil {
            Button("Show Side by Side with Current Tab") { browser.split(with: tab.id) }
        }
        Button("Copy Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url?.absoluteString ?? "", forType: .string)
        }
        if !tab.isAsleep { Button(tab.isMuted ? String(localized: "Unmute") : String(localized: "Mute Tab")) { tab.toggleMute() } }
        Divider()
        Button("Pin to Favorites") {
            if let url = tab.url?.absoluteString {
                if !Library.shared.isFavorite(url) { _ = Library.shared.toggleBookmark(url: url, title: tab.title) }
                browser.bind(tab, to: Browser.bookmarkKey(url: url, folder: Library.favoritesFolder))
            }
        }
        if tab.groupID == nil {
            Button("Add to New Group") { _ = withAnimation(Motion.standard) { browser.group([tab.id]) } }
        } else {
            Button("Remove from Group") { withAnimation(Motion.standard) { browser.removeFromGroup(tab.id) } }
        }
        let otherGroups = browser.groups.filter { $0.id != tab.groupID }
        if !otherGroups.isEmpty {
            Menu("Move to Group") {
                ForEach(otherGroups) { group in
                    Button(group.name) { withAnimation(Motion.standard) { browser.addTab(tab.id, to: group.id) } }
                }
            }
        }
        Divider()
        Button("Close Tab", action: close)
    }
}

/// A site's icon for a bookmark that may not be open: from the tab favicons, the disk cache or the site.
struct SiteIcon: View {
    let url: String
    let size: CGFloat
    /// False for a private window's page: the icon isn't saved to disk.
    var keep = true
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                IconImage(image: image, size: size)
            } else {
                Image(systemName: "globe").font(.system(size: size * 0.7)).foregroundStyle(Theme.faint)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { image = await Browser.icon(for: url, keep: keep) }
    }
}

struct BarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: Metrics.control, height: Metrics.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(FillStyle())
        .foregroundStyle(enabled ? Theme.secondary : Theme.ink(0.22))
        .help(help)
    }
}

/// Like Nunsseop's selected tab: a capsule with a symbol and a word, brighter while the panel is open.
struct AIButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                Text("AI").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: Metrics.control)
            .foregroundStyle(Theme.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(FillStyle(resting: isOn ? Theme.pill : Theme.hoverTab, hoverFill: isOn ? Theme.pill : Theme.field, radius: nil))
        .help("AI Panel (⌘E)")
    }
}

/// Where the AI button would be, in a private window.
struct PrivateBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash").font(.system(size: 11, weight: .semibold))
            Text("Private Window").font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.control)
        .foregroundStyle(Theme.primary)
        .background(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .help("Leaves no history, cookies or site data. AI and extensions can’t see this window.")
    }
}

struct Favicon: View {
    @ObservedObject var tab: Tab

    var body: some View {
        Group {
            if tab.isLoading && tab.favicon == nil {
                ProgressView().controlSize(.mini)
            } else if let image = tab.favicon {
                IconImage(image: image, size: 16)
            } else if let url = tab.url?.absoluteString {
                // A sleeping tab has no page to ask; the site's saved icon stands in.
                SiteIcon(url: url, size: 16, keep: !tab.isPrivate)
            } else {
                Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
        }
        .frame(width: 16, height: 16)
        .opacity(tab.isAsleep ? 0.6 : 1)
    }
}

/// Empty parts of the bar move the window, and a double click zooms it.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

// MARK: Web content

struct WebCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var overlay: PageOverlay

    init(browser: Browser) {
        self.browser = browser
        overlay = browser.overlay
    }

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                if browser.findBarVisible {
                    FindBar(browser: browser, overlay: overlay).transition(Motion.pop(.topTrailing))
                }
            }
            .overlay(alignment: .top) {
                if let tab = browser.active {
                    VStack(spacing: 0) {
                        LoginOfferBar(tab: tab)
                        PopupBar(tab: tab)
                        if #available(macOS 15.4, *), !browser.isPrivate { WebStoreBar(tab: tab, host: ExtensionHost.shared) }
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let text = overlay.statusMessage ?? overlay.hoveredLink.map(StatusLine.display) {
                    StatusLine(text: text).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: overlay.hoveredLink)
            .animation(.easeOut(duration: 0.12), value: overlay.statusMessage)
            .animation(Motion.quick, value: browser.findBarVisible)
    }

    @ViewBuilder private var content: some View {
        if let split = browser.shownSplit, let left = browser.tab(split.left), let right = browser.tab(split.right) {
            GeometryReader { geo in
                let width = max(1, geo.size.width - SplitDivider.width)
                HStack(spacing: 0) {
                    pane(left).frame(width: (width * overlay.splitFraction).rounded())
                    SplitDivider(fraction: $overlay.splitFraction, total: width)
                    pane(right)
                }
            }
        } else {
            pane(browser.active)
        }
    }

    private func pane(_ tab: Tab?) -> some View {
        // In a split, the pane with the active tab (what the address bar and keys act on) wears the hairline.
        let focused = browser.shownSplit != nil && tab?.id == browser.activeID
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
        return ZStack {
            if let tab {
                Theme.page
                WebViewHost(tab: tab, browser: browser)
            } else {
                Theme.card
                EmptyPage()
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(focused ? Theme.secondary : .clear, lineWidth: 1))
    }
}

/// "Save this sign-in?" over the top of the page, after a password was submitted.
struct LoginOfferBar: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if let offer = tab.loginOffer {
            let site = offer.host.hasPrefix("www.") ? String(offer.host.dropFirst(4)) : offer.host
            HStack(spacing: 8) {
                Image(systemName: "key.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text("Save login info for \(site)?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if !offer.username.isEmpty {
                    Text(offer.username).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer(minLength: 8)
                PeekAction(title: String(localized: "Save")) {
                    if Logins.save(host: offer.host, username: offer.username, password: offer.password) {
                        tab.browser?.flashStatus(String(localized: "Login info saved"))
                    }
                    tab.loginOffer = nil
                    tab.checkForLogins()
                }
                Button("Never for This Site") {
                    Preferences.shared.neverSaveLoginHosts.append(site.lowercased())
                    tab.loginOffer = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 4)
                BarButton(symbol: "xmark", help: String(localized: "Close")) { tab.loginOffer = nil }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 40)
            .frame(maxWidth: 620)
            .floatingPanel(radius: 12)
            .padding(10)
            .transition(Motion.pop(.top))
        }
    }
}

/// "A popup was blocked" over the top of the page, with the way to open it, once or always for this site.
struct PopupBar: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if let popup = tab.blockedPopup {
            HStack(spacing: 8) {
                Image(systemName: "macwindow.badge.plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text("Pop-up blocked").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                Text(popup.host() ?? popup.absoluteString).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1)
                Spacer(minLength: 8)
                PeekAction(title: String(localized: "Open")) { tab.openBlockedPopup(always: false) }
                if !tab.isPrivate {
                    Button("Always Allow for This Site") { tab.openBlockedPopup(always: true) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 4)
                }
                BarButton(symbol: "xmark", help: String(localized: "Close")) { tab.blockedPopup = nil }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 40)
            .frame(maxWidth: 620)
            .floatingPanel(radius: 12)
            .padding(10)
            .transition(Motion.pop(.top))
        }
    }
}

/// On a Chrome Web Store extension page: install it into Changmun (the store's own button only works in Chrome).
@available(macOS 15.4, *)
struct WebStoreBar: View {
    @ObservedObject var tab: Tab
    @ObservedObject var host: ExtensionHost

    var body: some View {
        if let url = tab.url, let id = ChromeWebStore.extensionID(from: url.absoluteString) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text(host.isInstalled(chromeWebStoreID: id) ? String(localized: "This extension is installed in Changmun") : String(localized: "You can use this extension in Changmun"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if let error = host.storeErrors[id] {
                    Text(error).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.waiting).lineLimit(1)
                }
                Spacer(minLength: 8)
                if host.installing.contains(id) {
                    ProgressView().controlSize(.small).padding(.horizontal, 8)
                } else {
                    PeekAction(title: host.isInstalled(chromeWebStoreID: id) ? String(localized: "Update") : String(localized: "Add to Changmun")) {
                        Task { await host.installFromChromeWebStore(id) }
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 40)
            .frame(maxWidth: 620)
            .floatingPanel(radius: 12)
            .padding(10)
        }
    }
}

/// Between the halves of a split: drag to share the width, double-click to halve it.
struct SplitDivider: View {
    static let width: CGFloat = 8
    @Binding var fraction: Double
    let total: CGFloat
    @State private var start: Double?
    @State private var hover = false

    var body: some View {
        Capsule()
            .fill(hover || start != nil ? Theme.secondary : Theme.hairline)
            .frame(width: 3, height: 32)
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hover { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let base = start ?? fraction
                        start = base
                        fraction = Browser.clampedSplitFraction(base + drag.translation.width / total)
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { fraction = 0.5 }
            .help("Drag to resize · double-click to split evenly")
    }
}

/// A ⇧-clicked link floating over the window: esc or a click outside closes it, ⌘↩ keeps it as a tab.
struct PeekCard: View {
    @ObservedObject var tab: Tab
    @ObservedObject var browser: Browser

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture { browser.closePeek() }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Favicon(tab: tab)
                    Text(tab.url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    PeekAction(title: String(localized: "Open as Tab"), key: "⌘↩") { browser.keepPeek() }
                    PeekAction(title: String(localized: "Close"), key: "esc") { browser.closePeek() }
                }
                .padding(.leading, 6)
                .frame(height: 30)
                ZStack(alignment: .top) {
                    Theme.page
                    WebViewHost(tab: tab, browser: browser)
                    LoginOfferBar(tab: tab)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .top) {
                    if tab.isLoading { Meter(fraction: tab.progress).padding(.horizontal, 12).padding(.top, 4).transition(.opacity) }
                }
            }
            .padding(10)
            .floatingPanel(radius: 16)
            .frame(maxWidth: 1180)
            .padding(.horizontal, 64)
            .padding(.top, BrowserWindow.barHeight)
            .padding(.bottom, 32)
        }
        .animation(Motion.quick, value: tab.isLoading)
    }
}

/// ⌃Tab: the tabs most recently shown first; let go of ⌃ to go to the picked one. It shows only if ⌃ is held a moment.
struct TabSwitcherView: View {
    @ObservedObject var browser: Browser
    let switcher: Browser.TabSwitcher
    @State private var shown = false

    var body: some View {
        let picked = switcher.order[switcher.index]
        let tabs = switcher.order.compactMap { browser.tab($0) }
        let index = tabs.firstIndex { $0.id == picked } ?? 0
        // Ten rows at most, scrolled to keep the pick in view.
        let first = max(0, min(index - 4, tabs.count - 10))
        VStack(spacing: 2) {
            ForEach(tabs.dropFirst(first).prefix(10)) { tab in
                HStack(spacing: 9) {
                    Favicon(tab: tab)
                    Text(tab.displayTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(tab.url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background { if tab.id == picked { SelectedBackground() } }
                .contentShape(Rectangle())
                .onTapGesture { browser.finishSwitching(to: tab.id) }
            }
        }
        .padding(8)
        .frame(width: 460)
        .floatingPanel(radius: 16)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown || Motion.reduced ? 1 : 0.97)
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(Motion.quick) { shown = true }
        }
    }
}

struct PeekAction: View {
    let title: String
    var key: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let key { Keycap(key) }
            }
            .padding(.leading, Metrics.rowPadding)
            .padding(.trailing, key == nil ? Metrics.rowPadding : 4)
            .frame(height: Metrics.row)
            .foregroundStyle(Theme.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(FillStyle())
    }
}

/// The link under the pointer (or a short message), bottom left of the page like Safari's status bar.
struct StatusLine: View {
    let text: String

    static func display(_ href: String) -> String {
        guard let url = URL(string: href), let host = url.host() else { return href.removingPercentEncoding ?? href }
        let rest = String(href.dropFirst((url.scheme?.count ?? 0) + 3 + host.count))
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + (rest.removingPercentEncoding ?? rest)
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(.black.opacity(0.8)))
            .frame(maxWidth: 520, alignment: .leading)
            .padding(8)
            .allowsHitTesting(false)
    }
}

struct WebViewHost: NSViewRepresentable {
    @ObservedObject var tab: Tab
    let browser: Browser

    final class Container: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ container: Container, context: Context) {
        guard let webView = tab.webView else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        // A host fading out (a closed peek, a split that ended) must not take the page back from the one showing it.
        guard webView.superview !== container, browser.isShown(tab) || browser.peek === tab else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        DispatchQueue.main.async {
            let shown = tab.id == browser.activeID || browser.peek === tab
            if shown, browser.commandBar == nil, browser.showOnboarding == false { container.window?.makeFirstResponder(webView) }
        }
    }
}

struct EmptyPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.ink(0.3))
            HStack(spacing: 6) {
                Text("New Tab").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.faint)
                Keycap("⌘T")
                Text("AI").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.faint).padding(.leading, 8)
                Keycap("⌘E")
            }
        }
    }
}

// MARK: Command bar

struct CommandBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var chat: ChatStore
    @ObservedObject private var prefs = Preferences.shared
    let mode: CommandBarMode
    @State private var text = ""
    @State private var selection = 0
    @StateObject private var source = SuggestionSource()
    @FocusState private var focused: Bool

    enum Suggestion: Hashable {
        case open(String)
        case search(String)
        case suggested(String)
        case ask(String)
        case tab(id: Int, url: String, title: String)
        case page(url: String, title: String)
    }

    /// Typing an address or words: open or search it, ask the AI, switch to a matching open tab, the engine's
    /// suggestions, then bookmarks and history. The local and remote parts arrive from `source` as they're ready.
    private var suggestions: [Suggestion] {
        let query = text.trimmingCharacters(in: .whitespaces)
        if query.isEmpty || (mode == .editCurrent && query == browser.active?.url?.absoluteString) {
            return source.pages.map { .page(url: $0.url, title: $0.title) }
        }
        var list: [Suggestion] = [AddressInput.isAddress(query) ? .open(query) : .search(query)]
        if !browser.isPrivate { list.append(.ask(query)) }
        let tabs = Self.matchingTabs(browser.tabs.filter { $0.id != browser.activeID }, query)
        list += tabs.prefix(3).map { .tab(id: $0.id, url: $0.url?.absoluteString ?? "", title: $0.displayTitle) }
        list += source.searches.prefix(4).map { .suggested($0) }
        let open = Set(tabs.compactMap { $0.url?.absoluteString })
        list += source.pages.filter { !open.contains($0.url) }.prefix(6).map { .page(url: $0.url, title: $0.title) }
        return list
    }

    /// Open tabs whose title or address holds every word.
    static func matchingTabs(_ tabs: [Tab], _ query: String) -> [Tab] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        return tabs.filter { tab in
            let haystack = (tab.title + " " + (tab.url?.absoluteString ?? "")).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        let items = suggestions
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: mode == .editCurrent ? "link" : "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    TextField(browser.isPrivate ? String(localized: "Search or enter an address") : String(localized: "Search, enter an address or ask AI"), text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .focused($focused)
                        .onSubmit { run(items.indices.contains(selection) ? items[selection] : nil) }
                        .onChange(of: text) {
                            selection = 0
                            refresh()
                        }
                    Keycap("esc")
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                if !items.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            SuggestionRow(item: item, selected: index == selection)
                                .onTapGesture { run(item) }
                                .onHover { if $0 { selection = index } }
                        }
                    }
                }
            }
            .padding(10)
            .frame(width: 620)
            .floatingPanel(radius: 16)
            .padding(.top, 96)
            .onKeyPress(.downArrow) { selection = max(0, min(selection + 1, items.count - 1)); return .handled }
            .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
            .onKeyPress(.escape) { dismiss(); return .handled }
        }
        .onChange(of: items) { old, new in keepSelection(old, new) }
        .onAppear {
            text = mode == .editCurrent ? (browser.active?.url?.absoluteString ?? "") : ""
            refresh()
            NSApp.keyWindow?.makeFirstResponder(nil)
            DispatchQueue.main.async { focused = true }
        }
    }

    /// Bookmarks for an empty field (or the current address, untouched); otherwise a search as the user types.
    private func refresh() {
        let query = text.trimmingCharacters(in: .whitespaces)
        if query.isEmpty || (mode == .editCurrent && query == browser.active?.url?.absoluteString) {
            source.update("", remote: false)
        } else {
            source.update(text, remote: prefs.searchSuggestions && !browser.isPrivate)
        }
    }

    /// Results arrive while the user moves through them: the highlight stays on the same row, wherever it went.
    private func keepSelection(_ old: [Suggestion], _ new: [Suggestion]) {
        if old.indices.contains(selection), let index = new.firstIndex(of: old[selection]) {
            selection = index
        } else {
            selection = 0
        }
    }

    private func dismiss() {
        browser.commandBar = nil
    }

    private func run(_ item: Suggestion?) {
        switch item {
        case .open(let input), .search(let input), .suggested(let input):
            browser.open(input, in: mode)
        case .tab(let id, _, _):
            browser.activate(id)
            browser.commandBar = nil
        case .ask(let question):
            browser.commandBar = nil
            browser.showChat = true
            chat.send(question)
        case .page(let url, _):
            browser.open(url, in: mode)
        case nil:
            break
        }
    }
}

struct SuggestionRow: View {
    let item: CommandBar.Suggestion
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 20)
            label
            Spacer(minLength: 0)
            if selected { Keycap("↵") }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background { if selected { SelectedBackground() } }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .open: Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
        case .search, .suggested: Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
        case .tab(_, let url, _): SiteIcon(url: url, size: 16)
        case .ask: Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
        case .page(let url, _): SiteIcon(url: url, size: 16)
        }
    }

    @ViewBuilder private var label: some View {
        switch item {
        case .open(let text):
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
        case .search(let text):
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
            Text("Search").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint)
        case .suggested(let text):
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
        case .tab(_, let url, let title):
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
            Text("Switch to Tab").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint)
            Text(URL(string: url)?.host() ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1)
        case .ask(let text):
            Text("Ask AI").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
        case .page(let url, let title):
            Text(title.isEmpty ? url : title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
            Text(URL(string: url)?.host() ?? url).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1)
        }
    }
}
