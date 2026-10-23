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
        props["title"] = stepTitleSchema
        if !["list_tabs", "open_tab", "read_tabs"].contains(name) { props["tab_id"] = tabID }
        return ["name": name, "description": description, "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    private static let stepTitleSchema: [String: Any] = ["type": "string", "description": "A few words, in the user's language, saying what this step is for (for example “Comparing prices”). The user sees it while you work."]

    /// Longest title the panel shows, in unicode scalars.
    static let maxStepTitle = 60

    /// The title the AI gave a step, made fit to show: model text, so it is one line, its invisible and look-alike characters are
    /// made visible and it is cut, as anything of the model's shown in a question. nil when there is none to show. It is only ever
    /// shown in the panel's progress line; no question and no decision is made with it.
    nonisolated static func stepTitle(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let shown = Approvals.shown(line, limit: maxStepTitle)
        guard !shown.text.isEmpty else { return nil }
        return shown.cut > 0 ? shown.text + "…" : shown.text
    }

    /// The title of the tool call under way, which the progress line shows in place of the words the app would make.
    @TaskLocal static var currentTitle: String?
    /// The tool being carried out: its scripts mark the page as driven by the app, unless it is a click (see AppScripts).
    @TaskLocal static var currentTool: String?

    static let maxTabsPerRead = 10
    /// All of a read_tabs call, approvals included, ends before the control server gives up on its caller.
    static let readDeadline: TimeInterval = 60

    static let definitions: [[String: Any]] = [
        tool("list_tabs", "List the open tabs of every space with their ids (and the space's name in brackets when there are several spaces), and which one is active. The tab in front and the tabs the user allowed you to use have their titles and URLs; any other tab is named by its site only."),
        tool("open_tab", "Open a new tab with a URL or a search query and show it.", ["url": ["type": "string", "description": "URL, domain, or search words"]], required: ["url"]),
        tool("switch_tab", "Show a tab to the user.", required: ["tab_id"]),
        tool("close_tab", "Close a tab.", required: ["tab_id"]),
        tool("navigate", "Load a URL or search query in a tab and wait for it to load.", ["url": ["type": "string", "description": "URL, domain, or search words"]], required: ["url"]),
        tool("go_back", "Go back in the tab's history."),
        tool("go_forward", "Go forward in the tab's history."),
        tool("reload", "Reload the tab."),
        tool("read_page", "Read the page: title, URL, scroll position, a numbered list of interactive elements, and the visible text, frames included (the content of a frame from another site is read when Changmun can reach it, and the page says so when it can't). Elements inside shadow DOM (web components) aren't listed: use click_at for those. Each element line carries its states in brackets ([checked] or [unchecked], [selected], [expanded] or [collapsed], [disabled], [focused], [pressed], [required], [invalid]) and the current value of a field or list (never of a password, code or card field). Use the element numbers with click, type_text, press_key, select_option, hover and drag.",
             ["max_chars": ["type": "integer", "description": "Maximum characters of page text (default 12000)"]]),
        tool("read_tabs", "Read several tabs at once: each one's title, URL and visible text, without the numbered elements. Use it to compare or combine tabs instead of switching between them; use read_page on a tab before clicking in it.",
             ["tab_ids": ["type": "array", "items": ["type": "integer"], "description": "Tab ids from list_tabs (at most \(maxTabsPerRead))"],
              "max_chars": ["type": "integer", "description": "Maximum characters of text per tab (default 6000)"]], required: ["tab_ids"]),
        tool("click", "Click an element by its number from the latest read_page. If it looks like it pays, orders, sends, posts, replies, comments, shares, uploads, grants access, deletes or cancels, Changmun asks the user every time; if it looks like a cookie banner or a setting (save, clear, reset, block, enable), Changmun asks the user (once per site when the user allows the site for the chat). After the page you are working on has read other sites, Changmun also asks the user before every click, key press, hover, drag, typed text and chosen option (once per site when the user allows the site for the chat).", ["element_id": ["type": "integer"]], required: ["element_id"]),
        tool("click_at", "Click the element at a point of the visible page, for things read_page doesn't list (a canvas, a map, a custom control). x and y are CSS pixels from the top left of the visible page, which is exactly what a screenshot shows when its note says 1 pixel = 1 CSS pixel (otherwise divide the screenshot's pixels by the scale it names; page zoom and the screen's pixel density don't matter). Says which element was hit. Points in frames work too, and it reaches elements inside open shadow DOM that read_page doesn't list.",
             ["x": ["type": "number", "description": "CSS pixels from the left edge of the visible page"], "y": ["type": "number", "description": "CSS pixels from the top edge of the visible page"]], required: ["x", "y"]),
        tool("type_text", "Replace the text of an input, text area or editable element (by number from read_page). Set submit to press Enter afterwards.",
             ["element_id": ["type": "integer"], "text": ["type": "string"], "submit": ["type": "boolean"]], required: ["element_id", "text"]),
        tool("press_key", "Press a key, with keydown, keypress and keyup events like a keyboard, on the element in focus or on the one given by element_id (focused first). Only these keys: \(AgentKey.names.joined(separator: ", ")); with any of the modifiers \(AgentKey.modifierNames.joined(separator: ", ")). Use type_text for text. What the page doesn't handle itself is done as a browser would: Enter activates a button or link and submits a form, Tab moves focus, Escape closes a dialog, arrows and Home/End move the cursor, change a select or scroll, Backspace and Delete edit a text field, Space activates a button or scrolls. Combinations with alt, ctrl or meta only reach the page's own handlers.",
             ["key": ["type": "string", "enum": AgentKey.names], "modifiers": ["type": "array", "items": ["type": "string", "enum": AgentKey.modifierNames]],
              "element_id": ["type": "integer", "description": "Focus this element first (number from read_page)"]], required: ["key"]),
        tool("select_option", "Choose an option of a select list by its visible text or its value (also for custom listboxes and comboboxes, whose options are then clicked). Fires input and change.",
             ["element_id": ["type": "integer"], "option": ["type": "string", "description": "The option's text or value"]], required: ["element_id", "option"]),
        tool("hover", "Move the pointer over an element so that menus and tooltips open (pointer and mouse over, enter and move events). Then read the page again.", ["element_id": ["type": "integer"]], required: ["element_id"]),
        tool("drag", "Drag from an element or point to another and drop there: HTML5 drag and drop when the source is draggable, otherwise pointer and mouse events along the way (sliders, sortable lists). Both ends must be in the same frame.",
             ["from_element_id": ["type": "integer"], "from_x": ["type": "number"], "from_y": ["type": "number"],
              "to_element_id": ["type": "integer"], "to_x": ["type": "number"], "to_y": ["type": "number"]]),
        tool("sign_in", "Fill in the user's saved login for this site (the page's exact host, on https) into the sign-in form's username and password fields, firing input and change events. The user is asked every time, shown the site and the account, and confirms with Touch ID or their password; you are never given the password or the account name. It does not submit: click the form's sign-in button afterwards (that click is judged like any other). Refused in private windows, on http, with no saved login for the exact host, and in a frame of another site unless the login is for that frame's host. When several logins are saved for the site, the user picks the account in the question. If the sign-in wasn't done (no saved login, the user said no, or it couldn't be confirmed) you are told only that, whatever the reason: don't retry; tell the user. Asking again for a site the user declined shows no question but waits a few seconds before it gives the same answer. The account name is not given to you, but it can still reach you if the page itself shows it (a greeting, a filled field you read).",
             ["element_id": ["type": "integer", "description": "A field or button of the form (number from read_page). Default: the page's password field"]]),
        tool("wait_for", "Wait until the given text is on the page (or, with gone, no longer there), or, without text, until the page stops loading. Frames from other sites are searched too. Gives up after timeout seconds (default 10, at most 30). Use it instead of reading the page over and over.",
             ["text": ["type": "string"], "gone": ["type": "boolean", "description": "Wait for the text to disappear"], "timeout": ["type": "number", "description": "Seconds, default 10, at most 30"]]),
        tool("scroll", "Scroll the page.", ["direction": ["type": "string", "enum": ["down", "up", "top", "bottom"]]], required: ["direction"]),
        tool("screenshot", "Take a screenshot of the visible part of the page. Its note says how its pixels relate to the CSS pixels click_at takes. With labels, the page is read again and a numbered box is drawn on the picture over each interactive element in view (nothing is added to the page): the numbers are those read_page gives, so you can use them with click, type_text, select_option, hover, press_key and drag. The boxes follow the page's layout, which a hostile page can bend, so what read_page says about an element is authoritative.",
             ["labels": ["type": "boolean", "description": "Draw each interactive element's number over it"]]),
    ]

    @MainActor
    /// `caller` tells apart the chat panel and each MCP connection: what one has read doesn't count for another.
    static func call(_ name: String, _ args: [String: Any], caller: String) async -> ToolResult {
        await $currentTool.withValue(name) { await $currentTitle.withValue(stepTitle(args["title"])) { await perform(name, args, caller: caller) } }
    }

    @MainActor
    private static func perform(_ name: String, _ args: [String: Any], caller: String) async -> ToolResult {
        if name == "list_tabs" {
            guard let browser = Browser.recent else { return .text("No tabs are open.") }
            return listTabs(browser, caller: caller)
        }
        if name == "open_tab" {
            guard let url = webURL(args["url"]) else { return .text("Give an http(s) URL, a domain, or search words.", error: true) }
            AgentActivity.shared.step(String(localized: "Opening \(url.host() ?? "")"), caller: caller)
            defer { AgentActivity.shared.step(nil, caller: caller) }
            let session = Session(caller: caller)
            guard await Approvals.allowNavigation(url, caller: caller) else { return declined }
            if session.stopped { return stopped }
            let tab = (Browser.recent ?? BrowserWindow.open()).openTab(url: url)
            // A tab the AI opened itself is its own to use, on the site it opened.
            Approvals.allowOpened(tab, at: url, caller: caller)
            defer { Approvals.noteRead(tab, caller: caller) }
            await waitForLoad(tab)
            return .text("Opened tab #\(tab.id): \(tab.displayTitle) — \(tab.url?.absoluteString ?? "")")
        }
        if name == "read_tabs" { return await readTabs(args, caller: caller) }
        if args["tab_id"] != nil && int(args["tab_id"]) == nil { return .text("tab_id must be a number.", error: true) }
        if let problem = validate(name, args) { return .text(problem, error: true) }
        // Tab ids are unique across windows: one listed earlier is found even after another window came to the front.
        var tab = int(args["tab_id"]).map(findTab) ?? Browser.recent?.active
        if args["tab_id"] == nil, caller == ChatStore.caller {
            switch ChatStore.shared.runDefaultTab {
            case .front: break
            case .tab(let id): tab = findTab(id)
            case .none: return .text("Error: this message was written while the user was looking at a tab that has since gone to another site or been closed, so there is no default tab. Call list_tabs and pass the tab_id.", error: true)
            }
        }
        guard let tab, let browser = tab.browser else {
            return .text(args["tab_id"] == nil ? "No tab is open. Use open_tab first." : "No tab with that id.", error: true)
        }
        // Only the tab in front of the user goes without asking, closing a tab too. What was approved is the site it was on when
        // it was asked about, and the tools that act on the page check the page they reach against it.
        let needsApproval = tab.id != browser.activeID || browser !== Browser.recent
        let approvedHost = Approvals.site(of: tab.url)
        let session = Session(caller: caller, approved: needsApproval ? approvedHost ?? "" : nil)
        if needsApproval {
            guard await Approvals.allowTab(tab, caller: caller, reading: ["read_page", "screenshot", "wait_for"].contains(name)) else { return declined }
            if session.stopped { return stopped }
        }
        // Every answer below carries the tab's title, address or content.
        defer { if name != "close_tab" { Approvals.noteRead(tab, caller: caller) } }
        let webView = tab.wake()
        if name != "switch_tab" && name != "close_tab" { AgentActivity.shared.use(tab, caller: caller) }
        defer { AgentActivity.shared.step(nil, caller: caller) }
        switch name {
        case "switch_tab":
            browser.activate(tab.id)
            return .text("Showing tab #\(tab.id): \(tab.displayTitle)")
        case "close_tab":
            let lastClosed = browser.closedTabs.last?.id
            browser.close(tab.id)
            // The panel offers to bring back what its AI closed.
            if caller == ChatStore.caller, let closed = browser.closedTabs.last, closed.id != lastClosed { ChatStore.shared.noteClosed(closed.id, in: browser) }
            return .text("Closed tab #\(tab.id).")
        case "navigate":
            guard let url = webURL(args["url"]) else { return .text("Give an http(s) URL, a domain, or search words.", error: true) }
            AgentActivity.shared.step(String(localized: "Opening \(url.host() ?? "")"), caller: caller)
            guard await Approvals.allowNavigation(url, caller: caller) else { return declined }
            if session.stopped { return stopped }
            tab.load(url)
            await waitForLoad(tab)
            return .text("Now at: \(tab.displayTitle) — \(tab.url?.absoluteString ?? "")")
        case "go_back", "go_forward", "reload":
            // A page that came from a submitted form would send it again: that is not done for the AI.
            tab.agentHistoryMove = true
            tab.resubmitBlocked = false
            if name == "go_back" { webView.goBack() } else if name == "go_forward" { webView.goForward() } else { webView.reload() }
            await waitForLoad(tab)
            tab.agentHistoryMove = false
            if tab.resubmitBlocked {
                tab.resubmitBlocked = false
                return .text("Error: that page came from a submitted form, so going there (or reloading) would send the form again. Changmun didn't. Tell the user if they want it done.", error: true)
            }
            return .text(now(tab, caller: caller))
        case "read_page":
            AgentActivity.shared.step(tab.url?.host().map { String(localized: "Reading \($0)") } ?? String(localized: "Reading the page"), caller: caller)
            let (result, frameHosts) = await readPage(tab, webView, maxChars: int(args["max_chars"]) ?? 12000, session: session)
            let host = readHost(result)
            if needsApproval, !(await Approvals.allowRead(tab, approvedHost: approvedHost, readHost: host, caller: caller)) { return declined }
            if session.stopped { return stopped }
            Approvals.noteRead(tab, readHost: host, caller: caller)
            // What a frame of another site showed was read from that site, not from the page around it.
            for frameHost in frameHosts { Approvals.noteRead(tab, readHost: frameHost, caller: caller) }
            return result
        case "click":
            guard let id = int(args["element_id"]) else { return .text("element_id is required.", error: true) }
            return await clickElement(id, tab: tab, webView: webView, session: session)
        case "click_at":
            return await clickAt(args, tab: tab, webView: webView, session: session)
        case "type_text":
            guard let id = int(args["element_id"]), let text = args["text"] as? String else { return .text("element_id and text are required.", error: true) }
            return await typeText(id, text: text, submit: args["submit"] as? Bool ?? false, tab: tab, webView: webView, session: session)
        case "press_key":
            return await pressKey(args, tab: tab, webView: webView, session: session)
        case "select_option":
            return await selectOption(args, tab: tab, webView: webView, session: session)
        case "hover":
            guard let id = int(args["element_id"]) else { return .text("element_id is required.", error: true) }
            return await hover(id, tab: tab, webView: webView, session: session)
        case "drag":
            return await drag(args, tab: tab, webView: webView, session: session)
        case "wait_for":
            return await waitFor(args, tab: tab, webView: webView, session: session)
        case "sign_in":
            return await signIn(args, tab: tab, webView: webView, session: session)
        case "scroll":
            // Free of the questions the other ways of using a page are asked: it moves what is in view and nothing else. A page
            // can see which of four directions was chosen, which is all it can be told this way.
            AgentActivity.shared.step(String(localized: "Scrolling"), caller: caller)
            return await run(PageScripts.scroll, ["direction": args["direction"] as? String ?? "down"], in: webView)
        case "screenshot":
            AgentActivity.shared.step(String(localized: "Looking at the page"), caller: caller)
            Approvals.noteRead(tab, caller: caller)
            // A picture shows the frames of other sites on the page too.
            for frameHost in await shownFrameHosts(tab, webView) { Approvals.noteRead(tab, readHost: frameHost, caller: caller) }
            return await screenshot(tab, webView, labels: args["labels"] as? Bool ?? false, session: session)
        default:
            return .text("Unknown tool \(name).", error: true)
        }
    }

    /// Tab ids are unique across windows. Private windows are not the AI's to use.
    @MainActor
    static func findTab(_ id: Int) -> Tab? {
        Browser.all.lazy.filter { !$0.isPrivate }.compactMap { browser in browser.tabs.first { $0.id == id && browser.isVisibleToAI($0) } }.first
    }

    @MainActor
    private static func readTabs(_ args: [String: Any], caller: String) async -> ToolResult {
        guard let values = args["tab_ids"] as? [Any], !values.isEmpty, values.allSatisfy({ int($0) != nil }) else {
            return .text("tab_ids must be a list of tab ids.", error: true)
        }
        let ids = values.compactMap(int).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        guard ids.count <= maxTabsPerRead else { return .text("Read at most \(maxTabsPerRead) tabs at a time.", error: true) }
        let maxChars = min(max(int(args["max_chars"]) ?? 6000, 200), 30000)
        let session = Session(caller: caller)
        let deadline = Date().addingTimeInterval(readDeadline)
        var sections: [Int: String] = [:]
        var reads: [(tab: Tab, approvedHost: String?, inFront: Bool, wasShown: Date?)] = []
        // Approve and wake every tab first, so the sleeping ones load at the same time.
        for id in ids {
            guard let tab = findTab(id), let browser = tab.browser else {
                sections[id] = "No tab with that id."
                continue
            }
            if Date() >= deadline {
                sections[id] = "Not reached in time. Try again."
                continue
            }
            let inFront = tab.id == browser.activeID && browser === Browser.recent
            let asked = Approvals.site(of: tab.url)
            if !inFront, !(await Approvals.allowTab(tab, caller: caller, reading: true)) {
                sections[id] = "The user declined this tab. Don't retry it."
                continue
            }
            if session.stopped { break }
            // A tab woken only to be read goes back to sleep, looking as if nobody had shown it.
            reads.append((tab, asked, inFront, tab.isAsleep ? tab.lastShown : nil))
            tab.wake()
        }
        for read in reads {
            let tab = read.tab
            if read.wasShown != nil { await waitForLoad(tab, within: min(10, deadline.timeIntervalSinceNow)) }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let webView = tab.webView else {
                sections[tab.id] = "This tab didn't load in time. Try again."
                continue
            }
            let result = await run(PageScripts.readText, ["maxChars": maxChars], in: webView, timeout: min(20, remaining))
            let host = readHost(result)
            if !read.inFront, !(await Approvals.allowRead(tab, approvedHost: read.approvedHost, readHost: host, caller: caller)) {
                sections[tab.id] = "The user declined this tab. Don't retry it."
                continue
            }
            if session.stopped { break }
            Approvals.noteRead(tab, readHost: host, caller: caller)
            sections[tab.id] = result.content.first?["text"] as? String ?? ""
        }
        for read in reads {
            if let shown = read.wasShown, read.tab.browser?.isShown(read.tab) != true {
                read.tab.sleep()
                read.tab.lastShown = shown
            }
        }
        if session.stopped { return stopped }
        return .text(ids.map { "=== Tab #\($0) ===\n" + (sections[$0] ?? "") }.joined(separator: "\n\n"))
    }

    /// The site a read's text came from, by its "URL:" line: the page itself says where it was when it was read.
    static func readHost(_ result: ToolResult) -> String? {
        let text = result.content.first?["text"] as? String ?? ""
        return text.split(separator: "\n").first { $0.hasPrefix("URL: ") }.flatMap { Approvals.site(of: URL(string: String($0.dropFirst(5)))) }
    }

    /// Where a tab is, for the answer of a tool that moved it. A tab the user isn't looking at that ended up on a site it wasn't
    /// approved for gives neither its title nor its address: using it again asks about the new site.
    @MainActor
    static func now(_ tab: Tab, caller: String) -> String {
        guard Approvals.mayShow(tab, caller: caller) else { return "The tab is now on another site, which the user hasn't allowed yet. Use the tab again to ask them." }
        return "Now at: \(tab.displayTitle) — \(tab.url?.absoluteString ?? "")"
    }

    static let declined = ToolResult.text("The user declined this in Changmun. Don't retry it; tell the user what you wanted to do.", error: true)

    /// What the user's headless app tells an AI whose pay, send, post or delete it refused, in place of a person who would be asked.
    static let needsAPerson = ToolResult.text("Refused: this looks like paying, ordering, sending, posting, deleting or granting access, and the headless Changmun never does that without a person. Don't retry it; tell the user what you wanted to do.", error: true)

    /// What an action the user (or, in the user's headless app, the rule for it) said no to answers with.
    static func declined(_ tier: IrreversibleAction.Tier, markupOnly: Bool = false, inUserHeadless: Bool = Headless.isUser) -> ToolResult {
        inUserHeadless && (tier == .high || markupOnly) ? needsAPerson : declined
    }

    /// The AI only ever opens web pages: never file:, data: or other schemes a page could talk it into.
    static func webURL(_ value: Any?) -> URL? {
        guard let input = value as? String, let url = AddressInput.resolve(input), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as Double where v == v.rounded(): return Int(exactly: v)
        case let v as String: return Int(v.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// The tabs, each with its title and address if the caller may be told them (the tab in front, or one it was allowed to use on
    /// the site it is on); any other tab is named only by its site, and nothing is recorded as read for it, since nothing of it was
    /// given. What was told of the others is recorded, as every answer with a tab's title or address is.
    @MainActor
    private static func listTabs(_ browser: Browser, caller: String) -> ToolResult {
        // The tabs of every space but another profile's, which keeps its logins apart.
        let visible = browser.tabs.filter { browser.isVisibleToAI($0) }
        if visible.isEmpty { return .text("No tabs are open.") }
        // With more than one space, each tab says which one it is in.
        let named = browser.spaces.spaces.count > 1 && !browser.isPrivate
        let lines = visible.map { tab in
            let space = named ? " [\(browser.spaces.space(tab.spaceID).name)]" : ""
            let mark = "\(tab.id == browser.activeID ? "*" : " ") #\(tab.id)\(space)"
            guard Approvals.mayShow(tab, caller: caller) else {
                let site = Approvals.site(of: tab.url).map { Approvals.shown($0, limit: 100).text } ?? "no page"
                return "\(mark) (a tab on \(site); its title and address are shown once you use it and the user allows it)\(tab.isAsleep ? " (asleep)" : "")"
            }
            Approvals.noteRead(tab, caller: caller)
            return "\(mark) \(tab.displayTitle) — \(tab.url?.absoluteString ?? "about:blank")\(tab.isAsleep ? " (asleep)" : "")"
        }
        return .text("Tabs (* = the one the user is looking at):\n" + lines.joined(separator: "\n"))
    }

    /// What a script run in the page is answered when the page gave no answer in time.
    static let didNotAnswer = "Error: the page did not answer in time (a dialog may be open)."

    /// Runs a script in the page, or in `frame` (a frame of another site, which the page's own scripts can't enter).
    @MainActor
    static func run(_ script: String, _ arguments: [String: Any], in webView: WKWebView, frame: WKFrameInfo? = nil, timeout: Double = 20) async -> ToolResult {
        await withTimeout(seconds: timeout, fallback: .text(didNotAnswer, error: true)) { finish in
            webView.appScript(script, arguments: arguments, in: frame, userLike: currentTool.map(AppScripts.clickTools.contains) ?? false) { result in
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

    /// The picture is made as wide as the visible page is in CSS pixels (up to 1280), so a point of it is a point for
    /// click_at whatever the page zoom or the screen's pixel density; a wider page is scaled down, and the note says by how much.
    @MainActor
    private static func screenshot(_ tab: Tab, _ webView: WKWebView, labels: Bool, session: Session) async -> ToolResult {
        guard labels else { return await picture(tab, webView).0 }
        // The page is read again, so that the numbers are the ones a read_page gives now, and nobody else's read renumbers the
        // elements meanwhile. Nothing is put into the page: where each numbered element is comes from its own scripts, and the boxes
        // are drawn on the picture afterwards, out of the page's reach.
        return await tab.agent.gate.run {
            let read = await readPageAlone(tab, webView, maxChars: 200, session: session)
            if read.0.isError { return read.0 }
            let placed = await labelBoxes(tab, webView)
            var (result, drawn) = await picture(tab, webView, labels: placed.boxes)
            if !result.isError {
                var note: String
                if placed.boxes.isEmpty {
                    note = "No interactive element is in view, so no numbers are drawn."
                } else if drawn == 0 {
                    // The size of the page was not known, so the boxes could not be put at their places.
                    note = "No numbers could be drawn on this picture (the size of the page was not known), so it has no boxes. Use the element numbers of the read_page that was just taken."
                } else {
                    note = "The boxes (\(drawn)) carry the element numbers of a read_page taken just now (the page was read again for the picture, so numbers from earlier reads are replaced): use them with click, type_text, select_option, hover, press_key and drag. Where the boxes are comes from the page's layout, which a page can bend: what read_page says of an element is authoritative."
                }
                if placed.unplaced > 0 {
                    note += " The elements of \(placed.unplaced) frame\(placed.unplaced == 1 ? "" : "s") from another site have no box, since where \(placed.unplaced == 1 ? "it is" : "they are") on the page could not be worked out: use their numbers from read_page."
                }
                result.content.append(["type": "text", "text": note])
            }
            return result
        } ?? stopped
    }

    /// A numbered element's place in the visible page, in CSS pixels from its top left.
    struct LabelBox: Equatable {
        var id: Int
        var x: Double, y: Double, width: Double, height: Double
    }

    /// Where a frame sits in the window: where its top left is, what one of its pixels is worth, and the part of it that shows.
    struct FramePlace: Equatable {
        var x: Double, y: Double, scale: Double
        var left: Double, top: Double, right: Double, bottom: Double
    }

    /// A box moved into the window from a frame's own pixels and cut at the part of the frame that shows; nil when none of it shows.
    static func placed(_ box: LabelBox, in place: FramePlace) -> LabelBox? {
        let left = max(place.x + place.scale * box.x, place.left), top = max(place.y + place.scale * box.y, place.top)
        let right = min(place.x + place.scale * (box.x + box.width), place.right), bottom = min(place.y + place.scale * (box.y + box.height), place.bottom)
        return right > left && bottom > top ? LabelBox(id: box.id, x: left, y: top, width: right - left, height: bottom - top) : nil
    }

    /// The place of a frame found inside another, from what the script of the outer one says (in its own pixels), in the window.
    static func nested(_ inner: [Double], in outer: FramePlace) -> FramePlace? {
        guard inner.count >= 7 else { return nil }
        let x = outer.x + outer.scale * inner[0], y = outer.y + outer.scale * inner[1]
        return FramePlace(x: x, y: y, scale: outer.scale * inner[2],
                          left: max(outer.left, outer.x + outer.scale * inner[3]), top: max(outer.top, outer.y + outer.scale * inner[4]),
                          right: min(outer.right, outer.x + outer.scale * inner[5]), bottom: min(outer.bottom, outer.y + outer.scale * inner[6]))
    }

    /// Where each element the latest read numbered is in the visible page, from the page's own scripts (and those of the frames of
    /// other sites that the read reached, whose places are taken from where the page puts their frames, also for a frame inside a
    /// frame). Only what is in view, and of a frame only the part of it that shows. `unplaced` is how many frames' elements get no box
    /// because where their frame is could not be worked out.
    @MainActor
    static func labelBoxes(_ tab: Tab, _ webView: WKWebView) async -> (boxes: [LabelBox], unplaced: Int) {
        func parse(_ result: ToolResult) -> (boxes: [LabelBox], frames: [String: [Double]])? {
            guard case .answered(let json) = look(result), let list = json["rects"] as? [[Double]] else { return nil }
            return (list.compactMap { $0.count == 5 ? LabelBox(id: Int($0[0]), x: $0[1], y: $0[2], width: $0[3], height: $0[4]) : nil }, json["frames"] as? [String: [Double]] ?? [:])
        }
        guard let page = parse(await run(PageScripts.rects, [:], in: webView, timeout: 5)) else { return ([], 0) }
        var boxes = page.boxes
        var places: [String: FramePlace] = [:]
        for (slot, frame) in page.frames {
            if let place = nested(frame, in: FramePlace(x: 0, y: 0, scale: 1, left: -.infinity, top: -.infinity, right: .infinity, bottom: .infinity)) { places[slot] = place }
        }
        var waiting = tab.agent.frames.known
        var unplaced = 0
        // A frame is asked once the place of the frame that holds it is known: the page's own frames first, then the ones inside them.
        var progress = true
        while progress && !waiting.isEmpty {
            progress = false
            for entry in waiting {
                guard let place = places[entry.slot] else { continue }
                waiting.removeAll { $0.slot == entry.slot }
                progress = true
                guard let inside = parse(await run(PageScripts.rects, [:], in: webView, frame: entry.frame, timeout: 5)) else {
                    unplaced += 1
                    continue
                }
                boxes += inside.boxes.compactMap { placed($0, in: place) }
                for (slot, frame) in inside.frames { if let inner = nested(frame, in: place) { places[slot] = inner } }
            }
        }
        return (boxes, unplaced + waiting.count)
    }

    /// Draws the boxes and their numbers into the picture being made, `scale` pixels to a CSS pixel, `height` pixels high (the same
    /// scale click_at's note names, so a box lands where the element is).
    @discardableResult
    private static func draw(_ boxes: [LabelBox], scale: CGFloat, height: CGFloat) -> Int {
        let red = NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
        var drawn = 0
        for box in boxes {
            drawn += 1
            let frame = NSRect(x: box.x * scale, y: height - (box.y + box.height) * scale, width: max(box.width * scale, 4), height: max(box.height * scale, 4))
            red.withAlphaComponent(0.10).setFill()
            frame.fill()
            red.setStroke()
            let outline = NSBezierPath(rect: frame.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            outline.stroke()
            let text = NSAttributedString(string: String(box.id), attributes: attributes)
            let tag = NSRect(x: frame.minX, y: frame.maxY - 16, width: max(16, text.size().width + 8), height: 16)
            red.setFill()
            tag.fill()
            text.draw(at: NSPoint(x: tag.minX + (tag.width - text.size().width) / 2, y: tag.minY + (16 - text.size().height) / 2))
        }
        return drawn
    }

    @MainActor
    private static func picture(_ tab: Tab, _ webView: WKWebView, labels: [LabelBox] = []) async -> (ToolResult, drawn: Int) {
        let size = await run("return JSON.stringify([innerWidth, innerHeight]);", [:], in: webView, timeout: 5).content.first?["text"] as? String
        let viewport = size.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Double] }.flatMap { $0.count == 2 && $0[0] >= 1 && $0[1] >= 1 ? $0 : nil }
        let configuration = WKSnapshotConfiguration()
        if let viewport { configuration.snapshotWidth = NSNumber(value: min(viewport[0], 1280)) }
        // What a field holds that is secret (a password shown by a "show" button) isn't in the picture, also in the frames of
        // other sites that were greeted (a card or code field in a payment frame).
        await runInPageAndFrames(PageScripts.maskSecrets, tab, webView)
        let image: NSImage? = await withTimeout(seconds: 10, fallback: nil) { finish in
            webView.takeSnapshot(with: configuration) { image, _ in finish(image) }
        }
        await runInPageAndFrames(PageScripts.unmaskSecrets, tab, webView)
        guard let image, let (jpeg, drawn) = jpegData(image, maxWidth: 1280, labels: labels, cssWidth: viewport?[0]) else { return (.text("Error: the page could not be captured.", error: true), 0) }
        var content: [[String: Any]] = [["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]]
        if let viewport {
            let pixels = min(image.size.width, 1280).rounded(), scale = pixels / viewport[0]
            content.append(["type": "text", "text": scale == 1 ? "Screenshot: \(Int(pixels)) x \(Int((image.size.height * min(1, 1280 / image.size.width)).rounded())) pixels, 1 pixel = 1 CSS pixel, so a point in it is the x and y for click_at."
                : "Screenshot: \(Int(pixels)) pixels wide for a page \(Int(viewport[0])) x \(Int(viewport[1])) CSS pixels: for click_at, divide a point's x and y by \(String(format: "%.3f", scale))."])
        }
        return (ToolResult(content: content), drawn)
    }

    /// Runs a script in the page and in every frame of another site the app can reach, all at once.
    @MainActor
    static func runInPageAndFrames(_ script: String, _ tab: Tab, _ webView: WKWebView) async {
        await withTaskGroup(of: Void.self) { group in
            for frame in [nil] + tab.agent.frames.known.map({ Optional($0.frame) }) {
                group.addTask { @MainActor in _ = await run(script, [:], in: webView, frame: frame, timeout: 3) }
            }
        }
    }

    /// The picture as a JPEG, and how many boxes were drawn on it (none when the width of the page in CSS pixels is not known).
    private static func jpegData(_ image: NSImage, maxWidth: CGFloat, labels: [LabelBox] = [], cssWidth: Double? = nil) -> (Data, drawn: Int)? {
        let scale = min(1, maxWidth / max(image.size.width, 1))
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        var drawn = 0
        if let cssWidth, cssWidth > 0 { drawn = draw(labels, scale: size.width / cssWidth, height: size.height) }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]).map { ($0, drawn) }
    }

    /// Waits until the tab stops loading (at most ten seconds). After a click, gives a navigation a moment to start.
    @MainActor
    static func waitForLoad(_ tab: Tab, expectingChangeFrom before: URL? = nil, within seconds: Double = 10) async {
        try? await Task.sleep(for: .milliseconds(before == nil ? 250 : 500))
        let deadline = Date().addingTimeInterval(seconds)
        while tab.isLoading && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// What the AI may do without asking. A page that injects instructions could otherwise have the AI carry what it
/// read elsewhere (another tab, an earlier page in the chat) to the attacker: in a URL it opens, or typed into the
/// attacker's own page. So the AI acts freely only on the tab the user is looking at, opens only addresses that carry
/// nothing new, and uses a page freely only where it has read nothing from another site. The rest is asked in the
/// app, for every caller (the chat panel and MCP clients alike). What looks like it pays, orders, sends, posts or
/// deletes is asked about every time, whatever else was allowed.
@MainActor
enum Approvals {
    /// Per caller, the tabs the user let it use, each together with the site it was on then.
    private static var tabs: [String: Set<String>] = [:]
    /// Tabs the user attached in the chat panel, each with the site it was on then; the panel may read them there.
    private static var attached: [Int: String] = [:]
    private static var urls: [String: Set<String>] = [:]
    /// Per caller, the sites whose titles, addresses or content the AI has been given since its chat started.
    private static var readHosts: [String: Set<String>] = [:]
    static var timeout: TimeInterval = 90

    /// Stands for a frame that has no site to name (a sandboxed frame, one that could not be asked): a site of its own.
    nonisolated static let unknownFrame = "\u{1}unknown-frame"

    /// The site an address is on, as what was read and allowed is remembered: its exact host, lowercased and in the ASCII form
    /// of an international name (www.example.com and shop.example.com are two sites, so are two sites on one hosting service),
    /// with the port when it isn't the scheme's own (another port is another site), and with "http://" in front for an
    /// unencrypted page (http and https are two sites); a page with no host (a file:, data: or blob: page) is a site by its
    /// scheme; nil for a blank page.
    nonisolated static func site(of url: URL?) -> String? {
        guard let url else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        guard var host = URLComponents(string: url.absoluteString)?.encodedHost?.lowercased(), !host.isEmpty else { return scheme.isEmpty || scheme == "about" ? nil : scheme + ":" }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let written = host.contains(":") ? "[\(host)]" : host, prefix = scheme == "http" ? "http://" : ""
        guard let port = url.port, !(port == 443 && scheme == "https"), !(port == 80 && scheme == "http") else { return prefix + written }
        return "\(prefix)\(written):\(port)"
    }

    /// The host name of a site as `site(of:)` writes it (without "http://" and the port): nil for a site that has none.
    nonisolated static func hostname(ofSite site: String) -> String? {
        guard hasSiteSyntax(site) else { return nil }
        var rest = Substring(site)
        if rest.hasPrefix("http://") { rest = rest.dropFirst(7) }
        if rest.hasPrefix("[") { return rest.firstIndex(of: "]").map { String(rest[rest.index(after: rest.startIndex)..<$0]) } }
        return rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    nonisolated private static func hasSiteSyntax(_ site: String) -> Bool {
        !site.isEmpty && site != unknownFrame && !(site.hasSuffix(":") && site.dropLast().allSatisfy(\.isLetter))
    }

    /// The site an origin names ("https://example.com:8443"): "" for an origin that has none (a sandboxed frame, a data: page).
    nonisolated static func site(ofOrigin origin: String) -> String {
        site(of: URL(string: origin)) ?? ""
    }

    /// Whether a site is one a user could allow for a chat: not "" and not a page that only has a scheme (file:).
    static func hasSite(_ site: String) -> Bool {
        !site.isEmpty && !(site.hasSuffix(":") && site.dropLast().allSatisfy(\.isLetter))
    }

    /// A text the page chose, kept from passing for the end of a quotation in a question: its quotation marks are made plain.
    nonisolated static func quotable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { "\"“”„‟«»「」『』`´".unicodeScalars.contains($0) ? "'" : $0 }))
    }

    /// A tab and the site it is on, or the site given when that is where its content came from.
    private static func key(_ tab: Tab, host: String? = nil) -> String {
        "\(tab.id)|\(host ?? site(of: tab.url) ?? "")"
    }

    /// Whether the title and address of a tab can be told to the caller as they are: the tab is in front of the user, or the
    /// caller was allowed to use it on the site it is on now.
    static func mayShow(_ tab: Tab, caller: String) -> Bool {
        guard Preferences.shared.aiApprovals, let browser = tab.browser else { return true }
        if tab.id == browser.activeID && browser === Browser.recent { return true }
        if caller == ChatStore.caller, attached[tab.id] == (site(of: tab.url) ?? "") { return true }
        return tabs[caller]?.contains(key(tab)) == true
    }

    /// A tab the AI opened itself is its to use, on the site it was opened on.
    static func allowOpened(_ tab: Tab, at url: URL, caller: String) {
        tabs[caller, default: []].insert(key(tab, host: site(of: url)))
    }

    /// What the AI chose (or a page named), as a question shows it, counted and cut by unicode scalars: line breaks and every
    /// character that is invisible or lets text pass for other text (controls, format and default-ignorable characters,
    /// variation selectors, tag characters, bidi controls, the Hangul fillers, the blank braille pattern) are made visible as a
    /// box, and a base character keeps at most `maxMarks` combining marks. What doesn't fit is said to be left out, with how
    /// much. `cut` is how many scalars are not shown, and `altered` is whether anything shown was replaced or left out of a
    /// run of marks: the user then sees something other than what the text is, which is as good as cut.
    nonisolated static func shown(_ text: String, limit: Int = 500) -> (text: String, cut: Int, altered: Bool) {
        let maxMarks = 3
        var clean: [Unicode.Scalar] = [], altered = false, marks = 0
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            let category = properties.generalCategory
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                marks = 0
                clean.append(scalar == "\t" ? "⇥" : "⏎")
            } else if category == .control || category == .lineSeparator || category == .paragraphSeparator || category == .format
                        || properties.isDefaultIgnorableCodePoint || properties.isVariationSelector || properties.isBidiControl
                        || [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800].contains(scalar.value) {
                marks = 0
                altered = true
                clean.append("▯")
            } else if category == .nonspacingMark || category == .spacingMark || category == .enclosingMark {
                marks += 1
                if marks <= maxMarks {
                    clean.append(scalar)
                } else {
                    if marks == maxMarks + 1 { clean.append("▯") }
                    altered = true
                }
            } else {
                marks = 0
                clean.append(scalar)
            }
        }
        var head = String.UnicodeScalarView()
        head.append(contentsOf: clean.prefix(limit))
        return (String(head), max(clean.count - limit, 0), altered)
    }

    /// `shown`, with the note about what was left out at its end.
    nonisolated static func shownWithNote(_ text: String, limit: Int = 500) -> (text: String, cut: Int, altered: Bool) {
        let (head, cut, altered) = shown(text, limit: limit)
        return (cut > 0 ? head + " " + String(localized: "…(\(cut) more characters are not shown)") : head, cut, altered)
    }

    /// Attaching records the tab's site once; attaching or detaching others never renews it, so a tab that has since
    /// moved to another site is asked about.
    static func attach(_ tab: Tab) {
        if attached[tab.id] == nil { attached[tab.id] = site(of: tab.url) ?? "" }
    }

    static func detach(_ id: Int) {
        attached[id] = nil
    }

    static func detachAll() {
        attached = [:]
    }

    static func allowTab(_ tab: Tab, caller: String, reading: Bool = false, host: String? = nil) async -> Bool {
        guard Preferences.shared.aiApprovals else { return true }
        let key = key(tab, host: host)
        let current = host ?? site(of: tab.url) ?? ""
        if tabs[caller]?.contains(key) == true || (reading && caller == ChatStore.caller && attached[tab.id] == current) { return true }
        let allowed = await ask(String(localized: "The AI wants to use a tab you aren't looking at"),
                                "\(display(current))\n\n#\(tab.id) \(shown(tab.displayTitle, limit: 80).text)\n\n" + String(localized: "If you allow it, you won't be asked again while this tab stays on this site."),
                                caller: caller)
        if allowed { tabs[caller, default: []].insert(key) }
        return allowed
    }

    /// A tab approved while asleep or loading may have ended up on another site by the time it was read; what it
    /// gave is held back unless the site it really came from is approved too. When the page named no site (an error,
    /// a page without an address), the tab's own site stands in, and an unknown one is asked about.
    static func allowRead(_ tab: Tab, approvedHost: String?, readHost: String?, caller: String) async -> Bool {
        let host = readHost ?? site(of: tab.url)
        if let host, host == approvedHost { return true }
        return await allowTab(tab, caller: caller, reading: true, host: host)
    }

    static func allowNavigation(_ url: URL, caller: String) async -> Bool {
        guard Preferences.shared.aiApprovals else { return true }
        if isFree(url, knownURL: { knownURL($0, caller: caller) }, knownHost: Library.shared.knowsHost) || urls[caller]?.contains(url.absoluteString) == true { return true }
        let address = shownWithNote(url.absoluteString)
        let allowed = await ask(String(localized: "The AI wants to open this address"),
                                "\(shown(site(of: url).map(display) ?? url.host() ?? "", limit: 100).text)\n\n\(address.text)\n\n" + String(localized: "Deny if the address carries content from another page or from the conversation."),
                                caller: caller)
        // An address whose end was not shown is asked about each time.
        if allowed && address.cut == 0 && !address.altered { urls[caller, default: []].insert(url.absoluteString) }
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

    /// An address that was open, visited or bookmarked before: not one on a site the AI has read in this chat (what it read
    /// there could have been put into the address), and not a page visited since the chat began.
    private static func knownURL(_ address: String, caller: String) -> Bool {
        if let host = site(of: URL(string: address)), readHosts[caller]?.contains(host) == true { return false }
        return Browser.all.contains { !$0.isPrivate && $0.tabs.contains { $0.url?.absoluteString == address } } || Library.shared.knowsURL(address, before: began(caller))
    }

    /// When the caller's chat began (an MCP client or the command line: when the app first heard from it).
    private static var chatBegan: [String: Date] = [:]

    private static func began(_ caller: String) -> Date {
        if let date = chatBegan[caller] { return date }
        chatBegan[caller] = Date()
        return chatBegan[caller] ?? Date()
    }

    static func noteRead(_ tab: Tab, caller: String) {
        noteRead(tab, readHost: nil, caller: caller)
    }

    /// Records a read by the site its text came from, or by the tab's own site when the page named none.
    static func noteRead(_ tab: Tab, readHost: String?, caller: String) {
        if let site = readHost ?? site(of: tab.url) { readHosts[caller, default: []].insert(site) }
    }

    /// How an approval was answered. `site` (allow on this site for as long as the chat lasts) is offered to the chat panel and to any
    /// MCP client that the bridge named itself (its chat is its connection); any other caller is only ever asked each time.
    enum Choice {
        case deny, once, site
    }

    struct Prompt {
        var message: String
        var detail: String
        var choices: [Choice]
        /// The accounts the user is to pick one of (a sign-in with several saved logins); empty for any other question.
        var accounts: [String] = []
        /// Whether it is the question of what can't be undone (the high tier of `allowAction`), or of what only the page's markup
        /// puts in a cookie banner.
        var irreversible = false
    }

    /// Answers questions in place of the window, and keeps what was asked, newest last.
    final class Stand {
        var answer: (Prompt) -> Choice
        /// Which account of a question's list the user picks (the index), for the questions that have one.
        var pick: (Prompt) -> Int = { _ in 0 }
        var asked: [Prompt] = []
        /// Holds each question until it is withdrawn or released, as a window would while the user thinks.
        var holds = false

        init(_ answer: @escaping (Prompt) -> Choice) {
            self.answer = answer
        }
    }

    /// Stands in for the user in the code run inside `$stand.withValue`: the tests, each for itself.
    @TaskLocal static var stand: Stand?
    /// The headless apps have nobody to ask, and their own profiles hold nothing of the user's to leak. The test copy allows
    /// everything unless a test says otherwise.
    static let headless = Stand(Headless.isUser ? userHeadlessAnswer : { _ in .once })

    /// What the user's headless app answers: yes to everything but what can't be undone (pays, orders, sends, posts, deletes,
    /// grants access: the high tier, and what only a page's markup calls a cookie banner, which a page can say of anything), which
    /// waits for a person and so is refused. Anything the AI signed in to inside that app,
    /// it could otherwise pay, post or delete with, and nobody is there to see it happen.
    static func userHeadlessAnswer(_ prompt: Prompt) -> Choice { prompt.irreversible ? .deny : .once }
    /// Per caller and site, the sites the AI had read when the user allowed it to use that site for the rest of the chat.
    /// A caller's chat is the panel's chat, or an MCP client's connection (its name is its process's and never used again).
    private static var allowances: [String: [String: Set<String>]] = [:]

    /// What the AI does to a page.
    enum Interaction {
        /// Text typed into a field.
        case type(String)
        /// An option chosen from a list.
        case choose(String)
        /// Anything else (a click, a key, a hover, a drop), in the words of the progress line.
        case act(String)
    }

    /// Using a page hands it something the AI chose, or lets it see what the AI does; after reading other sites, the user
    /// is asked for each of those, and says yes: once, or for the site until the chat is cleared, but only for as long as
    /// the sites read are those it was allowed with (reading another site takes it back). Typing and choosing show what
    /// is typed or chosen. `site` is where it happens when that isn't the tab's own site: a frame of another site, or "" for
    /// a document with no site, which no allowance covers.
    static func allowInteraction(_ interaction: Interaction, on tab: Tab, caller: String, site: String? = nil) async -> Bool {
        guard Preferences.shared.aiApprovals else { return true }
        let host = site ?? Self.site(of: tab.url) ?? ""
        let read = readHosts[caller, default: []]
        let others = read.subtracting([host])
        if others.isEmpty { return true }
        // What is typed or chosen is shown whole, or said to be cut: text whose end the user can't see is asked about each time.
        let text: (text: String, cut: Int, altered: Bool)
        switch interaction {
        case .type(let value), .choose(let value), .act(let value): text = shownWithNote(value, limit: 500)
        }
        let allowable = text.cut == 0 && !text.altered && hasSite(host)
        if allowable, let granted = allowances[caller]?[host], others.isSubset(of: granted) { return true }
        let target = host.isEmpty ? String(localized: "this page") : display(host)
        let sites = others.sorted().prefix(5).map(display).joined(separator: ", ")
        let message: String, detail: String
        switch interaction {
        case .type:
            message = String(localized: "The AI wants to type into \(target)")
            detail = "\(target)\n\n" + String(localized: "Text to type:\n\(text.text)\n\nSites read earlier in this conversation: \(sites)\nDeny if content from there is mixed in.")
        case .choose:
            message = String(localized: "The AI wants to choose an option on \(target)")
            detail = "\(target)\n\n" + String(localized: "Option to choose:\n\(text.text)\n\nSites read earlier in this conversation: \(sites)\nDeny if content from there is mixed in.")
        case .act:
            message = String(localized: "The AI wants to use \(target)")
            detail = "\(target)\n\n" + String(localized: "Action:\n\(text.text)\n\nSites read earlier in this conversation: \(sites)\nA page can hide instructions for the AI. Deny if this isn’t what you asked for.")
        }
        let forChat = hasChat(caller) && allowable
        let answer = await choose(message, detail,
                                  [(.deny, String(localized: "Don’t Allow")), (.once, String(localized: "Allow Once"))]
                                  + (forChat ? [(.site, String(localized: "Allow on \(display(host)) for This Chat"))] : []), caller: caller)
        if answer == .site, forChat { allowances[caller, default: [:]][host] = read }
        return answer != .deny
    }

    /// Whether the caller has a chat an allowance can last for, which only a caller no other process can be taken for has: the panel
    /// (its name is only ever given back to a request that proved it, see `ControlServer.caller`), or a name in the form the MCP bridge
    /// gives itself, "mcp-<process ID>-<UUID>", which no other process will have. Everything else is asked each time: the command line
    /// (every command is the one caller "cli"), a request with no name, one that named the panel without proving it, and a name a client
    /// chose for itself with `--caller`, which another process can choose too.
    private static func hasChat(_ caller: String) -> Bool {
        if caller == ChatStore.caller { return true }
        let parts = caller.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "mcp" && !parts[1].isEmpty && parts[1].utf8.allSatisfy { (48...57).contains($0) }
            && UUID(uuidString: String(parts[2])) != nil
    }

    private static func display(_ host: String) -> String {
        host == unknownFrame ? String(localized: "a frame of an unknown site") : host
    }

    /// Per caller, the sites on which the user allowed the AI the actions of the low tier for the rest of the chat.
    private static var lowAllowed: [String: Set<String>] = [:]

    /// What looks like it pays, orders, sends, posts, deletes, cancels or gives something up (the high tier) is asked about every
    /// time, whatever else the user allowed (and whether or not the other questions are asked): what it does can't be taken
    /// back, and a page can name a button anything. What looks like agreeing, saving, sharing or changing a setting (the low
    /// tier) is asked about once per site for a chat when the user says so (the panel or an MCP client of the bridge's own naming), else each time. `destination` is
    /// the site a form sends its data to when that isn't the site it is on.
    /// `markupOnly`: the low tier is only the page's markup saying the control is in a cookie banner. A page can say that of anything,
    /// so this is asked every time, with no offer to allow the site for the chat, and in words that don't vouch for it.
    static func allowAction(_ tier: IrreversibleAction.Tier, _ name: String, on tab: Tab, caller: String, site: String? = nil, destination: String? = nil,
                            markupOnly: Bool = false) async -> Bool {
        let host = site ?? Self.site(of: tab.url) ?? ""
        let allowable = hasSite(host)
        if tier == .low, markupOnly {
            let place = host.isEmpty ? String(localized: "this page") : display(host)
            return await choose(String(localized: "The AI wants to click a button in what the page calls a cookie banner"),
                                "\(place)\n\n“\(shown(quotable(abbreviated(name))).text)”\n\n" + String(localized: "Only the page’s own markup says this is a cookie banner, and a page can say that of anything. It is asked every time.\n\nAllow it only if you asked for this."),
                                [(.deny, String(localized: "Don’t Allow")), (.once, String(localized: "Allow Once"))], irreversible: true, caller: caller) != .deny
        }
        if tier == .low, allowable, lowAllowed[caller]?.contains(host) == true { return true }
        let place = host.isEmpty ? String(localized: "this page") : display(host)
        let words = shown(quotable(abbreviated(name))).text
        if tier == .high {
            let sent = destination.map { String(localized: "The form sends what is typed in it to \(display($0)), another site than this page.") + "\n\n" } ?? ""
            return await choose(String(localized: "The AI wants to do something that can’t be undone"),
                                "\(place)\n\n“\(words)”\n\n" + sent + String(localized: "This looks like it pays, orders, sends, posts, shares, uploads, grants access, deletes or cancels, and that can’t be taken back. It is asked every time.\n\nAllow it only if you asked for this."),
                                [(.deny, String(localized: "Don’t Allow")), (.once, String(localized: "Allow Once"))], irreversible: true, caller: caller) != .deny
        }
        let forChat = hasChat(caller) && allowable
        let answer = await choose(String(localized: "The AI wants to accept cookies or change a setting"),
                                  "\(place)\n\n“\(words)”\n\n" + String(localized: "This looks like a cookie banner or a setting (save, clear, reset, block, enable), not like paying, sending or granting access. You can allow it once, or on this site for the rest of the chat."),
                                  [(.deny, String(localized: "Don’t Allow")), (.once, String(localized: "Allow Once"))]
                                  + (forChat ? [(.site, String(localized: "Allow on \(display(host)) for This Chat"))] : []), caller: caller)
        if answer == .site, forChat { lowAllowed[caller, default: []].insert(host) }
        return answer != .deny
    }

    /// The sign-in of the sign_in tool: asked every time, whatever else was allowed and whether or not the other questions are asked,
    /// with the site the login goes to and the account that is filled in (what the user sees; the AI never does). With several
    /// accounts saved the user picks one in the question (the first, the most recently used, to begin with): the AI is never asked
    /// which. `page` is the site of the page when the form is in a frame of another. nil when the user says no (or doesn't answer).
    static func allowSignIn(host: String, accounts: [String], page: String?, caller: String) async -> String? {
        let site = shown(display(host), limit: 100).text
        let inFrame = page.map { String(localized: "The sign-in form is in a frame on \(shown(display($0), limit: 100).text).") + "\n\n" } ?? ""
        let explanation = String(localized: "Changmun fills in the saved login itself; the AI is not shown the password or the account name. It does not press Sign in: the AI does that next, and that click is judged like any other.")
        let buttons = [(Choice.deny, String(localized: "Don’t Allow")), (Choice.once, String(localized: "Allow Once"))]
        // No saved login: the same kind of question, with the same wait, that only says so and can only be closed.
        if accounts.isEmpty {
            _ = await choose(String(localized: "The AI tried to sign in to \(site)"), "\(site)\n\n\(inFrame)" + String(localized: "There is no saved login for this site, so nothing was filled in. The AI is told only that the sign-in wasn't done."),
                             [(.deny, String(localized: "Close"))], caller: caller)
            return nil
        }
        guard let only = accounts.first, accounts.count == 1 else {
            let answer = await choose(String(localized: "Let the AI sign in to \(site)?"), "\(site)\n\n\(inFrame)" + String(localized: "Pick the account to sign in with.") + "\n\n\(explanation)",
                                      buttons, accounts: accounts, caller: caller)
            return answer.choice == .once && accounts.indices.contains(answer.account) ? accounts[answer.account] : nil
        }
        let account = accountTitle(only)
        return await choose(String(localized: "Let the AI sign in to \(site) as \(account)?"), "\(site)\n\(account)\n\n\(inFrame)\(explanation)", buttons, caller: caller) == .once ? only : nil
    }

    /// How a saved account is named in a question: a login saved with no username is said so.
    static func accountTitle(_ account: String) -> String {
        account.isEmpty ? String(localized: "(No username)") : shown(quotable(account), limit: 100).text
    }

    /// A long name keeps its beginning and its end, where a button says what it does.
    static func abbreviated(_ name: String, to length: Int = 80) -> String {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count > length else { return name }
        let part = (length - 3) / 2
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars.prefix(part))
        result.append(contentsOf: " … ".unicodeScalars)
        result.append(contentsOf: scalars.suffix(part))
        return String(result)
    }

    /// A new chat starts without anything read or allowed; other callers keep theirs.
    static func forgetReads(caller: String) {
        readHosts[caller] = nil
        allowances[caller] = nil
        lowAllowed[caller] = nil
        SignIn.forgetDeclined(caller: caller)
        chatBegan[caller] = Date()
    }

    private final class Once {
        var done = false
    }

    /// A question waiting for the user, which the stop button can withdraw.
    private struct Pending {
        var id: UUID
        var caller: String
        var resolve: (Choice) -> Void
    }

    private static var pending: [Pending] = []

    /// The caller was stopped: what it is waiting to be answered is answered no, and the question taken off the window.
    static func cancelPending(caller: String) {
        for question in pending where question.caller == caller { question.resolve(.deny) }
    }

    /// Answers the questions a held stand has waiting (for tests: the headless app's `/approvals`).
    static func release(_ choice: Choice) {
        for question in pending { question.resolve(choice) }
    }

    private static func ask(_ message: String, _ detail: String, caller: String) async -> Bool {
        await choose(message, detail, [(.deny, String(localized: "Deny")), (.once, String(localized: "Allow"))], caller: caller) != .deny
    }

    private static func choose(_ message: String, _ detail: String, _ buttons: [(Choice, String)], irreversible: Bool = false, caller: String) async -> Choice {
        await choose(message, detail, buttons, accounts: [], irreversible: irreversible, caller: caller).choice
    }

    /// Asks on the browser window, the first button being the one Return presses; no answer within `timeout` counts as
    /// no, so a late yes never runs a stale request. With `accounts`, the question carries a list to pick one from (the first
    /// is chosen to begin with), and says which.
    private static func choose(_ message: String, _ detail: String, _ buttons: [(Choice, String)], accounts: [String], irreversible: Bool = false, caller: String) async -> (choice: Choice, account: Int) {
        let prompt = Prompt(message: message, detail: detail, choices: buttons.map(\.0), accounts: accounts, irreversible: irreversible)
        let standing = stand ?? (Headless.isOn ? headless : nil)
        if let standing {
            if standing.asked.count > 100 { standing.asked.removeFirst(standing.asked.count - 100) }
            standing.asked.append(prompt)
            if !standing.holds { return (standing.answer(prompt), min(max(standing.pick(prompt), 0), max(accounts.count - 1, 0))) }
        }
        guard standing != nil || Browser.recent?.window != nil else { return (.deny, 0) }
        let alert = NSAlert()
        let list = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        if standing == nil {
            alert.messageText = message
            alert.informativeText = detail
            for (_, title) in buttons { alert.addButton(withTitle: title) }
            if accounts.count > 1 {
                list.addItems(withTitles: accounts.map(accountTitle))
                alert.accessoryView = list
            }
            NSApp.requestUserAttention(.informationalRequest)
        }
        return await withCheckedContinuation { continuation in
            let once = Once()
            let id = UUID()
            let finish = { (choice: Choice, account: Int) in
                guard !once.done else { return }
                once.done = true
                pending.removeAll { $0.id == id }
                continuation.resume(returning: (choice, account))
            }
            var end: () -> Void = {}
            if standing == nil, let window = Browser.recent?.window {
                alert.beginSheetModal(for: window) { response in
                    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    finish(buttons.indices.contains(index) ? buttons[index].0 : .deny, max(list.indexOfSelectedItem, 0))
                }
                end = { window.endSheet(alert.window) }
            }
            pending.append(Pending(id: id, caller: caller) { choice in
                finish(choice, 0)
                end()
            })
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !once.done else { return }
                finish(.deny, 0)
                end()
            }
        }
    }
}

/// Scripts run in an isolated JavaScript world: they share the page's DOM but not its variables.
enum PageScripts {
    static let readText = """
    const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n');
    const cut = text.length > maxChars ? text.slice(0, maxChars) + '\\n…(truncated)' : text;
    return 'Title: ' + document.title + '\\nURL: ' + location.href + '\\n\\n' + cut;
    """

    static let scroll = """
    const height = document.documentElement.scrollHeight;
    if (direction === 'top') scrollTo(0, 0);
    else if (direction === 'bottom') scrollTo(0, height);
    else scrollBy(0, (direction === 'up' ? -1 : 1) * innerHeight * 0.85);
    return 'Scrolled ' + direction + '. Now at ' + Math.round(scrollY) + ' of ' + height + ' (viewport ' + innerHeight + ').';
    """
}
