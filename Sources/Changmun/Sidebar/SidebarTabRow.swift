import AppKit
import SwiftUI

/// A tab row is dragged by the whole row, except while its name is typed: selecting text in the field must not move the tab.
private struct TabDrag: ViewModifier {
    let id: Int
    let disabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if disabled { content } else { content.draggable(SidebarDrag.tab(id)) }
    }
}

extension View {
    func draggingTab(_ id: Int, unless renaming: Bool) -> some View { modifier(TabDrag(id: id, disabled: renaming)) }
}

struct SidebarTabRow: View {
    @ObservedObject var tab: Tab
    let browser: Browser
    let isActive: Bool
    /// Its name is being typed in the row (see `Browser.renamingTab`).
    let renaming: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hover = false
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: Metrics.iconGap) {
            Favicon(tab: tab)
            if renaming {
                TextField("Tab name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.row)
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
                    .font(.row)
                    .lineLimit(1)
                    .foregroundStyle(isActive || !tab.isAsleep ? Theme.primary : Theme.secondary)
            }
            Spacer(minLength: 0)
            CertificateWaitBadge(tab: tab)
            TabAudioButton(tab: tab, isActive: isActive)
            // The tab's menu, as on a bookmark's, a folder's and a group's row, for what a right-click alone would hide.
            if hover && !renaming { MoreButton { TabMenu(tab: tab, browser: browser, isActive: isActive, close: close) } }
            if browser.split?.contains(tab.id) == true { SplitMarker() }
            // One slot, always the same width, so what is before it doesn't move when the pointer comes and goes.
            ZStack {
                if hover {
                    HoverAction(symbol: "xmark", help: isActive ? String(localized: "Close Tab (⌘W)") : String(localized: "Close Tab"), action: close)
                }
            }
            .frame(width: Metrics.action)
        }
        .padding(.leading, Metrics.rowPadding)
        .padding(.trailing, 4)
        .frame(height: Metrics.row)
        .rowChrome(hover: hover, selected: isActive)
        .onHover { hover = $0 }
        .onTapGesture { if !renaming { select() } }
        // Alongside the click that shows the tab, so showing it does not wait for a second click.
        .simultaneousGesture(TapGesture(count: 2).onEnded { browser.renamingTab = tab.id })
        .contextMenu { TabMenu(tab: tab, browser: browser, isActive: isActive, close: close) }
        .help(Accessibility.tabHelp(title: tab.displayTitle, address: tab.url?.absoluteString, isStart: tab.isStart, asleep: tab.isAsleep && !isActive))
        .accessibleTab(tab, in: browser, isActive: isActive, renaming: renaming, close: close) { select() }
        .closesOnMiddleClick("tab:\(tab.id)", close: close)
    }

    private func commit() {
        browser.finishRenaming(tab, with: name)
    }
}

/// What a tab's context menu offers in its sidebar row: the tab, then where it goes, then closing it, the same order as a bookmark's menu.
struct TabMenu: View {
    @ObservedObject var tab: Tab
    let browser: Browser
    let isActive: Bool
    let close: () -> Void

    var body: some View {
        Button("Reload") {
            if tab.isAsleep { browser.activate(tab.id) } else { tab.reload() }
        }
        Button("Duplicate Tab") { browser.duplicate(tab.id) }
        Button("Rename Tab…") { browser.renamingTab = tab.id }
        if tab.customTitle != nil { Button("Reset Name") { tab.customTitle = nil } }
        if !tab.isPrivate && tab.bookmarkKey == nil { Button("Move to New Window") { browser.moveToNewWindow(tab.id) } }
        let otherSpaces = browser.spaces.spaces.filter { $0.id != tab.spaceID }
        if !browser.isPrivate && tab.bookmarkKey == nil && !otherSpaces.isEmpty {
            Menu("Move to Space") {
                ForEach(otherSpaces) { space in
                    Button(space.name) { withAnimation(Motion.standard) { _ = browser.moveTab(tab.id, toSpace: space.id) } }
                }
            }
        }
        if let url = tab.url, url.scheme?.hasPrefix("http") == true {
            ShareLink(item: url)
            OpenInMenu(url: url)
        }
        Divider()
        if browser.split?.contains(tab.id) == true {
            Button("End Split View") { browser.unsplit() }
        } else if !isActive && browser.activeID != nil {
            Button("Show Side by Side with Current Tab") { browser.split(with: tab.id) }
        }
        Button("Copy Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url?.absoluteString ?? "", forType: .string)
        }
        if !tab.isAsleep { Button(tab.isMuted ? String(localized: "Unmute") : String(localized: "Mute Tab")) { tab.toggleMute() } }
        if tab.isAsleep && !isActive && !tab.isStart {
            Button("Wake Tab") { _ = tab.wake() }
        } else if !tab.isAsleep && !browser.isShown(tab) {
            Button("Put to Sleep") { tab.sleep() }
        }
        Button("Save as PDF…") { Task { await SavePage.save(tab, as: .pdf) } }
            .disabled(tab.isAsleep)
        Button("Capture Full Page…") { Task { await SavePage.save(tab, as: .image) } }
            .disabled(tab.isAsleep || tab.showsPDF)
        Divider()
        if !tab.isPrivate {
            Button("Pin to Favorites") {
                if let url = tab.url?.absoluteString {
                    if !Library.shared.isFavorite(url, in: tab.favoritesFolder) { _ = Library.shared.toggleBookmark(url: url, title: tab.bookmarkTitle, in: tab.favoritesFolder) }
                    browser.bind(tab, to: Browser.bookmarkKey(url: url, folder: tab.favoritesFolder))
                }
            }
            Button("Add to Reading List") { browser.addToReadingList(tab) }
                .disabled(!ReadingList.canSave(tab.url?.absoluteString, isPrivate: false))
        }
        if tab.groupID == nil {
            Button("Add to New Group") { _ = withAnimation(Motion.standard) { browser.group([tab.id]) } }
        } else {
            Button("Remove from Group") { withAnimation(Motion.standard) { browser.removeFromGroup(tab.id) } }
        }
        let otherGroups = browser.spaceGroups.filter { $0.id != tab.groupID }
        if !otherGroups.isEmpty {
            Menu("Move to Group") {
                ForEach(otherGroups) { group in
                    Button(group.name) { withAnimation(Motion.standard) { browser.addTab(tab.id, to: group.id) } }
                }
            }
        }
        Divider()
        Button("Close Tab", action: close)
        let listed = browser.listedInOrder.map(\.id)
        Button("Close Other Tabs") { withAnimation(Motion.standard) { browser.closeOtherTabs(keeping: tab.id) } }
            .disabled(Browser.othersToClose(keeping: tab.id, listed: listed).isEmpty)
        Button("Close Tabs Below") { withAnimation(Motion.standard) { browser.closeTabsBelow(tab.id) } }
            .disabled(Browser.belowToClose(tab.id, listed: listed).isEmpty)
    }
}

