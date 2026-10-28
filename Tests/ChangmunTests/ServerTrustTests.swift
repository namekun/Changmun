import Foundation
import Security
import WebKit
import Testing
@testable import Changmun

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400

private func details(names: [String] = ["example.com"], selfSigned: Bool = false, from: TimeInterval = -30, to: TimeInterval = 30) -> CertificateDetails {
    CertificateDetails(subject: "example.com", issuer: selfSigned ? "example.com" : "Some CA", notBefore: now + from * day, notAfter: now + to * day,
                       fingerprint: String(repeating: "ab", count: 32), names: names, isSelfSigned: selfSigned)
}

struct ServerTrustExceptionTests {
    @Test func anExceptionIsForTheHostThePortAndTheCertificateAlone() {
        var exceptions = ServerTrustExceptions()
        exceptions.grant(host: "Intranet.Example.com", port: 8443, fingerprint: "aa", store: nil)
        #expect(exceptions.allows(host: "intranet.example.com", port: 8443, fingerprint: "aa", store: nil), "host letter case does not matter")
        #expect(exceptions.allows(host: "intranet.example.com.", port: 8443, fingerprint: "aa", store: nil), "nor a dot at the end")
        #expect(!exceptions.allows(host: "intranet.example.com", port: 443, fingerprint: "aa", store: nil), "another port")
        #expect(!exceptions.allows(host: "other.example.com", port: 8443, fingerprint: "aa", store: nil), "another host")
        #expect(!exceptions.allows(host: "intranet.example.com", port: 8443, fingerprint: "bb", store: nil), "another certificate")
    }

    @Test func aProfileSpaceDoesNotShareAChoiceWithTheOthers() {
        var exceptions = ServerTrustExceptions()
        let profile = UUID()
        exceptions.grant(host: "a.test", port: 443, fingerprint: "aa", store: profile)
        #expect(exceptions.allows(host: "a.test", port: 443, fingerprint: "aa", store: profile))
        #expect(!exceptions.allows(host: "a.test", port: 443, fingerprint: "aa", store: nil))
        #expect(!exceptions.allows(host: "a.test", port: 443, fingerprint: "aa", store: UUID()))
    }

    @Test func aChangedCertificateIsNotCoveredAndIsSaidToHaveChanged() {
        var exceptions = ServerTrustExceptions()
        #expect(!exceptions.isChanged(host: "a.test", port: 443, fingerprint: "bb", store: nil), "nothing was accepted, so nothing changed")
        exceptions.grant(host: "a.test", port: 443, fingerprint: "aa", store: nil)
        #expect(exceptions.isChanged(host: "a.test", port: 443, fingerprint: "bb", store: nil))
        #expect(!exceptions.isChanged(host: "a.test", port: 443, fingerprint: "aa", store: nil))
        #expect(!exceptions.allows(host: "a.test", port: 443, fingerprint: "bb", store: nil))
    }

    @Test func aSecondChoiceReplacesTheFirst() {
        var exceptions = ServerTrustExceptions()
        exceptions.grant(host: "a.test", port: 443, fingerprint: "aa", store: nil)
        exceptions.grant(host: "a.test", port: 443, fingerprint: "bb", store: nil)
        #expect(!exceptions.allows(host: "a.test", port: 443, fingerprint: "aa", store: nil))
        #expect(exceptions.allows(host: "a.test", port: 443, fingerprint: "bb", store: nil))
    }

    @Test func takingAnExceptionAwayStopsItFromApplying() {
        var exceptions = ServerTrustExceptions()
        exceptions.grant(host: "a.test", port: 443, fingerprint: "aa", store: nil)
        exceptions.revoke(host: "a.test", port: 443, store: nil)
        #expect(!exceptions.hasException(host: "a.test", port: 443, store: nil))
        #expect(!exceptions.allows(host: "a.test", port: 443, fingerprint: "aa", store: nil))
        exceptions.grant(host: "b.test", port: 443, fingerprint: "aa", store: nil)
        exceptions.removeAll()
        #expect(!exceptions.hasException(host: "b.test", port: 443, store: nil))
    }

    /// WebKit keeps a certificate it was told to go on with in a session of its own, and the sessions are not the app's stores or windows, so what was
    /// accepted anywhere is remembered by host and port for the whole run, whatever happens to the exceptions.
    @Test func aHostAcceptedAnywhereIsRememberedForTheRunByHostAndPort() {
        var accepted = AcceptedSites()
        #expect(!accepted.contains(host: "a.test", port: 443))
        accepted.add(host: "A.test.", port: 443)
        #expect(accepted.contains(host: "a.test", port: 443))
        #expect(!accepted.contains(host: "a.test", port: 8443), "another port")
        #expect(!accepted.contains(host: "b.test", port: 443), "another host")
    }

