import WebKit

/// Sites the user keeps translating: their next pages are translated as they open, and so is the text a translated page adds.
extension Tab {
    /// How long a kept site's page is given to draw its text before its language is looked at once more.
    nonisolated(unsafe) static var languageRetryDelay = Duration.milliseconds(1500)

    /// The page's site is one the user keeps translating, and this is a window that may.
    var keepsTranslating: Bool { !isPrivate && Preferences.shared.keepsTranslating(webView?.url?.host()) }

    /// Whether a page that has just been found foreign is translated without being asked: its site is kept, the window is not private
    /// and nobody has translated it (or shown the original) since it opened.
    nonisolated static func translatesByItself(host: String?, kept: [String], isPrivate: Bool, translation: Translation) -> Bool {
        !isPrivate && translation == .original && Preferences.matchesExactly(host, kept)
    }

    /// Reads the page's language once it has loaded, and translates the page on the spot if its site is kept.
    func checkLanguage(in webView: WKWebView) {
        let page = page
        Task {
            var language = await PageTranslator.foreignLanguage(of: webView)
            if self.page == page && translation == .original { foreignLanguage = language }
            // Comic sites often draw their text late: a kept site's page is looked at once more.
            if language == nil, keepsTranslating {
                try? await Task.sleep(for: Self.languageRetryDelay)
                guard self.page == page, self.webView === webView, translation == .original else { return }
                language = await PageTranslator.foreignLanguage(of: webView)
                if self.page == page && translation == .original { foreignLanguage = language }
            }
            guard let language, self.page == page, self.webView === webView,
                  Self.translatesByItself(host: webView.url?.host(), kept: Preferences.shared.translatedHosts, isPrivate: isPrivate, translation: translation)
            else { return }
            startTranslation(from: language, automatically: true)
        }
    }

    /// The site's switch, in the site settings and on the Translate button. Never saved from a private window. Turned on, a foreign page
    /// that is not translated starts being translated, and one that is begins to be followed; turned off, the page is left as it is
    /// and the following stops.
    func setKeepsTranslating(_ on: Bool, host: String) {
        guard !isPrivate else { return }
        let prefs = Preferences.shared
        prefs.translatedHosts = on ? Preferences.adding(host, to: prefs.translatedHosts) : Preferences.removingExactly(host, from: prefs.translatedHosts)
        guard on else {
            following?.cancel()
            following = nil
            return
        }
        guard keepsTranslating, let language = foreignLanguage else { return }
        if translation == .original {
            startTranslation(from: language, automatically: true)
        } else if translation == .translated {
            followTranslation(from: language)
        }
    }

    /// Watches the translated page for text it adds or changes, and translates that as it comes, for as long as the page is shown, is
    /// translated, and its site is kept. Not for a page whose allowance for Claude is used up. The task holds the tab and its view weakly.
    func followTranslation(from source: Locale.Language) {
        guard keepsTranslating, !translationBudget.exhausted, let webView else { return }
        following?.cancel()
        let page = page
        following = Task { [weak self, weak webView] in
            _ = try? await webView?.callAsyncJavaScript(PageTranslator.observeScript, contentWorld: .defaultClient)
            var state = PageTranslator.FollowUpState()
            while !Task.isCancelled {
                try? await Task.sleep(for: PageTranslator.pollInterval)
                guard !Task.isCancelled, let self, let webView, await self.followUp(webView, from: source, page: page, state: &state) else { return }
            }
        }
    }

    /// A run with Claude: what it may send, and what it counts against.
    struct ClaudeRun {
        let site: String?
        let allowance: ClaudeTranslation.Budget
        /// The site's window, not the page's allowance, is what is nearer to running out.
        let byWindow: Bool
        let epoch: Int
        let token: Int
    }

    /// Starts a run with Claude: the button's text says it is sending, and the run has the page's allowance, which for one nobody asked
    /// for is no more than the site has left in its window.
    func beginClaudeRun(automatically: Bool) -> ClaudeRun {
        claudeRuns += 1
        translatesWithClaude = true
        let site = AutomaticClaude.site(of: webView?.url?.host())
        var allowance = translationBudget
        var byWindow = false
        if automatically, let site {
            let shared = AutomaticClaude.shared
            let left = shared.window.remaining(for: site, at: shared.now())
            (allowance, byWindow) = translationBudget.narrowed(toCharacters: left.characters, batches: left.batches)
        }
        return ClaudeRun(site: site, allowance: allowance, byWindow: byWindow, epoch: budgetEpoch, token: claudeRuns)
    }

