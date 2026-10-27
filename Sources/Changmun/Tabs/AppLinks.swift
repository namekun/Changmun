import AppKit

/// The three things a page's address for an app (claude://...) needs from the system, apart so that a test asks no one and opens nothing.
struct AppLinks {
    /// The name of the app that opens the address, if there is one.
    var appName: (URL) -> String?
    /// Asks the user whether the site may open the app; true for Open.
    var confirm: (_ site: String, _ app: String, _ url: URL) -> Bool
    var open: (URL) -> Void

    @MainActor static let system = AppLinks(
        appName: { url in NSWorkspace.shared.urlForApplication(toOpen: url).map { FileManager.default.displayName(atPath: $0.path) } },
        confirm: { site, app, url in
            let alert = NSAlert()
            alert.messageText = String(localized: "\(site) wants to open \(app)")
            alert.informativeText = String(url.absoluteString.prefix(200))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Open"))
            return alert.runModal() == .alertSecondButtonReturn
        },
        open: { NSWorkspace.shared.open($0) })
}
