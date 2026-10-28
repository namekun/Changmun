import Foundation
import Security
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

    @Test func takingAnExceptionAwayStopsItFromApplyingButIsRemembered() {
        var exceptions = ServerTrustExceptions()
        exceptions.grant(host: "a.test", port: 443, fingerprint: "aa", store: nil)
        exceptions.revoke(host: "a.test", port: 443, store: nil)
        #expect(!exceptions.hasException(host: "a.test", port: 443, store: nil))
        #expect(!exceptions.allows(host: "a.test", port: 443, fingerprint: "aa", store: nil))
        // WebKit keeps the certificate it was let through with, so the site is still judged by the Mac's trust afterwards.
        #expect(exceptions.hadException(host: "a.test", port: 443, store: nil))
        exceptions.grant(host: "b.test", port: 443, fingerprint: "aa", store: nil)
        exceptions.removeAll()
        #expect(!exceptions.hasException(host: "b.test", port: 443, store: nil) && exceptions.hadException(host: "b.test", port: 443, store: nil))
        #expect(!exceptions.hadException(host: "never.test", port: 443, store: nil))
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
        #expect(TrustFailure.from(error: error(NSURLErrorTimedOut), url: nil, changed: { _, _, _ in false }) == nil, "another kind of failure")
        #expect(TrustFailure.from(error: error(NSURLErrorServerCertificateUntrusted, domain: "WebKitErrorDomain"), url: nil, changed: { _, _, _ in false }) == nil)
        #expect(TrustFailure.from(error: error(NSURLErrorServerCertificateUntrusted, trust: nil), url: nil, changed: { _, _, _ in false }) == nil, "no certificate to show")
        let http = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted,
                           userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "http://intranet.test/")!, NSURLErrorFailingURLPeerTrustErrorKey: trust as Any])
        #expect(TrustFailure.from(error: http, url: nil, changed: { _, _, _ in false }) == nil, "only https")
    }
}
