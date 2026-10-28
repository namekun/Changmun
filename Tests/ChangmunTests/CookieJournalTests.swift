import CryptoKit
import Foundation
import Testing
import WebKit
@testable import Changmun

private func cookie(_ name: String, _ value: String = "v", domain: String = "example.com", path: String = "/", expires: Date? = nil,
                    secure: Bool = false, httpOnly: Bool = false, sameSite: HTTPCookieStringPolicy? = nil) -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
    if let expires { properties[.expires] = expires }
    if secure { properties[.secure] = "TRUE" }
    if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
    if let sameSite { properties[.sameSitePolicy] = sameSite }
    return HTTPCookie(properties: properties)!
}

private func record(_ name: String, _ value: String = "v", domain: String = "example.com", path: String = "/", saved: Date = Date()) -> CookieRecord {
    CookieRecord(name: name, value: value, domain: domain, path: path, saved: saved)
}

private func tomorrow() -> Date { Date().addingTimeInterval(86_400) }

/// A store's cookies in memory: what WebKit's would be, with a gate to hold its answer back while a restore is under way.
@MainActor
private final class FakeSource: CookieSource {
    var cookies: [HTTPCookie]
    private(set) var set: [HTTPCookie] = []
    private(set) var observing = false
    private var onChange: (@MainActor () -> Void)?
    /// Called after each cookie is set: a server giving the store another one while the journal is putting its cookies back.
    var afterSet: (@MainActor (FakeSource) -> Void)?
    private(set) var reads = 0
    private var gated = false
    private var gatedSets = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ cookies: [HTTPCookie] = []) { self.cookies = cookies }

    /// Holds back the answer to `allCookies` (or, with `sets`, the end of each `setCookie`) until `release()`.
    func hold(sets: Bool = false) {
        if sets { gatedSets = true } else { gated = true }
    }

    func release() {
        gated = false
        gatedSets = false
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func allCookies() async -> [HTTPCookie] {
        reads += 1
        if gated { await withCheckedContinuation { waiting.append($0) } }
        return cookies
    }

    func setCookie(_ cookie: HTTPCookie) async {
        set.append(cookie)
        cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
        if gatedSets { await withCheckedContinuation { waiting.append($0) } }
        cookies.append(cookie)
        afterSet?(self)
    }

    func startObserving(_ change: @escaping @MainActor () -> Void) {
        observing = true
        onChange = change
    }

    func stopObserving() {
        observing = false
        onChange = nil
    }

    /// The store's cookies are now these, and WebKit says so.
    func become(_ cookies: [HTTPCookie]) {
        self.cookies = cookies
        onChange?()
    }
}

/// A journal over a folder of its own and a key held in memory: nothing of the user's is reached.
@MainActor
private struct Rig {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
    let keys: MemoryJournalKeys
    let journal: CookieJournal

    init(enabled: Bool = true, debounce: Duration = .milliseconds(30), maxWait: Duration = .seconds(10), retryDelay: TimeInterval = 60, keys: MemoryJournalKeys = MemoryJournalKeys(),
         now: @escaping @Sendable () -> Date = { Date() }, sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.keys = keys
        journal = CookieJournal(folder: folder, keys: keys, enabled: enabled, debounce: debounce, maxWait: maxWait, retryDelay: retryDelay, now: now, sleep: sleep)
    }

    func read(_ id: String = "default") async -> CookieJournalFiles.Read { await journal.files.read(id) }

    func names(_ id: String = "default") async -> [String]? {
        if case .records(let records) = await read(id) { return records.map(\.name).sorted() }
        return nil
    }

    func file(_ id: String = "default") -> URL { journal.files.url(id) }

    /// Whether these stores' files hold exactly these cookie names.
    func holds(_ expected: [String: [String]]) async -> Bool {
        for (id, names) in expected where await self.names(id) != names { return false }
        return true
    }

    func finish() { try? FileManager.default.removeItem(at: folder) }
}

struct CookieJournalFileTests {
    private let key = SymmetricKey(size: .bits256)

    private let everything: [HTTPCookie] = [
        cookie("session", "s1", domain: "bank.example", path: "/"),
        cookie("domain", "p1", domain: ".example.com", path: "/app"),
        cookie("secret", "a b;c=d\u{00e9}\u{d55c}", domain: "www.example.com", secure: true, httpOnly: true, sameSite: .sameSiteStrict),
        cookie("lax", "l", domain: "example.org", httpOnly: true, sameSite: .sameSiteLax),
    ]

