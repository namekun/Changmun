import AppKit
import SwiftUI

// MARK: Advanced

struct AdvancedSettings: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        Form {
            Section {
                Picker("Shortcuts", selection: $prefs.shortcuts) {
                    Text("Safari-style").tag(ShortcutScheme.safari)
                    Text("Chrome-style").tag(ShortcutScheme.chrome)
                }
                .pickerStyle(.segmented)
                Caption(text: prefs.shortcuts == .safari
                        ? "Sidebar ⌘⇧L · Hard Reload ⌥⌘R · Console ⌥⌘C · Downloads ⌥⌘L"
                        : "Sidebar ⌘S · Hard Reload ⌘⇧R · Console ⌥⌘J · Downloads ⌘⇧J · Move Between Tabs ⌥⌘← ⌥⌘→")
            }
            Section {
                Toggle("Developer Mode", isOn: $prefs.developerMode)
                Caption(text: "When on, the address bar shows the full address by default. You can open the Web Inspector any time with F12 (Network tab) or ⌥⌘I.")
            }
            Section {
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)
                Toggle("Download and install updates automatically", isOn: $updates.automaticallyDownloads)
                    .disabled(!updates.allowsAutomaticDownloads)
                Caption(text: "Changmun fetches a short list of releases from GitHub Pages, which sees the app name and version in the request. Nothing about you or your Mac is sent, and an update is installed only if it is signed by the developer. To check now, choose Changmun › Check for Updates…")
            }
        }
        .formStyle(.grouped)
    }
}
