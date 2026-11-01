import AppKit
import Testing
@testable import Changmun

/// Nothing a test or the test copy makes may reach the user's screen, wherever it asks to be put.
@MainActor
struct OffScreenWindowsTests {
    private func isOnAScreen(_ window: NSWindow) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    @Test func theTestRunnerCountsAsSomewhereWindowsStayOffScreen() {
        #expect(OffScreenWindows.isActive, "on from when the code loads, before any test")
    }

    @Test func aWindowStaysOffEveryScreenHoweverItIsPlacedAndShown() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        #expect(!isOnAScreen(window))
        window.center()
        #expect(!isOnAScreen(window))
        window.setFrame(NSRect(x: 0, y: 0, width: 500, height: 400), display: false)
        #expect(!isOnAScreen(window) && window.frame.size == NSSize(width: 500, height: 400), "its size is kept")
        window.setFrameOrigin(.zero)
        #expect(!isOnAScreen(window))
        window.setFrameTopLeftPoint(NSPoint(x: 200, y: 400))
        #expect(!isOnAScreen(window))
        window.orderFrontRegardless()
        #expect(!isOnAScreen(window))
    }

    @Test func thePoppedOutPanelIsNotCentredOnTheUsersScreen() {
        let window = NSWindow(contentViewController: NSViewController())
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 380, height: 620))
        window.center()
        window.orderFront(nil)
        #expect(!isOnAScreen(window))
    }
}
