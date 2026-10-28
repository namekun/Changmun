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
            // The bar keeps the first one until it is closed, so that a frame can't swap the address (and the site "Always
            // Allow" would allow) under a user who is about to press it; the others only add to its count.
            if blockedPopup == nil {
                blockedPopup = popup
                blockedPopupFrame = frame
                blockedPopupSite = judged
                blockedPopupCount = 1
            } else {
                blockedPopupCount += 1
            }
            return
        }
        browser.openTab(url: popup, activate: browser.isShown(self), after: self).openerID = id
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
        blockedPopup = nil
        if always, !isPrivate, let site { Preferences.shared.allowPopups(from: site) }
        browser?.openTab(url: popup, after: self).openerID = id
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

    /// Translates the page into the user's language, or puts the original back (also stopping a translation under way).
    func toggleTranslation() {
        guard let webView else { return }
        if translation != .original {
            translating?.cancel()
            translating = nil
            translation = .original
            Announcer.announce(String(localized: "Showing the original page"))
            Task { await PageTranslator.showOriginal(webView) }
            return
        }
        translation = .translating
        let page = page
        let current = { [weak self] in self?.page == page && self?.webView === webView && !Task.isCancelled }
        translating = Task {
            guard let source = await PageTranslator.foreignLanguage(of: webView) else {
                guard current() else { return }
                translating = nil
                translation = .original
                browser?.flashStatus(String(localized: "No text in another language to translate"))
                return
            }
            foreignLanguage = source
            let outcome = await PageTranslator.translate(webView, from: source, while: current)
            guard current() else { return }
            translating = nil
            translation = outcome == .translated ? .translated : .original
            switch outcome {
            case .needsDownload: browser?.flashStatus(String(localized: "Download this language in System Settings › General › Language & Region › Translation Languages"))
            case .unsupported: browser?.flashStatus(String(localized: "This language can’t be translated"))
            case .nothingToTranslate: browser?.flashStatus(String(localized: "No text in another language to translate"))
            case .failed: browser?.flashStatus(String(localized: "Couldn't translate this page"))
            case .engineFailed: browser?.flashStatus(String(localized: "Couldn't translate this page. macOS’s translation didn’t respond — try again, or check System Settings › General › Language & Region › Translation Languages."))
            case .translated: Announcer.announce(String(localized: "Page translated"))
            }
        }
    }
}
