import SwiftUI

/// A small key on a tab whose page is waiting for the user to choose a certificate (see ClientCertificatePrompter), which would
/// otherwise look like a page that is just slow.
struct CertificateWaitBadge: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.waitingForCertificate {
            Image(systemName: "key.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.secondary)
                .frame(width: Metrics.action, height: Metrics.action)
                .help(String(localized: "Waiting for you to choose a certificate"))
        }
    }
}
