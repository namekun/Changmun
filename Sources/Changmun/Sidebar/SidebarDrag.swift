import AppKit
import SwiftUI

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
            .help("Drag to resize the sidebar · double-click for default width")
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Sidebar Width"))
            .accessibilityValue(Accessibility.widthValue(width))
            .accessibilityAdjustableAction { direction in
                width = Accessibility.adjusted(width, direction, step: 20, in: Preferences.sidebarWidths)
            }
    }
}

/// What the sidebar takes when something is dropped on it: one of its own rows (carried as text naming it), or a
/// link dragged from a page, the address or another app.
struct SidebarDrop: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.text, importing: { SidebarDrop(text: $0) })
        // Only taken in: what the sidebar hands out is its own text, never an address another app would open.
        ProxyRepresentation(importing: { (url: URL) in SidebarDrop(text: url.absoluteString) })
    }
}

extension Array where Element == SidebarDrop {
    var texts: [String] { map(\.text) }
}

/// Whether something of the sidebar's is being carried, for the views that make room to drop it only then.
@MainActor
final class SidebarDragWatcher: ObservableObject {
    static let shared = SidebarDragWatcher()
    @Published fileprivate(set) var isDragging = false
}

/// Dragging tabs, groups and favorites around the sidebar: the payload names what is dragged.
@MainActor
enum SidebarDrag {
    enum Kind { case tab, bookmark, folder, group }
    /// What the latest drag from the sidebar carries: set when the drag starts, so drop targets can show where it lands.
    private(set) static var dragging: Kind? {
        didSet {
            if dragging != .group { draggingGroup = nil }
            if SidebarDragWatcher.shared.isDragging != (dragging != nil) { SidebarDragWatcher.shared.isDragging = dragging != nil }
            watchForRelease()
        }
    }
    /// The group being dragged, so its own header and tabs show no line.
    private(set) static var draggingGroup: UUID?

    private static var releaseWatch: Timer?

