import AppKit
import Combine

/// The number of downloads running, on the Dock icon; nothing at zero.
@MainActor
final class DockBadge {
    static let shared = DockBadge()
    private var subscription: AnyCancellable?
    private var shown = 0

    nonisolated static func label(running: Int) -> String? { running > 0 ? String(running) : nil }

    func start() {
        guard !Headless.isOn else { return }
        // The list says it will change before it has: the count is read on the next turn of the run loop.
        subscription = Downloads.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func update() {
        let running = Downloads.shared.items.filter { $0.state == .running }.count
        guard running != shown else { return }
        shown = running
        NSApp?.dockTile.badgeLabel = Self.label(running: running)
    }
}
