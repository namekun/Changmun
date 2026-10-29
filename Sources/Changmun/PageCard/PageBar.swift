import AppKit
import SwiftUI

/// The bar on top of the page card, as in Dia: the sidebar switch and moving around, the address with the page's title,
/// then what acts on the whole window.
struct PageBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        HStack(spacing: Metrics.rowGap) {
            if prefs.tabLayout == .top {
                // The tabs are in the strip above: this opens the rest of the sidebar over the page.
                BarButton(symbol: "sidebar.left", help: browser.showSidebarOverlay ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar"),
                          label: String(localized: "Sidebar"), value: Accessibility.shownValue(browser.showSidebarOverlay)) { browser.showSidebarOverlay.toggle() }
            } else {
                if !browser.showSidebar && !browser.fullScreen { Color.clear.frame(width: BrowserWindow.windowButtonsTrailing - Metrics.inset) }
                BarButton(symbol: "sidebar.left", help: browser.showSidebar ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar"),
                          label: String(localized: "Sidebar"), value: Accessibility.shownValue(browser.showSidebar)) { browser.showSidebar.toggle() }
            }
            if let tab = browser.active { NavigationButtons(tab: tab) } else { DisabledNavigationButtons() }
            Group {
                if let tab = browser.active {
                    if prefs.addressBarOnTop {
                        AddressField(tab: tab, browser: browser).id(tab.id)
                    } else {
                        AddressPill(tab: tab) { browser.commandBar = .editCurrent }
                    }
                } else {
                    AddressPlaceholder { browser.openNewTab(.emptied) }
                }
            }
            .padding(.horizontal, Metrics.inset)
            if #available(macOS 15.4, *), !browser.isPrivate { ExtensionButtons(browser: browser) }
            DownloadButton(browser: browser, arrowEdge: .bottom)
            if browser.isPrivate {
                PrivateBadge()
            } else {
                AIButton(isOn: browser.panelShown) { browser.showChat.toggle() }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: BrowserWindow.pageBarHeight)
        .padding(.top, BrowserWindow.cardInset)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.cardEdge).frame(height: 1) }
    }
}

struct NavigationButtons: View {
    @ObservedObject var tab: Tab

    var body: some View {
        BarButton(symbol: "chevron.left", help: String(localized: "Back (⌘[)")) { tab.webView?.goBack() }.disabled(!tab.canGoBack)
        BarButton(symbol: "chevron.right", help: String(localized: "Forward (⌘])")) { tab.webView?.goForward() }.disabled(!tab.canGoForward)
        BarButton(symbol: tab.isLoading ? "xmark" : "arrow.clockwise", help: String(localized: "Reload (⌘R)"), label: tab.isLoading ? String(localized: "Stop") : String(localized: "Reload")) {
            if tab.isLoading { tab.webView?.stopLoading() } else { tab.webView?.reload() }
        }
    }
}

struct DisabledNavigationButtons: View {
    var body: some View {
        BarButton(symbol: "chevron.left", help: String(localized: "Back")) {}.disabled(true)
        BarButton(symbol: "chevron.right", help: String(localized: "Forward")) {}.disabled(true)
        BarButton(symbol: "arrow.clockwise", help: String(localized: "Reload")) {}.disabled(true)
    }
}

/// Nunsseop's search field: a softly filled rounded box; loading shows as its 3 pt bar along the bottom edge, which the box's corners clip,
/// so it never runs into the text above it.
struct FieldBackground: View {
    var focused = false

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
            .fill(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: focused ? 0.5 : 0))
    }
}

/// How far the page has loaded: a thin line along the top edge of the page, clear of the address and its letters.
struct LoadingLine: View {
    @ObservedObject var tab: Tab