    @Test func everyAttributeOfACookieSurvivesTheJournal() throws {
        let saved = Date(timeIntervalSince1970: 1_700_000_000.5)
        let sealed = try #require(CookieJournalFile.seal(everything.map { CookieRecord($0, saved: saved)! }, store: "default", key: key))
        let opened = try #require(CookieJournalFile.open(sealed, store: "default", key: key))
        #expect(opened.allSatisfy { $0.saved == saved })
        let back = try opened.map { try #require($0.cookie) }
        #expect(back.count == everything.count)
        for (was, now) in zip(everything, back) {
            #expect(now.name == was.name && now.value == was.value, "\(was.name)")
            #expect(now.domain == was.domain && now.path == was.path, "\(was.name)")
            #expect(now.expiresDate == nil && now.isSessionOnly, "\(was.name): a session cookie stays one")
            #expect(now.isSecure == was.isSecure && now.isHTTPOnly == was.isHTTPOnly, "\(was.name)")
            #expect(now.sameSitePolicy == was.sameSitePolicy, "\(was.name)")
        }
        #expect(back[2].isSecure && back[2].isHTTPOnly && back[2].sameSitePolicy == .sameSiteStrict)
        #expect(back[1].domain == ".example.com", "a domain cookie keeps its dot, a host cookie lacks it")
    }

    @Test func onlyPlainSessionCookiesAreKept() {
        let now = Date()
        #expect(CookieRecord(cookie("a"), saved: now) != nil)
        #expect(CookieRecord(cookie("persistent", expires: tomorrow()), saved: now) == nil, "WebKit keeps these itself")
        #expect(CookieRecord(cookie("past", expires: Date(timeIntervalSince1970: 1)), saved: now) == nil)
        let plain: [HTTPCookiePropertyKey: Any] = [.name: "a", .value: "v", .domain: "example.com", .path: "/", HTTPCookiePropertyKey("HttpOnly"): "TRUE", .sameSitePolicy: "lax"]
        #expect(CookieRecord.canKeep(plain))
        #expect(!CookieRecord.canKeep(plain.merging([HTTPCookiePropertyKey("Partitioned"): "TRUE"]) { $1 }), "a partitioned cookie can't be given back as it was")
        #expect(!CookieRecord.canKeep(plain.merging([HTTPCookiePropertyKey("PartitionKey"): "https://top.example"]) { $1 }))
        #expect(!CookieRecord.canKeep(plain.merging([HTTPCookiePropertyKey("SomethingNew"): 1]) { $1 }), "nor one with an attribute nobody has heard of")
    }

    @Test func theFileHoldsNothingReadable() throws {
        let sealed = try #require(CookieJournalFile.seal([record("sid", "SECRET-VALUE-123", domain: "bank.example")], store: "default", key: key))
        let text = String(decoding: sealed, as: UTF8.self)
        #expect(!text.contains("SECRET-VALUE-123") && !text.contains("bank.example") && !text.contains("sid"))
        #expect(sealed.prefix(4) == Data("CMCJ".utf8) && sealed[4] == 1, "a magic and the format's version, then the sealed part")
    }

    @Test func aFileThatIsNotOursIsIgnored() throws {
        let sealed = try #require(CookieJournalFile.seal([record("a")], store: "default", key: key))
        #expect(CookieJournalFile.open(sealed, store: "default", key: key)?.map(\.name) == ["a"])
        #expect(CookieJournalFile.open(sealed, store: "default", key: SymmetricKey(size: .bits256)) == nil, "another key")
        #expect(CookieJournalFile.open(sealed, store: "other", key: key) == nil, "another store's file moved over this one")
        #expect(CookieJournalFile.open(Data(), store: "default", key: key) == nil)
        #expect(CookieJournalFile.open(Data("CMCJ".utf8), store: "default", key: key) == nil)
        #expect(CookieJournalFile.open(Data("not a journal at all, just text".utf8), store: "default", key: key) == nil)
        #expect(CookieJournalFile.open(sealed.dropLast(), store: "default", key: key) == nil, "cut short")
        #expect(CookieJournalFile.open(sealed.prefix(sealed.count / 2), store: "default", key: key) == nil, "cut in half")
        for version: UInt8 in [0, 2, 255] {
            var other = sealed
            other[4] = version
            #expect(CookieJournalFile.open(other, store: "default", key: key) == nil, "format \(version)")
        }
        var magic = sealed
        magic[0] ^= 1
        #expect(CookieJournalFile.open(magic, store: "default", key: key) == nil)
    }

    @Test func aChangedByteAnywhereMakesTheFileUnusable() throws {
        let sealed = try #require(CookieJournalFile.seal(everything.map { CookieRecord($0, saved: Date())! }, store: "default", key: key))
        for index in stride(from: 0, to: sealed.count, by: max(1, sealed.count / 40)) + [sealed.count - 1] {
            var damaged = sealed
            damaged[index] ^= 0x01
            #expect(CookieJournalFile.open(damaged, store: "default", key: key) == nil, "byte \(index) changed")
        }
    }

    // MARK: What is put back

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func onlyTheCookiesTheStoreLacksComeBack() {
        let records = [record("a", "journal", saved: now), record("b", "journal", saved: now), record("c", "journal", domain: "other.example", saved: now)]
        let back = CookieJournalFile.missing(from: records, in: [cookie("a", "fresher")], now: now)
        #expect(back.map(\.name) == ["b", "c"], "a cookie the store has is newer than the journal's, whatever its value")
        #expect(CookieJournalFile.missing(from: [record("a", domain: "Example.COM", saved: now)], in: [cookie("a")], now: now).isEmpty, "domains are compared without case")
        #expect(CookieJournalFile.missing(from: [record("a", path: "/x", saved: now)], in: [cookie("a")], now: now).map(\.path) == ["/x"], "another path is another cookie")
    }

    @Test func cookiesOlderThanThirtyDaysStayGone() {
        let day = 86_400.0
        let records = [record("old", saved: now.addingTimeInterval(-31 * day)), record("edge", saved: now.addingTimeInterval(-30 * day)),
                       record("young", saved: now.addingTimeInterval(-29 * day)), record("new", saved: now)]
        #expect(CookieJournalFile.missing(from: records, in: [], now: now).map(\.name) == ["young", "new"])
        #expect(CookieJournalFile.usable(records, now: now).map(\.name) == ["young", "new"])
    }

    @Test func aCookieKeepsItsFirstDateWhileItsValueIsTheSame() {
        let day = 86_400.0
        let first = now.addingTimeInterval(-20 * day)
        let known = ["example.com\nsame\n/": CookieSeen(value: "v", saved: first), "example.com\nrotated\n/": CookieSeen(value: "old", saved: first)]
        let records = CookieJournalFile.records(from: [cookie("same", "v"), cookie("rotated", "new"), cookie("fresh", "v")], known: known, now: now)
        let saved = Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0.saved) })
        #expect(saved["same"] == first, "written again unchanged: counted from the first time")
        #expect(saved["rotated"] == now, "a new value is a new sign-in")
        #expect(saved["fresh"] == now)
        #expect(records.map(\.name) == ["fresh", "rotated", "same"], "in an order of its own")
    }

    @Test func aSnapshotDropsWhatHasBeenInTheJournalTooLong() {
        let day = 86_400.0
        let known = ["example.com\nold\n/": CookieSeen(value: "v", saved: now.addingTimeInterval(-31 * day)), "example.com\nkept\n/": CookieSeen(value: "v", saved: now.addingTimeInterval(-29 * day))]
        let records = CookieJournalFile.records(from: [cookie("old"), cookie("kept")], known: known, now: now)
        #expect(records.map(\.name) == ["kept"], "the store still has it, the journal no longer keeps it")
    }

    @Test func aSessionCookieComesBackAsOneOfThisRun() throws {
        let back = try #require(CookieJournalFile.missing(from: [CookieRecord(cookie("sid", "x", httpOnly: true), saved: now)!], in: [], now: now).first)
        #expect(back.isSessionOnly && back.expiresDate == nil && back.isHTTPOnly && back.value == "x")
    }

    @Test func aCookieTwiceInTheJournalComesBackOnce() {
        #expect(CookieJournalFile.missing(from: [record("a", "1", saved: now), record("a", "2", saved: now)], in: [], now: now).map(\.value) == ["1"])
    }

    @Test func theSameCookiesHaveTheSameDigestInAnyOrder() {
        let a = [record("a"), record("b", "2")], b = [record("b", "2"), record("a")]
        #expect(CookieJournal.digest(a) == CookieJournal.digest(b))
        #expect(CookieJournal.digest(a) != CookieJournal.digest([record("a"), record("b", "3")]))
        #expect(CookieJournal.digest(a) != CookieJournal.digest([record("a")]))
    }

    @Test func aStoreIdIsOnlyEverAFileName() {
        #expect(CookieJournalFiles.isValid("default") && CookieJournalFiles.isValid(UUID().uuidString))
        for bad in ["", "../x", "a/b", "a.b", "a b", String(repeating: "a", count: 65)] { #expect(!CookieJournalFiles.isValid(bad), "\(bad)") }
    }
}

