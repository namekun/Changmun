import AppKit
import WebKit

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // SECURITY DEPENDENCY: with javaScriptCanOpenWindowsAutomatically on, every window.open reaches this method, and all that keeps
        // a page from opening windows on its own is that `_isUserInitiated` (private, read through KVC) is false for them. If a
        // macOS release renames it, `knowsUserInitiated` goes false and the preference is turned off again (Browser.swift), so WebKit
        // refuses the unclicked windows itself. If one changes what it says, only the test that opens a window from a timer with no
        // gesture (aTimersPopupWithNoGestureIsRefused) notices, so it must keep passing.
        // The app's own scripts (the AI's tools, a login filled in...) run with a user gesture too: see AppScripts.
        let userInitiated = !AppScripts.drives(webView) && Self.isUserInitiated(action)
        // A window for an app's address (window.open("claude://...")) is no window: the user is asked about the app here.
        if let url = action.request.url, let scheme = url.scheme?.lowercased(), !Self.browserSchemes.contains(scheme) {
            appLinkRequested(url, navigationType: action.navigationType, userInitiated: userInitiated, isMainFrame: true, source: action.sourceFrame.request.url, in: webView)
            return nil
        }
        if userInitiated, Self.isPeekClick(action), let url = action.request.url {
            browser?.openPeek(url)
            return nil
        }
        var activate = true
        // The user's window is the first of its gesture, so that a loop of window.open in a click opens one tab, not hundreds.
        if !userInitiated || isAnotherWindowOfTheGesture() {
            // Not the user's, or one more of the same gesture: only a site the user allowed gets a window, and only a few.
            let site = PopupWatcher.site(of: action.sourceFrame)
            guard let browser, !isPrivate, Preferences.shared.allowsPopups(from: site.isEmpty ? nil : site),
                  browser.takeAllowedPopupSlot() else { return nil }
            activate = browser.isShown(self)
        }
        // The window about to take the front would close the peek, which is the page asking and its `window.opener`: it is kept as a tab.
        if activate, browser?.peek === self { browser?.keepPeek() }
        let tab = browser?.openTab(configuration: configuration, after: self, activate: activate)
        tab?.openerID = id
        return tab?.webView
    }

    /// Whether the window a user-initiated `window.open` asks for follows another of the same gesture: within a second of the last
    /// one asked for (each ask renews that, so a long loop is one gesture), and with no new click or key between. Where the event
    /// can't be told (a script of the app's, a stale one), the second alone decides.
    private func isAnotherWindowOfTheGesture() -> Bool {
        let event = NSApp.currentEvent?.timestamp
        defer { lastGestureWindow = (Date(), event) }
        guard let last = lastGestureWindow, Date().timeIntervalSince(last.at) < 1 else { return false }
        return event == nil || event == last.event
    }

    /// Whether WebKit can say a window was asked for by the user (it can in this version of macOS: its navigation actions carry
    /// `_isUserInitiated`). Where it can't, windows are left to WebKit to allow or refuse, and the watcher offers the refused.
    static let knowsUserInitiated = WKNavigationAction.instancesRespond(to: NSSelectorFromString("_isUserInitiated"))

    /// A click (or a script a click started a moment ago, as WebKit counts it) is behind the action.
    static func isUserInitiated(_ action: WKNavigationAction) -> Bool {
        guard knowsUserInitiated else { return true }
        return action.value(forKey: "_isUserInitiated") as? Bool ?? false
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        SitePermissions.shared.decide(host: origin.host, type: type, remember: !isPrivate)
    }

    /// "Back to tab" on the floating video, the only thing WebKit asks this for: its tab and window come to the front, as
    /// in Safari. WebKit holds the video until its page is on screen; if it still floats a moment later, it is let go.
    @objc(_webViewFullscreenMayReturnToInline:)
    func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        guard let browser else { return }
        if browser.peek !== self && !browser.isShown(self) { browser.activate(id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.isInPictureInPicture == true { self?.pictureInPicture(.exit) }
        }
        guard let window = browser.window else { return }
        window.makeKeyAndOrderFront(nil)
        if !Headless.isOn { NSApp.activate() }
    }

    func webViewDidClose(_ webView: WKWebView) {
        if browser?.peek === self { browser?.closePeek() } else { browser?.close(id) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        guard !Headless.isOn else { return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard !Headless.isOn else { return false }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard !Headless.isOn else { return nil }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard !Headless.isOn else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
