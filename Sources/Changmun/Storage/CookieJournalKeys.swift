import CryptoKit
import Foundation
import Security

/// Where the cookie journal's key is kept. Reading it may block (the keychain can ask the user), so it is only called off the main thread.
enum JournalKey {
    case key(SymmetricKey)
    /// There is none (and none was asked to be made).
    case missing
    /// It can't be had: the user said no, the keychain is locked, or it failed. Not tried again by the journal in this run.
    case unavailable
}

protocol CookieJournalKeys: Sendable {
    func key(create: Bool) -> JournalKey
    func remove()
}

/// The real key: 256 random bits in the login keychain, a generic password named "Changmun Cookie Journal" that is readable only while the
/// Mac is unlocked and never leaves it. Its access list is the app that made it, so another program asking for it gets the system's question.
struct KeychainJournalKeys: CookieJournalKeys {
    static let name = "Changmun Cookie Journal"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.name, kSecAttrLabel as String: Self.name]
    }

    func key(create: Bool) -> JournalKey {
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &found)
        if status == errSecSuccess {
            guard let data = found as? Data, data.count == 32 else { return .unavailable }
            return .key(SymmetricKey(data: data))
        }
        guard status == errSecItemNotFound else { return .unavailable }
        guard create else { return .missing }
        let fresh = SymmetricKey(size: .bits256)
        let add = query.merging([
            kSecValueData as String: fresh.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? .key(fresh) : .unavailable
    }

    func remove() { SecItemDelete(query as CFDictionary) }
}

/// The headless apps never touch the keychain, so theirs is a file beside the journal (mode 0600). That only keeps the cookies from being
/// read at a glance: it is for the test copy and the agents' app, not for the user's browsing.
struct FileJournalKeys: CookieJournalKeys {
    let file: URL

    func key(create: Bool) -> JournalKey {
        if let data = try? Data(contentsOf: file) { return data.count == 32 ? .key(SymmetricKey(data: data)) : .unavailable }
        guard create else { return .missing }
        let fresh = SymmetricKey(size: .bits256)
        return DurableFile.write(fresh.withUnsafeBytes { Data($0) }, to: file) ? .key(fresh) : .unavailable
    }

    func remove() { try? FileManager.default.removeItem(at: file) }
}

/// A key kept in memory, for tests: the user's keychain is never reached.
final class MemoryJournalKeys: CookieJournalKeys, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SymmetricKey?
    private var blocked: Bool

    init(key: SymmetricKey? = nil, unavailable: Bool = false) {
        stored = key
        blocked = unavailable
    }

    var hasKey: Bool { lock.withLock { stored != nil } }

    func key(create: Bool) -> JournalKey {
        lock.withLock {
            if blocked { return .unavailable }
            if let stored { return .key(stored) }
            guard create else { return .missing }
            let fresh = SymmetricKey(size: .bits256)
            stored = fresh
            return .key(fresh)
        }
    }

    func remove() { lock.withLock { stored = nil } }
}
