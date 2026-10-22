import Foundation
import LocalAuthentication
import Security
import SwiftUI
import WebKit

/// Saved sign-ins, kept in the login keychain as internet passwords labelled "Changmun". Headless never touches them.
enum Logins {
    static let label = "Changmun"

    /// Updates the account where it is already saved (`example.com` or its `www.` twin), so filling never finds an old one.
    static func save(host: String, username: String, password: String) -> Bool {
        guard !Headless.isOn, !host.isEmpty, !password.isEmpty, let secret = password.data(using: .utf8) else { return false }
        let server = hostVariants(host).first { exists(server: $0, username: username) } ?? host
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: username,
            kSecAttrLabel as String: label,
        ]
        let status = SecItemAdd(query.merging([kSecValueData as String: secret, kSecAttrProtocol as String: kSecAttrProtocolHTTPS]) { $1 } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, [kSecValueData as String: secret] as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func exists(server: String, username: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: username,
            kSecAttrLabel as String: label,
            kSecReturnAttributes as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Usernames saved for a host (or its www/non-www twin). Reads no secrets, so it never prompts.
    static func accounts(for host: String) -> [String] {
        guard !Headless.isOn else { return [] }
        var names: [String] = []
        for candidate in hostVariants(host) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: candidate,
                kSecAttrLabel as String: label,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { continue }
            names += items.compactMap { $0[kSecAttrAccount as String] as? String }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    static func password(host: String, username: String) -> String? {
        guard !Headless.isOn else { return nil }
        for candidate in hostVariants(host) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: candidate,
                kSecAttrAccount as String: username,
                kSecAttrLabel as String: label,
                kSecReturnData as String: true,
            ]
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    /// The usernames saved under exactly this host, the most recently saved or updated first.
    static func accounts(exactly host: String) -> [String] {
        guard !Headless.isOn else { return [] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrLabel as String: label,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        let recent = items.sorted { ($0[kSecAttrModificationDate as String] as? Date ?? .distantPast) > ($1[kSecAttrModificationDate as String] as? Date ?? .distantPast) }
        return recent.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// The password saved under exactly this host, not under its www or non-www twin.
    static func password(exactly host: String, username: String) -> String? {
        guard !Headless.isOn else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: username,
            kSecAttrLabel as String: label,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    struct Saved: Identifiable, Hashable {
        var host: String
        var username: String
        var id: String { host + "\n" + username }
    }

    /// Every saved sign-in, without secrets.
    static func all() -> [Saved] {
        guard !Headless.isOn else { return [] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let host = item[kSecAttrServer as String] as? String else { return nil }
            return Saved(host: host, username: item[kSecAttrAccount as String] as? String ?? "")
        }
        .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    @discardableResult
    static func delete(host: String, username: String) -> Bool {
        guard !Headless.isOn else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: username,
            kSecAttrLabel as String: label,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    static func hostVariants(_ host: String) -> [String] {
        host.hasPrefix("www.") ? [host, String(host.dropFirst(4))] : [host, "www." + host]
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
        guard let webView, webView.url?.scheme == "https", let host = webView.url?.host() else { savedLogins = []; return }
        let accounts = Logins.accounts(for: host)
        guard !accounts.isEmpty else { savedLogins = []; return }
        webView.evaluateJavaScript("!!document.querySelector('input[type=password], input[autocomplete=username]')") { [weak self] value, _ in
            Task { @MainActor in self?.savedLogins = (value as? Bool == true) ? accounts : [] }
        }
    }

    /// Fills a saved login into the page the user is on, after the device owner has confirmed (unless they turned that off).
    func fillLogin(username: String, authorization: FillAuthorization? = nil, readPassword: @escaping (String, String) -> String? = Logins.password(host:username:)) {
        guard let webView, webView.url?.scheme == "https", let host = webView.url?.host() else { return }
        Task { @MainActor [weak self] in
            guard let password = await (authorization ?? .shared).read({ readPassword(host, username) }) else { return }
            // The user may have moved on while the question was open: the password only goes to the site it was chosen for.
            guard let self, self.webView?.url?.host() == host else { return }
            self.fill(username: username, password: password)
        }
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