    /// A drag that is cancelled (esc, dropped outside the sidebar) reaches no drop target, so nothing else would end it:
    /// once the mouse button is up, nothing is being carried any more.
    private static func watchForRelease() {
        releaseWatch?.invalidate()
        releaseWatch = nil
        guard dragging != nil else { return }
        releaseWatch = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated { dragEnded() }
        }
    }

    static func dragEnded(buttons: Int = NSEvent.pressedMouseButtons) {
        if buttons & 1 == 0 { dragging = nil }
    }

    static func tab(_ id: Int) -> String { dragging = .tab; return "changmun-tab:\(id)" }
    static func bookmark(_ url: String, in folder: String) -> String { dragging = .bookmark; return "changmun-bookmark:" + folder + "\n" + url }
    static func folder(_ key: String) -> String { dragging = .folder; return "changmun-folder:" + key }
    static func group(_ id: UUID) -> String { dragging = .group; draggingGroup = id; return "changmun-group:\(id.uuidString)" }

    static func groupID(_ items: [String]) -> UUID? {
        guard let item = items.first, item.hasPrefix("changmun-group:") else { return nil }
        return UUID(uuidString: String(item.dropFirst("changmun-group:".count)))
    }

    /// A web address dragged in from a page or another app.
    static func link(_ items: [String]) -> URL? {
        guard let item = items.first?.trimmingCharacters(in: .whitespacesAndNewlines), !item.hasPrefix("changmun-"),
              let url = URL(string: item), ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil else { return nil }
        return url
    }

    /// Nothing from the sidebar is being carried: a link from outside, which lands where a tab would.
    static var carriesTab: Bool { dragging == .tab || dragging == nil }

    static func folderKey(_ items: [String]) -> String? {
        guard let item = items.first, item.hasPrefix("changmun-folder:") else { return nil }
        return String(item.dropFirst("changmun-folder:".count))
    }

    /// A folder dropped among the pinned ones is pinned there (before `target`, or at the end); a group becomes a
    /// folder pinned there.
    @discardableResult
    static func pin(_ items: [String], before target: String?, in browser: Browser) -> Bool {
        defer { dragging = nil }
        if let group = groupID(items) {
            _ = withAnimation(Motion.standard) { browser.saveGroup(group, to: .pinned(before: target)) }
            return true
        }
        guard let key = folderKey(items) else { return false }
        withAnimation(Motion.standard) { browser.spaces.pinFolder(key, before: target, in: browser.spaceID) }
        return true
    }

    /// A tab dropped below the list goes to its end, out of any group.
    static func dropAtEnd(_ items: [String], browser: Browser) -> Bool {
        defer { dragging = nil }
        if let url = link(items) {
            withAnimation(Motion.standard) {
                let tab = browser.openTab(url: url)
                // Put where the user chose, not where its page would sort it to.
                tab.sortsIntoGroup = false
                browser.moveTab(tab.id, to: nil)
            }
            return true
        }
        if let group = groupID(items) {
            withAnimation(Motion.standard) { browser.moveGroup(group, before: nil) }
            return true
        }
        guard let id = tabID(items) else { return false }
        withAnimation(Motion.standard) {
            browser.moveTab(id, to: nil)
            browser.removeFromGroup(id)
        }
        return true
    }

    /// The bookmark (or favorite) being dragged, and the folder it is in.
    static func bookmark(_ items: [String]) -> (url: String, folder: String)? {
        guard let item = items.first else { return nil }
        guard item.hasPrefix("changmun-bookmark:") else { return nil }
        let rest = item.dropFirst("changmun-bookmark:".count)
        guard let newline = rest.firstIndex(of: "\n") else { return nil }
        return (String(rest[rest.index(after: newline)...]), String(rest[..<newline]))
    }

    /// A bookmark or favorite dropped on a folder moves into it; a group becomes a folder inside it.
    static func drop(_ items: [String], onFolder folder: String, browser: Browser) -> Bool {
        defer { dragging = nil }
        if let url = link(items) {
            Library.shared.addBookmark(url: url.absoluteString, title: url.host() ?? url.absoluteString, folder: folder)
            return true
        }
        if let group = groupID(items) {
            _ = withAnimation(Motion.standard) { browser.saveGroup(group, to: .folder(folder)) }
            return true
        }
        // A tab becomes the folder's bookmark and that bookmark's tab, as on the favorites; the folder opens to show it.
        if let id = tabID(items), let tab = browser.tab(id), !tab.isPrivate, let url = tab.url, ["http", "https"].contains(url.scheme?.lowercased()) {
            let address = url.absoluteString
            if !Library.shared.isFavorite(address, in: folder) {
                Library.shared.addBookmark(url: address, title: tab.bookmarkTitle.isEmpty ? (url.host() ?? address) : tab.bookmarkTitle, folder: folder)
            }
            withAnimation(Motion.standard) {
                browser.bind(tab, to: Browser.bookmarkKey(url: address, folder: folder))
                if !browser.space.openFolders.contains("pin:" + folder) { browser.spaces.toggleOpen("pin:" + folder, in: browser.spaceID) }
            }
            return true
        }
        guard let (url, from) = bookmark(items) else { return false }
        // From its own folder, dropped on the folder itself: to the end of it.
        if from == folder { return Library.shared.moveFolderBookmark(url, to: nil, in: folder) }
        Browser.moveBookmark(url: url, from: from, to: folder)
        return true
    }

    static func drop(_ items: [String], onTab target: Int, browser: Browser) -> Bool {
        defer { dragging = nil }
        if let url = link(items) {
            withAnimation(Motion.standard) {
                // Just above the tab it was dropped on, where the drop line showed, and into its group.
                let tab = browser.openTab(url: url)
                tab.sortsIntoGroup = false
                browser.moveTab(tab.id, to: nil)
                browser.dropTab(tab.id, on: target)
            }
            return true
        }
        if let group = groupID(items) {
            withAnimation(Motion.standard) { browser.moveGroup(group, before: target) }
            return true
        }
        guard let id = tabID(items) else { return false }
        withAnimation(Motion.standard) { browser.dropTab(id, on: target) }
        return true
    }

    static func drop(_ items: [String], onGroup group: UUID, browser: Browser) -> Bool {
        defer { dragging = nil }
        if let url = link(items) {
            withAnimation(Motion.standard) { browser.addTab(browser.openTab(url: url).id, to: group) }
            return true
        }
        if let dragged = groupID(items) {
            withAnimation(Motion.standard) { browser.dropGroup(dragged, onGroup: group) }
            return true
        }
        guard let id = tabID(items) else { return false }
        withAnimation(Motion.standard) { browser.addTab(id, to: group) }
        return true
    }

    private static func tabID(_ items: [String]) -> Int? {
        guard let item = items.first, item.hasPrefix("changmun-tab:") else { return nil }
        return Int(item.dropFirst("changmun-tab:".count))
    }

    /// A bookmark dropped on a row of a folder goes just above it, in that folder (from another folder it moves in); with no row
    /// (below the last one), to the end of it. Anything else dropped there lands in the folder as it would on the folder itself.
    static func drop(_ items: [String], onBookmark target: String?, in folder: String, browser: Browser) -> Bool {
        guard let (url, from) = bookmark(items) else { return drop(items, onFolder: folder, browser: browser) }
        defer { dragging = nil }
        guard url != target || from != folder else { return true }
        withAnimation(Motion.standard) {
            if from != folder { Browser.moveBookmark(url: url, from: from, to: folder) }
            Library.shared.moveFolderBookmark(url, to: target, in: folder)
        }
        return true
    }

    /// A tab (or a link) dropped below the last tab of a group goes to the end of the group, from inside it too.
    static func drop(_ items: [String], onEndOf group: UUID, browser: Browser) -> Bool {
        guard groupID(items) == nil else { dragging = nil; return false }
        return drop(items, onGroup: group, browser: browser)
    }

    /// A favorite dropped on a favorite moves there; a bookmark from a folder or a tab dropped on one is pinned there.
    /// With no target, past the last tile, it goes to the end.
    static func drop(_ items: [String], onFavorite target: String?, browser: Browser) -> Bool {
        defer { dragging = nil }
        let favorites = browser.favoritesFolder
        if let url = link(items) {
            let address = url.absoluteString
            if !Library.shared.isFavorite(address, in: favorites) { _ = Library.shared.toggleBookmark(url: address, title: url.host() ?? address, in: favorites) }
            Library.shared.moveFavorite(address, to: target, in: favorites)
            return true
        }
        if let group = groupID(items) {
            // Kept together as one folder, the first of the pinned ones, just below the favorites.
            let first = browser.spaces.space(browser.spaceID).pinnedFolders.first
            _ = withAnimation(Motion.standard) { browser.saveGroup(group, to: .pinned(before: first)) }
            return true
        }
        if let (url, folder) = bookmark(items) {
            if folder != favorites { Browser.moveBookmark(url: url, from: folder, to: favorites) }
            Library.shared.moveFavorite(url, to: target, in: favorites)
            return true
        }
        if let id = tabID(items), let tab = browser.tab(id), !tab.isPrivate, let url = tab.url?.absoluteString {
            if !Library.shared.isFavorite(url, in: favorites) { _ = Library.shared.toggleBookmark(url: url, title: tab.bookmarkTitle, in: favorites) }
            browser.bind(tab, to: Browser.bookmarkKey(url: url, folder: favorites))
            Library.shared.moveFavorite(url, to: target, in: favorites)
            return true
        }
        return false
    }
}
