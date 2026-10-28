import SwiftUI

/// Over the page whose server's certificate can't be verified: drawn by the app, so no page can imitate it or press its buttons. "Go Back" is the
/// default; "Visit This Website" is smaller and asks the Mac's owner to confirm before anything is accepted.
struct TrustFailureOverlay: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if let failure = tab.trustFailure {
            TrustFailureView(failure: failure, goBack: { tab.leaveUntrustedSite() }, visit: { Task { await tab.continueToUntrustedSite() } })
                .id(failure.url)
        }
    }
}

struct TrustFailureView: View {
    let failure: TrustFailure
    let goBack: () -> Void
    let visit: () -> Void
    @State private var showDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 26)).foregroundStyle(Theme.waiting)
                    Text("This connection isn’t private").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.primary)
                }
                Text("Changmun can’t confirm that you are connected to \(DisplayHost.trimmed(failure.host)). Someone on the network may be pretending to be this site and could see what you send.")
                    .font(.system(size: 13)).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
                Text(Self.reason(failure.reason, host: DisplayHost.trimmed(failure.host)))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).fixedSize(horizontal: false, vertical: true)
                if failure.changed {
                    Label("The certificate of this site has changed since you chose to go on. Don’t continue unless you know why.", systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button(action: goBack) { Text("Go Back").frame(minWidth: 90) }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                    Spacer(minLength: 0)
                }
                DisclosureGroup(isExpanded: $showDetails) {
                    details.padding(.top, 8)
                } label: {
                    Text("Certificate Details").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                if showDetails {
                    Text("Don’t enter passwords or payment details here unless you know and trust this site.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(action: visit) { Text("Visit This Website").font(.system(size: 12)) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.card)
    }

    private var details: some View {
        let c = failure.certificate
        return VStack(alignment: .leading, spacing: 6) {
            row(String(localized: "Name"), c.subject)
            row(String(localized: "Issued by"), c.issuer)
            row(String(localized: "Valid from"), c.notBefore.formatted(date: .long, time: .omitted))
            row(String(localized: "Expires"), c.notAfter.formatted(date: .long, time: .omitted))
            if !c.names.isEmpty { row(String(localized: "Other names"), c.names.joined(separator: ", ")) }
            row(String(localized: "SHA-256 fingerprint"), c.spacedFingerprint)
        }
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 110, alignment: .trailing)
            Text(verbatim: value).font(.system(size: 12)).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The reason in plain words.
    static func reason(_ reason: TrustReason, host: String) -> String {
        switch reason {
        case .selfSigned: String(localized: "The certificate is self-signed: no authority vouches for it.")
        case .unknownAuthority: String(localized: "The certificate was issued by an authority this Mac doesn’t trust.")
        case .expired(let date): String(localized: "The certificate expired on \(date.formatted(date: .long, time: .omitted)).")
        case .notYetValid(let date): String(localized: "The certificate isn’t valid until \(date.formatted(date: .long, time: .omitted)).")
        case .nameMismatch: String(localized: "The certificate is for another name than \(host).")
        case .other: String(localized: "The certificate can’t be verified.")
        }
    }
}
