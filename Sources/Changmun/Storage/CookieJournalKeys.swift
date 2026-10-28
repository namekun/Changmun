import CryptoKit
import Foundation
import Security

enum JournalKey {
    case key(SymmetricKey)
    /// There is none (and none was asked to be made).
    case missing
    /// It can't be had: the user said no, the keychain is locked, or it failed. The code is the system's reason (or -1), for the log.
    case unavailable(code: Int32)
}

/// Where the cookie journal's key is kept. Reading it may block (the keychain can ask the user), so it is only called off the main thread.
protocol CookieJournalKeys: Sendable {
    func key(create: Bool) -> JournalKey
    func remove()
}

/// The real key: 256 random bits in the login keychain, a generic password named "Changmun Cookie Journal", not synchronizable, so it doesn't
/// leave this Mac through iCloud. The login keychain (a file) ignores `kSecAttrAccessible`, so none is set: what protects the key is the keychain's
/// own lock and its access list, which names the app that made the item (Changmun's code signature); another program asking for it gets the
/// system's question, and a user who answers it, or a process running as the user with the keychain's password, can still read it.
struct KeychainJournalKeys: CookieJournalKeys {
    static let name = "Changmun Cookie Journal"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.name, kSecAttrLabel as String: Self.name]
    }

    func key(create: Bool) -> JournalKey {
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &found)
        if status == errSecSuccess {
            guard let data = found as? Data, data.count == 32 else { return .unavailable(code: -1) }
            return .key(SymmetricKey(data: data))
        }
        guard status == errSecItemNotFound else { return .unavailable(code: status) }
        guard create else { return .missing }
        let fresh = SymmetricKey(size: .bits256)
        let add = query.merging([kSecValueData as String: fresh.withUnsafeBytes { Data($0) }, kSecAttrSynchronizable as String: false]) { $1 }
        let added = SecItemAdd(add as CFDictionary, nil)
        return added == errSecSuccess ? .key(fresh) : .unavailable(code: added)
    }

    func remove() { SecItemDelete(query as CFDictionary) }
}

/// The headless apps never touch the keychain, so theirs is a file beside the journal (mode 0600, left out of backups). That only keeps the cookies
/// from being read at a glance: it is for the test copy and the agents' app, not for the user's browsing, and the headless apps keep no sign-ins
/// unless they are told to.
struct FileJournalKeys: CookieJournalKeys {
    let file: URL

    func key(create: Bool) -> JournalKey {
        if let data = try? Data(contentsOf: file) { return data.count == 32 ? .key(SymmetricKey(data: data)) : .unavailable(code: -1) }
        guard create else { return .missing }
        let fresh = SymmetricKey(size: .bits256)
        guard DurableFile.write(fresh.withUnsafeBytes { Data($0) }, to: file) else { return .unavailable(code: -1) }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var file = self.file
        try? file.setResourceValues(values)
        return .key(fresh)
    }

    func remove() { try? FileManager.default.removeItem(at: file) }
}

/// A key kept in memory, for tests: the user's keychain is never reached.
final class MemoryJournalKeys: CookieJournalKeys, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SymmetricKey?
    private var blocked: Bool
    private var asked = 0

    init(key: SymmetricKey? = nil, unavailable: Bool = false) {
        stored = key
        blocked = unavailable
    }

    var hasKey: Bool { lock.withLock { stored != nil } }
    /// How many times the key was asked for.
    var attempts: Int { lock.withLock { asked } }
    func setUnavailable(_ on: Bool) { lock.withLock { blocked = on } }

    func key(create: Bool) -> JournalKey {
        lock.withLock {
            asked += 1
            if blocked { return .unavailable(code: -1) }
            if let stored { return .key(stored) }
            guard create else { return .missing }
            let fresh = SymmetricKey(size: .bits256)
            stored = fresh
            return .key(fresh)
        }
    }

    func remove() { lock.withLock { stored = nil } }
}
