import AppKit
import SwiftUI

/// A ⇧-clicked link floating over the window: esc or a click outside closes it, ⌘↩ keeps it as a tab.
struct PeekCard: View {
    @ObservedObject var tab: Tab
    @ObservedObject var browser: Browser
    var area = PageArea.window

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture { browser.closePeek() }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Favicon(tab: tab)
                    Text(tab.url?.host().map(DisplayHost.trimmed) ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    PeekAction(title: String(localized: "Open as Tab"), key: "⌘↩") { browser.keepPeek() }
                    PeekAction(title: String(localized: "Close"), key: "esc") { browser.closePeek() }
                }
                .padding(.leading, 6)
                .frame(height: 30)
                ZStack(alignment: .top) {
                    Theme.page
                    WebViewHost(tab: tab, browser: browser)
                    LoginOfferBar(tab: tab)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .top) {
                    if tab.isLoading { Meter(fraction: tab.progress).padding(.horizontal, 12).padding(.top, 4).transition(.opacity) }
                }
            }
            .padding(10)
            .floatingPanel(radius: 16)
            .frame(maxWidth: 1180)
            // 64 pt from the page's sides, less where the page is narrow.
            .padding(.horizontal, min(64, max(16, (area.width - 480) / 2)))
            .padding(.leading, area.leading)
            .padding(.trailing, area.trailing)
            .padding(.top, BrowserWindow.barHeight)
            .padding(.bottom, 32)
        }
        .animation(Motion.quick, value: tab.isLoading)
    }
}

/// ⌃Tab: the tabs most recently shown first; let go of ⌃ to go to the picked one. It shows only if ⌃ is held a moment.
struct TabSwitcherView: View {
    @ObservedObject var browser: Browser
    let switcher: Browser.TabSwitcher
    @State private var shown = false

    var body: some View {
        let picked = switcher.order[switcher.index]
        let tabs = switcher.order.compactMap { browser.tab($0) }
        let index = tabs.firstIndex { $0.id == picked } ?? 0
        // Ten rows at most, scrolled to keep the pick in view.
        let first = max(0, min(index - 4, tabs.count - 10))
        VStack(spacing: 2) {
            ForEach(tabs.dropFirst(first).prefix(10)) { tab in
                HStack(spacing: 9) {
                    Favicon(tab: tab)
                    Text(tab.displayTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(tab.url?.host().map(DisplayHost.trimmed) ?? "")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background { if tab.id == picked { SelectedBackground() } }
                .contentShape(Rectangle())
                .onTapGesture { browser.finishSwitching(to: tab.id) }
            }
        }
        .padding(8)
        .frame(width: 460)
        .floatingPanel(radius: 16)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown || Motion.reduced ? 1 : 0.97)
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(Motion.quick) { shown = true }
        }
    }
}

struct PeekAction: View {
    let title: String
    var key: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let key { Keycap(key) }
            }
            .padding(.leading, Metrics.rowPadding)
            .padding(.trailing, key == nil ? Metrics.rowPadding : 4)
            .frame(height: Metrics.row)
            .foregroundStyle(Theme.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(FillStyle())
    }
}

/// The link under the pointer (or a short message), bottom left of the page like Safari's status bar.
struct StatusLine: View {
    let text: String

    static func display(_ href: String) -> String {
        guard let url = URL(string: href), let host = url.host() else { return href.removingPercentEncoding ?? href }
        let rest = String(href.dropFirst((url.scheme?.count ?? 0) + 3 + host.count))
        return DisplayHost.trimmed(host) + (rest.removingPercentEncoding ?? rest)
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(.black.opacity(0.8)))
            .frame(maxWidth: 520, alignment: .leading)
            .padding(8)
            .allowsHitTesting(false)
    }
}
