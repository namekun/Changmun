import AppKit
import SwiftUI
import WebKit

/// Nunsseop's look: a black (or, in light mode, near-white) ground, ink at a few fixed opacities, hairlines instead of cards,
/// and colour only where it means something: orange when something needs you, green while work is going on.
enum Theme {
    static let background = dynamic(light: NSColor(red: 0.957, green: 0.957, blue: 0.961, alpha: 1), dark: .black)
    static let page = Color.white

    /// White on black, black on white.
    static func ink(_ opacity: Double) -> Color {
        dynamic(light: NSColor(white: 0, alpha: opacity), dark: NSColor(white: 1, alpha: opacity))
    }

    static let primary = ink(1)
    static let body = ink(0.9)
    static let secondary = ink(0.6)
    static let dim = ink(0.55)
    static let faint = ink(0.45)
    static let hairline = ink(0.24)
    static let pill = ink(0.16)
    static let field = ink(0.1)
    static let selected = ink(0.08)
    static let hoverTab = ink(0.07)
    static let track = ink(0.15)
    static let meter = ink(0.75)
    static let waiting = Color(red: 1.0, green: 0.62, blue: 0.2)
    static let working = Color(red: 0.31, green: 0.82, blue: 0.47)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    static var nsBackground: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : NSColor(red: 0.957, green: 0.957, blue: 0.961, alpha: 1) }
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

/// A selected row or tile: a faint fill inside a hairline, as in Nunsseop's lists.
struct SelectedBackground: View {
    var radius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.selected)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
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