    /// Every combination of what a challenge has (or lacks) and what is true of it, against what a challenge for a host the user went on with must do.
    @Test func aChallengeForAHostAcceptedAnywhereGoesThroughOnlyOnThisStoresExceptionOrTheMacsOwnTrust() {
        typealias Decision = ServerTrustChallengeDecision
        let flags = [false, true]
        var seen = 0
        for accepted in flags { for hasTrust in flags { for hasStore in flags { for hasLeaf in flags { for systemTrusts in flags { for matches in flags { for mayOffer in flags {
            let got = Decision.decide(accepted: accepted, hasTrust: hasTrust, hasStore: hasStore, hasLeaf: hasLeaf, systemTrusts: systemTrusts,
                                      exceptionMatches: matches, mayOffer: mayOffer)
            let wanted: Decision
            if !accepted { wanted = .defaultHandling }
            else if hasTrust && hasStore && hasLeaf && matches && mayOffer { wanted = .useException }
            else if hasTrust && systemTrusts { wanted = .defaultHandling }
            else { wanted = .cancel }
            #expect(got == wanted, "accepted \(accepted) trust \(hasTrust) store \(hasStore) leaf \(hasLeaf) system \(systemTrusts) matches \(matches) mayOffer \(mayOffer)")
            seen += 1
        } } } } } } }
        #expect(seen == 128)
    }

    @Test func aMissingPieceNeverLetsAChallengeForAnAcceptedHostThrough() {
        typealias Decision = ServerTrustChallengeDecision
        // Nothing to judge it by: cancelled, whatever else is true.
        #expect(Decision.decide(accepted: true, hasTrust: false, hasStore: true, hasLeaf: true, systemTrusts: true, exceptionMatches: true, mayOffer: true) == .cancel)
        #expect(Decision.decide(accepted: true, hasTrust: true, hasStore: false, hasLeaf: true, systemTrusts: false, exceptionMatches: true, mayOffer: true) == .cancel)
        #expect(Decision.decide(accepted: true, hasTrust: true, hasStore: true, hasLeaf: false, systemTrusts: false, exceptionMatches: true, mayOffer: true) == .cancel)
        // A host nobody went on with is judged as ever, with or without the pieces.
        #expect(Decision.decide(accepted: false, hasTrust: false, hasStore: false, hasLeaf: false, systemTrusts: false, exceptionMatches: false, mayOffer: false) == .defaultHandling)
        // The Mac's own trust is only asked when the exception does not decide it.
        var asked = 0
        _ = Decision.decide(accepted: true, hasTrust: true, hasStore: true, hasLeaf: true, systemTrusts: { asked += 1; return false }(), exceptionMatches: true, mayOffer: true)
        #expect(asked == 0)
    }

    @Test func theWarningIsForTheMainFrameLoadThatIsPendingAndNothingElse() {
        let pending = URL(string: "https://Intranet.test:8443/page?x=1")
        #expect(TrustFailure.pendingTarget(navigatingTo: pending, host: "intranet.test", port: 8443) == pending)
        #expect(TrustFailure.pendingTarget(navigatingTo: nil, host: "intranet.test", port: 8443) == nil, "no main frame load is pending: a subresource, or a later load")
        #expect(TrustFailure.pendingTarget(navigatingTo: pending, host: "cdn.test", port: 8443) == nil, "another host than the page's")
        #expect(TrustFailure.pendingTarget(navigatingTo: pending, host: "intranet.test", port: 443) == nil, "another port")
        #expect(TrustFailure.pendingTarget(navigatingTo: URL(string: "https://intranet.test/")!, host: "intranet.test", port: 443) != nil, "the port of https is 443")
        #expect(TrustFailure.pendingTarget(navigatingTo: URL(string: "http://intranet.test/")!, host: "intranet.test", port: 80) == nil, "only https")
    }

    @Test func noExceptionIsOfferedToThePagesOfTheAIOrToAHeadlessChangmun() {
        #expect(ServerTrust.mayOffer(agentDriven: false, headless: false, testCopy: false))
        #expect(!ServerTrust.mayOffer(agentDriven: true, headless: false, testCopy: false), "a page the AI drives")
        #expect(!ServerTrust.mayOffer(agentDriven: false, headless: true, testCopy: false), "headless")
        #expect(!ServerTrust.mayOffer(agentDriven: true, headless: true, testCopy: true), "even in the test copy, not for the AI")
        #expect(ServerTrust.mayOffer(agentDriven: false, headless: true, testCopy: true), "the test copy, where a test stands in for the user")
    }
}

