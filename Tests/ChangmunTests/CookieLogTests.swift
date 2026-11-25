import Foundation
import Testing
import WebKit
@testable import Changmun

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func identity(_ name: String, domain: String = ".naver.com", expires: Date? = nil) -> CookieIdentity {
    CookieIdentity(domain: domain, name: name, path: "/", expires: expires)
}

private func cookie(_ name: String, _ value: String, domain: String = ".naver.com", expires: Date? = nil) -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
    if let expires { properties[.expires] = expires }
    return HTTPCookie(properties: properties)!
}

/// A store's cookies in memory, whose reads can be held back.
@MainActor
private final class Source: CookieSource {
    var cookies: [HTTPCookie]
    /// When set, a read waits for it to open.
    var hold: Gate?
    private var onChange: (@MainActor () -> Void)?

    init(_ cookies: [HTTPCookie] = []) { self.cookies = cookies }

    func allCookies() async -> [HTTPCookie] {
        if let hold { await hold.sleep() }
        return cookies
    }

    func setCookie(_ cookie: HTTPCookie) async { cookies.append(cookie) }
    func startObserving(_ change: @escaping @MainActor () -> Void) { onChange = change }
    func stopObserving() { onChange = nil }

    func become(_ cookies: [HTTPCookie]) {
        self.cookies = cookies
        onChange?()
    }
}

/// A sleep that ends only when the test says so, so what comes in during the window can be controlled.
@MainActor
private final class Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }

    func sleep() async { await withCheckedContinuation { waiting.append($0) } }

    func open() {
        let all = waiting
        waiting = []
        all.forEach { $0.resume() }
    }
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

@Suite("Cookie log")
struct CookieLogTests {
    @Test func countsAddedChangedRemovedAndExpired() {
        let before = CookieLog.baseline([identity("NID_AUT"), identity("NID_SES"), identity("pref", expires: start.addingTimeInterval(86_400)),
                                         identity("old", expires: start.addingTimeInterval(10)), identity("refresh", expires: start.addingTimeInterval(100))],
                                        now: start)
        let now = start.addingTimeInterval(60)
        let after = [identity("NID_AUT"), identity("refresh", expires: start.addingTimeInterval(1_000)), identity("new")]
        let (change, next) = CookieLog.diff(before, after, now: now)
        #expect(change.added == 1)
        #expect(change.changed == 1)
        #expect(change.expired == 1)
        #expect(change.removed.map(\.identity.name) == ["NID_SES", "pref"])
        #expect(change.removed.allSatisfy { $0.age == 60 && $0.sinceBaseline })
        #expect(change.sessionBefore == 2)
        #expect(change.sessionAfter == 2)
        #expect(!change.massLoss)
        #expect(next.count == 3)
        // A cookie that stays keeps its first sighting; a new one counts from now.
        #expect(next[identity("NID_AUT").key]?.since == start)
        #expect(next[identity("new").key]?.since == now)
        #expect(next[identity("new").key]?.sinceBaseline == false)
    }

    @Test func aSessionCookieTurnedPersistentIsAChange() {
        let before = CookieLog.baseline([identity("a")], now: start)
        let (change, _) = CookieLog.diff(before, [identity("a", expires: start.addingTimeInterval(3_600))], now: start)
        #expect(change.changed == 1)
        #expect(change.removed.isEmpty)
        #expect(change.sessionAfter == 0)
    }

    @Test func massLossNeedsFiveAndHalf() {
        let ten = (0..<10).map { identity("s\($0)") }
        let before = CookieLog.baseline(ten, now: start)
        #expect(CookieLog.diff(before, Array(ten.prefix(5)), now: start).0.massLoss)
        #expect(!CookieLog.diff(before, Array(ten.prefix(6)), now: start).0.massLoss)
        // Four of four is all of them, but too few to say a process lost its memory.
        let four = CookieLog.baseline(Array(ten.prefix(4)), now: start)
        #expect(!CookieLog.diff(four, [], now: start).0.massLoss)
        // Persistent cookies going don't count towards it.
        let persistent = CookieLog.baseline((0..<10).map { identity("p\($0)", expires: start.addingTimeInterval(86_400)) } + Array(ten.prefix(2)), now: start)
        #expect(!CookieLog.diff(persistent, [], now: start).0.massLoss)
    }

