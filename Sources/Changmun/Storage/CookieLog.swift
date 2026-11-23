import Foundation
import os
import WebKit

/// One cookie as the log knows it: what makes it the cookie it is and when it ends. Its value is not here, so no line can ever carry one.
struct CookieIdentity: Hashable, Sendable {
    var domain: String
    var name: String
    var path: String
    var expires: Date?
    var session: Bool

    init(domain: String, name: String, path: String, expires: Date? = nil, session: Bool? = nil) {
        self.domain = domain
        self.name = name
        self.path = path
        self.expires = expires
        self.session = session ?? (expires == nil)
    }

    init(_ cookie: HTTPCookie) {
        self.init(domain: cookie.domain, name: cookie.name, path: cookie.path, expires: cookie.expiresDate, session: cookie.isSessionOnly)
    }

    var key: String { CookieRecord.key(name: name, domain: domain, path: path) }
}

/// Why a sign-in was lost while browsing, in Console (subsystem io.github.namekun.Changmun, category cookies). A session cookie (Naver's NID_AUT
/// and NID_SES, for one) lives only in the memory of WebKit's network process, so nothing on disk shows when it goes: these lines do. Each
/// persistent store's cookies are compared, a moment after they change, with what they were, and every cookie that went before it expired is
/// named, with how long it had been there; a cookie that expired is only counted, and so is one that changed. A loss of most session cookies at
/// once, the sign of a network process that lost its memory, says so with that process's identifier. Of a cookie only the site, the name, whether
/// it is a session cookie and its expiry are written, never its value; nothing is written for a private window.
enum CookieLog {
    nonisolated static let log = Logger(subsystem: "io.github.namekun.Changmun", category: "cookies")

    /// A cookie as last seen, and since when: `sinceBaseline` when it was already there at the first look, so its age is at least that.
    struct Entry: Equatable, Sendable {
        var identity: CookieIdentity
        var since: Date
        var sinceBaseline: Bool
    }

    struct Removal: Equatable, Sendable {
        var identity: CookieIdentity
        var age: TimeInterval
        var sinceBaseline: Bool
    }

    /// What one look found against the one before.
    struct Change: Equatable, Sendable {
        var added = 0
        /// The same cookie with another expiry or another kind; a new value alone can't be seen, as values are not kept.
        var changed = 0
        /// Gone before their expiry (a session cookie has none), in the order of their site and name.
        var removed: [Removal] = []
        var expired = 0
        var sessionBefore = 0
        var sessionAfter = 0

        var sessionLost: Int { removed.filter(\.identity.session).count }
        /// At least five session cookies and at least half of them gone at once: no site signs out like that, a network process that ended does.
        var massLoss: Bool { sessionLost >= 5 && sessionLost * 2 >= sessionBefore }
        var isEmpty: Bool { added == 0 && changed == 0 && removed.isEmpty && expired == 0 }
    }

    nonisolated static func identities(_ cookies: [HTTPCookie]) -> [CookieIdentity] { cookies.map(CookieIdentity.init) }

    /// The store's cookies now against the last look: what changed, and the snapshot to compare the next look with.
    nonisolated static func diff(_ before: [String: Entry], _ after: [CookieIdentity], now: Date) -> (Change, [String: Entry]) {
        var change = Change()
        var next: [String: Entry] = [:]
        next.reserveCapacity(after.count)
        for identity in after {
            let key = identity.key
            guard next[key] == nil else { continue }
            if let old = before[key] {
                if old.identity.expires != identity.expires || old.identity.session != identity.session { change.changed += 1 }
                next[key] = Entry(identity: identity, since: old.since, sinceBaseline: old.sinceBaseline)
            } else {
                change.added += 1
                next[key] = Entry(identity: identity, since: now, sinceBaseline: false)
            }
        }
        for (key, old) in before where next[key] == nil {
            if let expires = old.identity.expires, expires <= now {
                change.expired += 1
            } else {
                change.removed.append(Removal(identity: old.identity, age: now.timeIntervalSince(old.since), sinceBaseline: old.sinceBaseline))
            }
        }
        change.removed.sort { ($0.identity.domain, $0.identity.name, $0.identity.path) < ($1.identity.domain, $1.identity.name, $1.identity.path) }
        change.sessionBefore = before.values.filter(\.identity.session).count
        change.sessionAfter = next.values.filter(\.identity.session).count
        return (change, next)
    }