struct TrustReasonTests {
    private func reason(_ certificate: CertificateDetails, host: String = "example.com", code: Int = NSURLErrorServerCertificateUntrusted) -> TrustReason {
        TrustReason.determine(code: code, certificate: certificate, host: host, now: now)
    }

    @Test func aCertificateThatRanOutOrIsNotYetValidSaysSo() {
        #expect(reason(details(to: -1)) == .expired(now - day))
        #expect(reason(details(from: 2, to: 30)) == .notYetValid(now + 2 * day))
        #expect(reason(details(to: -1), code: NSURLErrorServerCertificateHasBadDate) == .expired(now - day))
    }

    @Test func aCertificateForAnotherNameSaysSo() {
        #expect(reason(details(names: ["other.example.com"])) == .nameMismatch)
        #expect(reason(details(names: [])) == .nameMismatch)
    }

    @Test func aSelfSignedCertificateSaysSo() {
        #expect(reason(details(selfSigned: true)) == .selfSigned)
    }

    @Test func aCertificateFromAnAuthorityTheMacDoesNotKnowSaysSo() {
        #expect(reason(details()) == .unknownAuthority)
        #expect(reason(details(), code: NSURLErrorServerCertificateHasUnknownRoot) == .unknownAuthority)
        #expect(reason(details(), code: NSURLErrorServerCertificateHasBadDate) == .other, "no date is wrong, so the code alone is not enough to say more")
    }

    @Test func theNameMatchesAsTheSystemRuleHasIt() {
        #expect(details(names: ["example.com"]).covers(host: "EXAMPLE.com"))
        #expect(details(names: ["*.example.com"]).covers(host: "www.example.com"))
        #expect(!details(names: ["*.example.com"]).covers(host: "example.com"), "a wildcard stands for one label")
        #expect(!details(names: ["*.example.com"]).covers(host: "a.b.example.com"))
        #expect(details(names: ["10.0.0.5"]).covers(host: "10.0.0.5"))
        #expect(!details(names: ["*.0.0.5"]).covers(host: "10.0.0.5"), "a wildcard never stands for part of an address")
        #expect(!details(names: ["10.0.0.5"]).covers(host: "10.0.0.6"))
    }
}

