import Foundation

/// A search engine the user added: typing `keyword terms` in the address bar searches with it, and it can be the default.
struct CustomSearchEngine: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// One lower-case word.
    var keyword: String
    /// An https address with `%s` once, after the site's name, where the search words go.
    var template: String

    static let defaultsKey = "customSearchEngines"
    static let maxNameLength = 40
    static let maxKeywordLength = 16

    /// The engines stored in the defaults. Each is checked again as it is read, so a damaged or hand-edited value loses that engine and
    /// no other, and a template that is not safe never reaches a search.
    nonisolated static func stored(in defaults: UserDefaults = .standard) -> [CustomSearchEngine] {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([Lossy].self, from: data) else { return [] }
        var kept: [CustomSearchEngine] = []
        for engine in entries.compactMap(\.value) where problem(name: engine.name, keyword: engine.keyword, template: engine.template, among: kept, ignoring: engine.id) == nil {
            kept.append(engine)
        }
        return kept
    }

    nonisolated static func store(_ engines: [CustomSearchEngine], in defaults: UserDefaults = .standard) {
        defaults.set(engines.isEmpty ? nil : try? JSONEncoder().encode(engines), forKey: defaultsKey)
    }

    private struct Lossy: Decodable {
        let value: CustomSearchEngine?
        init(from decoder: Decoder) throws { value = try? CustomSearchEngine(from: decoder) }
    }

    /// Why the three fields can't make an engine, or nil when they can. `ignoring` is the engine being edited.
    nonisolated static func problem(name: String, keyword: String, template: String, among others: [CustomSearchEngine], ignoring id: UUID? = nil) -> Problem? {
        let others = others.filter { $0.id != id }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noName }
        if keyword.isEmpty { return .noKeyword }
        if !isKeyword(keyword) { return .badKeyword }
        if others.contains(where: { $0.keyword == keyword }) { return .keywordTaken }
        if let problem = SearchTemplate.problem(template) { return .template(problem) }
        if others.contains(where: { $0.template == template }) || SearchEngine.allCases.contains(where: { $0.template == template }) { return .alreadyAdded }
        return nil
    }

    /// One word of at most `maxKeywordLength` letters, digits, "-" and "_", in lower case: what can be typed before a search without
    /// being taken for an address.
    nonisolated static func isKeyword(_ text: String) -> Bool {
        !text.isEmpty && text.count <= maxKeywordLength && text == text.lowercased()
            && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    enum Problem: Equatable {
        case noName, noKeyword, badKeyword, keywordTaken, alreadyAdded
        case template(SearchTemplate.Problem)

        var reason: String {
            switch self {
            case .noName: String(localized: "Give the engine a name.")
            case .noKeyword: String(localized: "Give the engine a keyword: one word you type before what you search for.")
            case .badKeyword: String(localized: "A keyword is one word of up to \(maxKeywordLength) letters, numbers, - or _.")
            case .keywordTaken: String(localized: "Another engine already uses that keyword.")
            case .alreadyAdded: String(localized: "That search address is already set up.")
            case .template(let problem): problem.reason
            }
        }
    }
}

/// The address a search engine is reached by: https, the site's name, and `%s` once after it for the words searched for.
enum SearchTemplate {
    static let placeholder = "%s"
    static let google = "https://www.google.com/search?q=%s"

    enum Problem: Equatable {
        case notHTTPS, noPlaceholder, manyPlaceholders, noHost, placeholderInHost

        var reason: String {
            switch self {
            case .notHTTPS: String(localized: "The address must start with https://.")
            case .noPlaceholder: String(localized: "The address needs \(SearchTemplate.placeholder) where your search words go.")
            case .manyPlaceholders: String(localized: "The address can have \(SearchTemplate.placeholder) only once.")
            case .noHost: String(localized: "The address needs a site name after https://.")
            case .placeholderInHost: String(localized: "\(SearchTemplate.placeholder) must come after the site's name, not in it.")
            }
        }
    }

    nonisolated static func problem(_ template: String) -> Problem? {
        guard template.lowercased().hasPrefix("https://") else { return .notHTTPS }
        switch template.components(separatedBy: placeholder).count - 1 {
        case 0: return .noPlaceholder
        case 1: break
        default: return .manyPlaceholders
        }
        // What comes before the first "/", "?" or "#" after "https://" is the site: the search words must not choose it.
        let rest = template.dropFirst("https://".count)
        let site = rest.prefix { !"/?#".contains($0) }
        if site.contains(placeholder) { return .placeholderInHost }
        guard let host = URLComponents(string: template.replacingOccurrences(of: placeholder, with: "x"))?.host, !host.isEmpty else { return .noHost }
        return nil
    }

