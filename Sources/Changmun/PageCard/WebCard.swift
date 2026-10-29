import AppKit
import SwiftUI

// MARK: Web content

struct WebCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var overlay: PageOverlay

    init(browser: Browser) {
        self.browser = browser
        overlay = browser.overlay
    }

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                if browser.findBarVisible {
                    FindBar(browser: browser, overlay: overlay).transition(Motion.pop(.topTrailing))
                }
            }
            .overlay(alignment: .top) {
                if let tab = browser.active {
                    VStack(spacing: 0) {
                        LoginOfferBar(tab: tab)
                        PopupBar(tab: tab)
                        if #available(macOS 15.4, *), !browser.isPrivate { WebStoreBar(tab: tab, host: ExtensionHost.shared) }
                    }
                }
            }
            .overlay(alignment: .top) {
                if let tab = browser.active { LoadingLine(tab: tab) }
            }
            .overlay(alignment: .bottomLeading) {
                if let text = overlay.statusMessage ?? overlay.hoveredLink.map(StatusLine.display) {
                    StatusLine(text: text).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: overlay.hoveredLink)
            .animation(.easeOut(duration: 0.12), value: overlay.statusMessage)
            .animation(Motion.quick, value: browser.findBarVisible)
    }

    @ViewBuilder private var content: some View {
        if let split = browser.shownSplit, let left = browser.tab(split.left), let right = browser.tab(split.right) {
            GeometryReader { geo in
                let width = max(1, geo.size.width - SplitDivider.width)
                HStack(spacing: 0) {
                    pane(left).frame(width: (width * overlay.splitFraction).rounded())
                    SplitDivider(fraction: $overlay.splitFraction, total: width)
                    pane(right)
                }
            }
        } else {
            pane(browser.active)
        }
    }

    private func pane(_ tab: Tab?) -> some View {
        // In a split, the pane with the active tab (what the address bar and keys act on) wears the hairline.
        let focused = browser.shownSplit != nil && tab?.id == browser.activeID
        return ZStack {
            if let tab, !tab.isStart {
                Theme.page
                WebViewHost(tab: tab, browser: browser)
                TrustFailureOverlay(tab: tab)
            } else {
                Theme.card
                StartPageContent(browser: browser, mode: tab == nil ? .newTab : .editCurrent)
                HeldPagesHost(browser: browser)
            }
        }
        .clipped()
        .overlay(Rectangle().strokeBorder(focused ? Theme.secondary : .clear, lineWidth: 1))
    }
}

/// Between the halves of a split: drag to share the width, double-click to halve it.
struct SplitDivider: View {
    static let width: CGFloat = 8
    @Binding var fraction: Double
    let total: CGFloat
    @State private var start: Double?
    @State private var hover = false

    var body: some View {
        Capsule()
            .fill(hover || start != nil ? Theme.secondary : Theme.hairline)
            .frame(width: 3, height: 32)
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hover { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let base = start ?? fraction
                        start = base
                        fraction = Browser.clampedSplitFraction(base + drag.translation.width / total)
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { fraction = 0.5 }
            .help("Drag to resize · double-click to split evenly")
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Split View Divider"))
            .accessibilityValue(Accessibility.percentValue(fraction))
            .accessibilityAdjustableAction { direction in
                fraction = Browser.clampedSplitFraction(Accessibility.adjusted(fraction, direction, step: 0.05, in: 0...1))
            }
    }
}
