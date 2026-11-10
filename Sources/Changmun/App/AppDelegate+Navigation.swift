import AppKit

extension AppDelegate {
    /// The page in front of the window in front: the peek while one is open, otherwise the active tab.
    var frontTab: Tab? { (ChatPopOut.shared.keyBrowser() ?? Browser.current).flatMap { $0.peek ?? $0.active } }

    /// Stops the page in front, as the button's ✕ does; only on while it loads.
    @objc func stopLoadingPage(_ sender: Any?) { frontTab?.webView?.stopLoading() }

    @objc func viewPageSource(_ sender: Any?) { frontTab?.viewSource() }

    /// ⌘+ and ⌘−: the new size is said, since a page can look the same at two of them.
    func zoom(_ browser: Browser, by step: Double) {
        guard let tab = browser.active, let webView = tab.webView else { return }
        tab.setZoom(webView.pageZoom + step)
        browser.flashStatus(Tab.zoomLabel(webView.pageZoom))
    }

    /// ⌘0: the default size, with a pinch undone too.
    func resetZoom(in browser: Browser) {
        guard let tab = browser.active, let webView = tab.webView else { return }
        tab.resetZoom()
        browser.flashStatus(Tab.zoomLabel(webView.pageZoom))
    }

    // MARK: Quitting

    /// The question before quitting while files are still downloading (quitting stops them): nil when nothing is. Keep Downloading is what Return does.
    static func quitQuestion(runningDownloads: Int) -> DialogSpec? {
        guard runningDownloads > 0 else { return nil }
        return DialogSpec(title: runningDownloads == 1 ? String(localized: "Quit and stop the download?") : String(localized: "Quit and stop \(runningDownloads) downloads?"),
                          message: String(localized: "Files that are still downloading won’t be finished."),
                          buttons: [DialogButton(title: String(localized: "Quit")), DialogButton(title: String(localized: "Keep Downloading"), role: .cancel, isDefault: true)])
    }

    /// Asks before quitting when downloads are running, and answers the app's question about quitting once the user has: true when it asks (the app
    /// waits for the answer). A headless Changmun never asks. What the cookie journal still has to write is written before the app ends, as always.
    func askBeforeQuitting() -> Bool {
        guard !Headless.isOn, let spec = Self.quitQuestion(runningDownloads: Downloads.shared.items.filter { $0.state == .running }.count) else { return false }
        let browser = Browser.current ?? BrowserWindow.open()
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task {
            let quits = await Dialog.present(in: browser.window, spec, key: DialogKey(group: "quit", kind: "downloads"))?.button == 0
            if quits, CookieJournal.shared.hasPendingWork { await CookieJournal.shared.flush(within: .seconds(2)) }
            NSApp.reply(toApplicationShouldTerminate: quits)
        }
        return true
    }
}