/// The certificates here are read from real ones made by openssl, in a folder of their own.
struct CertificateDetailsTests {
    private func openssl(_ arguments: [String], in folder: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func certificate(named file: String, in folder: URL) throws -> SecCertificate {
        let pem = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
        let der = try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
        return try #require(SecCertificateCreateWithData(nil, der as CFData))
    }

    @Test func aSelfSignedCertificateIsReadWithItsNamesAndDates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("changmun-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #require(openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "k.pem", "-out", "self.pem", "-days", "10", "-subj", "/CN=intranet.test/O=Test",
                              "-addext", "subjectAltName=DNS:intranet.test,DNS:*.intranet.test,IP:10.1.2.3"], in: folder))
        let certificate = try certificate(named: "self.pem", in: folder)
        let read = try #require(CertificateDetails(certificate))
        #expect(read.subject == "intranet.test" && read.issuer == "intranet.test" && read.isSelfSigned)
        #expect(read.names == ["intranet.test", "*.intranet.test", "10.1.2.3"])
        #expect(read.covers(host: "www.intranet.test") && read.covers(host: "10.1.2.3") && !read.covers(host: "10.1.2.4"))
        #expect(read.fingerprint == ServerTrust.fingerprint(of: certificate) && read.fingerprint.count == 64)
        #expect(read.spacedFingerprint.split(separator: ":").count == 32)
        #expect(abs(read.notAfter.timeIntervalSinceNow - 10 * day) < 2 * day)
        #expect(TrustReason.determine(code: NSURLErrorServerCertificateUntrusted, certificate: read, host: "intranet.test", now: Date()) == .selfSigned)
        #expect(TrustReason.determine(code: NSURLErrorServerCertificateUntrusted, certificate: read, host: "other.test", now: Date()) == .nameMismatch)
    }

    @Test func aCertificateFromAnAuthorityNamesItsIssuerAndIsNotSelfSigned() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("changmun-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #require(openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "30", "-subj", "/CN=Test Private CA"], in: folder))
        try #require(openssl(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "s.key", "-out", "s.csr", "-subj", "/CN=server.test"], in: folder))
        try #require(openssl(["x509", "-req", "-in", "s.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "s.pem", "-days", "10"], in: folder))
        let read = try #require(CertificateDetails(try certificate(named: "s.pem", in: folder)))
        #expect(read.subject == "server.test" && read.issuer == "Test Private CA" && !read.isSelfSigned && read.names.isEmpty)
        #expect(TrustReason.determine(code: NSURLErrorServerCertificateUntrusted, certificate: read, host: "server.test", now: Date()) == .nameMismatch, "no names: the system's rule has it for no one")
    }

    @Test func aFailedLoadIsReadFromItsErrorAndOnlyFromThose() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("changmun-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #require(openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "k.pem", "-out", "self.pem", "-days", "10", "-subj", "/CN=intranet.test",
                              "-addext", "subjectAltName=DNS:intranet.test"], in: folder))
        let certificate = try certificate(named: "self.pem", in: folder)
        var trust: SecTrust?
        try #require(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let address = URL(string: "https://intranet.test:8443/path")!
        func error(_ code: Int, domain: String = NSURLErrorDomain, trust: SecTrust? = trust) -> NSError {
            var info: [String: Any] = [NSURLErrorFailingURLErrorKey: address]
            if let trust { info[NSURLErrorFailingURLPeerTrustErrorKey] = trust }
            return NSError(domain: domain, code: code, userInfo: info)
        }
        let failure = try #require(TrustFailure.from(error: error(NSURLErrorServerCertificateUntrusted), url: nil, changed: { host, port, _ in host == "intranet.test" && port == 8443 }))
        #expect(failure.host == "intranet.test" && failure.port == 8443 && failure.code == -1202 && failure.changed)
        #expect(failure.reason == .selfSigned && failure.url == address)
        #expect(failure.visit == .offered)
        let wentBad = try #require(TrustFailure.from(error: error(NSURLErrorServerCertificateUntrusted), url: nil, changed: { _, _, _ in false }, wasTrusted: { host, port in host == "intranet.test" && port == 8443 }))
        #expect(wentBad.visit == .refusedWentBad, "it loaded over a trusted connection before: no way on")
        let strict = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted,
                             userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://intranet.dev/")!, NSURLErrorFailingURLPeerTrustErrorKey: trust as Any])
        #expect(TrustFailure.from(error: strict, url: nil, changed: { _, _, _ in false })?.visit == .refusedStrictTransport)
        #expect(TrustFailure.from(error: error(NSURLErrorTimedOut), url: nil, changed: { _, _, _ in false }) == nil, "another kind of failure")
        #expect(TrustFailure.from(error: error(NSURLErrorServerCertificateUntrusted, domain: "WebKitErrorDomain"), url: nil, changed: { _, _, _ in false }) == nil)
        #expect(TrustFailure.from(error: error(NSURLErrorServerCertificateUntrusted, trust: nil), url: nil, changed: { _, _, _ in false }) == nil, "no certificate to show")
        let http = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted,
                           userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "http://intranet.test/")!, NSURLErrorFailingURLPeerTrustErrorKey: trust as Any])
        #expect(TrustFailure.from(error: http, url: nil, changed: { _, _, _ in false }) == nil, "only https")
    }
}

struct ServerTrustPolicyTests {
    @Test func aSiteThatInsistsOnHTTPSByThePreloadListCannotBeOverridden() {
        for host in ["example.dev", "EXAMPLE.App", "a.b.page", "my.new", "x.day.", "foo.zip", "a.mov", "dev"] {
            #expect(ServerTrustPolicy.visit(host: host, wasTrusted: false) == .refusedStrictTransport, "\(host)")
        }
        for host in ["example.com", "intranet.local", "localhost", "127.0.0.1", "a.xyz", "dev.example.com", "app.example.org", "foo.fyi", "device.example", "[::1]"] {
            #expect(ServerTrustPolicy.visit(host: host, wasTrusted: false) == .offered, "\(host)")
        }
    }

    @Test func aCertificateThatWasFineAndIsNotIsNotOverridden() {
        #expect(ServerTrustPolicy.visit(host: "example.com", wasTrusted: true) == .refusedWentBad)
        #expect(ServerTrustPolicy.visit(host: "example.dev", wasTrusted: true) == .refusedStrictTransport, "the stricter reason first")
    }

    @Test func aHostIsTrustedPerStore() {
        var trusted = TrustedSites()
        let profile = UUID()
        trusted.add(host: "A.test", port: 443, store: nil)
        #expect(trusted.contains(host: "a.test", port: 443, store: nil))
        #expect(!trusted.contains(host: "a.test", port: 443, store: profile))
        #expect(!trusted.contains(host: "a.test", port: 8443, store: nil))
    }

    @Test func aPrivateWindowsAcceptedHostsGoWithIt() {
        var accepted = AcceptedSites()
        let one = NSObject(), two = NSObject()
        accepted.add(host: "a.test", port: 443, owner: ObjectIdentifier(one))
        accepted.add(host: "b.test", port: 443, owner: ObjectIdentifier(one))
        accepted.add(host: "b.test", port: 443, owner: ObjectIdentifier(two))
        accepted.add(host: "c.test", port: 443)
        #expect(accepted.contains(host: "a.test", port: 443))
        accepted.removeAll(ownedBy: ObjectIdentifier(one))
        #expect(!accepted.contains(host: "a.test", port: 443), "only that window accepted it")
        #expect(accepted.contains(host: "b.test", port: 443), "another window accepted it too")
        #expect(accepted.contains(host: "c.test", port: 443), "a window that is not private keeps it for the run")
        accepted.removeAll(ownedBy: ObjectIdentifier(two))
        #expect(!accepted.contains(host: "b.test", port: 443))
    }
}

