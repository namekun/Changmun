import Foundation
import WebKit

/// Follows WebKit's private `_isPlayingAudio` (it is key-value observable), when this WebKit has it.
final class AudioWatcher: NSObject {
    private static let key = "_isPlayingAudio"
    private weak var view: WKWebView?
    private let changed: @MainActor (Bool) -> Void

    init?(_ view: WKWebView, changed: @escaping @MainActor (Bool) -> Void) {
        guard view.responds(to: NSSelectorFromString(Self.key)) else { return nil }
        self.view = view
        self.changed = changed
        super.init()
        view.addObserver(self, forKeyPath: Self.key, options: [.initial, .new], context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let playing = (object as? NSObject)?.value(forKey: Self.key) as? Bool ?? false
        Task { @MainActor in changed(playing) }
    }

    deinit {
        view?.removeObserver(self, forKeyPath: Self.key)
    }
}

/// A sign-in the user just submitted. The password stays in memory until it is saved or turned down.
struct LoginOffer: Equatable {
    /// The key the login is saved under: the host, with its port when that isn't https's own.
    var host: String
    var username: String
    var password: String
    /// The account is saved already: what is offered is the new password for it.
    var updatesExisting = false

    /// The user name to offer the login under. A sign-in in two steps (the password page without the name) has none: it is the one account
    /// saved for the site when there is only one, and when there are several nobody can tell which (nil: nothing is offered).
    static func username(captured: String, saved accounts: [String]) -> String? {
        guard captured.isEmpty, !accounts.contains("") else { return captured }
        switch accounts.count {
        case 0: return captured
        case 1: return accounts[0]
        default: return nil
        }
    }

    /// The offer for a sign-in captured on a page whose logins are saved under `host`. A sign-in in two steps is the one account saved
    /// under exactly that key; the accounts of its www twin, or saved for the bare host before ports counted, are other sites' to it.
    static func make(host: String, captured: String, password: String) -> LoginOffer? {
        guard let username = username(captured: captured, saved: Logins.accounts(exactly: host)) else { return nil }
        return LoginOffer(host: host, username: username, password: password, updatesExisting: Logins.accounts(for: host).contains(username))
    }
}

/// Notices sign-in forms being submitted, so the browser can offer to save the password. Runs in an isolated world:
/// pages can't post to it, though they can fill a form with anything, so nothing is saved without the user's yes.
final class LoginCapture: NSObject, WKScriptMessageHandler {
    static let name = "changmunLoginCapture"

    static let script = """
    (() => {
      const visible = e => e.offsetParent !== null || e.getClientRects().length > 0;
      let last = '';
      const capture = scope => {
        scope = scope || document;
        const pw = [...scope.querySelectorAll('input[type=password]')].find(e => visible(e) && e.value);
        if (!pw) return;
        const fields = [...(pw.form || scope).querySelectorAll('input')]
          .filter(e => /^(text|email|tel|)$/.test(e.type) && visible(e) && e.value);
        const user = fields.filter(e => e.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING).pop() || null;
        pw.setAttribute('data-cm-secret', '');
        const key = (user ? user.value : '') + '\\n' + pw.value;
        if (key === last) return;
        last = key;
        window.webkit.messageHandlers.\(name).postMessage({username: user ? user.value : '', password: pw.value});
      };
      // Only what the user did: a page's own synthetic events, and buttons that don't submit (show password), don't count.
      document.addEventListener('submit', e => { if (e.isTrusted) capture(e.target); }, true);
      document.addEventListener('click', e => {
        const button = e.target instanceof Element ? e.target.closest('button, input[type=submit]') : null;
        if (e.isTrusted && button && button.form && button.type === 'submit') capture(button.form);
      }, true);
      document.addEventListener('keydown', e => {
        if (e.isTrusted && e.key === 'Enter' && e.target instanceof HTMLInputElement && e.target.form) capture(e.target.form);
      }, true);
    })();
    """

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        controller.add(LoginCapture(), contentWorld: .defaultClient, name: name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let password = body["password"] as? String, !password.isEmpty else { return }
        let username = body["username"] as? String ?? ""
        MainActor.assumeIsolated {
            guard let webView = message.webView, let url = webView.url, url.scheme == "https", let host = Logins.key(for: url), let site = url.host(),
                  let tab = Browser.tab(showing: webView), !tab.isPrivate, !Tab.isUnverified(url) else { return }
            guard let offer = LoginOffer.make(host: host, captured: username, password: password) else { return }
            // The saved secret is read only when that account is already saved here. The never-list names sites, not ports.
            guard Self.worthOffering(LoginOffer(host: site, username: offer.username, password: password), neverHosts: Preferences.shared.neverSaveLoginHosts, saved: {
                offer.updatesExisting ? Logins.password(host: host, username: offer.username) : nil
            }) else { return }
            tab.loginOffer = offer
        }
    }

    /// Not for a site the user said never to, and not when that exact sign-in is already saved.
    nonisolated static func worthOffering(_ offer: LoginOffer, neverHosts: [String], saved: () -> String?) -> Bool {
        let host = offer.host.lowercased()
        if neverHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return false }
        return saved() != offer.password
    }
}

/// The site a frame's own documents come from, which is its origin's: how a refused window is judged (`Tab.createWebViewWith`).
/// Empty for a frame with none (a sandboxed one, whose address its page chose), which no site's permission ever matches. Nothing of
/// the app's runs in the page's world for this: a replaced `window.open` would be seen by a site's bot check, and the app refused.
enum PopupWatcher {
    static func site(of frame: WKFrameInfo) -> String { frame.securityOrigin.host.lowercased() }
}

/// Tells the app when a page's video goes into picture in picture or comes back, so ⌃⌘← and ⌃⌘→ can move it 5 seconds
/// from any app while it floats. Runs in an isolated world.
final class PictureInPictureWatcher: NSObject, WKScriptMessageHandler {
    static let name = "changmunPictureInPicture"

    static let script = """
    (() => {
      const report = () => window.webkit.messageHandlers.\(name).postMessage(!!document.pictureInPictureElement
        || [...document.querySelectorAll('video')].some(v => v.webkitPresentationMode === 'picture-in-picture'));
      for (const type of ['enterpictureinpicture', 'leavepictureinpicture', 'webkitpresentationmodechanged']) {
        document.addEventListener(type, () => setTimeout(report, 0), true);
      }
    })();
    """

    static func install(in controller: WKUserContentController) {
        // The main frame only, where seeking reaches: a video embedded from another site can't be moved from here.
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        controller.add(PictureInPictureWatcher(), contentWorld: .defaultClient, name: name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let floating = message.body as? Bool ?? false
        MainActor.assumeIsolated {
            guard let webView = message.webView, let tab = Browser.tab(showing: webView) else { return }
            tab.isInPictureInPicture = floating
        }
    }
}
