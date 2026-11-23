import AppKit
import Combine
import SwiftUI
import WebKit

/// The saved logins offered just under a sign-in field when it gets focus, as Safari and Chrome do; the key button in the address bar
/// stays as it was. The app draws the list in a panel of its own over the page, never in the page, so the page can't read which
/// accounts are saved. The panel never becomes key, so what the user types still goes to the field. Choosing an account fills it the
/// key button's way, Touch ID first when the setting asks for it.
///
/// A field losing focus only hides the menu: tabbing from the user name to the password offers it again there, as Chrome does.
/// Turned down on purpose (Esc, typing in the field, a click outside the menu) or used, it isn't offered again until another page,
/// whatever field gets focus: a page that keeps drawing its field anew would otherwise bring it back each time.
@MainActor
final class LoginFieldMenu {
    /// A click counts only this long after the panel appeared where it is, and only once the pointer has moved inside it: a page can
    /// focus a field, or move one, so that the panel comes up under a pointer that was about to click something else.
    static let clickDelay: TimeInterval = 0.5
    /// A move further than this from where the panel appeared counts as appearing again.
    static let moveTolerance: CGFloat = 4
    /// Room around the list for its shadow, inside the panel.
    nonisolated static let shadowRoom = Metrics.section

    /// Whether the panel may come up over the tab's page now (`isShowable`; tests put their own, as their windows are never key).
    static var showable: (Tab, WKWebView) -> Bool = { isShowable(tab: $0, webView: $1) }

    struct Shown: Equatable {
        var field: Int
        /// The document the field is in, as its own frame says (not the web view's address).
        var origin: Tab.Origin
        var matches: [Logins.Match]
        /// Where the field is, in the web view's own coordinates.
        var fieldRect: CGRect
    }

    private weak var tab: Tab?
    private(set) var shown: Shown?
    /// The menu was turned down or used on this page.
    private(set) var dismissedOnPage = false
    /// When the menu last appeared on this page: it appears again at most once in `reshowInterval`, later if asked sooner, so a page
    /// can't make it jump about with focus() and blur(), or by drawing its field anew. (Each appearance starts the click guard over.)
    private var appearedAt: Date?
    static let reshowInterval: TimeInterval = 1
    private var waiting: Task<Void, Never>?
    /// The accounts for this page once looked up, none included, so a scroll or another field doesn't look again.
    private var pageOffers: (origin: Tab.Origin, offers: [Logins.Match])?
    private var lookup: Task<Void, Never>?
    /// The field that has focus while the accounts are looked up, or while the menu waits to appear again.
    private var pending: (field: Int, rect: CGRect, origin: Tab.Origin)?
    /// When the panel last appeared or moved, and where it was then.
    private(set) var armedAt: Date?
    private var armedFrame: CGRect?
    /// The pointer has moved inside the panel since then.
    private(set) var pointerMovedInside = false
    private(set) var panel: NSPanel?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var browserWatch: AnyCancellable?
    /// Tests move the clock and see what a chosen account would fill.
    var now: () -> Date = Date.init
    var fill: ((Logins.Match) -> Void)?

    init(tab: Tab) {
        self.tab = tab
    }

    /// The origin whose logins a field is offered: the document's own (`document`, from its frame), and only while it is the page
    /// committed and no navigation is under way. During one, `webView.url` already names where it goes while this document is still on
    /// screen, so a page could send itself to a bank's address that never answers and be offered the bank's accounts. The key button's
    /// rules besides: https only, not on a page whose certificate couldn't be verified. A private window gets the menu as it gets the
    /// key button (Safari and Chrome fill saved passwords there too); it still saves nothing.
    static func pageOrigin(document: Tab.Origin?, committed: URL?, provisional: Bool, isUnverified: Bool) -> Tab.Origin? {
        guard !provisional, !isUnverified, let document, document == Tab.httpsOrigin(committed), !Tab.isUnverified(committed) else { return nil }
        return document
    }

    /// The panel is for the page the user is looking at and typing into: the tab shown in its window (not one held behind, which
    /// the AI may be using), every view up to the window visible and not see-through, the window key, the page with the keyboard.
    static func isShowable(tab: Tab, webView: WKWebView) -> Bool {
        guard let window = webView.window, window.isKeyWindow, !tab.isInBackground, isVisible(webView) else { return false }
        return (window.firstResponder as? NSView)?.isDescendant(of: webView) == true
    }