    var body: some View {
        GeometryReader { geo in
            if tab.isLoading {
                Rectangle().fill(Theme.meter)
                    .frame(width: max(3, geo.size.width * min(1, max(0.05, tab.progress))), height: 2)
                    .animation(.easeOut(duration: 0.2), value: tab.progress)
                    .transition(.opacity)
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .animation(Motion.quick, value: tab.isLoading)
        // Said as a value that changes all the time, not announced at every step.
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(!tab.isLoading)
        .accessibilityLabel(String(localized: "Loading"))
        .accessibilityValue(Accessibility.loadingValue(progress: tab.progress))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct BarButton: View {
    let symbol: String
    let help: String
    /// What VoiceOver calls it, when that isn't the help text without its shortcut; `value` says its state.
    var label: String?
    var value: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: Metrics.control, height: Metrics.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(FillStyle())
        .foregroundStyle(enabled ? Theme.secondary : Theme.ink(0.22))
        .help(help)
        .accessibilityLabel(label ?? Accessibility.label(fromHelp: help))
        .accessibilityValue(value ?? "")
    }
}

/// Like Nunsseop's selected tab: a capsule with a symbol and a word, brighter while the panel is open.
struct AIButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                Text("AI").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: Metrics.control)
            .foregroundStyle(Theme.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(FillStyle(resting: isOn ? Theme.pill : Theme.hoverTab, hoverFill: isOn ? Theme.pill : Theme.field, radius: nil))
        .help("AI Panel (⌘E)")
        .accessibilityLabel(String(localized: "AI Panel"))
        .accessibilityValue(Accessibility.onOffValue(isOn))
    }
}

/// Where the AI button would be, in a private window.
struct PrivateBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash").font(.system(size: 11, weight: .semibold))
            Text("Private Window").font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.control)
        .foregroundStyle(Theme.primary)
        .background(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .help("Leaves no history, cookies or site data. AI and extensions can’t see this window.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Private Window"))
        .accessibilityHint(String(localized: "Leaves no history, cookies or site data. AI and extensions can’t see this window."))
    }
}

/// Empty parts of the bar move the window, and a double click does what a title bar's would.
struct WindowDragArea: NSViewRepresentable {
    /// System Settings › Desktop & Dock › "Double-click a window's title bar to".
    enum DoubleClick: Equatable {
        case zoom, minimize, nothing

        static func from(action: String?, minimizeFlag: Bool) -> Self {
            switch action {
            case "Minimize": .minimize
            case "None": .nothing
            case nil: minimizeFlag ? .minimize : .zoom
            default: .zoom
            }
        }

        static var current: Self {
            let defaults = UserDefaults.standard
            return from(action: defaults.string(forKey: "AppleActionOnDoubleClick"), minimizeFlag: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"))
        }
    }

    /// How far the pointer must move from where the button went down before the window follows it: a hand on a mouse trembles, and a
    /// double-click with a small tremor is still a double-click.
    static let dragThreshold: CGFloat = 3

    /// Whether the pointer has moved far enough from the point the button went down at (both in window coordinates) to drag the window.
    static func movedEnough(from start: NSPoint, to point: NSPoint, threshold: CGFloat = dragThreshold) -> Bool {
        hypot(point.x - start.x, point.y - start.y) > threshold
    }

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch DoubleClick.current {
                case .zoom: window.performZoom(nil)
                case .minimize: window.performMiniaturize(nil)
                case .nothing: break
                }
                return
            }
            // The drag starts only once the pointer has moved: a drag begun on a still click leaves the window server
            // holding the second click, so a double click never arrives. The wait ends with the button's release; it
            // looks again every so often at whether the button is still down, so a press that is never followed by a
            // release (nothing real does that, but a test can send one) does not hold the app.
            let start = event.locationInWindow
            while true {
                guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(timeIntervalSinceNow: 0.1), inMode: .eventTracking, dequeue: true) else {
                    if NSEvent.pressedMouseButtons & 1 == 0 { return }
                    continue
                }
                if next.type == .leftMouseUp { return }
                if WindowDragArea.movedEnough(from: start, to: next.locationInWindow) {
                    window.performDrag(with: next)
                    return
                }
            }
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}