@MainActor
struct CookieJournalTests {
    private func eventually(_ seconds: Double = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func quietFor(_ time: Duration) async { try? await Task.sleep(for: time) }

    // MARK: Writing

    @Test func aChangeIsWrittenAfterTheCookiesHaveBeenStill() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let source = FakeSource()
        await rig.journal.attach("default", source)
        #expect(rig.journal.phase(of: "default") == .live && source.observing)
        source.become([cookie("sid"), cookie("pid", expires: tomorrow())])
        #expect(await eventually { await rig.names() == ["sid"] }, "a cookie that lasts is WebKit's to keep")
        source.become([cookie("sid")])
        #expect(await eventually { await rig.names() == ["sid"] }, "a cookie the store dropped is dropped from the next snapshot too")
        source.become([])
        #expect(await eventually { !FileManager.default.fileExists(atPath: rig.file().path) }, "no cookies, no file")
    }

    @Test func aBurstOfChangesIsOneWrite() async throws {
        let clock = SimulatedClock()
        let rig = Rig(debounce: .seconds(2), maxWait: .seconds(10), now: { clock.now }, sleep: { await clock.sleep($0) })
        defer { rig.finish(); clock.finish() }
        let source = FakeSource()
        await rig.journal.attach("default", source)
        var count = 0
        await clock.run(for: 5) { count += 1; source.become([cookie("c\(count)")]) }
        #expect(source.reads == 0 && !FileManager.default.fileExists(atPath: rig.file().path), "still being changed: not yet")
        await clock.run(for: 3)
        #expect(await eventually { await rig.names() == ["c5"] })
        #expect(source.reads == 1, "one snapshot for the whole burst")
    }

