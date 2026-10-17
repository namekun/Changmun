import Foundation
import Security
import SwiftUI
import WebKit

/// Saved sign-ins, kept in the login keychain as internet passwords labelled "Changmun".
enum Logins {
    static let label = "Changmun"

    static func save(host: String, username: String, password: String) -> Bool {
        guard !host.isEmpty, !password.isEmpty, let secret = password.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: username,
            kSecAttrLabel as String: label,
        ]
        let status = SecItemAdd(query.merging([kSecValueData as String: secret, kSecAttrProtocol as String: kSecAttrProtocolHTTPS]) { $1 } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, [kSecValueData as String: secret] as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Usernames saved for a host (or its www/non-www twin). Reads no secrets, so it never prompts.
    static func accounts(for host: String) -> [String] {
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

    struct Saved: Identifiable, Hashable {
        var host: String
        var username: String
        var id: String { host + "\n" + username }
    }

    /// Every saved sign-in, without secrets.
    static func all() -> [Saved] {
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

    func fillLogin(username: String) {
        guard let webView, webView.url?.scheme == "https", let host = webView.url?.host(),
              let password = Logins.password(host: host, username: username) else { return }
        webView.callAsyncJavaScript(Logins.fillScript, arguments: ["username": username, "password": password], in: nil, in: .defaultClient) { _ in }
    }
}

struct LoginButton: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if !tab.savedLogins.isEmpty {
            Menu {
                ForEach(tab.savedLogins, id: \.self) { name in
                    Button(name.isEmpty ? "(아이디 없음)" : name) { tab.fillLogin(username: name) }
                }
            } label: {
                Image(systemName: "key.fill").font(.system(size: 10.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Theme.primary)
            .help("저장된 로그인 정보 채우기")
        }
    }
}
