import SwiftUI

/// The popover over the Customize button: style, sections, background and where new tabs open, then "Reset to Defaults". Everything applies as it is
/// changed and "Done" only closes it.
struct StartPageCustomizeView: View {
    @ObservedObject var browser: Browser
    let pageHeight: CGFloat
    let contents: StartPageContents
    @StateObject private var model: StartPageCustomizeModel
    @ObservedObject private var hidden = StartHiddenItems.shared
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 520

    init(browser: Browser, expand: StartSection?, pageHeight: CGFloat, contents: StartPageContents) {
        self.browser = browser
        self.pageHeight = pageHeight
        self.contents = contents
        _model = StateObject(wrappedValue: StartPageCustomizeModel(expanded: expand, offerUndo: { [weak browser] message, undo in browser?.offerUndo(message, undo: undo) }))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Customize").font(.bodyStrong).foregroundStyle(Theme.primary).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { dismiss() } label: { Text("Done") }
                    .buttonStyle(PrimaryButton(size: .small))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    group(String(localized: "Style")) { StartStyleTiles(model: model, tint: browser.space.tint) }
                    group(String(localized: "Sections"), trailing: String(localized: "Drag to reorder")) {
                        StartComponentsList(model: model, contents: contents)
                        if hidden.count > 0 {
                            Button { hidden.showAll() } label: {
                                Text(hidden.count == 1 ? String(localized: "Show 1 hidden item again") : String(localized: "Show \(hidden.count) hidden items again"))
                                    .font(.caption).foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    group(String(localized: "Background")) { StartBackgroundControls(model: model, tint: browser.space.tint) }
                    group(String(localized: "New Tabs Open")) { StartNewTabControls(model: model) }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, max(260, pageHeight - 190)))
            Divider()
            HStack {
                Button { model.reset() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise").font(.symbolInline)
                        Text("Reset to Defaults").font(.secondary)
                    }
                    .foregroundStyle(Theme.primary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Changes apply right away").font(.caption).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 360)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Customize Start Page"))
        .onAppear { Announcer.announce(String(localized: "Customize Start Page")) }
        .onExitCommand { dismiss() }
    }

    private func group<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: title).font(.caption).foregroundStyle(Theme.secondary).accessibilityAddTraits(.isHeader)
                Spacer()
                if let trailing { Text(verbatim: trailing).font(.caption).foregroundStyle(Theme.dim) }
            }
            content()
        }
    }
}

/// Settings › New Tab & Start Page: the same controls in a form, with a preview of the page above them that changes as they are touched.
struct StartPageSettingsView: View {
    @StateObject private var model = StartPageCustomizeModel(offerUndo: { message, undo in Browser.current?.offerUndo(message, undo: undo) })
    @ObservedObject private var hidden = StartHiddenItems.shared
    @State private var tint = Browser.current?.space.tint ?? .blue

    var body: some View {
        Form {
            Section("Style") {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        StartPageMiniature(settings: model.settings, tint: tint)
                            .frame(width: 330)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.cardEdge, lineWidth: 0.5) }
                        Text("Preview").font(.caption).foregroundStyle(.secondary)
                    }
                    StartStyleRadios(model: model).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section("Sections") {
                StartComponentsList(model: model, inline: true)
                Caption(text: "Drag to reorder. Each style remembers its own sections. A section with nothing to show hides itself.")
                if hidden.count > 0 {
                    Button(hidden.count == 1 ? String(localized: "Show 1 hidden item again") : String(localized: "Show \(hidden.count) hidden items again")) { hidden.showAll() }
                }
            }
            Section("Background") { StartBackgroundControls(model: model, tint: tint) }
            Section("New Tabs Open") {
                StartNewTabControls(model: model, detailed: true)
                Caption(text: "A private window always shows its own start page, whatever is set here.")
            }
            Section {
                Button("Reset to Defaults") { model.reset() }
            }
        }
        .formStyle(.grouped)
    }
}