    /// Whether `view` and every view it is in are drawn: not hidden, and not made transparent (a page held behind another, PassiveHost).
    static func isVisible(_ view: NSView) -> Bool {
        guard view.window != nil else { return false }
        var current: NSView? = view
        while let shown = current {
            if shown.isHidden || shown.alphaValue < 0.01 { return false }
            current = shown.superview
        }
        return true
    }

    /// A sign-in field has focus, or has moved (a scroll, a resize): `rect` is where it is, in CSS pixels of what is on screen, and
    /// `document` the origin of the document it is in.
    func fieldFocused(_ field: Int, at rect: CGRect, document: Tab.Origin?) {
        if let shown, shown.field != field { hide() }
        guard !dismissedOnPage, let tab, tab.webView != nil,
              let origin = Self.pageOrigin(document: document, committed: tab.committedURL, provisional: tab.isLoadingProvisionally, isUnverified: tab.isUnverified)
        else { return hide() }
        if let pageOffers, pageOffers.origin == origin {
            present(field, at: rect, origin: origin, offers: pageOffers.offers)
            return
        }
        pending = (field, rect, origin)
        guard lookup == nil else { return }
        lookup = Task { [weak self] in
            let offers = await Tab.loginAccounts(origin.key)
            guard let self, !Task.isCancelled else { return }
            self.lookup = nil
            self.pageOffers = (origin, offers)
            if let pending = self.pending, pending.origin == origin {
                self.pending = nil
                self.present(pending.field, at: pending.rect, origin: origin, offers: offers)
            }
        }
    }

    /// The field lost focus: the menu goes, but may come back for the next field.
    func fieldLeft(_ field: Int) {
        if pending?.field == field { pending = nil }
        if shown?.field == field { hide() }
    }

    /// A navigation began: the page on screen is on its way out, and offers nothing until the next one commits.
    func navigationStarted() {
        pending = nil
        waiting?.cancel()
        waiting = nil
        hide()
    }

    /// Esc, typing in the field, a click outside the menu and the field, an account chosen.
    func dismiss() {
        if shown != nil { dismissedOnPage = true }
        hide()
    }

    /// Another page (or the tab asleep): its fields are new ones, and its accounts are looked up again.
    func reset() {
        hide()
        lookup?.cancel()
        lookup = nil
        pending = nil
        pageOffers = nil
        dismissedOnPage = false
        appearedAt = nil
        waiting?.cancel()
        waiting = nil
    }

    /// Whether a click on the menu now is taken (`clickDelay`).
    var clickCounts: Bool {
        guard let armedAt, pointerMovedInside else { return false }
        return now().timeIntervalSince(armedAt) >= Self.clickDelay
    }

    func pointerMoved() {
        if armedAt != nil { pointerMovedInside = true }
    }

    func choose(_ match: Logins.Match) {
        guard shown != nil, clickCounts else { return }
        guard let origin = shown?.origin else { return }
        dismiss()
        if let fill { fill(match) } else { tab?.fillLogin(match, origin: origin) }
    }

