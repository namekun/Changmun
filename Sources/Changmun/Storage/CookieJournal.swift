import CryptoKit
import Foundation
import WebKit

/// One cookie as the journal keeps it: every attribute WebKit gives, so a restored cookie behaves as the one it was.
struct CookieRecord: Codable, Equatable {
    var name: String
    var value: String
    var domain: String
    var path: String
    /// Nil for a session cookie, which the site meant to end with the browser.
    var expires: Date?
    var secure: Bool
    var httpOnly: Bool
    /// "lax" or "strict"; nil for none.
    var sameSite: String?

    init(name: String, value: String, domain: String, path: String, expires: Date? = nil, secure: Bool = false, httpOnly: Bool = false, sameSite: String? = nil) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
    }

    init(_ cookie: HTTPCookie) {
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, expires: cookie.expiresDate,
                  secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly, sameSite: cookie.sameSitePolicy?.rawValue)
    }

    /// What makes it the same cookie: one with this name, domain and path replaces the other.
    var key: String { Self.key(name: name, domain: domain, path: path) }

    static func key(name: String, domain: String, path: String) -> String { [domain.lowercased(), name, path].joined(separator: "\n") }

    func isExpired(at now: Date) -> Bool { expires.map { $0 <= now } ?? false }

    var cookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if let expires { properties[.expires] = expires }
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite, [HTTPCookieStringPolicy.sameSiteLax, .sameSiteStrict].contains(where: { $0.rawValue == sameSite }) { properties[.sameSitePolicy] = HTTPCookieStringPolicy(rawValue: sameSite) }
        return HTTPCookie(properties: properties)
    }
}

/// The journal's file: sealed with AES-GCM under a key that is not in the file. The header (a magic, then the format's version) and the store's
/// name are authenticated, so a file can't be passed off as another store's, nor an old or new format as this one.
enum CookieJournalFile {
    static let magic = Data("CMCJ".utf8)
    static let version: UInt8 = 1

    private struct Payload: Codable {
        var saved: Date
        var cookies: [CookieRecord]
    }

    private static func authenticated(_ id: String) -> Data { magic + Data([version]) + Data(id.utf8) }

    static func seal(_ records: [CookieRecord], store id: String, key: SymmetricKey, saved: Date = Date()) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let plain = try? encoder.encode(Payload(saved: saved, cookies: records)),
              let box = try? AES.GCM.seal(plain, using: key, authenticating: authenticated(id)),
              let combined = box.combined else { return nil }
        return magic + Data([version]) + combined
    }

    /// The cookies in the file, or nil when it is none of ours: damaged, cut short, another version, another store's, sealed with another key.
    static func open(_ data: Data, store id: String, key: SymmetricKey) -> [CookieRecord]? {
        guard data.count > magic.count + 1, data.prefix(magic.count) == magic, data[data.startIndex + magic.count] == version,
              let box = try? AES.GCM.SealedBox(combined: data.dropFirst(magic.count + 1)),
              let plain = try? AES.GCM.open(box, using: key, authenticating: authenticated(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(Payload.self, from: plain))?.cookies
    }

    /// The cookies the journal has that the store lacks and that are still good: a cookie the store has, whatever its value, is newer than the
    /// journal's and stays. A session cookie (no expiry) comes back as a session cookie of this run.
    static func missing(from records: [CookieRecord], in store: [HTTPCookie], now: Date) -> [HTTPCookie] {
        var have = Set(store.map { CookieRecord.key(name: $0.name, domain: $0.domain, path: $0.path) })
        var restored: [HTTPCookie] = []
        for record in records where !record.isExpired(at: now) && !have.contains(record.key) {
            guard let cookie = record.cookie else { continue }
            have.insert(record.key)
            restored.append(cookie)
        }
        return restored
    }
}

/// The journal's files in one folder, one per data store, and the key that seals them. Everything runs on one queue, in order: a delete never
/// comes before a write it should follow.
final class CookieJournalFiles: @unchecked Sendable {
    enum Read {
        case missing
        /// The file is there but isn't usable (damaged, tampered with, another key or version, or the key can't be had).
        case unusable
        /// Couldn't be read at all (permissions, a disk fault): says nothing about what it holds.
        case unreadable
        case records([CookieRecord])
    }

