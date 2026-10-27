import CryptoKit
import Foundation
import Security

/// Sites that ask for a certificate to identify the user (TLS client authentication, as Safari does it): which of the Mac's
/// identities the site accepts, which one is used, and when the user is asked. The choosing is pure, with the keychain and the
/// panel handed in, so the rules can be tested without either.
enum ClientCertificates {
    /// An identity (a certificate with its private key) as the rules see it.
    struct Candidate: Equatable {
        /// The certificate's SHA-256, which tells two copies of one identity (a keychain and a smart card) apart from two identities.
        let id: String
        let name: String
        /// The issuer of the certificate, then that of each certificate above it, as `key(ofName:)` writes them.
        let issuers: Set<String>
        let notBefore: Date
        let notAfter: Date
        /// Nil only where a test stands in for the keychain.
        let identity: SecIdentity?

        static func == (a: Candidate, b: Candidate) -> Bool { a.id == b.id }
    }

    /// What the choosing depends on besides the identities.
    struct Situation: Equatable {
        /// A headless Changmun shows nothing and leaves the keychain alone.
        var isHeadless = false
        /// The page was opened or is driven by the AI (or an agent over MCP): it may use what the system's own preference says,
        /// but nothing else is chosen for the user, and a choice they made for another page is not reused.
        var agentDriven = false
    }

    enum Plan: Equatable {
        /// The system's preference, or the user's earlier choice in this window, names one.
        case use(Candidate)
        /// The user picks, in this order.
        case ask([Candidate])
        /// The site gets no certificate and shows what it shows then.
        case continueWithout
    }

    // MARK: Choosing

    /// What the site accepts and has not run out: issued by (or below) one of the CAs it named, if it named any, and valid now.
    /// Each identity once, by name and then the newer first.
    static func usable(_ candidates: [Candidate], acceptedIssuers: [Data], now: Date) -> [Candidate] {
        let accepted = Set(acceptedIssuers.map(key(ofName:)))
        var seen = Set<String>()
        return candidates.filter {
            $0.notBefore <= now && now <= $0.notAfter && (accepted.isEmpty || !$0.issuers.isDisjoint(with: accepted)) && seen.insert($0.id).inserted
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.notBefore != $1.notBefore ? $0.notBefore > $1.notBefore : $0.id < $1.id
        }
    }

    /// The system's preference for the site comes first (it is what the user, or Safari, said), then the user's earlier choice in
    /// this window; each only while it is something the site accepts and valid. Otherwise the user is asked, also when there is only
    /// one identity (nothing is chosen for them), and when there are none the site is simply visited without.
    static func plan(candidates: [Candidate], preferred: Candidate?, remembered: Candidate?, acceptedIssuers: [Data], now: Date, situation: Situation) -> Plan {
        if situation.isHeadless { return .continueWithout }
        if let preferred, let found = usable([preferred], acceptedIssuers: acceptedIssuers, now: now).first { return .use(found) }
        if !situation.agentDriven, let remembered, let found = usable([remembered], acceptedIssuers: acceptedIssuers, now: now).first { return .use(found) }
        let list = usable(candidates, acceptedIssuers: acceptedIssuers, now: now)
        return list.isEmpty ? .continueWithout : .ask(list)
    }

    /// Where the keychain and the panel come in. A headless Changmun never reaches either.
    struct Environment {
        var situation: Situation
        var now: () -> Date = Date.init
        var identities: () -> [Candidate]
        var preferred: ([String], [Data]) -> Candidate?
        var remembered: Candidate?
        /// Shows the list and answers with the user's choice; nil for Cancel.
        var ask: ([Candidate]) async -> Candidate?
    }

    /// The identity to answer the site with, or nil to go on without one.
    static func resolve(host: String, port: Int, acceptedIssuers: [Data], environment env: Environment) async -> Candidate? {
        guard !env.situation.isHeadless else { return nil }
        let plan = plan(candidates: env.identities(), preferred: env.preferred(preferenceNames(host: host, port: port), acceptedIssuers), remembered: env.remembered,
                        acceptedIssuers: acceptedIssuers, now: env.now(), situation: env.situation)
        switch plan {
        case .use(let candidate): return candidate
        case .continueWithout: return nil
        case .ask(let list): return await env.ask(list)
        }
    }

    /// The names an identity preference for the site may be filed under, the most specific first: the address, and the host alone.
    static func preferenceNames(host: String, port: Int) -> [String] {
        [port == 443 || port == 0 ? "https://\(host)" : "https://\(host):\(port)", host]
    }

    /// The site a request is for, by host, port and the issuers it named.
    static func requestKey(host: String, port: Int, acceptedIssuers: [Data]) -> String {
        "\(host.lowercased()):\(port)|" + acceptedIssuers.map(key(ofName:)).sorted().joined(separator: ";")
    }