struct ServerTrustTextTests {
    @Test func textFromACertificateShowsHiddenAndTurningCharactersAsBoxesAndIsCapped() {
        #expect(ServerTrust.sanitized("a\u{0}b\u{7}c\nd\te") == "a▯b▯c▯d▯e")
        #expect(ServerTrust.sanitized("pay\u{202E}lap.com") == "pay▯lap.com", "a right-to-left override would show the end first; it is seen as changed")
        #expect(ServerTrust.sanitized("x\u{2066}y\u{2069}z\u{200F}\u{061C}\u{2028}") == "x▯y▯z▯▯▯")
        #expect(ServerTrust.sanitized("a\u{3164}b\u{115F}c\u{FE0F}d\u{E0041}e") == "a▯b▯c▯d▯e", "the Hangul fillers, variation selectors and tag characters")
        #expect(ServerTrust.sanitized("a\u{E000}b\u{0378}c") == "a▯b▯c", "private-use and unassigned code points")
        #expect(ServerTrust.sanitized("한국 ✓ é") == "한국 ✓ é", "ordinary text is kept")
        let long = String(repeating: "a", count: 300)
        #expect(ServerTrust.sanitized(long) == String(repeating: "a", count: 200) + "…")
        #expect(ServerTrust.sanitized(long, limit: 500) == long)
        // One character can be many scalars: a base letter under a long run of combining marks is capped by scalars as well.
        let stacked = "e" + String(repeating: "\u{0301}", count: 400)
        #expect(ServerTrust.sanitized(stacked, limit: 50).unicodeScalars.count <= 51, "a character made of 401 scalars does not get past the scalar cap")
    }

    @Test func anInternationalizedHostIsAlsoShownInUnicode() {
        #expect(ServerTrust.unicodeHost("xn--bcher-kva.example") == "bücher.example")
        #expect(ServerTrust.unicodeHost("xn--3e0b707e") == "한국")
        #expect(ServerTrust.unicodeHost("www.xn--vermgensberatung-pwb.example") == "www.vermögensberatung.example")
        #expect(ServerTrust.unicodeHost("example.com") == "example.com")
        #expect(ServerTrust.unicodeHost("xn--!!.example") == "xn--!!.example", "a label that does not decode is left as it is")
    }

    @Test func theWarningNamesTheHostAndPortTheUnicodeFormAndTheFullAddress() {
        let certificate = CertificateDetails(subject: "s", issuer: "i", notBefore: Date(), notAfter: Date(), fingerprint: "ab", names: [], isSelfSigned: true)
        let address = URL(string: "https://xn--bcher-kva.example:8443/a/b?x=1#y")!
        let failure = TrustFailure(url: address, host: "xn--bcher-kva.example", port: 8443, code: -1202, reason: .selfSigned, certificate: certificate, changed: false)
        #expect(failure.hostAndPort == "xn--bcher-kva.example:8443")
        #expect(failure.unicodeHost == "bücher.example")
        #expect(failure.address == "https://xn--bcher-kva.example:8443/a/b?x=1#y")
        let plain = TrustFailure(url: URL(string: "https://www.example.com/")!, host: "www.example.com", port: 443, code: -1202, reason: .selfSigned, certificate: certificate, changed: false)
        #expect(plain.hostAndPort == "www.example.com:443", "not trimmed of its www, and the port is said though it is the usual one")
        #expect(plain.unicodeHost == nil)
        let v6 = TrustFailure(url: URL(string: "https://[::1]:9/")!, host: "::1", port: 9, code: -1202, reason: .selfSigned, certificate: certificate, changed: false)
        #expect(v6.hostAndPort == "[::1]:9")
    }
}

/// What is kept for a site (saved logins, remembered permissions, the AI's approvals) is not used on a page whose certificate the user went on with.
@MainActor
struct UnverifiedPageTests {
    private let owner = NSObject()

    private func accept(_ host: String, port: Int = 443) { ServerTrustStore.acceptedAnywhere.add(host: host, port: port, owner: ObjectIdentifier(owner)) }
    private func forget() { ServerTrustStore.acceptedAnywhere.removeAll(ownedBy: ObjectIdentifier(owner)) }

