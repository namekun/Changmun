import Foundation
import LocalAuthentication
import Security
import SwiftUI
import WebKit

/// Where the saved sign-ins are kept. The login keychain; a test gives its own, in memory, and so never touches the real one.
protocol LoginBackend {
    /// What is saved for the server (everything for nil): no secrets, so reading it never prompts.
    func records(server: String?) -> [Logins.Record]
    func secret(server: String, account: String) -> Data?
    /// Saves the secret, or changes it where the account is already saved.
    func set(server: String, account: String, secret: Data) -> Bool
    func remove(server: String, account: String) -> Bool
}

struct KeychainBackend: LoginBackend {
    private func query(_ server: String?, _ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrLabel as String: Logins.label]
        if let server { query[kSecAttrServer as String] = server }
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    func records(server: String?) -> [Logins.Record] {
        var result: CFTypeRef?
        let search = query(server).merging([kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]) { $1 }
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let server = item[kSecAttrServer as String] as? String else { return nil }
            return Logins.Record(server: server, account: item[kSecAttrAccount as String] as? String ?? "", modified: item[kSecAttrModificationDate as String] as? Date)
        }
    }

    func secret(server: String, account: String) -> Data? {
        var result: CFTypeRef?
        let search = query(server, account).merging([kSecReturnData as String: true]) { $1 }
        return SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    // Every change goes through `set` and `remove` (saving, importing, deleting), which tell `Logins.recordCache` it is out of date.
    func set(server: String, account: String, secret: Data) -> Bool {
        defer { Logins.recordCache.invalidate() }
        let add = query(server, account).merging([kSecValueData as String: secret, kSecAttrProtocol as String: kSecAttrProtocolHTTPS]) { $1 }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(query(server, account) as CFDictionary, [kSecValueData as String: secret] as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }

    func remove(server: String, account: String) -> Bool {
        defer { Logins.recordCache.invalidate() }
        return SecItemDelete(query(server, account) as CFDictionary) == errSecSuccess
    }
}

/// Saved sign-ins, kept in the login keychain as internet passwords labelled "Changmun". Headless never touches them.
enum Logins {
    static let label = "Changmun"

    struct Record {
        var server: String
        var account: String
        var modified: Date?
    }

    /// Tests set their own, so they never touch the keychain.
    @TaskLocal static var testBackend: LoginBackend?
    private static var backend: LoginBackend { testBackend ?? KeychainBackend() }

    /// What is saved, without secrets, kept in memory so that a page's sign-in fields don't ask the keychain at every load and focus.
    /// Dropped whenever Changmun changes an item; a change made elsewhere (Keychain Access) shows within `RecordCache.ttl`, as macOS
    /// no longer says when the keychain changes.
    static let recordCache = RecordCache { KeychainBackend().records(server: nil) }

    /// Reads the saved records once, off the main thread, so the first page with a sign-in field doesn't wait for the keychain.
    static func preload() {
        guard !Headless.isOn else { return }
        DispatchQueue.global(qos: .utility).async { _ = recordCache.records() }
    }

    final class RecordCache: @unchecked Sendable {
        static let ttl: TimeInterval = 30
        private let lock = NSLock()
        private let source: () -> [Record]
        private let now: () -> Date
        private var kept: [Record]?
        private var keptAt = Date.distantPast
        /// Counts the times it was dropped, so that a read that began before a change doesn't keep what it read.
        private(set) var generation = 0

        init(now: @escaping () -> Date = Date.init, source: @escaping () -> [Record]) {
            self.now = now
            self.source = source
        }

        func records() -> [Record] {
            let (kept, generation) = lock.withLock { (now().timeIntervalSince(keptAt) < Self.ttl ? self.kept : nil, self.generation) }
            if let kept { return kept }
            let read = source()
            lock.withLock {
                guard self.generation == generation else { return }
                self.kept = read
                keptAt = now()
            }
            return read
        }

        func invalidate() {
            lock.withLock {
                kept = nil
                generation += 1
            }
        }
    }

    /// What a page's logins are saved under: its host, and its port when that isn't the scheme's own (localhost:3000 and localhost:8080
    /// are two sites to sign in to, though one host).
    ///
    /// The host is the one WebKit reports for a page, which has a non-ASCII name in punycode (`xn--bcher-kva.de`); asked this way Foundation gives
    /// the same for an address typed with the letters (`bücher.de`), where its plain `host()` gives them percent-encoded and so another key.
    static func key(for url: URL) -> String? {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        guard let port = url.port, port != (url.scheme == "http" ? 80 : 443) else { return host }
        return "\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }

    /// The host name of a key, without its port.
    static func hostname(ofKey key: String) -> String {
        if key.hasPrefix("["), let end = key.firstIndex(of: "]") { return String(key[key.index(after: key.startIndex)..<end]) }
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 ? String(parts[0]) : key
    }

    /// Updates the account where it is already saved (`example.com` or its `www.` twin), so filling never finds an old one.
    /// For a port's key with no login of its own but one saved before ports were part of the key (under the bare host or its twin),
    /// the login moves to the port's key and the old item goes, so the old password is not left to fill elsewhere.
    static func save(host: String, username: String, password: String) -> Bool {
        guard !Headless.isOn, !host.isEmpty, !password.isEmpty, let secret = password.data(using: .utf8) else { return false }
        if let server = hostVariants(host).first(where: { exists(server: $0, username: username) }) {
            return backend.set(server: server, account: username, secret: secret)
        }
        let bare = hostname(ofKey: host)
        guard bare != host, let legacy = hostVariants(bare).first(where: { exists(server: $0, username: username) }) else {
            return backend.set(server: host, account: username, secret: secret)
        }
        guard backend.set(server: host, account: username, secret: secret) else { return false }
        _ = backend.remove(server: legacy, account: username)
        return true
    }

    enum ImportOutcome: Equatable {
        case saved, unchanged, kept, failed
    }

    /// Saves a login from another browser, but never over one Changmun has for the same site and account: that one is the newer.
    static func importLogin(host: String, username: String, password: String) -> ImportOutcome {
        guard !Headless.isOn, !host.isEmpty, !password.isEmpty, let secret = password.data(using: .utf8) else { return .failed }
        if let saved = hostVariants(host).first(where: { exists(server: $0, username: username) }) {
            return backend.secret(server: saved, account: username) == secret ? .unchanged : .kept
        }
        return backend.set(server: host, account: username, secret: secret) ? .saved : .failed
    }

    private static func exists(server: String, username: String) -> Bool {
        backend.records(server: server).contains { $0.account == username }
    }

    /// Usernames saved for a host (or its www/non-www twin). Reads no secrets, so it never prompts.
    static func accounts(for host: String) -> [String] {
        guard !Headless.isOn else { return [] }
        var seen = Set<String>()
        return lookupVariants(host).flatMap { backend.records(server: $0).map(\.account) }.filter { seen.insert($0).inserted }
    }

    static func password(host: String, username: String) -> String? {
        guard !Headless.isOn else { return nil }
        for candidate in lookupVariants(host) {
            if let data = backend.secret(server: candidate, account: username) { return String(data: data, encoding: .utf8) }
        }
        return nil
    }

    /// The usernames saved under exactly this host, the most recently saved or updated first.
    static func accounts(exactly host: String) -> [String] {
        guard !Headless.isOn else { return [] }
        return backend.records(server: host).sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }.map(\.account)
    }

    /// The password saved under exactly this host, not under its www or non-www twin.
    static func password(exactly host: String, username: String) -> String? {
        guard !Headless.isOn else { return nil }
        return backend.secret(server: host, account: username).flatMap { String(data: $0, encoding: .utf8) }
    }

    struct Saved: Identifiable, Hashable {
        var host: String
        var username: String
        var id: String { host + "\n" + username }
    }

    /// Every saved sign-in, without secrets.
    static func all() -> [Saved] {
        guard !Headless.isOn else { return [] }
        return backend.records(server: nil).map { Saved(host: $0.server, username: $0.account) }
            .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    @discardableResult
    static func delete(host: String, username: String) -> Bool {
        guard !Headless.isOn else { return false }
        return backend.remove(server: host, account: username)
    }

    /// A saved account offered to fill a page: the key it is saved under, and whether that is the page's own (its key, the key's www
    /// twin, or the bare host for a port's key, as `accounts(for:)` looks) or another host of the same site.
    struct Match: Hashable {
        var host: String
        var username: String
        var sameHost: Bool

        /// What the menus show: the name, and for another host's login the host it was saved for, so it is never taken for this one's.
        var title: String {
            let name = username.isEmpty ? String(localized: "(No username)") : username
            return sameHost ? name : "\(name) — \(host)"
        }
    }

    /// The accounts to offer a page whose logins are saved under `key`: its own first, as `accounts(for:)` has them, then those saved
    /// for other hosts of the same site (`mayShare`), by host. Saving is unchanged: a login is still saved under the page's own key.
    /// Reads no secrets, so it never prompts. The AI's sign_in never uses this: it goes by the exact host (`accounts(exactly:)`).
    static func matches(for key: String) -> [Match] {
        guard !Headless.isOn else { return [] }
        let records = testBackend.map { $0.records(server: nil) } ?? recordCache.records()
        let variants = lookupVariants(key).map { $0.lowercased() }
        var seen = Set<String>()
        let own = variants.flatMap { variant in records.filter { $0.server.lowercased() == variant } }
            .map(\.account).filter { seen.insert($0).inserted }
            .map { Match(host: key, username: $0, sameHost: true) }
        let ownHosts = Set(variants)
        let shared = records
            .filter { !ownHosts.contains($0.server.lowercased()) && mayShare($0.server, with: key) }
            .sorted { ($0.server, $0.account) < ($1.server, $1.account) }
            .map { Match(host: $0.server, username: $0.account, sameHost: false) }
        return own + shared
    }

    /// Whether a login saved under `saved` may be offered on a page whose key is `key`, being another host of the same site: the same
    /// registrable domain by the Public Suffix List (`PublicSuffix`), and the same port. It fails closed: never for an IP address, a name
    /// of one label, a name that is a public suffix itself, or without the list. The list's private section keeps the subdomains of
    /// shared hosting apart (alice.github.io is not bob.github.io's site), as its country suffixes keep apart a.co.kr and b.co.kr.
    /// The keys carry no scheme: http is kept apart because nothing is offered on a page that isn't https.
    static func mayShare(_ saved: String, with key: String) -> Bool {
        let saved = saved.lowercased(), key = key.lowercased()
        let savedHost = hostname(ofKey: saved), keyHost = hostname(ofKey: key)
        // The port is what follows the host in the key ("" for the scheme's own), and must be the same.
        guard saved.dropFirst(savedHost.count) == key.dropFirst(keyHost.count), !saved.hasPrefix("["), !key.hasPrefix("["),
              SiteIndex.isHostName(keyHost), SiteIndex.isHostName(savedHost), let list = PublicSuffix.list,
              let domain = list.registrableDomain(keyHost), !list.isPublicSuffix(domain) else { return false }
        return list.registrableDomain(savedHost) == domain
    }

    static func hostVariants(_ host: String) -> [String] {
        host.hasPrefix("www.") ? [host, String(host.dropFirst(4))] : [host, "www." + host]
    }

    /// Where to look for a page's logins: under its key and the key's www twin, and for a port's key also under the bare host, where
    /// logins saved before the port was part of the key are (they were for the host on any port).
    private static func lookupVariants(_ key: String) -> [String] {
        let bare = hostname(ofKey: key)
        return hostVariants(key) + (bare == key ? [] : hostVariants(bare))
    }

    static let fillScript = """
    const visible = e => e.offsetParent !== null || e.getClientRects().length > 0;
    const pw = [...document.querySelectorAll('input[type=password]')].find(visible) || null;
    let user = null;
    const scope = (pw && pw.form) || document;
    const fields = [...scope.querySelectorAll('input')].filter(e => /^(text|email|tel|)$/.test(e.type) && visible(e));
    if (pw) {
      user = fields.filter(e => e.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING).pop() || null;
    }
    user = user || document.querySelector('input[autocomplete=username], input[type=email]');
    const set = (el, v) => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
      el.dispatchEvent(new Event('input', {bubbles: true}));
      el.dispatchEvent(new Event('change', {bubbles: true}));
    };
    if (user && username) set(user, username);
    if (pw) { set(pw, password); pw.setAttribute('data-cm-secret', ''); }
    return !!(user || pw);
    """
}

/// The device owner's say before a saved password is read to fill a page: Touch ID or the Mac's password, as for copying one
/// in the settings and for the AI's sign-in. Once confirmed, further fills within `grace` seconds need no new question, so
/// filling two forms in a row asks once. Cancelling fills nothing. The setting "Require Touch ID to fill passwords" turns it off.
@MainActor
final class FillAuthorization {
    static let shared = FillAuthorization()
    static let grace: TimeInterval = 60

    private let required: @MainActor () -> Bool
    private let confirm: (String) async -> Bool
    private let now: () -> Date
    private var confirmedAt: Date?
    private var asking = false

    /// Changmun Headless has nobody to ask (and no keychain), so it goes without, as the other paths do.
    init(required: @escaping @MainActor () -> Bool = { Preferences.shared.requireAuthToFill },
         confirm: @escaping (String) async -> Bool = FillAuthorization.askDeviceOwner,
         now: @escaping () -> Date = Date.init) {
        self.required = required
        self.confirm = confirm
        self.now = now
    }

    /// The password from `read`, which is not called until the device owner has confirmed (or the setting is off, or they
    /// confirmed less than `grace` seconds ago). nil when they declined, or while another question is still open.
    func read(_ read: () -> String?) async -> String? {
        if required(), !Headless.isOn, !withinGrace {
            guard !asking else { return nil }
            asking = true
            defer { asking = false }
            guard await confirm(String(localized: "Authentication is required to fill the saved password")) else { return nil }
            confirmedAt = now()
        }
        return read()
    }

    private var withinGrace: Bool {
        confirmedAt.map { now().timeIntervalSince($0) < Self.grace } ?? false
    }

    nonisolated private static func askDeviceOwner(_ reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }
}

extension Tab {
    /// The saved accounts to offer on a page's key, as the key button and the menu under a field ask (tests put their own: a WebKit
    /// callback can't see a task-local backend).
    /// The default reads off the main thread (`Logins.recordCache`, kept in memory, mostly answers without the keychain).
    nonisolated(unsafe) static var loginAccounts: (String) async -> [Logins.Match] = { key in
        await Task.detached(priority: .userInitiated) { Logins.matches(for: key) }.value
    }

    /// Shows the key button when the page asks for a password and one is saved for its host or another host of its site. Asked when
    /// the page finishes, and again whenever a password field comes or goes after that (`LoginFormWatcher`).
    func checkForLogins() {
        loginCheck += 1
        let check = loginCheck
        // Not on a page whose certificate the user went on with, though it could not be verified: a saved password is for the site it was saved for.
        guard let webView, webView.url?.scheme == "https", !Self.isUnverified(webView.url), let host = webView.url.flatMap(Logins.key(for:)) else { savedLogins = []; return }
        // The saved logins are looked up only once the page shows a sign-in field.
        webView.evaluateJavaScript("!!document.querySelector('input[type=password], input[autocomplete=username]')") { [weak self] value, _ in
            Task { @MainActor in
                guard let self, self.loginCheck == check else { return }
                guard value as? Bool == true else { self.savedLogins = []; return }
                let accounts = await Self.loginAccounts(host)
                // A later look, or another page, has the say.
                guard self.loginCheck == check, self.webView?.url.flatMap(Logins.key(for:)) == host else { return }
                self.savedLogins = accounts
            }
        }
    }

    /// Fills a saved login into the page the user is on, after the device owner has confirmed (unless they turned that off).
    func fillLogin(_ match: Logins.Match, authorization: FillAuthorization? = nil) {
        fillLogin(username: match.username, savedUnder: match.sameHost ? nil : match.host, authorization: authorization)
    }

    /// `savedUnder` is the key of another host of the site the login was saved for (nil: the page's own). It is checked again against
    /// the page as it is now, which may have moved to another site since the menu was drawn.
    func fillLogin(username: String, savedUnder: String? = nil, authorization: FillAuthorization? = nil,
                   readPassword: @escaping (String, String) -> String? = Logins.password(host:username:)) {
        guard let webView, let origin = Self.httpsOrigin(webView.url), !Self.isUnverified(webView.url) else { return }
        let pageKey = webView.url.flatMap(Logins.key(for:)) ?? origin.host
        if let savedUnder, !Logins.mayShare(savedUnder, with: pageKey) { return }
        let host = savedUnder ?? pageKey
        Task { @MainActor [weak self] in
            guard let password = await (authorization ?? .shared).read({ readPassword(host, username) }) else { return }
            // The page may have moved on while the question was open (to http, another port, another site): the password
            // goes only to the origin it was chosen for.
            guard let self, Self.httpsOrigin(self.webView?.url) == origin, !Self.isUnverified(self.webView?.url) else { return }
            self.fill(username: username, password: password)
        }
    }

    /// The scheme, host and port of an https address; nil for anything else.
    private static func httpsOrigin(_ url: URL?) -> Origin? {
        guard let url, url.scheme == "https", let host = url.host() else { return nil }
        return Origin(host: host, port: url.port ?? 443)
    }

    private struct Origin: Equatable {
        let host: String
        let port: Int
    }

    func fill(username: String, password: String) {
        webView?.appScript(Logins.fillScript, arguments: ["username": username, "password": password])
    }
}

struct LoginButton: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if !tab.savedLogins.isEmpty {
            Menu {
                ForEach(tab.savedLogins, id: \.self) { match in
                    Button(match.title) { tab.fillLogin(match) }
                }
            } label: {
                Image(systemName: "key").font(.symbolInline)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Theme.primary)
            .help("Fill in saved login")
            .accessibilityLabel(String(localized: "Fill in saved login"))
        }
    }
}
