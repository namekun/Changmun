import AppKit
import SwiftUI

/// A tab as VoiceOver meets it, in the sidebar's row and in the strip along the top: its title, what it is doing, whether it is the one shown,
/// and what its menu does that a press does not.
extension Accessibility {
    @MainActor
    static func facts(of tab: Tab, in browser: Browser) -> TabFacts {
        TabFacts(loading: tab.isLoading, playingAudio: tab.isPlayingAudio, muted: tab.isMuted, asleep: tab.isAsleep, pinned: tab.bookmarkKey != nil,
                 split: browser.split?.contains(tab.id) == true, group: tab.groupID.flatMap { id in browser.groups.first { $0.id == id }?.name })
    }

    @MainActor
    static func tabActions(of tab: Tab, in browser: Browser, close: @escaping () -> Void) -> [AccessibleButton.Action] {
        var actions: [AccessibleButton.Action] = [
            .init(String(localized: "Close Tab"), close),
            .init(String(localized: "Rename"), { browser.renamingTab = tab.id }),
            .init(String(localized: "Reload")) { if tab.isAsleep { browser.activate(tab.id) } else { tab.webView?.reload() } },
        ]
        if !tab.isAsleep { actions.append(.init(tab.isMuted ? String(localized: "Unmute") : String(localized: "Mute Tab")) { tab.toggleMute() }) }
        return actions
    }
}

extension View {
    /// Makes a tab's row or strip tile a button for VoiceOver and the keyboard (see `AccessibleButton`).
    @MainActor
    func accessibleTab(_ tab: Tab, in browser: Browser, isActive: Bool, renaming: Bool, close: @escaping () -> Void, select: @escaping () -> Void) -> some View {
        accessibleButton(tab.displayTitle, value: Accessibility.tabValue(Accessibility.facts(of: tab, in: browser)), selected: isActive, enabled: !renaming,
                         actions: Accessibility.tabActions(of: tab, in: browser, close: close), activate: select)
    }
}