    let folder: URL
    private let keys: CookieJournalKeys
    private let queue = DispatchQueue(label: "Changmun.cookie-journal", qos: .utility)
    private var cached: SymmetricKey?
    private var blocked = false

    init(folder: URL, keys: CookieJournalKeys) {
        self.folder = folder
        self.keys = keys
    }

    /// Only names the journal makes itself: a store's id is a UUID or "default".
    static func isValid(_ id: String) -> Bool { !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }

    func url(_ id: String) -> URL { folder.appendingPathComponent(id + ".journal") }

    private func key(create: Bool) -> SymmetricKey? {
        if let cached { return cached }
        guard !blocked else { return nil }
        switch keys.key(create: create) {
        case .key(let key): cached = key; return key
        case .missing: return nil
        case .unavailable: blocked = true; return nil
        }
    }

    private func prepareFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func read(_ id: String) async -> Read {
        await run { [self] in
            guard Self.isValid(id) else { return .unusable }
            switch DurableFile.FileRead(url(id)) {
            case .missing: return .missing
            case .unreadable: return .unreadable
            case .data(let data):
                guard let key = key(create: false), let records = CookieJournalFile.open(data, store: id, key: key) else { return .unusable }
                return .records(records)
            }
        }
    }

    /// An empty list takes the file away. False when it couldn't be written (no key, no room).
    @discardableResult
    func write(_ id: String, _ records: [CookieRecord]) async -> Bool {
        await run { [self] in
            guard Self.isValid(id) else { return false }
            if records.isEmpty {
                try? FileManager.default.removeItem(at: url(id))
                return true
            }
            prepareFolder()
            guard let key = key(create: true), let data = CookieJournalFile.seal(records, store: id, key: key) else { return false }
            return DurableFile.write(data, to: url(id))
        }
    }

    func remove(_ id: String) async {
        await run { [self] in if Self.isValid(id) { try? FileManager.default.removeItem(at: url(id)) } }
    }

    /// Every file but those of the stores named.
    func removeFiles(except keep: Set<String> = []) async {
        await run { [self] in
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".journal") {
                if !keep.contains(String(name.dropLast(".journal".count))) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
            }
        }
    }

    /// All the files and the key: there is nothing left that could open anything.
    func removeEverything() async {
        await removeFiles()
        await run { [self] in
            keys.remove()
            cached = nil
            blocked = false
        }
    }

    /// Returns once everything asked before it is done.
    func drain() async { await run { () -> Void in } }

    private func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: work()) } }
    }
}

/// A store's cookies, as the journal sees them: WebKit's for the real thing, a fake for tests.
@MainActor
protocol CookieSource: AnyObject {
    func allCookies() async -> [HTTPCookie]
    func setCookie(_ cookie: HTTPCookie) async
    /// `change` is called, on the main thread, whenever the store's cookies changed.
    func startObserving(_ change: @escaping @MainActor () -> Void)
    func stopObserving()
}

@MainActor
final class WebKitCookieSource: NSObject, CookieSource, WKHTTPCookieStoreObserver {
    /// Held, so the store (and the observer on its cookies) lives as long as the journal watches it.
    private let store: WKWebsiteDataStore
    private var change: (@MainActor () -> Void)?

    init(_ store: WKWebsiteDataStore) { self.store = store }

    func allCookies() async -> [HTTPCookie] { await store.httpCookieStore.allCookies() }
    func setCookie(_ cookie: HTTPCookie) async { await store.httpCookieStore.setCookie(cookie) }

    func startObserving(_ change: @escaping @MainActor () -> Void) {
        guard self.change == nil else { return }
        self.change = change
        store.httpCookieStore.add(self)
    }

    func stopObserving() {
        guard change != nil else { return }
        change = nil
        store.httpCookieStore.remove(self)
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        MainActor.assumeIsolated { change?() }
    }
}

/// Keeps the sign-ins that sites meant to end with the browser. WebKit holds a session cookie (one with no expiry) only in memory, so quitting
/// signs the user out everywhere; Safari and Chrome bring them back when they restore the session, and the journal does the same. It watches each
/// persistent data store (the default one and every profile's, never a private window's), writes the store's cookies, session and persistent
/// alike, to an encrypted file shortly after they change, and puts back at launch the ones the store lacks.
///
/// A store is `restoring` until its file has been read and merged, and only then `live`: nothing is written before that, so a store that
/// is still empty at launch can't replace what the journal holds. `off` is for a journal that is switched off or has no key.
@MainActor
final class CookieJournal {
    enum Phase: Equatable { case restoring, live, off }

