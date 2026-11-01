import AppKit
import Foundation
import Testing
@testable import Changmun

/// The sheets of a window: one at a time, in the order they came, none on another sheet, and what a page can start is refused while one is up
/// unless it is the question that is already up. Nothing here waits for ever: every wait is bounded, so a sheet that does not come fails the test
/// instead of stopping the suite.
@MainActor @Suite(.serialized)
struct DialogQueueTests {
    /// A question asked in the background, and what became of it.
    final class Asked {
        var done = false
        var result: DialogResult?
        var task: Task<Void, Never>?
    }

    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -32000, y: -32000, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        return window
    }

    private func spec(_ title: String) -> DialogSpec {
        DialogSpec(title: title, buttons: [DialogButton(title: "Cancel", role: .cancel, isDefault: true), DialogButton(title: "OK")])
    }

    private func ask(_ work: @escaping @MainActor () async -> DialogResult?) -> Asked {
        let asked = Asked()
        asked.task = Task { @MainActor in
            asked.result = await work()
            asked.done = true
        }
        return asked
    }

    private func present(in window: NSWindow?, _ title: String, whenBusy: Dialog.WhenBusy = .wait, key: DialogKey? = nil, handle: Dialog.Handle? = nil) -> Asked {
        ask { await Dialog.present(in: window, self.spec(title), whenBusy: whenBusy, key: key, handle: handle) }
    }

    /// Waits up to three seconds for `condition`.
    private func until(_ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

    private func sheet(of window: NSWindow, is title: String?) async -> Bool { await until { window.attachedSheet?.title == title } }

    private func finished(_ asked: Asked) async -> Bool { await until { asked.done } }

    /// Esc on the sheet that is up.
    private func escape() async {
        Dialog.lastSheet?.cancelOperation(nil)
        await settle()
    }

    /// Whatever is still up or waiting at the end of a test is let go.
    private func clear(_ window: NSWindow, _ all: [Asked]) async {
        for _ in 0..<6 where window.attachedSheet != nil { await escape() }
        for asked in all { asked.task?.cancel() }
        window.close()
    }

    @Test func aSheetNeverGoesOnAnotherSheet() async {
        let main = window()
        let first = present(in: main, "first")
        #expect(await sheet(of: main, is: "first"))
        let up = main.attachedSheet
        if let up { #expect(Dialog.root(of: up) === main, "the window under the sheet is the one that counts") }
        // Asked of the sheet (the key window is the sheet while it is up), the next question waits for it all the same.
        let second = present(in: up, "second")
        await settle()
        #expect(main.sheets.count == 1 && main.attachedSheet?.title == "first")
        await escape()
        #expect(await finished(first) && first.result?.button == 0)
        #expect(await sheet(of: main, is: "second"), "the second goes up when the first is gone")
        await escape()
        #expect(await finished(second) && second.result?.button == 0)
        await clear(main, [first, second])
    }

    @Test func theyGoUpInTheOrderTheyCame() async {
        let main = window()
        let all = ["a", "b", "c"].map { present(in: main, $0) }
        var seen: [String] = []
        for title in ["a", "b", "c"] {
            _ = await sheet(of: main, is: title)
            seen.append(main.attachedSheet?.title ?? "none")
            await escape()
        }
        #expect(seen == ["a", "b", "c"])
        await clear(main, all)
    }

    @Test func aQuestionAPageStartsCannotJumpTheOnesThatWait() async {
        let main = window()
        let first = present(in: main, "first")
        #expect(await sheet(of: main, is: "first"))
        let waiting = present(in: main, "waiting")
        await settle()
        let page = present(in: main, "page", whenBusy: .refuse)
        #expect(await finished(page) && page.result == nil, "refused while one is up and another waits")
        await escape()
        #expect(await sheet(of: main, is: "waiting"), "the one that waited goes before anyone who came later")
        let again = present(in: main, "page", whenBusy: .refuse)
        #expect(await finished(again) && again.result == nil)
        await escape()
        let (a, b) = (await finished(first), await finished(waiting))
        #expect(a && b)
        // With nothing up it is shown.
        let free = present(in: main, "free", whenBusy: .refuse)
        #expect(await sheet(of: main, is: "free"))
        await clear(main, [first, waiting, page, again, free])
    }

    @Test func theSameQuestionIsAskedOnceAndSharesItsAnswer() async {
        let main = window()
        let key = DialogKey(group: "meet.example", kind: "camera")
        let first = present(in: main, "camera", whenBusy: .refuse, key: key)
        #expect(await sheet(of: main, is: "camera"))
        let again = present(in: main, "camera again", whenBusy: .refuse, key: key)
        await settle()
        #expect(main.sheets.count == 1 && main.attachedSheet?.title == "camera")
        await escape()
        let (a, b) = (await finished(first), await finished(again))
        #expect(a && b)
        #expect(first.result?.button == 0 && again.result?.button == 0, "one answer for both")
        #expect(main.attachedSheet == nil, "and no second question")
        await clear(main, [first, again])
    }

    @Test func anotherDeviceOfTheSameSiteWaitsAndAnotherSiteIsRefused() async {
        let main = window()
        let camera = present(in: main, "camera", whenBusy: .refuse, key: DialogKey(group: "meet.example", kind: "camera"))
        #expect(await sheet(of: main, is: "camera"))
        let microphone = present(in: main, "microphone", whenBusy: .refuse, key: DialogKey(group: "meet.example", kind: "microphone"))
        await settle()
        let other = present(in: main, "other", whenBusy: .refuse, key: DialogKey(group: "other.example", kind: "camera"))
        #expect(await finished(other) && other.result == nil, "another site's question is refused while one is up")
        #expect(main.attachedSheet?.title == "camera")
        await escape()
        #expect(await finished(camera) && camera.result?.button == 0)
        #expect(await sheet(of: main, is: "microphone"), "the microphone is asked after the camera, not refused")
        await escape()
        #expect(await finished(microphone) && microphone.result?.button == 0)
        await clear(main, [camera, microphone, other])
    }

    @Test func aQuestionTakenBackWhileItWaitsNeverGoesUp() async {
        let main = window()
        let first = present(in: main, "first")
        #expect(await sheet(of: main, is: "first"))
        let handle = Dialog.Handle()
        let waiting = present(in: main, "waiting", handle: handle)
        await settle()
        handle.end()
        #expect(await finished(waiting) && waiting.result == nil)
        await escape()
        #expect(await finished(first))
        await settle()
        #expect(main.attachedSheet == nil)
        await clear(main, [first, waiting])
    }

    @Test func aCancelledTaskStopsWaitingAndAnswersNil() async {
        let main = window()
        let first = present(in: main, "first")
        #expect(await sheet(of: main, is: "first"))
        let waiting = present(in: main, "waiting")
        await settle()
        waiting.task?.cancel()
        #expect(await finished(waiting) && waiting.result == nil)
        await escape()
        #expect(await finished(first))
        await settle()
        #expect(main.attachedSheet == nil, "a cancelled question does not come up later")
        await clear(main, [first, waiting])
    }

    @Test func aSheetUpIsTakenBackByItsHandle() async {
        let main = window()
        let handle = Dialog.Handle()
        let up = present(in: main, "up", handle: handle)
        #expect(await sheet(of: main, is: "up"))
        handle.end()
        #expect(await finished(up) && up.result == nil)
        #expect(await sheet(of: main, is: nil))
        await clear(main, [up])
    }

    // MARK: A page's questions end with the page

    @Test func aQuestionOfAPageEndsWhenItsTabIsClosed() async {
        let b = Browser()
        b.focused()
        defer { b.windowClosed() }
        let main = window()
        let tab = b.openTab(url: nil)
        let asked = ask { await tab.askPage(self.spec("camera"), in: main) }
        #expect(await sheet(of: main, is: "camera"))
        b.close(tab.id)
        #expect(await finished(asked) && asked.result == nil, "closed, so no one is left to answer: no")
        #expect(await sheet(of: main, is: nil))
        await clear(main, [asked])
    }

    @Test func aQuestionOfAPageEndsWhenItMovesOn() async {
        let b = Browser()
        b.focused()
        defer { b.windowClosed() }
        let main = window()
        let tab = b.openTab(url: nil)
        let asked = ask { await tab.askPage(self.spec("camera"), in: main) }
        #expect(await sheet(of: main, is: "camera"))
        tab.endPageQuestions()
        #expect(await finished(asked) && asked.result == nil)
        // A tab that waits behind another sheet is taken back too, and never comes up.
        let first = present(in: main, "first")
        #expect(await sheet(of: main, is: "first"))
        let waiting = ask { await tab.askPage(self.spec("login"), in: main) }
        await settle()
        tab.endPageQuestions()
        #expect(await finished(waiting) && waiting.result == nil)
        await escape()
        #expect(await finished(first))
        await settle()
        #expect(main.attachedSheet == nil)
        await clear(main, [asked, first, waiting])
    }

    @Test func aTabThatIsNotTheOneShownIsInTheBackground() {
        let b = Browser()
        b.focused()
        defer { b.windowClosed() }
        let first = b.openTab(url: nil)
        let second = b.openTab(url: nil)
        #expect(!second.isInBackground)
        #expect(first.isInBackground)
    }
}
