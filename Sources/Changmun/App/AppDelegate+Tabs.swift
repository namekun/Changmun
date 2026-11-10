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

extension AppDelegate {
    /// The space shown, from the Window menu as from a right-click on its icon.
    @objc func editSpace(_ sender: Any?) {
        guard let browser = front, !browser.isPrivate else { return }
        browser.spaceSheet = .edit(browser.spaceID)
    }

    @objc func deleteSpace(_ sender: Any?) {
        guard let browser = front, !browser.isPrivate else { return }
        guard browser.spaces.spaces.count > 1 else { return browser.flashStatus(String(localized: "The only space can’t be deleted")) }
        SpaceSwitcher.confirmDelete(browser.space, in: browser)
    }
}
