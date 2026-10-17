import WebKit

/// Tells the app which link the pointer is over. Runs in an isolated world, so pages can't post to it.
final class LinkHover: NSObject, WKScriptMessageHandler {
    static let name = "changmunLinkHover"

    static let script = """
    (() => {
      let last = null;
      const report = href => { if (href !== last) { last = href; window.webkit.messageHandlers.\(name).postMessage(href || ''); } };
      document.addEventListener('mouseover', e => {
        const a = e.target instanceof Element ? e.target.closest('a[href]') : null;
        report(a ? a.href : null);
      }, true);
      document.addEventListener('mouseleave', () => report(null), true);
      window.addEventListener('blur', () => report(null));
    })();
    """

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        controller.add(LinkHover(), contentWorld: .defaultClient, name: name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let href = message.body as? String ?? ""
        MainActor.assumeIsolated {
            let browser = Browser.shared
            guard message.webView === browser.active?.webView else { return }
            browser.hoveredLink = href.isEmpty || href.hasPrefix("javascript:") ? nil : href
        }
    }
}
