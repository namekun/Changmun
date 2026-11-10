import AppKit

extension AppMenu {
    /// The Services submenu in the app menu, where macOS expects it, followed by its own separator.
    @MainActor
    static func addServices(to menu: NSMenu) {
        let title = String(localized: "Services")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let services = NSMenu(title: title)
        item.submenu = services
        menu.addItem(item)
        menu.addItem(.separator())
        NSApp?.servicesMenu = services
    }
}
