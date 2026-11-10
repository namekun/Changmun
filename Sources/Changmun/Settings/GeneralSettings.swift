import AppKit
import SwiftUI

// MARK: General

/// Whether Changmun is the browser that opens web links, and the system's question that makes it so.
enum DefaultBrowser {
    static var isSet: Bool {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        return handler?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// `then` runs once the system has answered.
    static func make(then: @escaping @MainActor () -> Void) {
        // Changing the default browser asks the user in a system dialog: never from a headless app.
        guard !Headless.isOn else { return }
        for scheme in ["http", "https"] {
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { _ in
                DispatchQueue.main.async { then() }
            }
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject var prefs: Preferences
    @State private var isDefaultBrowser = false

    /// Whether Claude Code is there to translate with (looked at again whenever a preference, such as its path, changes).
    private var claudeReady: Bool { AIAvailability.detector() == .ready }

    var body: some View {
        Form {
            Section("Search") {
                Picker("Search Engine", selection: $prefs.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                Toggle("Get search suggestions as you type", isOn: $prefs.searchSuggestions)
                    .help("What you type in the search bar is sent to your search engine to get suggestions. Nothing is sent in private windows.")
                Picker("On Startup", selection: $prefs.restoreTabs) {
                    Text("Reopen last session’s tabs").tag(true)
                    Text("Start with a new tab").tag(false)
                }
                if !prefs.restoreTabs {
                    Caption(text: "Tabs are not brought back after an update restarts Changmun either.")
                }
            }
            Section("Downloads") {
                LabeledContent("Downloads Folder") {
                    HStack {
                        Text(prefs.downloadFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                        Button("Change…", action: chooseFolder)
                    }
                }
                Toggle("Ask where to save each download", isOn: $prefs.askWhereToSave)
            }
            Section("Translation") {
                Picker("Translate pages with", selection: $prefs.translationEngine) {
                    Text("On this Mac").tag(TranslationEngine.onDevice)
                    Text("Claude").tag(TranslationEngine.claude).disabled(!claudeReady)
                }
                if prefs.translationEngine == .claude {
                    Picker("Model", selection: $prefs.translationModel) {
                        Text("Haiku (fastest)").tag("haiku")
                        Text("Sonnet (fast and balanced)").tag("sonnet")
                        Text("Opus (smartest, slower)").tag("opus")
                    }
                    Caption(text: "The text of each page you translate is sent to Anthropic and counts against your Claude subscription, or your API key if one is set. Pages in private windows, in profiles other than the one in front, and with a password or payment field are never sent.")
                } else {
                    Caption(text: "The text of a page stays on this Mac. It is translated with the models of macOS, which needs macOS 26 or later.")
                }
                Caption(text: "Sites you turned “Keep translating this site” on for stay here. Their pages are translated as they open. With Claude, the text of each of those pages is sent to Anthropic automatically.")
                ForEach(prefs.translatedHosts, id: \.self) { host in
                    HStack {
                        Text(host).lineLimit(1)
                        Spacer()
                        Caption(text: "Kept translating")
                        Button { prefs.translatedHosts.removeAll { $0 == host } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(String(localized: "Remove \(host)"))
                    }
                }
                if !claudeReady {
                    Caption(text: "Claude needs Claude Code on this Mac. Install it, or enter where it is in Settings › AI.")
                }
            }
            Section("Browser") {
                Toggle("Quit when the last window is closed", isOn: $prefs.quitWhenLastWindowCloses)
                Caption(text: "Turned off, Changmun stays open without a window, like Safari. Clicking its Dock icon or choosing New Window reopens the last session.")
                LabeledContent("Default Browser") {
                    if isDefaultBrowser {
                        Text("Changmun is your default browser").foregroundStyle(.secondary)
                    } else {
                        Button("Make Default Browser", action: makeDefault)
                    }
                }
                LabeledContent("Other Browsers") {
                    Button("Import Bookmarks, History, and Passwords…") {
                        let browser = Browser.recent ?? BrowserWindow.open()
                        browser.showOnboarding = true
                        browser.window?.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: checkDefault)
    }

    private func chooseFolder() {
        // A headless app has no one to choose, and a panel would come up on the screen of whoever is working.
        guard !Headless.isOn else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.downloadFolder
        if panel.runModal() == .OK, let url = panel.url { prefs.downloadFolder = url }
    }

    private func checkDefault() { isDefaultBrowser = DefaultBrowser.isSet }

    private func makeDefault() { DefaultBrowser.make { checkDefault() } }
}
