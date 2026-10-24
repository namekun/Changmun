import AppKit
import Foundation
import Network

/// Where the running app's control server listens, written for `Changmun --mcp` to find.
struct ControlEndpoint: Codable {
    var port: UInt16
    var token: String
    var pid: Int32

    static var file: URL { Library.folder.appendingPathComponent("control.json") }

    static func read(file: URL = file) -> ControlEndpoint? {
        guard let data = try? Data(contentsOf: file), let endpoint = try? JSONDecoder().decode(ControlEndpoint.self, from: data),
              isChangmun(pid: endpoint.pid) else { return nil }
        return endpoint
    }

    /// Deletes the file if it still holds `endpoint`'s token and port: an app that restarts rewrites it within a second, and
    /// that new file must not go with the old one.
    static func remove(ifHolding endpoint: ControlEndpoint, file: URL = file) {
        guard let data = try? Data(contentsOf: file), let current = try? JSONDecoder().decode(ControlEndpoint.self, from: data),
              current.token == endpoint.token, current.port == endpoint.port else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Whether the process is alive and a program of the name this one has (Changmun, the app or a copy of it). A crash leaves
    /// `control.json` behind, and its process ID may be another program's by the time it is read.
    static func isChangmun(pid: Int32) -> Bool {
        func name(_ pid: Int32) -> String? {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            return proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? URL(fileURLWithPath: String(cString: path)).lastPathComponent : nil
        }
        guard kill(pid, 0) == 0, let theirs = name(pid), let ours = name(getpid()) else { return false }
        return theirs == ours
    }
}

/// A small HTTP server on 127.0.0.1 that runs browser tools: `POST /call {"name", "arguments"}` with the token as a bearer.
final class ControlServer {
    static let shared = ControlServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "changmun.control")
    private let token = UUID().uuidString + UUID().uuidString
    private let file: URL
    /// How long a connection has to send the head of its request (the part with the token) before it is dropped.
    private let headDeadline: TimeInterval
    private var stopped = false

    init(file: URL = ControlEndpoint.file, headDeadline: TimeInterval = 10) {
        self.file = file
        self.headDeadline = headDeadline
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return listenFailed("couldn't create the listener") }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else { return }
                let endpoint = ControlEndpoint(port: port, token: self.token, pid: getpid())
                guard let data = try? JSONEncoder().encode(endpoint),
                      FileManager.default.createFile(atPath: self.file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    return self.listenFailed("couldn't write control.json")
                }
            case .failed:
                // A listener that failed (the network stack was reset, say) accepts nothing anymore: it is replaced, and the new port
                // is written to the file the bridges read.
                listener.cancel()
                self.queue.asyncAfter(deadline: .now() + 1) {
                    guard !self.stopped, self.listener === listener else { return }
                    self.listener = nil
                    self.start()
                }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// A headless copy has no window, and its control server is the only way to it: without one it would run on, unseen and out of
    /// reach, and `changmun headless start` could not tell. So it quits.
    private func listenFailed(_ reason: String) {
        FileHandle.standardError.write(Data("changmun: the control server isn't up: \(reason)\n".utf8))
        if Headless.isOn { DispatchQueue.main.async { NSApp.terminate(nil) } }
    }

    func stop() {
        queue.sync {
            stopped = true
            listener?.cancel()
        }
        if ControlEndpoint.read(file: file)?.pid == getpid() { try? FileManager.default.removeItem(at: file) }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        // No request, tool call included, takes this long; a client that stalls is dropped.
        queue.asyncAfter(deadline: .now() + 150) { connection.cancel() }
        // The head of a request, with the token, comes at once. A connection that hasn't sent it holds nothing useful: it is dropped.
        let head = Head()
        queue.asyncAfter(deadline: .now() + headDeadline) { if !head.received { connection.cancel() } }
        receive(connection, buffer: Data(), head: head)
    }

    /// Whether a connection has sent the end of its request's head.
    private final class Head { var received = false }

