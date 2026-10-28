import AppKit
import SwiftUI

/// The pages saved to read later, at the top of the bookmarks popover: a folder-like row that folds the list away, and a row for each page.
struct ReadingListSection: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var library = LibraryWatcher.shared
    @AppStorage("readingListCollapsed") private var collapsed = false

    var body: some View {
        let items = library.readingList
        FolderRow(name: String(localized: "Reading List"), symbol: "eyeglasses", count: items.count, isOpen: !collapsed, showCount: !items.isEmpty,
                  click: { _ in collapsed.toggle() }) {
            Button("Clear Read Items") { browser.clearReadItems() }
                .disabled(!items.contains(where: \.read))
        }
        if !collapsed {
            if items.isEmpty {
                Text("Pages you save to read later show up here.")
                    .font(.row)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, Metrics.rowPadding)
                    .padding(.vertical, Metrics.rowPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(items) { item in ReadingRow(item: item, browser: browser) }
            }
        }
        SectionGap()
    }
}

/// A saved page: its site's icon, the title (bold until it is read), where it is from and how long ago it was saved. Unread pages have a dot;
/// the pointer over the row shows a button that takes the page off the list.
struct ReadingRow: View {
    let item: ReadingItem
    @ObservedObject var browser: Browser
    @State private var hover = false

    var body: some View {
        HStack(spacing: Metrics.iconGap) {
            SiteIcon(url: item.url, size: Metrics.icon, keep: !browser.isPrivate)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(item.read ? .row : .rowSelected)
                    .foregroundStyle(item.read ? Theme.dim : Theme.primary)
                    .lineLimit(1)
                Text("\(ReadingList.siteName(of: item.url)) · \(ReadingList.dateLabel(item.added))")
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ZStack {
                if hover {
                    Button { browser.removeReadingItem(item) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .frame(width: Metrics.action, height: Metrics.action)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .help("Remove from Reading List")
                    .accessibilityLabel("Remove from Reading List")
                } else if !item.read {
                    Circle().fill(Theme.primary).frame(width: 6, height: 6)
                }
            }
            .frame(width: Metrics.action)
        }
        .padding(.leading, Metrics.rowPadding)
        .padding(.trailing, 4)
        .frame(height: Metrics.row + 12)
        .rowChrome(hover: hover)
        .onHover { hover = $0 }
        .onTapGesture { browser.openReadingItem(item, inNewTab: Browser.commandClick) }
        .contextMenu {
            Button("Open in New Tab") { browser.openReadingItem(item, inNewTab: true) }
            Button(item.read ? String(localized: "Mark as Unread") : String(localized: "Mark as Read")) { browser.markReadingItem(item, read: !item.read) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
            Divider()
            Button("Remove from Reading List") { browser.removeReadingItem(item) }
        }
        .help(item.url)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
