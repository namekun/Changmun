import AppKit
import SwiftUI
import WebKit

enum Theme {
    static let background = dynamic(light: NSColor(red: 0.925, green: 0.93, blue: 0.945, alpha: 1), dark: NSColor(white: 0.095, alpha: 1))
    static let card = dynamic(light: .white, dark: NSColor(white: 0.14, alpha: 1))
    static let activeTab = dynamic(light: .white, dark: NSColor(white: 0.22, alpha: 1))
    static let hoverTab = dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.06))
    static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
    static let secondary = dynamic(light: NSColor(white: 0, alpha: 0.5), dark: NSColor(white: 1, alpha: 0.5))
    static let userBubble = dynamic(light: NSColor(red: 0.91, green: 0.92, blue: 0.95, alpha: 1), dark: NSColor(white: 0.22, alpha: 1))
    static let accent = Color(red: 0.42, green: 0.36, blue: 0.95)
    static let accentGradient = LinearGradient(colors: [Color(red: 0.55, green: 0.35, blue: 0.98), Color(red: 0.25, green: 0.55, blue: 0.98)], startPoint: .topLeading, endPoint: .bottomTrailing)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
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
                    HStack(spacing: 8) {
                        WebCard(browser: browser)
                        if browser.showChat {
                            ChatPanel(chat: chat, browser: browser)
                                .frame(minWidth: 300, maxWidth: 372)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .padding(.top, browser.showSidebar && !prefs.addressBarOnTop ? 8 : 0)
                    .padding([.trailing, .bottom], 8)
                    .padding(.leading, browser.showSidebar ? 0 : 8)
                }
            }
            if let mode = browser.commandBar, !browser.showOnboarding {
                CommandBar(browser: browser, chat: chat, mode: mode)
            }
            if browser.showOnboarding {
                OnboardingView(browser: browser)
            }
        }
        .ignoresSafeArea()
        .animation(.spring(duration: 0.32, bounce: 0.12), value: browser.showChat)
        .animation(.spring(duration: 0.3, bounce: 0.1), value: browser.showSidebar)
        .animation(.spring(duration: 0.3, bounce: 0.1), value: prefs.addressBarOnTop)
        .animation(.easeOut(duration: 0.14), value: browser.commandBar)
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
            .frame(height: BrowserWindow.barHeight)
            .background(WindowDragArea())

            if !prefs.addressBarOnTop {
                if let tab = browser.active {
                    AddressPill(tab: tab) { browser.commandBar = .editCurrent }
                } else {
                    AddressPlaceholder { browser.commandBar = .newTab }
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !library.favorites.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                            ForEach(library.favorites, id: \.url) { entry in
                                let key = Browser.bookmarkKey(url: entry.url, folder: Library.favoritesFolder)
                                FavoriteTile(entry: entry, state: BookmarkTabState(key, browser)) {
                                    browser.openBookmark(entry.url, key: key, inNewTab: Browser.commandClick)
                                } closeTab: {
                                    if let tab = browser.bookmarkTab(key) { browser.close(tab.id) }
                                } remove: {
                                    Library.shared.removeBookmark(url: entry.url, folder: Library.favoritesFolder)
                                }
                                .draggable(SidebarDrag.favorite(entry.url))
                                .dropDestination(for: String.self) { items, _ in
                                    SidebarDrag.drop(items, onFavorite: entry.url, browser: browser)
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    NewTabRow { browser.commandBar = .newTab }
                    ForEach(browser.listedTabs) { tab in
                        SidebarTabRow(tab: tab, isActive: tab.id == browser.activeID) {
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
                        Divider().opacity(0.6).padding(.vertical, 8).padding(.horizontal, 6)
                        SectionHeader(title: "북마크", isOpen: showBookmarks) { showBookmarks.toggle() }
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
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .animation(.spring(duration: 0.25, bounce: 0.1), value: browser.tabs.map(\.id))
            }

            HStack(spacing: 4) {
                AIButton(isOn: browser.showChat) { browser.showChat.toggle() }
                Spacer()
                if #available(macOS 15.4, *) { ExtensionButtons(browser: browser) }
                BarButton(symbol: "square.and.arrow.down", help: "다른 브라우저에서 가져오기") { browser.showOnboarding = true }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
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

struct SectionHeader: View {
    let title: String
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .opacity(hover ? 1 : 0.6)
            Spacer()
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 8)
        .frame(height: 26)
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
        withAnimation(.spring(duration: 0.25, bounce: 0.1)) { browser.moveTab(id, to: target) }
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
        Browser.shared.releaseBookmarkTabs(keeping: keys)
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
            AIButton(isOn: browser.showChat) { browser.showChat.toggle() }
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

struct AddressPill: View {
    @ObservedObject var tab: Tab
    let edit: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: tab.url?.scheme == "https" ? "lock.fill" : "globe")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            Text(tab.url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "주소 입력")
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(Color.primary.opacity(0.8))
            Spacer(minLength: 0)
            LoginButton(tab: tab)
            AdBlockShield(tab: tab)
            BookmarkStar(tab: tab)
        }
        .padding(.leading, 11)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? Theme.activeTab : Theme.hoverTab))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: edit)
        .padding(.horizontal, 10)
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
            AddressPlaceholder { browser.commandBar = .newTab }.padding(.horizontal, -10)
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
        HStack(spacing: 7) {
            Image(systemName: tab.url?.scheme == "https" ? "lock.fill" : "globe")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            TextField("검색 또는 주소 입력", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
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
            AdBlockShield(tab: tab)
            BookmarkStar(tab: tab)
        }
        .padding(.leading, 11)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(focused ? Theme.activeTab : Theme.hoverTab))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.accent.opacity(focused ? 0.6 : 0), lineWidth: 1.5))
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
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
            Text("검색 또는 주소 입력").font(.system(size: 12.5))
            Spacer()
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.hoverTab))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .padding(.horizontal, 10)
    }
}

