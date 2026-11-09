import AppKit
import SwiftUI

/// What a page is waiting on the user for. None of it covers the page: a dot at the left of the address says something is there,
/// and its popover lists each as a row.
enum PageNotice: Hashable {
    /// A password was submitted: save it, or never for this site.
    case login
    /// A pop-up was blocked: open it, once or always for its site.
    case popup
    /// A Chrome Web Store extension page (by the extension's ID): install it into Changmun.
    case webStore(String)
}

extension Tab {
    /// The notices pending on this tab, in the order the popover lists them.
    var notices: [PageNotice] {
        var notices: [PageNotice] = []
        if loginOffer != nil { notices.append(.login) }
        if blockedPopup != nil { notices.append(.popup) }
        if #available(macOS 15.4, *), !isPrivate, let url, let id = ChromeWebStore.extensionID(from: url.absoluteString) { notices.append(.webStore(id)) }
        return notices
    }
}

/// What the page is waiting on the user for, said in words at the left of the address, and the popover that lists it.
/// A dot alone said nothing to someone who didn't already know it.
struct NoticesButton: View {
    @ObservedObject var tab: Tab
    @State private var shown = false

    static func label(_ count: Int) -> String {
        count == 1 ? String(localized: "\(count) notice") : String(localized: "\(count) notices")
    }

    /// The symbol and the words for the notices: the notice itself when there is one, how many when there are more.
    static func title(_ notices: [PageNotice]) -> (symbol: String, text: String) {
        guard notices.count == 1, let notice = notices.first else { return ("bell", label(notices.count)) }
        switch notice {
        case .login: return ("key", String(localized: "Save Password?"))
        case .popup: return ("macwindow.badge.plus", String(localized: "Pop-up Blocked"))
        case .webStore: return ("puzzlepiece.extension", String(localized: "Install Extension"))
        }
    }

    var body: some View {
        let notices = tab.notices
        if !notices.isEmpty {
            let title = Self.title(notices)
            Button { shown.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: title.symbol).font(.symbolInline)
                    Text(title.text).font(.secondaryStrong).lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .foregroundStyle(Theme.waitingText)
                .background(Capsule().fill(Theme.pill))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(Self.label(notices.count))
            .accessibilityLabel(Self.label(notices.count))
            .accessibilityHint(String(localized: "Shows what the page is waiting on you for"))
            .popover(isPresented: $shown, arrowEdge: .bottom) { NoticeList(tab: tab, shown: $shown) }
        }
    }
}

/// The pending notices as rows, each with the actions its bar over the page used to have.
struct NoticeList: View {
    @ObservedObject var tab: Tab
    @Binding var shown: Bool

    var body: some View {
        let notices = tab.notices
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(notices.enumerated()), id: \.element) { index, notice in
                if index > 0 { Divider() }
                row(notice)
            }
        }
        .padding(Metrics.inset)
        .frame(width: 400)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NoticesButton.label(notices.count))
        .onChange(of: notices.isEmpty) { _, empty in if empty { shown = false } }
    }

    @ViewBuilder private func row(_ notice: PageNotice) -> some View {
        switch notice {
        case .login: LoginNoticeRow(tab: tab)
        case .popup: PopupNoticeRow(tab: tab)
        case .webStore(let id):
            if #available(macOS 15.4, *) { WebStoreNoticeRow(id: id, host: ExtensionHost.shared) }
        }
    }
}

/// One notice: its symbol, what it says, a line under it, its actions, and × to put it away (when it can be).
private struct NoticeRow<Actions: View>: View {
    let symbol: String
    let title: String
    var detail: [String] = []
    var detailColor = Theme.secondary
    var close: (() -> Void)?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.iconGap) {
            Image(systemName: symbol).font(.symbolInline).foregroundStyle(Theme.secondary)
                .frame(width: Metrics.icon, height: 16)
                .decorative()
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.bodyStrong).foregroundStyle(Theme.primary).lineLimit(2)
                ForEach(detail, id: \.self) { Text($0).font(.secondary).foregroundStyle(detailColor).lineLimit(1) }
                HStack(spacing: Metrics.rowGap) { actions() }
                    .padding(.leading, -Metrics.rowPadding)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let close { BarButton(symbol: "xmark", help: String(localized: "Close"), action: close) }
        }
        .padding(Metrics.inset)
        .accessibilityElement(children: .contain)
    }
}

