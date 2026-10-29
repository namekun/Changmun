import AppKit
import SwiftUI

/// The tabs along the top of the window when they are not in the sidebar: the favorites as icon tiles, then the tabs of the space (a
/// group's chip before its tabs) and a plus. The tabs share the room, down to a least width, and past that the strip scrolls.
struct TabStrip: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var library = LibraryWatcher.shared
    @State private var dropTarget: String?
    @State private var stripWidth = 10_000.0

    private static let gap: CGFloat = 4
    private static let tabWidths: ClosedRange<CGFloat> = 120...220
    private static let plusWidth = Metrics.control
    /// A favorite's tile.
    static let favoriteWidth: CGFloat = 34
    private static let separatorWidth = 1 + 2 * Metrics.inset

    /// The width of the favorites when there are so many that they would leave the tabs less than room for one of the least width and the plus
    /// button, so the favorites scroll within it; nil while they and that much room for the tabs fit. `leading` is what comes before them.
    static func favoritesScrollWidth(count: Int, strip: CGFloat, leading: CGFloat) -> CGFloat? {
        guard count > 0 else { return nil }
        let wanted = CGFloat(count) * Self.favoriteWidth + CGFloat(count - 1) * gap
        let room = strip - leading - separatorWidth - Metrics.inset - (tabWidths.lowerBound + 2 * gap + plusWidth)
        return wanted > room ? max(room, Self.favoriteWidth) : nil
    }

    var body: some View {
        let favorites = library.favorites(in: browser.favoritesFolder)
        let leading = browser.fullScreen ? Metrics.inset : BrowserWindow.windowButtonsTrailing
        let items = Array(browser.stripItems(favorites: favorites).dropFirst(favorites.count))
        HStack(spacing: 0) {
            // Room for the window buttons, which sit level with the strip.
            Color.clear.frame(width: leading)
            if !favorites.isEmpty {
                let tiles = HStack(spacing: Self.gap) {
                    ForEach(favorites, id: \.url) { favorite($0) }
                }
                if let width = Self.favoritesScrollWidth(count: favorites.count, strip: stripWidth, leading: leading) {
                    // So many that the tabs would have no room: the favorites scroll, and the tabs and the plus button stay.
                    ScrollView(.horizontal, showsIndicators: false) { tiles }
                        .background(StripWheelScroll())
                        .frame(width: width, height: StripTab.height)
                } else {
                    tiles
                }
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 16).padding(.horizontal, Metrics.inset)
            }
            GeometryReader { geo in tabs(items, in: geo.size.width) }
        }
        .padding(.trailing, Metrics.inset)
        .frame(height: BrowserWindow.tabStripHeight)
        .background(WindowDragArea())
        .onGeometryChange(for: Double.self) { $0.size.width } action: { stripWidth = $0 }
        .animation(Motion.standard, value: items.map(\.id))
        .animation(Motion.quick, value: dropTarget)
    }

    // MARK: Tabs

    private func tabs(_ items: [TabStripItem], in available: CGFloat) -> some View {
        let count = items.filter { $0.tab != nil }.count
        let chips = items.reduce(CGFloat(0)) { total, item in
            if case .group(let group, let members) = item { total + StripGroupChip.width(group, count: members, renaming: browser.stripRenaming(group: group.id)) + Self.gap } else { total }
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
                    }
                }
                // The tab shown comes into view: when the strip appears, and when another tab is switched to from the keyboard or the command bar.
                .background(StripWheelScroll())
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "Tabs"))
                .onAppear {
                    DispatchQueue.main.async { if let id = browser.activeID { scroller.scrollTo("tab:\(id)", anchor: .center) } }
                }
                .onChange(of: browser.activeID) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.standard) { scroller.scrollTo("tab:\(id)", anchor: .center) }
                }
            }
            // As wide as the tabs when they all fit: the room left over is the window's to move by. The new tab button
            // stays outside the scrolling, so it is never scrolled away.
            .frame(width: max(0, min(available, content + 2) - Self.plusWidth - Self.gap))
            newTab.padding(.leading, Self.gap)
            Spacer(minLength: 0)
        }
        .frame(width: available, height: BrowserWindow.tabStripHeight, alignment: .leading)
    }

    private func stripTab(_ tab: Tab, width: CGFloat) -> some View {
        StripTab(tab: tab, browser: browser, isActive: tab.id == browser.activeID, renaming: browser.stripRenaming(tab: tab.id), width: width)
            .id("tab:\(tab.id)")
            .dropLine(dropTarget == "tab:\(tab.id)" && SidebarDrag.carriesTab, edge: .leading)
            .draggingTab(tab.id, unless: browser.stripRenaming(tab: tab.id))
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
        BarButton(symbol: "plus", help: String(localized: "New Tab (⌘T)")) { browser.openNewTab() }
            .dropLine(dropTarget == "tabs:end" && SidebarDrag.carriesTab, edge: .leading)
            .dropDestination(for: SidebarDrop.self) { items, _ in
                SidebarDrag.dropAtEnd(items.texts, browser: browser)
            } isTargeted: { target("tabs:end", $0) }
    }

    // MARK: Favorites

    private func favorite(_ entry: Library.Entry) -> some View {
        let folder = browser.favoritesFolder
        let key = Browser.bookmarkKey(url: entry.url, folder: folder)
        // With the sidebar open over the page, the favorite's popover is the sidebar's: two at once would fight for the focus.
        return StripFavorite(entry: entry, state: BookmarkTabState(key, browser), renaming: browser.renamingBookmark == key && !browser.showSidebarOverlay,
                             finishRenaming: { browser.finishRenamingBookmark(url: entry.url, folder: folder, title: entry.title, with: $0) }) {
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
