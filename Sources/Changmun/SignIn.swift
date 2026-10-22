import Foundation
import LocalAuthentication
import WebKit

/// The saved sign-ins the sign_in tool may use, looked up by the exact host of the page.
protocol LoginStore {
    /// The usernames saved for exactly this host (not its www or non-www twin), the most recently used first.
    func accounts(exactly host: String) -> [String]
    func password(exactly host: String, username: String) -> String?
}

/// The login keychain's saved sign-ins, as the settings list them.
struct KeychainLogins: LoginStore {
    func accounts(exactly host: String) -> [String] {
        Logins.accounts(exactly: host)
    }

    func password(exactly host: String, username: String) -> String? {
        Logins.password(exactly: host, username: username)
    }
}

/// What Changmun Headless has in place of the keychain, which it never touches: logins a test puts there.
final class MemoryLogins: LoginStore {
    static let shared = MemoryLogins()
    var items: [(host: String, username: String, password: String)] = []

    func accounts(exactly host: String) -> [String] {
        items.filter { $0.host == host }.map(\.username)
    }

    func password(exactly host: String, username: String) -> String? {
        items.first { $0.host == host && $0.username == username }?.password
    }
}

/// The sign_in tool: the app fills a saved login into the form of the page, and the AI is told only that it did. Neither the
/// password nor the account name is ever in anything that goes back to the AI.
enum SignIn {
    /// Tests give the tool their own store and their own way of confirming with the device owner.
    @TaskLocal static var store: LoginStore?
    @TaskLocal static var confirm: ((String) async -> Bool)?

    @MainActor static var activeStore: LoginStore { store ?? (Headless.isOn ? MemoryLogins.shared : KeychainLogins()) }

    /// Touch ID or the Mac's password, as the settings ask before they copy a saved password; every time, since the AI uses it.
    /// Changmun Headless has nobody to ask and holds only the logins a test put in memory.
    @MainActor static func confirmDeviceOwner(_ reason: String) async -> Bool {
        if let confirm { return await confirm(reason) }
        if Headless.isOn { return true }
        return (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }

    /// The host a saved login must be filed under for a document of this origin: only a page on https, with a host of its own
    /// and no port of its own (another port is another site). nil for anything else (http, a sandboxed frame, a data: page).
    nonisolated static func loginHost(ofOrigin origin: String) -> String? {
        guard let url = URL(string: origin), url.scheme?.lowercased() == "https" else { return nil }
        let site = Approvals.site(ofOrigin: origin)
        guard !site.isEmpty, let host = Approvals.hostname(ofSite: site), host == site else { return nil }
        return host
    }
}

extension ToolCatalog {
    private static func refused(_ text: String) -> ToolResult { .text("Error: \(text)", error: true) }

    /// What the AI is told whenever the sign-in wasn't done for a reason that has to do with the user's saved logins or their say: no
    /// saved login for the site, the user said no or didn't answer, they didn't confirm, or the password couldn't be read. One
    /// answer for all of them, so a page that talks the AI into trying can't tell from it which accounts are saved.
    static let signInNotDone = ToolResult.text("Error: The sign-in wasn't done. Don't retry it; tell the user what you wanted to do.", error: true)

    /// Fills the saved login for the site of the form into its username and password fields, without pressing anything. The page's
    /// exact host must be the saved login's host, on https; in a frame, the frame's host. The user is asked every time, with the
    /// site and the account (picking one when several are saved), and confirms with the device owner's authentication before the
    /// password is read. The AI is told whether it was done and never which account or what password.
    @MainActor
    static func signIn(_ args: [String: Any], tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        if tab.isPrivate { return refused("Saved logins are not used in private windows.") }
        var frame: WKFrameInfo?
        var wanted: [String: Any] = [:]
        if let id = int(args["element_id"]) {
            wanted["id"] = id
            switch await Self.frame(ofElement: id, in: tab) {
            case .failure(let failure): return failure.result
            case .success(let found): frame = found
            }
        }
        func ask(_ stage: String, _ extra: [String: Any] = [:]) async -> Look {
            look(await run(PageScripts.signIn, ["args": wanted.merging(["stage": stage]) { $1 }.merging(extra) { $1 }], in: webView, frame: frame))
        }
        guard case .answered(let found) = await ask("inspect") else { return refused("the page did not answer.") }
        switch found["error"] as? String {
        case "gone": return refused("that element is gone. Read the page again.")
        case "none": return refused("there is no sign-in form with a password field here. If the site asks for the username first, ask the user.")
        default: break
        }
        let origin = found["origin"] as? String ?? "null"
        guard let host = SignIn.loginHost(ofOrigin: origin) else {
            return refused("saved logins are used only on https pages (and frames) that have a host of their own, on the standard port.")
        }
        let shownHost = Approvals.shown(host, limit: 100).text
        // A form that sends what is typed in it to another site is not one to put a login in.
        if let action = found["action"] as? String, !action.isEmpty, Approvals.site(of: URL(string: action)) != Approvals.site(ofOrigin: origin) {
            return refused("the sign-in form on \(shownHost) sends to another site, so no login was filled in.")
        }
        // A tab the user isn't looking at is approved for one site; a frame of another is asked about.
        if let approved = session.approved, host != approved {
            let allowed = await Approvals.allowTab(tab, caller: session.caller, host: host)
            if session.stopped { return stopped }
            if !allowed { return declined }
        }
        // From here on, whatever goes wrong has the one answer: the AI can't tell whether a login is saved.
        let accounts = SignIn.activeStore.accounts(exactly: host)
        guard !accounts.isEmpty else { return signInNotDone }
        AgentActivity.shared.step(String(localized: "Signing in to \(shownHost)"), caller: session.caller)
        Approvals.noteRead(tab, readHost: host, caller: session.caller)
        // Using the page after reading other sites is asked about as for any other use; then the sign-in itself, every time.
        let used = await Approvals.allowInteraction(.act(String(localized: "Signing in to \(shownHost)")), on: tab, caller: session.caller, site: host)
        if session.stopped { return stopped }
        guard used else { return signInNotDone }
        let pageSite = Approvals.site(of: tab.url)
        let chosen = await Approvals.allowSignIn(host: host, accounts: accounts, page: pageSite == host ? nil : pageSite, caller: session.caller)
        if session.stopped { return stopped }
        guard let account = chosen else { return signInNotDone }
        guard await SignIn.confirmDeviceOwner(String(localized: "Authentication is required to let the AI sign in to \(shownHost)")) else { return signInNotDone }
        if session.stopped { return stopped }
        guard let password = SignIn.activeStore.password(exactly: host, username: account) else { return signInNotDone }
        // Whatever the page says back, none of it is passed on: only the words below.
        let filled = look(await run(PageScripts.signIn, ["args": wanted.merging(["stage": "fill", "expectOrigin": origin, "username": account, "password": password]) { $1 }],
                                    in: webView, frame: frame))
        guard case .answered(let done) = filled, done["error"] == nil else { return signInNotDone }
        return .text("Filled the saved login for \(shownHost) into the form (the user chose the account; the AI is not given it or the password). Nothing was submitted: click the page's sign-in button next.")
    }
}
