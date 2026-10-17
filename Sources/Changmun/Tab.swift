import AppKit
import WebKit

/// One tab. A sleeping tab has no web view (and so no web content process); it keeps its
/// back/forward state and loads again when it is shown.
@MainActor
final class Tab: NSObject, ObservableObject, Identifiable {
    let id: Int
    @Published var title: String
    @Published var url: URL?
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var favicon: NSImage?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var savedLogins: [String] = []
    @Published private(set) var webView: WKWebView?
    var lastShown = Date()
    private var savedState: Data?
    private var observations: [NSKeyValueObservation] = []
    private weak var browser: Browser?

    var isAsleep: Bool { webView == nil }

    init(id: Int, url: URL?, title: String = "", state: Data? = nil, browser: Browser) {
        self.id = id
        self.url = url
        self.title = title
        self.savedState = state
        self.browser = browser
        super.init()
    }

    /// A tab for a page WebKit opens itself (`target=_blank`, `window.open`): it must use the configuration WebKit hands over.
    init(id: Int, configuration: WKWebViewConfiguration, browser: Browser) {
        self.id = id
        self.title = ""
        self.browser = browser
        super.init()
        attach(WKWebView(frame: .zero, configuration: configuration))
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host() ?? "새 탭"
    }

    @discardableResult
    func wake() -> WKWebView {
        lastShown = Date()
        if let webView { return webView }
        let view = WKWebView(frame: .zero, configuration: Browser.configuration)
        attach(view)
        if let savedState {
            view.interactionState = savedState as NSData
        } else if let url {
            view.load(URLRequest(url: url))
        }
        savedState = nil
        return view
    }

    func sleep() {
        guard let webView else { return }
        savedState = webView.interactionState as? Data
        url = webView.url ?? url
        webView.stopLoading()
        webView.removeFromSuperview()
        observations.removeAll()
        self.webView = nil
        isLoading = false
        progress = 0
    }

    func load(_ url: URL) {
        self.url = url
        wake().load(URLRequest(url: url))
    }

    /// What gets written to disk to restore the tab at the next launch.
    var sessionState: Data? { (webView?.interactionState as? Data) ?? savedState }

    private func attach(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.isInspectable = true
        view.underPageBackgroundColor = .clear
        observations = [
            view.observe(\.title) { [weak self] v, _ in Task { @MainActor in if let t = v.title, !t.isEmpty { self?.title = t } } },
            view.observe(\.url) { [weak self] v, _ in Task { @MainActor in if let u = v.url { self?.url = u } } },
            view.observe(\.isLoading) { [weak self] v, _ in Task { @MainActor in self?.isLoading = v.isLoading } },
            view.observe(\.estimatedProgress) { [weak self] v, _ in Task { @MainActor in self?.progress = v.estimatedProgress } },
            view.observe(\.canGoBack) { [weak self] v, _ in Task { @MainActor in self?.canGoBack = v.canGoBack } },
            view.observe(\.canGoForward) { [weak self] v, _ in Task { @MainActor in self?.canGoForward = v.canGoForward } },
        ]
        webView = view
    }

    private func loadFavicon() {
        guard let webView, let host = webView.url?.host() else { return }
        if let cached = browser?.favicons[host] { favicon = cached; return }
        let script = """
        (() => { const l = document.querySelector('link[rel~="icon"][sizes="32x32"], link[rel~="icon"], link[rel="apple-touch-icon"]');
          return l ? l.href : location.origin + '/favicon.ico'; })()
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let href = value as? String, let iconURL = URL(string: href), ["http", "https"].contains(iconURL.scheme ?? "") else { return }
            URLSession.shared.dataTask(with: iconURL) { data, _, _ in
                guard let data, let image = NSImage(data: data), image.isValid else { return }
                Task { @MainActor in
                    self?.browser?.favicons[host] = image
                    self?.browser?.storeIcon(image, host: host)
                    if self?.url?.host() == host { self?.favicon = image }
                }
            }.resume()
        }
    }
}

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if action.shouldPerformDownload { return (.download, preferences) }
        if let url = action.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "data", "blob", "file", "javascript"].contains(scheme) {
            // mailto:, zoommtg: and the like go to their apps, but only when the user clicked.
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            return (.cancel, preferences)
        }
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command), let url = action.request.url {
            browser?.openTab(url: url, activate: action.modifierFlags.contains(.shift), after: self)
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.isForMainFrame && !response.canShowMIMEType ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = Downloads.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = Downloads.shared
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let host = webView.url?.host(), let cached = browser?.favicons[host] { favicon = cached }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadFavicon()
        if let url = webView.url?.absoluteString { Library.shared.recordVisit(url: url, title: webView.title ?? "") }
        checkForLogins()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled, nsError.domain != "WebKitErrorDomain" || nsError.code != 102 else { return }
        let failing = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        let message = nsError.localizedDescription.replacingOccurrences(of: "<", with: "&lt;")
        let address = (failing?.absoluteString ?? "").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        webView.loadHTMLString("""
        <meta name="color-scheme" content="light dark"><title>페이지를 열 수 없어요</title>
        <body style="font: 15px -apple-system; display: grid; place-content: center; height: 90vh; text-align: center; color: #888">
        <h2 style="color: CanvasText; font-weight: 600">페이지를 열 수 없어요</h2><p>\(message)</p><p style="font-size: 12px">\(address)</p>
        </body>
        """, baseURL: nil)
        if let failing { url = failing }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        browser?.openTab(configuration: configuration, after: self).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser?.close(id)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

/// Saves downloads to ~/Downloads under a name that doesn't overwrite anything.
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            n += 1
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        return candidate
    }

    func downloadDidFinish(_ download: WKDownload) {
        NSSound(named: "Glass")?.play()
    }
}
