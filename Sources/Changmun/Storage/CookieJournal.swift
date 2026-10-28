import CryptoKit
import Foundation
import WebKit

/// How a journalled cookie was first seen: the value, and when it was first written to the journal. A cookie that is written again with
/// the value it had keeps the date, so its time in the journal counts from the first.
struct CookieSeen: Equatable, Sendable {
    var value: String
    var saved: Date
}

/// One session cookie as the journal keeps it: every attribute WebKit gives, so a restored cookie behaves as the one it was.
/// Only session cookies (no expiry) are kept: WebKit keeps the others itself.
struct CookieRecord: Codable, Equatable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var httpOnly: Bool
    /// "lax" or "strict"; nil for none.
    var sameSite: String?
    /// When it was first journalled.
    var saved: Date

    init(name: String, value: String, domain: String, path: String, secure: Bool = false, httpOnly: Bool = false, sameSite: String? = nil, saved: Date = Date()) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
        self.saved = saved
    }

    /// What a cookie's properties may hold for the journal to know all of it. A cookie with another property (a partition key, say, or anything a
    /// later system adds) is not one the journal can give back as it was, so it is left out rather than kept as something else.
    static let knownProperties: Set<String> = [
        "Name", "Value", "Domain", "Path", "Secure", "HttpOnly", "SameSite", "Version", "Discard", "OriginURL", "Port", "Comment", "CommentURL", "Max-Age",
        "Created", "SetByJavaScript",
    ]

    static func canKeep(_ properties: [HTTPCookiePropertyKey: Any]?) -> Bool {
        (properties ?? [:]).keys.allSatisfy { knownProperties.contains($0.rawValue) }
    }

    /// Nil for a cookie that isn't a plain session cookie: one that lasts beyond the session (WebKit keeps it), or one with an attribute that isn't known.
    init?(_ cookie: HTTPCookie, saved: Date) {
        guard cookie.expiresDate == nil, cookie.isSessionOnly, Self.canKeep(cookie.properties) else { return nil }
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, secure: cookie.isSecure,
                  httpOnly: cookie.isHTTPOnly, sameSite: cookie.sameSitePolicy?.rawValue, saved: saved)
    }

    /// What makes it the same cookie: one with this name, domain and path replaces the other.
    var key: String { Self.key(name: name, domain: domain, path: path) }

    static func key(name: String, domain: String, path: String) -> String { [domain.lowercased(), name, path].joined(separator: "\n") }

    var seen: CookieSeen { CookieSeen(value: value, saved: saved) }

    var cookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
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
    /// How long a cookie stays in the journal, counted from when it was first written there.
    static let lifetime: TimeInterval = 30 * 86_400

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

    static func isOld(_ saved: Date, at now: Date) -> Bool { now.timeIntervalSince(saved) >= lifetime }

    /// The records that are still good: not older than the lifetime, and the first of each cookie.
    static func usable(_ records: [CookieRecord], now: Date) -> [CookieRecord] {
        var seen = Set<String>()
        return records.filter { !isOld($0.saved, at: now) && seen.insert($0.key).inserted }
    }

    /// The store's session cookies as the journal keeps them: each with the date it was first written (its old one while its value is the same),
    /// none older than the lifetime, in an order that doesn't depend on the order WebKit lists them in.
    static func records(from cookies: [HTTPCookie], known: [String: CookieSeen], now: Date) -> [CookieRecord] {
        var byKey: [String: CookieRecord] = [:]
        for cookie in cookies {
            guard var record = CookieRecord(cookie, saved: now) else { continue }
            if let before = known[record.key], before.value == record.value { record.saved = before.saved }
            guard !isOld(record.saved, at: now) else { continue }
            byKey[record.key] = record
        }
        return byKey.values.sorted { $0.key < $1.key }
    }

    /// The cookies the journal has that the store lacks and that are still good: a cookie the store has, whatever its value, is newer than the
    /// journal's and stays. They come back as session cookies of this run.
    static func missing(from records: [CookieRecord], in store: [HTTPCookie], now: Date) -> [HTTPCookie] {
        var have = Set(store.map { CookieRecord.key(name: $0.name, domain: $0.domain, path: $0.path) })
        var restored: [HTTPCookie] = []
        for record in usable(records, now: now) where !have.contains(record.key) {
            guard let cookie = record.cookie else { continue }
            have.insert(record.key)
            restored.append(cookie)
        }
        return restored
    }
}