    private final class Tracker {
        let source: CookieSource
        var phase = Phase.restoring
        /// Raised when the file is thrown away, so a snapshot taken before that is not written after it.
        var epoch = 0
        var pending: Task<Void, Never>?
        var lastDigest: SHA256.Digest?
        var restoring: Task<Void, Never>?
        init(_ source: CookieSource) { self.source = source }
    }

    let files: CookieJournalFiles
    private let debounce: Duration
    private let now: () -> Date
    private var trackers: [String: Tracker] = [:]
    private var inFlight = 0
    private(set) var enabled: Bool
    /// How many cookies the last restore put back, for tests and the one line the log gets.
    private(set) var restoredCount = 0

    init(folder: URL, keys: CookieJournalKeys, enabled: Bool, debounce: Duration = .seconds(2), now: @escaping () -> Date = Date.init) {
        files = CookieJournalFiles(folder: folder, keys: keys)
        self.enabled = enabled
        self.debounce = debounce
        self.now = now
    }

    /// The app's own: its files in Application Support/Changmun/Cookies, sealed with a key from the keychain (the headless apps keep theirs in a
    /// file, and anything that isn't the app, like the test runner, in memory: none of them touches the user's keychain).
    static let shared: CookieJournal = {
        let folder = Library.folder.appendingPathComponent("Cookies", isDirectory: true)
        let keys: CookieJournalKeys
        if Bundle.main.bundleIdentifier == "io.github.namekun.Changmun" {
            keys = KeychainJournalKeys()
        } else if Headless.isOn {
            keys = FileJournalKeys(file: folder.appendingPathComponent("journal.key"))
        } else {
            keys = MemoryJournalKeys()
        }
        return CookieJournal(folder: folder, keys: keys, enabled: UserDefaults.standard.object(forKey: "keepSessionCookies") as? Bool ?? true)
    }()

    func phase(of id: String) -> Phase? { trackers[id]?.phase }

    /// Work that would be lost if the app ended now: a change not yet written, or a write on its way.
    var hasPendingWork: Bool { inFlight > 0 || trackers.values.contains { $0.pending != nil } }

    // MARK: Watching a store

    /// Starts watching the store: its file is read and merged into it, and then, and not before, it is observed and written. Calling it again for
    /// the same id does nothing but wait for the first to finish. A journal that is off watches nothing.
    func attach(_ id: String, _ source: CookieSource) async {
        if let known = trackers[id] {
            await known.restoring?.value
            return
        }
        let tracker = Tracker(source)
        trackers[id] = tracker
        guard enabled, CookieJournalFiles.isValid(id) else { tracker.phase = .off; return }
        let restoring = Task { await self.restore(id, tracker) }
        tracker.restoring = restoring
        await restoring.value
    }

    /// For a store made while the app runs (a new profile): nothing to wait for, since there is nothing to put back before its first page.
    func attachInBackground(_ id: String, _ source: CookieSource) {
        Task { await attach(id, source) }
    }

    private func restore(_ id: String, _ tracker: Tracker) async {
        let read = await files.read(id)
        // Unreadable says nothing about what the file holds, so it is left alone: not read now, not overwritten later.
        if case .unreadable = read { tracker.phase = .off; return }
        if case .records(let records) = read, !records.isEmpty {
            let fresh = CookieJournalFile.missing(from: records, in: await tracker.source.allCookies(), now: now())
            for cookie in fresh { await tracker.source.setCookie(cookie) }
            restoredCount += fresh.count
            NSLog("Changmun: the cookie journal put back %d cookies", fresh.count)
        }
        // The setting may have been turned off while the file was being read.
        guard enabled else { tracker.phase = .off; return }
        goLive(id, tracker)
    }

    private func goLive(_ id: String, _ tracker: Tracker) {
        tracker.phase = .live
        tracker.source.startObserving { [weak self] in self?.changed(id) }
        // The store as it is now, merged: the file then says what the store has, which also takes away what it no longer has.
        changed(id)
    }

