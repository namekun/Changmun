import AppKit
import SwiftUI

// MARK: Sidebar

struct Sidebar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var library = LibraryWatcher.shared
    @ObservedObject private var drag = SidebarDragWatcher.shared
    @State private var dropTarget: String?
    @State private var showLibrary = false
    @State private var bookmarkQuery = ""
    @State private var newTabHover = false

    var body: some View {
        VStack(spacing: 0) {
            WindowDragArea().frame(height: browser.fullScreen ? 0 : BrowserWindow.windowButtonsBottom)
            // Above the list, so it is in sight however far down the list is scrolled.
            if browser.lastTidy != nil || browser.notice != nil {
                UndoNotices(browser: browser)
                    .padding(.horizontal, Metrics.inset)
                    .padding(.top, Metrics.inset)
                    .transition(.opacity)
            }

            ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.rowGap) {
                    if !library.favorites(in: browser.favoritesFolder).isEmpty {
                        favorites
                    }
                    pinned
                    // Tidying is offered where the tabs start, when the pointer is there.
                    HStack(spacing: Metrics.rowGap) {
                        NewTabRow { browser.openNewTab() }
                        if browser.tidying || (newTabHover && browser.looseTabs.count > 1) { TidyButton(browser: browser) }
                    }
                    .onHover { newTabHover = $0 }
                    ForEach(browser.listing) { item in
                        switch item {
                        case .tab(let tab):
                            tabRow(tab, depth: 0)
                        case .group(let group, let tabs):
                            TabGroupHeader(group: group, count: tabs.count, browser: browser,
                                           target: dropTarget == "group:\(group.id)" && SidebarDrag.carriesTab)
                                .dropLine(groupLands(above: group.id))
                                .dropDestination(for: SidebarDrop.self) { items, _ in
                                    SidebarDrag.drop(items.texts, onGroup: group.id, browser: browser)
                                } isTargeted: { target("group:\(group.id)", $0) }
                            let rows = browser.shown(tabs, in: group)
                            ForEach(rows) { tab in
                                tabRow(tab, depth: 1)
                            }
                            // Below the group's last tab: a tab dropped here goes to the end of the group.
                            if drag.isDragging, !rows.isEmpty {
                                EndOfListDrop(depth: 1)
                                    .dropLine(dropTarget == "group-end:\(group.id)" && SidebarDrag.carriesTab)
                                    .dropDestination(for: SidebarDrop.self) { items, _ in
                                        SidebarDrag.drop(items.texts, onEndOf: group.id, browser: browser)
                                    } isTargeted: { target("group-end:\(group.id)", $0) }
                            }
                        }
                    }
                    // Below the last tab: a tab dropped here goes to the end of the list.
                    SectionGap()
                        .dropLine(dropTarget == "tabs:end" && (SidebarDrag.carriesTab || SidebarDrag.dragging == .group))
                        .dropDestination(for: SidebarDrop.self) { items, _ in
                            SidebarDrag.dropAtEnd(items.texts, browser: browser)
                        } isTargeted: { target("tabs:end", $0) }
                }
                .padding(.horizontal, Metrics.inset)
                .padding(.top, Metrics.inset)
                .padding(.bottom, Metrics.inset)
                .animation(Motion.pointer, value: browser.tabs.map(\.id))
                .animation(Motion.standard, value: browser.groups)
                .animation(Motion.standard, value: browser.tabs.map(\.groupID))
                .animation(Motion.standard, value: browser.space.pinnedFolders)
                .animation(Motion.standard, value: browser.space.openFolders)
                .animation(Motion.quick, value: dropTarget)
                .animation(Motion.quick, value: drag.isDragging)
            }
            // A tab switched to from the keyboard or the command bar comes into view, without a scroll to watch: only the pointer animates.
            .middleClickList()
            .onChange(of: browser.activeID) { _, id in
                guard let id else { return }
                // A pinned bookmark's tab is in its bookmark's row.
                withAnimation(Motion.pointer) { scroller.scrollTo(browser.tab(id)?.bookmarkKey.map { "pin:" + $0 } ?? "tab:\(id)") }
            }
            }
            .modifier(SpaceSlide(spaceID: browser.spaceID, direction: browser.spaceDirection))

            DownloadShelf(browser: browser).padding(.bottom, Metrics.inset)
            // The rest of the browser, out of the way at the bottom: every bookmark, downloads, extensions and AI.
            HStack(spacing: Metrics.rowGap) {
                BarButton(symbol: "bookmark", help: String(localized: "Bookmarks")) { showLibrary.toggle() }
                    .popover(isPresented: $showLibrary, arrowEdge: .top) { allBookmarks }
                // The list opens where the progress was shown, above the shelf, not across the window.
                DownloadButton(browser: browser, arrowEdge: .top)
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
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.bottom, browser.isPrivate ? Metrics.inset : 0)
            if !browser.isPrivate {
                SpaceSwitcher(browser: browser)
                    .padding(.horizontal, Metrics.inset)
                    .padding(.bottom, Metrics.inset)
            }
        }
        .animation(Motion.standard, value: browser.notice == nil && browser.lastTidy == nil)
    }

    // MARK: Parts

    private var favorites: some View {
        // As many tiles a row as the sidebar's width holds: four at the default width, up to seven when wide.
        VStack(spacing: Metrics.rowGap) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 4)], spacing: 4) {
                ForEach(library.favorites(in: browser.favoritesFolder), id: \.url) { entry in
                    let key = Browser.bookmarkKey(url: entry.url, folder: browser.favoritesFolder)
                    FavoriteTile(entry: entry, state: BookmarkTabState(key, browser), tab: browser.bookmarkTab(key), renaming: browser.renamingBookmark == key,
                                 finishRenaming: { browser.finishRenamingBookmark(url: entry.url, folder: browser.favoritesFolder, title: entry.title, with: $0) }) {
                        browser.openBookmark(entry.url, key: key, inNewTab: Browser.commandClick)
                    } menu: {
                        BookmarkMenu(browser: browser, url: entry.url, title: entry.title, folder: browser.favoritesFolder, key: key)
                    }
                    .dropLine(dropTarget == "fav:" + entry.url && SidebarDrag.dragging != .folder, edge: .leading)
                    .draggable(SidebarDrag.bookmark(entry.url, in: browser.favoritesFolder))
                    .dropDestination(for: SidebarDrop.self) { items, _ in
                        SidebarDrag.drop(items.texts, onFavorite: entry.url, browser: browser)
                    } isTargeted: { target("fav:" + entry.url, $0) }
                }
            }
            // Between the tiles: dropped there, it goes to the end of the favorites.
            .dropDestination(for: SidebarDrop.self) { items, _ in
                SidebarDrag.drop(items.texts, onFavorite: nil, browser: browser)
            }
            // Below the last tile, in the gap before the tabs, also when the last row is full.
            Color.clear
                .frame(height: Metrics.section - 2 * Metrics.rowGap)
                .contentShape(Rectangle())
                .dropLine(dropTarget == "fav:end" && SidebarDrag.dragging != .folder)
                .dropDestination(for: SidebarDrop.self) { items, _ in
                    SidebarDrag.drop(items.texts, onFavorite: nil, browser: browser)
                } isTargeted: { target("fav:end", $0) }
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Favorites"))
    }

    /// Folders kept under the favorites, opened where they are, then a gap before the tabs. A folder dropped in
    /// the gap is pinned at the end.
    @ViewBuilder private var pinned: some View {
        let folders = browser.space.topPinnedFolders.compactMap(library.folder)
        // Ids carry the part of the sidebar: a folder can show both pinned and under Bookmarks.
        ForEach(folders.flatMap { treeRows($0, depth: 0, scope: "pin:", pinned: true) }) { row in
            treeRow(row)
        }
        SectionGap()
            .dropLine(dropTarget == "pin:end" && (SidebarDrag.dragging == .folder || SidebarDrag.dragging == .group))
            .dropDestination(for: SidebarDrop.self) { items, _ in
                SidebarDrag.pin(items.texts, before: nil, in: browser)
            } isTargeted: { target("pin:end", $0) }
    }

    /// Every imported bookmark, by browser and folder, in a popover over the sidebar's bottom bar; typing finds one.
    private var allBookmarks: some View {
        VStack(spacing: 0) {
            if library.sources.isEmpty {
                VStack(spacing: 0) { ReadingListSection(browser: browser) }.padding([.horizontal, .top], Metrics.inset)
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
                    Image(systemName: "magnifyingglass").font(.symbolInline).foregroundStyle(Theme.secondary)
                    TextField("Search Bookmarks", text: $bookmarkQuery)
                        .textFieldStyle(.plain)
                        .font(.row)
                }
                .padding(.horizontal, 8)
                .frame(height: Metrics.control)
                .background(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).fill(Theme.field))
                .padding([.horizontal, .top], Metrics.inset)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Metrics.rowGap) {
                        if bookmarkQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                            ReadingListSection(browser: browser)
                            bookmarkSources
                        } else {
                            ForEach(foundBookmarks) { row in treeRow(row) }
                        }
                    }
                    .padding(Metrics.inset)
                    .animation(Motion.standard, value: browser.space.openFolders)
                }
                .frame(width: 320, height: 420)
            }
        }
    }

    private var bookmarkSources: some View {
        ForEach(library.sources, id: \.source) { group in
            let key = "source:" + group.source
            FolderRow(name: group.source, symbol: "books.vertical", count: group.folders.reduce(0) { $0 + $1.count },
                      isOpen: browser.space.openFolders.contains(key), click: { _ in browser.spaces.toggleOpen(key, in: browser.spaceID) }) {
                Button("Delete All \(group.source) Bookmarks…") {
                    confirmDelete(String(localized: "Delete all bookmarks imported from \(DialogSpec.name(group.source))?"), String(localized: "They all go, and this can't be undone.")) { Library.shared.removeSource(group.source) }
                }
            }
            if browser.space.openFolders.contains(key) {
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
        /// Below the last bookmark of an open folder: where a bookmark dropped goes to the end of it.
        case end(folder: String, depth: Int, scope: String)
        /// An open folder with nothing in it says so, and takes what is dropped on it.
        case empty(folder: String, depth: Int, scope: String)

        /// Carries the part of the sidebar: a folder can show both pinned and under Bookmarks.
        var id: String {
            switch self {
            case .folder(let folder, _, let scope, _): scope + folder.key
            case .bookmark(let entry, let folder, _, let scope): scope + folder + "\n" + entry.url
            case .end(let folder, _, let scope): scope + folder + "\n\u{1}end"
            case .empty(let folder, _, let scope): scope + folder + "\n\u{1}empty"
            }
        }
    }

    private func treeRows(_ folder: Library.Folder, depth: Int, scope: String, pinned: Bool) -> [TreeRow] {
        Self.treeRows(folder, depth: depth, scope: scope, pinned: pinned, open: browser.space.openFolders,
                      shownKey: pinned ? browser.active?.bookmarkKey : nil, dragging: drag.isDragging)
    }

    /// A folder, and when it is open the folders and bookmarks inside it, each a step further in. `open` holds the open rows' keys
    /// (see `Space.openFolders`); `dragging` adds the strip to drop at the end of an open folder. A folded folder still shows the bookmark
    /// `shownKey` names when it is inside it, as a folded group keeps the tab shown: the tab on screen always has its row.
    static func treeRows(_ folder: Library.Folder, depth: Int, scope: String, pinned: Bool, open: [String], shownKey: String? = nil, dragging: Bool) -> [TreeRow] {
        var rows: [TreeRow] = [.folder(folder, depth: depth, scope: scope, pinned: pinned)]
        guard open.contains(scope + folder.key) else {
            for (inner, _) in folder.flattened() {
                if let entry = inner.entries.first(where: { Browser.bookmarkKey(url: $0.url, folder: inner.key) == shownKey }) {
                    rows.append(.bookmark(entry, folder: inner.key, depth: depth + 1, scope: scope))
                }
            }
            return rows
        }
        for child in folder.children { rows += treeRows(child, depth: depth + 1, scope: scope, pinned: pinned, open: open, shownKey: shownKey, dragging: dragging) }
        rows += folder.entries.map { .bookmark($0, folder: folder.key, depth: depth + 1, scope: scope) }
        if folder.entries.isEmpty && folder.children.isEmpty { rows.append(.empty(folder: folder.key, depth: depth + 1, scope: scope)) }
        if dragging { rows.append(.end(folder: folder.key, depth: depth + 1, scope: scope)) }
        return rows
    }

    @ViewBuilder private func treeRow(_ row: TreeRow) -> some View {
        switch row {
        case .folder(let folder, let depth, let scope, let pinned):
            folderRow(folder, depth: depth, scope: scope, pinned: pinned)
        case .bookmark(let entry, let folder, let depth, _):
            let key = Browser.bookmarkKey(url: entry.url, folder: folder)
            BookmarkRow(entry: entry, state: BookmarkTabState(key, browser), tab: browser.bookmarkTab(key),
                        inSplit: browser.bookmarkTab(key).map { browser.split?.contains($0.id) == true } ?? false, renaming: browser.renamingBookmark == key,
                        startRenaming: { browser.renamingBookmark = key },
                        finishRenaming: { browser.finishRenamingBookmark(url: entry.url, folder: folder, title: entry.title, with: $0) }) {
                browser.openBookmark(entry.url, key: key, inNewTab: Browser.commandClick)
            } menu: {
                BookmarkMenu(browser: browser, url: entry.url, title: entry.title, folder: folder, key: key)
            }
            .padding(.leading, CGFloat(depth) * Metrics.indent)
            .dropLine(dropTarget == "bm:" + row.id && SidebarDrag.dragging == .bookmark)
            .draggingRow(SidebarDrag.bookmark(entry.url, in: folder), unless: browser.renamingBookmark == key)
            .dropDestination(for: SidebarDrop.self) { items, _ in
                SidebarDrag.drop(items.texts, onBookmark: entry.url, in: folder, browser: browser)
            } isTargeted: { target("bm:" + row.id, $0) }
        case .empty(let folder, let depth, _):
            Text("Nothing here yet")
                .font(.row)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, minHeight: Metrics.row, alignment: .leading)
                .padding(.leading, Metrics.rowPadding + CGFloat(depth) * Metrics.indent)
                .contentShape(Rectangle())
                .dropLine(dropTarget == "bm:" + row.id && SidebarDrag.dragging == .bookmark)
                .dropDestination(for: SidebarDrop.self) { items, _ in
                    SidebarDrag.drop(items.texts, onBookmark: nil, in: folder, browser: browser)
                } isTargeted: { target("bm:" + row.id, $0) }
        case .end(let folder, let depth, _):
            EndOfListDrop(depth: depth)
                .dropLine(dropTarget == "bm:" + row.id && SidebarDrag.dragging == .bookmark)
                .dropDestination(for: SidebarDrop.self) { items, _ in
                    SidebarDrag.drop(items.texts, onBookmark: nil, in: folder, browser: browser)
                } isTargeted: { target("bm:" + row.id, $0) }
        }
    }

    private func folderRow(_ folder: Library.Folder, depth: Int, scope: String, pinned: Bool) -> some View {
        let openKey = scope + folder.key
        let isPinned = browser.space.pinnedFolders.contains(folder.key)
        let targetKey = scope + "folder:" + folder.key
        // Pinned folders reorder when a folder is dropped on one, and a group is pinned above it as a new folder;
        // a bookmark dropped on any folder moves in, a tab is kept there as its bookmark, and a group becomes a folder
        // inside it.
        let reorders = pinned && depth == 0
        let over = dropTarget == targetKey
        let places = reorders && (SidebarDrag.dragging == .folder || SidebarDrag.dragging == .group)
        return FolderRow(name: folder.label, count: folder.count, isOpen: browser.space.openFolders.contains(openKey), showCount: false,
                         target: over && !places && SidebarDrag.dragging != .folder, renaming: browser.renamingFolder == openKey,
                         finishRenaming: { browser.finishRenamingFolder(key: folder.key, scope: scope, shown: folder.label, with: $0) },
                         startRenaming: { browser.renamingFolder = openKey },
                         click: { browser.clickFolder(openKey: openKey, clickCount: $0) }) {
            if isPinned {
                Button("Unpin from Sidebar") { browser.unpinFolder(folder.key, named: folder.label) }
            } else if !browser.space.hasPinnedAncestor(folder.key) {
                Button("Pin to Sidebar") { browser.spaces.pinFolder(folder.key, in: browser.spaceID) }
            }
            Button("Rename…") { browser.renamingFolder = openKey }
            Divider()
            Button("Delete Folder…") {
                let count = folder.count
                let message = count == 1 ? String(localized: "Its bookmark goes with it. This can't be undone.")
                                         : String(localized: "Its \(count) bookmarks go with it. This can't be undone.")
                confirmDelete(String(localized: "Delete the folder “\(DialogSpec.name(folder.label))”?"), message) {
                    for inner in folder.flattened() { browser.spaces.unpinFolder(inner.folder.key) }
                    Library.shared.removeFolder(folder.key)
                }
            }
        }
        .padding(.leading, CGFloat(depth) * Metrics.indent)
        .help(ImportedFolders.displayKey(folder.key))
        .dropLine(places && over)
        .draggingRow(SidebarDrag.folder(folder.key), unless: browser.renamingFolder == openKey)
        .dropDestination(for: SidebarDrop.self) { items, _ in
            if reorders, SidebarDrag.pin(items.texts, before: folder.key, in: browser) { return true }
            return SidebarDrag.drop(items.texts, onFolder: folder.key, browser: browser)
        } isTargeted: { target(targetKey, $0) }
    }

    private func tabRow(_ tab: Tab, depth: Int) -> some View {
        SidebarTabRow(tab: tab, browser: browser, isActive: tab.id == browser.activeID, renaming: browser.renamingTab == tab.id) {
            browser.activate(tab.id)
        } close: {
            browser.closeTab(tab.id)
        }
        .padding(.leading, CGFloat(depth) * Metrics.indent)
        .id("tab:\(tab.id)")
        .dropLine(dropTarget == "tab:\(tab.id)" && (SidebarDrag.carriesTab || (SidebarDrag.dragging == .group && tab.groupID == nil)))
        .draggingTab(tab.id, unless: browser.renamingTab == tab.id)
        .dropDestination(for: SidebarDrop.self) { items, _ in
            SidebarDrag.drop(items.texts, onTab: tab.id, browser: browser)
        } isTargeted: { target("tab:\(tab.id)", $0) }
    }

    // MARK: Menus

    /// Asks over this window (not the whole app) before deleting what can't be brought back.
    private func confirmDelete(_ title: String, _ message: String, then delete: @escaping () -> Void) {
        let window = browser.window
        Task { @MainActor in
            if await Dialog.present(in: window, .confirmDelete(title, message))?.button == 1 { delete() }
        }
    }


    /// A dragged group lands just above another group when it is dropped on that group's header or on one of its tabs.
    private func groupLands(above group: UUID) -> Bool {
        guard SidebarDrag.dragging == .group, SidebarDrag.draggingGroup != group, let over = dropTarget else { return false }
        if over == "group:\(group)" { return true }
        guard over.hasPrefix("tab:"), let id = Int(over.dropFirst("tab:".count)) else { return false }
        return browser.tab(id)?.groupID == group
    }

    private func target(_ key: String, _ inside: Bool) {
        if inside { dropTarget = key } else if dropTarget == key { dropTarget = nil }
    }
}

/// A strip below the last row of a group or a folder while something of the sidebar's is being dragged (see `SidebarDragWatcher`), to drop
/// on to put it at the end (the rows take what is dropped just above them). A link dragged from a page doesn't make the watcher true, so
/// the strip doesn't appear for it; dropped on a group's header it goes to the end of the group already.
struct EndOfListDrop: View {
    let depth: Int

    var body: some View {
        Color.clear
            .frame(height: 16)
            .contentShape(Rectangle())
            .padding(.leading, CGFloat(depth) * Metrics.indent)
            .accessibilityHidden(true)
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