/// Ad blocking for the current site: filled while blocking, slashed when turned off here.
struct AdBlockShield: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        if prefs.blockTrackers, let host = tab.url?.host(), tab.url?.scheme?.hasPrefix("http") == true {
            let off = AdBlocker.shared.isAllowed(host)
            Button { AdBlocker.shared.toggleSite(host) } label: {
                Image(systemName: off ? "shield.slash" : "shield.lefthalf.filled")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(off ? Theme.secondary : Theme.accent)
                    .frame(width: 24, height: 24)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(marked ? Color.yellow : Theme.secondary)
                .frame(width: 24, height: 24)
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
        self = tab.id == browser.activeID ? .shown : .open
    }
}

struct FavoriteTile: View {
    let entry: Library.Entry
    let state: BookmarkTabState
    let open: () -> Void
    let closeTab: () -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        SiteIcon(url: entry.url, size: 18)
            .opacity(state == .closed ? 0.75 : 1)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(state == .shown ? Theme.activeTab : (hover ? Theme.activeTab.opacity(0.7) : Theme.hoverTab)))
            .shadow(color: .black.opacity(state == .shown ? 0.08 : 0), radius: 1.5, y: 1)
            .overlay(alignment: .bottom) {
                if state == .open { Capsule().fill(Theme.secondary).frame(width: 10, height: 2).padding(.bottom, 4) }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .overlay(alignment: .topTrailing) {
                if hover {
                    Button(action: state == .closed ? remove : closeTab) {
                        Image(systemName: state == .closed ? "xmark" : "minus").font(.system(size: 7, weight: .bold))
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Theme.card))
                            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .offset(x: 4, y: -4)
                    .help(state == .closed ? "즐겨찾기에서 빼기" : "이 즐겨찾기의 탭 닫기")
                }
            }
            .onHover { hover = $0 }
            .contextMenu {
                if state != .closed { Button("탭 닫기", action: closeTab) }
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
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .bold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .frame(width: 10)
            Image(systemName: symbol).font(.system(size: 11.5)).frame(width: 15)
            Text(name).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(count)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .foregroundStyle(Color.primary.opacity(0.72))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.hoverTab : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { toggle() } }
    }
}

