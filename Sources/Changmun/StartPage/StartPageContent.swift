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
    @FocusState private var pageFocused: Bool

    @MainActor
    init(browser: Browser, chat: ChatStore? = nil, mode: CommandBarMode = .newTab) {
        self.browser = browser
        self.chat = chat ?? ChatStore.shared
        self.mode = mode
    }

    /// The favorites that fit in one row of the page's column; the rest are in the sidebar. A private window shows none.
    private func favorites(width: CGFloat) -> [Library.Entry] {
        guard !browser.isPrivate else { return [] }
        let all = library.favorites(in: browser.favoritesFolder)
        return Array(all.prefix(StartPageArrangement.favoritesShown(count: all.count, pageWidth: width)))
    }

    var body: some View {
        GeometryReader { geo in
            let favorites = favorites(width: geo.size.width)
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)
                    if browser.isPrivate {
                        StartPrivateView(search: searchBox(count: 0))
                    } else {
                        searchBox(count: favorites.count).frame(maxWidth: StartPageArrangement.column).zIndex(10)
                        favoritesRow(favorites)
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
            .onKeyPress(phases: [.down, .repeat]) { press in handle(press, favorites: favorites) }
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
    private func favoritesRow(_ favorites: [Library.Entry]) -> some View {
        let size = StartPageArrangement.favoriteSize, pitch = StartPageArrangement.favoritePitch
        if favorites.isEmpty {
            VStack(spacing: 8) {
                HStack(spacing: 24) { ForEach(0..<5, id: \.self) { _ in StartEmptyFavorite(size: size) } }
                Text("Drag the sites you visit most to the favorites in the sidebar and they appear here as tiles.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(favorites.enumerated()), id: \.offset) { index, entry in
                    StartFavoriteTile(entry: entry, size: size, width: pitch, focused: cursor.item == index) { newTab in open(entry, inNewTab: newTab) }
                }
            }
        }
    }

    private func open(_ entry: Library.Entry, inNewTab: Bool) {
        browser.openBookmark(entry.url, key: Browser.bookmarkKey(url: entry.url, folder: browser.favoritesFolder), inNewTab: inNewTab)
    }

    // MARK: Keyboard

    private func handle(_ press: KeyPress, favorites: [Library.Entry]) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)
        if StartPageKeys.leavesToSearch(press.key, typing: typing, inSearch: cursor.item == nil) { return .ignored }
        switch press.key {
        case .tab:
            guard !command else { return .ignored }
            cursor = cursor.tab(count: favorites.count, backwards: press.modifiers.contains(.shift))
        case .escape:
            guard cursor.item != nil else { return .ignored }
            cursor = StartPageCursor()
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            guard !press.modifiers.contains(.option) else { return .ignored }
            let arrow: StartPageCursor.Arrow = press.key == .leftArrow ? .left : press.key == .rightArrow ? .right : press.key == .upArrow ? .up : .down
            if cursor.item == nil, arrow != .down { return .ignored }
            cursor = cursor.move(arrow, count: favorites.count)
        case .return, .space:
            guard let item = cursor.item, favorites.indices.contains(item) else { return .ignored }
            open(favorites[item], inNewTab: command)
            return .handled
        default:
            return .ignored
        }
        if cursor.item != nil { pageFocused = true } else { searchFocus += 1 }
        return .handled
    }
}
