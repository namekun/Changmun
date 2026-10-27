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
                if hover {
                    HoverAction(symbol: "xmark", help: String(localized: "Close Tab (⌘W)"), action: close)
                } else if browser.split?.contains(tab.id) == true {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .help("Split View")
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
        .help(tab.url?.absoluteString ?? "")
    }

    private func commit() {
        browser.finishRenaming(tab, with: name)
    }
}

/// What a tab's context menu offers, in the sidebar's row and in the strip along the top: the tab, then where it goes, then closing it,
/// the same order as a bookmark's menu.
struct TabMenu: View {
    @ObservedObject var tab: Tab
    let browser: Browser
    let isActive: Bool
    let close: () -> Void

    var body: some View {
        Button("Reload") {
            if tab.isAsleep { browser.activate(tab.id) } else { tab.webView?.reload() }
        }
        Button("Duplicate Tab") { browser.duplicate(tab.id) }
        Button("Rename Tab…") { browser.renamingTab = tab.id }
        if tab.customTitle != nil { Button("Reset Name") { tab.customTitle = nil } }
        if !tab.isPrivate && tab.bookmarkKey == nil { Button("Move to New Window") { browser.moveToNewWindow(tab.id) } }
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
    }
}

/// A site's icon for a bookmark that may not be open: from the tab favicons, the disk cache or the site.
struct SiteIcon: View {
    let url: String
    let size: CGFloat
    /// False for a private window's page: the icon isn't saved to disk.
    var keep = true
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                IconImage(image: image, size: size)
            } else {
                Image(systemName: "globe").font(.system(size: size * 0.7)).foregroundStyle(Theme.faint)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { image = await Browser.icon(for: url, keep: keep) }
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
                Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
        }
        .frame(width: 16, height: 16)
        .opacity(tab.isAsleep ? 0.6 : 1)
    }
}
