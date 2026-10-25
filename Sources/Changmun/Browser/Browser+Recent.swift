import AppKit
import WebKit

extension Browser {
    // MARK: Recent tabs

    /// ⌃Tab's switcher: the tabs, most recently shown first, and the one picked so far.
    struct TabSwitcher: Equatable {
        var order: [Int]
        var index: Int
    }

    /// Most pop-ups the allowed sites get in a minute, and the least time between two: a page can ask for any number.
    static let allowedPopupsPerMinute = 5, allowedPopupGap = 1.0

    /// Whether an allowed site's pop-up may open now (at most one a second, and so many a minute), counting it if so.
    func takeAllowedPopupSlot() -> Bool {
        let now = Date()
        allowedPopups = allowedPopups.filter { now.timeIntervalSince($0) < 60 }
        guard allowedPopups.count < Self.allowedPopupsPerMinute, allowedPopups.last.map({ now.timeIntervalSince($0) > Self.allowedPopupGap }) ?? true else { return false }
        allowedPopups.append(now)
        return true
    }

    /// The shown tab first, then the others by when they were last shown.
    var recentTabs: [Tab] {
        spaceTabs.enumerated().sorted { a, b in
            if (a.element.id == activeID) != (b.element.id == activeID) { return a.element.id == activeID }
            if a.element.lastShown != b.element.lastShown { return a.element.lastShown > b.element.lastShown }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Opens the switcher on the tab shown before this one, or moves along it.
    func cycleRecentTabs(backwards: Bool = false) {
        guard commandBar == nil else { return }
        if var switcher = tabSwitcher {
            switcher.index = (switcher.index + (backwards ? -1 : 1) + switcher.order.count) % switcher.order.count
            tabSwitcher = switcher
            return
        }
        let order = recentTabs.map(\.id)
        guard order.count > 1 else { return }
        tabSwitcher = TabSwitcher(order: order, index: backwards ? order.count - 1 : 1)
    }

    /// Goes to the picked tab, or to the next one still open after it if it closed meanwhile.
    func finishSwitching(to id: Int? = nil) {
        guard let switcher = tabSwitcher else { return }
        tabSwitcher = nil
        let open = (switcher.order[switcher.index...] + switcher.order[..<switcher.index]).first { tab($0) != nil }
        if let pick = id ?? open { activate(pick) }
    }

    func cancelSwitching() { tabSwitcher = nil }
}
