import AppKit
import WebKit

extension Tab {
    // MARK: Popups

    /// A popup that was not opened: offered in a bar, or opened as a tab when the site it came from is one the user allows
    /// popups from. That site is the origin of the page (`pageSite`, as WebKit named it; the address of the tab when it
    /// isn't known) or, for a popup from a frame (`frame`), the frame's own: an ad's frame never borrows the permission of
    /// the page it sits in. An allowed site's tabs are few (`Browser.takeAllowedPopupSlot`); the ones beyond them are offered too.
    func popupBlocked(_ popup: URL, fromFrame frame: String? = nil, pageSite: String? = nil) {
        let site = (frame ?? pageSite ?? url?.host() ?? "").lowercased()
        let judged = site.isEmpty ? nil : site
        guard !isPrivate, Preferences.shared.allowsPopups(from: judged), let browser, browser.takeAllowedPopupSlot() else {
            popupRefused(popup, fromFrame: frame, pageSite: judged)
            return
        }
        browser.openTab(url: popup, activate: browser.isShown(self), after: self).openerID = id
    }

    /// A popup the app has just refused goes to the bar. The bar keeps the first one until it is closed, so that a frame can't swap
    /// the address (and the site "Always Allow" would allow) under a user who is about to press it; the others only add to its count.
    func popupRefused(_ popup: URL, fromFrame frame: String?, pageSite: String?) {
        let site = (frame ?? pageSite ?? "").lowercased()
        if blockedPopup == nil {
            blockedPopup = popup
            blockedPopupFrame = frame
            blockedPopupSite = site.isEmpty ? nil : site
            blockedPopupCount = 1
        } else {
            blockedPopupCount += 1
        }
    }

    /// Whether the site the bar would allow is not the one the page shows (a frame's, or the main frame's when the tab has
    /// moved on): the button then names it. It is the site that is granted that is compared, nothing else.
    var blockedPopupIsFromOtherSite: Bool {
        guard let site = blockedPopupSite else { return false }
        func bare(_ host: String?) -> String { (host ?? "").lowercased().replacingOccurrences(of: "www.", with: "", options: .anchored) }
        return bare(site) != bare(url?.host())
    }

    /// Opens the pop-up in the bar, and with `always` allows its site. `seen` is what the bar showed when the user pressed the
    /// button: if the bar has changed since (another page's, or another site's), nothing is opened or allowed on its word.
    func openBlockedPopup(always: Bool, seen: (popup: URL, site: String?)? = nil) {
        guard let popup = blockedPopup else { return }
        let site = blockedPopupSite
        if let seen, seen.popup != popup || (always && seen.site != site) { return }
        let empty = blockedPopupIsEmpty
        blockedPopup = nil
        if always, !isPrivate, let site { Preferences.shared.allowPopups(from: site) }
        if !empty { browser?.openTab(url: popup, after: self).openerID = id }
    }

    // MARK: Page source

    /// Opens the page's document, as it is now, as text in a new tab after this one. It is read in the app's own world, so the page's scripts can't
    /// answer in its place, and shown as our own page, which runs nothing of it.
    func viewSource() {
        guard let webView else { return }
        let title = String(localized: "Source of \(displayTitle)")
        webView.callAsyncJavaScript("return document.documentElement ? document.documentElement.outerHTML : ''", arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            Task { @MainActor in
                guard let self, let browser = self.browser, case .success(let value) = result, let source = value as? String else { return }
                browser.openTab(url: nil, after: self).wake().loadHTMLString(Self.sourcePage(source, title: title), baseURL: nil)
            }
        }
    }

