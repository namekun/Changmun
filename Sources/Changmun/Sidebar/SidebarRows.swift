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

/// A tab group in the tab list: click to fold it, drag to move it; its menu renames, ungroups, saves or closes it. A tab dropped on it joins.
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
            grab(Image(systemName: "square.on.square").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary).frame(width: Metrics.icon))
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
                grab(Text(group.name).font(.row).foregroundStyle(Theme.secondary).lineLimit(1))
            }
            grab(Color.clear.frame(maxWidth: .infinity).contentShape(Rectangle()))
            grab(ZStack(alignment: .trailing) {
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.faint).opacity(hover ? 0 : 1)
                if hover && browser.renamingGroup != group.id { MoreButton { menu } }
            }
            .frame(minWidth: Metrics.action, alignment: .trailing))
            grab(Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.faint)
                .rotationEffect(.degrees(group.isOpen ? 90 : 0))
                .frame(width: Metrics.icon))
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

    /// The header is dragged by everything but the name field, so selecting text while renaming does not move the group.
    private func grab<Content: View>(_ content: Content) -> some View {
        content.draggable(SidebarDrag.group(group.id)) {
            Text(group.name)
                .font(.row)
                .foregroundStyle(Theme.primary)
                .padding(.horizontal, Metrics.rowPadding)
                .frame(height: Metrics.row)
                .background(Theme.hoverTab, in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Rename") { browser.renamingGroup = group.id }
        Button("Ungroup") { withAnimation(Motion.standard) { browser.ungroup(group.id) } }
        Button("Save as Bookmark Folder") { _ = withAnimation(Motion.standard) { browser.saveGroup(group.id, to: .pinned(before: nil)) } }
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
