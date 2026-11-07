import AppKit
import SwiftUI

/// A private window: no history, closed tabs, reading list or AI on the page, and plainly what stays and what doesn't.
struct StartPrivateView: View {
    let search: AnyView

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "eye.slash").font(.symbolEmpty).foregroundStyle(Theme.primary)
                .frame(width: 62, height: 52)
                .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Theme.field))
                .decorative()
            Text("Private Window").font(.display).foregroundStyle(Theme.primary).padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            Text("What you browse in this window isn't kept in history or the session. When you close it, cookies and site data go with it.")
                .font(.title).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 460).padding(.top, 8)
            search.frame(maxWidth: 620).padding(.top, 32)
            HStack(alignment: .top, spacing: 24) {
                note("eye.slash", String(localized: "Nothing is kept"),
                     String(localized: "History, the session, cookies and site data are erased when you close the window. Search suggestions aren't sent either."))
                note("sparkles", String(localized: "The AI rests"),
                     String(localized: "A private window can't be shown to the AI, so the AI panel and its suggestions don't appear here."))
                note("shield", String(localized: "It isn't anonymous"),
                     String(localized: "The sites you visit, and your company, school or internet provider, still see it. Ad and tracker blocking stays on."))
            }
            .frame(maxWidth: 880)
            .padding(.top, 32)
        }
        .padding(.horizontal, 24)
    }

    private func note(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.symbolToolbar).foregroundStyle(Theme.primary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(Theme.field))
                .decorative()
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title).font(.bodyStrong).foregroundStyle(Theme.primary).accessibilityAddTraits(.isHeader)
                Text(verbatim: text).font(.secondary).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}