    /// The first look at a store, which everything after is compared with.
    nonisolated static func baseline(_ cookies: [CookieIdentity], now: Date) -> [String: Entry] {
        var entries: [String: Entry] = [:]
        for identity in cookies where entries[identity.key] == nil {
            entries[identity.key] = Entry(identity: identity, since: now, sinceBaseline: true)
        }
        return entries
    }

    // MARK: The lines

    nonisolated static func baselineLine(store: String, _ entries: [String: Entry], networkProcess: Int32?) -> String {
        "watching store=\(store) cookies=\(entries.count) session=\(entries.values.filter(\.identity.session).count) networkProcess=\(pid(networkProcess))"
    }

    /// Whether the log names the cookies a store loses (their sites, names and paths). Off unless turned on with
    /// `defaults write io.github.namekun.Changmun CookieLogNamesSites -bool true`: a line for every cookie gone would put the sites one visits
    /// into the system log, which other software on the Mac and a shared sysdiagnose can read. Without it the log keeps only counts.
    nonisolated static let namesSitesKey = "CookieLogNamesSites"
    nonisolated static var namesSites: Bool { UserDefaults.standard.bool(forKey: namesSitesKey) }

    /// One line per cookie gone before its expiry (only when `naming`), one for those that expired, the counts, and the mass loss if it was one.
    /// Nothing for a look that found nothing different: a cookie given a new value alone changes nothing the log can see.
    nonisolated static func lines(_ change: Change, store: String, networkProcess: Int32?, naming: Bool = true) -> [String] {
        guard !change.isEmpty else { return [] }
        var lines: [String] = !naming ? [] : change.removed.map { removal in
            let cookie = removal.identity
            let kind = cookie.session ? "session" : "persistent expires=\(cookie.expires.map { $0.formatted(.iso8601) } ?? "-")"
            return "removed store=\(store) domain=\(cookie.domain) name=\(cookie.name) path=\(cookie.path) \(kind) age\(removal.sinceBaseline ? ">=" : "=")\(Int(removal.age))s"
        }
        if change.expired > 0 { lines.append("expired store=\(store) count=\(change.expired)") }
        lines.append("diff store=\(store) added=\(change.added) changed=\(change.changed) removed=\(change.removed.count) expired=\(change.expired) "
                     + "sessionCookies=\(change.sessionBefore)->\(change.sessionAfter)")
        if change.massLoss {
            lines.append("MASS LOSS store=\(store) sessionCookiesLost=\(change.sessionLost) of=\(change.sessionBefore) networkProcess=\(pid(networkProcess))")
        }
        return lines
    }

    /// The journal's restore of one store at launch: what its file held, what came back, what was left (the store had it already, or it was too
    /// old or a second copy), and how long it took.
    nonisolated static func restoreLine(store: String, file: String, restored: Int = 0, skipped: Int = 0, took: Duration) -> String {
        "restore store=\(store) file=\(file) restored=\(restored) skipped=\(skipped) took=\(seconds(took))"
    }

    nonisolated static func launchLine(took: Duration, cap: Duration) -> String {
        took <= cap ? "launch restore finished took=\(seconds(took)) within the \(seconds(cap)) cap"
            : "launch restore finished took=\(seconds(took)) after the \(seconds(cap)) cap: windows opened without waiting for it"
    }

    private nonisolated static func pid(_ pid: Int32?) -> String { pid.map(String.init) ?? "unknown" }

    private nonisolated static func seconds(_ duration: Duration) -> String { String(format: "%.3fs", duration.seconds) }

    nonisolated static func write(_ lines: [String]) {
        for line in lines { log.notice("\(line, privacy: .public)") }
    }

    // MARK: The network process