    /// What challenges share one panel and one answer: those of the same site that the user drives. The AI's are kept apart, from the
    /// user's and from those of the AI's other tabs, so a page the AI drives never receives the certificate the user picked for their own.
    static func queueKey(site: String, agentDriven: Bool, tab: Int) -> String {
        agentDriven ? "\(site)|ai:\(tab)" : "\(site)|user"
    }

    /// The name the panel files the user's choice under, so that the next visit finds it (it is the first name `preferenceNames` looks
    /// up): nil where the choice is not kept in the keychain, in a private window and for a page the AI drives.
    static func domainToRemember(host: String, port: Int, isPrivate: Bool, agentDriven: Bool) -> String? {
        isPrivate || agentDriven ? nil : preferenceNames(host: host, port: port).first
    }

    // MARK: The keychain

    /// Every identity the Mac holds (the keychains in the search list and the smart cards CryptoTokenKit shows), or those of `searchList`.
    static func keychainIdentities(searchList: CFArray? = nil) -> [Candidate] {
        var query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnRef as String: true]
        if let searchList { query[kSecMatchSearchList as String] = searchList }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let found = result as? [SecIdentity] else { return [] }
        return found.compactMap(candidate(for:))
    }

    /// The identity the system has on file for the site (what Safari's "use this certificate for this site" and Keychain Access
    /// write); only read here. The preference is limited to the issuers the site named.
    static func preferredIdentity(names: [String], acceptedIssuers: [Data]) -> Candidate? {
        for name in names {
            if let identity = SecIdentityCopyPreferred(name as CFString, nil, acceptedIssuers.isEmpty ? nil : acceptedIssuers as CFArray),
               let candidate = candidate(for: identity) { return candidate }
        }
        return nil
    }

    static func candidate(for identity: SecIdentity) -> Candidate? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              let leaf = fields(ofCertificate: SecCertificateCopyData(certificate) as Data) else { return nil }
        var issuers: Set<String> = [key(ofName: leaf.issuer)]
        // The chain, so a certificate issued by an intermediate is offered to a site that named the root. Nothing is fetched for it.
        var trust: SecTrust?
        if SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust {
            SecTrustSetNetworkFetchAllowed(trust, false)
            _ = SecTrustEvaluateWithError(trust, nil)
            for above in (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? [] {
                if let issuer = fields(ofCertificate: SecCertificateCopyData(above) as Data)?.issuer { issuers.insert(key(ofName: issuer)) }
            }
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        return Candidate(id: digest, name: SecCertificateCopySubjectSummary(certificate) as String? ?? "", issuers: issuers,
                         notBefore: leaf.notBefore, notAfter: leaf.notAfter, identity: identity)
    }

    // MARK: Reading certificates (DER)

    /// The issuer name (as the certificate holds it) and the dates a certificate is valid between.
    static func fields(ofCertificate der: Data) -> (issuer: Data, notBefore: Date, notAfter: Date)? {
        guard let top = elements(Array(der)), top.count == 1, top[0].tag == 0x30,
              let certificate = elements(top[0].content), let tbs = certificate.first, tbs.tag == 0x30,
              let parts = elements(tbs.content) else { return nil }
        // [0] version (optional), serial number, signature algorithm, issuer, validity.
        let start = parts.first?.tag == 0xA0 ? 1 : 0
        guard parts.count > start + 3, parts[start + 2].tag == 0x30, parts[start + 3].tag == 0x30,
              let validity = elements(parts[start + 3].content), validity.count == 2,
              let notBefore = date(validity[0]), let notAfter = date(validity[1]) else { return nil }
        return (Data(parts[start + 2].whole), notBefore, notAfter)
    }

    /// A distinguished name in a form that two spellings of one name share (letter case, runs of spaces, and the string type
    /// are left out, as the Mac's own matching does); one that can't be read stands for its bytes.
    static func key(ofName der: Data) -> String {
        guard let top = elements(Array(der)), top.count == 1, top[0].tag == 0x30, let sets = elements(top[0].content) else { return raw(der) }
        var names: [String] = []
        for set in sets {
            guard set.tag == 0x31, let attributes = elements(set.content) else { return raw(der) }
            var parts: [String] = []
            for attribute in attributes {
                guard attribute.tag == 0x30, let pair = elements(attribute.content), pair.count == 2, pair[0].tag == 0x06 else { return raw(der) }
                parts.append(hex(pair[0].content) + "=" + normalized(pair[1]))
            }
            names.append(parts.sorted().joined(separator: "+"))
        }
        return names.joined(separator: ",")
    }

    private struct Element {
        let tag: UInt8
        let content: [UInt8]
        let whole: [UInt8]
    }

    /// The elements one after another in `bytes`; nil when they don't add up (only tags of one byte are known).
    private static func elements(_ bytes: [UInt8]) -> [Element]? {
        var found: [Element] = []
        var at = 0
        while at < bytes.count {
            let start = at
            let tag = bytes[at]
            guard tag & 0x1F != 0x1F, at + 1 < bytes.count else { return nil }
            var length = Int(bytes[at + 1])
            at += 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard (1...4).contains(count), at + count <= bytes.count else { return nil }
                length = bytes[at..<at + count].reduce(0) { $0 << 8 | Int($1) }
                at += count
            }
            guard length >= 0, at + length <= bytes.count else { return nil }
            found.append(Element(tag: tag, content: Array(bytes[at..<at + length]), whole: Array(bytes[start..<at + length])))
            at += length
        }
        return found
    }

    private static func date(_ time: Element) -> Date? {
        guard let text = String(bytes: time.content, encoding: .ascii), text.hasSuffix("Z"), time.tag == 0x17 || time.tag == 0x18 else { return nil }
        let digits = text.dropLast().compactMap(\.wholeNumberValue)
        guard digits.count == text.count - 1 else { return nil }
        let number = { (range: Range<Int>) in digits[range].reduce(0) { $0 * 10 + $1 } }
        var components = DateComponents(timeZone: TimeZone(identifier: "UTC"))
        if time.tag == 0x17 {
            guard digits.count == 12 else { return nil }
            components.year = number(0..<2) >= 50 ? 1900 + number(0..<2) : 2000 + number(0..<2)
            (components.month, components.day, components.hour, components.minute, components.second) = (number(2..<4), number(4..<6), number(6..<8), number(8..<10), number(10..<12))
        } else {
            guard digits.count == 14 else { return nil }
            components.year = number(0..<4)
            (components.month, components.day, components.hour, components.minute, components.second) = (number(4..<6), number(6..<8), number(8..<10), number(10..<12), number(12..<14))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    private static func normalized(_ value: Element) -> String {
        let encoding: String.Encoding?
        switch value.tag {
        case 0x0C, 0x13, 0x16: encoding = .utf8
        case 0x14: encoding = .isoLatin1
        case 0x1E: encoding = .utf16BigEndian
        case 0x1C: encoding = .utf32BigEndian
        default: encoding = nil
        }
        guard let encoding, let text = String(bytes: value.content, encoding: encoding) else { return hex(value.content) }
        return text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    private static func raw(_ der: Data) -> String { "raw:" + hex(Array(der)) }
}

/// What the user chose for a site in one window, which lasts as long as the window does. A choice made for a page the AI drives is not
/// kept, and the AI's pages never get one: only what the user picked on a page of their own is reused, and only for their own pages.
struct RememberedChoices {
    private var byKey: [String: ClientCertificates.Candidate] = [:]

    mutating func remember(_ choice: ClientCertificates.Candidate?, forSite site: String, agentDriven: Bool) {
        if let choice, !agentDriven { byKey[site] = choice }
    }

    func choice(forSite site: String, agentDriven: Bool) -> ClientCertificates.Candidate? {
        agentDriven ? nil : byKey[site]
    }
}

/// Challenges waiting for the user to choose, in the order they came. Those for the same site share one answer, and only one
/// goes to the user at a time. Pure, so how waiters are kept and handed back can be tested with anything standing in for them.
struct CertificatePromptQueue<Waiter, Info> {
    struct Entry {
        let key: String
        var info: Info
        var waiters: [(tab: Int, waiter: Waiter)]
    }

    private(set) var entries: [Entry] = []
    private(set) var activeKey: String?

    /// Joins the entry for `key` (a challenge for the same site is answered with the same choice), or begins one.
    mutating func add(key: String, tab: Int, info: Info, waiter: Waiter) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].waiters.append((tab, waiter))
        } else {
            entries.append(Entry(key: key, info: info, waiters: [(tab, waiter)]))
        }
    }

    /// The next entry to show, if none is shown now: the first that a tab on screen is waiting for. A tab nobody is looking at waits
    /// until it is shown, so a sheet never comes up over a page it has nothing to do with.
    func next(isShown: (Int) -> Bool) -> Entry? {
        guard activeKey == nil else { return nil }
        return entries.first { $0.waiters.contains { isShown($0.tab) } }
    }

    mutating func start(_ key: String) { activeKey = key }

    /// The answer came: everyone who waited for it.
    mutating func finish(_ key: String) -> [Waiter] {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return [] }
        if activeKey == key { activeKey = nil }
        return entries.remove(at: index).waiters.map(\.waiter)
    }

    /// A tab went away (closed, put to sleep): its waiters are handed back to be answered with nothing. `emptiedActive` says the
    /// entry on screen has no one left to answer.
    mutating func drop(tab: Int) -> (released: [Waiter], emptiedActive: Bool) {
        var released: [Waiter] = []
        var emptiedActive = false
        for index in entries.indices {
            released += entries[index].waiters.filter { $0.tab == tab }.map(\.waiter)
            entries[index].waiters.removeAll { $0.tab == tab }
            if entries[index].waiters.isEmpty, entries[index].key == activeKey { emptiedActive = true }
        }
        entries.removeAll { $0.waiters.isEmpty && $0.key != activeKey }
        return (released, emptiedActive)
    }
}