    @Test func theFileIsPrivateAndWrittenWhole() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let source = FakeSource([cookie("sid")])
        await rig.journal.attach("default", source)
        #expect(await eventually { FileManager.default.fileExists(atPath: rig.file().path) })
        let attributes = try FileManager.default.attributesOfItem(atPath: rig.file().path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: rig.folder.path)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
        let names = try FileManager.default.contentsOfDirectory(atPath: rig.folder.path)
        #expect(names == ["default.journal"], "no temporary file is left")
    }

    @Test func aQuitWritesWhatIsWaitingAtOnce() async throws {
        let rig = Rig(debounce: .seconds(60))
        defer { rig.finish() }
        let source = FakeSource()
        await rig.journal.attach("default", source)
        source.become([cookie("sid")])
        #expect(rig.journal.hasPendingWork)
        await rig.journal.flush(within: .seconds(5))
        #expect(await rig.names() == ["sid"])
        #expect(!rig.journal.hasPendingWork)
    }

    // MARK: Restoring

    @Test func theLaunchPutsBackWhatTheStoreLacksAndLeavesWhatItHas() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let first = FakeSource()
        await rig.journal.attach("default", first)
        first.become([cookie("sid", "old"), cookie("kept", "journal"), cookie("gone", "journal")])
        #expect(await eventually { await rig.names()?.count == 3 })

        // The next run: WebKit has the persistent cookies it saved itself (one of them changed since), but no session cookie.
        let later = CookieJournal(folder: rig.folder, keys: rig.keys, enabled: true, debounce: .milliseconds(30))
        let source = FakeSource([cookie("gone", "fresher")])
        await later.attach("default", source)
        #expect(Set(source.set.map(\.name)) == ["sid", "kept"], "the journal's session cookies came back; the store's own cookie stays")
        #expect(source.cookies.first { $0.name == "gone" }?.value == "fresher")
        #expect(source.cookies.first { $0.name == "sid" }?.isSessionOnly == true)
        #expect(later.restoredCount == 2)
    }

    @Test(arguments: [false, true]) func nothingIsWrittenBeforeTheRestoreIsDone(whileSettingCookies: Bool) async throws {
        let rig = Rig()
        defer { rig.finish() }
        // The journal holds a sign-in; the store, still loading, shows nothing yet.
        let writer = FakeSource([cookie("sid", "kept")])
        await rig.journal.attach("default", writer)
        #expect(await eventually { await rig.names() == ["sid"] })
        let before = try Data(contentsOf: rig.file())

        let later = CookieJournal(folder: rig.folder, keys: rig.keys, enabled: true, debounce: .milliseconds(20))
        let source = FakeSource()
        source.hold(sets: whileSettingCookies)
        let restoring = Task { await later.attach("default", source) }
        await quietFor(.milliseconds(100))
        #expect(later.phase(of: "default") == .restoring)
        #expect(!source.observing, "not watched until it is restored")
        later.changed("default")
        await later.flush(within: .milliseconds(200))
        await quietFor(.milliseconds(150))
        #expect(try Data(contentsOf: rig.file()) == before, "an empty store in the middle of a restore didn't replace the journal")

        source.release()
        await restoring.value
        #expect(later.phase(of: "default") == .live && source.observing)
        #expect(source.cookies.map(\.name) == ["sid"])
        #expect(await eventually { later.restoredCount == 1 })
        #expect(await rig.names() == ["sid"], "and once it is restored the journal follows the store")
    }

    @Test func aDamagedFileIsIgnoredAndThenReplaced() async throws {
        let rig = Rig()
        defer { rig.finish() }
        try FileManager.default.createDirectory(at: rig.folder, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: rig.file())
        let source = FakeSource([cookie("sid")])
        await rig.journal.attach("default", source)
        #expect(source.set.isEmpty && rig.journal.phase(of: "default") == .live)
        #expect(await eventually { await rig.names() == ["sid"] }, "and the file is then a good one")
    }

    @Test func aFileFromAnotherKeyIsIgnored() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let source = FakeSource([cookie("sid")])
        await rig.journal.attach("default", source)
        #expect(await eventually { await rig.names() == ["sid"] })

        let later = CookieJournal(folder: rig.folder, keys: MemoryJournalKeys(key: SymmetricKey(size: .bits256)), enabled: true, debounce: .milliseconds(30))
        let empty = FakeSource()
        await later.attach("default", empty)
        #expect(empty.set.isEmpty, "what can't be opened is not put back")
    }

    @Test func aFileThatCantBeReadIsLeftAlone() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let first = FakeSource([cookie("sid")])
        await rig.journal.attach("default", first)
        #expect(await eventually { await rig.names() == ["sid"] })
        let before = try Data(contentsOf: rig.file())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: rig.file().path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rig.file().path) }
        guard (try? Data(contentsOf: rig.file())) == nil else { return }   // running as someone who can read anything

        let later = CookieJournal(folder: rig.folder, keys: rig.keys, enabled: true, debounce: .milliseconds(20))
        let source = FakeSource([cookie("other")])
        await later.attach("default", source)
        #expect(later.phase(of: "default") == .off, "what the file holds is unknown, so nothing is written over it")
        source.become([cookie("other"), cookie("more")])
        await later.flush(within: .milliseconds(200))
        await quietFor(.milliseconds(100))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rig.file().path)
        #expect(try Data(contentsOf: rig.file()) == before)
    }

    @Test func aKeyThatCantBeHadMeansNothingIsKeptAndNothingIsThrownAway() async throws {
        let rig = Rig(keys: MemoryJournalKeys(unavailable: true))
        defer { rig.finish() }
        try FileManager.default.createDirectory(at: rig.folder, withIntermediateDirectories: true)
        try Data("sealed by a key that can't be had".utf8).write(to: rig.file())
        let before = try Data(contentsOf: rig.file())
        let source = FakeSource([cookie("sid")])
        await rig.journal.attach("default", source)
        source.become([cookie("sid"), cookie("more")])
        await rig.journal.flush(within: .seconds(2))
        source.become([])
        await rig.journal.flush(within: .seconds(2))
        await quietFor(.milliseconds(100))
        #expect(try Data(contentsOf: rig.file()) == before, "the file stays: no cookies is not a reason to throw away what can't be opened")
        #expect(source.set.isEmpty)
        #expect(rig.journal.status.keyDenied, "and the settings can say so")
        #expect(await rig.journal.files.write("default", []) == false, "not even when it is asked to")
        #expect(try Data(contentsOf: rig.file()) == before)
    }

    @Test func theKeyIsAskedForAgainAfterAWaitAndAFewTimesAtMost() async throws {
        let clock = SimulatedClock()
        let keys = MemoryJournalKeys(unavailable: true)
        let rig = Rig(debounce: .seconds(2), maxWait: .seconds(10), retryDelay: 60, keys: keys, now: { clock.now }, sleep: { await clock.sleep($0) })
        defer { rig.finish(); clock.finish() }
        let source = FakeSource([cookie("sid")])
        await rig.journal.attach("default", source)
        await clock.run(for: 3)
        #expect(await eventually { keys.attempts == 1 }, "asked once, and not again for every change")
        for index in 0..<5 {
            source.become([cookie("sid"), cookie("n\(index)")])
            await clock.run(for: 3)
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(keys.attempts == 1, "changes inside the wait don't ask again")
        #expect(rig.journal.status.keyDenied)

        keys.setUnavailable(false)
        await clock.run(for: 70)
        #expect(await eventually { await rig.names() != nil }, "after the wait it asked again, got the key, and wrote")
        #expect(!rig.journal.status.keyDenied)
    }

    @Test func theKeyIsGivenUpOnAfterThreeTries() async throws {
        let clock = SimulatedClock()
        let keys = MemoryJournalKeys(unavailable: true)
        let rig = Rig(debounce: .seconds(2), maxWait: .seconds(10), retryDelay: 60, keys: keys, now: { clock.now }, sleep: { await clock.sleep($0) })
        defer { rig.finish(); clock.finish() }
        let source = FakeSource([cookie("sid")])
        await rig.journal.attach("default", source)
        for _ in 0..<8 { await clock.run(for: 65) }
        #expect(await eventually { keys.attempts == CookieJournalFiles.maxKeyTries })
        source.become([cookie("sid"), cookie("more")])
        await clock.run(for: 200)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(keys.attempts == CookieJournalFiles.maxKeyTries, "no more tries, and no busy loop")
    }

    @Test func eachStoreHasAFileOfItsOwn() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let profile = UUID().uuidString
        let one = FakeSource([cookie("main")]), two = FakeSource([cookie("work")])
        await rig.journal.attach("default", one)
        await rig.journal.attach(profile, two)
        await rig.journal.attach(profile, FakeSource([cookie("never")]))
        #expect(await eventually { await rig.holds(["default": ["main"], profile: ["work"]]) })
        #expect(two.observing, "a store attached again is not watched twice")
    }

    @Test func aStoreIdThatIsNotAFileNameIsNotWatched() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let source = FakeSource([cookie("sid")])
        await rig.journal.attach("../escape", source)
        #expect(rig.journal.phase(of: "../escape") == .off && !source.observing)
        #expect(!FileManager.default.fileExists(atPath: rig.folder.deletingLastPathComponent().appendingPathComponent("escape.journal").path))
    }

    // MARK: Taking it away

    @Test func aDeletedStoreTakesItsFileAndItsWatchWithIt() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let profile = UUID().uuidString
        let source = FakeSource([cookie("work")])
        await rig.journal.attach(profile, source)
        await rig.journal.attach("default", FakeSource([cookie("main")]))
        #expect(await eventually { await rig.holds(["default": ["main"], profile: ["work"]]) })
        rig.journal.forget(profile)
        #expect(await eventually { !FileManager.default.fileExists(atPath: rig.file(profile).path) })
        #expect(!source.observing && rig.journal.phase(of: profile) == nil)
        #expect(await rig.names() == ["main"], "another store's file stays")
    }

    @Test func clearingSiteDataTakesTheFilesAndWritesWhatIsLeft() async throws {
        let rig = Rig(debounce: .milliseconds(30))
        defer { rig.finish() }
        let profile = UUID().uuidString
        let one = FakeSource([cookie("sid"), cookie("kept")]), two = FakeSource([cookie("work")])
        await rig.journal.attach("default", one)
        await rig.journal.attach(profile, two)
        #expect(await eventually { await rig.holds(["default": ["kept", "sid"], profile: ["work"]]) })

        rig.journal.clearing()
        #expect(await eventually { !FileManager.default.fileExists(atPath: rig.file().path) && !FileManager.default.fileExists(atPath: rig.file(profile).path) })
        // A cookie cleared "for the past hour" leaves the older ones, which the journal keeps on being told about once the clearing is done.
        one.cookies = [cookie("kept")]
        two.cookies = []
        rig.journal.cleared()
        #expect(await eventually { await rig.names() == ["kept"] })
        #expect(!FileManager.default.fileExists(atPath: rig.file(profile).path))
        #expect(one.observing, "and the stores are still watched")
    }

    @Test func aSnapshotTakenBeforeTheClearingIsNotWrittenAfterIt() async throws {
        let rig = Rig(debounce: .milliseconds(20))
        defer { rig.finish() }
        let source = FakeSource([cookie("sid")])
        await rig.journal.attach("default", source)
        #expect(await eventually { await rig.names() == ["sid"] })
        source.hold()
        source.become([cookie("sid"), cookie("late")])
        await quietFor(.milliseconds(80))   // the snapshot is reading the store ...
        rig.journal.clearing()              // ... when the clearing begins
        source.release()
        await quietFor(.milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: rig.file().path), "what was read before the clearing is not written after it")
    }

    @Test func turningItOffTakesEverythingAndTurningItOnWritesAgain() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let source = FakeSource([cookie("sid")])
        await rig.journal.attach("default", source)
        #expect(await eventually { await rig.names() == ["sid"] })
        #expect(rig.keys.hasKey)

        rig.journal.setEnabled(false)
        #expect(await eventually { !FileManager.default.fileExists(atPath: rig.file().path) && !rig.keys.hasKey })
        #expect(!source.observing && rig.journal.phase(of: "default") == .off)
        source.become([cookie("sid"), cookie("more")])
        await rig.journal.flush(within: .milliseconds(300))
        await quietFor(.milliseconds(150))
        #expect(!FileManager.default.fileExists(atPath: rig.file().path), "nothing is written while it is off")

        rig.journal.setEnabled(true)
        #expect(await eventually { await rig.names() == ["more", "sid"] })
        #expect(source.observing && rig.journal.phase(of: "default") == .live)
    }

    @Test func offFromTheStartNothingIsRestoredOrKept() async throws {
        let rig = Rig(enabled: false)
        defer { rig.finish() }
        let source = FakeSource([cookie("sid")])
        await rig.journal.attach("default", source)
        source.become([cookie("sid"), cookie("more")])
        await rig.journal.flush(within: .milliseconds(300))
        await quietFor(.milliseconds(100))
        #expect(rig.journal.phase(of: "default") == .off && !source.observing && source.set.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rig.file().path))
    }

    @Test func aJournalThatIsOffAtLaunchLeavesNothingBehind() async throws {
        let rig = Rig()
        defer { rig.finish() }
        await rig.journal.files.write("default", [record("a")])
        await rig.journal.wipeIfOff()
        #expect(FileManager.default.fileExists(atPath: rig.file().path) && rig.keys.hasKey, "on: left alone")

        let off = CookieJournal(folder: rig.folder, keys: rig.keys, enabled: false, debounce: .milliseconds(20))
        await off.wipeIfOff()
        #expect(!FileManager.default.fileExists(atPath: rig.file().path) && !rig.keys.hasKey, "off: the file and the key are gone")
    }

    @Test func filesOfStoresThatAreGoneAreRemovedAtLaunch() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let live = UUID().uuidString, gone = UUID().uuidString
        for id in ["default", live, gone] { await rig.journal.files.write(id, [record("a")]) }
        rig.journal.removeOrphans(keeping: [live])
        #expect(await eventually { !FileManager.default.fileExists(atPath: rig.file(gone).path) })
        #expect(FileManager.default.fileExists(atPath: rig.file(live).path) && FileManager.default.fileExists(atPath: rig.file("default").path))
        #expect(rig.keys.hasKey, "the key stays: the other files still need it")
    }

    @Test func aPrivateWindowsStoreIsNeverAttached() {
        // A private window's configuration is the one place a nonPersistent store is made (Browser.init); nothing there names the journal.
        let private1 = Browser.makeConfiguration(store: .nonPersistent(), extensions: false)
        #expect(!private1.websiteDataStore.isPersistent)
        #expect(CookieJournal.shared.phase(of: "private") == nil)
    }
}

