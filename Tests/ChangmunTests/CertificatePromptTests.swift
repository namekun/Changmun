import AppKit
import Testing
@testable import Changmun

extension SharedAgentState {
    /// What the window does with a challenge that waits for the user to choose a certificate, without a sheet: the queue is what is
    /// looked at, and the window has none to put one on.
    @MainActor @Suite(.serialized)
    struct CertificatePromptTests {
        private func browser() -> Browser {
            let browser = Browser()
            browser.focused()
            return browser
        }

        private func prompt(agent: Bool = false) -> ClientCertificatePrompter.Prompt {
            .init(host: "mtls.example", candidates: [], agentDriven: agent, domain: nil)
        }

        /// Asks for `tab` and returns once the challenge is queued; the task ends when the challenge is answered.
        private func ask(_ b: Browser, _ tab: Tab, agent: Bool = false, key: String = "site") async -> Task<ClientCertificates.Candidate?, Never> {
            let task = Task { await b.certificatePrompter.ask(prompt(agent: agent), queueKey: key, site: key, tab: tab) }
            #expect(await waitUntil { tab.waitingForCertificate })
            return task
        }

        // MARK: Typing

        @Test func theSheetWaitsForTheUserToStopTyping() {
            let now = Date(timeIntervalSince1970: 3000)
            typealias Prompter = ClientCertificatePrompter
            #expect(Prompter.typingHold(lastKeyDown: nil, now: now) == 0, "no key seen, no wait")
            #expect(Prompter.typingHold(lastKeyDown: now.addingTimeInterval(-5), now: now) == 0)
            #expect(Prompter.typingHold(lastKeyDown: now.addingTimeInterval(-Prompter.typingQuiet), now: now) == 0)
            let wait = Prompter.typingHold(lastKeyDown: now.addingTimeInterval(-0.1), now: now)
            #expect(abs(wait - (Prompter.typingQuiet - 0.1)) < 1e-6, "the rest of the quiet time")
            #expect(Prompter.typingHold(lastKeyDown: now, now: now) == Prompter.typingQuiet)
            #expect(Prompter.typingHold(lastKeyDown: now.addingTimeInterval(2), now: now) == Prompter.typingQuiet, "a clock that stepped back waits no more than the quiet time")
            #expect(Prompter.typingQuiet >= 0.5)
        }

        // MARK: Which tab is waiting

        @Test func aTabWaitingForACertificateSaysSoUntilItIsAnswered() async {
            let b = browser()
            defer { b.windowClosed() }
            _ = b.openTab(url: nil)
            let background = b.openTab(url: nil, activate: false), other = b.openTab(url: nil, activate: false)
            let task = await ask(b, background)
            #expect(!other.waitingForCertificate, "only the tab that was asked")
            b.certificatePrompter.forget(background)
            #expect(await task.value == nil)
            #expect(!background.waitingForCertificate)
        }

        @Test func stoppingTheLoadForgetsTheChallengeOfThatTab() async throws {
            let b = browser()
            defer { b.windowClosed() }
            _ = b.openTab(url: nil)
            let tab = b.openTab(url: nil, activate: false), other = b.openTab(url: nil, activate: false)
            let view = tab.wake()
            _ = other.wake()
            let stopped = await ask(b, tab, key: "one"), kept = await ask(b, other, key: "two")
            view.stopLoading()
            #expect(await stopped.value == nil, "the challenge is answered with nothing")
            #expect(!tab.waitingForCertificate && other.waitingForCertificate, "the other tab's challenge is not touched")
            b.certificatePrompter.forget(other)
            #expect(await kept.value == nil)
        }

        // MARK: When the sheet is looked for

        @Test func theSheetIsLookedForWhenTheWindowCanShowItAgain() async {
            let b = browser()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
            b.window = window
            defer { b.windowClosed() }
            let prompter = b.certificatePrompter
            let center = NotificationCenter.default
            for name in [NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
                let before = prompter.showRequests
                center.post(name: name, object: window)
                #expect(prompter.showRequests == before + 1, "\(name.rawValue)")
                center.post(name: name, object: NSWindow())
                #expect(prompter.showRequests == before + 1, "another window's \(name.rawValue) is not this window's")
            }
            for name in [NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification] {
                let before = prompter.showRequests
                center.post(name: name, object: NSApp)
                #expect(prompter.showRequests == before + 1, "\(name.rawValue)")
            }
        }

        @Test func aChangeInTheWindowLooksForTheSheetOfAWaitingTab() async {
            let b = browser()
            defer { b.windowClosed() }
            _ = b.openTab(url: nil)
            let waiting = b.openTab(url: nil, activate: false)
            let task = await ask(b, waiting)
            let before = b.certificatePrompter.showRequests
            b.spaceDirection = 1
            b.objectWillChange.send()   // a split opened, the tab shown changed, ...
            #expect(await waitUntil { b.certificatePrompter.showRequests > before })
            b.certificatePrompter.forget(waiting)
            _ = await task.value
        }

        @Test func aPrompterNobodyHoldsIsReleasedWithItsObservers() async {
            let b = browser()
            defer { b.windowClosed() }
            weak var gone: ClientCertificatePrompter?
            do {
                let prompter = ClientCertificatePrompter(browser: b)
                gone = prompter
            }
            #expect(await waitUntil { gone == nil }, "nothing keeps it alive")
        }

        // MARK: The AI's line

        @Test func theAIsPanelSaysItIsWaitingForACertificateAndGoesBackToWhatItWasDoing() async {
            let b = browser()
            let chat = ChatStore.shared
            chat.step = nil
            AgentActivity.shared.runStarted()
            defer { AgentActivity.shared.runEnded(); chat.step = nil; b.windowClosed() }
            _ = b.openTab(url: nil)
            let tab = b.openTab(url: nil, activate: false)
            AgentActivity.shared.step("Opening mtls.example", caller: ChatStore.caller)
            let task = await ask(b, tab, agent: true)
            #expect(chat.step == String(localized: "Waiting for you to choose a certificate"))
            b.certificatePrompter.forget(tab)
            _ = await task.value
            #expect(chat.step == "Opening mtls.example", "the step it was on")
        }

        @Test func aChallengeOfTheUsersOwnLeavesTheAIsLineAlone() async {
            let b = browser()
            let chat = ChatStore.shared
            chat.step = nil
            AgentActivity.shared.runStarted()
            defer { AgentActivity.shared.runEnded(); chat.step = nil; b.windowClosed() }
            _ = b.openTab(url: nil)
            let tab = b.openTab(url: nil, activate: false)
            AgentActivity.shared.step("Reading github.com", caller: ChatStore.caller)
            let task = await ask(b, tab)
            #expect(chat.step == "Reading github.com")
            b.certificatePrompter.forget(tab)
            _ = await task.value
        }
    }
}
