import AppKit
import SwiftUI
import WebKit

/// An extension Changmun found or was given, loaded or not.
struct ExtensionSource: Identifiable, Hashable {
    enum Kind: Hashable { case safari, folder }

    var kind: Kind
    var path: String
    var id: String { path }
}

/// Safari web extensions installed on this Mac (each lives in an app as a `.appex`) and unpacked extension folders
/// the user added, loaded into one WebKit extension controller that every tab shares.
@available(macOS 15.4, *)
@MainActor
final class ExtensionHost: NSObject, ObservableObject {
    static let shared = ExtensionHost()

    struct Loaded: Identifiable {
        var source: ExtensionSource
        var context: WKWebExtensionContext
        var name: String
        var id: String { source.id }
    }

    let controller = WKWebExtensionController(configuration: .default())
    @Published private(set) var found: [ExtensionSource] = []
    @Published private(set) var loaded: [Loaded] = []
    @Published private(set) var failures: [String: String] = [:]
    /// Bumped when an extension's button changes (icon, badge, enabled).
    @Published private(set) var actionsChanged = 0
    /// The views extension buttons are drawn in, so popups can point at them.
    var anchors: [String: NSView] = [:]
    private var optionsWindows: [String: NSWindow] = [:]

    private override init() {
        super.init()
        controller.delegate = self
    }

    // MARK: Finding and loading

    func start() async {
        found = Self.installedSafariExtensions().map { ExtensionSource(kind: .safari, path: $0) }
            + Preferences.shared.extensionFolders.map { ExtensionSource(kind: .folder, path: $0) }
        for source in found where Preferences.shared.enabledExtensions.contains(source.path) {
            await load(source, askForPermissions: false)
        }
    }

