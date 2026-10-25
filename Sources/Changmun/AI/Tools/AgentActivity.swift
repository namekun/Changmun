import Foundation

/// What the AI is doing now: the line the panel shows, the tabs it is using (which must keep running while the user
/// looks at another), and the stop button's reach into a wait or an approval that is under way.
@MainActor
final class AgentActivity: ObservableObject {
    static let shared = AgentActivity()
    /// A tab used by another caller than the panel (which says when its run ends) counts as in use for this long.
    static let lease: TimeInterval = 90
    /// So many tabs at most are kept drawing behind the page shown; the rest of those in use are only kept awake.
    static let maxHeld = 3

    /// The tabs in use, the most recently used first. The view that keeps them leaves out the page in front and the ones shown
    /// elsewhere and holds the first `maxHeld` of the rest, so a page in use that is in front doesn't take a place from another.
    @Published private(set) var held: [Int] = []
    private var stops: [String: Int] = [:]
    /// Per tab and caller, when the tab was last used.
    private var uses: [Int: [String: Date]] = [:]
    private var panelRun: Date?
    private var expiry: Task<Void, Never>?

    /// Counts a caller's stops: what began before one ends at it.
    func stopCount(for caller: String) -> Int {
        stops[caller] ?? 0
    }

    /// A caller that is gone (its bridge process ended) is not kept in mind.
    func forget(caller: String) {
        stops[caller] = nil
    }

    func use(_ tab: Tab, caller: String) {
        uses[tab.id, default: [:]][caller] = Date()
        refresh()
        scheduleExpiry()
    }

    private func valid(_ caller: String, at date: Date) -> Bool {
        if caller == ChatStore.caller { return panelRun.map { date >= $0 } ?? false }
        return Date().timeIntervalSince(date) < Self.lease
    }

    func holds(_ tab: Tab) -> Bool {
        uses[tab.id]?.contains { valid($0.key, at: $0.value) } ?? false
    }

    func runStarted() {
        panelRun = Date()
    }

    func runEnded() {
        panelRun = nil
        refresh()
    }

    /// Drops what is no longer in use, and works out which tabs are kept drawing.
    private func refresh() {
        for (id, callers) in uses {
            let live = callers.filter { valid($0.key, at: $0.value) }
            uses[id] = live.isEmpty ? nil : live
        }
        let newest = uses.sorted { ($0.value.values.max() ?? .distantPast) > ($1.value.values.max() ?? .distantPast) }.map(\.key)
        let now = newest.filter { ToolCatalog.findTab($0) != nil }
        if now != held { held = now }
    }

    /// A tab in use got another page (it woke up, or went to sleep): the view that holds it behind the page in front takes the new one.
    func pageChanged(_ tab: Tab) {
        // Not within the update of a view that woke the tab.
        if held.contains(tab.id) { DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() } }
    }

    /// One timer for all the leases: it wakes when the first one runs out.
    private func scheduleExpiry() {
        expiry?.cancel()
        let soonest = uses.values.flatMap { $0.filter { $0.key != ChatStore.caller }.values }.min()
        guard let soonest else { return }
        let wait = max(0, soonest.addingTimeInterval(Self.lease).timeIntervalSinceNow) + 0.5
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.refresh()
            self?.scheduleExpiry()
        }
    }

    /// The stop button (and a new chat, and the end of the AI's process): what the caller has under way ends, a question
    /// waiting for the user's answer is withdrawn as no, the marks the AI drew come off the pages, and the line goes.
    func cancel(caller: String = ChatStore.caller) {
        stops[caller, default: 0] += 1
        Approvals.cancelPending(caller: caller)
        SignIn.cancelConfirmation(caller: caller)
        for (id, callers) in uses where callers[caller] != nil {
            guard let tab = ToolCatalog.findTab(id), let webView = tab.webView else { continue }
            for frame in [nil] + tab.agent.frames.known.map({ Optional($0.frame) }) {
                webView.appScript(PageScripts.clearMarks, in: frame)
            }
        }
        if caller == ChatStore.caller {
            ChatStore.shared.step = nil
            runEnded()
        }
    }

    /// Tells the panel what a tool call from it is doing, while one of its runs lasts. The words the app says are always shown; the
    /// title the AI gave the step comes after them as a second label (`titled`), except where the user decides on what the app says
    /// (signing in, what can't be undone): there the AI's words are left out of the line and the step's chip.
    func step(_ text: String?, caller: String, titled: Bool = true) {
        guard caller == ChatStore.caller, panelRun != nil || text == nil else { return }
        if !titled { ChatStore.shared.hideTitle(ToolCatalog.currentTitle) }
        ChatStore.shared.step = text.map { text in titled ? ToolCatalog.currentTitle.map { text + " · " + $0 } ?? text : text }
    }
}
