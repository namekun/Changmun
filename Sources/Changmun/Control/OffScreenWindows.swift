import ChangmunOffScreen

/// Keeps every window of the test copy and of the test runner off every screen, whoever made it: tests and agents must never show anything on the
/// user's. It works on NSWindow itself rather than on each place that makes a window, so a new one can't forget. It does nothing in the app.
@MainActor
enum OffScreenWindows {
    /// The test runner's are kept off from the moment the code is loaded; the test copy asks here, first thing.
    static func install() {
        if Headless.isOn { changmun_off_screen_install() }
    }

    nonisolated static var isActive: Bool { changmun_off_screen_active() }
}
