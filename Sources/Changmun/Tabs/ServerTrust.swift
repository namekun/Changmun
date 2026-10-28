import CryptoKit
import Foundation
import LocalAuthentication
import os
import Security

/// A site whose own certificate can't be verified (a private CA the Mac doesn't know, a self-signed one, an expired one, one for another name),
/// as Safari's "Show Details › visit this website" has it: the page says so in the app's own view, and only the user, after authenticating
/// as the Mac's owner, can go on, and then for that certificate only. Everything here is pure or in memory; the exceptions are never written
/// to disk and go when the app does.
enum ServerTrust {
    /// What happened to such a site, in Console (subsystem io.github.namekun.Changmun, category certificate; the same as for client certificates, see
    /// ClientCertificates.log): the error code, the port, the answer, and the first eight digits of a certificate's fingerprint; the host is private and
    /// nothing is written for a private window. Nothing else a certificate holds.
    nonisolated static let log = Logger(subsystem: "io.github.namekun.Changmun", category: "certificate")

    /// The errors of a page whose server's certificate was refused: untrusted, bad date, unknown root, not yet valid.
    nonisolated static let failureCodes: Set<Int> = [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                                                     NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid]

    /// Whether an exception may be offered or applied to a page: not to a page the AI drives (it fails, as it did, with nobody to ask), and not in a
    /// headless Changmun, except the test copy, where a test stands in for the user.
    nonisolated static func mayOffer(agentDriven: Bool, headless: Bool, testCopy: Bool) -> Bool {
        !agentDriven && (!headless || testCopy)
    }

    /// The leaf certificate of a trust, the one the site presented.
    nonisolated static func leaf(of trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }

    nonisolated static func fingerprint(of certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    }

    /// What the user is asked as the Mac's owner (Touch ID or the password) before the exception is made. A test copy's tests answer in its place.
    @MainActor static var confirm: (String) async -> Bool = { reason in
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }
}

/// Why the certificate was refused, in the words the page says.
enum TrustReason: Equatable {
    case selfSigned, unknownAuthority, expired(Date), notYetValid(Date), nameMismatch, other

    /// Decided from the certificate itself, so it does not depend on which of the system's codes came: its dates first, then whether it is for
    /// this host, then whether it vouches for itself.
    static func determine(code: Int, certificate: CertificateDetails, host: String, now: Date) -> TrustReason {
        if now > certificate.notAfter { return .expired(certificate.notAfter) }
        if now < certificate.notBefore { return .notYetValid(certificate.notBefore) }
        if !certificate.covers(host: host) { return .nameMismatch }
        if certificate.isSelfSigned { return .selfSigned }
        return code == NSURLErrorServerCertificateUntrusted || code == NSURLErrorServerCertificateHasUnknownRoot ? .unknownAuthority : .other
    }
}

/// What the page shows of the certificate: enough to tell one from another.
struct CertificateDetails: Equatable {
    var subject: String
    var issuer: String
    var notBefore: Date
    var notAfter: Date
    /// SHA-256 of the whole certificate, 64 hex digits.
    var fingerprint: String
    /// The DNS names and addresses it says it is for.
    var names: [String]
    var isSelfSigned: Bool