struct BookmarkRow: View {
    let entry: Library.Entry
    let state: BookmarkTabState
    let open: () -> Void
    let closeTab: () -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            SiteIcon(url: entry.url, size: 14)
            Text(entry.title.isEmpty ? entry.url : entry.title).font(.system(size: 12.5, weight: state == .shown ? .medium : .regular)).lineLimit(1)
            Spacer(minLength: 0)
            if hover {
                Button(action: state == .closed ? remove : closeTab) {
                    Image(systemName: state == .closed ? "xmark" : "minus").font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.hoverTab))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary.opacity(0.5))
                .help(state == .closed ? "북마크 삭제" : "이 북마크의 탭 닫기")
            } else if state == .open {
                Circle().fill(Theme.secondary).frame(width: 4, height: 4).padding(.trailing, 6)
            }
        }
        .foregroundStyle(Color.primary.opacity(state == .closed ? 0.7 : 0.9))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(state == .shown ? Theme.activeTab : (hover ? Theme.hoverTab : .clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            if state != .closed { Button("탭 닫기", action: closeTab) }
            Button("북마크 삭제", action: remove)
        }
        .help(entry.url)
    }
}

struct NewTabRow: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 16)
            Text("새 탭").font(.system(size: 12.5))
            Spacer()
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.hoverTab : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .help("새 탭 (⌘T)")
    }
}

struct SidebarTabRow: View {
    @ObservedObject var tab: Tab
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Favicon(tab: tab)
            Text(tab.displayTitle)
                .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .foregroundStyle(Color.primary.opacity(isActive ? 0.9 : (tab.isAsleep ? 0.5 : 0.7)))
            Spacer(minLength: 0)
            if hover {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.hoverTab))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary.opacity(0.5))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? Theme.activeTab : (hover ? Theme.hoverTab : .clear))
                .shadow(color: .black.opacity(isActive ? 0.08 : 0), radius: 1.5, y: 1)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: select)
        .contextMenu {
            Button("즐겨찾기에 고정") {
                if let url = tab.url?.absoluteString {
                    if !Library.shared.isFavorite(url) { _ = Library.shared.toggleBookmark(url: url, title: tab.title) }
                    Browser.shared.bind(tab, to: Browser.bookmarkKey(url: url, folder: Library.favoritesFolder))
                }
            }
            Button("주소 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.url?.absoluteString ?? "", forType: .string)
            }
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
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe").font(.system(size: size * 0.75)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { image = await Browser.shared.icon(for: url) }
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
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover && enabled ? Theme.hoverTab : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary.opacity(0.75) : Color.primary.opacity(0.25))
        .onHover { hover = $0 }
        .help(help)
    }
}

struct AIButton: View {
    let isOn: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                Text("AI").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.8))
            .background {
                if isOn {
                    Capsule().fill(Theme.accentGradient)
                } else {
                    Capsule().fill(hover ? Theme.hoverTab : Theme.hairline)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("AI 패널 (⌘E)")
    }
}

struct Favicon: View {
    @ObservedObject var tab: Tab

