import AppKit
import UniformTypeIdentifiers

/// What ties the browser to the Mac around it: the Dock menu, sharing a page, and bookmarks as a file.
extension AppDelegate {
    /// The window the menu's commands are for (see `AppDelegate.current`).
    private var systemBrowser: Browser? { ChatPopOut.shared.keyBrowser() ?? Browser.current }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [(String(localized: "New Window"), #selector(newWindow(_:))),
                                (String(localized: "New Private Window"), #selector(newPrivateWindow(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        return menu
    }

    @objc func sharePage(_ sender: Any?) {
        guard !Headless.isOn, let browser = systemBrowser, let tab = browser.active, SharePage.canShare(isStart: tab.isStart, url: tab.url),
              let url = tab.url, let view = browser.window?.contentView else { return }
        SharePage.show(title: tab.title, url: url, in: view)
    }

    @objc func exportBookmarks(_ sender: Any?) {
        guard !Headless.isOn else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = String(localized: "Changmun Bookmarks") + ".html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let library = Library.shared
        let main = Space.defaultID
        let spaces = SpaceStore.shared.spaces
        let html = BookmarkFile.export(
            favorites: library.favorites(),
            spaceFavorites: spaces.filter { $0.id != main }.map { ($0.name, library.favorites(in: $0.favoritesFolder)) },
            sources: Library.groupBySource(library.folders(), names: library.folderNames(), section: { $0 }),
            readingList: library.readingList())
        do {
            try Data(html.utf8).write(to: url, options: .atomic)
            systemBrowser?.flashStatus(String(localized: "Exported bookmarks to \(url.lastPathComponent)"))
        } catch {
            systemBrowser?.flashStatus(String(localized: "Couldn’t save the bookmarks: \(error.localizedDescription)"))
        }
    }

    @objc func importBookmarksFromFile(_ sender: Any?) {
        guard !Headless.isOn else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let browser = systemBrowser
        Task.detached {
            let message: String
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                // Refused by its size before it is read: a file that big is not a bookmark file.
                let outcome = size > BookmarkFile.maxFileSize ? BookmarkFile.Outcome.tooLarge : try BookmarkFile.importBookmarks(from: Data(contentsOf: url))
                switch outcome {
                case .imported(let bookmarks, let readingList):
                    var report = ImportReport(source: url.lastPathComponent)
                    report.bookmarks = bookmarks
                    report.readingList = readingList
                    message = report.summary
                case .nothingFound: message = String(localized: "No bookmarks found in that file")
                case .tooLarge: message = String(localized: "That file is too large to be a bookmark file")
                }
            } catch {
                message = String(localized: "Couldn’t read that file: \(error.localizedDescription)")
            }
            await MainActor.run { browser?.flashStatus(message) }
        }
    }
}

/// Sharing the page in front through the system's share menu.
@MainActor
enum SharePage {
    /// Kept while its menu is up.
    private static var picker: NSSharingServicePicker?

    /// A web page that is not a start tab: what a start tab shows is not an address to give anyone.
    nonisolated static func canShare(isStart: Bool, url: URL?) -> Bool {
        !isStart && ["http", "https"].contains(url?.scheme?.lowercased())
    }

    /// The menu opens under the top edge of the window, where the toolbar is.
    static func show(title: String, url: URL, in view: NSView) {
        let item = NSItemProvider(object: url as NSURL)
        item.suggestedName = title
        let picker = NSSharingServicePicker(items: [item])
        self.picker = picker
        let strip = NSRect(x: view.bounds.midX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY - 1, width: 1, height: 1)
        picker.show(relativeTo: strip, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }
}
