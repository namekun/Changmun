import AppKit
import SwiftUI

/// The tabs along the top of the window when they are not in the sidebar: the favorites as icon tiles, then the tabs of the space (a
/// group's chip before its tabs) and a plus. The tabs share the room, down to a least width, and past that the strip scrolls.
struct TabStrip: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var library = LibraryWatcher.shared
    @State private var dropTarget: String?

    private static let gap: CGFloat = 4
    private static let tabWidths: ClosedRange<CGFloat> = 120...220
    private static let plusWidth = Metrics.control

    var body: some View {
        let favorites = library.favorites(in: browser.favoritesFolder)
        let items = Array(browser.stripItems(favorites: favorites).dropFirst(favorites.count))
        HStack(spacing: 0) {
            // Room for the window buttons, which sit level with the strip.
            Color.clear.frame(width: browser.fullScreen ? Metrics.inset : BrowserWindow.windowButtonsTrailing)
            if !favorites.isEmpty {
                HStack(spacing: Self.gap) {
                    ForEach(favorites, id: \.url) { favorite($0) }
                }
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 16).padding(.horizontal, Metrics.inset)
            }
            GeometryReader { geo in tabs(items, in: geo.size.width) }
        }
        .padding(.trailing, Metrics.inset)
        .frame(height: BrowserWindow.tabStripHeight)
        .background(WindowDragArea())
        .animation(Motion.standard, value: items.map(\.id))
        .animation(Motion.quick, value: dropTarget)
    }

    // MARK: Tabs

    private func tabs(_ items: [TabStripItem], in available: CGFloat) -> some View {
        let count = items.filter { $0.tab != nil }.count
        let chips = items.reduce(CGFloat(0)) { total, item in
            if case .group(let group, let members) = item { total + StripGroupChip.width(group, count: members, renaming: browser.renamingGroup == group.id) + Self.gap } else { total }
        }
        let rest = chips + Self.plusWidth + Self.gap * CGFloat(count)
        let width = count == 0 ? Self.tabWidths.upperBound : min(Self.tabWidths.upperBound, max(Self.tabWidths.lowerBound, ((available - rest) / CGFloat(count)).rounded(.down)))
        let content = rest + width * CGFloat(count)
        return HStack(spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.gap) {
                        ForEach(items) { item in
                            switch item {
                            case .tab(let tab): stripTab(tab, width: width)
                            case .group(let group, let members): chip(group, count: members)
                            case .favorite: EmptyView()
                            }
                        }
                        newTab
                    }
                }
                // The tab shown comes into view: when the strip appears, and when another tab is switched to from the keyboard or the command bar.
                .onAppear {
                    DispatchQueue.main.async { if let id = browser.activeID { scroller.scrollTo("tab:\(id)", anchor: .center) } }
                }
                .onChange(of: browser.activeID) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.standard) { scroller.scrollTo("tab:\(id)", anchor: .center) }
                }
            }
            // As wide as the tabs when they all fit: the room left over is the window's to move by.
            .frame(width: min(available, content + 2))
            Spacer(minLength: 0)
        }
        .frame(width: available, height: BrowserWindow.tabStripHeight, alignment: .leading)
    }

    private func stripTab(_ tab: Tab, width: CGFloat) -> some View {
        StripTab(tab: tab, browser: browser, isActive: tab.id == browser.activeID, renaming: browser.renamingTab == tab.id, width: width)
            .id("tab:\(tab.id)")
            .dropLine(dropTarget == "tab:\(tab.id)" && SidebarDrag.carriesTab, edge: .leading)
            .draggingTab(tab.id, unless: browser.renamingTab == tab.id)
            .dropDestination(for: SidebarDrop.self) { items, _ in
                SidebarDrag.drop(items.texts, onTab: tab.id, browser: browser)
            } isTargeted: { target("tab:\(tab.id)", $0) }
    }

    private func chip(_ group: Browser.TabGroup, count: Int) -> some View {
        StripGroupChip(group: group, count: count, browser: browser, target: dropTarget == "group:\(group.id)" && SidebarDrag.carriesTab)
            .dropDestination(for: SidebarDrop.self) { items, _ in
                SidebarDrag.drop(items.texts, onGroup: group.id, browser: browser)
            } isTargeted: { target("group:\(group.id)", $0) }
    }

    /// After the last tab: a tab dropped on it goes to the end of the list.
    private var newTab: some View {
        BarButton(symbol: "plus", help: String(localized: "New Tab (⌘T)")) { browser.commandBar = .newTab }
            .dropLine(dropTarget == "tabs:end" && SidebarDrag.carriesTab, edge: .leading)
            .dropDestination(for: SidebarDrop.self) { items, _ in
                SidebarDrag.dropAtEnd(items.texts, browser: browser)
            } isTargeted: { target("tabs:end", $0) }
    }

    // MARK: Favorites

    private func favorite(_ entry: Library.Entry) -> some View {
        let folder = browser.favoritesFolder
        let key = Browser.bookmarkKey(url: entry.url, folder: folder)
        return StripFavorite(entry: entry, state: BookmarkTabState(key, browser)) {
            browser.openBookmark(entry.url, key: key, inNewTab: Browser.commandClick)
        } menu: {
            BookmarkMenu(browser: browser, url: entry.url, title: entry.title, folder: folder, key: key)
        }
        .dropLine(dropTarget == "fav:" + entry.url && SidebarDrag.dragging != .folder, edge: .leading)
        .draggable(SidebarDrag.bookmark(entry.url, in: folder))
        .dropDestination(for: SidebarDrop.self) { items, _ in
            SidebarDrag.drop(items.texts, onFavorite: entry.url, browser: browser)
        } isTargeted: { target("fav:" + entry.url, $0) }
    }

    private func target(_ key: String, _ inside: Bool) {
        if inside { dropTarget = key } else if dropTarget == key { dropTarget = nil }
    }
}