/// When a snapshot is due: once the cookies have been still for a while, but never later than a longest wait after the first change since the
/// last one (a page that keeps refreshing its cookies would otherwise keep it away), and not before the time a failed attempt asked to wait.
enum CookieJournalSchedule {
    /// Seconds from `now`; zero or less means now.
    static func delay(now: Date, firstChange: Date, lastChange: Date, notBefore: Date?, quiet: TimeInterval, maxWait: TimeInterval) -> TimeInterval {
        var due = min(lastChange.addingTimeInterval(quiet), firstChange.addingTimeInterval(maxWait))
        if let notBefore { due = max(due, notBefore) }
        return due.timeIntervalSince(now)
    }
}

/// The journal's files in one folder, one per data store, and the key that seals them. Everything runs on one queue, in order: a delete never
/// comes before a write it should follow. A write is checked against the store's generation inside the queue, just before it is made, so one that
/// was asked for before the files were thrown away (or the journal turned off) can't come back after them.
final class CookieJournalFiles: @unchecked Sendable {
    enum Read {
        case missing
        /// The file is there but isn't usable (damaged, tampered with, another key or version).
        case unusable
        /// Couldn't be read at all (permissions, a disk fault): says nothing about what it holds.
        case unreadable
        /// The file is there, but the key can't be had; `retryAfter` is when it will be tried again, nil when it won't be.
        case noKey(retryAfter: Date?)
        case records([CookieRecord])
    }

    enum Snapshot {
        case written(digest: SHA256.Digest, known: [String: CookieSeen])
        case unchanged(known: [String: CookieSeen])
        /// Asked for before the files were thrown away or the journal turned off: not made.
        case skipped
        /// The key can't be had: nothing was written, and no file was touched.
        case noKey(retryAfter: Date?)
        case failed
    }

    static let maxKeyTries = 3

    let folder: URL
    private let keys: CookieJournalKeys
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval
    private let queue = DispatchQueue(label: "Changmun.cookie-journal", qos: .utility)
    // Used on the queue only.
    private var cached: SymmetricKey?
    private var keyFailures = 0
    private var keyRetryAt: Date?
    private var folderPrepared = false
    // Used from anywhere.
    private let lock = NSLock()
    private var base = 0
    private var generations: [String: Int] = [:]
    private var operations = 0

    init(folder: URL, keys: CookieJournalKeys, retryDelay: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder
        self.keys = keys
        self.retryDelay = retryDelay
        self.now = now
    }

    /// Only names the journal makes itself: a store's id is a UUID or "default".
    static func isValid(_ id: String) -> Bool { !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }

    func url(_ id: String) -> URL { folder.appendingPathComponent(id + ".journal") }

    // MARK: Generations

    func generation(_ id: String) -> Int { lock.withLock { base + (generations[id] ?? 0) } }

    /// Writes asked for before this are not made.
    func revoke(_ id: String) { lock.withLock { generations[id, default: 0] += 1 } }
    func revokeAll() { lock.withLock { base += 1 } }

    /// Deletions asked for and not yet done.
    var pendingOperations: Int { lock.withLock { operations } }

    // MARK: The key

    private enum KeyResult {
        case key(SymmetricKey)
        case missing
        case unavailable(retryAfter: Date?)
    }

    /// On the queue. A key that can't be had is not asked for again at once (it may be the user's "Deny" or a locked keychain): after a wait, a few times.
    private func key(create: Bool) -> KeyResult {
        if let cached { return .key(cached) }
        if keyFailures >= Self.maxKeyTries { return .unavailable(retryAfter: nil) }
        if let keyRetryAt, now() < keyRetryAt { return .unavailable(retryAfter: keyRetryAt) }
        switch keys.key(create: create) {
        case .key(let key):
            keyFailures = 0
            keyRetryAt = nil
            cached = key
            return .key(key)
        case .missing:
            return .missing
        case .unavailable(let code):
            keyFailures += 1
            // The reason code only: nothing that was in a cookie.
            NSLog("Changmun: the cookie journal can't use its key (code %d, attempt %d of %d)", Int(code), keyFailures, Self.maxKeyTries)
            keyRetryAt = keyFailures < Self.maxKeyTries ? now().addingTimeInterval(retryDelay) : nil
            return .unavailable(retryAfter: keyRetryAt)
        }
    }