    var body: some View {
        Group {
            if tab.isLoading && tab.favicon == nil {
                ProgressView().controlSize(.mini)
            } else if let image = tab.favicon {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .opacity(tab.isAsleep ? 0.5 : 1)
    }
}

/// Empty parts of the tab strip move the window, and a double click zooms it.
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

    var body: some View {
        ZStack(alignment: .top) {
            Theme.card
            if let tab = browser.active {
                WebViewHost(tab: tab, browser: browser)
                LoadingBar(tab: tab)
            } else {
                EmptyPage()
            }
        }
        .overlay(alignment: .topTrailing) {
            if browser.findBarVisible {
                FindBar(browser: browser).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let text = browser.statusMessage ?? browser.hoveredLink.map(StatusLine.display) {
                StatusLine(text: text).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: browser.hoveredLink)
        .animation(.easeOut(duration: 0.12), value: browser.statusMessage)
        .animation(.easeOut(duration: 0.15), value: browser.findBarVisible)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
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
            .font(.system(size: 11.5))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(Color.primary.opacity(0.75))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .frame(maxWidth: 520, alignment: .leading)
            .padding(6)
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
            layer?.cornerRadius = 10
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
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        DispatchQueue.main.async {
            if browser.commandBar == nil, browser.showOnboarding == false { container.window?.makeFirstResponder(webView) }
        }
    }
}

struct LoadingBar: View {
    @ObservedObject var tab: Tab

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Theme.accentGradient)
                .frame(width: geo.size.width * max(tab.progress, 0.05), height: 2.5)
                .opacity(tab.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: tab.progress)
                .animation(.easeOut(duration: 0.3), value: tab.isLoading)
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
    }
}

struct EmptyPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.accentGradient)
            Text("⌘T로 새 탭을 열거나 AI에게 물어보세요").font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
    }
}

// MARK: Command bar

struct CommandBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var chat: ChatStore
    let mode: CommandBarMode
    @State private var text = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    enum Suggestion: Hashable {
        case open(String)
        case search(String)
        case ask(String)
        case page(url: String, title: String)
    }

    private var suggestions: [Suggestion] {
        let query = text.trimmingCharacters(in: .whitespaces)
        if query.isEmpty || (mode == .editCurrent && query == browser.active?.url?.absoluteString) {
            return Library.shared.bookmarks().map { .page(url: $0.url, title: $0.title) }
        }
        var list: [Suggestion] = [AddressInput.isAddress(query) ? .open(query) : .search(query), .ask(query)]
        list += Library.shared.search(query, limit: 6).map { .page(url: $0.url, title: $0.title) }
        return list
    }

    var body: some View {
        let items = suggestions
        ZStack(alignment: .top) {
            Color.black.opacity(0.14)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: mode == .editCurrent ? "link" : "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                    TextField("검색하거나 주소를 입력하거나, AI에게 물어보세요", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($focused)
                        .onSubmit { run(items.indices.contains(selection) ? items[selection] : nil) }
                        .onChange(of: text) { selection = 0 }
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                if !items.isEmpty {
                    Divider().opacity(0.5)
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            SuggestionRow(item: item, selected: index == selection)
                                .onTapGesture { run(item) }
                                .onHover { if $0 { selection = index } }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 40, y: 16)
            .padding(.top, 96)
            .onKeyPress(.downArrow) { selection = min(selection + 1, items.count - 1); return .handled }
            .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
            .onKeyPress(.escape) { dismiss(); return .handled }
        }
        .onAppear {
            text = mode == .editCurrent ? (browser.active?.url?.absoluteString ?? "") : ""
            NSApp.keyWindow?.makeFirstResponder(nil)
            DispatchQueue.main.async { focused = true }
        }
    }

    private func dismiss() {
        if browser.tabs.isEmpty && mode == .newTab { return }
        browser.commandBar = nil
    }

    private func run(_ item: Suggestion?) {
        switch item {
        case .open(let input), .search(let input):
            browser.open(input, in: mode)
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
            icon.frame(width: 22)
            label
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.hoverTab : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .open: Image(systemName: "arrow.up.right.circle").foregroundStyle(Theme.secondary)
        case .search: Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
        case .ask: Image(systemName: "sparkles").foregroundStyle(Theme.accentGradient)
        case .page: Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.secondary)
        }
    }

    @ViewBuilder private var label: some View {
        switch item {
        case .open(let text):
            Text(text).font(.system(size: 13.5)).lineLimit(1)
        case .search(let text):
            Text(text).font(.system(size: 13.5)).lineLimit(1)
            Text("— 검색").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
        case .ask(let text):
            Text("AI에게 묻기:").font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 13.5)).lineLimit(1)
        case .page(let url, let title):
            Text(title.isEmpty ? url : title).font(.system(size: 13.5)).lineLimit(1)
            Text(URL(string: url)?.host() ?? url).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
    }
}
