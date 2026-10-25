import AppKit
import Combine
import WebKit

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
    nonisolated static let unknownFrame = Site.unknownFrame
    /// Stands for an image the user added from outside the browser (a file, the clipboard): a source of its own, which no tab is on.
    nonisolated static let addedImage = Site.addedImage

    /// The site an address is on, as what was read and allowed is remembered: its exact host, lowercased and in the ASCII form
    /// of an international name (www.example.com and shop.example.com are two sites, so are two sites on one hosting service),
    /// with the port when it isn't the scheme's own (another port is another site), and with "http://" in front for an
    /// unencrypted page (http and https are two sites); a page with no host (a file:, data: or blob: page) is a site by its
    /// scheme; nil for a blank page. See `Site.site(of:)`.
    nonisolated static func site(of url: URL?) -> String? { Site.site(of: url) }

    /// The host name of a site as `site(of:)` writes it (without "http://" and the port): nil for a site that has none.
    nonisolated static func hostname(ofSite site: String) -> String? { Site.hostname(ofSite: site) }

    /// The site an origin names ("https://example.com:8443"): "" for an origin that has none (a sandboxed frame, a data: page).
    nonisolated static func site(ofOrigin origin: String) -> String { Site.site(ofOrigin: origin) }

    /// Whether a site is one a user could allow for a chat: not "" and not a page that only has a scheme (file:).
    static func hasSite(_ site: String) -> Bool { Site.hasSite(site) }

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
        guard Preferences.shared.aiApprovalMode.asksAboutOtherSites, let browser = tab.browser else { return true }
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
        guard Preferences.shared.aiApprovalMode.asksAboutOtherSites else { return true }
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
        guard Preferences.shared.aiApprovalMode.asksAboutOtherSites else { return true }
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
        if let site = readHost ?? site(of: tab.url), readHosts[caller, default: []].insert(site).inserted { changes.send() }
    }

    /// Records that the AI was given pictures of these sites (a page screenshot the user attached) or of an unknown source (an image
    /// the user added): later actions on any other site are asked about, as after reading it.
    static func noteRead(sites: [String], caller: String) {
        let before = readHosts[caller]?.count ?? 0
        readHosts[caller, default: []].formUnion(sites)
        if (readHosts[caller]?.count ?? 0) != before { changes.send() }
    }


    static func route(caller: String, irreversible: Bool, accounts: [String], panelOpen: Bool, signIn: Bool = false) -> Route {
        caller == ChatStore.caller && panelOpen && !irreversible && !signIn && accounts.count < 2 ? .card : .sheet
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


    /// Using a page hands it something the AI chose, or lets it see what the AI does; after reading other sites, the user
    /// is asked for each of those, and says yes: once, or for the site until the chat is cleared, but only for as long as
    /// the sites read are those it was allowed with (reading another site takes it back). Typing and choosing show what
    /// is typed or chosen. `site` is where it happens when that isn't the tab's own site: a frame of another site, or "" for
    /// a document with no site, which no allowance covers.
    /// In the mode that asks before every action, the use of a page is asked about even when nothing else was read; `everyActionAsks: false`
    /// leaves that out for a use that is asked about on its own right after (the sign-in).
    static func allowInteraction(_ interaction: Interaction, on tab: Tab, caller: String, site: String? = nil, mark: Mark? = nil, everyActionAsks: Bool = true) async -> Bool {
        var mode = Preferences.shared.aiApprovalMode
        if mode == .everyAction && !everyActionAsks { mode = .afterReading }
        guard mode != .irreversibleOnly else { return true }
        let host = site ?? Self.site(of: tab.url) ?? ""
        let read = readHosts[caller, default: []]
        let others = read.subtracting([host])
        if !asksForInteraction(mode, readOtherSites: !others.isEmpty) { return true }
        // What is typed or chosen is shown whole, or said to be cut: text whose end the user can't see is asked about each time.
        let text: (text: String, cut: Int, altered: Bool)
        switch interaction {
        case .type(let value), .choose(let value), .act(let value): text = shownWithNote(value, limit: 500)
        }
        let allowable = text.cut == 0 && !text.altered && hasSite(host)
        if allowable, let granted = allowances[caller]?[host], others.isSubset(of: granted) { return true }
        let target = host.isEmpty ? String(localized: "this page") : display(host)
        let sites = others.sorted().prefix(5).map(display).joined(separator: ", ") + (others.count > 5 ? " +\(others.count - 5)" : "")
        let message: String, label: String
        switch interaction {
        case .type:
            message = String(localized: "The AI wants to type into \(target)")
            label = String(localized: "Text to type:")
        case .choose:
            message = String(localized: "The AI wants to choose an option on \(target)")
            label = String(localized: "Option to choose:")
        case .act:
            message = String(localized: "The AI wants to use \(target)")
            label = String(localized: "Action:")
        }
        // Nothing else was read (the mode that asks before every action): no line about what was read, and the reason is the user's own choice.
        let why = others.isEmpty ? String(localized: "You chose to be asked before every action.") : String(localized: "A page you read earlier could have slipped instructions into this.")
        let readLine = others.isEmpty ? "" : String(localized: "Read earlier in this chat: \(sites)")
        let detail = "\(target)\n\n\(label)\n\(text.text)\n\n" + (readLine.isEmpty ? "" : "\(readLine)\n") + why
        let forChat = hasChat(caller) && allowable
        let answer = await choose(message, detail,
                                  [(.deny, String(localized: "Don’t Allow")), (.once, String(localized: "Allow Once"))]
                                  + (forChat ? [(.site, String(localized: "Allow on \(display(host)) for This Chat"))] : []),
                                  parts: Prompt.Parts(site: target, readLine: readLine, label: label, text: text.text, why: why), mark: mark, caller: caller)
        if answer == .site, forChat {
            allowances[caller, default: [:]][host] = read
            changes.send()
        }
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

    static func display(_ host: String) -> String {
        host == unknownFrame ? String(localized: "a frame of an unknown site") : host == addedImage ? String(localized: "an image you added") : host
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
                            markupOnly: Bool = false, mark: Mark? = nil) async -> Bool {
        let host = site ?? Self.site(of: tab.url) ?? ""
        let allowable = hasSite(host)
        if tier == .low, markupOnly {
            let place = host.isEmpty ? String(localized: "this page") : display(host)
            return await choose(String(localized: "The AI wants to click a button in what the page calls a cookie banner"),
                                "\(place)\n\n“\(shown(quotable(abbreviated(name))).text)”\n\n" + String(localized: "Only the page’s own markup says this is a cookie banner, and a page can say that of anything, so you are asked every time."),
                                [(.deny, String(localized: "Don’t Allow")), (.once, String(localized: "Allow Once"))], irreversible: true, caller: caller) != .deny
        }
        if tier == .low, allowable, lowAllowed[caller]?.contains(host) == true { return true }
        let place = host.isEmpty ? String(localized: "this page") : display(host)
        let words = shown(quotable(abbreviated(name))).text
        if tier == .high {
            let sent = destination.map { String(localized: "The form sends what is typed in it to \(display($0)), another site than this page.") + "\n\n" } ?? ""
            return await choose(String(localized: "The AI wants to do something that can’t be undone"),
                                "\(place)\n\n“\(words)”\n\n" + sent + String(localized: "This looks like paying, ordering, sending, posting, deleting or granting access, which can’t be taken back, so you are asked every time."),
                                [(.deny, String(localized: "Don’t Allow")), (.once, String(localized: "Allow Once"))], irreversible: true, caller: caller) != .deny
        }
        let forChat = hasChat(caller) && allowable
        let why = String(localized: "This looks like a cookie banner or a setting, not like paying or sending.")
        let answer = await choose(String(localized: "The AI wants to accept cookies or change a setting"),
                                  "\(place)\n\n“\(words)”\n\n" + why,
                                  [(.deny, String(localized: "Don’t Allow")), (.once, String(localized: "Allow Once"))]
                                  + (forChat ? [(.site, String(localized: "Allow on \(display(host)) for This Chat"))] : []),
                                  parts: Prompt.Parts(site: place, text: "“\(words)”", why: why), mark: mark, caller: caller)
        if answer == .site, forChat {
            lowAllowed[caller, default: []].insert(host)
            changes.send()
        }
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
                             [(.deny, String(localized: "Close"))], signIn: true, caller: caller)
            return nil
        }
        guard let only = accounts.first, accounts.count == 1 else {
            let answer = await choose(String(localized: "Let the AI sign in to \(site)?"), "\(site)\n\n\(inFrame)" + String(localized: "Pick the account to sign in with.") + "\n\n\(explanation)",
                                      buttons, accounts: accounts, signIn: true, caller: caller)
            return answer.choice == .once && accounts.indices.contains(answer.account) ? accounts[answer.account] : nil
        }
        let account = accountTitle(only)
        return await choose(String(localized: "Let the AI sign in to \(site) as \(account)?"), "\(site)\n\(account)\n\n\(inFrame)\(explanation)", buttons, signIn: true, caller: caller) == .once ? only : nil
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

    /// The callers heard from so far (see `noteCaller`).
    private static var heard: Set<String> = []

    /// An MCP client is its bridge process (`mcp-<pid>-<id>`), and its entries here are of no use once that process has ended. The
    /// first call of a caller not heard from before is the cheap moment to forget the callers whose process is gone.
    static func noteCaller(_ caller: String) {
        guard caller.hasPrefix("mcp-"), heard.insert(caller).inserted else { return }
        forgetEndedCallers()
    }

    /// The process ID in the name of an MCP client (nil for any other caller: the panel, the command line, a headless test).
    static func bridgePID(of caller: String) -> pid_t? {
        let parts = caller.split(separator: "-", maxSplits: 2)
        guard parts.count == 3, parts[0] == "mcp" else { return nil }
        return pid_t(parts[1])
    }

    /// Forgets the MCP clients whose process has ended; `alive` says whether a process is still there.
    static func forgetEndedCallers(alive: (pid_t) -> Bool = { kill($0, 0) == 0 || errno != ESRCH }) {
        let callers = Set(tabs.keys).union(urls.keys).union(readHosts.keys).union(chatBegan.keys).union(allowances.keys)
            .union(lowAllowed.keys).union(heard)
        for caller in callers where bridgePID(of: caller).map({ !alive($0) }) == true {
            tabs[caller] = nil
            urls[caller] = nil
            readHosts[caller] = nil
            chatBegan[caller] = nil
            allowances[caller] = nil
            lowAllowed[caller] = nil
            heard.remove(caller)
            SignIn.forgetDeclined(caller: caller)
            AgentActivity.shared.forget(caller: caller)
        }
    }

    /// Whether anything is still remembered of a caller (tests).
    static func remembers(caller: String) -> Bool {
        tabs[caller] != nil || urls[caller] != nil || readHosts[caller] != nil || chatBegan[caller] != nil
            || allowances[caller] != nil || lowAllowed[caller] != nil || heard.contains(caller)
            || SignIn.wasDeclinedAnywhere(caller: caller) || AgentActivity.shared.stopCount(for: caller) != 0
    }

    /// A new chat starts without anything read or allowed; other callers keep theirs.
    static func forgetReads(caller: String) {
        readHosts[caller] = nil
        allowances[caller] = nil
        lowAllowed[caller] = nil
        SignIn.forgetDeclined(caller: caller)
        chatBegan[caller] = Date()
        changes.send()
    }

    /// Tells those showing what a caller has read and been allowed that it changed.
    static let changes = PassthroughSubject<Void, Never>()

    /// The sites the caller's AI has been given the content of since its chat began, in the way they are shown to the user.
    static func sitesRead(caller: String) -> [String] {
        (readHosts[caller] ?? []).sorted()
    }

    /// The sites on which the caller's AI acts without asking for as long as the chat lasts: the actions of the low tier, and the use of
    /// the page after reading other sites, which holds only for as long as the sites read are those it was allowed with.
    static func sitesAllowed(caller: String) -> [String] {
        let read = readHosts[caller] ?? []
        var sites = lowAllowed[caller] ?? []
        for (host, granted) in allowances[caller] ?? [:] where read.subtracting([host]).isSubset(of: granted) { sites.insert(host) }
        return sites.sorted()
    }

    /// Takes back what the user allowed the caller on a site: the next action there is asked about again. Nothing else changes.
    static func revoke(site: String, caller: String) {
        allowances[caller]?[site] = nil
        lowAllowed[caller]?.remove(site)
        changes.send()
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

    private static func choose(_ message: String, _ detail: String, _ buttons: [(Choice, String)], irreversible: Bool = false, signIn: Bool = false,
                               parts: Prompt.Parts? = nil, mark: Mark? = nil, caller: String) async -> Choice {
        await choose(message, detail, buttons, accounts: [], irreversible: irreversible, signIn: signIn, parts: parts, mark: mark, caller: caller).choice
    }

    /// Asks in the chat panel when the panel's AI asks with the panel open (see `route`), else on the browser window, the first button being
    /// the one Return presses; no answer within `timeout` counts as no, so a late yes never runs a stale request. With `accounts`, the
    /// question carries a list to pick one from (the first is chosen to begin with), and says which.
    private static func choose(_ message: String, _ detail: String, _ buttons: [(Choice, String)], accounts: [String], irreversible: Bool = false, signIn: Bool = false,
                               parts: Prompt.Parts? = nil, mark: Mark? = nil, caller: String) async -> (choice: Choice, account: Int) {
        let prompt = Prompt(message: message, detail: detail, choices: buttons.map(\.0), accounts: accounts, irreversible: irreversible, parts: parts)
        let standing = stand ?? (Headless.isOn ? headless : nil)
        if let standing {
            if standing.asked.count > 100 { standing.asked.removeFirst(standing.asked.count - 100) }
            standing.asked.append(prompt)
            if !standing.holds { return (standing.answer(prompt), min(max(standing.pick(prompt), 0), max(accounts.count - 1, 0))) }
        }
        // The panel is where the user can see it: docked in the front window, or in the window it was popped out into.
        let panel = Browser.recent.flatMap { browser -> Browser? in browser.showChat && !browser.focusMode ? browser : nil } ?? ChatPopOut.shared.panelBrowser
        // A stand that holds its questions shows them as the app would, so that what a person would see can be looked at.
        let inPanel = (standing == nil || standing?.holds == true) && route(caller: caller, irreversible: irreversible, accounts: accounts, panelOpen: panel != nil, signIn: signIn) == .card
        guard standing != nil || inPanel || Browser.recent?.window != nil else { return (.deny, 0) }
        let list = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        if standing == nil { NSApp?.requestUserAttention(.informationalRequest) }
        return await withCheckedContinuation { continuation in
            let once = Once()
            let id = UUID()
            var end: () -> Void = {}
            let finish = { (choice: Choice, account: Int) in
                guard !once.done else { return }
                once.done = true
                pending.removeAll { $0.id == id }
                ApprovalCards.shared.remove(id)
                if inPanel { mark?.clear() }
                continuation.resume(returning: (choice, account))
            }
            let showSheet = {
                guard standing == nil else { return }
                guard let window = Browser.recent?.window else {
                    finish(.deny, 0)
                    return
                }
                let alert = NSAlert()
                alert.messageText = message
                alert.informativeText = detail
                for (_, title) in buttons { alert.addButton(withTitle: title) }
                if accounts.count > 1 {
                    list.addItems(withTitles: accounts.map(accountTitle))
                    alert.accessoryView = list
                }
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
            if inPanel, let panel {
                // The panel closing with the question open moves it to the window, where it can't be missed.
                ApprovalCards.shared.add(ApprovalCards.Card(id: id, prompt: prompt, buttons: buttons, browser: panel, answer: { finish($0, 0) }, moveToSheet: showSheet))
                if ChatPopOut.shared.isPoppedOut(for: panel) { ChatPopOut.shared.revealForQuestion() }
                if let mark {
                    Task {
                        if !once.done { await mark.show() }
                        if once.done { mark.clear() }
                    }
                }
            } else {
                showSheet()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !once.done else { return }
                finish(.deny, 0)
                end()
            }
        }
    }
}
