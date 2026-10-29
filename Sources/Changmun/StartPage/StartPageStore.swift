import Combine
import Foundation

/// The start page's settings, kept in the user defaults as one JSON value and changed only through `update` and `reset`.
@MainActor
final class StartPageStore: ObservableObject {
    static let shared = StartPageStore()
    static let defaultsKey = "startPageSettings"

    @Published private(set) var settings: StartPageSettings
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    func restore(_ previous: StartPageSettings) { set(previous.normalized()) }

    /// The page the "Choose Image…" button would copy a picture into: set by the image import (see the integration lane); until then it
    /// copies nothing and answers false.
    func chooseImage(from url: URL) async -> Bool { false }

    private func set(_ new: StartPageSettings) {
        guard new != settings else { return }
        settings = new
        if let data = try? JSONEncoder().encode(new) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
