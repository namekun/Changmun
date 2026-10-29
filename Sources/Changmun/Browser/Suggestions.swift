import Foundation

/// What the search engine suggests for a few typed words.
enum SearchSuggestions {
    static func url(for engine: SearchEngine, query: String) -> URL? {
        var components: URLComponents?
        switch engine {
        case .google:
            components = URLComponents(string: "https://suggestqueries.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8")
            components?.queryItems?.append(URLQueryItem(name: "q", value: query))
        case .duckDuckGo:
            components = URLComponents(string: "https://duckduckgo.com/ac/?type=list")
            components?.queryItems?.append(URLQueryItem(name: "q", value: query))
        case .bing:
            components = URLComponents(string: "https://api.bing.com/osjson.aspx")
            components?.queryItems = [URLQueryItem(name: "query", value: query)]
        case .naver:
            components = URLComponents(string: "https://ac.search.naver.com/nx/ac?q_enc=UTF-8&st=100&r_format=json&r_enc=UTF-8")
            components?.queryItems?.append(URLQueryItem(name: "q", value: query))
        }
        // URLComponents leaves "+" alone, which servers read as a space ("c++" would ask about "c").
        let encoded = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encoded
        return components?.url
    }

    /// Short searches only: a long sentence is more likely a question for the AI or something pasted, which shouldn't
    /// leave for the search engine while it's typed.
    static func mayAsk(_ query: String) -> Bool {
        query.count <= 60 && query.split(separator: " ").count <= 6 && !query.contains("\n")
    }

    /// `["query", ["suggestion", …]]` (Google, DuckDuckGo, Bing) or Naver's `{"items": [[["suggestion"], …]]}`.
    static func parse(_ data: Data) -> [String] {
        let json = try? JSONSerialization.jsonObject(with: data)
        if let list = json as? [Any], list.count > 1, let words = list[1] as? [String] { return words }
        if let object = json as? [String: Any], let groups = object["items"] as? [[[String]]], let first = groups.first {
            return first.compactMap(\.first)
        }
        return []
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        return URLSession(configuration: config)
    }()

    static func fetch(_ query: String, engine: SearchEngine) async -> [String] {
        guard let url = url(for: engine, query: query),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let lower = query.lowercased()
        return parse(data).filter { $0.lowercased() != lower }
    }
}

/// The command bar's list, worked out off the main thread as the user types: the local search over tens of thousands
/// of visits takes tens of milliseconds, and the engine's suggestions a network round trip.
@MainActor
final class SuggestionSource: ObservableObject {
    @Published private(set) var pages: [Library.Entry] = []
    @Published private(set) var searches: [String] = []
    private var pageTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    /// `hiding`: favorites of other profile spaces, which this window's suggestions must not show. `history` false (a private window): bookmarks only.
    func update(_ raw: String, remote: Bool, hiding: [String] = [], history: Bool = true) {
        pageTask?.cancel()
        searchTask?.cancel()
        let query = raw.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searches = []
            pageTask = Task {
                let marks = await Library.shared.inBackground { $0.bookmarks(hiding: hiding) }
                if !Task.isCancelled { pages = marks }
            }
            return
        }
        pageTask = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let found = await Library.shared.inBackground { $0.search(query, hiding: hiding, history: history) }
            if !Task.isCancelled { pages = found }
        }
        guard remote, SearchSuggestions.mayAsk(query), !AddressInput.isAddress(query) else {
            searches = []
            return
        }
        let engine = Preferences.shared.searchEngine
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let found = await SearchSuggestions.fetch(query, engine: engine)
            if !Task.isCancelled { searches = found }
        }
    }
}
