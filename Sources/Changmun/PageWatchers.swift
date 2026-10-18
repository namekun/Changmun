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
        const key = (user ? user.value : '') + '\\n' + pw.value;
        if (key === last) return;
        last = key;
        window.webkit.messageHandlers.\(name).postMessage({username: user ? user.value : '', password: pw.value});
      };
      document.addEventListener('submit', e => capture(e.target), true);
      document.addEventListener('click', e => {
        const button = e.target instanceof Element ? e.target.closest('button, input[type=submit]') : null;
        if (button && button.form) capture(button.form);
      }, true);
      document.addEventListener('keydown', e => {
        if (e.key === 'Enter' && e.target instanceof HTMLInputElement && e.target.form) capture(e.target.form);
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
                  let tab = Browser.all.lazy.compactMap({ browser in (browser.tabs + [browser.peek].compactMap { $0 }).first { $0.webView === webView } }).first,
                  !tab.isPrivate else { return }
            let offer = LoginOffer(host: host, username: username, password: password)
            guard Self.worthOffering(offer, neverHosts: Preferences.shared.neverSaveLoginHosts,
                                     saved: { Logins.password(host: host, username: username) }) else { return }
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
