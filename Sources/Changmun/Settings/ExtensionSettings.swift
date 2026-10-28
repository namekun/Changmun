import AppKit
import SwiftUI

// MARK: Extensions

struct ExtensionSettings: View {
    var body: some View {
        if #available(macOS 15.4, *) {
            ExtensionList(host: ExtensionHost.shared, blockers: ContentBlockerHost.shared)
        } else {
            Form {
                Caption(text: "Web extensions are available on macOS 15.4 or later.")
                ContentBlockerSection(host: ContentBlockerHost.shared)
            }
            .formStyle(.grouped)
        }
    }
}

/// Safari content blockers (Unicorn, AdGuard…): their rules, applied alongside the built-in ad blocking.
struct ContentBlockerSection: View {
    @ObservedObject var host: ContentBlockerHost

    var body: some View {
        Section("Safari Content Blockers") {
            if host.blockers.isEmpty {
                Caption(text: "No content blockers installed.")
            }
            ForEach(host.blockers) { blocker in
                HStack(spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled").frame(width: 24, height: 24).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(blocker.name).lineLimit(1)
                        if let status = host.status[blocker.bundleID] {
                            Text(status).font(.system(size: 11)).foregroundStyle(status.hasPrefix("[ERROR]") ? .red : .secondary).lineLimit(3)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { host.isEnabled(blocker) }, set: { on in Task { await host.setEnabled(blocker, on) } }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(blocker.name)
                }
            }
            Caption(text: "Reads the rules saved by the blocker app. The first time you turn one on, macOS asks whether Changmun may access another app’s data. If you change the rules in the blocker app, they take effect the next time you launch Changmun.")
        }
    }
}

@available(macOS 15.4, *)
struct ExtensionList: View {
    @ObservedObject var host: ExtensionHost
    let blockers: ContentBlockerHost
    @State private var storeAddress = ""

    var body: some View {
        Form {
            Section {
                if host.found.isEmpty {
                    Caption(text: "No extensions yet. You can install Safari extensions from the App Store or extensions from the Chrome Web Store.")
                }
                ForEach(host.found) { source in
                    ExtensionRow(host: host, source: source)
                }
            }
            Section("Install") {
                HStack {
                    Button("Find Safari Extensions on the App Store…") { NSWorkspace.shared.open(SafariExtensionGallery.url) }
                    Spacer()
                    Button("Load from Folder…", action: chooseFolder)
                }
                HStack {
                    TextField("Chrome Web Store URL or extension ID", text: $storeAddress)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(installFromStore)
                    if let id = ChromeWebStore.extensionID(from: storeAddress), host.installing.contains(id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Install", action: installFromStore).disabled(ChromeWebStore.extensionID(from: storeAddress) == nil)
                    }
                }
                if let error = host.storeErrors[ChromeWebStore.extensionID(from: storeAddress) ?? storeAddress] {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }
                Caption(text: "Safari extensions you get from the App Store show up here automatically. When you open a Chrome Web Store page, an “Add to Changmun” button appears over the page. Some features, such as talking to native apps, may not work.")
            }
            ContentBlockerSection(host: blockers)
        }
        .formStyle(.grouped)
        .onAppear {
            host.rescan()
            blockers.rescan()
        }
    }

    private func installFromStore() {
        guard ChromeWebStore.extensionID(from: storeAddress) != nil else { return }
        let input = storeAddress
        Task { await host.installFromChromeWebStore(input) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose an extension folder that contains manifest.json")
        if panel.runModal() == .OK, let url = panel.url { Task { await host.addFolder(url) } }
    }
}

@available(macOS 15.4, *)
struct ExtensionRow: View {
    @ObservedObject var host: ExtensionHost
    let source: ExtensionSource

    var body: some View {
        let item = host.loaded.first { $0.id == source.id }
        HStack(spacing: 10) {
            if let icon = item?.context.webExtension.icon(for: CGSize(width: 24, height: 24)) {
                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
            } else {
                Image(systemName: "puzzlepiece.extension").frame(width: 24, height: 24).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item?.name ?? Self.name(source)).lineLimit(1)
                if let failure = host.failures[source.path] {
                    Text(failure).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text(source.kind == .safari ? String(localized: "Safari Extension")
                         : ExtensionHost.isFromChromeWebStore(source) ? String(localized: "Chrome Web Store")
                         : source.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let item, item.context.optionsPageURL != nil {
                Button("Settings") { host.openOptions(item) }.buttonStyle(.borderless)
            }
            if source.kind == .folder {
                Button { Task { await host.removeFolder(source) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "Remove \(item?.name ?? Self.name(source))"))
            }
            Toggle("", isOn: Binding(get: { host.isLoaded(source) }, set: { on in Task { await host.setEnabled(source, on) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(item?.name ?? Self.name(source))
        }
    }

    /// Before loading, the extension's name is the app that carries it (or the folder).
    static func name(_ source: ExtensionSource) -> String {
        let url = URL(fileURLWithPath: source.path)
        if source.kind == .safari, let bundle = Bundle(url: url) {
            return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        }
        return url.lastPathComponent
    }
}
