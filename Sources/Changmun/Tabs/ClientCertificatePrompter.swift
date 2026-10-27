import AppKit
import SecurityInterface

/// Asks the user which certificate to show a site, in the system's own chooser as a sheet on the window of the tab that was
/// challenged. One window has one sheet at a time; a tab nobody is looking at is asked when it is shown.
@MainActor
final class ClientCertificatePrompter {
    struct Prompt {
        let host: String
        let candidates: [ClientCertificates.Candidate]
        let agentDriven: Bool
    }

    private weak var browser: Browser?
    private var queue = CertificatePromptQueue<CheckedContinuation<ClientCertificates.Candidate?, Never>, Prompt>()
    /// What the user chose for a site in this window, which lasts as long as the window does (it is never written to the keychain).
    private(set) var remembered: [String: ClientCertificates.Candidate] = [:]
    private var shown: (panel: SFChooseIdentityPanel, delegate: SheetEnd)?

    init(browser: Browser) {
        self.browser = browser
    }

    /// Waits for the user's choice among `candidates` for the site `key` stands for; nil when they cancel, or the tab goes away first.
    func ask(_ prompt: Prompt, key: String, tab: Tab) async -> ClientCertificates.Candidate? {
        let choice = await withCheckedContinuation { continuation in
            queue.add(key: key, tab: tab.id, info: prompt, waiter: continuation)
            show()
        }
        // The choice stands for the site until the window closes; the AI's own page doesn't use it (see ClientCertificates.plan).
        if let choice { remembered[key] = choice }
        return choice
    }

    /// Shows the next sheet, if none is up and a tab waiting for one is on screen. Called again when another tab is shown.
    func show() {
        guard shown == nil, let browser, let window = browser.window, window.isVisible, !window.isMiniaturized,
              let entry = queue.next(isShown: { id in browser.tab(id).map { browser.isShown($0) || browser.peek === $0 } ?? false }) else { return }
        queue.start(entry.key)
        let panel = SFChooseIdentityPanel()
        // The domain is left unset on purpose: the panel files the choice as an identity preference of the user's when it has one, with no
        // way to say no, so choosing is all this does.
        if entry.info.agentDriven { panel.setInformativeText(String(localized: "The AI is using this tab. Choose a certificate only if you want it to identify you to this site.")) }
        let delegate = SheetEnd { [weak self, weak panel] code in
            guard let self, let panel else { return }
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
        show()
    }

    /// A tab went away: what it waited for is answered with nothing, and the sheet closes if it was the only one waiting.
    func forget(_ tab: Tab) {
        let dropped = queue.drop(tab: tab.id)
        for waiter in dropped.released { waiter.resume(returning: nil) }
        if dropped.emptiedActive, let panel = shown?.panel, let window = browser?.window { window.endSheet(panel, returnCode: .cancel) }
    }

    /// AppKit calls a selector when the sheet ends.
    @MainActor final class SheetEnd: NSObject {
        private let finished: @MainActor (Int) -> Void
        init(_ finished: @escaping @MainActor (Int) -> Void) { self.finished = finished }
        @objc func sheetDidEnd(_ sheet: NSWindow, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) { finished(returnCode) }
    }
}
