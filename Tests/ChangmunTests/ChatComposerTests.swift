import AppKit
import Testing
@testable import Changmun

@MainActor
struct ChatComposerTests {
    private func press(_ keyCode: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    private func composer() -> (view: ComposerTextView, sent: () -> [(text: String, command: Bool)]) {
        let view = ComposerTextView()
        final class Box { var sent: [(text: String, command: Bool)] = [] }
        let box = Box()
        view.onReturn = { box.sent.append(($0, $1)) }
        return (view, { box.sent })
    }

    @Test func returnWhileAnInputMethodHoldsMarkedTextGoesToTheInputMethodAndSendsNothing() {
        let (view, sent) = composer()
        view.string = "안녕"
        view.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 2, length: 0))
        #expect(view.hasMarkedText())
        view.keyDown(with: press(36, "\r"))
        #expect(sent().isEmpty, "a Return that commits a syllable is not a send")
        #expect(!view.string.contains("\n"), "and not a line break either: \(view.string.debugDescription)")
        view.keyDown(with: press(76, "\u{3}"))
        view.keyDown(with: press(36, "\r", modifiers: .command))
        #expect(sent().isEmpty, "also the keypad Enter and ⌘Return")
    }

    @Test func returnAfterTheCompositionEndedSendsAndCommandReturnSteers() {
        let (view, sent) = composer()
        view.string = "안녕"
        view.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 2, length: 0))
        view.keyDown(with: press(36, "\r"))
        view.unmarkText()
        #expect(!view.hasMarkedText())
        view.keyDown(with: press(36, "\r"))
        view.keyDown(with: press(36, "\r", modifiers: .command))
        #expect(sent().map(\.text) == [view.string, view.string] && view.string.hasPrefix("안녕"), "\(sent())")
        #expect(sent().map(\.command) == [false, true])
        #expect(!view.string.contains("\n"))
    }

    @Test func shiftReturnBreaksTheLineAndSendsNothing() {
        let (view, sent) = composer()
        view.string = "one"
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.keyDown(with: press(36, "\r", modifiers: .shift))
        #expect(sent().isEmpty && view.string == "one\n", "\(view.string.debugDescription)")
    }
}
