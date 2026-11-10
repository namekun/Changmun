import SwiftUI

/// The engines the user added, under the picker of built-in ones: add, edit, remove, and which one is the default.
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

    var body: some View {
        ForEach(prefs.customSearchEngines) { engine in
            HStack {
                VStack(alignment: .leading) {
                    Text(engine.name).lineLimit(1)
                    Caption(verbatim: engine.keyword + " · " + (URLComponents(string: engine.template)?.host ?? engine.template))
                }
                Spacer()
                if prefs.defaultCustomEngine?.id == engine.id {
                    Text("Default").foregroundStyle(.secondary)
                } else {
                    Button("Use as Default") { prefs.useAsDefault(engine) }
                }
                Button { draft = Draft(id: engine.id, name: engine.name, keyword: engine.keyword, template: engine.template) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit")
                    .accessibilityLabel(String(localized: "Edit \(engine.name)"))
                Button(role: .destructive) { remove(engine) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove")
                    .accessibilityLabel(String(localized: "Remove \(engine.name)"))
            }
        }
        if prefs.defaultCustomEngine != nil {
            Button("Use \(prefs.searchEngine.name) as Default") { prefs.useBuiltInAsDefault() }
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
            Button("Add Search Engine…") { draft = Draft() }
        }
        Caption(text: "Type an engine’s keyword and then what you want to find in the address bar to search with it. Engines you add get no search suggestions.")
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
