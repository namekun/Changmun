import AppKit

extension AppDelegate {
    /// The window the menu's commands are for, as `current` in AppDelegate.
    private var front: Browser? { ChatPopOut.shared.keyBrowser() ?? Browser.current }

    /// The tab list's tabs other than the one shown.
    @objc func closeOtherTabs(_ sender: Any?) {
        guard let browser = front, let id = browser.activeID else { return }
        browser.closeOtherTabs(keeping: id)
    }

    /// The tab list's tabs below the one shown.
    @objc func closeTabsBelow(_ sender: Any?) {
        guard let browser = front, let id = browser.activeID else { return }
        browser.closeTabsBelow(id)
    }
}
