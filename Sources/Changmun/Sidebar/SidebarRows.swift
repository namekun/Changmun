import AppKit
import SwiftUI

/// Whether a bookmark's own tab is shown, open in the background, or not open.
enum BookmarkTabState {
    case closed, open, shown

    @MainActor
    init(_ key: String, _ browser: Browser) {
        guard let tab = browser.bookmarkTab(key) else { self = .closed; return }
        self = browser.isShown(tab) ? .shown : .open
    }
}

struct FavoriteTile<MenuItems: View>: View {
    let entry: Library.Entry
    let state: BookmarkTabState
    /// Its title is being typed in a popover on the tile (see `Browser.renamingBookmark`).
    let renaming: Bool
    let finishRenaming: (String?) -> Void
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
            .renamePopover(shown: entry.title.isEmpty ? entry.url : entry.title, isPresented: renaming, finish: finishRenaming)
            .help(entry.title.isEmpty ? entry.url : entry.title)
            .accessibleButton(Accessibility.bookmarkLabel(title: entry.title, url: entry.url), value: Accessibility.bookmarkValue(state), selected: state == .shown, activate: open)
    }
}

/// The title of a favorite, typed in a small popover on its tile: Return keeps it, Esc drops it, a click outside keeps it, as in a tab's row.
/// `finish` gets what was typed, or nil for Esc.
struct RenamePopover: ViewModifier {
    let shown: String
    let isPresented: Bool
    let finish: (String?) -> Void
    @State private var name = ""
    @FocusState private var editing: Bool

    func body(content: Content) -> some View {
        content.popover(isPresented: Binding(get: { isPresented }, set: { if !$0 { finish(name) } }), arrowEdge: .top) {
            TextField("Bookmark name", text: $name)
                .textFieldStyle(.plain)
                .font(.row)
                .foregroundStyle(Theme.primary)
                .focused($editing)
                .padding(.horizontal, Metrics.rowPadding)
                .frame(width: 220, height: Metrics.row + 8)
                .onAppear {
                    name = shown
                    // Focus taken in the same pass as the field appears is sometimes dropped.
                    DispatchQueue.main.async { editing = true }
                }
                .onSubmit { finish(name) }
                .onKeyPress(.escape) {
                    finish(nil)
                    return .handled
                }
        }
    }
}

extension View {
    func renamePopover(shown: String, isPresented: Bool, finish: @escaping (String?) -> Void) -> some View {
        modifier(RenamePopover(shown: shown, isPresented: isPresented, finish: finish))
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
    /// Its name is being typed in the row (see `Browser.renamingFolder`); `finishRenaming` gets what was typed, or nil for Esc. A row that can't be renamed leaves both.
    var renaming = false
    var finishRenaming: (String?) -> Void = { _ in }
    /// Starts typing the name (for VoiceOver's actions); nil for a row that can't be renamed.
    var startRenaming: (() -> Void)?
    /// A click on the row, with how many clicks it is (2 for the second of a double-click).
    let click: (Int) -> Void
    @ViewBuilder let menu: () -> MenuItems
    @State private var hover = false
    @State private var typed = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: Metrics.iconGap) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary).frame(width: Metrics.icon)
            if renaming {
                TextField("Folder name", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.row)
                    .foregroundStyle(Theme.primary)
                    // A name longer than the field scrolls inside it: it must not draw over the icon before it.
                    .clipped()
                    .focused($editing)
                    .onAppear {
                        typed = name
                        // Focus taken in the same pass as the field appears is sometimes dropped.
                        DispatchQueue.main.async { editing = true }
                    }
                    .onSubmit { finishRenaming(typed) }
                    .onChange(of: editing) { if !editing { finishRenaming(typed) } }
                    .onKeyPress(.escape) {
                        finishRenaming(nil)
                        return .handled
                    }
            } else {
                Text(name).font(.row).foregroundStyle(Theme.body).lineLimit(1)
            }
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                if showCount { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.faint).opacity(hover ? 0 : 1) }
                if hover && !renaming { MoreButton(items: menu) }
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
        .onTapGesture {
            guard !renaming else { return }
            withAnimation(Motion.standard) { click(Browser.clickCount) }
        }
        .contextMenu(menuItems: menu)
        .accessibleButton(name, value: Accessibility.folderValue(open: isOpen, bookmarks: count), enabled: !renaming,
                          actions: [.init(Accessibility.toggleAction(open: isOpen)) { withAnimation(Motion.standard) { click(1) } }]
                              + (startRenaming.map { start in [AccessibleButton.Action(String(localized: "Rename"), start)] } ?? [])) {
            withAnimation(Motion.standard) { click(1) }
        }
    }
}