    @Test func aPageOnAHostTheUserWentOnWithIsUnverifiedForCredentials() {
        let host = "unverified-\(UUID().uuidString.prefix(8).lowercased()).test"
        defer { forget() }
        #expect(!Tab.isUnverified(URL(string: "https://\(host)/login")))
        accept(host)
        #expect(Tab.isUnverified(URL(string: "https://\(host)/login")), "no saved login is filled or offered for saving there")
        #expect(Tab.isUnverified(URL(string: "https://\(host.uppercased())/other?x=1")))
        #expect(!Tab.isUnverified(URL(string: "https://\(host):8443/")), "another port is another site")
        #expect(!Tab.isUnverified(URL(string: "https://www.\(host)/")), "another host")
        #expect(!Tab.isUnverified(nil) && !Tab.isUnverified(URL(string: "about:blank")))
    }

    @Test func theSignInToolRefusesAnUnverifiedHost() {
        let host = "signin-\(UUID().uuidString.prefix(8).lowercased()).test"
        defer { forget() }
        #expect(!SignIn.isUnverified(host: host))
        accept(host)
        #expect(SignIn.isUnverified(host: host))
        #expect(!SignIn.isUnverified(host: "other-\(host)"))
    }

    @Test func aRememberedAllowanceIsNotAppliedToAnUnverifiedPageButARefusalStands() {
        typealias Decision = SitePermissions.Decision
        #expect(SitePermissions.effective(.allow, unverified: false) == .allow)
        #expect(SitePermissions.effective(.allow, unverified: true) == .ask, "asked again each time")
        #expect(SitePermissions.effective(.deny, unverified: true) == .deny)
        #expect(SitePermissions.effective(.ask, unverified: true) == .ask)
    }

    @Test func aWindowThatClosedTakesItsHostsAwayFromWhatIsUnverified() {
        let host = "private-\(UUID().uuidString.prefix(8).lowercased()).test"
        accept(host)
        #expect(Tab.isUnverified(URL(string: "https://\(host)/")))
        forget()
        #expect(!Tab.isUnverified(URL(string: "https://\(host)/")))
    }
}

struct ServerTrustBackTests {
    private func urls(_ list: String...) -> [URL] { list.map { URL(string: $0)! } }

    @Test func goBackSkipsThePagesTheTabMayNotShowAndIsOneStepOtherwise() {
        let history = urls("https://a.test/", "https://unverified.test/", "about:blank")
        #expect(ServerTrust.backTarget(history: history, isStopped: { _ in false }) == 1, "one step when the page before is fine")
        #expect(ServerTrust.backTarget(history: history, isStopped: { $0.host() == "unverified.test" }) == 0, "the page that was on an exception is skipped")
        #expect(ServerTrust.backTarget(history: history, isStopped: { _ in true }) == nil, "nothing before it can be shown")
        #expect(ServerTrust.backTarget(history: urls("about:blank"), isStopped: { _ in false }) == nil, "no page before")
        #expect(ServerTrust.backTarget(history: urls("https://a.test/", "about:blank", "about:blank", "about:blank"), isStopped: { _ in false }) == 0, "the app's own empty pages are gone past")
        #expect(ServerTrust.backTarget(history: urls("about:blank", "about:blank", "about:blank"), isStopped: { _ in false }) == nil, "only empty pages remain: no page to go to")
    }
}

