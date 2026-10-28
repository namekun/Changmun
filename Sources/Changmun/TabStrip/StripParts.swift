import AppKit
import SwiftUI

/// A favorite in the strip: its icon alone, like a pinned tab. Clicking goes to its own tab, as a favorite's tile does in the sidebar.
struct StripFavorite<MenuItems: View>: View {
    let entry: Library.Entry
    let state: BookmarkTabState
    /// Its title is being typed in a popover on the tile (see `Browser.renamingBookmark`).
    let renaming: Bool
    let finishRenaming: (String?) -> Void
    let open: () -> Void
    @ViewBuilder let menu: () -> MenuItems
    @State private var hover = false

    var body: some View {
        SiteIcon(url: entry.url, size: 16)
            .frame(width: TabStrip.favoriteWidth, height: StripTab.height)
            .overlay(alignment: .bottom) {
                if state == .open { Circle().fill(Theme.dim).frame(width: 4, height: 4).padding(.bottom, 2) }
            }
            .rowChrome(hover: hover, selected: state == .shown)
            .onTapGesture(perform: open)
            .onHover { hover = $0 }
            .contextMenu(menuItems: menu)
            .renamePopover(shown: entry.title.isEmpty ? entry.url : entry.title, isPresented: renaming, finish: finishRenaming)
            .help(entry.title.isEmpty ? entry.url : entry.title)
            .accessibleButton(Accessibility.bookmarkLabel(title: entry.title, url: entry.url), value: Accessibility.bookmarkValue(state), selected: state == .shown, activate: open)
    }
}

/// An open tab in the strip: its icon, its title and a close button while the pointer is on it or it is the one shown.
struct StripTab: View {
    static let height: CGFloat = 30

    @ObservedObject var tab: Tab
    let browser: Browser
    let isActive: Bool
    /// Its name is being typed in the tab (see `Browser.renamingTab`).
    let renaming: Bool
    let width: CGFloat
    @State private var hover = false
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 6) {
            Favicon(tab: tab)
            if renaming {
                TextField("Tab name", text: $name)
                    .textFieldStyle(.plain)
                    .font(isActive ? .rowSelected : .row)
                    .foregroundStyle(Theme.primary)
                    .focused($editing)
                    .onAppear {
                        name = tab.displayTitle
                        // Focus taken in the same pass as the field appears is sometimes dropped.
                        DispatchQueue.main.async { editing = true }
                    }
                    .onSubmit(commit)
                    .onChange(of: editing) { if !editing { commit() } }
                    .onKeyPress(.escape) {
                        browser.renamingTab = nil
                        return .handled
                    }
            } else {
                Text(tab.displayTitle)
                    .font(isActive ? .rowSelected : .row)
                    .lineLimit(1)
                    .foregroundStyle(isActive || !tab.isAsleep ? Theme.primary : Theme.dim)
            }
            Spacer(minLength: 0)
            CertificateWaitBadge(tab: tab)
            if tab.isPlayingAudio || tab.isMuted {
                HoverAction(symbol: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            help: tab.isMuted ? String(localized: "Unmute (⌃⌘M)") : String(localized: "Mute (⌃⌘M)")) { tab.toggleMute() }
            }
            // One slot, always the same width, so the title doesn't move when the pointer comes and goes.
            ZStack {
                if hover || isActive {
                    HoverAction(symbol: "xmark", help: String(localized: "Close Tab (⌘W)")) { browser.close(tab.id) }
                } else if browser.split?.contains(tab.id) == true {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .help("Split View")
                        .decorative()
                }
            }
            .frame(width: Metrics.action)
        }
        .padding(.leading, Metrics.rowPadding)
        .padding(.trailing, 4)
        .frame(width: width, height: Self.height)
        .rowChrome(hover: hover, selected: isActive)
        .onHover { hover = $0 }
        .onTapGesture { if !renaming { browser.activate(tab.id) } }
        // Alongside the click that shows the tab, so showing it does not wait for a second click.
        .simultaneousGesture(TapGesture(count: 2).onEnded { browser.renamingTab = tab.id })
        .overlay { MiddleClick { browser.close(tab.id) } }
        .contextMenu { TabMenu(tab: tab, browser: browser, isActive: isActive) { browser.close(tab.id) } }
        .help(tab.url?.absoluteString ?? "")
        .accessibleTab(tab, in: browser, isActive: isActive, renaming: renaming, close: { browser.close(tab.id) }) { browser.activate(tab.id) }
    }

    private func commit() {
        browser.finishRenaming(tab, with: name)
    }
}

