import Foundation

/// Stored settings are read leniently: a missing key, a value of another type or a name a version of the app doesn't know (an older or newer one wrote
/// it, or the file is damaged) takes that one value back to its default, and does not throw away everything else.
private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// Where ⌘T and a new tab go.
enum NewTabOpens: String, Codable, CaseIterable, Sendable {
    case startPage, commandBar, blank, address
}

/// Where a new tab goes. Anything else an older version stored (a style, sections, a background) is not read.
struct StartPageSettings: Codable, Equatable, Sendable {
    var newTab: NewTabOpens = .startPage
    /// The custom address for `newTab == .address`, as typed.
    var address: String = ""

    static let `default` = StartPageSettings()
}

extension StartPageSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        newTab = container.lenient(.newTab, newTab)
        address = container.lenient(.address, address)
    }
}

/// What the custom address of "New tabs open" comes to.
enum StartAddressCheck: Equatable, Sendable {
    case empty
    case invalid
    /// A page that isn't encrypted: allowed, with a note.
    case insecure(URL)
    case ok(URL)

    var url: URL? {
        switch self {
        case .ok(let url), .insecure(let url): url
        case .empty, .invalid: nil
        }
    }

    static let maxLength = 2048

    /// A bare host gets https; only http and https, with a host and no spaces or user name and password, and of a sensible length, are addresses.
    /// "://" means a scheme only before any "/", "?" or "#": `example.com/?u=http://x` is a bare host with a query.
    static func check(_ typed: String) -> StartAddressCheck {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        guard text.count <= maxLength, !text.contains(where: \.isWhitespace) else { return .invalid }
        let hasScheme = text.range(of: "://").map { !text[..<$0.lowerBound].contains { "/?#".contains($0) } } ?? false
        let withScheme = hasScheme ? text : "https://" + text
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil,
              let host = url.host(), !host.isEmpty, host.contains(".") || host == "localhost" else { return .invalid }
        return scheme == "https" ? .ok(url) : .insecure(url)
    }
}