    private func present(_ field: Int, at rect: CGRect, origin: Tab.Origin, offers: [Logins.Match]) {
        guard !offers.isEmpty, !dismissedOnPage, let tab, let webView = tab.webView, let window = webView.window, Self.showable(tab, webView) else {
            hide()
            return
        }
        if shown == nil {
            // Appearing (again): not sooner than `reshowInterval` after the last time on this page; asked sooner, it waits for it.
            if let last = appearedAt, now().timeIntervalSince(last) < Self.reshowInterval {
                pending = (field, rect, origin)
                if waiting == nil {
                    let wait = Self.reshowInterval - now().timeIntervalSince(last)
                    waiting = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(wait))
                        guard let self, !Task.isCancelled else { return }
                        self.waiting = nil
                        if let pending = self.pending, self.shown == nil {
                            self.pending = nil
                            self.fieldFocused(pending.field, at: pending.rect, document: pending.origin)
                        }
                    }
                }
                return
            }
            appearedAt = now()
            pending = nil
        }
        let fieldRect = Self.viewRect(rect, zoom: webView.pageZoom * webView.magnification, flipped: webView.isFlipped, height: webView.bounds.height)
        shown = Shown(field: field, origin: origin, matches: offers, fieldRect: fieldRect)
        let panel = self.panel ?? makePanel(in: window, matches: offers)
        place(panel, under: fieldRect, in: webView)
    }

    /// Starts the wait for a click over: the panel has just appeared, or moved, under wherever the pointer is.
    private func arm(at frame: CGRect) {
        armedAt = now()
        armedFrame = frame
        pointerMovedInside = false
    }

    /// A rect the page gave in CSS pixels, in the web view's points: scaled by its zoom and pinch, and turned over when the view isn't flipped.
    nonisolated static func viewRect(_ css: CGRect, zoom: CGFloat, flipped: Bool, height: CGFloat) -> CGRect {
        let rect = CGRect(x: css.minX * zoom, y: css.minY * zoom, width: css.width * zoom, height: css.height * zoom)
        return flipped ? rect : CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Where the panel goes on screen: the list's top left just under the field's bottom left, or over the field when there is no room
    /// under it, and kept inside `bounds` (the page's part of the window). `size` includes the room for the shadow.
    nonisolated static func panelFrame(field: CGRect, size: CGSize, bounds: CGRect) -> CGRect {
        let gap = Metrics.rowGap, room = shadowRoom
        let width = size.width - 2 * room, height = size.height - 2 * room
        var y = field.minY - gap - height
        if y < bounds.minY, field.maxY + gap + height <= bounds.maxY { y = field.maxY + gap }
        let x = max(min(field.minX, bounds.maxX - width), bounds.minX)
        y = max(min(y, bounds.maxY - height), bounds.minY)
        return CGRect(x: x - room, y: y - room, width: size.width, height: size.height)
    }

    private func place(_ panel: NSPanel, under fieldRect: CGRect, in webView: WKWebView) {
        guard let window = webView.window, let content = panel.contentView else { return }
        let page = window.convertToScreen(webView.convert(webView.bounds, to: nil)).intersection(window.frame)
        let onScreen = window.convertToScreen(webView.convert(fieldRect, to: nil))
        let frame = Self.panelFrame(field: onScreen, size: content.fittingSize, bounds: page)
        panel.setFrame(frame, display: true)
        // A field scrolled out of the page's view has no menu showing, until it is back; coming back, or moving far, is appearing anew.
        let inView = webView.bounds.intersects(fieldRect)
        panel.alphaValue = inView ? 1 : 0
        panel.ignoresMouseEvents = !inView
        guard inView else {
            armedAt = nil
            armedFrame = nil
            return
        }
        if let armedFrame, hypot(frame.minX - armedFrame.minX, frame.minY - armedFrame.minY) <= Self.moveTolerance { return }
        arm(at: frame)
    }

    private func makePanel(in window: NSWindow, matches: [Logins.Match]) -> NSPanel {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.setAccessibilityLabel(String(localized: "Fill in saved login"))
        let hosting = Hosting(rootView: LoginMenuList(matches: matches, width: 200) { [weak self] in self?.choose($0) })
        hosting.onPointer = { [weak self] in self?.pointerMoved() }
        panel.contentView = hosting
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        // Another tab shown (by the user or the AI): this page is no longer the one looked at.
        browserWatch = tab?.browser?.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let tab = self.tab, let webView = tab.webView, self.shown != nil, !Self.showable(tab, webView) else { return }
                self.hide()
            }
        }
        return panel
    }

    /// What a key or a click while the menu is up does to it. Every event goes on to the page, Esc too: the page sees what it would
    /// have seen without a menu, so it can't tell from a key that never came that one (and so a saved login) was there.
    func handle(_ event: NSEvent) {
        guard let shown, event.window !== panel else { return }
        if event.type == .keyDown {
            // Tab moves to the next field, which may be offered the menu in its turn; anything else is typing, or Esc.
            if event.keyCode == 48 { hide() } else { dismiss() }
            return
        }
        // A click in the field itself keeps it.
        if let webView = tab?.webView, event.window === webView.window, shown.fieldRect.contains(webView.convert(event.locationInWindow, from: nil)) { return }
        dismiss()
    }

    private func hide() {
        shown = nil
        armedAt = nil
        armedFrame = nil
        pointerMovedInside = false
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        browserWatch = nil
    }

    /// Never key and never main: the page's field keeps the keyboard while the menu is up.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Takes the first click though its window isn't key (it never is), and says when the pointer moves inside it.
    final class Hosting: NSHostingView<LoginMenuList> {
        var onPointer: (() -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self && area.userInfo?["pointer"] != nil { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: ["pointer": true]))
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            onPointer?()
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            onPointer?()
        }
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
