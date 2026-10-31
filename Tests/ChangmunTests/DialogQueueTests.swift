import AppKit
import Foundation
import Testing
@testable import Changmun

/// The sheets of a window: one at a time, in the order they came, none on another sheet, and what a page can start is refused while one is up
/// unless it is the question that is already up.
@MainActor @Suite(.serialized)
struct DialogQueueTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -32000, y: -32000, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        return window
    }

    private func spec(_ title: String) -> DialogSpec {
        DialogSpec(title: title, buttons: [DialogButton(title: "Cancel", role: .cancel, isDefault: true), DialogButton(title: "OK")])
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(150)) }

    /// Esc on the sheet that is up.
    private func escape() async {
        Dialog.lastSheet?.cancelOperation(nil)
        await settle()
    }

    @Test func aSheetNeverGoesOnAnotherSheet() async {
        let main = window()
        defer { main.close() }
        let first = Task { await Dialog.present(in: main, spec("first")) }
        await settle()
        let sheet = main.attachedSheet
        #expect(sheet != nil)
        #expect(Dialog.root(of: sheet!) === main, "the window under the sheet is the one that counts")
        // Asked of the sheet (the key window is the sheet while it is up), the next question waits for it all the same.
        let second = Task { await Dialog.present(in: sheet, spec("second")) }
        await settle()
        #expect(main.sheets.count == 1 && main.attachedSheet?.title == "first")
        await escape()
        #expect(await first.value?.button == 0)
        #expect(main.attachedSheet?.title == "second", "the second goes up when the first is gone")
        await escape()
        #expect(await second.value?.button == 0)
    }

    @Test func theyGoUpInTheOrderTheyCame() async {
        let main = window()
        defer { main.close() }
        let tasks = ["a", "b", "c"].map { title in Task { await Dialog.present(in: main, spec(title)) } }
        var seen: [String] = []
        for _ in tasks {
            await settle()
            seen.append(main.attachedSheet?.title ?? "none")
            await escape()
        }
        #expect(seen == ["a", "b", "c"])
        for task in tasks { _ = await task.value }
    }

    @Test func aQuestionAPageStartsCannotJumpTheOnesThatWait() async {
        let main = window()
        defer { main.close() }
        let first = Task { await Dialog.present(in: main, spec("first")) }
        await settle()
        let waiting = Task { await Dialog.present(in: main, spec("waiting")) }
        await settle()
        #expect(await Dialog.present(in: main, spec("page"), whenBusy: .refuse) == nil, "refused while one is up and another waits")
        await escape()
        #expect(main.attachedSheet?.title == "waiting", "the one that waited goes before anyone who came later")
        #expect(await Dialog.present(in: main, spec("page"), whenBusy: .refuse) == nil)
        await escape()
        _ = await first.value
        _ = await waiting.value
        // With nothing up it is shown.
        let free = Task { await Dialog.present(in: main, spec("free"), whenBusy: .refuse) }
        await settle()
        #expect(main.attachedSheet?.title == "free")
        await escape()
        _ = await free.value
    }

    @Test func theSameQuestionIsAskedOnceAndSharesItsAnswer() async {
        let main = window()
        defer { main.close() }
        let key = DialogKey(group: "meet.example", kind: "camera")
        let first = Task { await Dialog.present(in: main, spec("camera"), whenBusy: .refuse, key: key) }
        await settle()
        let again = Task { await Dialog.present(in: main, spec("camera again"), whenBusy: .refuse, key: key) }
        await settle()
        #expect(main.sheets.count == 1 && main.attachedSheet?.title == "camera")
        await escape()
        let (one, two) = (await first.value, await again.value)
        #expect(one?.button == 0 && two?.button == 0, "one answer for both")
        #expect(main.attachedSheet == nil, "and no second question")
    }

    @Test func anotherDeviceOfTheSameSiteWaitsAndAnotherSiteIsRefused() async {
        let main = window()
        defer { main.close() }
        let camera = Task { await Dialog.present(in: main, spec("camera"), whenBusy: .refuse, key: DialogKey(group: "meet.example", kind: "camera")) }
        await settle()
        let microphone = Task { await Dialog.present(in: main, spec("microphone"), whenBusy: .refuse, key: DialogKey(group: "meet.example", kind: "microphone")) }
        await settle()
        let other = await Dialog.present(in: main, spec("other"), whenBusy: .refuse, key: DialogKey(group: "other.example", kind: "camera"))
        #expect(other == nil, "another site's question is refused while one is up")
        #expect(main.attachedSheet?.title == "camera")
        await escape()
        #expect(await camera.value?.button == 0)
        #expect(main.attachedSheet?.title == "microphone", "the microphone is asked after the camera, not refused")
        await escape()
        #expect(await microphone.value?.button == 0)
    }

    @Test func aQuestionTakenBackWhileItWaitsNeverGoesUp() async {
        let main = window()
        defer { main.close() }
        let first = Task { await Dialog.present(in: main, spec("first")) }
        await settle()
        let handle = Dialog.Handle()
        let waiting = Task { await Dialog.present(in: main, spec("waiting"), handle: handle) }
        await settle()
        handle.end()
        #expect(await waiting.value == nil)
        await escape()
        _ = await first.value
        await settle()
        #expect(main.attachedSheet == nil)
    }

    @Test func aCancelledTaskStopsWaitingAndAnswersNil() async {
        let main = window()
        defer { main.close() }
        let first = Task { await Dialog.present(in: main, spec("first")) }
        await settle()
        let waiting = Task { await Dialog.present(in: main, spec("waiting")) }
        await settle()
        waiting.cancel()
        #expect(await waiting.value == nil)
        await escape()
        _ = await first.value
        await settle()
        #expect(main.attachedSheet == nil, "a cancelled question does not come up later")
    }

    @Test func aSheetUpIsTakenBackByItsHandle() async {
        let main = window()
        defer { main.close() }
        let handle = Dialog.Handle()
        let up = Task { await Dialog.present(in: main, spec("up"), handle: handle) }
        await settle()
        #expect(main.attachedSheet != nil)
        handle.end()
        #expect(await up.value == nil)
        await settle()
        #expect(main.attachedSheet == nil)
    }

    // MARK: A page's questions end with the page

    @Test func aQuestionOfAPageEndsWhenItsTabIsClosed() async {
        let b = Browser()
        b.focused()
        defer { b.windowClosed() }
        let main = window()
        defer { main.close() }
        let tab = b.openTab(url: nil)
        let asked = Task { await tab.askPage(spec("camera"), in: main) }
        await settle()
        #expect(main.attachedSheet?.title == "camera")
        b.close(tab.id)
        #expect(await asked.value == nil, "closed, so no one is left to answer: no")
        await settle()
        #expect(main.attachedSheet == nil)
    }

    @Test func aQuestionOfAPageEndsWhenItMovesOn() async {
        let b = Browser()
        b.focused()
        defer { b.windowClosed() }
        let main = window()
        defer { main.close() }
        let tab = b.openTab(url: nil)
        let asked = Task { await tab.askPage(spec("camera"), in: main) }
        await settle()
        tab.endPageQuestions()
        #expect(await asked.value == nil)
        // A tab that waits behind another sheet is taken back too, and never comes up.
        let first = Task { await Dialog.present(in: main, spec("first")) }
        await settle()
        let waiting = Task { await tab.askPage(spec("login"), in: main) }
        await settle()
        tab.endPageQuestions()
        #expect(await waiting.value == nil)
        await escape()
        _ = await first.value
        await settle()
        #expect(main.attachedSheet == nil)
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
