import Foundation
import FoundationModels

/// Sorts tabs into groups: tabs opened from one another and tabs of one site go together, and where Apple
/// Intelligence is on, tabs about the same thing too, worked out by the model on this Mac. Nothing leaves it.
enum TabSorter {
    struct Item: Equatable, Sendable {
        var id: Int
        var title: String
        var host: String?
        /// The tab it was opened from.
        var opener: Int?
    }

    struct Group: Equatable {
        var name: String
        var ids: [Int]
    }

    static let noTopic = "None"

    /// Groups for the tabs, in the order of their first tabs. A group named like one in `existing` means that group.
    static func plan(_ items: [Item], existing: [String]) async -> [Group] {
        plan(items, topics: await topics(for: items, existing: existing) ?? [:], existing: existing)
    }

    /// Tabs given the same topic go together; a tab without one follows the tab it was opened from, and the rest go by
    /// opener and site. A new group needs two tabs; one tab is enough to join a group that is there already.
    static func plan(_ items: [Item], topics: [Int: String], existing: [String] = []) -> [Group] {
        let ids = Set(items.map(\.id))
        var topic = topics.filter { ids.contains($0.key) && $0.value != noTopic }
        var followed = true
        while followed {
            followed = false
            for item in items where topic[item.id] == nil {
                if let opener = item.opener, let name = topic[opener] {
                    topic[item.id] = name
                    followed = true
                }
            }
        }
        // A topic the model gave one tab only makes no group of its own, unless the window has a group by that name.
        let counts = Dictionary(grouping: topic.values, by: { $0 }).mapValues(\.count)
        topic = topic.filter { counts[$0.value, default: 0] > 1 || existing.contains($0.value) }
        var groups: [Group] = []
        func add(_ name: String, _ id: Int) {
            if let index = groups.firstIndex(where: { $0.name == name }) { groups[index].ids.append(id) } else { groups.append(Group(name: name, ids: [id])) }
        }
        let rest = items.filter { topic[$0.id] == nil }
        let clustered = Dictionary(uniqueKeysWithValues: clusters(rest).flatMap { cluster in cluster.ids.map { ($0, cluster.name) } })
        for item in items {
            if let name = topic[item.id] ?? clustered[item.id] { add(name, item.id) }
        }
        return groups.filter { $0.ids.count > 1 || existing.contains($0.name) }
    }

    /// Tabs opened from one another or on one site, two or more together, named for the site or the first tab.
    static func clusters(_ items: [Item]) -> [Group] {
        var parent = Array(items.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { i = parent[i] }
            return i
        }
        func join(_ a: Int, _ b: Int) {
            let (ra, rb) = (root(a), root(b))
            parent[max(ra, rb)] = min(ra, rb)
        }
        let index = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var bySite: [String: Int] = [:]
        for (i, item) in items.enumerated() {
            if let opener = item.opener, let o = index[opener] { join(i, o) }
            if let site = item.host.map(site) {
                if let other = bySite[site] { join(i, other) } else { bySite[site] = i }
            }
        }
        let members = Dictionary(grouping: items.indices, by: root)
        return members.keys.sorted().compactMap { key in
            let cluster = members[key]!.map { items[$0] }
            guard cluster.count > 1 else { return nil }
            let sites = Set(cluster.compactMap { $0.host.map(site) })
            let title = cluster[0].title.components(separatedBy: " - ").first ?? cluster[0].title
            let name = sites.count == 1 ? sites.first! : String(title.prefix(24))
            return Group(name: name, ids: cluster.map(\.id))
        }
    }

    /// The host without "www." or "m.".
    static func site(_ host: String) -> String {
        var host = host.lowercased()
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        return host
    }

    /// Which of the groups a newly opened tab belongs in, if it plainly belongs in one: a group all on its site, or, by
    /// the model, a group doing the same thing.
    static func fit(_ item: Item, groups: [(name: String, members: [Item])]) async -> Int? {
        if let site = item.host.map(site),
           let index = groups.firstIndex(where: { group in !group.members.isEmpty && group.members.allSatisfy { $0.host.map(Self.site) == site } }) {
            return index
        }
        guard #available(macOS 26, *) else { return nil }
        return await Model.fit(item, groups: groups)
    }

    static func topics(for items: [Item], existing: [String]) async -> [Int: String]? {
        guard #available(macOS 26, *) else { return nil }
        return await Model.topics(for: items, existing: existing)
    }

    static func line(_ item: Item) -> String {
        let title = item.title.isEmpty ? (item.host ?? "") : String(item.title.prefix(80))
        return item.host.map { "\(title) (\($0))" } ?? title
    }
}

/// Apple's on-device model. It answers in a set shape, so it can only name the tabs and groups it was shown.
@available(macOS 26, *)
private enum Model {
    /// The model keeps a short context: more tabs than this are left out.
    static let most = 50