    /// The source as plain text, wrapped, in the monospaced type of Reader Mode's code.
    nonisolated static func sourcePage(_ source: String, title: String) -> String {
        let escape = { (text: String) in
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>\(escape(title))</title>
        <body style="margin: 0"><pre style="margin: 0; padding: 16px; font: 13px/1.5 ui-monospace, Menlo, monospace; white-space: pre-wrap; overflow-wrap: anywhere">\(escape(source))</pre></body>
        """
    }

    // MARK: Reader Mode

    /// Shows the page's article over it as clean text, or takes it away again.
    func toggleReader() {
        guard let webView, webView.url?.scheme?.hasPrefix("http") == true else { return }
        let page = page
        Task {
            let state = await Reader.run(.toggle, in: webView)
            guard self.page == page else { return }
            if state == .none { browser?.flashStatus(String(localized: "No article to show in Reader Mode")) }
            isReading = state == .up
        }
    }

    /// Reads from the page whether it looks like an article and whether the article is up: a page that comes back from
    /// the back/forward cache keeps its article, whatever was reset on the way.
    func checkReader() async {
        guard let webView else { return }
        let page = page
        let state = await Reader.run(.check, in: webView)
        guard self.page == page else { return }
        isReadable = state == .up || state == .readable
        isReading = state == .up
    }

    /// The address changed without a new page (a single-page site moved on): the article is no longer this page's.
    func closeReader() {
        guard isReading, let webView else { return }
        isReading = false
        Task { _ = await Reader.run(.close, in: webView) }
    }

    // MARK: Translation

    /// Where this tab's page would be translated now (see `PageTranslator.route`); a tab the AI may not see never goes to Claude.
    func translationRoute() -> PageTranslator.Route {
        PageTranslator.route(engine: Preferences.shared.translationEngine, model: Preferences.shared.translationModel, claude: AIAvailability.detector(),
                             seenByAI: !isPrivate && browser?.isVisibleToAI(self) == true)
    }

    /// Translates the page into the user's language, or puts the original back (also stopping a translation under way).
    func toggleTranslation() {
        guard let webView else { return }
        if translation != .original {
            translating?.cancel()
            translating = nil
            following?.cancel()
            following = nil
            claudeRuns += 1
            translatesWithClaude = false
            translation = .original
            Announcer.announce(String(localized: "Showing the original page"))
            Task { await PageTranslator.showOriginal(webView) }
            return
        }
        startTranslation()
    }

    /// Translates the page, as the button does. `known` is the page's language where it has just been found; `automatically` is a
    /// translation nobody pressed the button for (a kept site's next page, the switch turned on), which has nothing to say when there is
    /// nothing to translate, says it is refused once, draws on the site's window for Claude, and goes on with what is left of the page's
    /// allowance: the button is the user's own act, and starts the page's allowance over.
    func startTranslation(from known: Locale.Language? = nil, automatically: Bool = false) {
        guard let webView, translation == .original else { return }
        // Which way the page goes is decided before anything starts: a refusal says why and changes nothing on the page.
        let route = translationRoute()
        if case .refused(let refusal) = route {
            if !automatically || !refusalSaid { browser?.flashStatus(PageTranslator.statusMessage(for: refusal)) }
            if automatically { refusalSaid = true }
            return
        }
        let usesClaude: Bool = { if case .claude = route { return !sensitiveSeen }; return false }()
        if automatically, usesClaude, claudeWindowIsUsedUp() {
            sayPaused()
            return
        }
        if !automatically {
            translationBudget = ClaudeTranslation.Budget()
            budgetEpoch += 1
        }
        translation = .translating
        let claudeRun = usesClaude ? beginClaudeRun(automatically: automatically) : nil
        let page = page
        let current = { [weak self] in self?.page == page && self?.webView === webView && !Task.isCancelled }
        translating = Task {
            var language = known
            if language == nil { language = await PageTranslator.foreignLanguage(of: webView) }
            guard let source = language else {
                guard current() else { return }
                translating = nil
                translatesWithClaude = false
                translation = .original
                if !automatically { browser?.flashStatus(String(localized: "No text in another language to translate")) }
                return
            }
            foreignLanguage = source
            let outcome: PageTranslator.Outcome
            var paused = false
            if case .claude(let model) = route, let run = claudeRun {
                // Asked again before every batch: the tab may stop being one that may go to Claude, or the setting may change, while it works.
                let claude = await PageTranslator.translateWithClaude(webView, model: model, within: run.allowance, collecting: PageTranslator.claudeCollectScript,
                                                                      plan: { self.planClaudeRun(run, for: $0) }, while: current, permitted: {
                    if case .claude = self.translationRoute() { return true }
                    return false
                })
                // What was sent counts, whether or not the work was stopped.
                endClaudeRun(run, spent: claude.budget)
                paused = run.byWindow && claude.budget.exhausted
                var result = claude.outcome
                if result == .sensitivePage, current() {
                    sensitiveSeen = true
                    translatesWithClaude = false
                    if PageTranslator.onDeviceAvailable {
                        browser?.flashStatus(String(localized: "This page has a password or payment field, so it is translated on this Mac and not sent to Claude."))
                        result = await PageTranslator.translate(webView, from: source, while: current)
                    }
                }
                outcome = result
            } else if case .claude = route {
                // A password or payment field was on this page before: it is not sent, field or no field now.
                outcome = PageTranslator.onDeviceAvailable ? await PageTranslator.translate(webView, from: source, while: current) : .sensitivePage
            } else {
                outcome = await PageTranslator.translate(webView, from: source, while: current)
            }
            guard current() else { return }
            translating = nil
            translatesWithClaude = false
            translation = outcome == .translated || outcome == .translatedPartly ? .translated : .original
            if paused {
                sayPaused()
            } else if let message = PageTranslator.statusMessage(for: outcome), !(automatically && outcome == .nothingToTranslate) {
                browser?.flashStatus(message)
            }
            if outcome == .translated { Announcer.announce(String(localized: "Page translated")) }
            if translation == .translated { followTranslation(from: source) }
        }
    }
}