struct BookmarkRow<MenuItems: View>: View {
    let entry: Library.Entry
    let state: BookmarkTabState
    /// Its title is being typed in the row (see `Browser.renamingBookmark`); `startRenaming` asks for that, `finishRenaming` gets what was
    /// typed, or nil for Esc.
    let renaming: Bool
    let startRenaming: () -> Void
    let finishRenaming: (String?) -> Void
    let open: () -> Void
    @ViewBuilder let menu: () -> MenuItems
    @State private var hover = false
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: Metrics.iconGap) {
            SiteIcon(url: entry.url, size: Metrics.icon)
            if renaming {
                TextField("Bookmark name", text: $name)
                    .textFieldStyle(.plain)
                    .font(state == .shown ? .rowSelected : .row)
                    .foregroundStyle(Theme.primary)
                    // A title longer than the field scrolls inside it: it must not draw over the icon before it.
                    .clipped()
                    .focused($editing)
                    .onAppear {
                        name = entry.title.isEmpty ? entry.url : entry.title
                        // Focus taken in the same pass as the field appears is sometimes dropped.
                        DispatchQueue.main.async { editing = true }
                    }
                    .onSubmit { finishRenaming(name) }
                    .onChange(of: editing) { if !editing { finishRenaming(name) } }
                    .onKeyPress(.escape) {
                        finishRenaming(nil)
                        return .handled
                    }
            } else {
                Text(entry.title.isEmpty ? entry.url : entry.title)
                    .font(state == .shown ? .rowSelected : .row)
                    .foregroundStyle(state == .closed ? Theme.dim : Theme.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ZStack {
                if hover && !renaming {
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
        .onTapGesture { if !renaming { open() } }
        // Alongside the click that opens it, so opening does not wait for a second click.
        .simultaneousGesture(TapGesture(count: 2).onEnded(startRenaming))
        .contextMenu(menuItems: menu)
        .help(entry.url)
        .accessibleButton(Accessibility.bookmarkLabel(title: entry.title, url: entry.url), value: Accessibility.bookmarkValue(state), selected: state == .shown, enabled: !renaming,
                          actions: [.init(String(localized: "Rename"), startRenaming)], activate: open)
    }
}

/// The same items for a favorite and a bookmark, in the same order: the tab, then where it goes, then deleting. In the sidebar, and for a favorite
/// in the strip along the top.
struct BookmarkMenu: View {
    let browser: Browser
    let url: String
    let title: String
    let folder: String
    let key: String
    @ObservedObject private var library = LibraryWatcher.shared

    var body: some View {
        let tab = browser.bookmarkTab(key)
        if let tab {
            Button("Close Tab") { browser.close(tab.id) }
        }
        if let tab, browser.split?.contains(tab.id) == true {
            Button("End Split View") { browser.unsplit() }
        } else if browser.activeID != nil && tab?.id != browser.activeID {
            Button("Show Side by Side with Current Tab") { browser.split(withBookmark: url, key: key) }
        }
        Button("Rename…") { browser.renamingBookmark = key }
        moveMenu
        Divider()
        if Library.isFavorites(folder) {
            Button("Remove from Favorites") { remove(String(localized: "Removed from Favorites")) }
        } else {
            Button("Delete Bookmark") { remove(String(localized: "Deleted the bookmark")) }
        }
    }

    private func remove(_ message: String) {
        let tab = browser.bookmarkTab(key)
        Library.shared.removeBookmark(url: url, folder: folder)
        browser.offerUndo(message) { [browser, url, title, folder, key] in
            Library.shared.addBookmark(url: url, title: title, folder: folder)
            if let tab, browser.tab(tab.id) != nil { browser.bind(tab, to: key) }
        }
    }

    /// "Move To": the favorites and every imported folder, by the browser it came from.
    @ViewBuilder private var moveMenu: some View {
        Menu("Move To") {
            Button("Favorites") { Browser.moveBookmark(url: url, from: folder, to: browser.favoritesFolder) }
                .disabled(folder == browser.favoritesFolder)
            ForEach(library.sources, id: \.source) { group in
                Section(group.source) {
                    ForEach(group.folders.flatMap { $0.paths() }, id: \.key) { item in
                        Button(item.path) { Browser.moveBookmark(url: url, from: folder, to: item.key) }
                            .disabled(item.key == folder)
                    }
                }
            }
        }
    }
}

/// A bookmark's or a folder's row is dragged by the whole row, except while its name is typed: selecting text in the field must not move the row.
/// The payload stays an autoclosure, as in `draggable`: making it notes what is being dragged, which is for when a drag starts.
private struct RowDrag: ViewModifier {
    let payload: () -> String
    let disabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if disabled { content } else { content.draggable(payload()) }
    }
}

extension View {
    func draggingRow(_ payload: @autoclosure @escaping () -> String, unless renaming: Bool) -> some View {
        modifier(RowDrag(payload: payload, disabled: renaming))
    }
}

/// A group header is dragged by the whole row, except while its name is typed: selecting text in the field must not move the group.
private struct GroupDrag: ViewModifier {
    let group: Browser.TabGroup
    let disabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if disabled {
            content
        } else {
            content.draggable(SidebarDrag.group(group.id)) {
                Text(group.name)
                    .font(.row)
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, Metrics.rowPadding)
                    .frame(height: Metrics.row)
                    .background(Theme.hoverTab, in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
            }
        }
    }
}

/// A tab group in the tab list: click to fold it, double-click to rename it, drag to move it; its menu renames, ungroups, saves or closes it. A tab dropped on it joins.
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
                    // The field gets the room before the empty drag area does, so a name that fits is not scrolled; one that does not fit scrolls
                    // inside the field and must not draw over the icon before it.
                    .layoutPriority(1)
                    .clipped()
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
            Color.clear.frame(maxWidth: .infinity).contentShape(Rectangle())
            ZStack(alignment: .trailing) {
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.faint).opacity(hover ? 0 : 1)
                if hover && browser.renamingGroup != group.id { MoreButton { GroupMenu(group: group, browser: browser) } }
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
            withAnimation(Motion.standard) { browser.clickGroup(group.id, clickCount: Browser.clickCount) }
        }
        .contextMenu { GroupMenu(group: group, browser: browser) }
        .help(group.isOpen ? String(localized: "Collapse") : String(localized: "Expand"))
        .accessibleButton(group.name, value: Accessibility.groupValue(open: group.isOpen, tabs: count), header: true, enabled: browser.renamingGroup != group.id, actions: [
            .init(Accessibility.toggleAction(open: group.isOpen)) { withAnimation(Motion.standard) { browser.clickGroup(group.id, clickCount: 1) } },
            .init(String(localized: "Rename")) { browser.renamingGroup = group.id },
        ]) { withAnimation(Motion.standard) { browser.clickGroup(group.id, clickCount: 1) } }
        .modifier(GroupDrag(group: group, disabled: browser.renamingGroup == group.id))
    }

    private func commit() {
        guard browser.renamingGroup == group.id else { return }
        browser.rename(group.id, to: name)
        browser.renamingGroup = nil
    }
}

/// A group's menu, in the tab list and on its chip in the strip along the top.
struct GroupMenu: View {
    let group: Browser.TabGroup
    let browser: Browser

    var body: some View {
        Button("Rename") { browser.renamingGroup = group.id }
        Button("Ungroup") { withAnimation(Motion.standard) { browser.ungroup(group.id) } }
        Button("Save as Bookmark Folder") { _ = withAnimation(Motion.standard) { browser.saveGroup(group.id, to: .pinned(before: nil)) } }
        Divider()
        Button("Close All Tabs in Group") { withAnimation(Motion.standard) { browser.closeGroup(group.id) } }
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
        .accessibilityLabel(String(localized: "Tidy Tabs"))
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
        .accessibleButton(String(localized: "New Tab"), activate: action)
    }
}
