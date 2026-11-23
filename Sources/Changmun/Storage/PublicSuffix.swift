import Foundation

/// The Public Suffix List, both its ICANN and its PRIVATE sections: the names under which anyone can register a name of their own
/// (com, co.kr, and also github.io or myshopify.com, whose subdomains are different people's). It is the one definition of a site the
/// app goes by: the address bar's completion (`SiteIndex.registrableStart`), which hosts share saved logins (`Logins.mayShare`) and
/// which hosts a sign-in offer survives a move between (`Tab.sameSite`).
///
/// The list is `Resources/public_suffix_list.dat`, fetched as is from https://publicsuffix.org/list/public_suffix_list.dat (Mozilla
/// Public License 2.0; its header is kept in the file), and copied into the app by scripts/bundle.sh. Refresh it by fetching it again.
final class PublicSuffix: Sendable {
    /// Read once, the first time anything asks; the app asks off the main thread at launch (`preload`), so no page waits for it. nil
    /// when the file can't be read, and then nothing that depends on it is shared or completed beyond the last label.
    static let shared: PublicSuffix? = load()

    /// Tests that check what happens without the list.
    @TaskLocal static var unavailableForTest = false

    static var list: PublicSuffix? { unavailableForTest ? nil : shared }

    /// Reads the list on a background queue, so the first page that needs it doesn't.
    static func preload() {
        DispatchQueue.global(qos: .utility).async { _ = shared }
    }

    /// Suffixes the list doesn't have but whose subdomains are still different people's (blogs, hosting): taken as private rules.
    static let missingFromList = ["tistory.com", "wordpress.com", "glitch.me", "amazonaws.com"]

    private let rules: Set<String>
    /// The rest of a wildcard rule: "ck" for "*.ck".
    private let wildcards: Set<String>
    /// An exception rule without its "!": "www.ck".
    private let exceptions: Set<String>

    var count: Int { rules.count + wildcards.count + exceptions.count }

    init(list: String) {
        var rules = Set<String>(), wildcards = Set<String>(), exceptions = Set<String>()
        for line in list.split(whereSeparator: \.isNewline) {
            guard let rule = line.split(whereSeparator: \.isWhitespace).first, !rule.hasPrefix("//") else { continue }
            let name = Self.normalized(String(rule.hasPrefix("!") ? rule.dropFirst() : rule.hasPrefix("*.") ? rule.dropFirst(2) : rule))
            guard let name, !name.isEmpty else { continue }
            if rule.hasPrefix("!") { exceptions.insert(name) } else if rule.hasPrefix("*.") { wildcards.insert(name) } else { rules.insert(name) }
        }
        rules.formUnion(Self.missingFromList)
        self.rules = rules
        self.wildcards = wildcards
        self.exceptions = exceptions
    }

    private static func load() -> PublicSuffix? {
        // In the app it is a resource; run from the package (swift run, the tests) it is read where it sits in the source tree.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Resources/public_suffix_list.dat").standardizedFileURL
        let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat") ?? source
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let list = PublicSuffix(list: text)
        return list.rules.count > Self.missingFromList.count ? list : nil
    }

    /// How many labels at the end of `host` make its registrable domain (the public suffix and one label more): 2 for
    /// accounts.example.com, 3 for nid.naver.co.kr and for alice.github.io. nil for an IP address, a name of one label, and a name
    /// that is a public suffix itself.
    func registrableLabelCount(_ host: String) -> Int? {
        guard let name = Self.normalized(host), name.contains("."), !Self.isAddress(name) else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.contains(where: \.isEmpty) else { return nil }
        let suffix = suffixLabelCount(labels)
        return suffix < labels.count ? suffix + 1 : nil
    }

    /// The registrable domain of `host`, in lower case (and punycode): nil where `registrableLabelCount` is.
    func registrableDomain(_ host: String) -> String? {
        guard let count = registrableLabelCount(host), let name = Self.normalized(host) else { return nil }
        return name.split(separator: ".").suffix(count).joined(separator: ".")
    }

    func isPublicSuffix(_ host: String) -> Bool {
        guard let name = Self.normalized(host), !name.isEmpty else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return suffixLabelCount(labels) == labels.count
    }

    /// The labels of the public suffix, by the list's rules: an exception rule wins, else the longest rule that matches (a wildcard
    /// matching any one label in its place), else the last label alone (the list's implicit "*").
    private func suffixLabelCount(_ labels: [Substring]) -> Int {
        let ends = (0..<labels.count).map { labels[$0...].joined(separator: ".") }
        if let i = ends.firstIndex(where: exceptions.contains) { return labels.count - i - 1 }
        for i in 0..<labels.count {
            if rules.contains(ends[i]) || (i + 1 < labels.count && wildcards.contains(ends[i + 1])) { return labels.count - i }
        }
        return 1
    }

    /// Lower case, without a trailing dot, with every label that isn't ASCII in punycode ("xn--…"), as WebKit gives host names.
    static func normalized(_ host: String) -> String? {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.unicodeScalars.allSatisfy(\.isASCII) else { return name }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false).map { label in
            label.unicodeScalars.allSatisfy(\.isASCII) ? String(label) : punycode(String(label)).map { "xn--" + $0 }
        }
        guard labels.allSatisfy({ $0 != nil }) else { return nil }
        return labels.compactMap { $0 }.joined(separator: ".")
    }

    private static func isAddress(_ name: String) -> Bool {
        name.contains(":") || name.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
    }

    /// RFC 3492's encoding of a label, without the "xn--".
    static func punycode(_ label: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        let input = label.unicodeScalars.map { Int($0.value) }
        var output = input.filter { $0 < 0x80 }.compactMap { UnicodeScalar($0).map(Character.init) }
        let basic = output.count
        if basic > 0 { output.append("-") }
        func adapt(_ delta: Int, _ points: Int, _ first: Bool) -> Int {
            var delta = first ? delta / damp : delta / 2
            delta += delta / points
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 {
                delta /= base - tMin
                k += base
            }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }
        func digit(_ d: Int) -> Character { Character(UnicodeScalar(UInt8(d < 26 ? d + 97 : d + 22))) }
        var n = 128, delta = 0, bias = 72, handled = basic
        while handled < input.count {
            guard let next = input.filter({ $0 >= n }).min() else { return nil }
            delta += (next - n) * (handled + 1)
            n = next
            for c in input {
                if c < n { delta += 1 }
                guard c == n else { continue }
                var q = delta, k = base
                while true {
                    let t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias
                    if q < t { break }
                    output.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q))
                bias = adapt(delta, handled + 1, handled == basic)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return String(output)
    }
}