/// Hosts and certificates come from the network: nothing parsed from them may trap, whatever the bytes.
struct ServerTrustParsingSafetyTests {
    /// A tiny deterministic generator, so a failure repeats.
    private struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state ^ (state >> 29)
        }
    }

    @Test func craftedPunycodeThatOverflowsDecodesToNothingInsteadOfTrapping() {
        let crafted = [
            "xn--" + String(repeating: "z", count: 59),
            "xn--" + String(repeating: "9", count: 59),
            "xn--" + String(repeating: "a", count: 59),
            "xn--a-" + String(repeating: "z", count: 50),
            "xn--" + String(repeating: "zzzzzzzzzzzzzzzz", count: 3) + "9",
            "xn--9999999999-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
            "xn--" + String(repeating: "zy", count: 29),
        ]
        for label in crafted {
            let host = label + ".example"
            // Whatever comes back, it came back: a label that does not decode is left as it is.
            let shown = ServerTrust.unicodeHost(host)
            #expect(!shown.isEmpty, "\(label)")
        }
        #expect(ServerTrust.unicodeHost("xn--" + String(repeating: "z", count: 59)) == "xn--" + String(repeating: "z", count: 59), "overflow: the ASCII form stays")
    }

    @Test func aHostOrLabelThatIsTooLongIsNotDecoded() {
        let long = "xn--" + String(repeating: "a", count: 70)   // a label of 74
        #expect(ServerTrust.unicodeHost(long + ".example") == long + ".example")
        let host = (0..<30).map { _ in "xn--bcher-kva" }.joined(separator: ".")   // over 253 characters
        #expect(host.count > 253 && ServerTrust.unicodeHost(host) == host)
        #expect(ServerTrust.unicodeHost("xn--bcher-kva") == "bücher", "an ordinary one still decodes")
        #expect(ServerTrust.unicodeHost("xn--é-kva") == "xn--é-kva", "a basic part that is not ASCII is not a punycode label")
    }

    @Test func thousandsOfRandomPunycodeLabelsNeverTrap() {
        var random = Random(state: 20_261_028)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789-")
        let heavy = Array("zyxw9876-")
        for round in 0..<6000 {
            let length = Int.random(in: 1...59, using: &random)
            let from = round % 3 == 0 ? heavy : alphabet
            let label = "xn--" + String((0..<length).map { _ in from.randomElement(using: &random)! })
            _ = ServerTrust.unicodeHost(label + ".example")
            _ = ServerTrust.unicodeHost(label)
        }
    }

    @Test func randomBytesAndDamagedCertificatesNeverTrapTheDERReaders() throws {
        var random = Random(state: 9_001)
        for _ in 0..<4000 {
            let bytes = Data((0..<Int.random(in: 0...200, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) })
            _ = ClientCertificates.fields(ofCertificate: bytes)
            _ = ClientCertificates.extendedKeyUsages(ofCertificate: bytes)
            _ = ClientCertificates.key(ofName: bytes)
            _ = CertificateDetails.parts(ofCertificate: bytes)
            _ = CertificateDetails.commonName(Array(bytes))
        }
        // A real certificate with bytes changed and cut: the structure is right up to the damage, which is where a reader goes wrong.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("changmun-fuzz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "k.pem", "-out", "c.pem", "-days", "5", "-subj", "/CN=fuzz.test",
                             "-addext", "subjectAltName=DNS:fuzz.test,IP:10.0.0.1", "-addext", "extendedKeyUsage=clientAuth,serverAuth"]
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let pem = try String(contentsOf: folder.appendingPathComponent("c.pem"), encoding: .utf8)
        let der = try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
        #expect(ClientCertificates.extendedKeyUsages(ofCertificate: der)?.contains(ClientCertificates.clientAuthentication) == true, "the undamaged one reads")
        for _ in 0..<6000 {
            var damaged = [UInt8](der)
            for _ in 0..<Int.random(in: 1...6, using: &random) { damaged[Int.random(in: 0..<damaged.count, using: &random)] = UInt8.random(in: 0...255, using: &random) }
            if Bool.random(using: &random) { damaged = Array(damaged.prefix(Int.random(in: 0...damaged.count, using: &random))) }
            let data = Data(damaged)
            _ = ClientCertificates.fields(ofCertificate: data)
            _ = ClientCertificates.extendedKeyUsages(ofCertificate: data)
            _ = CertificateDetails.parts(ofCertificate: data)
            if let certificate = SecCertificateCreateWithData(nil, data as CFData) { _ = CertificateDetails(certificate) }
        }
    }
}

struct ServerTrustFrameTests {
    @Test func aLoadIsStoppedForAHostTheUserWentOnWithUnlessThisTabMayUseItsException() {
        #expect(!ServerTrust.stopsLoad(unverified: false, hasException: false, mayOffer: true), "a host nobody went on with")
        #expect(!ServerTrust.stopsLoad(unverified: true, hasException: true, mayOffer: true), "this store's exception covers it")
        #expect(ServerTrust.stopsLoad(unverified: true, hasException: false, mayOffer: true), "another store, or an exception taken away")
        #expect(ServerTrust.stopsLoad(unverified: true, hasException: true, mayOffer: false), "a page the AI drives")
        #expect(ServerTrust.stopsLoad(unverified: true, hasException: false, mayOffer: false))
        #expect(!ServerTrust.stopsLoad(unverified: true, hasException: false, mayOffer: true, systemTrusts: true), "the Mac trusts it now (a CA was installed): judged as ever")
        #expect(!ServerTrust.stopsLoad(unverified: true, hasException: false, mayOffer: false, systemTrusts: true))
        var asked = 0
        _ = ServerTrust.stopsLoad(unverified: false, hasException: false, mayOffer: true, systemTrusts: { asked += 1; return true }())
        _ = ServerTrust.stopsLoad(unverified: true, hasException: true, mayOffer: true, systemTrusts: { asked += 1; return true }())
        #expect(asked == 0, "the Mac's trust is asked only when it can decide")
    }