    /// The identifier of the store's network process, from WebKit's `_networkProcessIdentifier` (there on macOS 14 to 27). Asked only when
    /// `_networkProcessExists` says there is one, as asking would otherwise start one.
    @MainActor static func networkProcess(of store: WKWebsiteDataStore) -> Int32? {
        typealias Exists = @convention(c) (AnyObject, Selector) -> Bool
        typealias Identifier = @convention(c) (AnyObject, Selector) -> Int32
        let exists = NSSelectorFromString("_networkProcessExists"), identifier = NSSelectorFromString("_networkProcessIdentifier")
        guard let existsMethod = class_getInstanceMethod(WKWebsiteDataStore.self, exists),
              let identifierMethod = class_getInstanceMethod(WKWebsiteDataStore.self, identifier),
              unsafeBitCast(method_getImplementation(existsMethod), to: Exists.self)(store, exists) else { return nil }
        let pid = unsafeBitCast(method_getImplementation(identifierMethod), to: Identifier.self)(store, identifier)
        return pid > 0 ? pid : nil
    }

    // MARK: Watching the stores

    @MainActor private static var watches: [String: CookieWatch] = [:]

    /// Watches a persistent store (the default one, or a profile's) until `stop`; a private window's is never watched.
    @MainActor static func watch(_ id: String, _ store: WKWebsiteDataStore) {
        guard store.isPersistent, watches[id] == nil else { return }
        let watch = CookieWatch(store: id, source: WebKitCookieSource(store)) { [weak store] in store.flatMap(networkProcess(of:)) }
        watches[id] = watch
        watch.start()
    }

    @MainActor static func stop(_ id: String) {
        watches.removeValue(forKey: id)?.stop()
    }
}

/// One store watched for the log. A change is looked at a moment later, so a page that sets many cookies at once makes one comparison, not one
/// for each; a change that comes while the cookies are being read and compared gets one more look after.
@MainActor
final class CookieWatch {
    let store: String
    private let source: CookieSource
    private let window: Duration
    private let now: () -> Date
    private let sleep: (Duration) async -> Void
    private let networkProcess: @MainActor () -> Int32?
    private let write: @MainActor ([String]) -> Void
    private let naming: () -> Bool
    private var snapshot: [String: CookieLog.Entry]?
    private var running: Task<Void, Never>?
    private var dirty = false
    /// How many times the cookies were read, for tests.
    private(set) var looks = 0

    init(store: String, source: CookieSource, window: Duration = .milliseconds(250), now: @escaping () -> Date = { Date() },
         sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         write: @escaping @MainActor ([String]) -> Void = { CookieLog.write($0) }, naming: @escaping () -> Bool = { CookieLog.namesSites },
         networkProcess: @escaping @MainActor () -> Int32?) {
        self.store = store
        self.source = source
        self.window = window
        self.now = now
        self.sleep = sleep
        self.write = write
        self.naming = naming
        self.networkProcess = networkProcess
    }

    /// Observes the store and takes the first look, the one the rest is compared with, at once.
    func start() {
        source.startObserving { [weak self] in self?.changed() }
        changed()
    }

    func stop() {
        source.stopObserving()
        running?.cancel()
        running = nil
    }

    /// Returns once the look under way, if any, is done.
    func settle() async { await running?.value }

    func changed() {
        dirty = true
        guard running == nil else { return }
        running = Task { await self.run() }
    }

    private func run() async {
        defer { running = nil }
        repeat {
            if snapshot != nil { await sleep(window) }
            guard !Task.isCancelled else { return }
            // What changed before this look is in it; only a change during the look asks for another.
            dirty = false
            let cookies = await source.allCookies()
            looks += 1
            let before = snapshot, time = now()
            // Off the main thread: the default store holds thousands of cookies.
            let (change, next) = await Task.detached(priority: .utility) {
                let identities = CookieLog.identities(cookies)
                guard let before else { return (CookieLog.Change(), CookieLog.baseline(identities, now: time)) }
                return CookieLog.diff(before, identities, now: time)
            }.value
            guard !Task.isCancelled else { return }
            if before == nil {
                write([CookieLog.baselineLine(store: store, next, networkProcess: networkProcess())])
            } else {
                write(CookieLog.lines(change, store: store, networkProcess: change.massLoss ? networkProcess() : nil, naming: naming()))
            }
            snapshot = next
        } while dirty
    }
}
