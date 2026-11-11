import AppKit
import WebKit
import os

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // SECURITY DEPENDENCY: with javaScriptCanOpenWindowsAutomatically on, every window.open reaches this method, and all that keeps
        // a page from opening windows on its own is that `_isUserInitiated` (private, read through KVC) is false for them. If a
        // macOS release renames it, `knowsUserInitiated` goes false and the preference is turned off again (Browser.swift), so WebKit
        // refuses the unclicked windows itself. If one changes what it says, only the test that opens a window from a timer with no
        // gesture (aTimersPopupWithNoGestureIsRefused) notices, so it must keep passing.
        // The app's own scripts (the AI's tools, a login filled in...) run with a user gesture too: see AppScripts.
        let userInitiated = !AppScripts.drives(webView) && Self.isUserInitiated(action)
        var decision = "opened"
        defer { WindowLog.note("window", action, userInitiated: userInitiated, decision: decision, in: webView) }
        // A window for an app's address (window.open("claude://...")) is no window: the user is asked about the app here.
        if let url = action.request.url, let scheme = url.scheme?.lowercased(), !Self.browserSchemes.contains(scheme) {
            appLinkRequested(url, navigationType: action.navigationType, userInitiated: Self.userStartedForAppLinks(userInitiated, knowsUserInitiated: Self.knowsUserInitiated), isMainFrame: action.sourceFrame.isMainFrame,
                             site: Self.askingSite(of: action.sourceFrame), in: webView)
            decision = "app"
            return nil
        }
        if userInitiated, Self.isPeekClick(action), let url = action.request.url {
            browser?.openPeek(url)
            decision = "peek"
            return nil
        }
        if Self.isDownloadClick(action.navigationType, modifiers: action.modifierFlags, optionHeld: Self.optionKeyHeld, url: action.request.url,
                                userInitiated: Self.userStartedForAppLinks(userInitiated, knowsUserInitiated: Self.knowsUserInitiated)) {
            webView.startDownload(using: action.request) { [weak self] download in
                guard let self else { return }
                Downloads.shared.track(download, from: self)
            }
            decision = "download"
            return nil
        }
        var activate = true
        // The user's window is the first of its gesture, so that a loop of window.open in a click opens one tab, not hundreds.
        if !userInitiated || isAnotherWindowOfTheGesture() {
            // Not the user's, or one more of the same gesture: only a site the user allowed gets a window, and only a few. A refused one is
            // offered in the bar from here, not from a replaced `window.open`: a site that checks whether its functions are the browser's
            // own (a bot check does) would see the replacement and treat the browser as a bot.
            let site = PopupWatcher.site(of: action.sourceFrame)
            guard let browser, !isPrivate, Preferences.shared.allowsPopups(from: site.isEmpty ? nil : site),
                  browser.takeAllowedPopupSlot() else {
                // An empty window (window.open('')) is told about too: older sites open one and fill it in themselves.
                let url = action.request.url.flatMap { $0.absoluteString.isEmpty ? nil : $0 } ?? URL(string: "about:blank")!
                if ["http", "https"].contains(url.scheme?.lowercased()) || url.absoluteString == "about:blank" {
                    popupRefused(url, fromFrame: action.sourceFrame.isMainFrame ? nil : site, pageSite: action.sourceFrame.isMainFrame ? site : nil)
                }
                decision = userInitiated ? "refused (another of the gesture)" : "refused (not the user's)"
                return nil
            }
            activate = browser.isShown(self)
        }
        // The window about to take the front would close the peek, which is the page asking and its `window.opener`: it is kept as a tab.
        if activate, browser?.peek === self { browser?.keepPeek() }
        let tab = browser?.openTab(configuration: configuration, after: self, activate: activate)
        tab?.openerID = id
        if tab == nil { decision = "no window to open it in" }
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

    /// Whether a navigation counts as the user's for an app question (asking past the once-limit, giving the page its question back):
    /// where `_isUserInitiated` can't be read, `isUserInitiated` says yes for everything, which is not the user's word, so nothing counts.
    nonisolated static func userStartedForAppLinks(_ userInitiated: Bool, knowsUserInitiated: Bool) -> Bool {
        userInitiated && knowsUserInitiated
    }

    /// A click (or a script a click started a moment ago, as WebKit counts it) is behind the action.
    static func isUserInitiated(_ action: WKNavigationAction) -> Bool {
        guard knowsUserInitiated else { return true }
        return action.value(forKey: "_isUserInitiated") as? Bool ?? false
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        // Told no once, a page is told no again, quietly, until it loads another page.
        let blocked = "\(origin.host)|\(type.rawValue)"
        if blockedThisLoad.contains(blocked) { return .deny }
        let window = webView.window ?? browser?.window
        let answer = await SitePermissions.shared.decide(host: origin.host, type: type, remember: !isPrivate,
                                                         unverified: ServerTrustStore.isUnverified(host: origin.host, port: origin.port == 0 ? 443 : origin.port),
                                                         background: isInBackground) { spec, key in await self.askPage(spec, in: window, key: key) }
        if answer.blockedByUser { blockedThisLoad.insert(blocked) }
        return answer.decision
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
        _ = await askPageDialog(.alert, message: message, site: Self.askingSite(of: frame) ?? "", in: webView.window ?? browser?.window)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await askPageDialog(.confirm, message: message, site: Self.askingSite(of: frame) ?? "", in: webView.window ?? browser?.window)?.button == 1
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard let answer = await askPageDialog(.prompt(defaultText ?? ""), message: prompt, site: Self.askingSite(of: frame) ?? "",
                                               in: webView.window ?? browser?.window), answer.button == 1 else { return nil }
        return answer.fields.first ?? ""
    }

    enum PageDialog: Equatable {
        case alert, confirm
        /// With the text the field starts with.
        case prompt(String)
    }

    enum PageDialogTurn: Equatable {
        /// Answered at once with what leaves things as they are (OK for an alert, Cancel for the others), nothing shown.
        case answerQuietly
        /// A sheet on the window, with "Don't let this page show more dialogs" from the second one of a page load on.
        case ask(offerToStop: Bool)
    }

    /// What `blockedThisLoad` holds once the user said no more dialogs for this page.
    static let dialogsRefused = "page dialogs"

    /// Tests only: answers the page's dialogs (and the question about leaving it) in place of the user. A WebKit callback doesn't see task locals.
    static var pageDialogAnswerForTests: ((DialogSpec) -> DialogResult?)?

    nonisolated static func pageDialogTurn(shownThisLoad: Int, refused: Bool, headless: Bool) -> PageDialogTurn {
        headless || refused ? .answerQuietly : .ask(offerToStop: shownThisLoad >= 1)
    }

    /// A page's alert, confirm or prompt: a sheet on its tab's window like the app's other questions, never a window that holds the whole app.
    /// nil is the safe answer: nothing shown (a headless Changmun, a page told to stop, a busy window), or the sheet closed without one.
    func askPageDialog(_ kind: PageDialog, message: String, site: String, in window: NSWindow?) async -> DialogResult? {
        guard case .ask(let offer) = Self.pageDialogTurn(shownThisLoad: pageDialogsThisLoad, refused: blockedThisLoad.contains(Self.dialogsRefused),
                                                         headless: Headless.isOn) else { return nil }
        pageDialogsThisLoad += 1
        let load = navigations
        let spec = Self.pageDialogSpec(kind, message: message, site: site, background: isInBackground, offerToStop: offer)
        let answer: DialogResult?
        if let hook = Self.pageDialogAnswerForTests { answer = hook(spec) } else { answer = await askPage(spec, in: window) }
        // A page that came after the question was asked is not the one the user meant.
        if answer?.remembered == true, navigations == load { blockedThisLoad.insert(Self.dialogsRefused) }
        return answer
    }

    /// The page's words go in the box under the title, apart from the app's own, with the site that asks above them.
    static func pageDialogSpec(_ kind: PageDialog, message: String, site: String, background: Bool, offerToStop: Bool) -> DialogSpec {
        let ok = DialogButton(title: String(localized: "OK"), isDefault: true)
        var spec = DialogSpec(title: String(localized: "\(DialogSpec.host(site)) says"), detail: message.isEmpty ? nil : .text(message),
                              buttons: kind == .alert ? [ok] : [DialogButton(title: String(localized: "Cancel"), role: .cancel), ok],
                              note: background ? String(localized: "From a tab in the background") : nil, guarded: true)
        if case .prompt(let text) = kind { spec.fields = [DialogField(placeholder: String(localized: "Answer"), text: text)] }
        if offerToStop { spec.remember = String(localized: "Don’t let this page show more dialogs") }
        return spec
    }

    /// The page has something it says would be lost (`beforeunload`) and is about to be left: the user is asked, and Stay is what Return does.
    /// WebKit's question for this is private; a WebKit that stops asking it leaves the page without a word, as before. The answer goes to
    /// WebKit exactly once, whatever happens to the question.
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webViewRunBeforeUnloadConfirmPanel(_ webView: WKWebView, message: String?, frame: WKFrameInfo?, completionHandler: @escaping (Bool) -> Void) {
        let window = webView.window ?? browser?.window
        Task { @MainActor in completionHandler(await mayLeavePage(in: window)) }
    }

    /// A headless Changmun and a page the AI is driving leave as they did before there was a question; anything but Leave stays.
    func mayLeavePage(in window: NSWindow?) async -> Bool {
        guard !Headless.isOn, !AgentActivity.shared.holds(self) else { return true }
        let spec = Self.leavePageSpec(background: isInBackground)
        let answer: DialogResult?
        if let hook = Self.pageDialogAnswerForTests { answer = hook(spec) } else { answer = await askPage(spec, in: window, whenBusy: .wait) }
        return answer?.button == 0
    }

    static func leavePageSpec(background: Bool) -> DialogSpec {
        DialogSpec(title: String(localized: "Leave this page?"), message: String(localized: "Changes you made may not be saved."),
                   buttons: [DialogButton(title: String(localized: "Leave")), DialogButton(title: String(localized: "Stay"), role: .cancel, isDefault: true)],
                   note: background ? String(localized: "From a tab in the background") : nil, guarded: true)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard !Headless.isOn else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

/// Why a link or a page's window did what it did, in Console (subsystem io.github.namekun.Changmun, category windows): what kind of
/// navigation, whether the user's click started it, the keys held, and what was decided. A link that "does nothing" on a page the
/// developer can't open (one behind a sign-in) is found from these lines. Of the address only the scheme and, for http(s), the host are
/// written as they are; the path is a hash (the same path, the same hash) and the query is left out, as either can say who the user is.
/// Nothing is written unless the page keeps its data on disk, so never for a private window, even one whose browser has gone.
enum WindowLog {
    nonisolated static let log = Logger(subsystem: "io.github.namekun.Changmun", category: "windows")

    @MainActor static func note(_ what: String, _ action: WKNavigationAction, userInitiated: Bool, decision: String, in webView: WKWebView) {
        guard webView.configuration.websiteDataStore.isPersistent else { return }
        let url = action.request.url
        let scheme = url?.scheme?.lowercased() ?? "(none)"
        let web = scheme == "http" || scheme == "https"
        let host = web ? url?.host() ?? "" : ""
        let path = web ? url?.path() ?? "" : ""
        let keys = [(NSEvent.ModifierFlags.command, "cmd"), (.shift, "shift"), (.option, "opt"), (.control, "ctrl")]
            .filter { action.modifierFlags.contains($0.0) }.map(\.1).joined(separator: "+")
        log.notice("""
            \(what, privacy: .public) \(scheme, privacy: .public)://\(host, privacy: .public) path=\(path, privacy: .private(mask: .hash)) \
            type=\(action.navigationType.rawValue, privacy: .public) user=\(userInitiated, privacy: .public) keys=\(keys, privacy: .public) \
            mainFrame=\(action.sourceFrame.isMainFrame, privacy: .public) -> \(decision, privacy: .public)
            """)
    }
}