/// A quiet section label, sentence case, with an optional count on the right.
struct SectionCaption: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.faint) }
        }
        .frame(height: 16)
        .padding(.horizontal, 8)
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
        ZStack {
            Theme.background
            HStack(spacing: 0) {
                if browser.showSidebar {
                    Sidebar(browser: browser)
                        .frame(width: prefs.sidebarWidth)
                        .overlay(alignment: .trailing) { SidebarResizeHandle(width: $prefs.sidebarWidth) }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    if !browser.showSidebar {
                        CompactBar(browser: browser)
                    } else if prefs.addressBarOnTop {
                        TopAddressBar(browser: browser)
                            .padding(.trailing, 8)
                            .frame(height: BrowserWindow.barHeight)
                            .background(WindowDragArea())
                    }
                    HStack(spacing: 0) {
                        WebCard(browser: browser)
                        if browser.showChat {
                            HStack(spacing: 0) {
                                Hairline(vertical: true).padding(.horizontal, 8)
                                ChatPanel(chat: chat, browser: browser)
                            }
                            .frame(minWidth: 300, maxWidth: 360)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .padding(.top, browser.showSidebar && !prefs.addressBarOnTop ? 8 : 0)
                    .padding([.trailing, .bottom], 8)
                    .padding(.leading, browser.showSidebar ? 0 : 8)
                }
            }
            if let peek = browser.peek {
                PeekCard(tab: peek, browser: browser).transition(.opacity)
            }
            if let mode = browser.commandBar, !browser.showOnboarding {
                CommandBar(browser: browser, chat: chat, mode: mode)
            }
            if browser.showOnboarding {
                OnboardingView(browser: browser)
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.22), value: browser.showChat)
        .animation(.easeOut(duration: 0.22), value: browser.showSidebar)
        .animation(.easeOut(duration: 0.22), value: prefs.addressBarOnTop)
        .animation(.easeOut(duration: 0.14), value: browser.commandBar)
        .animation(.easeOut(duration: 0.16), value: browser.peek?.id)
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var prefs = Preferences.shared
    @StateObject private var library = LibraryWatcher()
    @State private var openFolders: Set<String> = []
    @AppStorage("sidebarBookmarksOpen") private var showBookmarks = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 70)
                Spacer(minLength: 0)
                BarButton(symbol: "sidebar.left", help: "사이드바 숨기기") { browser.showSidebar = false }
                if let tab = browser.active { NavigationButtons(tab: tab) } else { DisabledNavigationButtons() }
            }
            .padding(.trailing, 8)
            .frame(height: BrowserWindow.barHeight)
            .background(WindowDragArea())

            if !prefs.addressBarOnTop {
                Group {
                    if let tab = browser.active {
                        AddressPill(tab: tab) { browser.commandBar = .editCurrent }
                    } else {
                        AddressPlaceholder { browser.commandBar = .newTab }
                    }
                }
                .padding(.horizontal, 12)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !library.favorites.isEmpty {
                        // As many tiles a row as the sidebar's width holds: four at the default width, up to seven when wide.
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 6)], spacing: 6) {
                            ForEach(library.favorites, id: \.url) { entry in
                                let key = Browser.bookmarkKey(url: entry.url, folder: Library.favoritesFolder)
                                FavoriteTile(entry: entry, state: BookmarkTabState(key, browser)) {
                                    browser.openBookmark(entry.url, key: key, inNewTab: Browser.commandClick)
                                } closeTab: {
                                    if let tab = browser.bookmarkTab(key) { browser.close(tab.id) }
                                } remove: {
                                    Library.shared.removeBookmark(url: entry.url, folder: Library.favoritesFolder)
                                } split: {
                                    splitItem(url: entry.url, key: key)
                                }
                                .draggable(SidebarDrag.favorite(entry.url))
                                .dropDestination(for: String.self) { items, _ in
                                    SidebarDrag.drop(items, onFavorite: entry.url, browser: browser)
                                }
                            }
                        }
                        .padding(.bottom, 14)
                    }
                    SectionCaption(text: "탭", trailing: "\(browser.listedTabs.count)").padding(.bottom, 4)
                    NewTabRow { browser.commandBar = .newTab }
                    ForEach(browser.listedTabs) { tab in
                        SidebarTabRow(tab: tab, browser: browser, isActive: tab.id == browser.activeID) {
                            browser.activate(tab.id)
                        } close: {
                            browser.close(tab.id)
                        }
                        .draggable(SidebarDrag.tab(tab.id))
                        .dropDestination(for: String.self) { items, _ in
                            SidebarDrag.drop(items, onTab: tab.id, browser: browser)
                        }
                    }
                    if !library.sources.isEmpty {
                        SectionHeader(title: "북마크", isOpen: showBookmarks) { showBookmarks.toggle() }
                            .padding(.top, 14)
                            .padding(.bottom, 2)
                        if showBookmarks {
                            ForEach(library.sources, id: \.source) { group in
                                let key = "source:" + group.source
                                FolderRow(name: group.source, symbol: "books.vertical", count: group.folders.reduce(0) { $0 + $1.entries.count },
                                          isOpen: openFolders.contains(key)) { toggle(key) }
                                    .contextMenu {
                                        Button("\(group.source) 북마크 모두 삭제…") {
                                            if confirmDelete("\(group.source)에서 가져온 북마크를 모두 지울까요?") { Library.shared.removeSource(group.source) }
                                        }
                                    }
                                if openFolders.contains(key) {
                                    ForEach(group.folders, id: \.key) { folder in
                                        FolderRow(name: folder.label, symbol: "folder", count: folder.entries.count, isOpen: openFolders.contains(folder.key)) {
                                            toggle(folder.key)
                                        }
                                        .padding(.leading, 12)
                                        .help(folder.key)
                                        .contextMenu {
                                            Button("폴더 삭제…") {
                                                if confirmDelete("'\(folder.label)' 폴더와 안의 북마크 \(folder.entries.count)개를 지울까요?") {
                                                    Library.shared.removeFolder(folder.key)
                                                }
                                            }
                                        }
                                        if openFolders.contains(folder.key) {
                                            ForEach(folder.entries, id: \.url) { entry in
                                                let key = Browser.bookmarkKey(url: entry.url, folder: folder.key)
                                                BookmarkRow(entry: entry, state: BookmarkTabState(key, browser)) {
                                                    browser.openBookmark(entry.url, key: key, inNewTab: Browser.commandClick)
                                                } closeTab: {
                                                    if let tab = browser.bookmarkTab(key) { browser.close(tab.id) }
                                                } remove: {
                                                    Library.shared.removeBookmark(url: entry.url, folder: folder.key)
                                                } split: {
                                                    splitItem(url: entry.url, key: key)
                                                }
                                                .padding(.leading, 26)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .animation(.easeOut(duration: 0.18), value: browser.tabs.map(\.id))
            }

            HStack(spacing: 4) {
                if browser.isPrivate {
                    PrivateBadge()
                    Spacer()
                } else {
                    AIButton(isOn: browser.showChat) { browser.showChat.toggle() }
                    Spacer()
                    if #available(macOS 15.4, *) { ExtensionButtons(browser: browser) }
                    BarButton(symbol: "arrow.down.circle", help: "다운로드") {
                        NSApp.sendAction(#selector(AppDelegate.showDownloads(_:)), to: nil, from: nil)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
        }
    }

    /// The split item in a bookmark's menu: end the split it is in, or show it next to the active tab.
    @ViewBuilder private func splitItem(url: String, key: String) -> some View {
        let tab = browser.bookmarkTab(key)
        if let tab, browser.split?.contains(tab.id) == true {
            Button("분할 보기 끝내기") { browser.unsplit() }
        } else if browser.activeID != nil && tab?.id != browser.activeID {
            Button("지금 탭 옆에 나란히 보기") { browser.split(withBookmark: url, key: key) }
        }
    }

    private func confirmDelete(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "삭제").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func toggle(_ key: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            if openFolders.contains(key) { openFolders.remove(key) } else { openFolders.insert(key) }
        }
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
            .help("끌어서 사이드바 폭 조절 · 더블클릭하면 기본 폭")
    }
}

struct SectionHeader: View {
    let title: String
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .opacity(hover ? 1 : 0.7)
            Spacer()
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { toggle() } }
    }
}

/// Dragging tabs and favorites around the sidebar: the payload names what is dragged.
@MainActor
enum SidebarDrag {
    static func tab(_ id: Int) -> String { "changmun-tab:\(id)" }
    static func favorite(_ url: String) -> String { "changmun-favorite:" + url }

    static func drop(_ items: [String], onTab target: Int, browser: Browser) -> Bool {
        guard let item = items.first, item.hasPrefix("changmun-tab:"), let id = Int(item.dropFirst("changmun-tab:".count)) else { return false }
        withAnimation(.easeOut(duration: 0.18)) { browser.moveTab(id, to: target) }
        return true
    }

    /// A favorite dropped on a favorite moves there; a tab dropped on one is pinned there.
    static func drop(_ items: [String], onFavorite target: String, browser: Browser) -> Bool {
        guard let item = items.first else { return false }
        if item.hasPrefix("changmun-favorite:") {
            Library.shared.moveFavorite(String(item.dropFirst("changmun-favorite:".count)), to: target)
            return true
        }
        if item.hasPrefix("changmun-tab:"), let id = Int(item.dropFirst("changmun-tab:".count)),
           let tab = browser.tab(id), let url = tab.url?.absoluteString {
            if !Library.shared.isFavorite(url) { _ = Library.shared.toggleBookmark(url: url, title: tab.title) }
            browser.bind(tab, to: Browser.bookmarkKey(url: url, folder: Library.favoritesFolder))
            Library.shared.moveFavorite(url, to: target)
            return true
        }
        return false
    }
}

/// Re-reads the bookmarks whenever the library changes.
@MainActor
final class LibraryWatcher: ObservableObject {
    @Published private(set) var favorites: [Library.Entry] = []
    @Published private(set) var sources: [(source: String, folders: [Library.Folder])] = []
    private var observer: NSObjectProtocol?

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(forName: Library.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        favorites = Library.shared.favorites()
        let folders = Library.shared.folders()
        sources = Library.groupBySource(folders)
        var keys = Set(favorites.map { Browser.bookmarkKey(url: $0.url, folder: Library.favoritesFolder) })
        for folder in folders { for entry in folder.entries { keys.insert(Browser.bookmarkKey(url: entry.url, folder: folder.name)) } }
        for browser in Browser.all { browser.releaseBookmarkTabs(keeping: keys) }
    }
}

/// The top bar when the sidebar is hidden.
struct CompactBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: 70)
            BarButton(symbol: "sidebar.left", help: "사이드바 보기") { browser.showSidebar = true }
            if let tab = browser.active { NavigationButtons(tab: tab) } else { DisabledNavigationButtons() }
            if prefs.addressBarOnTop {
                TopAddressBar(browser: browser).padding(.horizontal, 8)
            } else {
                Spacer(minLength: 12)
                if let tab = browser.active {
                    AddressPill(tab: tab) { browser.commandBar = .editCurrent }.frame(maxWidth: 460)
                }
                Spacer(minLength: 12)
            }
            if browser.isPrivate {
                PrivateBadge()
            } else {
                AIButton(isOn: browser.showChat) { browser.showChat.toggle() }
            }
        }
        .padding(.trailing, 10)
        .frame(height: BrowserWindow.barHeight)
        .background(WindowDragArea())
    }
}

