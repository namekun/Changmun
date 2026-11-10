import AppKit
import UniformTypeIdentifiers
import WebKit

extension WKWebView {
    /// The page is in WebKit's full screen window (a video's or another element's), with a placeholder where it was. A host
    /// that took it back then would leave the full screen window empty and, as it ends, WebKit nothing to put the page back in.
    var isAway: Bool { fullscreenState != .notInFullscreen }
}

/// A tab's web view: WebKit's own, with "Ask AI About Selection", "Preview Link" and "Add Link to Reading List" added to its context menu.
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

    /// A load the user stopped no longer waits for a certificate.
    override func stopLoading() {
        super.stopLoading()
        if let owner { owner.browser?.certificatePrompter.forget(owner) }
    }

    /// Reload from the menu while the page has the keys comes here, not to the app: it goes the tab's way (see `Tab.reload`).
    override func reload(_ sender: Any?) {
        if let owner { owner.reload() } else { super.reload(sender) }
    }

    override func reloadFromOrigin(_ sender: Any?) {
        if let owner { owner.reload(fromOrigin: true) } else { super.reloadFromOrigin(sender) }
    }

    // MARK: Keys

    enum PageKey: Equatable { case stop, back, forward }

    /// Esc stops a page that is loading; ⌘← and ⌘→ go back and forward. Held down, a key does it once.
    nonisolated static func pageKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> PageKey? {
        guard !isRepeat else { return nil }
        // Arrow keys also carry the function and keypad flags.
        let held = modifiers.intersection([.command, .option, .control, .shift])
        switch (keyCode, held) {
        case (53, []): return .stop
        case (123, .command): return .back
        case (124, .command): return .forward
        default: return nil
        }
    }

    /// Whether the keys go to something the user types in: a field, an editor, a frame (whose inside the app can't see from here). There Esc and
    /// ⌘← / ⌘→ belong to the text.
    static let typingScript = """
    if (document.designMode === 'on') return true;
    let el = document.activeElement;
    while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
    if (!el || el === document.body || el === document.documentElement) return false;
    if (el.isContentEditable || ['TEXTAREA', 'SELECT', 'IFRAME', 'FRAME', 'EMBED', 'OBJECT'].includes(el.tagName)) return true;
    if (el.getAttribute('role') === 'textbox') return true;
    if (el.tagName !== 'INPUT') return false;
    return !['button', 'submit', 'reset', 'checkbox', 'radio', 'image', 'file', 'range', 'color'].includes((el.type || '').toLowerCase());
    """

    private var lastPageKey: TimeInterval?

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        afterPageKey(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let handled = super.performKeyEquivalent(with: event)
        afterPageKey(event)
        return handled
    }

    /// The page has the key first, always: these keys only add to what it does with them, and only where nothing takes typing. The question is
    /// asked in the app's own world, after the page has had the key.
    private func afterPageKey(_ event: NSEvent) {
        guard event.type == .keyDown, event.timestamp != lastPageKey, owner != nil, !isAway,
              (window?.firstResponder as? NSView)?.isDescendant(of: self) == true,
              let key = Self.pageKey(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat) else { return }
        // WebKit hands a key the page left alone back up the chain, which can bring it here a second time.
        lastPageKey = event.timestamp
        if key == .stop && !isLoading { return }
        callAsyncJavaScript(Self.typingScript, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            Task { @MainActor in
                guard let self, let owner = self.owner, case .success(let typing) = result, typing as? Bool == false else { return }
                switch key {
                case .stop: if self.isLoading { self.stopLoading() }
                case .back: if owner.canGoBack { self.goBack() }
                case .forward: if owner.canGoForward { self.goForward() }
                }
            }
        }
    }

    // MARK: Dropped files

    /// Files the user dropped on the page a moment ago. WebKit opens one in the page when the page doesn't take the drop; only a load of such a file
    /// is the user's, never one the page asks for itself.
    private var dropped: (files: [URL], at: Date)?

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        dropped = files.isEmpty ? nil : (files, Date())
        return super.performDragOperation(sender)
    }

    /// The files to open when WebKit loads `url`: the openable ones the user dropped, if `url` is one of them. Asked once per drop.
    func takeDrop(leadingTo url: URL) -> [URL]? {
        guard let drop = dropped else { return nil }
        dropped = nil
        return Self.filesToOpen(loading: url, dropped: drop.files, droppedAt: drop.at, now: Date())
    }

    /// Only a load that comes right after the drop and is for a dropped file counts, and only web pages, PDFs and images are opened.
    nonisolated static func filesToOpen(loading url: URL, dropped: [URL], droppedAt: Date, now: Date) -> [URL]? {
        let opens = { (file: URL) in
            !file.hasDirectoryPath && [UTType.html, .pdf, .image].contains { UTType(filenameExtension: file.pathExtension)?.conforms(to: $0) == true }
        }
        guard now.timeIntervalSince(droppedAt) < 3, opens(url), dropped.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return nil }
        return dropped.filter(opens)
    }

    /// WebKit's identifier for the menu's "Copy", which is there when text is selected.
    private static let copyItem = "WKMenuItemIdentifierCopy"
    /// WebKit's identifier for the link menu's "Copy Link".
    private static let copyLinkItem = "WKMenuItemIdentifierCopyLink"
    /// WebKit's identifier for the link menu's "Open Link in New Window".
    private static let openLinkInNewWindowItem = "WKMenuItemIdentifierOpenLinkInNewWindow"

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // The ⇧-click's preview, for whoever doesn't know the click.
        if let link = owner?.browser?.hoveredLink, let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let at = menu.items.firstIndex(where: { $0.identifier?.rawValue == Self.openLinkInNewWindowItem })
               ?? menu.items.firstIndex(where: { $0.identifier?.rawValue == Self.copyLinkItem }) {
            let item = NSMenuItem(title: String(localized: "Preview Link"), action: #selector(previewLink(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.insertItem(item, at: at + 1)
        }
        // The link the pointer is over (see `LinkHover`), not in a private window.
        if let link = owner?.browser?.hoveredLink, owner?.isPrivate == false, ReadingList.key(for: link) != nil,
           let at = menu.items.firstIndex(where: { $0.identifier?.rawValue == Self.copyLinkItem }) {
            let item = NSMenuItem(title: String(localized: "Add Link to Reading List"), action: #selector(addLinkToReadingList(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = link
            menu.insertItem(item, at: at + 1)
        }
        guard let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == Self.copyItem }),
              owner?.canAskAIAboutSelection == true else { return }
        let item = NSMenuItem(title: String(localized: "Ask AI About Selection"), action: #selector(askAI), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.insertItem(item, at: index + 1)
    }

    @objc private func addLinkToReadingList(_ item: NSMenuItem) {
        owner?.browser?.addToReadingList(url: item.representedObject as? String, title: "")
    }

    @objc private func previewLink(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { owner?.browser?.openPeek(url) }
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
