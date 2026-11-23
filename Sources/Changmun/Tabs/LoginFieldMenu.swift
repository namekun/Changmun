import AppKit
import Combine
import SwiftUI
import WebKit

/// The saved logins offered just under a sign-in field when it gets focus, as Safari and Chrome do; the key button in the address bar
/// stays as it was. The app draws the list in a panel of its own over the page, never in the page, so the page can't read which
/// accounts are saved. The panel never becomes key, so what the user types still goes to the field. Choosing an account fills it the
/// key button's way, Touch ID first when the setting asks for it.
///
/// As in Chrome, it is offered whenever the user focuses or clicks a sign-in field, and put away by anything else: the field losing
/// focus, a key, a click outside it and the field, an account chosen. Typing puts it away for that field while the field has text;
/// emptied, a click or a focus offers it again. After Esc or a click elsewhere only the user's own click on a field brings it back,
/// as a page can focus() a field whenever it likes. Nothing locks it for the page: it appears at most once a second, on focus at
/// most `focusShowsPerMinute` times a minute, and every appearance starts the click guard over.
@MainActor
final class LoginFieldMenu {
    /// A click counts only this long after the panel appeared where it is, and only once the pointer has come into it from outside: a
    /// page can focus a field, or move one, so that the panel comes up under a pointer that was about to click something else.
    static let clickDelay: TimeInterval = 0.4
    /// Appearances on focus a page gets in a minute; after that only the user's own click on a field brings the menu.
    static let focusShowsPerMinute = 5

    /// What brought a field's place: a focus or a click on it may show the menu; a move (a scroll, a resize) only takes it along.
    enum Reason: String {
        case focus, click, move
    }
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
    /// When the menu last appeared on this page: it appears again at most once in `reshowInterval`, later if asked sooner, so a page
    /// can't make it jump about with focus() and blur(), or by drawing its field anew. (Each appearance starts the click guard over.)
    private var appearedAt: Date?
    static let reshowInterval: TimeInterval = 1
    private var waiting: Task<Void, Never>?
    /// The accounts for this page once looked up, none included, so a scroll or another field doesn't look again.
    private var pageOffers: (origin: Tab.Origin, offers: [Logins.Match])?
    private var lookup: Task<Void, Never>?
    /// The field that has focus while the accounts are looked up, or while the menu waits to appear again.
    private var pending: (field: Int, rect: CGRect, origin: Tab.Origin, reason: Reason)?
    /// Put away with Esc or a click elsewhere: only the user's own click on a field brings it back (a page can focus() at will).
    private(set) var clickOnly = false
    /// The menu's appearances on this page in the last minute.
    private var appearances: [Date] = []
    /// When the panel last appeared or moved, and where it was then.
    private(set) var armedAt: Date?
    private var armedFrame: CGRect?
    /// The pointer has come into the panel from outside since then (not merely been there when it appeared).
    private(set) var pointerEntered = false
    /// The pointer was over the panel when it appeared or moved: it has to leave before coming in counts. Taken from where the
    /// pointer is, not from AppKit's tracking, which keeps thinking the pointer outside when the panel is moved under it.
    private var waitsForExit = false
    /// Where the pointer is on screen (tests put their own).
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
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

    /// Whether `view` and every view it is in are drawn: not hidden, and not made transparent (a page held behind another).
    static func isVisible(_ view: NSView) -> Bool {
        guard view.window != nil else { return false }
        var current: NSView? = view
        while let shown = current {
            if shown.isHidden || shown.alphaValue < 0.01 { return false }
            current = shown.superview
        }
        return true
    }

    /// A sign-in field has been focused or clicked, or has moved (`reason`): `rect` is where it is, in CSS pixels of what is on
    /// screen, and `document` the origin of the document it is in.
    func fieldFocused(_ field: Int, at rect: CGRect, document: Tab.Origin?, reason: Reason) {
        if reason == .move {
            if pending?.field == field { pending?.rect = rect }
            guard let shown, shown.field == field else { return }
        }
        if reason == .click { clickOnly = false }
        if reason == .focus, clickOnly { return }
        if let shown, shown.field != field { hide() }
        guard let tab, tab.webView != nil,
              let origin = Self.pageOrigin(document: document, committed: tab.committedURL, provisional: tab.isLoadingProvisionally, isUnverified: tab.isUnverified)
        else { return hide() }
        if let pageOffers, pageOffers.origin == origin {
            present(field, at: rect, origin: origin, offers: pageOffers.offers, reason: reason)
            return
        }
        pending = (field, rect, origin, reason)
        guard lookup == nil else { return }
        // A key meanwhile (Esc, typing) calls off the menu the lookup is for, so the events are watched from now.
        watchEvents()
        lookup = Task { [weak self] in
            let offers = await Tab.loginAccounts(origin.key)
            guard let self, !Task.isCancelled else { return }
            self.lookup = nil
            self.pageOffers = (origin, offers)
            if let pending = self.pending, pending.origin == origin {
                self.pending = nil
                self.present(pending.field, at: pending.rect, origin: origin, offers: offers, reason: pending.reason)
            }
            self.stopWatchingEvents()
        }
    }

    /// The field lost focus: the menu goes, but may come back for the next field.
    func fieldLeft(_ field: Int) {
        if pending?.field == field { pending = nil }
        if shown?.field == field { hide() }
    }

