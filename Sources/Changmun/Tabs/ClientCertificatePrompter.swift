import AppKit
import Combine
import SecurityInterface

/// Asks the user which certificate to show a site, in the system's own chooser as a sheet on the window of the tab that was
/// challenged. One window has one sheet at a time; a tab nobody is looking at is asked when it is shown.
@MainActor
final class ClientCertificatePrompter {
    struct Prompt {
        let host: String
        let candidates: [ClientCertificates.Candidate]
        let agentDriven: Bool
        /// What the panel files the choice under (an identity preference in the user's keychain), or nil to keep nothing there.
        let domain: String?
    }

    private weak var browser: Browser?
    private var queue = CertificatePromptQueue<CheckedContinuation<ClientCertificates.Candidate?, Never>, Prompt>()
    /// What the user chose in this window, which is kept as long as the window is (also in a private one, which keeps nothing else).
    private(set) var remembered = RememberedChoices()
    private var shown: (panel: SFChooseIdentityPanel, delegate: SheetEnd)?
    /// The sheet on screen is being closed because the tab it was for went away: its end is not an answer to anyone.
    private var sheetEnding = false
    /// Tests only: how often a sheet was looked for.
    private(set) var showRequests = 0
    private let observations = Observations()
    private var browserWatch: AnyCancellable?

    /// Notifications that remove themselves when the prompter goes.
    private final class Observations {
        var tokens: [NSObjectProtocol] = []
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    /// A challenge that came while the window was hidden, minimized or behind another app is asked when the window can show the sheet,
    /// and one for a tab that is shown by a change in the window (the tab switched, a split opened) when that has happened.
    init(browser: Browser) {
        self.browser = browser
        let center = NotificationCenter.default
        for name in [NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            observations.tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if let self, let window = note.object as? NSWindow, window === self.browser?.window { self.show() }
                }
            })
        }
        for name in [NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification] {
            observations.tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.show() }
            })
        }
        // Published before the change is made: looked at once it has been.
        browserWatch = browser.objectWillChange.sink { [weak self] in
            guard let self, !self.queue.entries.isEmpty else { return }
            Task { @MainActor [weak self] in self?.show() }
        }
    }

    /// Waits for the user's choice among `candidates`; nil when they cancel, or the tab goes away first. `queueKey` is what challenges
    /// share one answer by (see ClientCertificates.queueKey), `site` what the choice is remembered for.
    func ask(_ prompt: Prompt, queueKey: String, site: String, tab: Tab) async -> ClientCertificates.Candidate? {
        // The AI's panel says what the page is waiting for, as long as nothing else has taken the line.
        let waiting = String(localized: "Waiting for you to choose a certificate")
        let before = ChatStore.shared.step
        if prompt.agentDriven { AgentActivity.shared.step(waiting, caller: ChatStore.caller, titled: false) }
        let choice = await withCheckedContinuation { continuation in
            queue.add(key: queueKey, tab: tab.id, info: prompt, waiter: continuation)
            refreshWaiting()
            show()
        }
        if prompt.agentDriven, ChatStore.shared.step == waiting { ChatStore.shared.step = before }
        remembered.remember(choice, forSite: site, agentDriven: prompt.agentDriven)
        return choice
    }

    /// Shows the next sheet, if none is up and a tab waiting for one is on screen. Called again when another tab is shown.
    func show() {
        showRequests += 1
        guard shown == nil, let browser, let window = browser.window, window.isVisible, !window.isMiniaturized,
              let entry = queue.next(isShown: { id in browser.tab(id).map { browser.isShown($0) || browser.peek === $0 } ?? false }) else { return }
        queue.start(entry.key)
        let panel = SFChooseIdentityPanel()
        // With a domain the panel files the choice as an identity preference in the user's keychain (as Safari's does) when they choose.
        // It has no way to say no, so no domain is given where nothing should be kept (see ClientCertificates.domainToRemember).
        if let domain = entry.info.domain {
            panel.setDomain(domain)
            panel.setInformativeText(String(localized: "This choice will be remembered for this site. You can remove it in Keychain Access."))
        } else if entry.info.agentDriven {
            panel.setInformativeText(String(localized: "The AI is using this tab. Choose a certificate only if you want it to identify you to this site."))
        }
        let delegate = SheetEnd { [weak self, weak panel] code in
            guard let self, let panel else { return }
            if self.sheetEnding {
                self.sheetEnding = false
                self.shown = nil
                self.show()
                return
            }
            var choice: ClientCertificates.Candidate?
            if code == NSApplication.ModalResponse.OK.rawValue, let chosen = panel.identity()?.takeUnretainedValue() {
                choice = entry.info.candidates.first { $0.identity.map { CFEqual($0, chosen) } == true }
            }
            self.answer(entry.key, with: choice)
        }
        shown = (panel, delegate)
        panel.beginSheet(for: window, modalDelegate: delegate, didEnd: #selector(SheetEnd.sheetDidEnd(_:returnCode:contextInfo:)), contextInfo: nil,
                         identities: entry.info.candidates.compactMap(\.identity), message: String(localized: "\(entry.info.host) wants a certificate to identify you."))
    }

    private func answer(_ key: String, with choice: ClientCertificates.Candidate?) {
        shown = nil
        for waiter in queue.finish(key) { waiter.resume(returning: choice) }
        refreshWaiting()
        show()
    }

    /// Each tab says whether a challenge of its own is waiting for the user.
    private func refreshWaiting() {
        for tab in browser?.tabs ?? [] {
            let waiting = queue.isWaiting(tab: tab.id)
            if tab.waitingForCertificate != waiting { tab.waitingForCertificate = waiting }
        }
    }

    /// A tab went away or stopped loading: what it waited for is answered with nothing, and the sheet closes if it was the only one waiting.
    func forget(_ tab: Tab) {
        let dropped = queue.drop(tab: tab.id)
        for waiter in dropped.released { waiter.resume(returning: nil) }
        refreshWaiting()
        tab.waitingForCertificate = false
        if dropped.emptiedActive, let panel = shown?.panel, let window = browser?.window {
            sheetEnding = true
            window.endSheet(panel, returnCode: .cancel)
        }
    }

    /// AppKit calls a selector when the sheet ends.
    @MainActor final class SheetEnd: NSObject {
        private let finished: @MainActor (Int) -> Void
        init(_ finished: @escaping @MainActor (Int) -> Void) { self.finished = finished }
        @objc func sheetDidEnd(_ sheet: NSWindow, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) { finished(returnCode) }
    }
}
