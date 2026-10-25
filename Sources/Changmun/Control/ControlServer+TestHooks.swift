import AppKit
import Foundation
import Network

/// The endpoints only a headless test copy answers, kept out of `handle()`: the test copy is a release build told apart by its bundle id.
extension ControlServer {
    /// Answers the request and returns true if it is one of the test copy's own endpoints; false lets `handle()` go on.
    func handleTestRequest(_ request: HTTPRequest, on connection: NWConnection) -> Bool {
        // Tests only: a picture of the front window, sidebar and all.
        if Headless.isTestCopy, request.method == "POST", request.path == "/window-image" {
            Task { @MainActor in
                guard let window = Browser.current?.window, let png = await WindowImage.png(of: window) else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no window"])
                }
                self.respond(connection, status: "200 OK", body: ["png": png.base64EncodedString()])
            }
            return true
        }
        // Tests only: a mouse event at a point in the window (from its top left), handed to the app as if it came
        // from the window server, so the headless app can be clicked without touching the real pointer.
        if Headless.isTestCopy, request.method == "POST", request.path == "/window-event",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
           let kind = body["type"] as? String, let x = body["x"] as? Double, let y = body["y"] as? Double {
            Task { @MainActor in
                let types: [String: NSEvent.EventType] = ["down": .leftMouseDown, "drag": .leftMouseDragged, "up": .leftMouseUp, "right": .rightMouseDown]
                guard let window = Browser.current?.window, let content = window.contentView, let type = types[kind],
                      let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: content.bounds.height - y), modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no window or unknown type"])
                }
                NSApp.sendEvent(event)
                self.respond(connection, status: "200 OK", body: [:])
            }
            return true
        }
        // Tests only: the front window's spaces. "action" is list, create (name, symbol, tint, profile), switch, delete (by
        // name), or sheet (shows the new-space sheet, or the edit sheet of the space named); the answer lists the spaces.
        if Headless.isTestCopy, request.method == "POST", request.path == "/spaces",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            Task { @MainActor in
                guard let browser = Browser.current else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no window"])
                }
                let store = browser.spaces
                if body["action"] as? String != "sheet" { browser.spaceSheet = nil }
                let named = store.spaces.first { $0.name == body["name"] as? String }
                switch body["action"] as? String {
                case "create":
                    let tint = SpaceTint(rawValue: body["tint"] as? String ?? "") ?? .blue
                    let space = store.add(name: body["name"] as? String ?? "", symbol: body["symbol"] as? String ?? "briefcase", tint: tint,
                                          isProfile: body["profile"] as? Bool ?? false)
                    browser.switchSpace(to: space.id)
                case "switch": if let named { browser.switchSpace(to: named.id) }
                case "delete": if let named { Browser.deleteSpace(named.id, from: store) }
                case "sheet": browser.spaceSheet = named.map { .edit($0.id) } ?? .new
                default: break
                }
                let list = store.spaces.map { space -> [String: Any] in
                    ["name": space.name, "symbol": space.symbol, "tint": space.tint.rawValue, "profile": space.isProfile, "active": space.id == browser.spaceID,
                     "tabs": browser.tabs.filter { $0.spaceID == space.id }.count]
                }
                self.respond(connection, status: "200 OK", body: ["spaces": list])
            }
            return true
        }
        // Tests only: a tab (the active one unless "tab_id" names another) as a PDF or a full-page picture, written to a
        // path without the save panel. Private windows are refused.
        if Headless.isTestCopy, request.method == "POST", request.path == "/save-page",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
           let kind = body["format"] as? String, let path = body["path"] as? String {
            Task { @MainActor in
                guard let tab = (body["tab_id"] as? Int).flatMap(ToolCatalog.findTab) ?? Browser.recent?.active,
                      let page = await SavePage.data(of: tab, as: kind == "pdf" ? .pdf : .image), (try? page.data.write(to: URL(fileURLWithPath: path))) != nil else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "nothing saved"])
                }
                self.respond(connection, status: "200 OK", body: ["bytes": page.data.count, "cut": page.cut])
            }
            return true
        }
        // Tests only: split view and peek, run on the front window. "action" is split (tab_id: shown next to the active tab),
        // unsplit, toggle, peek (url), closePeek or keepPeek; the answer says, for every tab on screen, whether its web view
        // is in the window with a size, after a moment for the views to settle.
        if Headless.isTestCopy, request.method == "POST", request.path == "/views",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            Task { @MainActor in
                guard let browser = Browser.current else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no window"])
                }
                switch body["action"] as? String {
                case "split": if let id = body["tab_id"] as? Int { browser.split(with: id) }
                case "unsplit": browser.unsplit()
                case "toggle": browser.toggleSplit()
                case "peek": if let url = (body["url"] as? String).flatMap(URL.init(string:)) { browser.openPeek(url) }
                case "closePeek": browser.closePeek()
                case "keepPeek": browser.keepPeek()
                default: break
                }
                try? await Task.sleep(for: .milliseconds(500))
                let shown = browser.tabs.filter { browser.isShown($0) } + [browser.peek].compactMap { $0 }
                let report = shown.map { tab -> [String: Any] in
                    let view = tab.webView
                    return ["id": tab.id, "peek": tab === browser.peek, "hasWebView": view != nil, "attached": view?.superview != nil,
                            "inWindow": view?.window != nil, "width": Int(view?.frame.width ?? 0), "height": Int(view?.frame.height ?? 0)]
                }
                self.respond(connection, status: "200 OK", body: ["shown": report, "active": browser.activeID ?? -1, "split": browser.shownSplit != nil])
            }
            return true
        }
        // Tests only: where the web view of the tab in front stands (in its host, or in a full screen window), after "eval" ran a
        // script in it, if given, and a moment for the views to settle; "png" adds a picture of the window.
        if Headless.isTestCopy, request.method == "POST", request.path == "/fullscreen",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            Task { @MainActor in
                guard let browser = Browser.current else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no window"])
                }
                if let script = body["eval"] as? String { _ = try? await browser.active?.wake().evaluateJavaScript(script) }
                try? await Task.sleep(for: .milliseconds(body["wait"] as? Int ?? 1200))
                var report = await FullscreenMeasure.report(of: browser)
                if body["png"] as? Bool == true, let window = browser.window, let png = await WindowImage.png(of: window) { report["png"] = png.base64EncodedString() }
                self.respond(connection, status: "200 OK", body: report)
            }
            return true
        }
        // Tests only: pop-ups in the front window. "allow" replaces the sites allowed to open pop-ups; "action" is open, always or
        // close, run on the bar of the tab "tab_id" names (else the one in front); "reset" empties the bars and closes the tabs
        // other than "tab_id"; "eval" runs a script in the page of that tab as the browser's own calls do (with a user gesture),
        // and its value comes back as "result". The answer is the number of tabs, the last few of them (the page's opener, its title and address),
        // the active tab, and every bar that is showing.
        if Headless.isTestCopy, request.method == "POST", request.path == "/popups",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            Task { @MainActor in
                guard let browser = Browser.current else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no window"])
                }
                if let allow = body["allow"] as? [String] { Preferences.shared.popupHosts = allow }
                let target = browser.tab(body["tab_id"] as? Int)
                if body["reset"] as? Bool == true {
                    for tab in browser.tabs where tab !== target { browser.close(tab.id, remember: false) }
                    target?.blockedPopup = nil
                    browser.allowedPopups = []
                }
                switch body["action"] as? String {
                case "open": target?.openBlockedPopup(always: false)
                case "always": target?.openBlockedPopup(always: true)
                case "close": target?.blockedPopup = nil
                default: break
                }
                var result: Any?
                if let script = body["eval"] as? String { result = try? await target?.wake().evaluateJavaScript(script) }
                try? await Task.sleep(for: .milliseconds(600))
                let recent = browser.tabs.suffix(6).map { tab -> [String: Any] in
                    ["id": tab.id, "opener": tab.openerID ?? -1, "title": tab.webView?.title ?? "", "url": tab.webView?.url?.absoluteString ?? ""]
                }
                let bars = browser.tabs.compactMap { tab -> [String: Any]? in
                    guard let popup = tab.blockedPopup else { return nil }
                    return ["tab": tab.id, "url": popup.absoluteString, "frame": tab.blockedPopupFrame ?? NSNull(),
                            "site": tab.blockedPopupSite ?? NSNull(), "otherSite": tab.blockedPopupIsFromOtherSite]
                }
                self.respond(connection, status: "200 OK", body: ["tabs": browser.tabs.count, "active": browser.activeID ?? -1, "recent": recent,
                                                                   "bars": bars, "allowed": Preferences.shared.popupHosts, "result": result.map { "\($0)" } ?? ""])
            }
            return true
        }
        // Tests only: the saved logins of the headless app, which keeps them in memory (it never touches the keychain). "host",
        // "username" and "password" add one; "clear" empties them; the answer is how many there are.
        if Headless.isTestCopy, request.method == "POST", request.path == "/logins",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            Task { @MainActor in
                if body["clear"] as? Bool == true { MemoryLogins.shared.items = [] }
                if let host = body["host"] as? String, let username = body["username"] as? String, let password = body["password"] as? String {
                    MemoryLogins.shared.items.append((host, username, password))
                }
                self.respond(connection, status: "200 OK", body: ["count": MemoryLogins.shared.items.count])
            }
            return true
        }
        // Tests only: the front window put into a look. "appearance" is system, light or dark; "toolbar" is page or sidebar; "tabs" is sidebar or top (where the tabs are), "overlay" shows or hides the sidebar over the page that goes with top; "sidebar",
        // "focus", "find" (with "findText"), "downloads" and "onboarding" show or hide that part; "command" is newTab, editCurrent or
        // none; "progress" (0...1) holds the tab in front as loading at that point, and a negative one lets it be ("peek": true for the peek card's tab); "popup" (a link), "login"
        // (a user name) and "foreign" (a language) put up the bar or button for that on the tab in front, "" taking it down again; "reader" toggles Reader Mode; "group" ({"ids", "name"}) gathers tabs into a group;
        // "folder" ({"name", "pages": [[url, title]], "pin", "open"}) fills a bookmark folder, pinned and opened in the sidebar;
        // "rename" names the tab in front (an empty name takes the name away), and "renaming" opens or closes the name field in its row.
        if Headless.isTestCopy, request.method == "POST", request.path == "/ui",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            Task { @MainActor in
                guard let browser = Browser.current else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no window"])
                }
                if let name = body["appearance"] as? String, let appearance = AppAppearance(rawValue: name) { Preferences.shared.appearance = appearance }
                if let name = body["toolbar"] as? String, let place = ToolbarPlace(rawValue: name) { Preferences.shared.toolbarPlace = place }
                if let name = body["tabs"] as? String, let layout = TabLayout(rawValue: name) { Preferences.shared.tabLayout = layout }
                if let on = body["overlay"] as? Bool { browser.showSidebarOverlay = on }
                if let on = body["sidebar"] as? Bool { browser.showSidebar = on }
                if let on = body["focus"] as? Bool { browser.focusMode = on }
                if let on = body["onboarding"] as? Bool { browser.showOnboarding = on }
                if let on = body["downloads"] as? Bool { browser.showDownloads = on }
                if let text = body["findText"] as? String { browser.overlay.findText = text }
                if let on = body["find"] as? Bool { if on { browser.showFindBar() } else { browser.hideFindBar() } }
                switch body["command"] as? String {
                case "newTab": browser.commandBar = .newTab
                case "editCurrent": browser.commandBar = .editCurrent
                case "none": browser.commandBar = nil
                default: break
                }
                if let group = body["group"] as? [String: Any], let ids = group["ids"] as? [Int] {
                    browser.group(ids, name: group["name"] as? String ?? "Group")
                    browser.renamingGroup = nil
                }
                if let folder = body["folder"] as? [String: Any], let name = folder["name"] as? String {
                    for page in folder["pages"] as? [[String]] ?? [] where page.count == 2 { Library.shared.addBookmark(url: page[0], title: page[1], folder: name) }
                    if folder["pin"] as? Bool == true { browser.spaces.pinFolder(name, before: nil, in: browser.spaceID) }
                    if folder["open"] as? Bool == true, !browser.space.openFolders.contains("pin:" + name) { browser.spaces.toggleOpen("pin:" + name, in: browser.spaceID) }
                }
                if let tab = browser.active {
                    if let name = body["rename"] as? String { tab.rename(to: name) }
                    if let on = body["renaming"] as? Bool { browser.renamingTab = on ? tab.id : nil }
                    if let popup = body["popup"] as? String { tab.blockedPopup = URL(string: popup) }
                    if let login = body["login"] as? String { tab.loginOffer = login.isEmpty ? nil : LoginOffer(host: "accounts.example.com", username: login, password: "x") }
                    if let language = body["foreign"] as? String { tab.foreignLanguage = language.isEmpty ? nil : Locale.Language(identifier: language) }
                    if body["reader"] as? Bool == true { tab.toggleReader() }
                }
                if let progress = body["progress"] as? Double, let tab = (body["peek"] as? Bool == true ? browser.peek : browser.active) {
                    tab.isLoading = progress >= 0
                    tab.progress = max(0, progress)
                }
                try? await Task.sleep(for: .milliseconds(500))
                self.respond(connection, status: "200 OK", body: [:])
            }
            return true
        }
        // Tests only: a page of "html" in the tab in front, as if it came from the address "base" (https://lab.test/, say).
        if Headless.isTestCopy, request.method == "POST", request.path == "/load-html",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any], let html = body["html"] as? String {
            Task { @MainActor in
                guard let tab = Browser.recent?.active else { return self.respond(connection, status: "404 Not Found", body: ["error": "no tab"]) }
                tab.wake().loadHTMLString(html, baseURL: (body["base"] as? String).flatMap(URL.init(string:)))
                try? await Task.sleep(for: .milliseconds(500))
                self.respond(connection, status: "200 OK", body: [:])
            }
            return true
        }
        // Tests only: the Translate button pressed on the tab in front, answered when it is done with the page's language,
        // where the page stands ("original" or "translated"), what the status line says, and the page's text.
        if Headless.isTestCopy, request.method == "POST", request.path == "/translate" {
            Task { @MainActor in
                guard let browser = Browser.recent, let tab = browser.active else { return self.respond(connection, status: "404 Not Found", body: ["error": "no tab"]) }
                browser.overlay.statusMessage = nil
                tab.toggleTranslation()
                for _ in 0..<1200 where tab.translation == .translating { try? await Task.sleep(for: .milliseconds(100)) }
                let text = try? await tab.webView?.callAsyncJavaScript("return document.body.innerText", contentWorld: .page) as? String
                self.respond(connection, status: "200 OK", body: [
                    "language": tab.foreignLanguage?.minimalIdentifier ?? "", "state": tab.translation == .translated ? "translated" : "original",
                    "status": browser.overlay.statusMessage ?? "", "text": text ?? "",
                ])
            }
            return true
        }
        // Tests only: how the AI's approvals are answered ("answer": allow, site or deny; any other value goes back to
        // allowing), whether questions wait for an answer instead ("hold"), the answer given to those waiting ("release":
        // allow, site or deny), a caller's stop button ("stop": the caller's name), the chat started over ("newChat", as
        // the New Chat button does), what a caller has read forgotten ("forget": the caller's name), what the panel records
        // as read when a message goes out ("noteFront": the title and address of the tab in front, and the attached tabs),
        // the name the panel's calls carry ("panelSecret": its secret and the token of the run under way, which only a headless app
        // gives out; "panelRun" starts a run's token), and what was
        // asked, newest last ("clear" empties that list).
        if Headless.isTestCopy, request.method == "POST", request.path == "/approvals",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            Task { @MainActor in
                if let answer = body["answer"] as? String {
                    let wanted = ["allow": Approvals.Choice.once, "site": .site, "deny": .deny][answer]
                    Approvals.headless.answer = wanted.map { wanted in { prompt in prompt.choices.contains(wanted) ? wanted : (wanted == .site ? .once : .deny) } } ?? { _ in .once }
                }
                if let hold = body["hold"] as? Bool { Approvals.headless.holds = hold }
                if let release = body["release"] as? String { Approvals.release(["allow": .once, "site": .site][release] ?? .deny) }
                if let caller = body["stop"] as? String { AgentActivity.shared.cancel(caller: caller) }
                if let caller = body["forget"] as? String { Approvals.forgetReads(caller: caller) }
                if body["newChat"] as? Bool == true { ChatStore.shared.reset() }
                if body["noteFront"] as? Bool == true { ChatStore.shared.noteAttachedRead() }
                if body["panelRun"] as? Bool == true { ChatStore.shared.runToken = UUID().uuidString + UUID().uuidString }
                let asked = Approvals.headless.asked.map { ["message": $0.message, "detail": $0.detail, "choices": $0.choices.map { "\($0)" }] as [String: Any] }
                if body["clear"] as? Bool == true { Approvals.headless.asked = [] }
                self.respond(connection, status: "200 OK", body: ["asked": asked].merging(body["panelSecret"] as? Bool == true ? ["panelSecret": ChatStore.panelSecret, "runToken": ChatStore.shared.runToken ?? ""] : [:]) { $1 })
            }
            return true
        }
        // Tests only: what the AI tools on this Mac look like to the app. "state" is ready, coming (Claude Code missing, Codex and
        // opencode found) or none; "show" is onboarding (opens it, at its first step) or panel (opens the AI panel on a new chat).
        if Headless.isTestCopy, request.method == "POST", request.path == "/ai-tools",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            Task { @MainActor in
                switch body["state"] as? String {
                case "ready": AIAvailability.detector = { .ready }
                case "coming": AIAvailability.detector = { .supportComing(["Codex", "opencode"]) }
                case "none": AIAvailability.detector = { .none }
                default: break
                }
                ChatStore.shared.refreshAvailability()
                guard let browser = Browser.current else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no window"])
                }
                switch body["show"] as? String {
                case "onboarding": browser.showOnboarding = true
                case "panel": ChatStore.shared.reset(); browser.showChat = true
                default: break
                }
                self.respond(connection, status: "200 OK", body: [:])
            }
            return true
        }
        // Tests only: pictures for the next message of the AI panel ("sample": how many generated pictures to add; "add": the
        // base64 of a picture file, as if dropped; "screenshot": the Screenshot button on the front tab; "send": a message that goes
        // out with them, to no AI: the prompt it would have been given comes back). It answers with how many are waiting and the notice.
        if Headless.isTestCopy, request.method == "POST", request.path == "/chat-images",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            Task { @MainActor in
                let chat = ChatStore.shared
                for number in 0..<(body["sample"] as? Int ?? 0) {
                    let size = NSSize(width: 640, height: 400)
                    let picture = NSImage(size: size, flipped: false) { frame in
                        NSGradient(colors: [NSColor(hue: CGFloat(number) * 0.23 + 0.55, saturation: 0.7, brightness: 0.95, alpha: 1), .white])?.draw(in: frame, angle: 35)
                        NSAttributedString(string: "Sample \(number + 1)", attributes: [.font: NSFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.white]).draw(at: NSPoint(x: 40, y: 150))
                        return true
                    }
                    if let png = picture.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]) { chat.addImages([png]) }
                }
                if let encoded = body["add"] as? String { chat.addImages([Data(base64Encoded: encoded) ?? Data()]) }
                if body["screenshot"] as? Bool == true { await chat.attachScreenshot(of: Browser.recent?.active) }
                try? await Task.sleep(for: .milliseconds(300))
                while chat.pendingImages > 0 { try? await Task.sleep(for: .milliseconds(100)) }
                var prompt = ""
                if let message = body["send"] as? String {
                    chat.launch = { _, text in prompt = text; return false }
                    chat.send(message, images: chat.takeImages())
                }
                self.respond(connection, status: "200 OK", body: ["images": chat.images.count, "notice": chat.notice ?? "", "prompt": prompt])
            }
            return true
        }
        // Tests only: puts a conversation into the AI panel and opens the panel on it ("items": the chat's items as the history keeps
        // them: kind, text, symbol, title, tool, outcome, failure), keeps chats in its history ("history": a list of {"items", "ago"
        // in seconds}; "clearHistory" first empties it), and shows the history list ("showHistory") or a chat of it ("open": its index,
        // newest first).
        if Headless.isTestCopy, request.method == "POST", request.path == "/ai-chat",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            Task { @MainActor in
                let chat = ChatStore.shared
                func items(_ value: Any?) -> [ChatItem] {
                    guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return [] }
                    return (try? JSONDecoder().decode([ChatItem].self, from: data)) ?? []
                }
                if body["clearHistory"] as? Bool == true { chat.history.clear() }
                for kept in body["history"] as? [[String: Any]] ?? [] {
                    let ago = kept["ago"] as? Double ?? 0
                    chat.history.record(id: UUID(), started: Date(timeIntervalSinceNow: -ago), items: items(kept["items"]), now: Date(timeIntervalSinceNow: -ago))
                }
                chat.reset()
                if body["items"] != nil { chat.load(items(body["items"])) }
                if body["showHistory"] as? Bool == true || body["open"] != nil {
                    chat.showHistory = true
                    if let index = body["open"] as? Int, chat.history.chats.indices.contains(index) { chat.openedHistory = chat.history.chats[index].id }
                }
                // "running": a run under way that began this many seconds ago (to no AI), with "step" as its line; "context":
                // {"used", "window"} tokens for the ring.
                if let ago = body["running"] as? Double {
                    chat.isRunning = true
                    chat.runStarted = Date(timeIntervalSinceNow: -ago)
                    chat.step = body["step"] as? String
                }
                if let context = body["context"] as? [String: Int], let used = context["used"] {
                    chat.contextWindow = context["window"]
                    chat.noteContext(used)
                }
                Browser.current?.showChat = true
                self.respond(connection, status: "200 OK", body: ["chats": chat.history.chats.count])
            }
            return true
        }
        // Tests only: the AI panel's box and width. "open" shows or hides the panel, "width" sets its width, "model" the model, "prefill"
        // puts text in the box (with the cursor at its end), and "selection" asks the AI about the selection in the page in front.
        if Headless.isTestCopy, request.method == "POST", request.path == "/panel",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            Task { @MainActor in
                guard let browser = Browser.current else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no window"])
                }
                if let width = body["width"] as? Double { Preferences.shared.aiPanelWidth = Preferences.clampedAIPanelWidth(width) }
                if let model = body["model"] as? String { Preferences.shared.aiModel = model }
                if let effort = body["effort"] as? String { Preferences.shared.aiEffort = effort }
                if let mode = (body["approvalMode"] as? String).flatMap(AIApprovalMode.init(rawValue:)) { Preferences.shared.aiApprovalMode = mode }
                if let open = body["open"] as? Bool { browser.showChat = open }
                // "popOut": the panel in a window of its own (off screen here) or docked back; "popOutImage" answers with that window's picture.
                if let popOut = body["popOut"] as? Bool {
                    if popOut { ChatPopOut.shared.open(for: browser) } else { ChatPopOut.shared.close(dock: true) }
                    ChatPopOut.shared.window?.setFrameOrigin(Headless.origin)
                }
                if let text = body["prefill"] as? String { ChatStore.shared.prefill = text }
                if body["selection"] as? Bool == true { browser.active?.askAIAboutSelection() }
                var answer: [String: Any] = ["width": Preferences.shared.aiPanelWidth, "model": Preferences.shared.aiModel, "poppedOut": ChatPopOut.shared.window != nil,
                                             "docked": browser.showChat]
                if body["popOutImage"] as? Bool == true, let window = ChatPopOut.shared.window {
                    try? await Task.sleep(for: .milliseconds(600))
                    answer["png"] = await WindowImage.png(of: window)?.base64EncodedString()
                }
                self.respond(connection, status: "200 OK", body: answer)
            }
            return true
        }
        // Tests only: open the settings window on a page, far off screen, and answer with its picture.
        if Headless.isTestCopy, request.method == "POST", request.path == "/settings-image",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            Task { @MainActor in
                UserDefaults.standard.set(body["page"] as? String ?? SettingsPage.general.rawValue, forKey: "settingsPage")
                if let name = body["appearance"] as? String, let appearance = AppAppearance(rawValue: name) { Preferences.shared.appearance = appearance }
                (NSApp.delegate as? AppDelegate)?.showSettings(nil)
                guard let window = Panels.window("settings") else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no settings window"])
                }
                window.setFrameOrigin(Headless.origin)
                try? await Task.sleep(for: .milliseconds(600))
                guard let png = await WindowImage.png(of: window) else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no picture"])
                }
                self.respond(connection, status: "200 OK", body: ["png": png.base64EncodedString()])
            }
            return true
        }
        return false
    }
}
