import AppKit
import WebKit

struct ToolResult {
    var content: [[String: Any]]
    var isError = false

    static func text(_ text: String, error: Bool = false) -> ToolResult {
        ToolResult(content: [["type": "text", "text": text]], isError: error)
    }

    var json: [String: Any] { ["content": content, "isError": isError] }
}

/// The browser tools an AI agent gets, described once for MCP and carried out on the main actor.
enum ToolCatalog {
    private static let tabID: [String: Any] = ["type": "integer", "description": "Tab id from list_tabs. Defaults to the tab the user is looking at."]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        var props = properties
        if !["list_tabs", "open_tab", "read_tabs"].contains(name) { props["tab_id"] = tabID }
        return ["name": name, "description": description, "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    static let maxTabsPerRead = 10

    static let definitions: [[String: Any]] = [
        tool("list_tabs", "List the open tabs with their ids, titles and URLs, and which one is active."),
        tool("open_tab", "Open a new tab with a URL or a search query and show it.", ["url": ["type": "string", "description": "URL, domain, or search words"]], required: ["url"]),
        tool("switch_tab", "Show a tab to the user.", required: ["tab_id"]),
        tool("close_tab", "Close a tab.", required: ["tab_id"]),
        tool("navigate", "Load a URL or search query in a tab and wait for it to load.", ["url": ["type": "string", "description": "URL, domain, or search words"]], required: ["url"]),
        tool("go_back", "Go back in the tab's history."),
        tool("go_forward", "Go forward in the tab's history."),
        tool("reload", "Reload the tab."),
        tool("read_page", "Read the page: title, URL, scroll position, a numbered list of interactive elements, and the visible text. Use the element numbers with click and type_text.",
             ["max_chars": ["type": "integer", "description": "Maximum characters of page text (default 12000)"]]),
        tool("read_tabs", "Read several tabs at once: each one's title, URL and visible text, without the numbered elements. Use it to compare or combine tabs instead of switching between them; use read_page on a tab before clicking in it.",
             ["tab_ids": ["type": "array", "items": ["type": "integer"], "description": "Tab ids from list_tabs (at most \(maxTabsPerRead))"],
              "max_chars": ["type": "integer", "description": "Maximum characters of text per tab (default 6000)"]], required: ["tab_ids"]),
        tool("click", "Click an element by its number from the latest read_page.", ["element_id": ["type": "integer"]], required: ["element_id"]),
        tool("type_text", "Replace the text of an input, text area or editable element (by number from read_page). Set submit to press Enter afterwards.",
             ["element_id": ["type": "integer"], "text": ["type": "string"], "submit": ["type": "boolean"]], required: ["element_id", "text"]),
        tool("scroll", "Scroll the page.", ["direction": ["type": "string", "enum": ["down", "up", "top", "bottom"]]], required: ["direction"]),
        tool("screenshot", "Take a screenshot of the visible part of the page."),
    ]

    @MainActor
    /// `caller` tells apart the chat panel and each MCP connection: what one has read doesn't count for another.
    static func call(_ name: String, _ args: [String: Any], caller: String) async -> ToolResult {
        if name == "list_tabs" {
            guard let browser = Browser.recent else { return .text("No tabs are open.") }
            for tab in browser.tabs { Approvals.noteRead(tab, caller: caller) }
            return listTabs(browser)
        }
        if name == "open_tab" {
            guard let url = webURL(args["url"]) else { return .text("Give an http(s) URL, a domain, or search words.", error: true) }
            guard await Approvals.allowNavigation(url) else { return declined }
            let tab = (Browser.recent ?? BrowserWindow.open()).openTab(url: url)
            defer { Approvals.noteRead(tab, caller: caller) }
            await waitForLoad(tab)
            return .text("Opened tab #\(tab.id): \(tab.displayTitle) — \(tab.url?.absoluteString ?? "")")
        }
        if name == "read_tabs" { return await readTabs(args, caller: caller) }
        if args["tab_id"] != nil && int(args["tab_id"]) == nil { return .text("tab_id must be a number.", error: true) }
        // Tab ids are unique across windows: one listed earlier is found even after another window came to the front.
        let tab = int(args["tab_id"]).map(findTab) ?? Browser.recent?.active
        guard let tab, let browser = tab.browser else {
            return .text(args["tab_id"] == nil ? "No tab is open. Use open_tab first." : "No tab with that id.", error: true)
        }
        // Only the tab in front of the user goes without asking.
        let needsApproval = (tab.id != browser.activeID || browser !== Browser.recent) && name != "close_tab"
        if needsApproval {
            guard await Approvals.allowTab(tab, caller: caller, reading: name == "read_page" || name == "screenshot") else { return declined }
        }
        let approvedHost = tab.url?.host()?.lowercased()
        // Every answer below carries the tab's title, address or content.
        defer { if name != "close_tab" { Approvals.noteRead(tab, caller: caller) } }
        let webView = tab.wake()
        switch name {
        case "switch_tab":
            browser.activate(tab.id)
            return .text("Showing tab #\(tab.id): \(tab.displayTitle)")
        case "close_tab":
            browser.close(tab.id)
            return .text("Closed tab #\(tab.id).")
        case "navigate":
            guard let url = webURL(args["url"]) else { return .text("Give an http(s) URL, a domain, or search words.", error: true) }
            guard await Approvals.allowNavigation(url) else { return declined }
            tab.load(url)
            await waitForLoad(tab)
            return .text("Now at: \(tab.displayTitle) — \(tab.url?.absoluteString ?? "")")
        case "go_back", "go_forward", "reload":
            if name == "go_back" { webView.goBack() } else if name == "go_forward" { webView.goForward() } else { webView.reload() }
            await waitForLoad(tab)
            return .text("Now at: \(tab.displayTitle) — \(tab.url?.absoluteString ?? "")")
        case "read_page":
            let result = await run(PageScripts.read, ["maxChars": int(args["max_chars"]) ?? 12000], in: webView)
            let host = readHost(result)
            if needsApproval, !(await Approvals.allowRead(tab, approvedHost: approvedHost, readHost: host, caller: caller)) { return declined }
            Approvals.noteRead(tab, readHost: host, caller: caller)
            return result
        case "click":
            guard let id = int(args["element_id"]) else { return .text("element_id is required.", error: true) }
            let before = webView.url
            let result = await run(PageScripts.click, ["id": id], in: webView)
            if result.isError { return result }
            await waitForLoad(tab, expectingChangeFrom: before)
            return .text("Clicked [\(id)]. Now at: \(tab.displayTitle) — \(tab.url?.absoluteString ?? ""). Element numbers may have changed; read the page again before using them.")
        case "type_text":
            guard let id = int(args["element_id"]), let text = args["text"] as? String else { return .text("element_id and text are required.", error: true) }
            guard await Approvals.allowTyping(text, into: tab, caller: caller) else { return declined }
            let before = webView.url
            let result = await run(PageScripts.type, ["id": id, "text": text, "submit": args["submit"] as? Bool ?? false], in: webView)
            if result.isError || args["submit"] as? Bool != true { return result }
            await waitForLoad(tab, expectingChangeFrom: before)
            return .text("Typed into [\(id)] and pressed Enter. Now at: \(tab.displayTitle) — \(tab.url?.absoluteString ?? "")")
        case "scroll":
            return await run(PageScripts.scroll, ["direction": args["direction"] as? String ?? "down"], in: webView)
        case "screenshot":
            Approvals.noteRead(tab, caller: caller)
            return await screenshot(webView)
        default:
            return .text("Unknown tool \(name).", error: true)
        }
    }

    /// Tab ids are unique across windows. Private windows are not the AI's to use.
    @MainActor
    static func findTab(_ id: Int) -> Tab? {
        Browser.all.lazy.filter { !$0.isPrivate }.compactMap { $0.tabs.first { $0.id == id } }.first
    }

    @MainActor
    private static func readTabs(_ args: [String: Any], caller: String) async -> ToolResult {
        guard let values = args["tab_ids"] as? [Any], !values.isEmpty, values.allSatisfy({ int($0) != nil }) else {
            return .text("tab_ids must be a list of tab ids.", error: true)
        }
        let ids = values.compactMap(int).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        guard ids.count <= maxTabsPerRead else { return .text("Read at most \(maxTabsPerRead) tabs at a time.", error: true) }
        let maxChars = min(max(int(args["max_chars"]) ?? 6000, 200), 30000)
        var sections: [String] = []
        for id in ids {
            let heading = "=== Tab #\(id) ===\n"
            guard let tab = findTab(id), let browser = tab.browser else {
                sections.append(heading + "No tab with that id.")
                continue
            }
            let inFront = tab.id == browser.activeID && browser === Browser.recent
            if !inFront, !(await Approvals.allowTab(tab, caller: caller, reading: true)) {
                sections.append(heading + "The user declined this tab. Don't retry it.")
                continue
            }
            let approvedHost = tab.url?.host()?.lowercased()
            let wasAsleep = tab.isAsleep
            let webView = tab.wake()
            if wasAsleep { await waitForLoad(tab) }
            let result = await run(PageScripts.readText, ["maxChars": maxChars], in: webView)
            let host = readHost(result)
            if !inFront, !(await Approvals.allowRead(tab, approvedHost: approvedHost, readHost: host, caller: caller)) {
                sections.append(heading + "The user declined this tab. Don't retry it.")
                continue
            }
            Approvals.noteRead(tab, readHost: host, caller: caller)
            sections.append(heading + (result.content.first?["text"] as? String ?? ""))
        }
        return .text(sections.joined(separator: "\n\n"))
    }

    /// The site a read's text came from, by its "URL:" line: the page itself says where it was when it was read.
    static func readHost(_ result: ToolResult) -> String? {
        let text = result.content.first?["text"] as? String ?? ""
        return text.split(separator: "\n").first { $0.hasPrefix("URL: ") }.flatMap { URL(string: String($0.dropFirst(5)))?.host()?.lowercased() }
    }

    private static let declined = ToolResult.text("The user declined this in Changmun. Don't retry it; tell the user what you wanted to do.", error: true)

    /// The AI only ever opens web pages: never file:, data: or other schemes a page could talk it into.
    static func webURL(_ value: Any?) -> URL? {
        guard let input = value as? String, let url = AddressInput.resolve(input), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as Double where v == v.rounded(): return Int(v)
        case let v as String: return Int(v.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    @MainActor
    private static func listTabs(_ browser: Browser) -> ToolResult {
        if browser.tabs.isEmpty { return .text("No tabs are open.") }
        let lines = browser.tabs.map { tab in
            "\(tab.id == browser.activeID ? "*" : " ") #\(tab.id) \(tab.displayTitle) — \(tab.url?.absoluteString ?? "about:blank")\(tab.isAsleep ? " (asleep)" : "")"
        }
        return .text("Tabs (* = the one the user is looking at):\n" + lines.joined(separator: "\n"))
    }

    @MainActor
    private static func run(_ script: String, _ arguments: [String: Any], in webView: WKWebView) async -> ToolResult {
        await withTimeout(seconds: 20, fallback: .text("Error: the page did not answer in time (a dialog may be open).", error: true)) { finish in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value):
                    let text = value as? String ?? "\(value)"
                    finish(.text(text, error: text.hasPrefix("Error:")))
                case .failure(let error):
                    finish(.text("Error: \(error.localizedDescription)", error: true))
                }
            }
        }
    }