    @Test func aFrameThatIsLetThroughOnAnUnverifiedHostMakesThePageUnverified() {
        #expect(ServerTrust.frameMakesPageUnverified(unverified: true, stopped: false))
        #expect(!ServerTrust.frameMakesPageUnverified(unverified: true, stopped: true), "a stopped frame shows nothing")
        #expect(!ServerTrust.frameMakesPageUnverified(unverified: false, stopped: false))
    }
}

struct ServerTrustCertificateRecordTests {
    private func details(_ name: String) -> CertificateDetails {
        CertificateDetails(subject: name, issuer: name, notBefore: Date(), notAfter: Date(), fingerprint: "ab", names: [], isSelfSigned: true)
    }

    @Test func aPrivateWindowsCertificateIsNotShownByAWindowThatIsNotPrivate() {
        var accepted = AcceptedSites()
        let window = NSObject(), other = NSObject()
        accepted.add(host: "a.test", port: 443, owner: ObjectIdentifier(window), certificate: details("private"))
        #expect(accepted.certificate(host: "a.test", port: 443, viewedBy: ObjectIdentifier(window))?.subject == "private")
        #expect(accepted.certificate(host: "a.test", port: 443, viewedBy: nil) == nil, "the other windows never see it")
        #expect(accepted.certificate(host: "a.test", port: 443, viewedBy: ObjectIdentifier(other)) == nil, "nor another private window")
        accepted.add(host: "a.test", port: 443, certificate: details("shared"))
        #expect(accepted.certificate(host: "a.test", port: 443, viewedBy: nil)?.subject == "shared")
        #expect(accepted.certificate(host: "a.test", port: 443, viewedBy: ObjectIdentifier(window))?.subject == "private", "its own comes first")
        #expect(accepted.certificate(host: "a.test", port: 443, viewedBy: ObjectIdentifier(other))?.subject == "shared", "a private window may see what the others went on with")
        accepted.removeAll(ownedBy: ObjectIdentifier(window))
        #expect(accepted.certificate(host: "a.test", port: 443, viewedBy: ObjectIdentifier(window))?.subject == "shared", "what it saw goes with it")
    }

    @Test func theMacsTrustIsAskedOfTheCertificateThatWasGoneOnWith() throws {
        // A certificate nobody vouches for is not trusted; one with no bytes (a test's stand-in) is not either.
        #expect(!ServerTrust.systemTrusts(details("none"), host: "a.test"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("changmun-sys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "k.pem", "-out", "c.pem", "-days", "5", "-subj", "/CN=a.test", "-addext", "subjectAltName=DNS:a.test"]
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let pem = try String(contentsOf: folder.appendingPathComponent("c.pem"), encoding: .utf8)
        let der = try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        let read = try #require(CertificateDetails(certificate))
        #expect(!read.der.isEmpty && !ServerTrust.systemTrusts(read, host: "a.test"), "a self-signed certificate is not trusted by the Mac")
    }
}

@MainActor
struct ExtensionDenialTests {
    @Test func aHostPatternNamesTheHostInEveryScheme() {
        guard #available(macOS 15.4, *) else { return }
        #expect(ExtensionHost.denyPattern(forHost: "Intranet.Example.com") == "*://intranet.example.com/*")
        #expect(ExtensionHost.denyPattern(forHost: "example.com.") == "*://example.com/*")
        #expect(ExtensionHost.denyPattern(forHost: "::1") == "*://[::1]/*")
        #expect(ExtensionHost.denyPattern(forHost: "") == nil)
        #expect(ExtensionHost.denyPattern(forHost: "a*b") == nil && ExtensionHost.denyPattern(forHost: "a/b") == nil)
    }

    @Test func anExtensionWithAccessToEverySiteLosesTheHostTheUserWentOnTo() async throws {
        guard #available(macOS 15.4, *) else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ext-deny-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"""
        {"manifest_version": 3, "name": "Manager", "version": "1.0", "host_permissions": ["<all_urls>"],
         "content_scripts": [{"matches": ["<all_urls>"], "js": ["fill.js"]}]}
        """#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("1".utf8).write(to: folder.appendingPathComponent("fill.js"))
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: ext)
        for pattern in ext.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        let excepted = try #require(URL(string: "https://intranet.test:8443/login")), other = try #require(URL(string: "https://example.com/login"))
        #expect(context.permissionStatus(for: excepted) == .grantedExplicitly || context.permissionStatus(for: excepted) == .grantedImplicitly, "access to every site, before")
        ExtensionHost.deny(host: "intranet.test", in: context)
        #expect(context.permissionStatus(for: excepted) == .deniedExplicitly, "none on the host the user went on to (any port)")
        #expect(context.permissionStatus(for: URL(string: "http://intranet.test/")!) == .deniedExplicitly)
        #expect(context.permissionStatus(for: other) != .deniedExplicitly, "every other site is as it was")
    }
}
