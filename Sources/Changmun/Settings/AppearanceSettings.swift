import AppKit
import SwiftUI

// MARK: Appearance

struct AppearanceSettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section("Theme") {
                HStack(spacing: 28) {
                    ForEach(AppAppearance.allCases) { ThemeTile(choice: $0, selection: $prefs.appearance) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section("Address Bar") {
                Picker("Address Bar Position", selection: $prefs.toolbarPlace) {
                    Text("Above the Page").tag(ToolbarPlace.page)
                    Text("In the Sidebar").tag(ToolbarPlace.sidebar)
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Address Bar")
                    addressBarChoice(.automatic) {
                        Text("Match developer mode (currently: \(Preferences.onTop(.automatic, developerMode: prefs.developerMode) ? String(localized: "Full Address") : String(localized: "Site and Title")))")
                    }
                    addressBarChoice(.sidebar) { Text("Site and Title") }
                    addressBarChoice(.top) { Text("Full Address") }
                }
                Caption(text: "A full address can be edited right in place (⌘L). With site and title, ⌘L opens the search field to edit it.")
            }
            Section("Display") {
                LabeledContent("Sidebar Width") {
                    Slider(value: $prefs.sidebarWidth, in: Preferences.sidebarWidths, step: 4).frame(width: 220)
                }
                Picker("Default Zoom", selection: $prefs.defaultZoom) {
                    ForEach([0.75, 0.9, 1, 1.1, 1.25, 1.5], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension AppearanceSettings {
    /// A radio row, with the radio on the left of its text.
    private func addressBarChoice(_ choice: AddressBarChoice, @ViewBuilder label: () -> some View) -> some View {
        Button { prefs.addressBar = choice } label: {
            HStack(spacing: 8) {
                Image(systemName: prefs.addressBar == choice ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(prefs.addressBar == choice ? Color.accentColor : .secondary)
                label()
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(prefs.addressBar == choice ? .isSelected : [])
    }
}

/// One theme as a small picture of the window in it; the system theme is cut across, half light and half dark.
private struct ThemeTile: View {
    let choice: AppAppearance
    @Binding var selection: AppAppearance

    private struct Slant: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.width * 0.62, y: 0))
            path.addLine(to: CGPoint(x: rect.width, y: 0))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width * 0.46, y: rect.height))
            path.closeSubpath()
            return path
        }
    }

    var body: some View {
        Button { selection = choice } label: {
            VStack(spacing: 6) {
                picture
                    .frame(width: 104, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: selection == choice ? 3 : 0))
                label
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == choice ? .isSelected : [])
    }

    @ViewBuilder private var label: some View {
        switch choice {
        case .system: Text("System")
        case .light: Text("Light")
        case .dark: Text("Dark")
        }
    }

    @ViewBuilder private var picture: some View {
        switch choice {
        case .system:
            ZStack {
                window(dark: false)
                window(dark: true).mask(Slant())
            }
        case .light: window(dark: false)
        case .dark: window(dark: true)
        }
    }

    private func window(dark: Bool) -> some View {
        let sidebar = dark ? Color(white: 0.13) : Color(white: 0.86)
        let page = dark ? Color(white: 0.17) : Color(white: 0.93)
        let bar = dark ? Color(white: 0.27) : Color.white
        return HStack(spacing: 0) {
            VStack(alignment: .leading) {
                HStack(spacing: 3) {
                    Circle().fill(.red); Circle().fill(.yellow); Circle().fill(.green)
                }
                .frame(height: 4.5)
                .padding(.top, 6)
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(width: 30)
            .background(sidebar)
            VStack(spacing: 5) {
                Spacer().frame(height: 3)
                ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 2.5).fill(bar).frame(height: 10) }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(page)
        }
    }
}