    /// The store's cookies changed: they are written once they have been still for a moment.
    func changed(_ id: String) {
        guard let tracker = trackers[id], tracker.phase == .live else { return }
        tracker.pending?.cancel()
        tracker.pending = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.snapshot(id)
        }
    }

    private func snapshot(_ id: String) async {
        guard let tracker = trackers[id], tracker.phase == .live, enabled else { return }
        tracker.pending = nil
        inFlight += 1
        defer { inFlight -= 1 }
        let epoch = tracker.epoch
        let records = await tracker.source.allCookies().map(CookieRecord.init)
        // Switched off, or the file thrown away, while the cookies were being read.
        guard tracker.phase == .live, tracker.epoch == epoch, enabled else { return }
        let digest = Self.digest(records)
        guard digest != tracker.lastDigest else { return }
        let written = await files.write(id, records)
        // Only what was written is remembered as written, so a failed write is tried again with the next change.
        if written, tracker.epoch == epoch { tracker.lastDigest = digest }
    }

    /// The same set of cookies has the same digest, whatever order WebKit lists them in.
    nonisolated static func digest(_ records: [CookieRecord]) -> SHA256.Digest {
        var hash = SHA256()
        for record in records.sorted(by: { $0.key < $1.key }) {
            hash.update(data: Data("\(record.key)\n\(record.value)\n\(record.expires?.timeIntervalSince1970 ?? -1)\n\(record.secure)\(record.httpOnly)\(record.sameSite ?? "-")\u{0}".utf8))
        }
        return hash.finalize()
    }

    // MARK: Taking it all back

    /// Writes what is waiting, now; the quit waits for it. Gives up after `limit`.
    func flush(within limit: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task { await self.flushAll(); once.resume() }
            Task { try? await Task.sleep(for: limit); once.resume() }
        }
    }

    private func flushAll() async {
        for (id, tracker) in trackers where tracker.pending != nil {
            tracker.pending?.cancel()
            await snapshot(id)
        }
        await files.drain()
    }

    /// The store's data is erased (a profile deleted): its file goes and it is no longer watched.
    func forget(_ id: String) {
        if let tracker = trackers.removeValue(forKey: id) {
            tracker.epoch += 1
            tracker.pending?.cancel()
            tracker.source.stopObserving()
        }
        Task { await files.remove(id) }
    }

    /// Site data is being cleared (Settings › Privacy): the files go now, and what is waiting is dropped. The stores go on being watched; once the
    /// clearing is done `cleared()` writes what is left.
    func clearing() {
        for tracker in trackers.values {
            tracker.epoch += 1
            tracker.pending?.cancel()
            tracker.pending = nil
            tracker.lastDigest = nil
        }
        Task { await files.removeFiles() }
    }

    func cleared() {
        for id in trackers.keys { changed(id) }
    }

    /// The switch in Settings › Privacy. Off: the files and the key go, and nothing more is written. On: every store is written as it is.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            for (id, tracker) in trackers where tracker.phase == .off && CookieJournalFiles.isValid(id) { goLive(id, tracker) }
        } else {
            for tracker in trackers.values {
                tracker.phase = .off
                tracker.epoch += 1
                tracker.pending?.cancel()
                tracker.pending = nil
                tracker.lastDigest = nil
                tracker.source.stopObserving()
            }
            Task { await files.removeEverything() }
        }
    }

    /// Files of stores that are no longer there (a profile whose deletion was never finished) are not kept.
    func removeOrphans(keeping ids: Set<String>) {
        Task { await files.removeFiles(except: ids.union(trackers.keys).union(["default"])) }
    }
}

/// Resumes a continuation once, whichever of the things racing to do it gets there first.
@MainActor
final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

extension CookieJournal {
    /// The default store's cookies and each profile's, put back: the app waits for this before it opens a window. Files of stores that are gone go.
    func restoreAtLaunch(profiles spaces: [Space]) async {
        let ids = spaces.compactMap(\.dataStoreID)
        await attach("default", WebKitCookieSource(.default()))
        for id in ids { await attach(id.uuidString, WebKitCookieSource(Profiles.dataStore(id))) }
        removeOrphans(keeping: Set(ids.map(\.uuidString)))
    }
}