struct NavigationButtons: View {
    @ObservedObject var tab: Tab

    var body: some View {
        BarButton(symbol: "chevron.left", help: "뒤로 (⌘[)") { tab.webView?.goBack() }.disabled(!tab.canGoBack)
        BarButton(symbol: "chevron.right", help: "앞으로 (⌘])") { tab.webView?.goForward() }.disabled(!tab.canGoForward)
        BarButton(symbol: tab.isLoading ? "xmark" : "arrow.clockwise", help: "새로고침 (⌘R)") {
            if tab.isLoading { tab.webView?.stopLoading() } else { tab.webView?.reload() }
        }
    }
}

struct DisabledNavigationButtons: View {
    var body: some View {
        BarButton(symbol: "chevron.left", help: "뒤로") {}.disabled(true)
        BarButton(symbol: "chevron.right", help: "앞으로") {}.disabled(true)
        BarButton(symbol: "arrow.clockwise", help: "새로고침") {}.disabled(true)
    }
}

/// Nunsseop's search field: a softly filled rounded box; loading shows as its 3 pt bar along the bottom.
struct FieldBackground: View {
    @ObservedObject var tab: Tab
    var focused = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: focused ? 0.5 : 0))
            .overlay(alignment: .bottom) {
                if tab.isLoading { Meter(fraction: tab.progress).padding(.horizontal, 10).padding(.bottom, 3).transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.2), value: tab.isLoading)
    }
}

