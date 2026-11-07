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
            HStack(spacing: 4) {
                Image(systemName: tab.isUnverified ? "exclamationmark.triangle" : tab.url?.scheme == "https" ? "lock" : "globe")
                    .font(.symbolInline)
                    .foregroundStyle(tab.isUnverified ? Theme.waiting : Theme.secondary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(hasSite && (siteHover || showSite) ? Theme.pill : .clear))
                    .contentShape(Rectangle())
                    .onHover { siteHover = $0 }
                    .onTapGesture { if hasSite { showSite = true } else { edit() } }
                    .accessibleButton(hasSite ? String(localized: "Site Settings") : String(localized: "Edit Address"),
                                      value: Accessibility.connectionValue(scheme: tab.url?.scheme, unverified: tab.isUnverified, choseToGoOn: tab.usesTrustException)) {
                        if hasSite { showSite = true } else { edit() }
                    }
                    .popover(isPresented: $showSite, arrowEdge: .bottom) { SiteSettings(tab: tab) }
                    .onChange(of: tab.url?.host()) { _, _ in showSite = false }
                    .help(tab.usesTrustException ? String(localized: "The certificate wasn’t verified: you chose to go on") : hasSite ? String(localized: "Site Settings") : String(localized: "Edit Address (⌘L)"))
                Text(host ?? String(localized: "Enter Address"))
                    .font(.bodyStrong)
                    .lineLimit(1)
                    .foregroundStyle(Theme.primary)
                    .accessibleButton(String(localized: "Address"), value: tab.url?.absoluteString ?? "", hint: String(localized: "Edit the address"), activate: edit)
            }
            .layoutPriority(1)
            if !compact, let title = Self.shownTitle(tab.title, host: host) {
                Text(verbatim: "·").font(.body).foregroundStyle(Theme.secondary).decorative()
                Text(verbatim: title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(Theme.secondary)
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

struct AddressPlaceholder: View {
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.symbolInline)
            Text("Search or enter address").font(.body)
            Spacer()
        }
        .foregroundStyle(Theme.secondary)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: Metrics.control)
        .background(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).fill(hover ? Theme.pill : Theme.field))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .help("Edit Address (⌘L)")
        .accessibleButton(String(localized: "Address"), hint: String(localized: "Search or enter address"), activate: open)
    }
}
