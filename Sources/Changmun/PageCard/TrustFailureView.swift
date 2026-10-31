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
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.symbolEmpty).foregroundStyle(Theme.waiting).decorative()
                    Text("This connection isn’t private").font(.heading).foregroundStyle(Theme.primary)
                        .accessibilityAddTraits(.isHeader)
                }
                // The host with its port (never trimmed of its www), an internationalized name in Unicode as well, and the whole address.
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: failure.hostAndPort).font(.title.monospaced()).foregroundStyle(Theme.primary)
                    if let unicode = failure.unicodeHost { Text(verbatim: unicode).font(.body).foregroundStyle(Theme.body) }
                    Text(verbatim: failure.address).font(.caption.monospaced()).foregroundStyle(Theme.secondary).lineLimit(3)
                }
                .textSelection(.enabled)
                Text("Changmun can’t confirm that you are connected to \(failure.hostAndPort). Someone on the network may be pretending to be this site and could see what you send.")
                    .font(.body).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
                Text(Self.reason(failure.reason, host: ServerTrust.sanitized(failure.host)))
                    .font(.bodyStrong).foregroundStyle(Theme.primary).fixedSize(horizontal: false, vertical: true)
                if failure.changed {
                    Label("The certificate of this site has changed since you chose to go on. Don’t continue unless you know why.", systemImage: "exclamationmark.octagon")
                        .font(.bodyStrong).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 16) {
                    Button(action: goBack) { Text("Go Back").frame(minWidth: 90) }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                    Spacer(minLength: 0)
                }
                DisclosureGroup(isExpanded: $showDetails) {
                    details.padding(.top, 8)
                } label: {
                    Text("Certificate Details").font(.secondaryStrong).foregroundStyle(Theme.secondary)
                }
                switch failure.visit {
                case .offered:
                    if showDetails {
                        Text("Don’t enter passwords or payment details here unless you know and trust this site.")
                            .font(.secondary).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(action: visit) { Text("Visit This Website").font(.secondary) }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                case .refusedStrictTransport:
                    Label("This site insists on a secure connection, so its certificate can’t be overridden.", systemImage: "lock.slash")
                        .font(.secondaryStrong).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                case .refusedWentBad:
                    Label("This site’s certificate was fine earlier in this session and isn’t now. Someone may be intercepting the connection, so there is no way to go on.", systemImage: "exclamationmark.octagon")
                        .font(.secondaryStrong).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Certificate warning"))
        // The page is behind this view: a person who can't see it has to be told that it stands there.
        .onAppear { Announcer.announce(String(localized: "This connection isn’t private. \(Self.reason(failure.reason, host: ServerTrust.sanitized(failure.host)))"), important: true) }
    }

    private var details: some View {
        let c = failure.certificate
        return VStack(alignment: .leading, spacing: 8) {
            row(String(localized: "Name"), c.subject)
            row(String(localized: "Issued by"), c.issuer)
            row(String(localized: "Valid from"), c.notBefore.formatted(date: .long, time: .omitted))
            row(String(localized: "Expires"), c.notAfter.formatted(date: .long, time: .omitted))
            if !c.names.isEmpty { row(String(localized: "Other names"), ServerTrust.sanitized(c.names.joined(separator: ", "), limit: 400)) }
            row(String(localized: "SHA-256 fingerprint"), c.spacedFingerprint)
        }
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.secondary).foregroundStyle(Theme.secondary).frame(width: 110, alignment: .trailing)
            Text(verbatim: value).font(.secondary).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
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