    /// The person's language, in English, for the model to answer in.
    static var language: String {
        Locale(identifier: "en").localizedString(forIdentifier: Bundle.main.preferredLocalizations.first ?? "en") ?? "English"
    }

    static func topics(for items: [TabSorter.Item], existing: [String]) async -> [Int: String]? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let items = Array(items.prefix(most))
        let list = items.enumerated().map { "\($0.offset + 1). \(TabSorter.line($0.element))" }.joined(separator: "\n")
        return await withTimeout {
            let kept = existing.isEmpty ? "" : "\nExisting groups: \(existing.joined(separator: ", ")). If a tab fits one of these groups, use its name exactly."
            let first = LanguageModelSession(instructions: """
                Look at the list of browser tabs the user has open and decide on a few broad topics to sort them into. A topic is what the user was doing, not a site name (for example "Trip to Jeju", "Swift development", "Shopping", "Videos").
                Each topic needs at least 2 tabs. Merge similar activities into one.\(kept)
                Write the topic names in \(language).
                """)
            let topicsSchema = try GenerationSchema(root: DynamicGenerationSchema(name: "Topics", properties: [
                .init(name: "topics", description: "2 to 6 topics to sort the tabs into, each a short name (1-3 words) in \(language)",
                      schema: .init(arrayOf: .init(type: String.self))),
            ]), dependencies: [])
            let found = try await first.respond(to: list, schema: topicsSchema, options: GenerationOptions(sampling: .greedy))
                .content.value([String].self, forProperty: "topics")
            var names: [String] = []
            for name in found.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !name.isEmpty && name != TabSorter.noTopic && !names.contains(name) {
                names.append(name)
            }
            guard !names.isEmpty else { return [:] }
            let second = LanguageModelSession(instructions: "For each tab, pick the topic that fits best. If none of the topics fit, pick \"\(TabSorter.noTopic)\". Cover every tab.")
            let plan = try GenerationSchema(root: DynamicGenerationSchema(name: "Plan", properties: [
                .init(name: "tabs", schema: .init(arrayOf: .init(referenceTo: "Tab"))),
            ]), dependencies: [
                DynamicGenerationSchema(name: "Tab", properties: [
                    .init(name: "tab", schema: .init(type: Int.self)),
                    .init(name: "topic", schema: .init(referenceTo: "Topic")),
                ]),
                DynamicGenerationSchema(name: "Topic", anyOf: names + [TabSorter.noTopic]),
            ])
            let picked = try await second.respond(to: "Topics: \(names.joined(separator: ", "))\n\nTabs:\n\(list)", schema: plan,
                                                  options: GenerationOptions(sampling: .greedy))
            var topics: [Int: String] = [:]
            for entry in try picked.content.value([GeneratedContent].self, forProperty: "tabs") {
                let number = try entry.value(Int.self, forProperty: "tab"), name = try entry.value(String.self, forProperty: "topic")
                if items.indices.contains(number - 1), topics[items[number - 1].id] == nil { topics[items[number - 1].id] = name }
            }
            return topics
        }
    }

    static func fit(_ item: TabSorter.Item, groups: [(name: String, members: [TabSorter.Item])]) async -> Int? {
        guard SystemLanguageModel.default.isAvailable, !groups.isEmpty else { return nil }
        var names: [String] = []
        for group in groups where !names.contains(group.name) && group.name != TabSorter.noTopic { names.append(group.name) }
        guard !names.isEmpty else { return nil }
        let choices = names
        let described = groups.map { group in
            "- \(group.name): " + group.members.prefix(4).map { TabSorter.line($0) }.joined(separator: "; ")
        }.joined(separator: "\n")
        let name = await withTimeout {
            let session = LanguageModelSession(instructions: """
                Pick the group a newly opened browser tab belongs in. Pick a group only if the tab is clearly the same activity as the tabs in it; otherwise pick "\(TabSorter.noTopic)".
                """)
            let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Pick", properties: [
                .init(name: "group", schema: .init(referenceTo: "Group")),
            ]), dependencies: [DynamicGenerationSchema(name: "Group", anyOf: choices + [TabSorter.noTopic])])
            let answer = try await session.respond(to: "Groups:\n\(described)\n\nNew tab: \(TabSorter.line(item))", schema: schema,
                                                   options: GenerationOptions(sampling: .greedy))
            return try answer.content.value(String.self, forProperty: "group")
        }
        guard let name else { return nil }
        return groups.firstIndex { $0.name == name }
    }

    /// The work's answer, or nil if it failed or took too long (a busy model shouldn't hold the button). Work that runs
    /// over is left to finish on its own, unheard.
    static func withTimeout<T: Sendable>(seconds: Double = 20, _ work: @escaping @Sendable () async throws -> T) async -> T? {
        let race = Race<T>()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            Task { race.finish(try? await work()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                race.finish(nil)
            }
        }
    }
}

/// Whichever finishes first answers; the other is ignored.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<T?, Never>?

    func finish(_ value: T?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}
