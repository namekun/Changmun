import AppKit
import SwiftUI

/// The Keyboard Shortcuts window: the keys of the scheme in use, read from the menu, then the gestures, with a way to the setting that switches scheme.
struct ShortcutsView: View {
    @ObservedObject private var prefs = Preferences.shared

    private var schemeName: String {
        prefs.shortcuts == .safari ? String(localized: "Safari-style") : String(localized: "Chrome-style")
    }

    var body: some View {
        let groups = (NSApp.mainMenu.map(ShortcutList.groups(in:)) ?? []) + [ShortcutGroup(title: String(localized: "Mouse and Trackpad"), rows: ShortcutList.gestures)]
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Keys: \(schemeName)").font(.body).foregroundStyle(Theme.secondary)
                Button("Change…") { AppDelegate.showShortcutSetting() }.buttonStyle(QuietLinkStyle(font: .body))
                Spacer()
            }
            .padding(16)
            List {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.rows) { row in
                            HStack(spacing: 16) {
                                Text(verbatim: row.title)
                                Spacer()
                                Text(verbatim: row.keys).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}
