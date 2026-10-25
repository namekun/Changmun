import AppKit
import SwiftUI

/// "Save this sign-in?" over the top of the page, after a password was submitted.
struct LoginOfferBar: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if let offer = tab.loginOffer {
            let site = DisplayHost.trimmed(offer.host)
            HStack(spacing: 8) {
                Image(systemName: "key.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text(offer.updatesExisting && !offer.username.isEmpty ? String(localized: "Update password for \(offer.username)?") : String(localized: "Save login info for \(site)?"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                // The user name gives way first, so the site stays readable.
                if !offer.username.isEmpty, !offer.updatesExisting {
                    Text(offer.username).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer(minLength: 8)
                PeekAction(title: String(localized: "Save")) {
                    if Logins.save(host: offer.host, username: offer.username, password: offer.password) {
                        tab.browser?.flashStatus(String(localized: "Login info saved"))
                    }
                    tab.loginOffer = nil
                    tab.checkForLogins()
                }
                Button("Never for This Site") {
                    Preferences.shared.neverSaveLoginHosts.append(Logins.hostname(ofKey: site).lowercased())
                    tab.loginOffer = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
                BarButton(symbol: "xmark", help: String(localized: "Close")) { tab.loginOffer = nil }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 40)
            .frame(maxWidth: 620)
            .floatingPanel(radius: 12)
            .padding(10)
            .transition(Motion.pop(.top))
        }
    }
}

/// "A popup was blocked" over the top of the page, with the way to open it, once or always for this site.
struct PopupBar: View {
    @ObservedObject var tab: Tab

    /// Where the pop-up goes, and when a frame in the page asked for it, whose frame.
    private func description(of popup: URL) -> String {
        let host = popup.host() ?? popup.absoluteString
        guard let frame = tab.blockedPopupFrame else { return host }
        return frame.isEmpty ? String(localized: "\(host), from a frame") : String(localized: "\(host), from a frame of \(frame)")
    }

    var body: some View {
        if let popup = tab.blockedPopup {
            HStack(spacing: 8) {
                Image(systemName: "macwindow.badge.plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text("Pop-up blocked").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                Text(description(of: popup)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1)
                if tab.blockedPopupCount > 1 {
                    Text("and \(tab.blockedPopupCount - 1) more").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 8)
                // What is pressed is what the bar shows now: if it has changed by the time the press is handled, nothing happens.
                PeekAction(title: String(localized: "Open")) { tab.openBlockedPopup(always: false, seen: (popup, tab.blockedPopupSite)) }
                if !tab.isPrivate, let site = tab.blockedPopupSite {
                    // Allowing a pop-up from another site's frame allows that site, which the button says.
                    Button(tab.blockedPopupIsFromOtherSite ? String(localized: "Always Allow for \(site)") : String(localized: "Always Allow for This Site")) {
                        tab.openBlockedPopup(always: true, seen: (popup, site))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 4)
                }
                BarButton(symbol: "xmark", help: String(localized: "Close")) { tab.blockedPopup = nil }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 40)
            .frame(maxWidth: 620)
            .floatingPanel(radius: 12)
            .padding(10)
            .transition(Motion.pop(.top))
        }
    }
}

/// On a Chrome Web Store extension page: install it into Changmun (the store's own button only works in Chrome).
@available(macOS 15.4, *)
struct WebStoreBar: View {
    @ObservedObject var tab: Tab
    @ObservedObject var host: ExtensionHost

    var body: some View {
        if let url = tab.url, let id = ChromeWebStore.extensionID(from: url.absoluteString) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text(host.isInstalled(chromeWebStoreID: id) ? String(localized: "This extension is installed in Changmun") : String(localized: "You can use this extension in Changmun"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if let error = host.storeErrors[id] {
                    Text(error).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.waitingText).lineLimit(1)
                }
                Spacer(minLength: 8)
                if host.installing.contains(id) {
                    ProgressView().controlSize(.small).padding(.horizontal, 8)
                } else {
                    PeekAction(title: host.isInstalled(chromeWebStoreID: id) ? String(localized: "Update") : String(localized: "Add to Changmun")) {
                        Task { await host.installFromChromeWebStore(id) }
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 40)
            .frame(maxWidth: 620)
            .floatingPanel(radius: 12)
            .padding(10)
        }
    }
}