struct AddressPill: View {
    @ObservedObject var tab: Tab
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.url?.scheme == "https" ? "lock.fill" : "globe")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            Text(tab.url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "주소 입력")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(Theme.primary)
            Spacer(minLength: 0)
            LoginButton(tab: tab)
            PictureInPictureButton(tab: tab)
            AdBlockShield(tab: tab)
            BookmarkStar(tab: tab)
            Keycap("⌘L")
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .frame(height: 34)
        .background(FieldBackground(tab: tab))
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .help("주소 편집 (⌘L)")
    }
}

/// The address bar on top: the whole address, edited in place.
struct TopAddressBar: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if let tab = browser.active {
            AddressField(tab: tab, browser: browser).id(tab.id)
        } else {
            AddressPlaceholder { browser.commandBar = .newTab }
        }
    }
}

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
            TextField("검색 또는 주소 입력", text: $text)
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
            LoginButton(tab: tab)
            PictureInPictureButton(tab: tab)
            AdBlockShield(tab: tab)
            BookmarkStar(tab: tab)
            Keycap(focused ? "↵" : "⌘L")
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .frame(height: 34)
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
            Text("검색 또는 주소 입력").font(.system(size: 13, weight: .medium))
            Spacer()
            Keycap("⌘T")
        }
        .foregroundStyle(Theme.faint)
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
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
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("화면 속 화면 (⌃⌘P)")
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
            .help(off ? "이 사이트에서 광고 차단 켜기" : "이 사이트에서 광고 차단 끄기 (사이트가 깨질 때)")
        }
    }
}

struct BookmarkStar: View {
    @ObservedObject var tab: Tab

    var body: some View {
        let url = tab.url?.absoluteString ?? ""
        let marked = !url.isEmpty && Library.shared.isFavorite(url)
        Button {
            guard !url.isEmpty else { return }
            _ = Library.shared.toggleBookmark(url: url, title: tab.title)
            tab.objectWillChange.send()
        } label: {
            Image(systemName: marked ? "star.fill" : "star")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(marked ? Theme.primary : Theme.dim)
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(marked ? "즐겨찾기에서 빼기 (⌘D)" : "즐겨찾기에 추가 (⌘D)")
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

/// The little button that appears on hover: "–" closes a bookmark's tab, "✕" deletes.
struct HoverAction: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.field))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondary)
        .help(help)
    }
}

struct FavoriteTile<SplitItem: View>: View {
    let entry: Library.Entry
    let state: BookmarkTabState
    let open: () -> Void
    let closeTab: () -> Void
    let remove: () -> Void
    @ViewBuilder let split: () -> SplitItem
    @State private var hover = false

    var body: some View {
        SiteIcon(url: entry.url, size: 20)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background {
                if state == .shown {
                    SelectedBackground(radius: 10)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? Theme.field : Theme.hoverTab)
                }
            }
            .overlay(alignment: .bottom) {
                if state == .open { Circle().fill(Theme.dim).frame(width: 4, height: 4).padding(.bottom, 4) }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .overlay(alignment: .topTrailing) {
                if hover {
                    HoverAction(symbol: state == .closed ? "xmark" : "minus",
                                help: state == .closed ? "즐겨찾기에서 빼기" : "이 즐겨찾기의 탭 닫기",
                                action: state == .closed ? remove : closeTab)
                        .scaleEffect(0.78)
                        .padding(1)
                }
            }
            .onHover { hover = $0 }
            .contextMenu {
                if state != .closed { Button("탭 닫기", action: closeTab) }
                split()
                Divider()
                Button("즐겨찾기에서 빼기", action: remove)
            }
            .help(entry.title.isEmpty ? entry.url : entry.title)
    }
}

