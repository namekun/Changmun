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

    /// The key last given to the page, by its time. WebKit gives the page every key first and sends one it left alone (no listener prevented
    /// it, no field, editor or frame took it) through the window again, after the page is done with it: that second arrival is the only sign
    /// that the page didn't use the key, so only then do these keys do what they do here.
    private var givenToPage: TimeInterval?

    /// Whether a key arriving at `time` is one given to the page coming back unused. Its first arrival is noted as given.
    nonisolated static func cameBack(at time: TimeInterval, given: inout TimeInterval?) -> Bool {
        if given == time {
            given = nil
            return true
        }
        given = time
        return false
    }

    override func keyDown(with event: NSEvent) {
        if pageLeftAlone(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if pageLeftAlone(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// True when the key came back from the page unused and did what it does here. WebKit gives the page a key only while it is the first
    /// responder itself, so only then is a first arrival noted.
    private func pageLeftAlone(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let owner, !isAway, window?.firstResponder === self,
              let key = Self.pageKey(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat),
              Self.cameBack(at: event.timestamp, given: &givenToPage) else { return false }
        switch key {
        case .stop:
            guard isLoading else { return false }
            stopLoading()
        case .back:
            guard owner.canGoBack else { return false }
            goBack()
        case .forward:
            guard owner.canGoForward else { return false }
            goForward()
        }
        return true
    }

    // MARK: Dropped files

    /// Files the user dropped on the page a moment ago. WebKit opens one in the page when the page doesn't take the drop; only a load of such a file
    /// is the user's, never one the page asks for itself. A page that takes the drop loads nothing, so the claim waits for a load of one of
    /// those very files, and a load the tab starts itself (Open File, the address bar) ends it.
    private var dropped: (files: [URL], at: Date)?

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        noteDrop(sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
        return super.performDragOperation(sender)
    }

    func noteDrop(_ files: [URL], at date: Date = Date()) {
        dropped = files.isEmpty ? nil : (files, date)
    }

    func forgetDrop() { dropped = nil }

    /// The files to open when WebKit loads `url`: the openable ones the user dropped, if `url` is one of them. Spent by that load only.
    func takeDrop(leadingTo url: URL) -> [URL]? {
        guard let drop = dropped, let files = Self.filesToOpen(loading: url, dropped: drop.files, droppedAt: drop.at, now: Date()) else { return nil }
        dropped = nil
        return files
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
