import AppKit
import SwiftUI

/// The list under Site Styles in Appearance: the CSS the user keeps for a site, each with its switch, so that one that breaks a page is turned off
/// (or taken out, with Undo) in a click. New ones start from the site in front when it has no style yet.
struct SiteStylesSettings: View {
    @ObservedObject var styles: SiteStyles = .shared
    @State private var draft: Draft?
    /// The style just removed, which the line under the list can put back, and why it couldn't be when it couldn't. This pane says it, not a
    /// window's notice: there may be no window to show one, or only a private one.
    @State private var removed: SiteStyle?
    @State private var undoProblem: SiteStyle.Problem?

    /// What is typed in the editor. The style's switch is not in it: that stays as the list has it, also when it is changed while editing.
    struct Draft {
        var id: UUID?
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
                Button { draft = Draft(id: style.id, host: style.host, css: style.css) } label: { Image(systemName: "pencil") }
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
                CSSEditor(text: field(\.css))
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
        if let removed {
            HStack {
                Caption(verbatim: String(localized: "Removed the style for \(removed.host)"))
                Spacer()
                Button("Undo", action: undoRemove)
            }
            if let undoProblem { Caption(verbatim: undoProblem.reason, color: Theme.waitingText) }
        }
        if !styles.setAside.isEmpty {
            HStack {
                Caption(verbatim: String(localized: "\(styles.setAside.count) saved entries can't be used now (damaged, or a site that is no longer accepted). They are kept, not deleted."))
                Spacer()
                Button("Discard") { styles.discardSetAside() }
            }
        }
        Caption(text: "The CSS you keep here is put in every page of the site and of the sites under it, each time they open, in every window, private ones included. It is kept only on this Mac. Scripts are not supported.")
            // The editor closes when the style in it is removed, so Save can't make it again.
            .onChange(of: styles.styles.map(\.id)) { _, ids in
                if let id = draft?.id, !ids.contains(id) { draft = nil }
            }
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
        if let id = draft.id { styles.update(id, host: draft.host, css: draft.css) } else { styles.save(SiteStyle(host: draft.host, css: draft.css)) }
        self.draft = nil
    }

    private func remove(_ style: SiteStyle) {
        styles.remove(style.id)
        removed = style
        undoProblem = nil
        Announcer.announce(String(localized: "Removed the style for \(style.host)"))
    }

    private func undoRemove() {
        guard let style = removed else { return }
        undoProblem = styles.save(style)
        if undoProblem == nil { removed = nil }
    }
}

/// The CSS editor: a plain text view, with what a text field does to prose turned off. Typing `"` or `--` in CSS must give those characters, not
/// curly quotes and a dash, and no word is corrected or replaced. (SwiftUI's TextEditor leaves these on, as set in System Settings.)
struct CSSEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        Self.configure(view)
        view.string = text
        view.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func configure(_ view: NSTextView) {
        view.isRichText = false
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.setAccessibilityLabel(String(localized: "CSS"))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CSSEditor
        init(_ parent: CSSEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, parent.text != view.string else { return }
            parent.text = view.string
        }
    }
}
