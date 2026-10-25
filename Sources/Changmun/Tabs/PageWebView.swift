import AppKit
import WebKit

extension WKWebView {
    /// The page is in WebKit's full screen window (a video's or another element's), with a placeholder where it was. A host
    /// that took it back then would leave the full screen window empty and, as it ends, WebKit nothing to put the page back in.
    var isAway: Bool { fullscreenState != .notInFullscreen }
}

/// A tab's web view: WebKit's own, with "Ask AI About Selection" added to its context menu.
final class PageWebView: WKWebView {
    weak var owner: Tab?

    /// Tests only: what to say instead of WebKit's, which only a real full screen window changes.
    var fullscreenStateForTests: WKWebView.FullscreenState?
    override var fullscreenState: WKWebView.FullscreenState { fullscreenStateForTests ?? super.fullscreenState }

    /// Tests only: how often the page was asked to leave full screen.
    private(set) var fullscreenExitsRequested = 0

    /// Asks the page to end its full screen (element or video), and lets go of it once it is back in its window: WebKit puts it
    /// back where its placeholder is, and a page taken out before would be put back there, in a host that shows another tab.
    func leaveFullscreen() {
        fullscreenExitsRequested += 1
        evaluateJavaScript("document.fullscreenElement && document.exitFullscreen()") { _, _ in }
        closeAllMediaPresentations {}
        Task { @MainActor [self] in
            for _ in 0..<50 where fullscreenState != .notInFullscreen { try? await Task.sleep(for: .milliseconds(100)) }
            removeFromSuperview()
        }
    }

    /// WebKit's identifier for the menu's "Copy", which is there when text is selected.
    private static let copyItem = "WKMenuItemIdentifierCopy"

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == Self.copyItem }),
              owner?.canAskAIAboutSelection == true else { return }
        let item = NSMenuItem(title: String(localized: "Ask AI About Selection"), action: #selector(askAI), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.insertItem(item, at: index + 1)
    }

    @objc private func askAI() { owner?.askAIAboutSelection() }
}

extension Tab {
    /// Not in a private window (the AI can't see it), nor for a preview that floats over the page or a profile the window isn't in.
    var canAskAIAboutSelection: Bool {
        guard let browser else { return false }
        return browser.isVisibleToAI(self) && browser.peek !== self
    }

    /// Opens the AI panel with the selected text quoted in its box and this tab as the current one, ready for a question.
    func askAIAboutSelection() {
        guard canAskAIAboutSelection, let webView else { return }
        // Read in the app's own world: the page's scripts can't answer in place of the selection.
        webView.callAsyncJavaScript("return window.getSelection().toString()", arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            Task { @MainActor in
                guard let self, let browser = self.browser, case .success(let value) = result, let text = value as? String,
                      let quote = ComposerQuote.block(from: text) else { return }
                if browser.activeID != self.id { browser.activate(self.id) }
                // What the page's text says goes into the message as it is: it counts as read from this site, like the page itself.
                Approvals.noteRead(self, caller: ChatStore.caller)
                ChatStore.shared.prefill = quote
                browser.showChat = true
                browser.window?.makeKeyAndOrderFront(nil)
            }
        }
    }
}