    @Test func linesNameEachRemovalAndSummarise() {
        let before = CookieLog.baseline([identity("NID_SES"), identity("keep", domain: "example.com", expires: start.addingTimeInterval(86_400))], now: start)
        let (change, _) = CookieLog.diff(before, [identity("other")], now: start.addingTimeInterval(90))
        let lines = CookieLog.lines(change, store: "default", networkProcess: nil)
        #expect(lines == [
            "removed store=default domain=.naver.com name=NID_SES path=/ session age>=90s",
            "removed store=default domain=example.com name=keep path=/ persistent expires=\(start.addingTimeInterval(86_400).formatted(.iso8601)) age>=90s",
            "diff store=default added=1 changed=0 removed=2 expired=0 sessionCookies=1->1",
        ])
    }

    @Test func withoutNamingTheLogKeepsOnlyCounts() {
        let before = CookieLog.baseline([identity("NID_SES"), identity("keep", domain: "example.com")], now: start)
        let (change, _) = CookieLog.diff(before, [], now: start.addingTimeInterval(90))
        let lines = CookieLog.lines(change, store: "default", networkProcess: nil, naming: false)
        #expect(lines == ["diff store=default added=0 changed=0 removed=2 expired=0 sessionCookies=2->0"])
        #expect(!lines.joined().contains("naver") && !lines.joined().contains("NID_SES"))
        #expect(!UserDefaults.standard.bool(forKey: CookieLog.namesSitesKey), "off unless the user turns it on")
    }

    @Test func expiredCookiesGetOneLine() {
        let before = CookieLog.baseline((0..<3).map { identity("e\($0)", expires: start.addingTimeInterval(5)) }, now: start)
        let (change, _) = CookieLog.diff(before, [], now: start.addingTimeInterval(10))
        #expect(CookieLog.lines(change, store: "p", networkProcess: nil) == [
            "expired store=p count=3",
            "diff store=p added=0 changed=0 removed=0 expired=3 sessionCookies=0->0",
        ])
    }

    @Test func massLossNamesTheNetworkProcess() {
        let before = CookieLog.baseline((0..<6).map { identity("s\($0)") }, now: start)
        let (change, _) = CookieLog.diff(before, [], now: start)
        #expect(CookieLog.lines(change, store: "default", networkProcess: 4242).last
                == "MASS LOSS store=default sessionCookiesLost=6 of=6 networkProcess=4242")
    }

    @Test func aLookThatFindsNothingWritesNothing() {
        let before = CookieLog.baseline([identity("a")], now: start)
        #expect(CookieLog.lines(CookieLog.diff(before, [identity("a")], now: start).0, store: "default", networkProcess: nil).isEmpty)
    }

    @Test func restoreAndLaunchLines() {
        #expect(CookieLog.restoreLine(store: "default", file: "records", restored: 3, skipped: 2, took: .milliseconds(42))
                == "restore store=default file=records restored=3 skipped=2 took=0.042s")
        #expect(CookieLog.launchLine(took: .milliseconds(1_200), cap: .seconds(5)) == "launch restore finished took=1.200s within the 5.000s cap")
        #expect(CookieLog.launchLine(took: .seconds(7), cap: .seconds(5)).contains("after the 5.000s cap"))
    }

    @MainActor @Test func theNetworkProcessIdentifierIsAProcessOrNothing() async {
        // Asked of a store that has read its cookies, so there is a network process to name.
        let store = WKWebsiteDataStore.nonPersistent()
        _ = await store.httpCookieStore.allCookies()
        let pid = CookieLog.networkProcess(of: store)
        #expect(pid == nil || pid! > 0)
    }

    /// When cookies go and the log names sites, the trail of the sites they were from follows; without naming, no trail is asked for.
    @MainActor @Test func aLossIsFollowedByWhatTheSitesPagesLoadedOnlyWhenNamingSites() async {
        for naming in [true, false] {
            let source = Source([cookie("NID_AUT", "a", expires: start.addingTimeInterval(3_600)), cookie("other", "b", domain: "example.com", expires: start.addingTimeInterval(3_600))])
            var written: [String] = []
            var asked: [Set<String>] = []
            let watch = CookieWatch(store: "default", source: source, now: { start }, sleep: { _ in }, write: { written += $0 }, naming: { naming },
                                    trail: { sites in asked.append(sites); return ["trail tab=1 page=www.naver.com -120ms fetch static.nid.naver.com/getProfile"] },
                                    networkProcess: { nil })
            watch.start()
            await watch.settle()
            source.become([cookie("other", "b", domain: "example.com", expires: start.addingTimeInterval(3_600))])
            await watch.settle()
            #expect(asked == (naming ? [["naver.com"]] : []))
            #expect(written.contains("trail tab=1 page=www.naver.com -120ms fetch static.nid.naver.com/getProfile") == naming)
        }
    }

    @Test func aTrailLineHasTheTimeTheKindAndTheAddressWithoutItsQuery() {
        #expect(ResourceTrail.format(tab: 3, page: "www.naver.com", [[250, "xmlhttprequest", "nid.naver.com", "/login/ext"], [900, "page", "www.naver.com", "/"]]) == [
            "trail tab=3 page=www.naver.com -250ms xmlhttprequest nid.naver.com/login/ext",
            "trail tab=3 page=www.naver.com -900ms page www.naver.com/",
        ])
        #expect(ResourceTrail.format(tab: 3, page: "a.example", []) == ["trail tab=3 page=a.example nothing loaded in the last 3000ms"])
        #expect(ResourceTrail.site(ofCookieDomain: ".nid.naver.com") == "naver.com" && ResourceTrail.site(ofCookieDomain: "www.naver.com") == "naver.com")
    }

    @MainActor @Test func noValueReachesALine() async {
        let secrets = (0..<8).map { "SECRET-VALUE-\($0)-\(UUID().uuidString)" }
        let source = Source(secrets.enumerated().map { cookie("NID_\($0.offset)", $0.element) })
        var written: [String] = []
        let watch = CookieWatch(store: "default", source: source, now: { start }, sleep: { _ in }, write: { written += $0 }, naming: { true }, networkProcess: { 7 })
        watch.start()
        await watch.settle()
        source.become([cookie("NID_0", "SECRET-VALUE-new"), cookie("fresh", "SECRET-VALUE-fresh", expires: Date().addingTimeInterval(3_600))])
        await watch.settle()
        #expect(written.contains { $0.hasPrefix("watching store=default cookies=8 session=8 networkProcess=7") })
        #expect(written.contains { $0.hasPrefix("MASS LOSS store=default sessionCookiesLost=7 of=8 networkProcess=7") })
        #expect(written.contains("removed store=default domain=.naver.com name=NID_1 path=/ session age>=0s"))
        #expect(!written.contains { $0.contains("SECRET") })
    }

    @MainActor @Test func aBurstOfChangesIsOneLook() async {
        let gate = Gate()
        let source = Source([cookie("a", "1")])
        var written: [String] = []
        let watch = CookieWatch(store: "default", source: source, sleep: { _ in await gate.sleep() }, write: { written += $0 }, networkProcess: { nil })
        watch.start()
        await watch.settle()
        #expect(watch.looks == 1)
        for n in 0..<20 { source.become([cookie("a", "1")] + (0...n).map { cookie("b\($0)", "x") }) }
        #expect(await eventually { gate.count == 1 })
        gate.open()
        await watch.settle()
        #expect(watch.looks == 2)
        #expect(written.last == "diff store=default added=20 changed=0 removed=0 expired=0 sessionCookies=1->21")
    }

    @MainActor @Test func aChangeDuringALookGetsAnotherLook() async {
        let window = Gate(), reading = Gate()
        let source = Source([cookie("a", "1")])
        let watch = CookieWatch(store: "default", source: source, sleep: { _ in await window.sleep() }, write: { _ in }, networkProcess: { nil })
        watch.start()
        await watch.settle()
        source.hold = reading
        source.become([])
        #expect(await eventually { window.count == 1 })
        window.open()
        #expect(await eventually { reading.count == 1 })
        // The store is being read: a change now may not be in what comes back.
        source.become([cookie("c", "3")])
        source.hold = nil
        reading.open()
        #expect(await eventually { window.count == 1 })
        #expect(watch.looks == 2)
        window.open()
        await watch.settle()
        #expect(watch.looks == 3)
    }

    /// The default store holds about 5,000 cookies; the look a change brings must stay cheap.
    @Test func diffOfFiveThousandCookiesIsCheap() {
        let cookies = (0..<5_000).map { cookie("c\($0)", "value\($0)", domain: "site\($0 % 700).example", expires: $0 % 20 == 0 ? nil : start.addingTimeInterval(86_400)) }
        let clock = ContinuousClock()
        var identities: [CookieIdentity] = []
        let read = clock.measure { identities = CookieLog.identities(cookies) }
        let before = CookieLog.baseline(identities, now: start)
        var after = identities
        after.removeLast(50)
        var change = CookieLog.Change()
        let diff = clock.measure { change = CookieLog.diff(before, after, now: start.addingTimeInterval(1)).0 }
        print("CookieLog: 5,000 cookies: identities \(read), diff \(diff)")
        #expect(change.removed.count == 50)
        #expect(read + diff < .seconds(1))
    }
}