    private func receive(_ connection: NWConnection, buffer: Data, head: Head) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { head.received = true }
            switch HTTPRequest.parse(buffer, token: self.token) {
            case .complete(let request):
                self.handle(request, on: connection)
            case .rejected(let status):
                self.respond(connection, status: status, body: ["error": status])
            case .incomplete:
                if complete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer, head: head) }
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        // Tests only: a picture of the front window, sidebar and all.
        if Headless.isTestCopy, request.method == "POST", request.path == "/window-image" {
            Task { @MainActor in
                guard let window = Browser.current?.window, let png = await WindowImage.png(of: window) else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no window"])
                }
                self.respond(connection, status: "200 OK", body: ["png": png.base64EncodedString()])
            }
            return
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
            return
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
            return
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
            return
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
            return
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
            return
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
            return
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
            return
        }
        // Tests only: the front window put into a look. "appearance" is system, light or dark; "toolbar" is page or sidebar; "sidebar",
        // "focus", "find" (with "findText"), "downloads" and "onboarding" show or hide that part; "command" is newTab, editCurrent or
        // none; "progress" (0...1) holds the tab in front as loading at that point, and a negative one lets it be ("peek": true for the peek card's tab); "popup" (a link), "login"
        // (a user name) and "foreign" (a language) put up the bar or button for that on the tab in front, "" taking it down again; "reader" toggles Reader Mode; "group" ({"ids", "name"}) gathers tabs into a group;
        // "folder" ({"name", "pages": [[url, title]], "pin", "open"}) fills a bookmark folder, pinned and opened in the sidebar.
        if Headless.isTestCopy, request.method == "POST", request.path == "/ui",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            Task { @MainActor in
                guard let browser = Browser.current else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no window"])
                }
                if let name = body["appearance"] as? String, let appearance = AppAppearance(rawValue: name) { Preferences.shared.appearance = appearance }
                if let name = body["toolbar"] as? String, let place = ToolbarPlace(rawValue: name) { Preferences.shared.toolbarPlace = place }
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
            return
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
            return
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
            return
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
            return
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
            return
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
            return
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
                Browser.current?.showChat = true
                self.respond(connection, status: "200 OK", body: ["chats": chat.history.chats.count])
            }
            return
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
                if let open = body["open"] as? Bool { browser.showChat = open }
                if let text = body["prefill"] as? String { ChatStore.shared.prefill = text }
                if body["selection"] as? Bool == true { browser.active?.askAIAboutSelection() }
                self.respond(connection, status: "200 OK", body: ["width": Preferences.shared.aiPanelWidth, "model": Preferences.shared.aiModel])
            }
            return
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
            return
        }
        guard request.method == "POST", request.path == "/call",
              let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let name = body["name"] as? String else {
            return respond(connection, status: "404 Not Found", body: ["error": "use POST /call"])
        }
        let arguments = body["arguments"] as? [String: Any] ?? [:]
        Task { @MainActor in
            // A call from a run of the panel that was stopped or replaced is not carried out, however late it comes.
            guard let caller = Self.caller(request.headers) else {
                return self.respond(connection, status: "200 OK", body: ToolResult.text("This run of the AI was stopped, so its calls are no longer accepted.", error: true).json)
            }
            let result = await ToolCatalog.call(name, arguments, caller: caller)
            self.respond(connection, status: "200 OK", body: result.json)
        }
    }

    /// The caller a request names, except that the panel's name counts only with the panel's secret: without it the
    /// request is an ordinary outside client that happens to use that name. With the secret, it counts only with the token of the
    /// run under way; nil for a request that has the secret and not that token (a run that was stopped).
    @MainActor
    static func caller(_ headers: [String: String]) -> String? {
        let name = headers["x-changmun-caller"] ?? "unknown"
        guard name == ChatStore.caller else { return name }
        guard sameSecret(headers["x-changmun-panel-secret"] ?? "", ChatStore.panelSecret) else { return "unverified-" + name }
        guard let token = ChatStore.shared.runToken, sameSecret(headers["x-changmun-run-token"] ?? "", token) else { return nil }
        return name
    }

    /// Compares without stopping at the first difference, so how long it takes says nothing about the secret.
    static func sameSecret(_ given: String, _ secret: String) -> Bool {
        let a = Array(given.utf8), b = Array(secret.utf8)
        var difference = a.count ^ b.count
        for i in 0..<b.count { difference |= Int((i < a.count ? a[i] : 0) ^ b[i]) }
        return difference == 0
    }

    private func respond(_ connection: NWConnection, status: String, body: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var data = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(json)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// An HTTP/1.1 request to the control server.
struct HTTPRequest {
    static let maxHead = 16 * 1024
    static let maxBody = 1 << 20

    enum Parse {
        case incomplete
        case complete(HTTPRequest)
        /// Answer with this status and close; the body of a request without the token is never read.
        case rejected(String)
    }

    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    static func parse(_ data: Data, token: String) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHead ? .rejected("431 Request Header Fields Too Large") : .incomplete
        }
        guard end.lowerBound - data.startIndex <= maxHead, let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            return .rejected("400 Bad Request")
        }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return .rejected("400 Bad Request") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["authorization"] == "Bearer \(token)" else { return .rejected("401 Unauthorized") }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= maxBody else {
            return .rejected("413 Content Too Large")
        }
        let bodyStart = end.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        return .complete(HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers,
                                     body: data.subdata(in: bodyStart..<(bodyStart + length))))
    }
}
