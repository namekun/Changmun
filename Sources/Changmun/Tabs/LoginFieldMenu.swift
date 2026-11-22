import AppKit
import SwiftUI
import WebKit

/// The saved logins offered just under a sign-in field when it gets focus, as Safari and Chrome do; the key button in the address bar
/// stays as it was. The app draws the list in a panel of its own over the page, never in the page, so the page can't read which
/// accounts are saved. The panel never becomes key, so what the user types still goes to the field. Choosing an account fills it the
/// key button's way, Touch ID first when the setting asks for it.
///
/// A field whose menu was shown and then put away (Esc, a click outside the field, a key press, the field losing focus, an account chosen)
/// is not offered again until another page: the menu is a suggestion, and one the user has turned down shouldn't keep coming back.
@MainActor
final class LoginFieldMenu {
    /// Clicks on the menu in its first moment are not taken: a page can focus a field just where the pointer is about to click.
    static let clickDelay: TimeInterval = 0.5
    /// Room around the list for its shadow, inside the panel.
    nonisolated static let shadowRoom = Metrics.section

    struct Shown: Equatable {
        var field: Int
        var matches: [Logins.Match]
        /// Where the field is, in the web view's own coordinates.
        var fieldRect: CGRect
        var since: Date
    }

    private weak var tab: Tab?
    private(set) var shown: Shown?
    /// The page's fields (by the watcher's numbers) whose menu was put away.
    private(set) var dismissed: Set<Int> = []
    private(set) var panel: NSPanel?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(tab: Tab) {
        self.tab = tab
    }

    /// The accounts to offer under a field of the page at `url`. The key button's rules (https only, not on a page whose certificate
    /// couldn't be verified), and never in a private window, which leaves nothing of the user's saved data on view to fill from.
    nonisolated static func offers(url: URL?, isPrivate: Bool, isUnverified: Bool, accounts: (String) -> [Logins.Match]) -> [Logins.Match] {
        guard !isPrivate, !isUnverified, let url, url.scheme == "https", let key = Logins.key(for: url) else { return [] }
        return accounts(key)
    }

    /// A sign-in field has focus, or has moved (a scroll, a resize): `rect` is where it is, in CSS pixels of what is on screen.
    func fieldFocused(_ field: Int, at rect: CGRect) {
        if let shown, shown.field != field { dismiss() }
        guard !dismissed.contains(field), let tab, let webView = tab.webView, let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return }
        let matches = shown?.matches ?? Self.offers(url: webView.url, isPrivate: tab.isPrivate, isUnverified: tab.isUnverified, accounts: Tab.loginAccounts)
        guard !matches.isEmpty else { return }
        let fieldRect = Self.viewRect(rect, zoom: webView.pageZoom * webView.magnification, flipped: webView.isFlipped, height: webView.bounds.height)
        let since = shown?.since ?? Date()
        shown = Shown(field: field, matches: matches, fieldRect: fieldRect, since: since)
        let panel = self.panel ?? makePanel(in: window)
        (panel.contentView as? Hosting)?.rootView = LoginMenuList(matches: matches, width: min(max(fieldRect.width, 200), 360)) { [weak self] in self?.choose($0) }
        place(panel, under: fieldRect, in: webView)
    }

    /// The field lost focus: its menu goes, and is not offered for it again on this page.
    func fieldLeft(_ field: Int) {
        if shown?.field == field { dismiss() }
    }

    /// Esc, a click outside the field, a key press, the window going to the back.
    func dismiss() {
        if let shown { dismissed.insert(shown.field) }
        hide()
    }

    /// Another page (or the tab asleep): its fields are new ones.
    func reset() {
        hide()
        dismissed = []
    }

    func choose(_ match: Logins.Match) {
        guard let shown, Date().timeIntervalSince(shown.since) >= Self.clickDelay else { return }
        dismiss()
        tab?.fillLogin(match)
    }

    /// A rect the page gave in CSS pixels, in the web view's points: scaled by its zoom and pinch, and turned over when the view isn't flipped.
    nonisolated static func viewRect(_ css: CGRect, zoom: CGFloat, flipped: Bool, height: CGFloat) -> CGRect {
        let rect = CGRect(x: css.minX * zoom, y: css.minY * zoom, width: css.width * zoom, height: css.height * zoom)
        return flipped ? rect : CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Where the panel goes on screen: the list's top left just under the field's bottom left, or over the field when the screen
    /// has no room under it. `size` includes the room for the shadow.
    nonisolated static func panelFrame(field: CGRect, size: CGSize, screen: CGRect?) -> CGRect {
        let gap = Metrics.rowGap, room = shadowRoom
        var origin = CGPoint(x: field.minX - room, y: field.minY - gap + room - size.height)
        if let screen, origin.y < screen.minY { origin.y = field.maxY + gap - room }
        return CGRect(origin: origin, size: size)
    }

    private func place(_ panel: NSPanel, under fieldRect: CGRect, in webView: WKWebView) {
        guard let window = webView.window, let content = panel.contentView else { return }
        let onScreen = window.convertToScreen(webView.convert(fieldRect, to: nil))
        panel.setFrame(Self.panelFrame(field: onScreen, size: content.fittingSize, screen: window.screen?.visibleFrame), display: true)
        // A field scrolled out of the page's view has no menu showing, until it is back.
        let inView = webView.bounds.intersects(fieldRect)
        panel.alphaValue = inView ? 1 : 0
        panel.ignoresMouseEvents = !inView
    }

    private func makePanel(in window: NSWindow) -> NSPanel {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.setAccessibilityLabel(String(localized: "Fill in saved login"))
        panel.contentView = Hosting(rootView: LoginMenuList(matches: [], width: 200) { _ in })
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        // Any key goes on to the field (and puts the menu away: the user is typing their own), except Esc, which is the menu's.
        // A click in the field itself keeps it: a page that focuses its field on load gets clicked there next.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let elsewhere = MainActor.assumeIsolated {
                guard let self, let shown = self.shown, event.window !== self.panel else { return false }
                if event.type != .keyDown, let webView = self.tab?.webView, event.window === webView.window,
                   shown.fieldRect.contains(webView.convert(event.locationInWindow, from: nil)) { return false }
                self.dismiss()
                return true
            }
            return elsewhere && event.type == .keyDown && event.keyCode == 53 ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        return panel
    }

    private func hide() {
        shown = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// Never key and never main: the page's field keeps the keyboard while the menu is up.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Takes the first click though its window isn't key (it never is).
    final class Hosting: NSHostingView<LoginMenuList> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

struct LoginMenuList: View {
    let matches: [Logins.Match]
    let width: CGFloat
    let choose: (Logins.Match) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches, id: \.self) { match in
                Row(match: match) { choose(match) }
            }
        }
        .padding(Metrics.rowGap)
        .frame(width: width)
        .floatingPanel(radius: Metrics.cardRadius)
        .padding(LoginFieldMenu.shadowRoom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Fill in saved login"))
    }

    private struct Row: View {
        let match: Logins.Match
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: Metrics.iconGap) {
                    Image(systemName: "key").font(.symbolInline).foregroundStyle(Theme.secondary).frame(width: Metrics.icon)
                    Text(match.title).font(.row).foregroundStyle(Theme.primary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metrics.rowPadding)
                .frame(height: Metrics.row)
                .rowChrome(hover: hover)
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
        }
    }
}
