import SwiftUI

/// The list under Site Styles in Appearance: the CSS the user keeps for a site, each with its switch, so that one that breaks a page is turned off
/// (or taken out, with Undo) in a click. New ones start from the site in front when it has no style yet.
struct SiteStylesSettings: View {
    @ObservedObject var styles: SiteStyles = .shared
    @State private var draft: Draft?

    struct Draft {
        var id: UUID?
        var isOn = true
        var host = ""
        var css = ""
    }

    private var problem: SiteStyle.Problem? {
        guard let draft else { return nil }
        return SiteStyle.problem(host: draft.host, css: draft.css, among: styles.styles, ignoring: draft.id)
    }

    /// The reason the style can't be saved yet, once the user has started typing.
    private var shownProblem: SiteStyle.Problem? {
        guard let draft, !(draft.host + draft.css).isEmpty else { return nil }
        return problem
    }

    var body: some View {
        ForEach(styles.styles) { style in
            HStack {
                VStack(alignment: .leading) {
                    Text(verbatim: DisplayHost.trimmed(style.host)).lineLimit(1)
                    Caption(verbatim: style.css.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                        .lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { style.isOn }, set: { styles.setOn($0, for: style.id) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Apply the style for \(style.host)"))
                Button { draft = Draft(id: style.id, isOn: style.isOn, host: style.host, css: style.css) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit")
                    .accessibilityLabel(String(localized: "Edit \(style.host)"))
                Button(role: .destructive) { remove(style) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove")
                    .accessibilityLabel(String(localized: "Remove \(style.host)"))
            }
        }
        if draft != nil {
            VStack(alignment: .leading) {
                TextField("Site", text: field(\.host), prompt: Text(verbatim: "example.com"))
                TextEditor(text: field(\.css))
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 128)
                    .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(.separator))
                    .accessibilityLabel(String(localized: "CSS"))
                if let shownProblem { Caption(verbatim: shownProblem.reason, color: Theme.waitingText) }
                HStack {
                    Spacer()
                    Button("Cancel") { draft = nil }
                    Button("Save", action: save).disabled(problem != nil)
                }
            }
        } else {
            Button("Add Site Style") { draft = Draft(host: suggestedHost) }
        }
        Caption(text: "The CSS you keep here is put in every page of the site and of the sites under it, each time they open, in every window, private ones included. It is kept only on this Mac. Scripts are not supported.")
    }

    /// The site in the window in front, as long as it has no style yet.
    private var suggestedHost: String {
        guard let url = Browser.current?.active?.url, url.scheme?.hasPrefix("http") == true, let site = SiteStyle.normalizedHost(url.host() ?? ""),
              !styles.styles.contains(where: { $0.host == site }) else { return "" }
        return site
    }

    private func field(_ key: WritableKeyPath<Draft, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: key] ?? "" }, set: { draft?[keyPath: key] = $0 })
    }

    private func save() {
        guard let draft, problem == nil else { return }
        styles.save(SiteStyle(id: draft.id ?? UUID(), host: draft.host, css: draft.css, isOn: draft.isOn))
        self.draft = nil
    }

    private func remove(_ style: SiteStyle) {
        styles.remove(style.id)
        Browser.recent?.offerUndo(String(localized: "Removed the style for \(style.host)")) { styles.save(style) }
    }
}
