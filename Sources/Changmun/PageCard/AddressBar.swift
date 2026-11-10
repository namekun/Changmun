import AppKit
import SwiftUI

struct AddressPill: View {
    @ObservedObject var tab: Tab
    let edit: () -> Void
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

    /// What the pill calls the page: its site, a file's own name, a plain word for a page made of data; nil when there is no address.
    static func shownName(for url: URL?) -> String? {
        switch url?.scheme?.lowercased() {
        case "file": url.map(\.lastPathComponent)
        case "data": String(localized: "Data Page")
        default: url?.host().map(DisplayHost.trimmed)
        }
    }

    /// An http page says so in words beside its name (a local file or a data page is not on the network).
    /// A page that came over the network without encryption. This Mac's own servers (a project being built) never leave the machine.
    static func isNotSecure(_ url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "http", let host = url?.host()?.lowercased() else { return false }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let loopbackIPv4 = parts.count == 4 && parts.first == "127" && parts.allSatisfy { UInt8($0) != nil }
        return !(host == "localhost" || host.hasSuffix(".localhost") || loopbackIPv4 || host == "::1" || host == "[::1]")
    }

    /// What "Paste and Go" would open: the pasteboard's text if it makes an address or a search.
    static func pastedAddress(_ text: String?) -> URL? { text.flatMap(AddressInput.resolve) }

    /// What a drag out of the site's name carries: the page's address, named by its title.
    private var dragProvider: NSItemProvider {
        guard let url = tab.url else { return NSItemProvider() }
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = tab.displayTitle
        return provider
    }

    var body: some View {
        let host = tab.url?.host().map(DisplayHost.trimmed)
        let name = Self.shownName(for: tab.url)
        let notSecure = Self.isNotSecure(tab.url)
        // The lock opens the site's settings; the rest of the pill, the site's name included, edits the address.
        let hasSite = tab.url?.scheme?.hasPrefix("http") == true && host?.isEmpty == false
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                NoticesButton(tab: tab)
                Image(systemName: tab.isUnverified ? "exclamationmark.triangle" : tab.url?.scheme == "https" ? "lock" : "globe")
                    .font(.symbolInline)
                    .foregroundStyle(tab.isUnverified || notSecure ? Theme.waitingText : Theme.secondary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(hasSite && (siteHover || showSite) ? Theme.pill : .clear))
                    .contentShape(Rectangle())
                    .onHover { siteHover = $0 }
                    .onTapGesture { if hasSite { showSite = true } else { edit() } }
                    .onDrag { dragProvider }
                    .accessibleButton(hasSite ? String(localized: "Site Settings") : String(localized: "Edit Address"),
                                      value: Accessibility.connectionValue(scheme: tab.url?.scheme, unverified: tab.isUnverified, choseToGoOn: tab.usesTrustException)) {
                        if hasSite { showSite = true } else { edit() }
                    }
                    .popover(isPresented: $showSite, arrowEdge: .bottom) { SiteSettings(tab: tab) }
                    .onChange(of: tab.url?.host()) { _, _ in showSite = false }
                    .help(tab.usesTrustException ? String(localized: "The certificate wasn’t verified: you chose to go on") : hasSite ? String(localized: "Site Settings") : String(localized: "Edit Address (⌘L)"))
                Text(name ?? String(localized: "Enter Address"))
                    .font(.bodyStrong)
                    .lineLimit(1)
                    .foregroundStyle(Theme.primary)
                    .accessibleButton(String(localized: "Address"), value: tab.url?.absoluteString ?? "", hint: String(localized: "Edit the address"), activate: edit)
                    .onDrag { dragProvider }
                if notSecure {
                    // The lock's own label says the same to a screen reader.
                    Text("Not Secure")
                        .font(.secondaryStrong)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(Theme.waitingText)
                        .decorative()
                        .onTapGesture { if hasSite { showSite = true } else { edit() } }
                }
            }
            .layoutPriority(1)
            CaptureButton(tab: tab)
            if let title = Self.shownTitle(tab.title, host: name) {
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
            // Always there, for the keyboard and VoiceOver; quiet until the pointer is over the pill.
            AdBlockShield(tab: tab, emphasized: hover)
            if !tab.isPrivate { BookmarkStar(tab: tab, emphasized: hover) }
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .frame(height: Metrics.control)
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
        .contextMenu {
            Button("Copy Address") {
                guard let address = tab.url?.absoluteString else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
                tab.browser?.flashStatus(String(localized: "Address copied"))
            }
            .disabled(tab.url == nil)
            Button("Paste and Go") {
                if let url = Self.pastedAddress(NSPasteboard.general.string(forType: .string)) { tab.load(url) }
            }
            .disabled(Self.pastedAddress(NSPasteboard.general.string(forType: .string)) == nil)
        }
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
