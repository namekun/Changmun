import Foundation

/// What the app does with no window left: it quits, or stays open and opens a window again when asked.
enum LastWindow {
    /// What the app does when its Dock icon is clicked (or it is opened again) and there is no window.
    enum Reopen: Equatable {
        /// Windows are open, some perhaps minimized: the system brings them back.
        case system
        /// The windows the last session left, as at a launch.
        case restoreSession
        case blankWindow
    }

    /// Whether the app ends when its last window closes: what Settings › General says.
    static func quits(quitWhenLastWindowCloses setting: Bool) -> Bool { setting }

    /// By the windows there are, not by whether one is visible: a minimized window is still a window.
    static func reopen(openWindows: Int, savedWindows: Int) -> Reopen {
        if openWindows > 0 { return .system }
        return savedWindows > 0 ? .restoreSession : .blankWindow
    }
}
