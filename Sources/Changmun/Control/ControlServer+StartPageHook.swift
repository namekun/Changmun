import AppKit
import Foundation
import Network

/// Seeds standing in for a profile with something in it, which the test copy's start page shows; what was put there is remembered to be taken away again.
@MainActor
enum StartPageTestSeed {
    static var history: [String] = []
    static var favorites: [(url: String, folder: String)] = []
    static var reading: [String] = []

    /// A plain icon (a coloured square with the first letter) for a host, kept as a site's icon so the tiles have pictures without asking any site.
    static func icon(for address: String, size: CGFloat) {
        guard let host = URL(string: address)?.host() else { return }
        let colors: [NSColor] = [.black, .systemRed, .systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal]
        let color = colors[StartIconStyle.colorIndex(for: address, count: colors.count)]
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.08, dy: size * 0.08), xRadius: size * 0.2, yRadius: size * 0.2).fill()
            let text = NSAttributedString(string: StartIconStyle.letter(for: address), attributes: [.font: NSFont.systemFont(ofSize: size * 0.5, weight: .bold), .foregroundColor: NSColor.white])
            let box = text.size()
            text.draw(at: NSPoint(x: (size - box.width) / 2, y: (size - box.height) / 2))
            return true
        }
        Browser.favicons[host] = image
        Browser.storeIcon(image, host: host)
    }

    static func clear(in browser: Browser) {
        for url in history { Library.shared.deleteHistory(url: url) }
        for item in favorites { Library.shared.removeBookmark(url: item.url, folder: item.folder) }
        for url in reading { Library.shared.removeFromReadingList(url: url) }
        history = []
        favorites = []
        reading = []
        browser.closedTabs.removeAll()
    }
}