    /// `pluginkit` knows every Safari web extension the system has registered.
    nonisolated static func installedSafariExtensions() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-mAvvv", "-p", "com.apple.Safari.web-extension"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return parsePaths(output)
    }

    nonisolated static func parsePaths(_ pluginkitOutput: String) -> [String] {
        pluginkitOutput.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("Path = ") else { return nil }
            return String(text.dropFirst("Path = ".count))
        }
    }

    func setEnabled(_ source: ExtensionSource, _ enabled: Bool) async {
        if enabled {
            await load(source, askForPermissions: true)
        } else if let index = loaded.firstIndex(where: { $0.id == source.id }) {
            try? controller.unload(loaded[index].context)
            loaded.remove(at: index)
            Preferences.shared.enabledExtensions.removeAll { $0 == source.path }
        }
    }

    func isLoaded(_ source: ExtensionSource) -> Bool { loaded.contains { $0.id == source.id } }

    private func load(_ source: ExtensionSource, askForPermissions: Bool) async {
        guard !isLoaded(source) else { return }
        do {
            let url = URL(fileURLWithPath: source.path)
            let webExtension: WKWebExtension
            switch source.kind {
            case .safari:
                guard let bundle = Bundle(url: url) else { throw CocoaError(.fileNoSuchFile) }
                webExtension = try await WKWebExtension(appExtensionBundle: bundle)
            case .folder:
                webExtension = try await WKWebExtension(resourceBaseURL: url)
            }
            let context = WKWebExtensionContext(for: webExtension)
            // A stable identity keeps the extension's storage across launches.
            context.uniqueIdentifier = Self.identifier(for: source.path)
            context.isInspectable = true
            // Grant what the user approved before; anything an update added is asked about first.
            let requested = Self.permissionNames(webExtension)
            let approved = Set(Preferences.shared.extensionGrants[source.path] ?? [])
            let added = requested.subtracting(approved)
            var granted = approved
            if askForPermissions || !added.isEmpty {
                if confirmPermissions(for: webExtension, only: askForPermissions ? nil : added) {
                    granted = requested
                    Preferences.shared.extensionGrants[source.path] = granted.sorted()
                } else if askForPermissions {
                    return
                }
            }
            for permission in webExtension.requestedPermissions where granted.contains(permission.rawValue) {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            for pattern in webExtension.allRequestedMatchPatterns where granted.contains(pattern.string) {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            try controller.load(context)
            try? await context.loadBackgroundContent()
            loaded.append(Loaded(source: source, context: context, name: webExtension.displayName ?? url.lastPathComponent))
            failures[source.path] = nil
            if !Preferences.shared.enabledExtensions.contains(source.path) { Preferences.shared.enabledExtensions.append(source.path) }
            for tab in Browser.shared.tabs { controller.didOpenTab(tab) }
            if let active = Browser.shared.active { controller.didActivateTab(active) }
        } catch {
            failures[source.path] = error.localizedDescription
        }
    }

    nonisolated static func identifier(for path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "changmun-" + String(hash, radix: 16)
    }

    static func permissionNames(_ webExtension: WKWebExtension) -> Set<String> {
        Set(webExtension.requestedPermissions.map(\.rawValue)).union(webExtension.allRequestedMatchPatterns.map(\.string))
    }

    /// What the extension asks for (or, after an update, what it newly asks for), in words, before it gets it.
    private func confirmPermissions(for webExtension: WKWebExtension, only added: Set<String>? = nil) -> Bool {
        let hosts = webExtension.allRequestedMatchPatterns.map(\.string).filter { added?.contains($0) ?? true }.sorted()
        let alert = NSAlert()
        alert.messageText = added == nil ? "'\(webExtension.displayName ?? "확장")'을(를) 켤까요?"
            : "'\(webExtension.displayName ?? "확장")'이(가) 업데이트되며 권한을 더 요청해요"
        var lines: [String] = []
        if hosts.contains(where: { $0 == "<all_urls>" || $0.hasPrefix("*://*/") }) {
            lines.append("모든 웹사이트의 내용을 읽고 바꿀 수 있어요.")
        } else if !hosts.isEmpty {
            lines.append("이 사이트들의 내용을 읽고 바꿀 수 있어요: " + hosts.prefix(6).joined(separator: ", ") + (hosts.count > 6 ? " 외 \(hosts.count - 6)곳" : ""))
        }
        let permissions = webExtension.requestedPermissions.map(\.rawValue).filter { added?.contains($0) ?? true }.sorted()
        if !permissions.isEmpty { lines.append("권한: " + permissions.joined(separator: ", ")) }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: added == nil ? "켜기" : "허용")
        alert.addButton(withTitle: added == nil ? "취소" : "이전 권한만 쓰기")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Buttons

    func action(for item: Loaded) -> WKWebExtension.Action? {
        item.context.action(for: Browser.shared.active)
    }

    func performAction(_ item: Loaded) {
        item.context.performAction(for: Browser.shared.active)
    }

    func addFolder(_ url: URL) async {
        let path = url.path
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else {
            failures[path] = "manifest.json이 없는 폴더예요"
            return
        }
        if !Preferences.shared.extensionFolders.contains(path) { Preferences.shared.extensionFolders.append(path) }
        let source = ExtensionSource(kind: .folder, path: path)
        if !found.contains(source) { found.append(source) }
        await load(source, askForPermissions: true)
    }

    func removeFolder(_ source: ExtensionSource) async {
        await setEnabled(source, false)
        Preferences.shared.extensionFolders.removeAll { $0 == source.path }
        found.removeAll { $0 == source }
    }

    func openOptions(_ item: Loaded) {
        guard let url = item.context.optionsPageURL, let configuration = item.context.webViewConfiguration else { return }
        if let window = optionsWindows[item.id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 560), configuration: configuration)
        webView.load(URLRequest(url: url))
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = item.name
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()
        optionsWindows[item.id] = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Telling extensions about tabs

    func tabOpened(_ tab: Tab) { if !loaded.isEmpty { controller.didOpenTab(tab) } }
    func tabClosed(_ tab: Tab) { if !loaded.isEmpty { controller.didCloseTab(tab) } }
    func tabActivated(_ tab: Tab, previous: Tab?) { if !loaded.isEmpty { controller.didActivateTab(tab, previousActiveTab: previous) } }
    func tabMoved(_ tab: Tab, from index: Int) { if !loaded.isEmpty { controller.didMoveTab(tab, from: index, in: ExtensionWindow.shared) } }
    func tabChanged(_ tab: Tab) { if !loaded.isEmpty { controller.didChangeTabProperties([.URL, .title, .loading], for: tab) } }
}

// MARK: Delegate

@available(macOS 15.4, *)
extension ExtensionHost: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [ExtensionWindow.shared]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        ExtensionWindow.shared
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        // Extensions open web pages, not local files.
        let url = configuration.url.flatMap { $0.isFileURL ? nil : $0 }
        let tab = Browser.shared.openTab(url: url, activate: configuration.shouldBeActive)
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        // One window: its tabs open here.
        for url in configuration.tabURLs where !url.isFileURL { Browser.shared.openTab(url: url) }
        completionHandler(ExtensionWindow.shared, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let item = loaded.first(where: { $0.context === extensionContext }) { openOptions(item) }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let allowed = ask("'\(extensionContext.webExtension.displayName ?? "확장")'이(가) 권한을 더 요청해요",
                          permissions.map(\.rawValue).sorted().joined(separator: ", "))
        completionHandler(allowed ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let allowed = ask("'\(extensionContext.webExtension.displayName ?? "확장")'이(가) 이 사이트에 접근하려고 해요",
                          matchPatterns.map(\.string).sorted().joined(separator: "\n"))
        completionHandler(allowed ? matchPatterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let allowed = ask("'\(extensionContext.webExtension.displayName ?? "확장")'이(가) 이 사이트에 접근하려고 해요",
                          urls.compactMap { $0.host() }.sorted().joined(separator: "\n"))
        completionHandler(allowed ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        actionsChanged += 1
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover else {
            completionHandler(nil)
            return
        }
        let id = loaded.first { $0.context === context }?.id
        if let anchor = id.flatMap({ anchors[$0] }), anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = NSApp.windows.first(where: { $0 is BrowserWindow })?.contentView {
            popover.show(relativeTo: NSRect(x: 20, y: 20, width: 1, height: 1), of: content, preferredEdge: .maxY)
        }
        completionHandler(nil)
    }

    private func ask(_ message: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "허용")
        alert.addButton(withTitle: "거부")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: Tabs and the window, as extensions see them

@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    static let shared = ExtensionWindow()

    private var window: NSWindow? { NSApp.windows.first { $0 is BrowserWindow } }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { Browser.shared.tabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { Browser.shared.active }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isMiniaturized ? .minimized : .normal
    }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .null }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
extension Tab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { ExtensionWindow.shared }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { Browser.shared.tabs.firstIndex { $0 === self } ?? NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { title }
    func url(for context: WKWebExtensionContext) -> URL? { url }
    func isSelected(for context: WKWebExtensionContext) -> Bool { Browser.shared.activeID == id }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(webView?.pageZoom ?? 1) }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        Browser.shared.activate(id)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        Browser.shared.close(id)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard !url.isFileURL else { return completionHandler(CocoaError(.fileReadNoPermission)) }
        load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView?.reloadFromOrigin() } else { webView?.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goForward()
        completionHandler(nil)
    }
}

// MARK: Sidebar buttons

/// Records the AppKit view a SwiftUI button is drawn in, so a popover can point at it.
struct PopoverAnchor: NSViewRepresentable {
    let record: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { record(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@available(macOS 15.4, *)
struct ExtensionButtons: View {
    @ObservedObject var host = ExtensionHost.shared
    @ObservedObject var browser: Browser

    var body: some View {
        HStack(spacing: 2) {
            ForEach(host.loaded) { item in
                ExtensionButton(item: item, action: host.action(for: item), changes: host.actionsChanged)
            }
        }
        .id(browser.activeID)
    }
}

@available(macOS 15.4, *)
struct ExtensionButton: View {
    let item: ExtensionHost.Loaded
    let action: WKWebExtension.Action?
    let changes: Int
    @State private var hover = false

    var body: some View {
        Button { ExtensionHost.shared.performAction(item) } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let icon = action?.icon(for: CGSize(width: 16, height: 16)) ?? item.context.webExtension.icon(for: CGSize(width: 16, height: 16)) {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                    }
                }
                .frame(width: 16, height: 16)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? Theme.field : .clear))
                if let badge = action?.badgeText, !badge.isEmpty {
                    // Nunsseop's badge: a white disc with a black count.
                    Text(badge)
                        .font(.system(size: 8, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 3.5)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(Capsule().fill(Theme.primary))
                        .offset(x: 3, y: -2)
                }
            }
            .opacity(action?.isEnabled == false ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(action?.label.isEmpty == false ? action!.label : item.name)
        .background(PopoverAnchor { ExtensionHost.shared.anchors[item.id] = $0 })
        .contextMenu {
            if item.context.optionsPageURL != nil { Button("확장 설정") { ExtensionHost.shared.openOptions(item) } }
            Button("끄기") { Task { await ExtensionHost.shared.setEnabled(item.source, false) } }
        }
    }
}