/// A tab in the split: shown on its row, its bookmark's row too, whether or not the pointer is there.
struct SplitMarker: View {
    var body: some View {
        Image(systemName: "rectangle.split.2x1")
            .font(.symbolInline)
            .foregroundStyle(Theme.tertiary)
            .help("Split View")
            .decorative()
    }
}

/// The speaker on a row whose tab plays sound or is muted: a click mutes or unmutes it. The same on a tab's row, a bookmark's and a favorite's.
/// The key is shown only on the tab shown, which is the one ⌃⌘M mutes.
struct TabAudioButton: View {
    @ObservedObject var tab: Tab
    let isActive: Bool

    var body: some View {
        if tab.isPlayingAudio || tab.isMuted {
            HoverAction(symbol: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2",
                        help: isActive ? (tab.isMuted ? String(localized: "Unmute (⌃⌘M)") : String(localized: "Mute (⌃⌘M)"))
                                       : (tab.isMuted ? String(localized: "Unmute") : String(localized: "Mute Tab"))) { tab.toggleMute() }
        }
    }
}

/// The same speaker as a badge on a favorite's corner: the tile is too small for a button beside the icon, and one laid over
/// it hid half the icon.
struct TabAudioBadge: View {
    @ObservedObject var tab: Tab
    let isActive: Bool

    var body: some View {
        if tab.isPlayingAudio || tab.isMuted {
            let help = isActive ? (tab.isMuted ? String(localized: "Unmute (⌃⌘M)") : String(localized: "Mute (⌃⌘M)"))
                                : (tab.isMuted ? String(localized: "Unmute") : String(localized: "Mute Tab"))
            Button { tab.toggleMute() } label: {
                Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 7, weight: .semibold))  // design-exempt: a badge on a favorite's icon
                    .foregroundStyle(Theme.primary)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Theme.card))
                    .overlay(Circle().strokeBorder(Theme.cardEdge))
                    .frame(width: Metrics.action, height: Metrics.action)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(Accessibility.label(fromHelp: help))
        }
    }
}

/// A site's icon for a bookmark that may not be open: from the tab favicons, the disk cache or the site.
struct SiteIcon: View {
    let url: String
    let size: CGFloat
    /// False for a private window's page: the icon isn't saved to disk.
    var keep = true
    /// False: only an icon that is kept already is shown, and no site is asked for one (the start page's list).
    var fetches = true
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                IconImage(image: image, size: size)
            } else {
                Image(systemName: "globe").font(.system(size: size * 0.7)).foregroundStyle(Theme.tertiary)  // design-exempt: a share of the icon plate's size
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { image = fetches ? await Browser.icon(for: url, keep: keep) : Browser.savedIcon(for: url) }
    }
}

struct Favicon: View {
    @ObservedObject var tab: Tab

    var body: some View {
        Group {
            if tab.isLoading && tab.favicon == nil {
                ProgressView().controlSize(.mini)
            } else if let image = tab.favicon {
                IconImage(image: image, size: 16)
            } else if let url = tab.url?.absoluteString {
                // A sleeping tab has no page to ask; the site's saved icon stands in.
                SiteIcon(url: url, size: 16, keep: !tab.isPrivate)
            } else {
                Image(systemName: "globe").font(.symbolToolbar).foregroundStyle(Theme.tertiary)
            }
        }
        .frame(width: 16, height: 16)
        .opacity(tab.isAsleep ? 0.6 : tab.isLoading && tab.favicon != nil ? 0.35 : 1)
        // Loading again (a reload, the next page): the spinner over the icon it has.
        .overlay { if tab.isLoading && tab.favicon != nil { ProgressView().controlSize(.mini) } }
    }
}
