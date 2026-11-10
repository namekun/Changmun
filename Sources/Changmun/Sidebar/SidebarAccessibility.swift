import AppKit
import SwiftUI

/// A tab as VoiceOver meets it in its sidebar row: its title, what it is doing, whether it is the one shown,
/// and what its menu does that a press does not.
extension Accessibility {
    @MainActor
    static func facts(of tab: Tab, in browser: Browser) -> TabFacts {
        TabFacts(loading: tab.isLoading, playingAudio: tab.isPlayingAudio, muted: tab.isMuted, asleep: tab.isAsleep, pinned: tab.bookmarkKey != nil,
                 split: browser.split?.contains(tab.id) == true, group: tab.groupID.flatMap { id in browser.groups.first { $0.id == id }?.name })
    }

    @MainActor
    static func tabActions(of tab: Tab, in browser: Browser, close: @escaping () -> Void) -> [AccessibleButton.Action] {
        let actions: [AccessibleButton.Action] = [
            .init(String(localized: "Close Tab"), close),
            .init(String(localized: "Rename"), { browser.renamingTab = tab.id }),
            .init(String(localized: "Reload")) { if tab.isAsleep { browser.activate(tab.id) } else { tab.webView?.reload() } },
        ]
        return actions + muteActions(of: tab)
    }

    /// Mute or Unmute, for a tab that has a page (a favorite's or a bookmark's tab too); nothing for none.
    @MainActor
    static func muteActions(of tab: Tab?) -> [AccessibleButton.Action] {
        guard let tab, !tab.isAsleep else { return [] }
        return [.init(tab.isMuted ? String(localized: "Unmute") : String(localized: "Mute Tab")) { tab.toggleMute() }]
    }
}

extension Accessibility {
    /// A tab row's tooltip: its whole title (the row cuts it to one line), then its address, then that it sleeps; a start tab is a new tab.
    static func tabHelp(title: String, address: String?, isStart: Bool, asleep: Bool = false) -> String {
        if isStart { return String(localized: "New Tab") }
        // A page with no title of its own shows its address as the title: it is not said twice.
        return ((title == address ? [title] : [title, address ?? ""]) + [asleep ? asleepHint : ""]).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static var asleepHint: String { String(localized: "Asleep: click to wake") }

    /// Whether a favorite's or a bookmark's own tab is open, in words: the tile fades and the row has a dot for it.
    static func bookmarkTabValue(_ state: BookmarkTabState) -> String {
        switch state {
        case .closed: String(localized: "No tab open")
        case .open: String(localized: "Open in the background")
        case .shown: String(localized: "Shown")
        }
    }

    /// A favorite's or a bookmark's tooltip: its name, then whether its tab is open (the one shown needs no word).
    static func bookmarkHelp(_ name: String, _ state: BookmarkTabState) -> String {
        state == .shown ? name : name + "\n" + bookmarkTabValue(state)
    }

    /// A profile space's tooltip says what its key badge means.
    static func spaceHelp(_ name: String, isProfile: Bool) -> String {
        isProfile ? name + "\n" + String(localized: "Has its own logins") : name
    }
}

extension View {
    /// Makes a tab's row a button for VoiceOver and the keyboard (see `AccessibleButton`).
    @MainActor
    func accessibleTab(_ tab: Tab, in browser: Browser, isActive: Bool, renaming: Bool, close: @escaping () -> Void, select: @escaping () -> Void) -> some View {
        accessibleButton(tab.displayTitle, value: Accessibility.tabValue(Accessibility.facts(of: tab, in: browser)), hint: tab.isAsleep ? Accessibility.asleepHint : nil,
                         selected: isActive, enabled: !renaming,
                         actions: Accessibility.tabActions(of: tab, in: browser, close: close), activate: select)
    }
}
