import AppKit
import SwiftUI

// MARK: Sidebar

struct Sidebar: View {
    @ObservedObject var browser: Browser
    /// Over the page, opened from the page bar when the tabs are in a strip on top: no window buttons above it, and the page bar already
    /// holds the address, the downloads and the AI button.
    var overlay = false
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var library = LibraryWatcher.shared
    @State private var dropTarget: String?
    @State private var showLibrary = false
    @State private var bookmarkQuery = ""
    @State private var newTabHover = false
    private var toolbarHere: Bool { !overlay && prefs.toolbarPlace == .sidebar }

    var body: some View {
        VStack(spacing: 0) {
            if toolbarHere {
                SidebarToolbar(browser: browser)
            } else {
                WindowDragArea().frame(height: browser.fullScreen || overlay ? 0 : BrowserWindow.windowButtonsBottom)
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
                                .dropLine(groupLands(above: group.id))
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
                        .dropLine(dropTarget == "tabs:end" && (SidebarDrag.carriesTab || SidebarDrag.dragging == .group))
                        .dropDestination(for: SidebarDrop.self) { items, _ in
                            SidebarDrag.dropAtEnd(items.texts, browser: browser)
                        } isTargeted: { target("tabs:end", $0) }
                }
                .padding(.horizontal, Metrics.inset)
                .padding(.top, toolbarHere ? Metrics.section : Metrics.inset)
                .padding(.bottom, Metrics.inset)
                .animation(Motion.standard, value: browser.tabs.map(\.id))
                .animation(Motion.standard, value: browser.groups)
                .animation(Motion.standard, value: browser.tabs.map(\.groupID))
                .animation(Motion.standard, value: browser.lastTidy)
                .animation(Motion.standard, value: browser.notice)
                .animation(Motion.standard, value: browser.space.pinnedFolders)
                .animation(Motion.standard, value: browser.space.openFolders)
                .animation(Motion.quick, value: dropTarget)
            }
            // A tab switched to from the keyboard or the command bar comes into view.
            .onChange(of: browser.activeID) { _, id in
                guard let id else { return }
                withAnimation(Motion.standard) { scroller.scrollTo("tab:\(id)") }
            }
            }
            .modifier(SpaceSlide(spaceID: browser.spaceID, direction: browser.spaceDirection))

            DownloadShelf(browser: browser).padding(.bottom, Metrics.inset)
            // The rest of the browser, out of the way at the bottom: every bookmark, downloads, extensions and AI.
            HStack(spacing: Metrics.rowGap) {
                BarButton(symbol: "bookmark", help: String(localized: "Bookmarks")) { showLibrary.toggle() }
                    .popover(isPresented: $showLibrary, arrowEdge: .top) { allBookmarks }
                if toolbarHere {
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
                if toolbarHere {
                    if browser.isPrivate {
                        PrivateBadge()
                    } else {
                        AIButton(isOn: browser.panelShown) { browser.showChat.toggle() }
                    }
                }
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.bottom, browser.isPrivate ? Metrics.inset : 0)
            if !browser.isPrivate {
                SpaceSwitcher(browser: browser)
                    .padding(.horizontal, Metrics.inset)
                    .padding(.bottom, Metrics.inset)
            }
        }
    }

    // MARK: Parts

    private var favorites: some View {
        // As many tiles a row as the sidebar's width holds: four at the default width, up to seven when wide.
        VStack(spacing: 0) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 4)], spacing: 4) {
                ForEach(library.favorites(in: browser.favoritesFolder), id: \.url) { entry in
                    let key = Browser.bookmarkKey(url: entry.url, folder: browser.favoritesFolder)
                    FavoriteTile(entry: entry, state: BookmarkTabState(key, browser), renaming: browser.renamingBookmark == key,
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
                .frame(height: Metrics.section - Metrics.rowGap)
                .contentShape(Rectangle())
                .dropLine(dropTarget == "fav:end" && SidebarDrag.dragging != .folder)
                .dropDestination(for: SidebarDrop.self) { items, _ in
                    SidebarDrag.drop(items.texts, onFavorite: nil, browser: browser)
                } isTargeted: { target("fav:end", $0) }
        }
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
                    confirmDelete(String(localized: "Delete all bookmarks imported from \(group.source)?")) { Library.shared.removeSource(group.source) }
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
        guard browser.space.openFolders.contains(scope + folder.key) else { return rows }
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
            BookmarkRow(entry: entry, state: BookmarkTabState(key, browser), renaming: browser.renamingBookmark == key,
                        startRenaming: { browser.renamingBookmark = key },
                        finishRenaming: { browser.finishRenamingBookmark(url: entry.url, folder: folder, title: entry.title, with: $0) }) {
                browser.openBookmark(entry.url, key: key, inNewTab: Browser.commandClick)
            } menu: {
                BookmarkMenu(browser: browser, url: entry.url, title: entry.title, folder: folder, key: key)
            }
            .padding(.leading, CGFloat(depth) * Metrics.indent)
            .draggingRow(SidebarDrag.bookmark(entry.url, in: folder), unless: browser.renamingBookmark == key)
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
                         click: { browser.clickFolder(openKey: openKey, clickCount: $0) }) {
            if isPinned {
                Button("Unpin from Sidebar") { browser.spaces.unpinFolder(folder.key, in: browser.spaceID) }
            } else if !browser.space.hasPinnedAncestor(folder.key) {
                Button("Pin to Sidebar") { browser.spaces.pinFolder(folder.key, in: browser.spaceID) }
            }
            Button("Rename…") { browser.renamingFolder = openKey }
            Divider()
            Button("Delete Folder…") {
                let count = folder.count
                let question = count == 1 ? String(localized: "Delete the folder “\(folder.label)” and its \(count) bookmark?")
                                          : String(localized: "Delete the folder “\(folder.label)” and its \(count) bookmarks?")
                confirmDelete(question) {
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
            browser.close(tab.id)
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

/// The space between two parts of the sidebar.
struct SectionGap: View {
    var body: some View {
        Color.clear
            .frame(height: Metrics.section - 2 * Metrics.rowGap)
            .contentShape(Rectangle())
    }
}
