import AppKit
import SwiftUI

/// The start page: the search field and, under it, a row of the favorites. It is what a window or space with no tab shows, and what a start tab
/// shows (`mode` is then `.editCurrent`: what is typed or clicked goes to that tab).
struct StartPageContent: View {
    @ObservedObject var browser: Browser
    @ObservedObject var chat: ChatStore
    var mode: CommandBarMode
    @ObservedObject private var library = LibraryWatcher.shared
    @State private var typing = false
    @State private var cursor = StartPageCursor()
    @State private var searchFocus = 0
    @State private var expanded = false
    @State private var adding = false
    @FocusState private var pageFocused: Bool

    @MainActor
    init(browser: Browser, chat: ChatStore? = nil, mode: CommandBarMode = .newTab) {
        self.browser = browser
        self.chat = chat ?? ChatStore.shared
        self.mode = mode
    }

    /// The favorites of the page: all of them (a row of them fits the column, or a "+N" tile shows the rest). A private window shows none.
    private var allFavorites: [Library.Entry] { browser.isPrivate ? [] : library.favorites(in: browser.favoritesFolder) }

    var body: some View {
        GeometryReader { geo in
            let all = allFavorites
            let layout = StartPageArrangement.favoriteLayout(count: all.count, pageWidth: geo.size.width, expanded: expanded)
            let favorites = Array(all.prefix(layout.shown))
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)
                    if browser.isPrivate {
                        StartPrivateView(search: searchBox(count: 0))
                    } else {
                        searchBox(count: layout.tiles).frame(maxWidth: StartPageArrangement.column).zIndex(10)
                        favoritesRow(favorites, layout)
                            .padding(.top, 32)
                            .opacity(typing ? 0.22 : 1)
                            .allowsHitTesting(!typing)
                            .animation(Motion.quick, value: typing)
                    }
                    Spacer(minLength: 88)
                }
                .padding(.horizontal, StartPageArrangement.pageMargin)
                .frame(minHeight: geo.size.height)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .focusable()
            .focused($pageFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in handle(press, favorites: favorites, layout: layout) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(browser.isPrivate ? String(localized: "Private Window") : String(localized: "Start Page"))
        }
        .onAppear {
            chat.refreshAvailability()
            DispatchQueue.main.async { searchFocus += 1 }
        }
    }

    private func searchBox(count: Int) -> AnyView {
        AnyView(StartSearchBox(browser: browser, chat: chat, mode: mode, typing: $typing, focusRequest: searchFocus) { backwards in
            cursor = cursor.tab(count: count, backwards: backwards)
            if cursor.item != nil { pageFocused = true } else { searchFocus += 1 }
        })
    }

    @ViewBuilder
    private func favoritesRow(_ favorites: [Library.Entry], _ layout: StartPageArrangement.FavoriteLayout) -> some View {
        let size = StartPageArrangement.favoriteSize, pitch = StartPageArrangement.favoritePitch
        if favorites.isEmpty {
            VStack(spacing: 8) {
                HStack(spacing: 24) {
                    ForEach(0..<5, id: \.self) { index in StartEmptyFavorite(size: size, add: index == 0 ? startAdding : nil) }
                }
                Text(adding ? "Search for a site and open it, then press ⌘D to add it to your favorites."
                            : "Drag the sites you visit most to the favorites in the sidebar and they appear here as tiles.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(layout.rows, id: \.lowerBound) { row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(row), id: \.self) { index in
                            if index < favorites.count {
                                let entry = favorites[index]
                                StartFavoriteTile(entry: entry, size: size, width: pitch, focused: cursor.item == index,
                                                  open: { newTab in open(entry, inNewTab: newTab) }, remove: { remove(entry) })
                            } else {
                                StartMoreTile(size: size, width: pitch, hidden: layout.hidden, focused: cursor.item == index) { expanded.toggle() }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The first dashed tile: the search field is where a site is found, and ⌘D on its page makes it a favorite.
    private func startAdding() {
        adding = true
        searchFocus += 1
    }

    /// Takes a favorite off with a way back, as the sidebar's menu does.
    private func remove(_ entry: Library.Entry) {
        let folder = browser.favoritesFolder
        let key = Browser.bookmarkKey(url: entry.url, folder: folder)
        let tab = browser.bookmarkTab(key)
        Library.shared.removeBookmark(url: entry.url, folder: folder)
        browser.offerUndo(String(localized: "Removed from Favorites")) { [browser] in
            Library.shared.addBookmark(url: entry.url, title: entry.title, folder: folder)
            if let tab, browser.tab(tab.id) != nil { browser.bind(tab, to: key) }
        }
    }

    private func open(_ entry: Library.Entry, inNewTab: Bool) {
        browser.openBookmark(entry.url, key: Browser.bookmarkKey(url: entry.url, folder: browser.favoritesFolder), inNewTab: inNewTab)
    }

    // MARK: Keyboard

    private func handle(_ press: KeyPress, favorites: [Library.Entry], layout: StartPageArrangement.FavoriteLayout) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)
        if StartPageKeys.leavesToSearch(press.key, typing: typing, inSearch: cursor.item == nil) { return .ignored }
        switch press.key {
        case .tab:
            guard !command else { return .ignored }
            cursor = cursor.tab(count: layout.tiles, backwards: press.modifiers.contains(.shift))
        case .escape:
            guard cursor.item != nil else { return .ignored }
            cursor = StartPageCursor()
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            guard !press.modifiers.contains(.option) else { return .ignored }
            let arrow: StartPageCursor.Arrow = press.key == .leftArrow ? .left : press.key == .rightArrow ? .right : press.key == .upArrow ? .up : .down
            if cursor.item == nil, arrow != .down { return .ignored }
            cursor = cursor.move(arrow, count: layout.tiles)
        case .return, .space:
            guard let item = cursor.item else { return .ignored }
            if favorites.indices.contains(item) {
                open(favorites[item], inNewTab: command)
            } else if layout.hasActionTile, item == layout.tiles - 1 {
                expanded.toggle()
            } else {
                return .ignored
            }
            return .handled
        default:
            return .ignored
        }
        if cursor.item != nil { pageFocused = true } else { searchFocus += 1 }
        return .handled
    }
}
