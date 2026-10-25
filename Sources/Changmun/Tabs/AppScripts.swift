import ObjectiveC
import WebKit

/// The scripts the app itself runs in a page (the AI's tools, a login filled in, translation, the reader, picture in picture)
/// carry a user gesture, and the page's own handlers for what they do (an input event, a mutation, a timer set from them) run
/// under it: they could open a window as if the user had clicked. So a page counts as driven by the app while one of these
/// scripts is still running in it, and for a moment after the last one, and no window it opens then is the user's.
///
/// What counts is when the page's script really ends (the completion handler), not when the app stopped waiting for it:
/// a tool that timed out may have a script still going. The one exception is the user's own kind of act, a click of the
/// AI's (`userLike`), whose window is the point of the click. Scripts that only read are left on WebKit's own calls.
@MainActor
enum AppScripts {
    /// What is known of one page's scripts, kept on its web view so that it goes with it.
    private final class Page {
        var running = 0, userLike = 0
        var lastEnd = Date.distantPast
    }

    private static var key = 0
    /// How long after the last script a page is still taken to be driven: a gesture lets timers set under it run a moment later.
    static let grace: TimeInterval = 2
    static let clickTools: Set<String> = ["click", "click_at"]

    private static func page(of webView: WKWebView, create: Bool) -> Page? {
        if let page = objc_getAssociatedObject(webView, &key) as? Page { return page }
        guard create else { return nil }
        let page = Page()
        objc_setAssociatedObject(webView, &key, page, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return page
    }

    fileprivate static func started(_ webView: WKWebView, userLike: Bool) {
        let page = page(of: webView, create: true)!
        if userLike { page.userLike += 1 } else { page.running += 1 }
    }

    fileprivate static func ended(_ webView: WKWebView, userLike: Bool) {
        guard let page = page(of: webView, create: false) else { return }
        if userLike {
            page.userLike -= 1
        } else {
            page.running -= 1
            page.lastEnd = Date()
        }
    }

    /// Whether a gesture seen in this page now may be the app's script, not the user: one that is not a click is running, or
    /// ended a moment ago (unless a click of the AI's is running now).
    static func drives(_ webView: WKWebView) -> Bool {
        guard let page = page(of: webView, create: false) else { return false }
        if page.running > 0 { return true }
        return page.userLike == 0 && Date().timeIntervalSince(page.lastEnd) < grace
    }
}

extension WKWebView {
    /// `callAsyncJavaScript` in the page's name for the app: the page is marked as driven until the script has really ended.
    func appScript(_ script: String, arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil,
                   userLike: Bool = false, completion: @escaping (Result<Any, Error>) -> Void = { _ in }) {
        AppScripts.started(self, userLike: userLike)
        callAsyncJavaScript(script, arguments: arguments, in: frame, in: .defaultClient) { [weak self] result in
            if let self { AppScripts.ended(self, userLike: userLike) }
            completion(result)
        }
    }

    /// The same, waiting for the answer.
    @MainActor
    func appScript(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            appScript(script, arguments: arguments) { continuation.resume(with: $0.map { Optional($0) }) }
        }
    }
}
