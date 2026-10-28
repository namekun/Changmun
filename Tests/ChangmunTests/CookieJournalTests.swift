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

private func record(_ name: String, _ value: String = "v", domain: String = "example.com", path: String = "/", expires: Date? = nil) -> CookieRecord {
    CookieRecord(name: name, value: value, domain: domain, path: path, expires: expires)
}

/// A store's cookies in memory: what WebKit's would be, with a gate to hold its answer back while a restore is under way.
@MainActor
private final class FakeSource: CookieSource {
    var cookies: [HTTPCookie]
    private(set) var set: [HTTPCookie] = []
    private(set) var observing = false
    private var onChange: (@MainActor () -> Void)?
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
        if gated { await withCheckedContinuation { waiting.append($0) } }
        return cookies
    }

    func setCookie(_ cookie: HTTPCookie) async {
        set.append(cookie)
        cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
        if gatedSets { await withCheckedContinuation { waiting.append($0) } }
        cookies.append(cookie)
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

    init(enabled: Bool = true, debounce: Duration = .milliseconds(30), keys: MemoryJournalKeys = MemoryJournalKeys(), now: @escaping () -> Date = Date.init) {
        self.keys = keys
        journal = CookieJournal(folder: folder, keys: keys, enabled: enabled, debounce: debounce, now: now)
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
        cookie("persistent", "p1", domain: ".example.com", path: "/app", expires: Date(timeIntervalSince1970: 4_000_000_000.25)),
        cookie("secret", "a b;c=d\u{00e9}\u{d55c}", domain: "www.example.com", secure: true, httpOnly: true, sameSite: .sameSiteStrict),
        cookie("lax", "l", domain: "example.org", expires: Date(timeIntervalSince1970: 4_100_000_000), httpOnly: true, sameSite: .sameSiteLax),
    ]

    @Test func everyAttributeOfACookieSurvivesTheJournal() throws {
        let sealed = try #require(CookieJournalFile.seal(everything.map(CookieRecord.init), store: "default", key: key))
        let opened = try #require(CookieJournalFile.open(sealed, store: "default", key: key))
        let back = try opened.map { try #require($0.cookie) }
        #expect(back.count == everything.count)
        for (was, now) in zip(everything, back) {
            #expect(now.name == was.name && now.value == was.value, "\(was.name)")
            #expect(now.domain == was.domain && now.path == was.path, "\(was.name)")
            #expect(now.expiresDate == was.expiresDate, "\(was.name)")
            #expect(now.isSessionOnly == was.isSessionOnly, "\(was.name)")
            #expect(now.isSecure == was.isSecure && now.isHTTPOnly == was.isHTTPOnly, "\(was.name)")
            #expect(now.sameSitePolicy == was.sameSitePolicy, "\(was.name)")
        }
        #expect(back[0].isSessionOnly && back[0].expiresDate == nil, "a session cookie stays one")
        #expect(back[2].isSecure && back[2].isHTTPOnly && back[2].sameSitePolicy == .sameSiteStrict)
        #expect(back[1].domain == ".example.com", "a domain cookie keeps its dot, a host cookie lacks it")
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
        let sealed = try #require(CookieJournalFile.seal(everything.map(CookieRecord.init), store: "default", key: key))
        for index in stride(from: 0, to: sealed.count, by: max(1, sealed.count / 40)) + [sealed.count - 1] {
            var damaged = sealed
            damaged[index] ^= 0x01
            #expect(CookieJournalFile.open(damaged, store: "default", key: key) == nil, "byte \(index) changed")
        }
    }

    // MARK: What is put back

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func onlyTheCookiesTheStoreLacksComeBack() {
        let records = [record("a", "journal"), record("b", "journal"), record("c", "journal", domain: "other.example")]
        let back = CookieJournalFile.missing(from: records, in: [cookie("a", "fresher")], now: now)
        #expect(back.map(\.name) == ["b", "c"], "a cookie the store has is newer than the journal's, whatever its value")
        #expect(CookieJournalFile.missing(from: [record("a", domain: "Example.COM")], in: [cookie("a")], now: now).isEmpty, "domains are compared without case")
        #expect(CookieJournalFile.missing(from: [record("a", path: "/x")], in: [cookie("a")], now: now).map(\.path) == ["/x"], "another path is another cookie")
    }

    @Test func expiredCookiesStayGone() {
        let records = [record("old", expires: now.addingTimeInterval(-1)), record("edge", expires: now), record("live", expires: now.addingTimeInterval(60)), record("session")]
        #expect(CookieJournalFile.missing(from: records, in: [], now: now).map(\.name) == ["live", "session"])
    }

    @Test func aSessionCookieComesBackAsOneOfThisRun() throws {
        let back = try #require(CookieJournalFile.missing(from: [CookieRecord(cookie("sid", "x", httpOnly: true))], in: [], now: now).first)
        #expect(back.isSessionOnly && back.expiresDate == nil && back.isHTTPOnly && back.value == "x")
    }

    @Test func aCookieTwiceInTheJournalComesBackOnce() {
        #expect(CookieJournalFile.missing(from: [record("a", "1"), record("a", "2")], in: [], now: now).map(\.value) == ["1"])
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
        source.become([cookie("sid"), cookie("pid", expires: Date().addingTimeInterval(3600))])
        #expect(await eventually { await rig.names() == ["pid", "sid"] })
        source.become([cookie("sid")])
        #expect(await eventually { await rig.names() == ["sid"] }, "a cookie the store dropped is dropped from the next snapshot too")
        source.become([])
        #expect(await eventually { !FileManager.default.fileExists(atPath: rig.file().path) }, "no cookies, no file")
    }

    @Test func aBurstOfChangesIsOneWrite() async throws {
        let rig = Rig(debounce: .milliseconds(150))
        defer { rig.finish() }
        let source = FakeSource()
        await rig.journal.attach("default", source)
        for index in 0..<5 {
            source.become([cookie("c\(index)")])
            await quietFor(.milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: rig.file().path), "still being changed: not yet")
        #expect(await eventually { await rig.names() == ["c4"] })
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
        first.become([cookie("sid", "old"), cookie("kept", "journal"), cookie("gone", "journal", expires: Date().addingTimeInterval(3600))])
        #expect(await eventually { await rig.names()?.count == 3 })

        // The next run: WebKit has the persistent cookies it saved itself (one of them changed since), but no session cookie.
        let later = CookieJournal(folder: rig.folder, keys: rig.keys, enabled: true, debounce: .milliseconds(30))
        let source = FakeSource([cookie("gone", "fresher", expires: Date().addingTimeInterval(7200))])
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

    @Test func aKeyThatCantBeHadMeansNothingIsKept() async throws {
        let rig = Rig(keys: MemoryJournalKeys(unavailable: true))
        defer { rig.finish() }
        let source = FakeSource([cookie("sid")])
        await rig.journal.attach("default", source)
        source.become([cookie("sid"), cookie("more")])
        await rig.journal.flush(within: .seconds(2))
        await quietFor(.milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: rig.file().path))
        #expect(source.set.isEmpty)
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
        let one = FakeSource([cookie("sid"), cookie("pid", expires: Date().addingTimeInterval(3600))]), two = FakeSource([cookie("work")])
        await rig.journal.attach("default", one)
        await rig.journal.attach(profile, two)
        #expect(await eventually { await rig.holds(["default": ["pid", "sid"], profile: ["work"]]) })

        rig.journal.clearing()
        #expect(await eventually { !FileManager.default.fileExists(atPath: rig.file().path) && !FileManager.default.fileExists(atPath: rig.file(profile).path) })
        // A cookie cleared "for the past hour" leaves the older ones, which the journal keeps on being told about once the clearing is done.
        one.cookies = [cookie("pid", expires: Date().addingTimeInterval(3600))]
        two.cookies = []
        rig.journal.cleared()
        #expect(await eventually { await rig.names() == ["pid"] })
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
