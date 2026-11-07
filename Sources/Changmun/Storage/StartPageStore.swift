import Combine
import Foundation

/// Where a new tab goes, kept in the user defaults as one JSON value and changed only through `update`.
@MainActor
final class StartPageStore: ObservableObject {
    static let shared = StartPageStore()
    static let defaultsKey = "startPageSettings"

    @Published private(set) var settings: StartPageSettings
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey), let decoded = try? JSONDecoder().decode(StartPageSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
    }

    func update(_ change: (inout StartPageSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        if let data = try? JSONEncoder().encode(copy) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    func setNewTab(_ opens: NewTabOpens) { update { $0.newTab = opens } }
    func setAddress(_ address: String) { update { $0.address = address } }
}