/// A notice's second action, quieter than the first.
private struct QuietAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.secondaryStrong)
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
            .padding(.horizontal, Metrics.rowPadding)
            .frame(height: Metrics.row)
            .contentShape(Rectangle())
    }
}

/// "Save this sign-in?", after a password was submitted. Nothing is saved but by Save.
private struct LoginNoticeRow: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if let offer = tab.loginOffer {
            let site = DisplayHost.trimmed(offer.host)
            NoticeRow(symbol: "key",
                      title: offer.updatesExisting && !offer.username.isEmpty ? String(localized: "Update password for \(offer.username)?") : String(localized: "Save login info for \(site)?"),
                      detail: !offer.username.isEmpty && !offer.updatesExisting ? [offer.username] : [],
                      close: { tab.loginOffer = nil }) {
                PeekAction(title: offer.updatesExisting && !offer.username.isEmpty ? String(localized: "Update") : String(localized: "Save")) {
                    if Logins.save(host: offer.host, username: offer.username, password: offer.password) {
                        tab.browser?.flashStatus(String(localized: "Login info saved"))
                    }
                    tab.loginOffer = nil
                    tab.checkForLogins()
                }
                QuietAction(title: String(localized: "Never for This Site")) {
                    Preferences.shared.neverSaveLoginHosts.append(Logins.hostname(ofKey: site).lowercased())
                    tab.loginOffer = nil
                }
            }
        }
    }
}

/// "A pop-up was blocked", with the way to open it, once or always for its site. The first one blocked stays until it is opened or
/// closed; later ones only add to the count.
private struct PopupNoticeRow: View {
    @ObservedObject var tab: Tab

    /// Where the pop-up goes, and when a frame in the page asked for it, whose frame.
    private func description(of popup: URL) -> String {
        if tab.blockedPopupIsEmpty { return String(localized: "A window the site fills in itself. Allow it, then try again.") }
        let host = popup.host() ?? popup.absoluteString
        guard let frame = tab.blockedPopupFrame else { return host }
        return frame.isEmpty ? String(localized: "\(host), from a frame") : String(localized: "\(host), from a frame of \(frame)")
    }

    var body: some View {
        if let popup = tab.blockedPopup {
            NoticeRow(symbol: "macwindow.badge.plus", title: String(localized: "Pop-up blocked"),
                      detail: [description(of: popup)] + (tab.blockedPopupCount > 1 ? [String(localized: "and \(tab.blockedPopupCount - 1) more")] : []),
                      close: { tab.blockedPopup = nil }) {
                // What is pressed is what the row shows now: if it has changed by the time the press is handled, nothing happens.
                if !tab.blockedPopupIsEmpty {
                    PeekAction(title: String(localized: "Open")) { tab.openBlockedPopup(always: false, seen: (popup, tab.blockedPopupSite)) }
                }
                if !tab.isPrivate, let site = tab.blockedPopupSite {
                    // Allowing a pop-up from another site's frame allows that site, which the button says.
                    QuietAction(title: tab.blockedPopupIsFromOtherSite ? String(localized: "Always Allow for \(site)") : String(localized: "Always Allow for This Site")) {
                        tab.openBlockedPopup(always: true, seen: (popup, site))
                    }
                }
            }
        }
    }
}

/// On a Chrome Web Store extension page: install it into Changmun (the store's own button only works in Chrome).
@available(macOS 15.4, *)
private struct WebStoreNoticeRow: View {
    let id: String
    @ObservedObject var host: ExtensionHost

    var body: some View {
        let installed = host.isInstalled(chromeWebStoreID: id)
        NoticeRow(symbol: "puzzlepiece.extension",
                  title: installed ? String(localized: "This extension is installed in Changmun") : String(localized: "You can use this extension in Changmun"),
                  detail: host.storeErrors[id].map { [$0] } ?? [], detailColor: Theme.waitingText) {
            if host.installing.contains(id) {
                ProgressView().controlSize(.small).padding(.horizontal, Metrics.rowPadding).frame(height: Metrics.row)
            } else {
                PeekAction(title: installed ? String(localized: "Update") : String(localized: "Add to Changmun")) {
                    Task { await host.installFromChromeWebStore(id) }
                }
            }
        }
    }
}
