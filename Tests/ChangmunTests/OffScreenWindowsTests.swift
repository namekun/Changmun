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

    @Test func aPopUpChildWindowAtTheScreensCornerIsParkedToo() async {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        child.isReleasedWhenClosed = false
        defer { child.orderOut(nil); parent.orderOut(nil) }
        parent.orderFront(nil)
        parent.addChildWindow(child, ordered: .above)
        child.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        child.orderFront(nil)
        #expect(!isOnAScreen(child))
    }

    @Test func aWindowThatGotOntoAScreenByAnyPathIsPutBackWithinAMoment() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        // Straight to the window server's idea of its place, past every setter the hooks cover.
        window.setValue(NSValue(rect: NSRect(x: 50, y: 50, width: 300, height: 200)), forKey: "frame")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!isOnAScreen(window))
        #expect(window.collectionBehavior.contains(.transient), "and kept out of Mission Control")
    }
}