    /// The user typed into the field: it is theirs while it has text (the page doesn't offer it again until it is empty).
    func fieldTyped(_ field: Int) {
        fieldLeft(field)
    }

    /// A navigation began: the page on screen is on its way out, and offers nothing until the next one commits.
    func navigationStarted() {
        stopWaiting()
        hide()
    }

    /// Nothing is to appear later: no field is waiting for the menu.
    private func stopWaiting() {
        pending = nil
        waiting?.cancel()
        waiting = nil
        stopWatchingEvents()
    }

    /// Another page (or the tab asleep): its fields are new ones, and its accounts are looked up again.
    func reset() {
        hide()
        lookup?.cancel()
        lookup = nil
        pageOffers = nil
        appearedAt = nil
        appearances = []
        clickOnly = false
        stopWaiting()
    }

    /// Whether a click on the menu now is taken (`clickDelay`).
    var clickCounts: Bool {
        guard let armedAt, pointerEntered else { return false }
        return now().timeIntervalSince(armedAt) >= Self.clickDelay
    }

    func pointerDidEnter() {
        if armedAt != nil, !waitsForExit { pointerEntered = true }
    }

    func pointerDidExit() {
        waitsForExit = false
    }

    func choose(_ match: Logins.Match) {
        guard let shown, clickCounts else { return }
        hide()
        if let fill { fill(match) } else { tab?.fillLogin(match, origin: shown.origin, field: shown.field) }
    }

    private func present(_ field: Int, at rect: CGRect, origin: Tab.Origin, offers: [Logins.Match], reason: Reason) {
        guard !offers.isEmpty, let tab, let webView = tab.webView, let window = webView.window, Self.showable(tab, webView) else {
            hide()
            return
        }
        if shown == nil {
            // Appearing (again): not sooner than `reshowInterval` after the last time on this page; asked sooner, it waits for it.
            appearances.removeAll { now().timeIntervalSince($0) >= 60 }
            if reason == .focus, appearances.count >= Self.focusShowsPerMinute { return }
            if let last = appearedAt, now().timeIntervalSince(last) < Self.reshowInterval {
                pending = (field, rect, origin, reason)
                if waiting == nil {
                    let wait = Self.reshowInterval - now().timeIntervalSince(last)
                    // Esc or a key meanwhile calls it off, so the events are watched from now.
                    watchEvents()
                    waiting = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(wait))
                        guard let self, !Task.isCancelled else { return }
                        self.waiting = nil
                        if let pending = self.pending, self.shown == nil {
                            self.pending = nil
                            self.fieldFocused(pending.field, at: pending.rect, document: pending.origin, reason: pending.reason)
                        }
                        self.stopWatchingEvents()
                    }
                }
                return
            }
            appearedAt = now()
            appearances.append(now())
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
        pointerEntered = false
        // Where the window really is (the window server may have placed it otherwise than asked).
        waitsForExit = (panel?.frame ?? frame).contains(mouseLocation())
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
        panel.setAccessibilityLabel(String(localized: "Fill in saved login"))
        let hosting = Hosting(rootView: LoginMenuList(matches: matches, width: 200) { [weak self] in self?.choose($0) })
        hosting.onPointer = { [weak self] entered in if entered { self?.pointerDidEnter() } else { self?.pointerDidExit() } }
        panel.contentView = hosting
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        watchEvents()
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

    private func watchEvents() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    private func stopWatchingEvents() {
        guard panel == nil, waiting == nil, lookup == nil, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// What a key or a click while the menu is up, or waiting to come up (on the lookup of the accounts, or on `reshowInterval`), does
    /// to it. Any key puts it away (and calls off one waiting); Esc and a click outside the menu and the field also leave it to the user's own click on a field to come back, as
    /// a page can focus() a field whenever it likes. Every event goes on to the page, Esc too: the page sees what it would have seen
    /// without a menu, so it can't tell from a key that never came that one (and so a saved login) was there.
    func handle(_ event: NSEvent) {
        if let panel, event.window === panel { return }
        if event.type == .keyDown {
            guard shown != nil || pending != nil else { return }
            if event.keyCode == 53 { clickOnly = true }
        } else {
            // A click in the field itself keeps it. (With no menu up yet, the page says where the user pressed.)
            guard let shown else { return }
            if let webView = tab?.webView, event.window === webView.window,
               shown.fieldRect.contains(webView.convert(event.locationInWindow, from: nil)) { return }
            clickOnly = true
        }
        stopWaiting()
        hide()
    }

    private func hide() {
        shown = nil
        armedAt = nil
        armedFrame = nil
        pointerEntered = false
        waitsForExit = false
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        stopWatchingEvents()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        browserWatch = nil
    }

    /// Never key and never main: the page's field keeps the keyboard while the menu is up.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Takes the first click though its window isn't key (it never is), and says when the pointer comes into it.
    final class Hosting: NSHostingView<LoginMenuList> {
        /// True when the pointer comes in, false when it leaves.
        var onPointer: ((Bool) -> Void)?

        /// Without `.assumeInside`: a pointer already inside when the area is made (the panel came up under it) gets no mouseEntered
        /// until it has left and come back, so only a pointer that crossed into the panel arms a click.
        static let trackingOptions: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self && area.userInfo?["pointer"] != nil { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: Self.trackingOptions, owner: self, userInfo: ["pointer": true]))
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            onPointer?(true)
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            onPointer?(false)
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