    /// The template as stored for the default engine, or Google's when it is missing or does not pass.
    nonisolated static func valid(_ stored: String?) -> String {
        guard let stored, problem(stored) == nil else { return google }
        return stored
    }
}

/// Which template a typed search goes to.
enum SearchRouting {
    /// The template and the words to search for: with a custom engine's keyword first and something after it, that engine and what follows;
    /// otherwise the default template and all of it.
    nonisolated static func pick(_ query: String, default template: String, engines: [CustomSearchEngine]) -> (template: String, terms: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = text.firstIndex(where: \.isWhitespace) else { return (template, query) }
        let terms = text[space...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty, let engine = engines.first(where: { $0.keyword == text[..<space].lowercased() }) else { return (template, query) }
        return (engine.template, terms)
    }

    /// Whether what is typed may be sent to the built-in engine for suggestions: not when a custom engine is the default (custom engines get
    /// none) and not when the words are a search on a custom engine's keyword.
    nonisolated static func allowsSuggestions(for query: String, defaultTemplate: String, engines: [CustomSearchEngine]) -> Bool {
        !engines.contains { $0.template == defaultTemplate } && pick(query, default: defaultTemplate, engines: engines).template == defaultTemplate
    }

    nonisolated static func allowsSuggestions(for query: String) -> Bool {
        allowsSuggestions(for: query, defaultTemplate: AddressInput.searchTemplate, engines: CustomSearchEngine.stored())
    }
}

extension Preferences {
    /// The custom engine the default search goes to, if the default is one of them (it is what is stored as the default address).
    var defaultCustomEngine: CustomSearchEngine? {
        let template = UserDefaults.standard.string(forKey: "searchURL")
        return customSearchEngines.first { $0.template == template }
    }

    func useAsDefault(_ engine: CustomSearchEngine) {
        UserDefaults.standard.set(engine.template, forKey: "searchURL")
        objectWillChange.send()
    }

    /// The engine searches go to, built in or added, as the Search Engine menu shows it: one choice for both kinds.
    var defaultEngineChoice: SearchEngineChoice {
        get {
            SearchEngineChoice.current(template: UserDefaults.standard.string(forKey: "searchURL"), builtIn: searchEngine, custom: customSearchEngines)
        }
        set {
            switch newValue {
            case .builtIn(let engine):
                searchEngine = engine
                useBuiltInAsDefault()
            case .custom(let id):
                if let engine = customSearchEngines.first(where: { $0.id == id }) { useAsDefault(engine) }
            }
        }
    }

    /// The default goes back to the engine chosen in the list of built-in ones.
    func useBuiltInAsDefault() {
        UserDefaults.standard.set(searchEngine.template, forKey: "searchURL")
        objectWillChange.send()
    }

    /// Adds the engine, or replaces the one with its id. A default engine whose address changed stays the default.
    func save(_ engine: CustomSearchEngine) {
        let wasDefault = defaultCustomEngine?.id == engine.id
        if let index = customSearchEngines.firstIndex(where: { $0.id == engine.id }) {
            customSearchEngines[index] = engine
        } else {
            customSearchEngines.append(engine)
        }
        if wasDefault { useAsDefault(engine) }
    }

    /// Takes the engine out; when it was the default, the search goes back to the built-in one chosen in the list.
    func remove(_ engine: CustomSearchEngine) {
        let wasDefault = defaultCustomEngine?.id == engine.id
        customSearchEngines.removeAll { $0.id == engine.id }
        if wasDefault { useBuiltInAsDefault() }
    }
}

/// One entry of the Search Engine menu.
enum SearchEngineChoice: Hashable {
    case builtIn(SearchEngine)
    case custom(UUID)

    /// The added engine whose address is the stored default, or else the built-in engine last chosen.
    static func current(template: String?, builtIn: SearchEngine, custom: [CustomSearchEngine]) -> SearchEngineChoice {
        custom.first { $0.template == template }.map { .custom($0.id) } ?? .builtIn(builtIn)
    }
}