    /// Waits for a WebKit callback that may never come (a page blocked on an alert, a view not on screen).
    @MainActor
    static func withTimeout<T>(seconds: Double, fallback: T, _ start: (@escaping (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { continuation in
            var done = false
            let finish: (T) -> Void = { value in
                DispatchQueue.main.async {
                    guard !done else { return }
                    done = true
                    continuation.resume(returning: value)
                }
            }
            start(finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish(fallback) }
        }
    }

    @MainActor
    private static func screenshot(_ webView: WKWebView) async -> ToolResult {
        let image: NSImage? = await withTimeout(seconds: 10, fallback: nil) { finish in
            webView.takeSnapshot(with: nil) { image, _ in finish(image) }
        }
        guard let image, let jpeg = jpegData(image, maxWidth: 1280) else { return .text("Error: the page could not be captured.", error: true) }
        return ToolResult(content: [["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]])
    }

    private static func jpegData(_ image: NSImage, maxWidth: CGFloat) -> Data? {
        let scale = min(1, maxWidth / max(image.size.width, 1))
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    /// Waits until the tab stops loading (at most ten seconds). After a click, gives a navigation a moment to start.
    @MainActor
    static func waitForLoad(_ tab: Tab, expectingChangeFrom before: URL? = nil) async {
        try? await Task.sleep(for: .milliseconds(before == nil ? 250 : 500))
        let deadline = Date().addingTimeInterval(10)
        while tab.isLoading && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// What the AI may do without asking. A page that injects instructions could otherwise have the AI carry what it
/// read elsewhere (another tab, an earlier page in the chat) to the attacker: in a URL it opens, or typed into the
/// attacker's own page. So the AI acts freely only on the tab the user is looking at, opens only addresses that carry
/// nothing new, and types freely only where it has read nothing from another site. The rest is asked in the app,
/// for every caller (the chat panel and MCP clients alike).
@MainActor
enum Approvals {
    /// Tabs the user let the AI use, each together with the site it was on then.
    private static var tabs = Set<String>()
    /// Tabs the user attached in the chat panel, which the panel may read.
    private static var attached = Set<String>()
    private static var urls = Set<String>()
    /// Per caller, the sites whose titles, addresses or content the AI has been given since its chat started.
    private static var readHosts: [String: Set<String>] = [:]
    static var timeout: TimeInterval = 90

    /// A tab and the site it is on, or the site given when that is where its content came from.
    private static func key(_ tab: Tab, host: String? = nil) -> String {
        "\(tab.id)|\(host ?? tab.url?.host()?.lowercased() ?? "")"
    }

    /// The tabs attached in the chat panel: the panel reads them without asking, as long as they stay on the same site.
    static func attach(_ tabs: [Tab]) {
        attached = Set(tabs.map { key($0) })
    }

    static func allowTab(_ tab: Tab, caller: String, reading: Bool = false, host: String? = nil) async -> Bool {
        guard Preferences.shared.aiApprovals else { return true }
        let key = key(tab, host: host)
        if tabs.contains(key) || (reading && caller == ChatStore.caller && attached.contains(key)) { return true }
        let allowed = await ask(String(localized: "The AI wants to use a tab you aren't looking at"),
                                "#\(tab.id) \(tab.displayTitle.prefix(80))\n\(host ?? tab.url?.host() ?? "")\n\n" + String(localized: "If you allow it, you won't be asked again while this tab stays on this site."))
        if allowed { tabs.insert(key) }
        return allowed
    }

    /// A tab approved while asleep or loading may have ended up on another site by the time it was read; what it
    /// gave is held back unless the site it really came from is approved too. When the page named no site (an error,
    /// a page without an address), the tab's own site stands in, and an unknown one is asked about.
    static func allowRead(_ tab: Tab, approvedHost: String?, readHost: String?, caller: String) async -> Bool {
        let host = readHost ?? tab.url?.host()?.lowercased()
        if let host, host == approvedHost { return true }
        return await allowTab(tab, caller: caller, reading: true, host: host)
    }

    static func allowNavigation(_ url: URL) async -> Bool {
        guard Preferences.shared.aiApprovals else { return true }
        if isFree(url, knownURL: knownURL, knownHost: Library.shared.knowsHost) || urls.contains(url.absoluteString) { return true }
        let allowed = await ask(String(localized: "The AI wants to open this address"),
                                "\(url.host() ?? "")\n\n\(url.absoluteString.prefix(300))\n\n" + String(localized: "Deny if the address carries content from another page or from the conversation."))
        if allowed { urls.insert(url.absoluteString) }
        return allowed
    }

    /// Addresses that can't carry anything the AI chose: a search on the search engine, an address already open,
    /// visited or bookmarked, and the front page of a site the user knows.
    nonisolated static func isFree(_ url: URL, knownURL: (String) -> Bool, knownHost: (String) -> Bool) -> Bool {
        guard let host = url.host()?.lowercased(), url.user == nil, url.password == nil else { return false }
        if isPlainSearch(url) { return true }
        if knownURL(url.absoluteString) { return true }
        let frontPage = (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil && url.port == nil
        return frontPage && knownHost(host)
    }

    /// Exactly what the search engine template makes of one query: no extra parameters, port or fragment.
    nonisolated static func isPlainSearch(_ url: URL) -> Bool {
        guard let template = URLComponents(string: AddressInput.searchTemplate), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let key = template.queryItems?.first(where: { $0.value == "%s" })?.name,
              let items = components.queryItems, items.count == 1, items[0].name == key, let query = items[0].value,
              let rebuilt = AddressInput.searchURL(query) else { return false }
        return rebuilt.absoluteString == url.absoluteString
    }

    private static func knownURL(_ address: String) -> Bool {
        Browser.all.contains { !$0.isPrivate && $0.tabs.contains { $0.url?.absoluteString == address } } || Library.shared.knowsURL(address)
    }

    static func noteRead(_ tab: Tab, caller: String) {
        noteRead(tab, readHost: nil, caller: caller)
    }

    /// Records a read by the site its text came from, or by the tab's own site when the page named none.
    static func noteRead(_ tab: Tab, readHost: String?, caller: String) {
        if let host = readHost ?? tab.url?.host()?.lowercased() { readHosts[caller, default: []].insert(host) }
    }

    /// Typing hands text to the page; after reading other sites, the user sees what would be typed and says yes.
    static func allowTyping(_ text: String, into tab: Tab, caller: String) async -> Bool {
        guard Preferences.shared.aiApprovals else { return true }
        let host = tab.url?.host()?.lowercased() ?? ""
        let others = readHosts[caller, default: []].subtracting([host])
        if others.isEmpty { return true }
        let target = host.isEmpty ? String(localized: "this page") : host
        let typed = String(text.prefix(300))
        let sites = others.sorted().prefix(5).joined(separator: ", ")
        return await ask(String(localized: "The AI wants to type into \(target)"),
                         String(localized: "Text to type:\n\(typed)\n\nSites read earlier in this conversation: \(sites)\nDeny if content from there is mixed in."))
    }

    /// A new chat starts without anything read; other callers keep theirs.
    static func forgetReads(caller: String) {
        readHosts[caller] = nil
    }

    private final class Once {
        var done = false
    }

    /// Asks on the browser window; no answer within `timeout` counts as no, so a late yes never runs a stale request.
    private static func ask(_ message: String, _ detail: String) async -> Bool {
        // Headless has nobody to ask, and its own profile holds nothing of the user's to leak.
        if Headless.isOn { return true }
        guard let window = Browser.recent?.window else { return false }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "Deny"))
        alert.addButton(withTitle: String(localized: "Allow"))
        NSApp.requestUserAttention(.informationalRequest)
        return await withCheckedContinuation { continuation in
            let once = Once()
            let finish = { (allowed: Bool) in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: allowed)
            }
            alert.beginSheetModal(for: window) { finish($0 == .alertSecondButtonReturn) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !once.done else { return }
                finish(false)
                window.endSheet(alert.window)
            }
        }
    }
}

/// Scripts run in an isolated JavaScript world: they share the page's DOM but not its variables.
enum PageScripts {
    /// A field holding a password, even after a "show password" button turned it into a text field.
    static let secretTest = "const isSecret = el => el.type === 'password' || el.hasAttribute('data-cm-secret') || /password/i.test(el.autocomplete || '');"

    static let read = secretTest + """

    document.querySelectorAll('[data-cm-id]').forEach(e => e.removeAttribute('data-cm-id'));
    const selector = 'a[href],button,input,textarea,select,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=radio],[role=option],[role=switch],[role=combobox],[role=textbox],[contenteditable=""],[contenteditable=true],[onclick]';
    const lines = [];
    let n = 0;
    for (const el of document.querySelectorAll(selector)) {
      const r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) continue;
      const style = getComputedStyle(el);
      if (style.visibility === 'hidden' || style.display === 'none' || el.type === 'hidden') continue;
      el.setAttribute('data-cm-id', ++n);
      const tag = el.tagName.toLowerCase();
      const isButtonInput = tag === 'input' && /^(submit|button|reset)$/.test(el.type);
      const raw = el.getAttribute('aria-label') || (tag === 'input' || tag === 'textarea' || tag === 'select' ? '' : el.innerText)
        || (isButtonInput ? el.value : '') || el.placeholder || el.title || el.alt || el.name || '';
      const label = raw.trim().replace(/\\s+/g, ' ').slice(0, 80);
      let kind = el.getAttribute('role') || tag;
      if (tag === 'input') kind = 'input[' + (el.type || 'text') + ']';
      let extra = '';
      if (tag === 'a') extra = ' -> ' + el.href.slice(0, 120);
      if ((tag === 'input' || tag === 'textarea') && !isSecret(el) && !isButtonInput && el.value) extra = ' value="' + el.value.slice(0, 60) + '"';
      if (isSecret(el)) extra = ' (password field)';
      if (tag === 'select' && el.selectedOptions[0]) extra = ' selected="' + el.selectedOptions[0].text.slice(0, 40) + '"';
      if (el.type === 'checkbox' || el.type === 'radio') extra = el.checked ? ' (checked)' : ' (unchecked)';
      const inView = r.bottom > 0 && r.top < innerHeight ? '' : ' (off screen)';
      lines.push('[' + n + '] ' + kind + ' "' + label + '"' + extra + inView);
      if (n >= 250) break;
    }
    const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n');
    const cut = text.length > maxChars ? text.slice(0, maxChars) + '\\n…(truncated)' : text;
    return 'Title: ' + document.title + '\\nURL: ' + location.href +
      '\\nScroll: ' + Math.round(scrollY) + ' of ' + document.documentElement.scrollHeight + ' (viewport ' + innerHeight + ')' +
      '\\n\\n--- Interactive elements ---\\n' + (lines.join('\\n') || '(none)') + '\\n\\n--- Page text ---\\n' + cut;
    """

    static let readText = """
    const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n');
    const cut = text.length > maxChars ? text.slice(0, maxChars) + '\\n…(truncated)' : text;
    return 'Title: ' + document.title + '\\nURL: ' + location.href + '\\n\\n' + cut;
    """

    static let click = """
    const el = document.querySelector('[data-cm-id="' + id + '"]');
    if (!el) return 'Error: element ' + id + ' is gone. Read the page again.';
    el.scrollIntoView({block: 'center', inline: 'center'});
    const r = el.getBoundingClientRect();
    const at = {bubbles: true, cancelable: true, view: window, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2};
    el.dispatchEvent(new PointerEvent('pointerdown', at));
    el.dispatchEvent(new MouseEvent('mousedown', at));
    if (el.focus) el.focus();
    el.dispatchEvent(new PointerEvent('pointerup', at));
    el.dispatchEvent(new MouseEvent('mouseup', at));
    el.click();
    return 'ok';
    """

    static let type = secretTest + """

    const el = document.querySelector('[data-cm-id="' + id + '"]');
    if (!el) return 'Error: element ' + id + ' is gone. Read the page again.';
    if (isSecret(el)) return 'Error: Changmun does not let the AI type into password fields. Ask the user to.';
    el.scrollIntoView({block: 'center'});
    el.focus();
    if (el.isContentEditable) {
      document.execCommand('selectAll', false);
      document.execCommand('insertText', false, text);
    } else if (el instanceof HTMLSelectElement) {
      const option = [...el.options].find(o => o.text.trim() === text || o.value === text);
      if (!option) return 'Error: no option "' + text + '". Options: ' + [...el.options].map(o => o.text.trim()).join(', ');
      el.value = option.value;
      el.dispatchEvent(new Event('change', {bubbles: true}));
    } else {
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
      el.dispatchEvent(new Event('input', {bubbles: true}));
      el.dispatchEvent(new Event('change', {bubbles: true}));
    }
    if (submit) {
      const key = {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true};
      const handled = !el.dispatchEvent(new KeyboardEvent('keydown', key));
      el.dispatchEvent(new KeyboardEvent('keypress', key));
      el.dispatchEvent(new KeyboardEvent('keyup', key));
      if (!handled && el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
    }
    return 'ok';
    """

    static let scroll = """
    const height = document.documentElement.scrollHeight;
    if (direction === 'top') scrollTo(0, 0);
    else if (direction === 'bottom') scrollTo(0, height);
    else scrollBy(0, (direction === 'up' ? -1 : 1) * innerHeight * 0.85);
    return 'Scrolled ' + direction + '. Now at ' + Math.round(scrollY) + ' of ' + height + ' (viewport ' + innerHeight + ').';
    """
}