/// Time that passes only when the test says: sleeping waits for it, and `now` is what it has reached.
private final class SimulatedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    private var sleepers: [(deadline: Date, continuation: CheckedContinuation<Void, Never>)] = []

    var now: Date { lock.withLock { time } }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            lock.withLock { sleepers.append((time.addingTimeInterval(duration.seconds), continuation)) }
        }
    }

    func advance(by seconds: TimeInterval) {
        let due: [CheckedContinuation<Void, Never>] = lock.withLock {
            time = time.addingTimeInterval(seconds)
            let ready = sleepers.filter { $0.deadline <= time }
            sleepers.removeAll { $0.deadline <= time }
            return ready.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }

    /// A second at a time, giving whatever woke up its turn.
    func run(for seconds: Int, each: (@MainActor () -> Void)? = nil) async {
        for _ in 0..<seconds {
            advance(by: 1)
            await MainActor.run { each?() }
            for _ in 0..<5 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func finish() {
        let rest = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { sleepers = [] }
            return sleepers.map(\.continuation)
        }
        rest.forEach { $0.resume() }
    }
}

/// Keys whose removal takes a while, as a busy keychain's can.
private final class SlowRemoveKeys: CookieJournalKeys, @unchecked Sendable {
    let inner = MemoryJournalKeys()
    private let lock = NSLock()
    private var done = false
    var removed: Bool { lock.withLock { done } }
    func key(create: Bool) -> JournalKey { inner.key(create: create) }
    func remove() {
        Thread.sleep(forTimeInterval: 0.3)
        inner.remove()
        lock.withLock { done = true }
    }
}

@MainActor
struct CookieJournalHardeningTests {
    private func eventually(_ seconds: Double = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    // MARK: A longest wait

    @Test func aSnapshotIsDueAfterTheCookiesAreStillOrAtTheLongestWait() {
        let first = Date(timeIntervalSince1970: 1000)
        func delay(_ now: Double, last: Double, notBefore: Double? = nil) -> TimeInterval {
            CookieJournalSchedule.delay(now: Date(timeIntervalSince1970: now), firstChange: first, lastChange: Date(timeIntervalSince1970: last),
                                        notBefore: notBefore.map { Date(timeIntervalSince1970: $0) }, quiet: 2, maxWait: 10)
        }
        #expect(delay(1000, last: 1000) == 2, "a change: two seconds of quiet")
        #expect(delay(1001, last: 1001) == 2, "and another change pushes it back")
        #expect(delay(1008, last: 1008) == 2, "still")
        #expect(delay(1009.5, last: 1009.5) == 0.5, "but not past the longest wait after the first change")
        #expect(delay(1010, last: 1010) <= 0 && delay(1030, last: 1030) <= 0)
        #expect(delay(1003, last: 1000) < 0, "quiet long enough")
        #expect(delay(1010, last: 1010, notBefore: 1070) == 60, "a failed attempt asked for time")
    }

    @Test func aPageThatKeepsChangingItsCookiesIsStillWrittenWithinTheLongestWait() async throws {
        let clock = SimulatedClock()
        let rig = Rig(debounce: .seconds(2), maxWait: .seconds(10), now: { clock.now }, sleep: { await clock.sleep($0) })
        defer { rig.finish(); clock.finish() }
        let source = FakeSource()
        await rig.journal.attach("default", source)
        var count = 0
        // Every second, for half a minute, an analytics cookie is refreshed: never two seconds of quiet.
        await clock.run(for: 11) { count += 1; source.become([cookie("sid"), cookie("ga", "\(count)")]) }
        #expect(await eventually { await rig.names() == ["ga", "sid"] }, "written by the tenth second though it never was still")
        let afterFirst = source.reads
        #expect(afterFirst >= 1)
        source.become([])        // the user signs out ...
        await clock.run(for: 11) { count += 1; source.become([cookie("ga", "\(count)")]) }
        #expect(await eventually { await rig.names() == ["ga"] }, "... and the journal follows within the longest wait, not after the page has gone quiet")
        #expect(source.reads >= afterFirst + 1)
    }

    @Test func withoutMuchChurnASnapshotComesAfterTheQuiet() async throws {
        let clock = SimulatedClock()
        let rig = Rig(debounce: .seconds(2), maxWait: .seconds(10), now: { clock.now }, sleep: { await clock.sleep($0) })
        defer { rig.finish(); clock.finish() }
        let source = FakeSource()
        await rig.journal.attach("default", source)
        source.become([cookie("sid")])
        await clock.run(for: 1)
        #expect(source.reads == 0, "not yet")
        await clock.run(for: 2)
        #expect(await eventually { await rig.names() == ["sid"] })
    }

    // MARK: Nothing is lost on the way out

    @Test func aQuitWaitsForASnapshotThatIsStillReadingTheStore() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let source = FakeSource()
        await rig.journal.attach("default", source)
        source.hold()
        source.become([cookie("sid")])
        #expect(await eventually { rig.journal.hasPendingWork && source.reads >= 1 }, "the snapshot is waiting on the store")
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            source.release()
        }
        let start = Date()
        await rig.journal.flush(within: .seconds(2))
        #expect(Date().timeIntervalSince(start) < 1.9)
        #expect(await rig.names() == ["sid"], "it was written before the quit went on")
    }

    @Test func aQuitGivesUpOnAStoreThatNeverAnswers() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let source = FakeSource()
        await rig.journal.attach("default", source)
        source.hold()
        source.become([cookie("sid")])
        #expect(await eventually { source.reads >= 1 })
        let start = Date()
        await rig.journal.flush(within: .milliseconds(300))
        #expect(Date().timeIntervalSince(start) < 1.5)
        source.release()
    }

    @Test func aDeletionStillOnItsWayCountsAsWorkToBeDone() async throws {
        let keys = SlowRemoveKeys()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = CookieJournal(folder: folder, keys: keys, enabled: true, debounce: .milliseconds(20))
        await journal.attach("default", FakeSource([cookie("sid")]))
        #expect(await eventually { FileManager.default.fileExists(atPath: journal.files.url("default").path) })
        await journal.flush(within: .seconds(2))
        #expect(!journal.hasPendingWork)

        journal.setEnabled(false)
        #expect(journal.hasPendingWork, "the switch is off but the key is still being removed: a ⌘Q now has to wait for it")
        await journal.flush(within: .seconds(5))
        #expect(keys.removed && !FileManager.default.fileExists(atPath: journal.files.url("default").path))
        #expect(!journal.hasPendingWork)
    }

    // MARK: Temporary files

    @Test func temporaryFilesALostWriteLeftAreRemoved() async throws {
        let rig = Rig()
        defer { rig.finish() }
        try FileManager.default.createDirectory(at: rig.folder, withIntermediateDirectories: true)
        let live = UUID().uuidString
        await rig.journal.files.write("default", [record("a")])
        await rig.journal.files.write(live, [record("a")])
        func plant() -> [URL] {
            let names = [".default.journal.\(UUID().uuidString).tmp", ".journal.key.\(UUID().uuidString).tmp"]
            return names.map { rig.folder.appendingPathComponent($0) }.map { url in
                FileManager.default.createFile(atPath: url.path, contents: Data("data".utf8))
                return url
            }
        }
        func gone(_ files: [URL]) -> Bool { files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }

        var stale = plant()
        rig.journal.files.cleanStaleTemporaries()
        await rig.journal.files.drain()
        #expect(gone(stale), "at launch")
        #expect(FileManager.default.fileExists(atPath: rig.file().path), "and the journal itself stays")

        stale = plant()
        rig.journal.removeOrphans(keeping: [live])
        await rig.journal.files.drain()
        #expect(gone(stale) && FileManager.default.fileExists(atPath: rig.file(live).path), "with the orphans")

        stale = plant()
        await rig.journal.files.removeFiles()
        #expect(gone(stale), "when the files are cleared")

        stale = plant()
        rig.journal.setEnabled(false)
        await rig.journal.files.drain()
        #expect(gone(stale), "when the switch goes off")
    }

    // MARK: A write that was too late

    @Test func aWriteAskedForBeforeTheFilesWentIsNotMadeAfterThem() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let files = rig.journal.files
        let before = files.generation("default")
        files.revokeAll()
        let result = await files.snapshot("default", cookies: [cookie("sid")], known: [:], lastDigest: nil, generation: before)
        guard case .skipped = result else { Issue.record("it was made: \(result)"); return }
        #expect(!FileManager.default.fileExists(atPath: rig.file().path))
        #expect(!rig.keys.hasKey, "and it didn't make the key again")

        let profile = UUID().uuidString
        let profileBefore = files.generation(profile)
        files.revoke(profile)
        guard case .skipped = await files.snapshot(profile, cookies: [cookie("sid")], known: [:], lastDigest: nil, generation: profileBefore) else { Issue.record("made for a store that was forgotten"); return }
        guard case .written = await files.snapshot("default", cookies: [cookie("sid")], known: [:], lastDigest: nil, generation: files.generation("default")) else { Issue.record("not made when asked for afterwards"); return }
    }

    @Test func turningTheSwitchOffWhileASnapshotIsReadingLeavesNothing() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let source = FakeSource()
        await rig.journal.attach("default", source)
        source.hold()
        source.become([cookie("sid")])
        #expect(await eventually { source.reads >= 1 })
        rig.journal.setEnabled(false)
        source.release()
        await rig.journal.files.drain()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!FileManager.default.fileExists(atPath: rig.file().path) && !rig.keys.hasKey)
    }

    // MARK: Putting back

    @Test func aFresherCookieTheServerGaveMeanwhileIsNotOverwritten() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let first = FakeSource([cookie("a", "journal"), cookie("b", "journal")])
        await rig.journal.attach("default", first)
        #expect(await eventually { await rig.names() == ["a", "b"] })

        let later = CookieJournal(folder: rig.folder, keys: rig.keys, enabled: true, debounce: .milliseconds(30))
        let source = FakeSource()
        // While "a" is being put back, a page that is already loading is given "b" by its server.
        source.afterSet = { source in
            if !source.cookies.contains(where: { $0.name == "b" }) { source.cookies.append(cookie("b", "fresher")) }
        }
        await later.attach("default", source)
        #expect(source.cookies.first { $0.name == "b" }?.value == "fresher")
        #expect(source.set.map(\.name) == ["a"], "\"b\" was looked at again and left alone")
    }

    @Test func aRestoredCookieKeepsItsFirstDate() async throws {
        let clock = SimulatedClock()
        let rig = Rig(debounce: .seconds(2), now: { clock.now }, sleep: { await clock.sleep($0) })
        defer { rig.finish(); clock.finish() }
        let first = FakeSource([cookie("sid", "v1")])
        await rig.journal.attach("default", first)
        await clock.run(for: 3)
        #expect(await eventually { await rig.names() == ["sid"] })
        guard case .records(let written) = await rig.read() else { Issue.record("no file"); return }
        let firstDate = try #require(written.first?.saved)

        // Twenty days on, in a new run: put back, and written again with the same value.
        clock.advance(by: 20 * 86_400)
        let later = CookieJournal(folder: rig.folder, keys: rig.keys, enabled: true, debounce: .seconds(2), now: { clock.now }, sleep: { await clock.sleep($0) })
        let source = FakeSource()
        await later.attach("default", source)
        #expect(source.cookies.map(\.name) == ["sid"])
        source.become([cookie("sid", "v1"), cookie("other")])
        await clock.run(for: 3)
        #expect(await eventually {
            if case .records(let now) = await rig.read() { return now.count == 2 && now.first { $0.name == "sid" }?.saved == firstDate && now.first { $0.name == "other" }?.saved != firstDate }
            return false
        }, "the restored cookie is counted from when it was first journalled, a new one from now")

        // Thirty-one days after the first time, it is gone from the journal though the store has it.
        clock.advance(by: 11 * 86_400)
        source.become([cookie("sid", "v1"), cookie("other")])
        await clock.run(for: 3)
        #expect(await eventually { await rig.names() == ["other"] })
        later.setEnabled(false)
    }

    @Test func theFolderIsLeftOutOfBackups() async throws {
        let rig = Rig()
        defer { rig.finish() }
        await rig.journal.files.write("default", [record("a")])
        let values = try rig.folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func theFileKeyIsLeftOutOfBackupsToo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("journal.key")
        let keys = FileJournalKeys(file: file)
        guard case .key = keys.key(create: true) else { Issue.record("no key"); return }
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
    }
}

