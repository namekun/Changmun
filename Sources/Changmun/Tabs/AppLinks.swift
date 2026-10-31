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
            await Dialog.present(in: window, spec(site: site, app: app, url: url), whenBusy: .refuse)?.button == 1
        },
        open: { NSWorkspace.shared.open($0) })

    /// The question: the app and the site that asks come from the system and the page's origin, cleaned and cut; Cancel is what Return does.
    @MainActor static func spec(site: String, app: String, url: URL) -> DialogSpec {
        // The whole address, wrapped and scrollable; what does not fit is said, never left out unsaid.
        DialogSpec(title: String(localized: "Open \(DialogSpec.name(app))?"),
                   message: String(localized: "\(DialogSpec.host(site)) wants to open the app."),
                   detail: .text(Approvals.shownWithNote(url.absoluteString, limit: 1000).text),
                   buttons: [DialogButton(title: String(localized: "Cancel"), role: .cancel, isDefault: true), DialogButton(title: String(localized: "Open"))])
    }
}
