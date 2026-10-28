import AppKit
import Combine
import SecurityInterface

/// Asks the user which certificate to show a site, in the system's own chooser as a sheet on the window of the tab that was
/// challenged. One window has one sheet at a time; a tab nobody is looking at is asked when it is shown.
@MainActor
final class ClientCertificatePrompter {
    struct Prompt {
        let host: String
        let port: Int
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
    /// The window the panel put up on the browser's window as its sheet: it is not the panel itself, and ending the panel's does nothing.
    private var shownSheet: NSWindow?
    /// The sheet on screen is being closed because the tab it was for went away: its end is not an answer to anyone.
    private var sheetEnding = false
    /// Tests only: how often a sheet was looked for.
    private(set) var showRequests = 0
    private let observations = Observations()
    /// When the user last pressed a key in the window (a sheet that comes up under their typing would take it), and the wait for it to pass.
    private var lastKeyDown: Date?
    private var typingWait: Task<Void, Never>?
    private var browserWatch: AnyCancellable?

    /// Notifications that remove themselves when the prompter goes.
    private final class Observations {
        var tokens: [NSObjectProtocol] = []
        var keyMonitor: Any?
        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
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
        observations.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { if let self, event.window != nil, event.window === self.browser?.window { self.lastKeyDown = Date() } }
            return event
        }
        // Published before the change is made: looked at once it has been.
        browserWatch = browser.objectWillChange.sink { [weak self] in
            guard let self, !self.queue.entries.isEmpty else { return }
            Task { @MainActor [weak self] in self?.show() }
        }
    }

    /// How long after a key goes down in the window a sheet may not come up.
    static let typingQuiet: TimeInterval = 0.5

    /// How much longer a sheet must wait for the user's typing to be past (never more than `typingQuiet`).
    static func typingHold(lastKeyDown: Date?, now: Date) -> TimeInterval {
        guard let lastKeyDown else { return 0 }
        return max(0, min(typingQuiet, typingQuiet - now.timeIntervalSince(lastKeyDown)))
    }

    /// Waits for the user's choice among `candidates`; nil when they cancel, or the tab goes away first. `queueKey` is what challenges
    /// share one answer by (see ClientCertificates.queueKey), `site` what the choice is remembered for.
    func ask(_ prompt: Prompt, queueKey: String, site: String, tab: Tab) async -> ClientCertificates.Candidate? {
        // The test copy's test answers for the user: the chooser can't be clicked headlessly.
        if Headless.isTestCopy, let choice = ClientCertificateTestHook.choice {
            ClientCertificateTestHook.recordAsked(prompt.candidates.map(\.name))
            switch choice {
            case "cancel": return nil
            case "last": return prompt.candidates.last
            case "first": return prompt.candidates.first
            default: return prompt.candidates.first { $0.name == choice }
            }
        }
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
        // Not under the user's typing: the sheet takes the keys that come next (a Return would choose a certificate), so it waits for a pause.
        let hold = Self.typingHold(lastKeyDown: lastKeyDown, now: Date())
        if hold > 0 {
            if typingWait == nil {
                typingWait = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(hold))
                    self?.typingWait = nil
                    self?.show()
                }
            }
            return
        }
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
                self.shownSheet = nil
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
        let sheetBefore = window.attachedSheet
        defer { shownSheet = sheetBefore == nil ? window.attachedSheet : nil }
        panel.beginSheet(for: window, modalDelegate: delegate, didEnd: #selector(SheetEnd.sheetDidEnd(_:returnCode:contextInfo:)), contextInfo: nil,
                         identities: entry.info.candidates.compactMap(\.identity), message: String(localized: "\(entry.info.host) wants a certificate to identify you."))
    }

    private func answer(_ key: String, with choice: ClientCertificates.Candidate?) {
        shown = nil
        shownSheet = nil
        for waiter in queue.finish(key) { waiter.resume(returning: choice) }
        refreshWaiting()
        show()
    }

    /// Tests only (the test copy's `/client-cert`): whether a sheet is up on the window, and ending it as the user's OK or Cancel would.
    var sheetIsUp: Bool { Headless.isTestCopy && shown != nil && shownSheet != nil && browser?.window?.attachedSheet === shownSheet }

    func endSheetForTest(ok: Bool) {
        guard Headless.isTestCopy, let sheet = shownSheet, let window = browser?.window else { return }
        window.endSheet(sheet, returnCode: ok ? .OK : .cancel)
    }

    /// Each tab says whether a challenge of its own is waiting for the user.
    private func refreshWaiting() {
        for tab in browser?.tabs ?? [] {
            let waiting = queue.isWaiting(tab: tab.id)
            if tab.waitingForCertificate != waiting { tab.waitingForCertificate = waiting }
        }
    }

    /// A tab went away or stopped loading: what it waited for is answered with nothing, and the sheet closes if it was the only one waiting. A load that
    /// begins for the site of `site` keeps what its own challenge already asked: WebKit may deliver the challenge before it says the load began.
    func forget(_ tab: Tab, keepingSiteOf site: URL? = nil) {
        let host = site?.host()?.lowercased()
        let port = site.map { $0.port ?? 443 }
        let dropped = queue.drop(tab: tab.id) { info in host != nil && info.host.lowercased() == host && info.port == port }
        if !dropped.released.isEmpty { ClientCertificates.note("forget: \(dropped.released.count) waiting answers dropped", logging: browser?.isPrivate != true) }
        for waiter in dropped.released { waiter.resume(returning: nil) }
        refreshWaiting()
        tab.waitingForCertificate = queue.isWaiting(tab: tab.id)
        // The sheet that is up is the panel's own window; one that is not up yet (behind another sheet) cannot be ended, and its end finds nobody waiting.
        if dropped.emptiedActive, shown != nil, let sheet = shownSheet, let window = browser?.window {
            sheetEnding = true
            window.endSheet(sheet, returnCode: .cancel)
        }
    }

    /// AppKit calls a selector when the sheet ends.
    @MainActor final class SheetEnd: NSObject {
        private let finished: @MainActor (Int) -> Void
        init(_ finished: @escaping @MainActor (Int) -> Void) { self.finished = finished }
        @objc func sheetDidEnd(_ sheet: NSWindow, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) { finished(returnCode) }
    }
}
