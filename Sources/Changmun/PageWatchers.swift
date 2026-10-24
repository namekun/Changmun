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
                  let tab = Browser.tab(showing: webView), !tab.isPrivate else { return }
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

/// Notices a page's `window.open` coming back empty-handed, in the page and in every frame in it: the app refuses windows
/// nobody asked for (no click behind them, or one too long ago), a filter list can stop one before the app is asked, and a
/// sandboxed frame can't open any. Each is offered in a bar, or opened as a tab for a site the user allowed pop-ups from.
/// `window.open` belongs to the page, so this runs in the page's world and the page could post to it too: a message only
/// ever shows the bar, or opens a tab for the site of the frame it came from, which WebKit names, not the message.
final class PopupWatcher: NSObject, WKScriptMessageHandler {
    static let name = "changmunPopup"

    static let script = """
    (() => {
      const open = window.open, handler = window.webkit.messageHandlers.\(name);
      window.open = function (url, target, features, ...rest) {
        const opened = open.call(this, url, target, features, ...rest);
        // No window back means none was opened (noopener asks for none to come back, and its window did open).
        if (!opened && !/noopener|noreferrer/i.test(String(features || ''))) {
          try {
            const address = new URL(url || '', location.href).href;
            console.warn('Changmun blocked a pop-up to ' + address + ': it was not opened by a click, or a filter list or a sandbox stopped it.');
            handler.postMessage(address);
          } catch (e) {}
        }
        return opened;
      };
    })();
    """

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.add(PopupWatcher(), contentWorld: .page, name: name)
    }

    /// The site a frame's own documents come from, which is its origin's. Empty for a frame with none (a sandboxed one, whose
    /// address its page chose), which no site's permission ever matches.
    static func site(of frame: WKFrameInfo) -> String { frame.securityOrigin.host.lowercased() }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let address = message.body as? String, let url = URL(string: address), ["http", "https"].contains(url.scheme) else { return }
        MainActor.assumeIsolated {
            guard let webView = message.webView, let tab = Browser.tab(showing: webView) else { return }
            // An ad's frame posting here must not borrow the site's permission: it is judged by its own site. The page itself is
            // judged by the origin WebKit says its main frame has, not by the address the tab shows, which can run ahead of it.
            let site = Self.site(of: message.frameInfo)
            tab.popupBlocked(url, fromFrame: message.frameInfo.isMainFrame ? nil : site, pageSite: message.frameInfo.isMainFrame ? site : nil)
        }
    }
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
