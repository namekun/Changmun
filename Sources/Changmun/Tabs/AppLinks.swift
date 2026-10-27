import AppKit

/// The three things a page's address for an app (claude://...) needs from the system, apart so that a test asks no one and opens nothing.
struct AppLinks {
    /// The name of the app that opens the address, if there is one.
    var appName: (URL) -> String?
    /// Asks the user, in a sheet on the window, whether the site may open the app; true for Open. No window, or one already
    /// showing a sheet, is a no.
    var confirm: @MainActor (_ site: String, _ app: String, _ url: URL, _ window: NSWindow?) async -> Bool
    var open: (URL) -> Void

    @MainActor static let system = AppLinks(
        appName: { url in NSWorkspace.shared.urlForApplication(toOpen: url).map { FileManager.default.displayName(atPath: $0.path) } },
        confirm: { site, app, url, window in
            guard let window, window.attachedSheet == nil else { return false }
            let alert = NSAlert()
            alert.messageText = String(localized: "\(site) wants to open \(app)")
            alert.informativeText = String(url.absoluteString.prefix(200))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Open"))
            return await alert.beginSheetModal(for: window) == .alertSecondButtonReturn
        },
        open: { NSWorkspace.shared.open($0) })
}
