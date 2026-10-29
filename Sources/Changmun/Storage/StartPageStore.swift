import Combine
import Foundation

/// The start page's settings, kept in the user defaults as one JSON value and changed only through `update` and `reset`.
@MainActor
final class StartPageStore: ObservableObject {
    static let shared = StartPageStore()
    static let defaultsKey = "startPageSettings"

    @Published private(set) var settings: StartPageSettings
    private let defaults: UserDefaults
    /// Where the background picture's copy is kept (a test has a folder of its own), and how long a copy that was let go of waits to be deleted.
    let folder: URL
    private let undoWindow: Duration

    init(defaults: UserDefaults = .standard, folder: URL = StartPageFiles.folder(), undoWindow: Duration = .seconds(10)) {
        self.defaults = defaults
        self.folder = folder
        self.undoWindow = undoWindow
        if let data = defaults.data(forKey: Self.defaultsKey), let stored = try? JSONDecoder().decode(StartPageSettings.self, from: data) {
            settings = stored.normalized()
        } else {
            settings = .default
        }
    }

    func update(_ change: (inout StartPageSettings) -> Void) {
        var copy = settings
        change(&copy)
        set(copy.normalized())
    }

    func setStyle(_ style: StartStyle) { update { $0.style = style } }
    func toggle(_ section: StartSection) { update { $0 = $0.with(layout: $0.current.toggled(section), for: $0.style) } }
    func setOption(_ section: StartSection, _ option: Int) { update { $0 = $0.with(layout: $0.current.setting(section, option: option), for: $0.style) } }
    func move(_ section: StartSection, to index: Int) { update { $0 = $0.with(layout: $0.current.moving(section, to: index), for: $0.style) } }
    func move(_ section: StartSection, by offset: Int) { update { $0 = $0.with(layout: $0.current.moving(section, by: offset), for: $0.style) } }
    func setBackground(_ background: StartBackground) { update { $0.background = background } }
    func setNewTab(_ opens: NewTabOpens) { update { $0.newTab = opens } }
    func setAddress(_ address: String) { update { $0.address = address } }

    /// Back to the defaults; the settings from before are returned so "Undo" can put them back.
    @discardableResult
    func reset() -> StartPageSettings {
        let before = settings
        set(.default)
        return before
    }

    /// Puts settings back (the "Undo" of a reset); a picture whose copy is gone by now is not waited for.
    func restore(_ previous: StartPageSettings) {
        var settings = previous.normalized()
        if let file = settings.background.imageFile, !FileManager.default.fileExists(atPath: imageURL(file)?.path ?? "") {
            settings.background.imageFile = nil
            settings = settings.normalized()
        }
        set(settings)
    }

    /// The copy of the background picture for a stored file name.
    func imageURL(_ file: String?) -> URL? { StartPageFiles.imageURL(file, in: folder) }

    /// Makes the picture at `url` the background: a shrunk copy of its first frame, without any of its metadata, goes into the app's folder, and the
    /// settings then name that copy (blur and dim stay as they were) while the one before it is deleted. The work is done off the main thread; the
    /// original is only read. False when the file can't be used (not a picture, too large, undecodable): nothing changes then.
    func chooseImage(from url: URL) async -> Bool {
        let folder = folder
        let name = await Task.detached(priority: .userInitiated) { try? StartPageImage.importPicture(from: url, into: folder) }.value
        guard let name else { return false }
        let previous = settings.background.imageFile
        update {
            $0.background.kind = .image
            $0.background.imageFile = name
        }
        if let previous, previous != name { removeCopy(previous) }
        return true
    }

    /// Deletes the copies in the folder that the settings don't name: ones an earlier run let go of (a reset, a crash, an interrupted import).
    /// Run once a launch, off the main thread.
    func removeOrphanedImages() async {
        let folder = folder, keeping = Set([settings.background.imageFile].compactMap { $0 })
        _ = await Task.detached(priority: .utility) { StartPageImage.removeOrphans(in: folder, keeping: keeping) }.value
    }

    private func removeCopy(_ file: String) {
        guard let url = imageURL(file) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// A copy that nothing names any more is deleted after the undo window, unless an Undo has put it back by then.
    private func removeCopyLater(_ file: String) {
        Task { [weak self, undoWindow] in
            try? await Task.sleep(for: undoWindow)
            guard let self, self.settings.background.imageFile != file else { return }
            self.removeCopy(file)
        }
    }

    private func set(_ new: StartPageSettings) {
        guard new != settings else { return }
        let dropped = settings.background.imageFile.flatMap { $0 != new.background.imageFile ? $0 : nil }
        settings = new
        if let data = try? JSONEncoder().encode(new) { defaults.set(data, forKey: Self.defaultsKey) }
        if let dropped { removeCopyLater(dropped) }
    }
}
