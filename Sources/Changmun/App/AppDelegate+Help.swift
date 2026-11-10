import AppKit
import SwiftUI

/// The Help menu: the guide, and the shortcuts window.
extension AppDelegate {
    @objc func openGuide(_ sender: Any?) {
        let browser = Browser.recent ?? BrowserWindow.open()
        browser.openTab(url: ShortcutList.guideURL())
        browser.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showShortcuts(_ sender: Any?) {
        Panels.show("shortcuts", title: String(localized: "Keyboard Shortcuts"), size: NSSize(width: 520, height: 640)) { ShortcutsView() }
    }

    /// The shortcut scheme lives in Settings › Advanced.
    static func showShortcutSetting() {
        UserDefaults.standard.set(SettingsPage.advanced.rawValue, forKey: "settingsPage")
        (NSApp.delegate as? AppDelegate)?.showSettings(nil)
    }
}
