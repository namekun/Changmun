import AppKit
import SwiftUI

// MARK: Tabs

struct TabSettings: View {
    @ObservedObject var prefs: Preferences
    @State private var newHost = ""

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Play video in Picture in Picture when you switch to another tab", isOn: $prefs.autoPictureInPicture)
                Picker("Sleep inactive tabs", selection: $prefs.sleepMinutes) {
                    Text("Off").tag(0)
                    Text("After 10 minutes").tag(10)
                    Text("After 20 minutes").tag(20)
                    Text("After 1 hour").tag(60)
                }
                Caption(text: "Sleeping tabs free their memory and reload with their history when you go back to them. When memory runs low, tabs sleep regardless of this setting.")
            }
            Section("Sites that never sleep") {
                ForEach(prefs.neverSleepHosts, id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Button(role: .destructive) { prefs.neverSleepHosts.removeAll { $0 == host } } label: { Image(systemName: "minus.circle") }.accessibilityLabel(String(localized: "Remove \(host)"))
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("e.g. music.youtube.com", text: $newHost)
                        .onSubmit(addHost)
                    Button("Add", action: addHost).disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let current = Browser.recent?.active?.url?.host(), !prefs.neverSleepHosts.contains(current) {
                        Button("Current Site") { prefs.neverSleepHosts.append(current) }
                    }
                }
                Caption(text: "For sites you keep open, like music or meetings. Subdomains are included.")
            }
            Section("Tab Cleanup") {
                Toggle("Automatically put new tabs in the right group", isOn: $prefs.groupNewTabs)
                Picker("Archive tabs you haven’t viewed in a while", selection: $prefs.archiveHours) {
                    Text("Off").tag(0)
                    Text("After 12 hours").tag(12)
                    Text("After 1 day").tag(24)
                    Text("After 1 week").tag(168)
                    Text("After 30 days").tag(720)
                }
                Caption(text: "The Tidy button in the sidebar groups tabs that aren’t in a group yet. With Apple Intelligence on, tabs are grouped by topic on this Mac; otherwise tabs from the same site, or opened from one another, are grouped together. You can reopen archived tabs from History › Archived Tabs.")
            }
        }
        .formStyle(.grouped)
    }

    private func addHost() {
        let host = newHost.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
        guard !host.isEmpty, !prefs.neverSleepHosts.contains(host) else { return }
        prefs.neverSleepHosts.append(host)
        newHost = ""
    }
}
