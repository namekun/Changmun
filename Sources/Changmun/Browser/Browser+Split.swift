import AppKit
import WebKit

extension Browser {
    // MARK: Split view

    /// Two tabs side by side. It shows while either of them is the active tab; showing another tab hides it, and
    /// closing either one ends it.
    struct Split: Equatable {
        var left: Int
        var right: Int
        func contains(_ id: Int?) -> Bool { id == left || id == right }
    }

    var split: Split? { splits[spaceID] }

    /// The halves of a split that ends were on screen until now.
    func setSplit(_ new: Split?, in space: UUID) {
        let old = splits[space]
        splits[space] = new
        for id in [old?.left, old?.right].compactMap({ $0 }) where new?.contains(id) != true { tab(id)?.lastShown = Date() }
    }
    var shownSplit: Split? { split?.contains(activeID) == true ? split : nil }

    /// Shows `id` to the right of the active tab.
    func split(with id: Int) {
        // A start tab has no page to put beside another.
        guard let activeID, id != activeID, tab(id)?.spaceID == spaceID, tab(id)?.isStart != true, active?.isStart != true else { return }
        setSplit(Split(left: activeID, right: id), in: spaceID)
        splitFraction = 0.5
        tab(id)?.wake()
    }

    func unsplit() { setSplit(nil, in: spaceID) }

    nonisolated static func clampedSplitFraction(_ fraction: Double) -> Double { min(max(fraction, 0.2), 0.8) }

    /// The split for the menu command: the active tab and the one shown before it.
    func toggleSplit() {
        if shownSplit != nil { return unsplit() }
        guard let back = previousActiveID, tab(back) != nil, tab(back)?.isStart != true, active?.isStart != true else { return NSSound.beep() }
        split(with: back)
    }
}
