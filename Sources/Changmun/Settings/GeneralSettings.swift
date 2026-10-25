import AppKit
import SwiftUI

// MARK: General

struct GeneralSettings: View {
    @ObservedObject var prefs: Preferences
    @State private var isDefaultBrowser = false

    var body: some View {
        Form {
            Section("Search") {
                Picker("Search Engine", selection: $prefs.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                Toggle("Get search suggestions as you type", isOn: $prefs.searchSuggestions)
                    .help("What you type in the command bar is sent to your search engine to get suggestions. Nothing is sent in private windows.")
                Picker("On Startup", selection: $prefs.restoreTabs) {
                    Text("Reopen last session’s tabs").tag(true)
                    Text("Start with a new tab").tag(false)
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
            Section("Browser") {
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.downloadFolder
        if panel.runModal() == .OK, let url = panel.url { prefs.downloadFolder = url }
    }

    private func checkDefault() {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        isDefaultBrowser = handler?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func makeDefault() {
        for scheme in ["http", "https"] {
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { _ in
                DispatchQueue.main.async { checkDefault() }
            }
        }
    }
}
