import Foundation
import os
import Security

/// What the test copy (Changmun Headless) has to run a client-certificate request against a local TLS server end to end, without touching the
/// user's keychains, search list or trust settings: identities from a keychain file of its own, a server certificate trusted by a test CA for
/// one host and port only, and the user's choice in the chooser given by the test. Nothing here is reachable outside the test copy
/// (see `/client-cert` in ControlServer+TestHooks.swift).
enum ClientCertificateTestHook {
    private struct State {
        var searchList: CFArray?
        var keychainPath: String?
        var anchors: [SecCertificate] = []
        var trustedHost: String?
        var trustedPorts: Set<Int> = []
        /// "first", "cancel", "last" or the name of the identity to choose; nil leaves the chooser to the user.
        var choice: String?
        var events: [String] = []
        var asked: [[String]] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Whether a test has put its own keychain in place: the headless app then answers certificate requests as a window on screen would.
    static var isActive: Bool { Headless.isTestCopy && state.withLock { $0.searchList != nil } }
    static var searchList: CFArray? { state.withLock { $0.searchList } }
    static var choice: String? { state.withLock { $0.choice } }

    static func record(_ event: String) {
        guard Headless.isTestCopy else { return }
        state.withLock { $0.events.append(event) }
    }

    static func recordAsked(_ names: [String]) { state.withLock { $0.asked.append(names) } }

    /// The events since the last call, and the lists the chooser was given (the names of the identities, in order).
    static func drain() -> (events: [String], asked: [[String]]) {
        state.withLock { state in
            defer { (state.events, state.asked) = ([], []) }
            return (state.events, state.asked)
        }
    }

    static func setChoice(_ choice: String?) { state.withLock { $0.choice = choice } }

    static func trust(host: String, ports: [Int], anchors: [SecCertificate]) {
        state.withLock { ($0.trustedHost, $0.trustedPorts, $0.anchors) = (host, Set(ports), anchors) }
    }

    /// The server's certificate judged against the test CA alone, for the one host and port a test named; nil for any other.
    static func credential(forServerTrust trust: SecTrust, host: String, port: Int) -> URLCredential? {
        let (anchors, trusted) = state.withLock { ($0.anchors, $0.trustedHost == host && $0.trustedPorts.contains(port)) }
        guard Headless.isTestCopy, trusted else { return nil }
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil) ? URLCredential(trust: trust) : nil
    }

    /// The Security calls for keychain files, which are deprecated but the only way to make one that is not added to the user's search list.
    /// Looked up by name so the release build stays free of deprecation warnings for test-only code.
    private typealias CreateKeychain = @convention(c) (UnsafePointer<CChar>, UInt32, UnsafeRawPointer?, Bool, AnyObject?, UnsafeMutablePointer<AnyObject?>) -> OSStatus
    private typealias DeleteKeychain = @convention(c) (AnyObject) -> OSStatus
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }
    }

    /// A keychain file at `path` holding the identities of the PKCS #12 files (and the certificates of the PEM or DER files), searched alone.
    /// Nil when it worked, else what went wrong.
    static func makeKeychain(at path: String, identities: [(file: String, password: String)], certificates: [String]) -> String? {
        guard let create = symbol("SecKeychainCreate", as: CreateKeychain.self) else { return "SecKeychainCreate is gone" }
        var made: AnyObject?
        let password = "test"
        guard create(path, UInt32(password.utf8.count), password, false, nil, &made) == errSecSuccess, let made else { return "create failed" }
        let keychain = unsafeDowncast(made, to: SecKeychain.self)
        func importFile(_ file: String, password: String?) -> OSStatus {
            guard let data = FileManager.default.contents(atPath: file) else { return errSecItemNotFound }
            var parameters = SecItemImportExportKeyParameters()
            parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
            parameters.passphrase = password.map { Unmanaged.passUnretained($0 as CFString) }
            var format = SecExternalFormat.formatUnknown
            var type = SecExternalItemType.itemTypeUnknown
            return SecItemImport(data as CFData, file as CFString, &format, &type, [], &parameters, keychain, nil)
        }
        for identity in identities {
            let status = importFile(identity.file, password: identity.password)
            if status != errSecSuccess { return "import \(identity.file): \(status)" }
        }
        for certificate in certificates {
            let status = importFile(certificate, password: nil)
            if status != errSecSuccess { return "import \(certificate): \(status)" }
        }
        state.withLock { ($0.searchList, $0.keychainPath) = ([keychain] as CFArray, path) }
        return nil
    }

    /// Takes the keychain file away and forgets what a test put in place.
    static func reset() {
        let old = state.withLock { state -> (CFArray?, String?) in
            defer { state = State() }
            return (state.searchList, state.keychainPath)
        }
        if let list = old.0 as? [AnyObject], let keychain = list.first, let delete = symbol("SecKeychainDelete", as: DeleteKeychain.self) { _ = delete(keychain) }
        if let path = old.1 { try? FileManager.default.removeItem(atPath: path) }
    }
}