struct FolderRow: View {
    let name: String
    var symbol = "folder"
    let count: Int
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.secondary).frame(width: 16)
            Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Theme.faint)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
            Spacer(minLength: 0)
            Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.hoverTab : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { toggle() } }
    }
}

struct BookmarkRow<SplitItem: View>: View {
    let entry: Library.Entry
    let state: BookmarkTabState
    let open: () -> Void
    let closeTab: () -> Void
    let remove: () -> Void
    @ViewBuilder let split: () -> SplitItem
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            SiteIcon(url: entry.url, size: 16)
            Text(entry.title.isEmpty ? entry.url : entry.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(state == .closed ? Theme.dim : Theme.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if hover {
                HoverAction(symbol: state == .closed ? "xmark" : "minus",
                            help: state == .closed ? "북마크 삭제" : "이 북마크의 탭 닫기",
                            action: state == .closed ? remove : closeTab)
            } else if state == .open {
                Circle().fill(Theme.dim).frame(width: 4, height: 4).padding(.trailing, 6)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background {
            if state == .shown { SelectedBackground() } else { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.hoverTab : .clear) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            if state != .closed { Button("탭 닫기", action: closeTab) }
            split()
            Divider()
            Button("북마크 삭제", action: remove)
        }
        .help(entry.url)
    }
}

struct NewTabRow: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 16)
            Text("새 탭").font(.system(size: 12.5, weight: .medium))
            Spacer()
            if hover { Keycap("⌘T") }
        }
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.hoverTab : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .help("새 탭 (⌘T)")
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
        HStack(spacing: 9) {
            Favicon(tab: tab)
            Text(tab.displayTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(isActive || !tab.isAsleep ? Theme.primary : Theme.dim)
            Spacer(minLength: 0)
            if tab.isPlayingAudio || tab.isMuted {
                HoverAction(symbol: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            help: tab.isMuted ? "소리 켜기 (⌃⌘M)" : "음소거 (⌃⌘M)") { tab.toggleMute() }
            }
            if hover {
                HoverAction(symbol: "xmark", help: "탭 닫기 (⌘W)", action: close)
            } else if browser.split?.contains(tab.id) == true {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .help("분할 보기")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background {
            if isActive { SelectedBackground() } else { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.hoverTab : .clear) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: select)
        .contextMenu {
            Button("즐겨찾기에 고정") {
                if let url = tab.url?.absoluteString {
                    if !Library.shared.isFavorite(url) { _ = Library.shared.toggleBookmark(url: url, title: tab.title) }
                    browser.bind(tab, to: Browser.bookmarkKey(url: url, folder: Library.favoritesFolder))
                }
            }
            if browser.split?.contains(tab.id) == true {
                Button("분할 보기 끝내기") { browser.unsplit() }
            } else if !isActive && browser.activeID != nil {
                Button("지금 탭 옆에 나란히 보기") { browser.split(with: tab.id) }
            }
            Button("주소 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.url?.absoluteString ?? "", forType: .string)
            }
            if !tab.isAsleep { Button(tab.isMuted ? "소리 켜기" : "탭 음소거") { tab.toggleMute() } }
            Divider()
            Button("탭 닫기", action: close)
        }
        .help(tab.url?.absoluteString ?? "")
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
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover && enabled ? Theme.field : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? (hover ? Theme.primary : Theme.dim) : Theme.ink(0.22))
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Like Nunsseop's selected tab: a capsule with a symbol and a word, brighter while the panel is open.
struct AIButton: View {
    let isOn: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                Text("AI").font(.system(size: 12, weight: .semibold))
                Keycap("⌘E")
            }
            .padding(.leading, 11)
            .padding(.trailing, 6)
            .frame(height: 30)
            .foregroundStyle(Theme.primary)
            .background(Capsule().fill(isOn ? Theme.pill : (hover ? Theme.field : Theme.hoverTab)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("AI 패널 (⌘E)")
    }
}

/// Where the AI button would be, in a private window.
struct PrivateBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash").font(.system(size: 11, weight: .semibold))
            Text("개인 창").font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .foregroundStyle(Theme.primary)
        .background(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .help("기록·쿠키·사이트 데이터를 남기지 않아요. AI와 확장은 이 창을 보지 못해요.")
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
    @Environment(\.colorScheme) private var scheme

    init(browser: Browser) {
        self.browser = browser
        overlay = browser.overlay
    }

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                if browser.findBarVisible {
                    FindBar(browser: browser, overlay: overlay).transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if let tab = browser.active {
                    VStack(spacing: 0) {
                        LoginOfferBar(tab: tab)
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
            .animation(.easeOut(duration: 0.15), value: browser.findBarVisible)
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
        return ZStack {
            if let tab {
                Theme.page
                WebViewHost(tab: tab, browser: browser)
            } else {
                Theme.background
                EmptyPage()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(focused ? Theme.secondary : (tab == nil || scheme == .light ? Theme.ink(0.14) : .clear), lineWidth: focused ? 1 : 0.5))
    }
}

/// "Save this sign-in?" over the top of the page, after a password was submitted.
struct LoginOfferBar: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if let offer = tab.loginOffer {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text("\(offer.host.hasPrefix("www.") ? String(offer.host.dropFirst(4)) : offer.host)의 로그인 정보를 저장할까요?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if !offer.username.isEmpty {
                    Text(offer.username).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer(minLength: 8)
                PeekAction(title: "저장") {
                    if Logins.save(host: offer.host, username: offer.username, password: offer.password) {
                        tab.browser?.flashStatus("로그인 정보를 저장했어요")
                    }
                    tab.loginOffer = nil
                    tab.checkForLogins()
                }
                Button("이 사이트는 안 함") {
                    let site = offer.host.hasPrefix("www.") ? String(offer.host.dropFirst(4)) : offer.host
                    Preferences.shared.neverSaveLoginHosts.append(site.lowercased())
                    tab.loginOffer = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 4)
                BarButton(symbol: "xmark", help: "닫기") { tab.loginOffer = nil }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 40)
            .frame(maxWidth: 620)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .padding(10)
            .transition(.opacity)
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
                Text(host.isInstalled(chromeWebStoreID: id) ? "Changmun에 설치된 확장이에요" : "이 확장을 Changmun에서 쓸 수 있어요")
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
                    PeekAction(title: host.isInstalled(chromeWebStoreID: id) ? "업데이트" : "Changmun에 추가") {
                        Task { await host.installFromChromeWebStore(id) }
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 40)
            .frame(maxWidth: 620)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
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
            .help("끌어서 폭 나누기 · 더블클릭하면 반반")
    }
}

/// A ⇧-clicked link floating over the window: esc or a click outside closes it, ⌘↩ keeps it as a tab.
struct PeekCard: View {
    @ObservedObject var tab: Tab
    @ObservedObject var browser: Browser

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
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
                    PeekAction(title: "탭으로 열기", key: "⌘↩") { browser.keepPeek() }
                    PeekAction(title: "닫기", key: "esc") { browser.closePeek() }
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
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .frame(maxWidth: 1180)
            .padding(.horizontal, 64)
            .padding(.top, BrowserWindow.barHeight)
            .padding(.bottom, 32)
        }
        .animation(.easeOut(duration: 0.2), value: tab.isLoading)
    }
}

struct PeekAction: View {
    let title: String
    var key: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let key { Keycap(key) }
            }
            .padding(.leading, 9)
            .padding(.trailing, key == nil ? 9 : 5)
            .frame(height: 26)
            .foregroundStyle(Theme.primary)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? Theme.field : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
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
            layer?.cornerRadius = 12
            layer?.cornerCurve = .continuous
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
                Text("새 탭").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.faint)
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
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: mode == .editCurrent ? "link" : "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    TextField(browser.isPrivate ? "검색하거나 주소를 입력하세요" : "검색하거나 주소를 입력하거나, AI에게 물어보세요", text: $text)
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
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
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
        if browser.tabs.isEmpty && mode == .newTab { return }
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
            Text("검색").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint)
        case .suggested(let text):
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
        case .tab(_, let url, let title):
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
            Text("탭으로 전환").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint)
            Text(URL(string: url)?.host() ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1)
        case .ask(let text):
            Text("AI에게 묻기").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
        case .page(let url, let title):
            Text(title.isEmpty ? url : title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
            Text(URL(string: url)?.host() ?? url).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1)
        }
    }
}