    /// The fingerprint as pairs of digits ("AB:CD:…"), for reading.
    var spacedFingerprint: String {
        stride(from: 0, to: fingerprint.count, by: 2).map { i in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: i)
            return fingerprint[start..<fingerprint.index(start, offsetBy: 2)].uppercased()
        }.joined(separator: ":")
    }

    init(subject: String, issuer: String, notBefore: Date, notAfter: Date, fingerprint: String, names: [String], isSelfSigned: Bool) {
        (self.subject, self.issuer, self.notBefore, self.notAfter, self.fingerprint, self.names, self.isSelfSigned) =
            (subject, issuer, notBefore, notAfter, fingerprint, names, isSelfSigned)
    }

    init?(_ certificate: SecCertificate) {
        let der = SecCertificateCopyData(certificate) as Data
        guard let parts = Self.parts(ofCertificate: der), let dates = ClientCertificates.fields(ofCertificate: der) else { return nil }
        self.init(subject: Self.commonName(parts.subject) ?? (SecCertificateCopySubjectSummary(certificate) as String?) ?? "",
                  issuer: Self.commonName(parts.issuer) ?? "", notBefore: dates.notBefore, notAfter: dates.notAfter,
                  fingerprint: ServerTrust.fingerprint(of: certificate), names: parts.names, isSelfSigned: parts.subject == parts.issuer)
    }

    /// Whether the certificate is for the host: a DNS name it lists (a `*.` in front stands for one label) or, for an address, that address.
    /// A certificate that lists none is for no one, as the system's own rule has it (the common name is not looked at).
    func covers(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return names.contains { name in
            let name = name.lowercased()
            if name == host { return true }
            guard name.hasPrefix("*."), let dot = host.firstIndex(of: "."), !Self.isAddress(host) else { return false }
            return host[host.index(after: dot)...] == name.dropFirst(2)
        }
    }

    private static func isAddress(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    /// The subject and issuer (as their DER bytes) and the names of a certificate.
    static func parts(ofCertificate der: Data) -> (subject: [UInt8], issuer: [UInt8], names: [String])? {
        typealias E = ClientCertificates
        guard let top = E.elements(Array(der)), top.count == 1, let certificate = E.elements(top[0].content), let tbs = certificate.first,
              let parts = E.elements(tbs.content) else { return nil }
        let start = parts.first?.tag == 0xA0 ? 1 : 0
        guard parts.count > start + 5 else { return nil }
        var names: [String] = []
        if let extensions = parts.last(where: { $0.tag == 0xA3 }), let list = E.elements(extensions.content)?.first, let all = E.elements(list.content) {
            for one in all {
                // OID 2.5.29.17 (subjectAltName), an optional BOOLEAN, then an OCTET STRING holding the GeneralNames.
                guard let fields = E.elements(one.content), fields.first?.tag == 0x06, fields[0].content == [0x55, 0x1D, 0x11],
                      let value = fields.last(where: { $0.tag == 0x04 }), let general = E.elements(value.content), general.count == 1,
                      let entries = E.elements(general[0].content) else { continue }
                for entry in entries {
                    if entry.tag == 0x82, let name = String(bytes: entry.content, encoding: .ascii) { names.append(name) }
                    if entry.tag == 0x87, let address = address(entry.content) { names.append(address) }
                }
            }
        }
        return (parts[start + 4].whole, parts[start + 2].whole, names)
    }

    private static func address(_ bytes: [UInt8]) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch bytes.count {
        case 4: return bytes.withUnsafeBytes { inet_ntop(AF_INET, $0.baseAddress, &buffer, socklen_t(buffer.count)) }.map { String(cString: $0) }
        case 16: return bytes.withUnsafeBytes { inet_ntop(AF_INET6, $0.baseAddress, &buffer, socklen_t(buffer.count)) }.map { String(cString: $0) }
        default: return nil
        }
    }

    /// The common name of a distinguished name in DER (else the organization), as text.
    static func commonName(_ name: [UInt8]) -> String? {
        guard let top = ClientCertificates.elements(name), top.count == 1, let sets = ClientCertificates.elements(top[0].content) else { return nil }
        var found: [String: String] = [:]
        for set in sets {
            for attribute in ClientCertificates.elements(set.content) ?? [] {
                guard let pair = ClientCertificates.elements(attribute.content), pair.count == 2, pair[0].tag == 0x06 else { continue }
                let encoding: String.Encoding = pair[1].tag == 0x1E ? .utf16BigEndian : pair[1].tag == 0x14 ? .isoLatin1 : .utf8
                if let text = String(bytes: pair[1].content, encoding: encoding) { found[ClientCertificates.hex(pair[0].content)] = text }
            }
        }
        return found["550403"] ?? found["55040a"]
    }
}

/// A page that could not be shown because of its certificate, as the view over the tab says it.
struct TrustFailure: Equatable {
    let url: URL
    let host: String
    let port: Int
    let code: Int
    let reason: TrustReason
    let certificate: CertificateDetails
    /// An exception was made for this site before, and this is another certificate: the page is more alarming then.
    let changed: Bool

    /// The address a warning is for when the certificate is refused in a challenge (which has no address of its own): the main frame load that is
    /// still pending, if the challenge is for its host and port. With no such load (a subresource, a later load, one that has committed or failed) there is
    /// nothing to warn about and the challenge is cancelled with no view.
    static func pendingTarget(navigatingTo: URL?, host: String, port: Int) -> URL? {
        guard let target = navigatingTo, target.scheme?.lowercased() == "https", target.host()?.lowercased() == host.lowercased(), (target.port ?? 443) == port else { return nil }
        return target
    }