extension SharedAgentState {
    @MainActor
    struct CookieJournalProfileTests {
        @Test func deletingAProfileWipesItsJournalFile() async throws {
            let savedRemover = Profiles.remover
            defer { Profiles.remover = savedRemover }
            Profiles.remover = { _ in }
            let box = Sandbox()
            let store = box.store()
            let profile = store.add(name: "P", symbol: "key", tint: .coral, isProfile: true)
            let other = UUID().uuidString
            let id = profile.id.uuidString
            let files = CookieJournal.shared.files
            await files.write(id, [CookieRecord(name: "sid", value: "x", domain: "example.com", path: "/")])
            await files.write(other, [CookieRecord(name: "sid", value: "x", domain: "example.com", path: "/")])
            store.remove(profile.id)
            await Profiles.drain(store)
            _ = await waitUntil { !FileManager.default.fileExists(atPath: files.url(id).path) }
            #expect(!FileManager.default.fileExists(atPath: files.url(id).path), "its cookies are gone with it")
            #expect(FileManager.default.fileExists(atPath: files.url(other).path), "and nobody else's")
            await files.remove(other)
        }
    }
}

struct LastWindowTests {
    @Test func theAppQuitsWhenTheSettingSaysSo() {
        #expect(LastWindow.quits(quitWhenLastWindowCloses: true), "the default: as it has always been")
        #expect(!LastWindow.quits(quitWhenLastWindowCloses: false))
    }

    @Test func theDockIconOpensWhatTheAppIsMissing() {
        #expect(LastWindow.reopen(openWindows: 2, savedWindows: 3) == .system, "windows are open: the system brings back the minimized ones")
        #expect(LastWindow.reopen(openWindows: 1, savedWindows: 0) == .system)
        #expect(LastWindow.reopen(openWindows: 0, savedWindows: 2) == .restoreSession)
        #expect(LastWindow.reopen(openWindows: 0, savedWindows: 0) == .blankWindow)
    }
}