    /// On the queue: whether the key is known not to be there for now, without asking for it.
    private func keyBlocked() -> Date?? {
        if cached != nil { return nil }
        if keyFailures >= Self.maxKeyTries { return .some(nil) }
        if let keyRetryAt, now() < keyRetryAt { return .some(keyRetryAt) }
        return nil
    }

    private func prepareFolder() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: folder.path) {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            folderPrepared = false
        }
        // Not in a backup, nor in what a restore brings back to another Mac.
        if !folderPrepared {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var folder = self.folder
            try? folder.setResourceValues(values)
            folderPrepared = true
        }
    }

    /// A write cut short (the app ended in the middle of it) leaves its temporary file, which holds data or the key: it goes.
    private func removeStaleTemporaries() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(".") && name.hasSuffix(".tmp") {
            unlink(folder.appendingPathComponent(name).path)
        }
    }

    // MARK: Reading and writing

    func read(_ id: String) async -> Read {
        await run { [self] in
            guard Self.isValid(id) else { return .unusable }
            switch DurableFile.FileRead(url(id)) {
            case .missing: return .missing
            case .unreadable: return .unreadable
            case .data(let data):
                switch key(create: false) {
                case .unavailable(let retry): return .noKey(retryAfter: retry)
                case .missing: return .unusable
                case .key(let key):
                    guard let records = CookieJournalFile.open(data, store: id, key: key) else { return .unusable }
                    return .records(records)
                }
            }
        }
    }

    /// Writes the records (an empty list takes the file away). False when it couldn't be (no key, no room).
    @discardableResult
    func write(_ id: String, _ records: [CookieRecord]) async -> Bool {
        await run { [self] in commit(id, records) == .written }
    }

    private enum Commit: Equatable { case written, noKey(Date?), failed }

    /// On the queue. Never touches a file when the key can't be had: what can't be opened is not thrown away.
    private func commit(_ id: String, _ records: [CookieRecord], generation: Int? = nil) -> Commit {
        guard Self.isValid(id) else { return .failed }
        if records.isEmpty {
            if case .unavailable(let retry) = key(create: false) { return .noKey(retry) }
            if generation == nil || generation == self.generation(id) { try? FileManager.default.removeItem(at: url(id)) }
            return .written
        }
        prepareFolder()
        let sealing: SymmetricKey
        switch key(create: true) {
        case .key(let key): sealing = key
        case .unavailable(let retry): return .noKey(retry)
        case .missing: return .failed
        }
        // Checked again here, after the key: turning the journal off (or clearing) in the meantime must not leave a file or a key behind.
        if let generation, generation != self.generation(id) { return .failed }
        guard let data = CookieJournalFile.seal(records, store: id, key: sealing) else { return .failed }
        return DurableFile.write(data, to: url(id)) ? .written : .failed
    }

    /// The store's cookies made into records, compared with what was last written, and written if they differ: all off the main thread.
    func snapshot(_ id: String, cookies: [HTTPCookie], known: [String: CookieSeen], lastDigest: SHA256.Digest?, generation: Int) async -> Snapshot {
        await run { [self] in
            guard Self.isValid(id), generation == self.generation(id) else { return .skipped }
            if let blocked = keyBlocked() { return .noKey(retryAfter: blocked) }
            let records = CookieJournalFile.records(from: cookies, known: known, now: now())
            let seen = Dictionary(records.map { ($0.key, $0.seen) }) { $1 }
            let digest = CookieJournal.digest(records)
            if digest == lastDigest { return .unchanged(known: seen) }
            switch commit(id, records, generation: generation) {
            case .written: return .written(digest: digest, known: seen)
            case .noKey(let retry): return .noKey(retryAfter: retry)
            case .failed: return generation == self.generation(id) ? .failed : .skipped
            }
        }
    }

    // MARK: Taking away

    /// The deletions are queued at once, from wherever they are asked for, and counted until they are done: a quit that comes right after waits for them.
    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        lock.withLock { operations += 1 }
        queue.async { [self] in
            work()
            lock.withLock { operations -= 1 }
        }
    }

    func discard(_ id: String) {
        enqueue { [self] in
            if Self.isValid(id) { try? FileManager.default.removeItem(at: url(id)) }
            removeStaleTemporaries()
        }
    }

    /// Every file but those of the stores named.
    func discardFiles(except keep: Set<String> = []) {
        enqueue { [self] in
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".journal") {
                if !keep.contains(String(name.dropLast(".journal".count))) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
            }
            removeStaleTemporaries()
        }
    }

    /// All the files and the key: there is nothing left that could open anything.
    func discardEverything() {
        enqueue { [self] in
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".journal") {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
            keys.remove()
            cached = nil
            keyFailures = 0
            keyRetryAt = nil
            removeStaleTemporaries()
        }
    }

    func cleanStaleTemporaries() { enqueue { [self] in removeStaleTemporaries() } }

    func remove(_ id: String) async {
        discard(id)
        await drain()
    }

    func removeFiles(except keep: Set<String> = []) async {
        discardFiles(except: keep)
        await drain()
    }

    func removeEverything() async {
        discardEverything()
        await drain()
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

/// What the Privacy settings show of the journal: whether its key can't be had.
@MainActor
final class JournalStatus: ObservableObject {
    static let shared = JournalStatus()
    @Published var keyDenied = false
}

/// Keeps the sign-ins that sites meant to end with the browser. WebKit holds a session cookie (one with no expiry) only in memory, so quitting
/// signs the user out everywhere; Safari and Chrome bring them back when they restore the session, and the journal does the same. It watches each
/// persistent data store (the default one and every profile's, never a private window's), writes the store's session cookies, and only those, to an
/// encrypted file shortly after they change, and puts back at launch the ones the store lacks, for up to 30 days after they were first written.
///
/// A store is `restoring` until its file has been read and merged, and only then `live`: nothing is written before that, so a store that
/// is still empty at launch can't replace what the journal holds. `off` is for a journal that is switched off or whose file can't be read.
@MainActor
final class CookieJournal {
    enum Phase: Equatable { case restoring, live, off }

    private final class Tracker {
        let source: CookieSource
        var phase = Phase.restoring
        /// Raised when the file is thrown away, so a snapshot taken before that is not written after it.
        var epoch = 0
        /// A snapshot is waiting for the cookies to be still; `firstChange` and `lastChange` are the changes it is waiting on.
        var pending: Task<Void, Never>?
        var firstChange: Date?
        var lastChange = Date.distantPast
        /// A snapshot is being taken.
        var running: Task<Void, Never>?
        var lastDigest: SHA256.Digest?
        var known: [String: CookieSeen] = [:]
        /// Not before: the key couldn't be had. `gaveUp`: it won't be tried again.
        var retryAt: Date?
        var gaveUp = false
        var restoring: Task<Void, Never>?
        init(_ source: CookieSource) { self.source = source }
    }

    let files: CookieJournalFiles
    let status: JournalStatus
    private let debounce: Duration
    private let maxWait: Duration
    private let now: () -> Date
    private let sleep: (Duration) async -> Void
    private var trackers: [String: Tracker] = [:]
    private var inFlight = 0
    private(set) var enabled: Bool
    /// How many cookies the last restore put back, for tests and the one line the log gets.
    private(set) var restoredCount = 0

    init(folder: URL, keys: CookieJournalKeys, enabled: Bool, debounce: Duration = .seconds(2), maxWait: Duration = .seconds(10), retryDelay: TimeInterval = 60,
         now: @escaping @Sendable () -> Date = { Date() }, sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         status: JournalStatus? = nil) {
        files = CookieJournalFiles(folder: folder, keys: keys, retryDelay: retryDelay, now: now)
        self.enabled = enabled
        self.debounce = debounce
        self.maxWait = maxWait
        self.now = now
        self.sleep = sleep
        self.status = status ?? JournalStatus()
    }

    /// The setting "Stay signed in after quitting": on unless turned off, but off for the headless apps, which keep their key in a file.
    nonisolated static func storedSetting() -> Bool {
        UserDefaults.standard.object(forKey: "keepSessionCookies") as? Bool ?? !Headless.isOn
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
        return CookieJournal(folder: folder, keys: keys, enabled: storedSetting(), status: .shared)
    }()

    func phase(of id: String) -> Phase? { trackers[id]?.phase }

    /// Work that would be lost if the app ended now: a change not yet written, a write on its way, or a deletion not yet done.
    var hasPendingWork: Bool {
        inFlight > 0 || files.pendingOperations > 0 || trackers.values.contains { $0.pending != nil || $0.running != nil }
    }

    private func setKeyProblem(_ problem: Bool) {
        if status.keyDenied != problem { status.keyDenied = problem }
    }

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
        var restored = 0
        switch read {
        case .unreadable:
            // Says nothing about what the file holds, so it is left alone: not read now, not overwritten later.
            tracker.phase = .off
            return
        case .noKey(let retry):
            setKeyProblem(true)
            tracker.retryAt = retry
            tracker.gaveUp = retry == nil
        case .records(let records):
            setKeyProblem(false)
            let usable = CookieJournalFile.usable(records, now: now())
            for record in usable { tracker.known[record.key] = record.seen }
            for record in usable {
                // Looked at again for each cookie: a page that is already loading may have been given a newer one by its server.
                let have = await tracker.source.allCookies()
                guard !have.contains(where: { CookieRecord.key(name: $0.name, domain: $0.domain, path: $0.path) == record.key }), let cookie = record.cookie else { continue }
                await tracker.source.setCookie(cookie)
                restored += 1
            }
            restoredCount += restored
            NSLog("Changmun: the cookie journal put back %d cookies", restored)
        case .missing, .unusable:
            break
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

    // MARK: Writing

    /// The store's cookies changed: they are written once they have been still for a moment, and at the latest a while after the first change.
    func changed(_ id: String) {
        guard let tracker = trackers[id], tracker.phase == .live, !tracker.gaveUp else { return }
        let time = now()
        tracker.lastChange = time
        if tracker.firstChange == nil { tracker.firstChange = time }
        guard tracker.pending == nil else { return }
        // The epoch this change belongs to: if the files are thrown away before the snapshot it asks for is begun, that snapshot is not taken.
        let epoch = tracker.epoch
        tracker.pending = Task { await self.waitThenSnapshot(id, epoch: epoch) }
    }

    private func waitThenSnapshot(_ id: String, epoch: Int) async {
        while let tracker = trackers[id], let first = tracker.firstChange {
            let wait = CookieJournalSchedule.delay(now: now(), firstChange: first, lastChange: tracker.lastChange, notBefore: tracker.retryAt,
                                                   quiet: debounce.seconds, maxWait: maxWait.seconds)
            if wait <= 0 { break }
            await sleep(.seconds(wait))
            if Task.isCancelled { return }
        }
        guard !Task.isCancelled else { return }
        await snapshot(id, epoch: epoch)
    }

    /// `epoch` is the one the snapshot was asked for in. Its task starts later than this call, so the epoch and the file generation it is bound to are
    /// taken here, in one go with the check: read when the task starts, they could already be those of a clearing that came between, and the snapshot
    /// would then pass for one asked for after it.
    private func snapshot(_ id: String, epoch: Int) async {
        guard let tracker = trackers[id] else { return }
        // One at a time: a change that came in meanwhile is taken after.
        while let running = tracker.running { await running.value }
        guard tracker.phase == .live, enabled, tracker.epoch == epoch else { return }
        tracker.pending = nil
        tracker.firstChange = nil
        let generation = files.generation(id)
        let run = Task { await self.takeSnapshot(id, tracker, epoch: epoch, generation: generation) }
        tracker.running = run
        await run.value
    }

    private func takeSnapshot(_ id: String, _ tracker: Tracker, epoch: Int, generation: Int) async {
        inFlight += 1
        defer {
            inFlight -= 1
            tracker.running = nil
        }
        let cookies = await tracker.source.allCookies()
        // Switched off, or the file thrown away, while the cookies were being read.
        guard tracker.phase == .live, tracker.epoch == epoch, enabled else { return }
        let result = await files.snapshot(id, cookies: cookies, known: tracker.known, lastDigest: tracker.lastDigest, generation: generation)
        guard tracker.epoch == epoch else { return }
        switch result {
        case .written(let digest, let known):
            // Only what was written is remembered as written, so a failed write is tried again with the next change.
            tracker.lastDigest = digest
            tracker.known = known
            tracker.retryAt = nil
            setKeyProblem(false)
        case .unchanged(let known):
            tracker.known = known
            tracker.retryAt = nil
            setKeyProblem(false)
        case .noKey(let retry):
            setKeyProblem(true)
            tracker.retryAt = retry
            tracker.gaveUp = retry == nil
            // Tried again once the wait is over, whether or not the cookies change by then.
            if retry != nil { changed(id) }
        case .skipped, .failed:
            break
        }
    }

    /// The same set of cookies has the same digest, whatever order WebKit lists them in.
    nonisolated static func digest(_ records: [CookieRecord]) -> SHA256.Digest {
        var hash = SHA256()
        for record in records.sorted(by: { $0.key < $1.key }) {
            hash.update(data: Data("\(record.key)\n\(record.value)\n\(record.secure)\(record.httpOnly)\(record.sameSite ?? "-")\u{0}".utf8))
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
        for (id, tracker) in trackers {
            if tracker.pending != nil {
                tracker.pending?.cancel()
                await snapshot(id, epoch: tracker.epoch)
            } else if let running = tracker.running {
                await running.value
            }
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
        files.revoke(id)
        files.discard(id)
    }

    /// Site data is being cleared (Settings › Privacy): the files go now, and what is waiting is dropped. The stores go on being watched; once the
    /// clearing is done `cleared()` writes what is left.
    func clearing() {
        for tracker in trackers.values {
            tracker.epoch += 1
            tracker.pending?.cancel()
            tracker.pending = nil
            tracker.firstChange = nil
            tracker.lastDigest = nil
        }
        files.revokeAll()
        files.discardFiles()
    }

    func cleared() {
        for id in trackers.keys { changed(id) }
    }

    /// The switch in Settings › Privacy. Off: the files and the key go, and nothing more is written. On: every store is written as it is.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            for (id, tracker) in trackers where tracker.phase == .off && CookieJournalFiles.isValid(id) {
                tracker.gaveUp = false
                tracker.retryAt = nil
                goLive(id, tracker)
            }
        } else {
            for tracker in trackers.values {
                tracker.phase = .off
                tracker.epoch += 1
                tracker.pending?.cancel()
                tracker.pending = nil
                tracker.firstChange = nil
                tracker.lastDigest = nil
                tracker.known = [:]
                tracker.source.stopObserving()
            }
            files.revokeAll()
            files.discardEverything()
            setKeyProblem(false)
        }
    }

    /// A journal that is off at launch holds nothing: files it left (the setting was turned off some other way, or their removal never finished) go.
    func wipeIfOff() async {
        if !enabled {
            files.discardEverything()
            await files.drain()
        }
    }

    /// Files of stores that are no longer there are not kept, nor are temporary files a write cut short left.
    func removeOrphans(keeping ids: Set<String>) {
        files.discardFiles(except: ids.union(trackers.keys).union(["default"]))
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

extension Duration {
    var seconds: TimeInterval { TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18 }
}

extension CookieJournal {
    /// The default store's cookies and each profile's, put back: the app waits for this before it opens a window. Files of stores that are gone go.
    func restoreAtLaunch(profiles spaces: [Space]) async {
        let ids = spaces.compactMap(\.dataStoreID)
        await wipeIfOff()
        files.cleanStaleTemporaries()
        await attach("default", WebKitCookieSource(.default()))
        for id in ids { await attach(id.uuidString, WebKitCookieSource(Profiles.dataStore(id))) }
        removeOrphans(keeping: Set(ids.map(\.uuidString)))
    }
}
