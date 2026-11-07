import AppKit
import Combine
import SwiftUI

extension NewTabOpens {
    var title: String {
        switch self {
        case .startPage: String(localized: "Start Page")
        case .commandBar: String(localized: "Command Bar")
        case .blank: String(localized: "Blank Page")
        case .address: String(localized: "Address")
        }
    }

    var detail: String? {
        switch self {
        case .startPage: String(localized: "⌘T opens a new tab with the start page. The search field is ready to type in.")
        case .commandBar: String(localized: "⌘T opens the command bar over a blank page, as before.")
        case .blank: String(localized: "⌘T opens an empty page.")
        case .address: nil
        }
    }
}

/// What the Settings page does with the store: every change applies at once. A plain object with its announcements handed in, so that it can be
/// tested without a window.
@MainActor
final class StartPageSettingsModel: ObservableObject {
    let store: StartPageStore
    private let announce: (String) -> Void
    private var watch: AnyCancellable?

    /// The address as typed in the field, and what it came to when last checked (nil: not checked since it was changed).
    @Published var address: String
    @Published private(set) var addressState: StartAddressCheck?

    init(store: StartPageStore? = nil, announce: ((String) -> Void)? = nil) {
        let store = store ?? StartPageStore.shared
        self.store = store
        self.announce = announce ?? { Announcer.announce($0) }
        address = store.settings.address
        if store.settings.newTab == .address, !store.settings.address.isEmpty { addressState = StartAddressCheck.check(store.settings.address) }
        watch = store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var settings: StartPageSettings { store.settings }

    // MARK: New tabs

    func setNewTab(_ opens: NewTabOpens) {
        store.setNewTab(opens)
        if opens == .address, !address.isEmpty { commitAddress() }
    }

    /// The address is checked when the user is done with it (Return, or the field loses the keyboard), not while it is typed. A bare host gets https.
    func commitAddress() {
        var typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let check = StartAddressCheck.check(typed)
        if let url = check.url, !typed.contains("://") { typed = url.absoluteString }
        address = typed
        store.setAddress(typed)
        addressState = StartAddressCheck.check(typed)
        switch addressState {
        case .invalid: announce(String(localized: "That isn’t a valid address"))
        default: break
        }
    }

    func addressEdited() { addressState = nil }

    /// "Use https://" on an address that is plain http.
    func useHTTPS() {
        guard address.lowercased().hasPrefix("http://") else { return }
        address = "https://" + address.dropFirst("http://".count)
        commitAddress()
    }

    func restoreAddressFromStore() {
        address = store.settings.address
        addressState = store.settings.newTab == .address && !address.isEmpty ? StartAddressCheck.check(address) : nil
    }
}
