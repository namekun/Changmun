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

/// When the user may not go on: sites that insist on https, which Safari and Chrome never let a page override either.
enum ServerTrustPolicy {
    /// The top-level domains whose every name is on the HSTS preload list as a whole (the registry made them https-only), so a browser has no
    /// override for any host below them. Only the whole-TLD preloads of the Google registry that are certain; everything else is learned
    /// from a Strict-Transport-Security header, which WebKit does not show the app (see `visit`).
    nonisolated static let preloadedTopLevelDomains: Set<String> = [
        "dev", "app", "page", "new", "day", "foo", "gle", "zip", "mov", "nexus", "ing", "meme", "phd", "prof", "esq", "channel", "boo", "dad", "soy",
        "how", "rsvp",
    ]

    nonisolated static func isPreloadedStrictTransport(host: String) -> Bool {
        let labels = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".")
        guard labels.count >= 1, let last = labels.last else { return false }
        return preloadedTopLevelDomains.contains(String(last))
    }

    enum Visit: Equatable {
        /// The user may choose to go on.
        case offered
        /// The site is https-only by the preload list: no way on.
        case refusedStrictTransport
        /// The same host and port loaded over a trusted connection earlier in this run and fails now: a certificate that was fine and is not is the case of
        /// someone in the middle, so there is no way on either.
        case refusedWentBad
    }

    /// Whether "Visit This Website" is offered. `wasTrusted`: this host and port loaded over a connection the Mac trusted earlier in this run.
    nonisolated static func visit(host: String, wasTrusted: Bool) -> Visit {
        if isPreloadedStrictTransport(host: host) { return .refusedStrictTransport }
        return wasTrusted ? .refusedWentBad : .offered
    }
}

/// The hosts and ports that loaded over a connection the Mac trusted, per store: a later failure for one of them is not a site that never had a good
/// certificate.
struct TrustedSites {
    private var sites: Set<ServerTrustExceptions.Site> = []
    mutating func add(host: String, port: Int, store: UUID?) { sites.insert(.init(host: host, port: port, store: store)) }
    func contains(host: String, port: Int, store: UUID?) -> Bool { sites.contains(.init(host: host, port: port, store: store)) }
}

extension ServerTrust {
    /// Whether a load (of the main frame or of a frame in the page) is stopped by the app: the host and port are ones the user went on with in this run
    /// (`unverified`) and this tab may not use an exception for them (`hasException` false in this store, or the AI drives the page). WebKit may carry such a
    /// load over a connection kept alive from before, with no certificate question to cancel, so the app decides before the load starts.
    /// The Mac's own trust is not a way through here: what is known of the certificate gone on with says nothing of the one the connection in use presents
    /// now (someone in the middle may be on it). A new connection is judged by the certificate question, which lets a certificate the Mac trusts through.
    nonisolated static func stopsLoad(unverified: Bool, hasException: Bool, mayOffer: Bool) -> Bool {
        unverified && !(mayOffer && hasException)
    }

    /// A frame of the page that was let through on a host the user went on with makes the page unverified for what the app keeps for a site.
    nonisolated static func frameMakesPageUnverified(unverified: Bool, stopped: Bool) -> Bool { unverified && !stopped }

    /// Where "Go Back" goes from the warning: the nearest page before it that is not itself one the tab may not show now (a page restored from the
    /// back/forward list is not asked about again, so it would simply be shown). `history` is oldest first, the page the warning is over last.
    /// An index into `history`, or nil when there is no page before that could be shown.
    nonisolated static func backTarget(history: [URL], isStopped: (URL) -> Bool) -> Int? {
        // An empty page of the app's own (what a warning replaced a page with) is no page to go back to.
        history.indices.dropLast().reversed().first { history[$0].scheme?.lowercased() != "about" && !isStopped(history[$0]) }
    }

    /// Text from a certificate or an address as it is shown to the user, by the rules the AI's questions use (Approvals.isHidden): every character that is
    /// invisible or lets text pass for other text (controls and line breaks, format and default-ignorable characters, bidi controls, variation selectors, tag
    /// characters, the Hangul fillers), and private-use and unassigned code points, is shown as a box, not left out, so a changed text looks changed. No more
    /// than `limit` characters (graphemes) and no more than `limit` unicode scalars (one character can be many): what does not fit is cut, and said so with "…".
    nonisolated static func sanitized(_ text: String, limit: Int = 200) -> String {
        var out = String.UnicodeScalarView()
        var characters = 0, scalars = 0
        for character in text {
            let pieces = character.unicodeScalars
            guard characters < limit, scalars + pieces.count <= limit else { out.append("…"); break }
            for scalar in pieces {
                let category = scalar.properties.generalCategory
                out.append(Approvals.isHidden(scalar) || category == .privateUse || category == .unassigned || category == .surrogate ? "▯" : scalar)
            }
            characters += 1
            scalars += pieces.count
        }
        return String(out)
    }