    /// From a failed load: nil if its error is not one of the certificate's, or has no certificate in it.
    static func from(error: NSError, url: URL?, changed: (_ host: String, _ port: Int, _ fingerprint: String) -> Bool, now: Date = Date()) -> TrustFailure? {
        guard ServerTrust.failureCodes.contains(error.code), error.domain == NSURLErrorDomain,
              let url = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url,
              let raw = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey], CFGetTypeID(raw as CFTypeRef) == SecTrustGetTypeID() else { return nil }
        return from(trust: raw as! SecTrust, url: url, code: error.code, changed: changed, now: now)
    }

    /// From the trust a server's certificate was judged by, for a load of `url`.
    static func from(trust: SecTrust, url: URL, code: Int, changed: (_ host: String, _ port: Int, _ fingerprint: String) -> Bool, now: Date = Date()) -> TrustFailure? {
        guard url.scheme?.lowercased() == "https", let host = url.host(), let leaf = ServerTrust.leaf(of: trust), let certificate = CertificateDetails(leaf) else { return nil }
        let port = url.port ?? 443
        return TrustFailure(url: url, host: host, port: port, code: code, reason: TrustReason.determine(code: code, certificate: certificate, host: host, now: now),
                            certificate: certificate, changed: changed(host, port, certificate.fingerprint))
    }
}

/// The certificates the user chose to go on with, by site: host, port, and the data store the tab is in (nil for the one the spaces that are not
/// profiles share, so a profile's choice is not another profile's). Only one certificate per site, the last one chosen: a site that shows another
/// is blocked again.
struct ServerTrustExceptions {
    struct Site: Hashable {
        let host: String
        let port: Int
        let store: UUID?
        init(host: String, port: Int, store: UUID?) {
            self.host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            self.port = port
            self.store = store
        }
    }

    private var accepted: [Site: String] = [:]

    mutating func grant(host: String, port: Int, fingerprint: String, store: UUID?) { accepted[Site(host: host, port: port, store: store)] = fingerprint }
    mutating func revoke(host: String, port: Int, store: UUID?) { accepted[Site(host: host, port: port, store: store)] = nil }
    mutating func removeAll() { accepted = [:] }

    /// The site's certificate is the one the user went on with.
    func allows(host: String, port: Int, fingerprint: String, store: UUID?) -> Bool {
        accepted[Site(host: host, port: port, store: store)] == fingerprint
    }

    func hasException(host: String, port: Int, store: UUID?) -> Bool { accepted[Site(host: host, port: port, store: store)] != nil }

    /// The site had an exception and shows another certificate now.
    func isChanged(host: String, port: Int, fingerprint: String, store: UUID?) -> Bool {
        accepted[Site(host: host, port: port, store: store)].map { $0 != fingerprint } ?? false
    }
}

/// The hosts and ports the user went on with in this run, in any store or window. WebKit keeps a certificate it was told to go on with in the
/// network session for as long as the app runs, whoever asks, whichever store or private window it asks from, and whatever the app has forgotten since;
/// so these are not the exceptions (which are per store and can be taken away) but a record of where WebKit may let a page through on its own.
struct AcceptedSites {
    private var sites: Set<String> = []

    private static func key(_ host: String, _ port: Int) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) + ":\(port)"
    }

    mutating func add(host: String, port: Int) { sites.insert(Self.key(host, port)) }
    func contains(host: String, port: Int) -> Bool { sites.contains(Self.key(host, port)) }
}

/// What to do with a server's certificate that WebKit asks the tab about.
enum ServerTrustChallengeDecision: Equatable {
    /// Judged as ever: the user never went on with this host and port, or the Mac's own trust passes it on its own.
    case defaultHandling
    /// This store's exception covers this very certificate, for a page that may use it.
    case useException
    /// The user went on with this host and port somewhere, but this load is not covered and the Mac does not trust the certificate (or there is nothing
    /// to judge it by): the load is cancelled.
    case cancel

    /// For a host and port the user went on with anywhere in this run, everything that is missing counts against the load: it goes through only on this
    /// store's exception for this certificate, or when the Mac trusts the certificate by itself. `systemTrusts` is looked at only when it is needed.
    static func decide(accepted: Bool, hasTrust: Bool, hasStore: Bool, hasLeaf: Bool, systemTrusts: @autoclosure () -> Bool,
                       exceptionMatches: Bool, mayOffer: Bool) -> Self {
        guard accepted else { return .defaultHandling }
        if hasTrust, hasStore, hasLeaf, exceptionMatches, mayOffer { return .useException }
        return hasTrust && systemTrusts() ? .defaultHandling : .cancel
    }
}

/// The exceptions, held in memory by the app (the windows that are not private share one) or by a private window.
@MainActor
final class ServerTrustStore {
    static let shared = ServerTrustStore()
    var exceptions = ServerTrustExceptions()
    /// Where the user went on in this run, whichever store or window (see AcceptedSites).
    static var acceptedAnywhere = AcceptedSites()
}