extension ControlServer {
    /// Tests only: the start page put into a state to look at. "appearance" is system, light or dark; "reset" puts the settings back to the defaults;
    /// "style" is dashboard, quiet or aiFirst; "sections" lists the sections that are on, in order, for that style ("options": {"favorites": 1} sets
    /// their options); "background" ({"kind", "colorID", "customHex", "imageFile", "blur", "dim"}), "newTab" and "address" set those; "private" opens a
    /// private window; "noTabs" closes the tabs of the space shown so that the page shows; "seed" ({"icons", "favorites": [[url, title]],
    /// "history": [[url, title, visits, minutesAgo]], "closed": [[url, title, minutesAgo]], "reading": [[url, title, days, read]], "tabs": [url]}) fills the
    /// profile, and "clear" takes what was seeded away again; "popover" ({"open": true, "expand": "favorites"}) opens or closes the Customize popover;
    /// "empty" shows the page of a fresh profile, "ai" is ready or none (what the AI chips go by). The answer says how the page stands.
    func handleStartPageTestRequest(_ request: HTTPRequest, on connection: NWConnection) -> Bool {
        guard Headless.isTestCopy, request.method == "POST", request.path == "/start-page",
              let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return false }
        Task { @MainActor in
            let store = StartPageStore.shared
            if body["private"] as? Bool == true { BrowserWindow.open(private: true) }
            guard let browser = Browser.current else { return self.respond(connection, status: "404 Not Found", body: ["error": "no window"]) }
            if let empty = body["empty"] as? Bool { StartPageUI.showsAsEmpty = empty }
            if let ai = body["ai"] as? String {
                AIAvailability.detector = { ai == "ready" ? .ready : .none }
                ChatStore.shared.refreshAvailability()
            }
            browser.commandBar = nil
            if body["clear"] as? Bool == true { StartPageTestSeed.clear(in: browser) }
            if body["reset"] as? Bool == true { store.reset(); StartHiddenItems.shared.showAll() }
            if let name = body["appearance"] as? String, let appearance = AppAppearance(rawValue: name) { Preferences.shared.appearance = appearance }
            if let name = body["style"] as? String, let style = StartStyle(rawValue: name) { store.setStyle(style) }
            if let names = body["sections"] as? [String] {
                let on = names.compactMap(StartSection.init(rawValue:))
                store.update { settings in
                    let rest = settings.current.items.map(\.section).filter { !on.contains($0) }
                    let old = settings.current
                    let items = (on + rest).map { section in StartItem(section: section, enabled: on.contains(section), option: old.item(section)?.option ?? 0) }
                    settings = settings.with(layout: StartLayout(items: items), for: settings.style)
                }
            }
            for (name, option) in body["options"] as? [String: Int] ?? [:] { if let section = StartSection(rawValue: name) { store.setOption(section, option) } }
            if let background = body["background"] as? [String: Any] {
                var next = store.settings.background
                if let kind = (background["kind"] as? String).flatMap(StartBackgroundKind.init(rawValue:)) { next.kind = kind }
                if let id = background["colorID"] as? String { next.colorID = id }
                if let hex = background["customHex"] as? String { next.customHex = hex }
                if background.keys.contains("imageFile") { next.imageFile = background["imageFile"] as? String }
                if let blur = background["blur"] as? Double { next.blur = blur }
                if let dim = background["dim"] as? Double { next.dim = dim }
                store.setBackground(next)
            }
            if let name = body["newTab"] as? String, let opens = NewTabOpens(rawValue: name) { store.setNewTab(opens) }
            if let address = body["address"] as? String { store.setAddress(address) }
            if let seed = body["seed"] as? [String: Any] {
                let icons = seed["icons"] as? Bool ?? true
                for page in seed["favorites"] as? [[String]] ?? [] where page.count >= 2 {
                    Library.shared.addBookmark(url: page[0], title: page[1], folder: browser.favoritesFolder)
                    StartPageTestSeed.favorites.append((page[0], browser.favoritesFolder))
                    if icons { StartPageTestSeed.icon(for: page[0], size: 128) }
                }
                for page in seed["history"] as? [[Any]] ?? [] where page.count >= 4 {
                    guard let url = page[0] as? String, let title = page[1] as? String, let visits = page[2] as? Int, let ago = page[3] as? Double else { continue }
                    for visit in 0..<max(visits, 1) { Library.shared.recordVisit(url: url, title: title, at: Date().addingTimeInterval(-ago * 60 - Double(max(visits, 1) - 1 - visit))) }
                    StartPageTestSeed.history.append(url)
                    if icons { StartPageTestSeed.icon(for: url, size: 128) }
                }
                for page in seed["closed"] as? [[Any]] ?? [] where page.count >= 3 {
                    guard let url = page[0] as? String, let title = page[1] as? String, let ago = page[2] as? Double else { continue }
                    var closed = Browser.ClosedTab(url: URL(string: url), title: title, customTitle: nil, state: nil, index: 0, bookmarkKey: nil, group: nil, space: browser.spaceID)
                    closed.closedAt = Date().addingTimeInterval(-ago * 60)
                    browser.closedTabs.append(closed)
                    if icons { StartPageTestSeed.icon(for: url, size: 128) }
                }
                for page in seed["reading"] as? [[Any]] ?? [] where page.count >= 4 {
                    guard let url = page[0] as? String, let title = page[1] as? String, let days = page[2] as? Double else { continue }
                    Library.shared.addToReadingList(url: url, title: title, added: Date().addingTimeInterval(-days * 86400))
                    if page[3] as? Bool == true { Library.shared.markReadingItem(url: url, read: true) }
                    StartPageTestSeed.reading.append(ReadingList.key(for: url) ?? url)
                    if icons { StartPageTestSeed.icon(for: url, size: 128) }
                }
                for url in seed["tabs"] as? [String] ?? [] { browser.openTab(url: URL(string: url), activate: false) }
            }
            if body["noTabs"] as? Bool == true { for tab in browser.spaceTabs { browser.close(tab.id, remember: false) } }
            if let popover = body["popover"] as? [String: Any] {
                let open = popover["open"] as? Bool ?? true
                var info: [String: Any] = ["open": open]
                if let expand = popover["expand"] as? String { info["expand"] = expand }
                NotificationCenter.default.post(name: StartPageUI.customizeRequested, object: browser, userInfo: info)
            }
            try? await Task.sleep(for: .milliseconds(700))
            let settings = store.settings
            self.respond(connection, status: "200 OK", body: [
                "style": settings.style.rawValue, "sections": settings.current.shown.map(\.section.rawValue), "background": settings.background.kind.rawValue,
                "newTab": settings.newTab.rawValue, "tabs": browser.spaceTabs.count, "closed": browser.closedTabs.count, "private": browser.isPrivate,
                "shown": StartPageUI.isShown(in: browser),
            ])
        }
        return true
    }
}