    /// A host written in Unicode: the labels of an internationalized name are punycode ("xn--…") in an address. The host as it is when it is too long to be a
    /// host (253 characters; a label over 63) and for each label that does not decode: only its ASCII form is then shown.
    nonisolated static func unicodeHost(_ host: String) -> String {
        guard host.utf8.count <= 253 else { return host }
        return host.split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
            let text = String(label)
            guard text.utf8.count <= 63, text.lowercased().hasPrefix("xn--"), let decoded = decodePunycode(String(text.dropFirst(4))) else { return text }
            return decoded
        }.joined(separator: ".")
    }

    /// RFC 3492, with every sum and product checked against the 32-bit bound the RFC's own code uses (§6.4): a value that would pass it means the input is
    /// not punycode that stands for a name, and the result is nil. Nothing here can trap.
    nonisolated private static func decodePunycode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        let maxInt = Int(UInt32.max)
        var n = 128, i = 0, bias = 72
        var output: [UInt32] = []
        var rest = Substring(input)
        if let dash = input.lastIndex(of: "-") {
            // The part before the last dash is the basic code points: ASCII, or it is not punycode.
            let basic = input[..<dash].unicodeScalars
            guard basic.allSatisfy({ $0.value < 128 }) else { return nil }
            output = basic.map(\.value)
            rest = input[input.index(after: dash)...]
        }
        func digit(_ c: Character) -> Int? {
            guard let a = c.asciiValue else { return nil }
            switch a {
            case 48...57: return Int(a) - 22
            case 65...90: return Int(a) - 65
            case 97...122: return Int(a) - 97
            default: return nil
            }
        }
        func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
            var delta = first ? delta / damp : delta / 2
            delta += delta / count
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 { delta /= base - tMin; k += base }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }
        var index = rest.startIndex
        while index < rest.endIndex {
            let oldI = i
            var w = 1, k = base
            while true {
                guard index < rest.endIndex, let d = digit(rest[index]) else { return nil }
                index = rest.index(after: index)
                // i += d * w, as the RFC checks it: d * w must not pass what is left below the bound.
                guard d <= (maxInt - i) / w else { return nil }
                i += d * w
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if d < t { break }
                guard w <= maxInt / (base - t) else { return nil }
                w *= base - t
                k += base
            }
            let count = output.count + 1
            bias = adapt(i - oldI, count, oldI == 0)
            guard i / count <= maxInt - n else { return nil }
            n += i / count
            i %= count
            // A code point past Unicode, and the halves of surrogate pairs, are not names; so is a name longer than a label can hold.
            guard n <= 0x10FFFF, Unicode.Scalar(UInt32(n)) != nil, output.count < 63 else { return nil }
            output.insert(UInt32(n), at: i)
            i += 1
        }
        var scalars = String.UnicodeScalarView()
        for value in output { guard let scalar = Unicode.Scalar(value) else { return nil }; scalars.append(scalar) }
        return String(scalars)
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
        let digits = Array(fingerprint.uppercased())
        return stride(from: 0, to: digits.count, by: 2).map { String(digits[$0..<min($0 + 2, digits.count)]) }.joined(separator: ":")
    }

    init(subject: String, issuer: String, notBefore: Date, notAfter: Date, fingerprint: String, names: [String], isSelfSigned: Bool) {
        (self.subject, self.issuer, self.notBefore, self.notAfter, self.fingerprint, self.names, self.isSelfSigned) =
            (subject, issuer, notBefore, notAfter, fingerprint, names, isSelfSigned)
    }

    init?(_ certificate: SecCertificate) {
        let der = SecCertificateCopyData(certificate) as Data
        guard let parts = Self.parts(ofCertificate: der), let dates = ClientCertificates.fields(ofCertificate: der) else { return nil }
        self.init(subject: ServerTrust.sanitized(Self.commonName(parts.subject) ?? (SecCertificateCopySubjectSummary(certificate) as String?) ?? ""),
                  issuer: ServerTrust.sanitized(Self.commonName(parts.issuer) ?? ""), notBefore: dates.notBefore, notAfter: dates.notAfter,
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
    /// Whether the user may go on (see ServerTrustPolicy).
    var visit: ServerTrustPolicy.Visit = .offered

    /// The host with its port, as the page says where it is: `localhost:8443`, `[::1]:443`.
    var hostAndPort: String { ServerTrust.sanitized(host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)") }
    /// The host in Unicode when it is an internationalized name (the address has it as punycode), else nil.
    var unicodeHost: String? {
        let shown = ServerTrust.sanitized(ServerTrust.unicodeHost(host))
        return shown == ServerTrust.sanitized(host) ? nil : shown
    }
    /// The whole address as it was asked for, in full.
    var address: String { ServerTrust.sanitized(url.absoluteString, limit: 500) }

    /// The address a warning is for when the certificate is refused in a challenge (which has no address of its own): the main frame load that is
    /// still pending, if the challenge is for its host and port. With no such load (a subresource, a later load, one that has committed or failed) there is
    /// nothing to warn about and the challenge is cancelled with no view.
    static func pendingTarget(navigatingTo: URL?, host: String, port: Int) -> URL? {
        guard let target = navigatingTo, target.scheme?.lowercased() == "https", target.host()?.lowercased() == host.lowercased(), (target.port ?? 443) == port else { return nil }
        return target
    }

    /// From a failed load: nil if its error is not one of the certificate's, or has no certificate in it.
    static func from(error: NSError, url: URL?, changed: (_ host: String, _ port: Int, _ fingerprint: String) -> Bool,
                     wasTrusted: (_ host: String, _ port: Int) -> Bool = { _, _ in false }, now: Date = Date()) -> TrustFailure? {
        guard ServerTrust.failureCodes.contains(error.code), error.domain == NSURLErrorDomain,
              let url = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url,
              let raw = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey], CFGetTypeID(raw as CFTypeRef) == SecTrustGetTypeID() else { return nil }
        return from(trust: raw as! SecTrust, url: url, code: error.code, changed: changed, wasTrusted: wasTrusted, now: now)
    }

    /// From the trust a server's certificate was judged by, for a load of `url`.
    static func from(trust: SecTrust, url: URL, code: Int, changed: (_ host: String, _ port: Int, _ fingerprint: String) -> Bool,
                     wasTrusted: (_ host: String, _ port: Int) -> Bool = { _, _ in false }, now: Date = Date()) -> TrustFailure? {
        guard url.scheme?.lowercased() == "https", let host = url.host(), let leaf = ServerTrust.leaf(of: trust), let certificate = CertificateDetails(leaf) else { return nil }
        let port = url.port ?? 443
        return TrustFailure(url: url, host: host, port: port, code: code, reason: TrustReason.determine(code: code, certificate: certificate, host: host, now: now),
                            certificate: certificate, changed: changed(host, port, certificate.fingerprint),
                            visit: ServerTrustPolicy.visit(host: host, wasTrusted: wasTrusted(host, port)))
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
    /// What the certificate that was accepted looked like, so that the warning can be shown again when the exception is taken away.
    private var details: [Site: CertificateDetails] = [:]

    mutating func grant(host: String, port: Int, fingerprint: String, store: UUID?, details certificate: CertificateDetails? = nil) {
        accepted[Site(host: host, port: port, store: store)] = fingerprint
        details[Site(host: host, port: port, store: store)] = certificate
    }
    /// Takes the exception away; the certificate it was for, if it was kept.
    @discardableResult
    mutating func revoke(host: String, port: Int, store: UUID?) -> CertificateDetails? {
        let site = Site(host: host, port: port, store: store)
        accepted[site] = nil
        return details.removeValue(forKey: site)
    }
    mutating func removeAll() { accepted = [:]; details = [:] }

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
    /// By host and port: accepted in a window that is not private, which lasts the run.
    private var permanent: Set<String> = []
    /// The certificate last gone on with, by host and port and by who accepted it (a private window, or nil for the windows that are not): a window that
    /// is not private never shows what a private one saw.
    private var certificates: [String: [ObjectIdentifier?: CertificateDetails]] = [:]
    /// Accepted in private windows, by the windows: they go when the window does.
    private var owners: [String: Set<ObjectIdentifier>] = [:]

    private static func key(_ host: String, _ port: Int) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) + ":\(port)"
    }

    /// `owner` is a private window's, whose entry goes when it closes.
    mutating func add(host: String, port: Int, owner: ObjectIdentifier? = nil, certificate: CertificateDetails? = nil) {
        let key = Self.key(host, port)
        if let certificate { certificates[key, default: [:]][owner] = certificate }
        if let owner { owners[key, default: []].insert(owner) } else { permanent.insert(key) }
    }

    /// A private window closed: what only it accepted goes (its session, and WebKit's memory of the certificate, go with it).
    mutating func removeAll(ownedBy owner: ObjectIdentifier) {
        for key in Array(owners.keys) {
            owners[key]?.remove(owner)
            if owners[key]?.isEmpty == true { owners[key] = nil }
        }
        for key in Array(certificates.keys) {
            certificates[key]?[owner] = nil
            if certificates[key]?.isEmpty == true { certificates[key] = nil }
        }
    }

    func contains(host: String, port: Int) -> Bool {
        let key = Self.key(host, port)
        return permanent.contains(key) || owners[key] != nil
    }

    /// The certificate last gone on with that a window may see: its own (`owner`, nil for a window that is not private), and for a private window also
    /// the one a window that is not private went on with.
    func certificate(host: String, port: Int, viewedBy owner: ObjectIdentifier? = nil) -> CertificateDetails? {
        let byWho = certificates[Self.key(host, port)]
        return byWho?[owner] ?? (owner != nil ? byWho?[nil] : nil)
    }
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
    /// The hosts and ports whose certificate the Mac itself trusted in this run (seen in a certificate question, see Tab.answerServerTrust), for the whole
    /// app: a certificate that was fine and is not now is the case of someone in the middle.
    static var trustedAnywhere = TrustedSites()
    /// Whether the page at this host and port is one whose certificate the user went on with, in any store or window of this run: nothing the user
    /// keeps for a site (saved logins, remembered permissions) is used on it.
    static func isUnverified(host: String, port: Int) -> Bool { acceptedAnywhere.contains(host: host, port: port) }
}