    /// Ends a run with Claude, however it ended: what it sent counts against the site's window (also when the user pressed the button),
    /// and against the page's allowance if that is still the one it began with. It says Claude is no longer sent text only if it is the
    /// latest run.
    func endClaudeRun(_ run: ClaudeRun, spent budget: ClaudeTranslation.Budget) {
        let used = budget.spent(since: run.allowance)
        if let site = run.site {
            let shared = AutomaticClaude.shared
            shared.window.record(characters: used.characters, batches: used.batches, for: site, at: shared.now())
        }
        if budgetEpoch == run.epoch {
            translationBudget.characters += used.characters
            translationBudget.batches += used.batches
            if budget.exhausted && !run.byWindow { translationBudget.exhausted = true }
        }
        if claudeRuns == run.token { translatesWithClaude = false }
    }

    /// The site's window for Claude has nothing left: nothing nobody asked for goes there until it has.
    func claudeWindowIsUsedUp() -> Bool {
        guard let site = AutomaticClaude.site(of: webView?.url?.host()) else { return false }
        let shared = AutomaticClaude.shared
        return shared.window.isUsedUp(site, at: shared.now())
    }

    /// Says that translation with Claude is paused on this site, once in each window.
    func sayPaused() {
        guard let site = AutomaticClaude.site(of: webView?.url?.host()) else { return }
        let shared = AutomaticClaude.shared
        if shared.window.tellsPaused(site, at: shared.now()) { browser?.flashStatus(PageTranslator.pausedMessage) }
    }

    /// One look at the page: when it has changed and been still for a moment, its fresh text is translated. Whether to go on looking.
    private func followUp(_ webView: WKWebView, from source: Locale.Language, page: Int, state: inout PageTranslator.FollowUpState) async -> Bool {
        let current = { [weak self, weak webView] in
            guard let self, let webView else { return false }
            return self.page == page && self.webView === webView && !Task.isCancelled && self.translation == .translated && self.keepsTranslating
        }
        guard current() else { return false }
        // Nothing is looked at, or sent, from a tab nobody is looking at: it is picked up when the tab is shown.
        guard browser?.isShown(self) == true else { return true }
        guard let quiet = try? await webView.callAsyncJavaScript(PageTranslator.pollScript, contentWorld: .defaultClient) as? Double, current() else { return false }
        guard quiet >= PageTranslator.quietMilliseconds else { return true }
        // Where the page goes is asked afresh each time: a setting, a private window or a profile no longer shown changes it.
        let route = translationRoute()
        if case .refused(let refusal) = route {
            say(state.say(PageTranslator.statusMessage(for: refusal)))
            return false
        }
        var outcome: PageTranslator.Outcome
        if case .claude(let model) = route, !sensitiveSeen {
            if claudeWindowIsUsedUp() {
                sayPaused()
                return false
            }
            let run = beginClaudeRun(automatically: true)
            let claude = await PageTranslator.translateWithClaude(webView, model: model, within: run.allowance, collecting: PageTranslator.claudeFollowScript,
                                                                  while: current, permitted: {
                if case .claude = self.translationRoute() { return true }
                return false
            })
            endClaudeRun(run, spent: claude.budget)
            guard current() else { return false }
            outcome = claude.outcome
            if outcome == .sensitivePage {
                // As on the first pass: a page with a password or payment field is not sent, and is translated on this Mac if that can.
                sensitiveSeen = true
                if PageTranslator.onDeviceAvailable {
                    say(state.say(String(localized: "This page has a password or payment field, so it is translated on this Mac and not sent to Claude.")))
                    outcome = await PageTranslator.translate(webView, from: source, collecting: PageTranslator.followScript, while: current)
                }
            }
            if claude.budget.exhausted {
                if run.byWindow { sayPaused() } else { say(state.say(PageTranslator.statusMessage(for: .translatedPartly))) }
                return false
            }
        } else {
            outcome = await PageTranslator.translate(webView, from: source, collecting: PageTranslator.followScript, while: current)
        }
        guard current() else { return false }
        say(state.message(for: outcome))
        return PageTranslator.followsOn(after: outcome)
    }

    private func say(_ message: String?) {
        if let message { browser?.flashStatus(message) }
    }
}