/// A group's chip, before its tabs: its colour and name. Click folds the group (its tabs but the shown one leave the strip), double-click
/// renames it; its menu is the sidebar's.
struct StripGroupChip: View {
    let group: Browser.TabGroup
    let count: Int
    @ObservedObject var browser: Browser
    /// A tab is being dragged over it.
    var target = false
    @State private var hover = false
    @State private var name = ""
    @FocusState private var editing: Bool

    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let padding: CGFloat = 10

    /// A group keeps its colour: one of the space tints, picked by its id.
    static func tint(_ group: Browser.TabGroup) -> Color {
        SpaceTint.allCases[Int(group.id.uuid.0) % SpaceTint.allCases.count].color
    }

    /// The chip is as wide as its text, which the strip needs to know to share out the room.
    static func width(_ group: Browser.TabGroup, count: Int, renaming: Bool) -> CGFloat {
        if renaming { return 170 }
        let text = ceil(NSAttributedString(string: label(group, count: count), attributes: [.font: font]).size().width)
        return min(150, text + 8 + 4 + 2 * padding)
    }

    private static func label(_ group: Browser.TabGroup, count: Int) -> String {
        group.isOpen ? group.name : "\(group.name) \(count)"
    }

    var body: some View {
        let renaming = browser.stripRenaming(group: group.id)
        let label = HStack(spacing: 4) {
            Circle().fill(Self.tint(group)).frame(width: 8, height: 8)
            if renaming {
                TextField("Group name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    // A name longer than the field scrolls inside it: it must not draw over the dot before it.
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
                Text(Self.label(group, count: count))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(Theme.primary)
            }
        }
        .padding(.horizontal, Self.padding)
        .frame(width: Self.width(group, count: count, renaming: renaming), height: 24)
        .background(Capsule().fill(Self.tint(group).opacity(target ? 0.45 : hover ? 0.32 : 0.2)))
        .contentShape(Capsule())
        Group {
            if renaming {
                label
            } else {
                Button { withAnimation(Motion.standard) { browser.clickGroup(group.id, clickCount: Browser.clickCount) } } label: { label }
                    .buttonStyle(.plain)
            }
        }
        .onHover { hover = $0 }
        .contextMenu { GroupMenu(group: group, browser: browser) }
        .help(group.isOpen ? String(localized: "Collapse") : String(localized: "Expand"))
        .accessibleButton(group.name, value: Accessibility.groupValue(open: group.isOpen, tabs: count), header: true, enabled: !renaming, actions: [
            .init(Accessibility.toggleAction(open: group.isOpen)) { browser.clickGroup(group.id, clickCount: 1) },
            .init(String(localized: "Rename")) { browser.renamingGroup = group.id },
        ]) { browser.clickGroup(group.id, clickCount: 1) }
    }

    private func commit() {
        guard browser.renamingGroup == group.id else { return }
        browser.rename(group.id, to: name)
        browser.renamingGroup = nil
    }
}

/// A middle click on whatever it covers. It takes only that button's events (hit testing says no to every other), so clicks, drags and
/// hovers reach what is under it.
struct MiddleClick: NSViewRepresentable {
    let action: () -> Void

    final class ClickView: NSView {
        var action: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let type = NSApp.currentEvent?.type, type == .otherMouseDown || type == .otherMouseUp else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber != 2 { super.otherMouseDown(with: event) }
        }

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action() } else { super.otherMouseUp(with: event) }
        }
    }

    func makeNSView(context: Context) -> ClickView { ClickView() }
    func updateNSView(_ view: ClickView, context: Context) { view.action = action }
}
