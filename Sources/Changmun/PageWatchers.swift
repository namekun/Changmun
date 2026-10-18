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
    var host: String
    var username: String
    var password: String
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
            guard let webView = message.webView, let url = webView.url, url.scheme == "https", let host = url.host(),
                  let tab = Browser.tab(showing: webView), !tab.isPrivate else { return }
            let offer = LoginOffer(host: host, username: username, password: password)
            // The saved secret is read only when that account is already saved here.
            guard Self.worthOffering(offer, neverHosts: Preferences.shared.neverSaveLoginHosts, saved: {
                Logins.accounts(for: host).contains(username) ? Logins.password(host: host, username: username) : nil
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

/// Notices a page opening a window on its own (not from a click), which WebKit blocks, so the browser can offer it.
/// `window.open` belongs to the page, so this runs in the page's world and the page could post to it too: a message
/// only ever shows the bar, or opens a tab for a site the user allowed to open popups.
final class PopupWatcher: NSObject, WKScriptMessageHandler {
    static let name = "changmunPopup"

    static let script = """
    (() => {
      const open = window.open, handler = window.webkit.messageHandlers.\(name);
      window.open = function (url, target, features, ...rest) {
        // Blocked means: no click behind it. A click's window that returns null was opened with noopener, or shown as a peek.
        const clicked = navigator.userActivation ? navigator.userActivation.isActive : true;
        const opened = open.call(this, url, target, features, ...rest);
        if (!opened && !clicked && !/noopener|noreferrer/i.test(String(features || ''))) {
          try { handler.postMessage(new URL(url || '', location.href).href); } catch (e) {}
        }
        return opened;
      };
    })();
    """

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.add(PopupWatcher(), contentWorld: .page, name: name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the page itself: an ad's frame posting here must not borrow the site's permission.
        guard message.frameInfo.isMainFrame, let address = message.body as? String, let url = URL(string: address),
              ["http", "https"].contains(url.scheme) else { return }
        MainActor.assumeIsolated {
            guard let webView = message.webView, let tab = Browser.tab(showing: webView) else { return }
            tab.popupBlocked(url)
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
