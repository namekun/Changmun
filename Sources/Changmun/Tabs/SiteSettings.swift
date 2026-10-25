import SwiftUI

/// What Changmun keeps for one site, in one place: the popover over the site's name in the address bar. Each row is the
/// same setting that Settings shows for all sites. A private window records nothing about a site, so the rows that
/// would (ad blocking, pop-ups, camera and microphone, sleep) stay out of it.
struct SiteSettings: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var permissions = SitePermissions.shared
    @State private var zoom = 1.0

    private var host: String { (tab.url?.host() ?? "").lowercased() }

    var body: some View {
        if tab.url?.scheme?.hasPrefix("http") == true && !host.isEmpty { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Metrics.rowGap) {
            Text(DisplayHost.trimmed(host))
                .font(.rowSelected)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .frame(height: Metrics.row)
            if prefs.blockTrackers && !tab.isPrivate {
                row(String(localized: "Block ads and trackers")) {
                    switchFor(Binding(get: { !AdBlocker.shared.isAllowed(host) }, set: { if !host.isEmpty { AdBlocker.shared.setBlocking($0, for: host) } }))
                }
            }
            row(String(localized: "Zoom")) {
                HStack(spacing: 4) {
                    HoverAction(symbol: "minus", help: String(localized: "Zoom Out")) { setZoom(zoom - 0.1) }
                    Button { setZoom(prefs.defaultZoom) } label: {
                        Text("\(Int((zoom * 100).rounded()))%").font(.rowSelected).monospacedDigit()
                            .frame(width: 48, height: Metrics.action).contentShape(Rectangle())
                    }
                    .buttonStyle(FillStyle(resting: .clear, hoverFill: Theme.pill, radius: 6))
                    .foregroundStyle(Theme.body)
                    .help("Default Zoom")
                    HoverAction(symbol: "plus", help: String(localized: "Zoom In")) { setZoom(zoom + 0.1) }
                }
            }
            if !tab.isPrivate {
                row(String(localized: "Allow pop-ups")) {
                    switchFor(Binding(get: { prefs.allowsPopups(from: host) }, set: {
                        prefs.popupHosts = $0 ? Preferences.adding(host, to: prefs.popupHosts) : Preferences.removing(host, from: prefs.popupHosts)
                    }))
                }
                ForEach(SitePermissions.Device.allCases, id: \.self) { device in
                    row(device.name) {
                        Picker(device.name, selection: Binding(get: { permissions.decision(host, device) },
                                                               set: { permissions.set($0, host: host, device: device) })) {
                            ForEach(SitePermissions.Decision.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                row(String(localized: "Never put to sleep")) {
                    switchFor(Binding(get: { !Preferences.canSleep(host: host, neverSleep: prefs.neverSleepHosts) }, set: {
                        prefs.neverSleepHosts = $0 ? Preferences.adding(host, to: prefs.neverSleepHosts) : Preferences.removing(host, from: prefs.neverSleepHosts)
                    }))
                }
            }
        }
        .padding(Metrics.inset + 4)
        .frame(width: 280)
        .onAppear { zoom = Double(tab.webView?.pageZoom ?? 1) }
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: Metrics.iconGap) {
            Text(label).font(.row).foregroundStyle(Theme.body).lineLimit(1)
            Spacer(minLength: 0)
            control()
        }
        .frame(height: Metrics.row)
    }

    private func switchFor(_ binding: Binding<Bool>) -> some View {
        Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }

    private func setZoom(_ value: Double) {
        tab.setZoom(value)
        zoom = Double(tab.webView?.pageZoom ?? 1)
    }
}
