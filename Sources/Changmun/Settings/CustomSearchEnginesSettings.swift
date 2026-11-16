import SwiftUI

/// The list of search engines under the Search Engine menu: the built-in ones still in it and those the user added, each taken out with
/// its button but the default, and more put in from the Add menu (one taken out, a well-known one, or any other).
struct CustomSearchEnginesSettings: View {
    @ObservedObject var prefs: Preferences
    @State private var draft: Draft?

    struct Draft {
        var id: UUID?
        var name = ""
        var keyword = ""
        var template = ""

        var normalizedKeyword: String { keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var normalizedTemplate: String { template.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private var problem: CustomSearchEngine.Problem? {
        guard let draft else { return nil }
        return CustomSearchEngine.problem(name: draft.name, keyword: draft.normalizedKeyword, template: draft.normalizedTemplate, among: prefs.customSearchEngines, ignoring: draft.id)
    }

    /// The reason the engine can't be saved yet, once the user has started typing.
    private var shownProblem: CustomSearchEngine.Problem? {
        guard let draft, !(draft.name + draft.keyword + draft.template).isEmpty else { return nil }
        return problem
    }

    private var builtIns: [SearchEngine] { SearchEngine.listed(removed: prefs.removedSearchEngines) }
    private var defaultTemplate: String { AddressInput.searchTemplate }

    var body: some View {
        // One list: the built-in engines still in it, then the added ones. Each can be taken out but the one searches go to.
        ForEach(builtIns) { engine in
            row(name: engine.name, keyword: nil, template: engine.template) {
                removeButton(engine.name) { prefs.setListed(engine, false) }
            }
        }
        ForEach(prefs.customSearchEngines) { engine in
            row(name: engine.name, keyword: engine.keyword, template: engine.template) {
                Button { draft = Draft(id: engine.id, name: engine.name, keyword: engine.keyword, template: engine.template) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit")
                    .accessibilityLabel(String(localized: "Edit \(engine.name)"))
                removeButton(engine.name) { remove(engine) }
            }
        }
        if draft != nil {
            VStack(alignment: .leading) {
                TextField("Name", text: field(\.name))
                TextField("Keyword", text: field(\.keyword), prompt: Text(verbatim: "wiki"))
                TextField("Address", text: field(\.template), prompt: Text(verbatim: "https://en.wikipedia.org/w/index.php?search=%s"))
                if let shownProblem { Caption(verbatim: shownProblem.reason, color: Theme.waitingText) }
                HStack {
                    Spacer()
                    Button("Cancel") { draft = nil }
                    Button("Save", action: save).disabled(problem != nil)
                }
            }
        } else {
            Menu("Add Search Engine") {
                let removed = SearchEngine.allCases.filter { !builtIns.contains($0) }
                ForEach(removed) { engine in Button(engine.name) { prefs.setListed(engine, true) } }
                let presets = SearchEnginePresets.available(besides: prefs.customSearchEngines)
                ForEach(presets) { preset in Button(preset.name) { prefs.save(preset) } }
                if !removed.isEmpty || !presets.isEmpty { Divider() }
                Button("Other…") { draft = Draft() }
            }
            .fixedSize()
        }
        Caption(text: "The engines in this list are offered under a search in the address bar: click one, or press ⌘ and its number, to search with it once. An engine you add can also be searched by typing its keyword before your words, and gets no search suggestions.")
    }

    /// An engine's line: its name, its keyword and site, and what can be done to it; the default engine says so and can't be taken out.
    private func row<Actions: View>(name: String, keyword: String?, template: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(verbatim: name).lineLimit(1)
                let site = URLComponents(string: template.replacingOccurrences(of: SearchTemplate.placeholder, with: "x"))?.host ?? template
                Caption(verbatim: keyword.map { $0 + " · " + site } ?? site)
            }
            Spacer()
            if template == defaultTemplate {
                Text("Default").foregroundStyle(.secondary)
            } else {
                actions()
            }
        }
    }

    private func removeButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Remove")
            .accessibilityLabel(String(localized: "Remove \(name)"))
    }

    private func field(_ key: WritableKeyPath<Draft, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: key] ?? "" }, set: { draft?[keyPath: key] = $0 })
    }

    private func save() {
        guard let draft, problem == nil else { return }
        prefs.save(CustomSearchEngine(id: draft.id ?? UUID(), name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                      keyword: draft.normalizedKeyword, template: draft.normalizedTemplate))
        self.draft = nil
    }

    private func remove(_ engine: CustomSearchEngine) {
        let wasDefault = prefs.defaultCustomEngine?.id == engine.id
        prefs.remove(engine)
        Browser.recent?.offerUndo(String(localized: "Removed the search engine \(engine.name)")) {
            prefs.save(engine)
            if wasDefault { prefs.useAsDefault(engine) }
        }
    }
}
