import AppKit
import SwiftUI

struct AddressPill: View {
    @ObservedObject var tab: Tab
    /// In the narrow sidebar: the site alone, without the page's title or the ⌘L hint.
    var compact = false
    var height = Metrics.control
    let edit: () -> Void
    @ObservedObject private var library = LibraryWatcher.shared
    @State private var hover = false
    @State private var siteHover = false
    @State private var showSite = false
    @StateObject private var press = PressState()

    private var pressed: Bool { press.isPressed }

    /// The page names itself, so its title sits behind a dot and may not start like the rest of an address ("/login", ".bank.com").
    /// Invisible characters (zero-width spaces, direction overrides, Hangul fillers) are taken out first, and stray
    /// marks are trimmed with the punctuation, so nothing can hide a leading "/".
    static func shownTitle(_ title: String, host: String?) -> String? {
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .privateUse, .unassigned, .surrogate, .lineSeparator, .paragraphSeparator]
        var visible = String.UnicodeScalarView()
        visible.append(contentsOf: title.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint && !hidden.contains($0.properties.generalCategory) })
        let marks: Set<Unicode.GeneralCategory> = [.nonspacingMark, .spacingMark, .enclosingMark]
        let trimmed = String(visible).drop {
            $0.isWhitespace || $0.isPunctuation || $0.isSymbol || $0.unicodeScalars.first.map { marks.contains($0.properties.generalCategory) } == true
        }
        guard !trimmed.isEmpty, String(trimmed) != host else { return nil }
        return String(trimmed)
    }

    var body: some View {
        let host = tab.url?.host().map(DisplayHost.trimmed)
        // The lock opens the site's settings; the rest of the pill, the site's name included, edits the address.
        let hasSite = tab.url?.scheme?.hasPrefix("http") == true && host?.isEmpty == false
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Image(systemName: tab.url?.scheme == "https" ? "lock.fill" : "globe")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hasSite && (siteHover || showSite) ? Theme.pill : .clear))
                    .contentShape(Rectangle())
                    .onHover { siteHover = $0 }
                    .onTapGesture { if hasSite { showSite = true } else { edit() } }
                    .popover(isPresented: $showSite, arrowEdge: .bottom) { SiteSettings(tab: tab) }
                    .onChange(of: tab.url?.host()) { _, _ in showSite = false }
                    .help(hasSite ? String(localized: "Site Settings") : String(localized: "Edit Address (⌘L)"))
                Text(host ?? String(localized: "Enter Address"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(Theme.primary)
            }
            .layoutPriority(1)
            if !compact, let title = Self.shownTitle(tab.title, host: host) {
                Text(verbatim: "·").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.faint)
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 0)
            ReaderButton(tab: tab)
            TranslateButton(tab: tab)
            LoginButton(tab: tab)
            PictureInPictureButton(tab: tab)
            if hover || AdBlocker.shared.isAllowed(tab.url?.host() ?? "") { AdBlockShield(tab: tab) }
            if !tab.isPrivate, hover || tab.url.map({ library.isFavorite($0.absoluteString, in: tab.favoritesFolder) }) == true { BookmarkStar(tab: tab) }
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .frame(height: height)
        .background(FieldBackground())
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
                .fill(pressed ? Theme.hoverTab : hover ? Theme.ink(0.03) : .clear)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pressArea(press)
        .onTapGesture(perform: edit)
        .help("Edit Address (⌘L)")
    }
}

/// The whole address, edited in place.
struct AddressField: View {
    @ObservedObject var tab: Tab
    @ObservedObject var browser: Browser
    @State private var text = ""
    @FocusState private var focused: Bool

    private var current: String { tab.url?.absoluteString ?? "" }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.url?.scheme == "https" ? "lock.fill" : "globe")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.primary)
                .focused($focused)
                .onSubmit {
                    browser.open(text, in: .editCurrent)
                    focused = false
                }
                .onKeyPress(.escape) {
                    text = current
                    focused = false
                    return .handled
                }
            TranslateButton(tab: tab)
            LoginButton(tab: tab)
            PictureInPictureButton(tab: tab)
            AdBlockShield(tab: tab)
            BookmarkStar(tab: tab)
            Keycap(focused ? "↵" : "⌘L")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: Metrics.control)
        .background(FieldBackground(focused: focused))
        .onAppear { text = current }
        .onChange(of: tab.url) { if !focused { text = current } }
        .onChange(of: browser.addressFocusRequest) { focused = true }
        .onChange(of: focused) {
            if focused {
                DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
            } else {
                text = current
            }
        }
    }
}

struct AddressPlaceholder: View {
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
            Text("Search or enter address").font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .foregroundStyle(Theme.faint)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: Metrics.control)
        .background(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).fill(hover ? Theme.pill : Theme.field))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
    }
}
