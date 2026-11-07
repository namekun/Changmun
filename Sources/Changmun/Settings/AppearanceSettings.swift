import AppKit
import SwiftUI

// MARK: Appearance

struct AppearanceSettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section("Theme") {
                HStack(spacing: 24) {
                    ForEach(AppAppearance.allCases) { ThemeTile(choice: $0, selection: $prefs.appearance) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section("Display") {
                Picker("Default Zoom", selection: $prefs.defaultZoom) {
                    ForEach([0.75, 0.9, 1, 1.1, 1.25, 1.5], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
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
            VStack(spacing: 8) {
                picture
                    .frame(width: 104, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 7))  // design-exempt: the theme tile is a scaled-down drawing of the window
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))  // design-exempt: the theme tile is a scaled-down drawing of the window
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: selection == choice ? 3 : 0))  // design-exempt: the theme tile is a scaled-down drawing of the window
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
                HStack(spacing: 3) {  // grid-exempt: scale-model drawing of a window
                    Circle().fill(.red); Circle().fill(.yellow); Circle().fill(.green)
                }
                .frame(height: 4.5)
                .padding(.top, 6)  // grid-exempt: scale-model drawing of a window
                Spacer()
            }
            .padding(.horizontal, 6)  // grid-exempt: scale-model drawing of a window
            .frame(width: 30)
            .background(sidebar)
            VStack(spacing: 5) {  // grid-exempt: scale-model drawing of a window
                Spacer().frame(height: 3)
                ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 2.5).fill(bar).frame(height: 10) }  // design-exempt: the theme tile is a scaled-down drawing of the window
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(page)
        }
    }
}
