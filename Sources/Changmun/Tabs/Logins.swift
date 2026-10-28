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

    func set(server: String, account: String, secret: Data) -> Bool {
        let add = query(server, account).merging([kSecValueData as String: secret, kSecAttrProtocol as String: kSecAttrProtocolHTTPS]) { $1 }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(query(server, account) as CFDictionary, [kSecValueData as String: secret] as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }

    func remove(server: String, account: String) -> Bool {
        SecItemDelete(query(server, account) as CFDictionary) == errSecSuccess
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

    /// What a page's logins are saved under: its host, and its port when that isn't the scheme's own (localhost:3000 and localhost:8080
    /// are two sites to sign in to, though one host).
    static func key(for url: URL) -> String? {
        guard let host = url.host(), !host.isEmpty else { return nil }
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
    /// Shows the key button when the page asks for a password and one is saved for its host.
    func checkForLogins() {
        // Not on a page whose certificate the user went on with, though it could not be verified: a saved password is for the site it was saved for.
        guard let webView, webView.url?.scheme == "https", !Self.isUnverified(webView.url), let host = webView.url.flatMap(Logins.key(for:)) else { savedLogins = []; return }
        let accounts = Logins.accounts(for: host)
        guard !accounts.isEmpty else { savedLogins = []; return }
        webView.evaluateJavaScript("!!document.querySelector('input[type=password], input[autocomplete=username]')") { [weak self] value, _ in
            Task { @MainActor in self?.savedLogins = (value as? Bool == true) ? accounts : [] }
        }
    }

    /// Fills a saved login into the page the user is on, after the device owner has confirmed (unless they turned that off).
    func fillLogin(username: String, authorization: FillAuthorization? = nil, readPassword: @escaping (String, String) -> String? = Logins.password(host:username:)) {
        guard let webView, let origin = Self.httpsOrigin(webView.url), !Self.isUnverified(webView.url) else { return }
        let host = webView.url.flatMap(Logins.key(for:)) ?? origin.host
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
                ForEach(tab.savedLogins, id: \.self) { name in
                    Button(name.isEmpty ? String(localized: "(No username)") : name) { tab.fillLogin(username: name) }
                }
            } label: {
                Image(systemName: "key.fill").font(.system(size: 10.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Theme.primary)
            .help("Fill in saved login")
        }
    }
}
