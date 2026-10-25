import AppKit
import WebKit

extension Browser {
    // MARK: Peek

    func openPeek(_ url: URL) {
        // A peek opened from the old one's own delegate call (⇧-click in it) can't put it to sleep within that call.
        let old = peek
        let tab = Tab(id: Self.takeID(), url: url, browser: self)
        peek = tab
        tab.wake()
        DispatchQueue.main.async { old?.sleep() }
    }

    func closePeek() {
        peek?.sleep()
        peek = nil
    }

    /// Keeps the peeked page as a tab after the shown one, as it is now (not loaded again).
    func keepPeek() {
        guard let tab = peek else { return }
        peek = nil
        insert(tab, after: active)
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabOpened(tab) }
        activate(tab.id)
    }
}
