import AppKit
import SwiftUI

/// The AI panel's text box. Return sends (or queues) the message, ⌘Return steers, Shift/Option/Control+Return breaks the line.
///
/// While the user is composing text with an input method (Korean, Japanese, Chinese), Return belongs to the input method: it
/// commits the syllable or the conversion and is not a send. Whether text is under composition is read when the key goes down,
/// not afterwards: the Korean input method commits on that very key and the text no longer has a marked part by the time the
/// Return that did it reaches `insertNewline`.
final class ComposerTextView: NSTextView {
    /// Return was pressed with nothing under composition: the text, and whether ⌘ was held.
    var onReturn: ((_ text: String, _ command: Bool) -> Void)?
    /// A key the panel may want for itself (↑ ↓ Esc Tab, and Return without a modifier) went down with nothing under composition:
    /// true when the panel took it, which keeps it from the text.
    var onKey: ((ComposerKey) -> Bool)?
    private var composingAtKeyDown = false

    /// The key as the panel's hook knows it; nil for any other key or one pressed with ⇧ ⌥ ⌃ or ⌘.
    static func key(for event: NSEvent) -> ComposerKey? {
        guard event.modifierFlags.intersection([.shift, .option, .control, .command]).isEmpty else { return nil }
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 53: return .escape
        case 48: return .tab
        case 36, 76: return .returnKey
        default: return nil
        }
    }

    /// The composer in a window's views, if it has one.
    static func find(in window: NSWindow?) -> ComposerTextView? {
        func search(_ view: NSView) -> ComposerTextView? {
            if let found = view as? ComposerTextView { return found }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        return window?.contentView.flatMap(search)
    }

    private static func isReturn(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }

    override func keyDown(with event: NSEvent) {
        composingAtKeyDown = hasMarkedText()
        defer { composingAtKeyDown = false }
        if !composingAtKeyDown, let key = Self.key(for: event), onKey?(key) == true { return }
        guard Self.isReturn(event), !composingAtKeyDown else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) || flags.contains(.option) || flags.contains(.control) || onReturn == nil {
            return super.keyDown(with: event)
        }
        onReturn?(string, flags.contains(.command))
    }

    /// The line break an input method passes on after it committed what it composed is not the user asking for one.
    override func insertNewline(_ sender: Any?) {
        if composingAtKeyDown { return }
        super.insertNewline(sender)
    }
}

/// A keystroke the panel may take from the composer.
enum ComposerKey { case up, down, escape, tab, returnKey }

/// A replacement of part of the text, made from outside the box.
struct ComposerEdit: Equatable {
    let id = UUID()
    var range: NSRange
    var text: String
}

/// `ComposerTextView` in a scroll view, as high as its text (up to `maxLines`).
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    /// A change to make to the text from outside (an "@tab" taken out once it has been picked); it is applied once and then cleared.
    @Binding var edit: ComposerEdit?
    /// Changes when the panel wants the cursor back in the box.
    var focus = 0
    /// The text and where the cursor is, after either changed.
    var onChange: ((_ text: String, _ caret: Int) -> Void)?
    var onKey: ((ComposerKey) -> Bool)?
    var onReturn: (_ text: String, _ command: Bool) -> Void
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let maxLines: CGFloat = 6

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(String(localized: "Ask about this page, or give it a task"))
        textView.onReturn = onReturn
        textView.onKey = onKey
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ComposerTextView else { return }
        // Disabled (the AI can't answer yet): nothing can be typed, and Return sends nothing.
        let enabled = context.environment.isEnabled
        textView.isEditable = enabled
        textView.onReturn = enabled ? onReturn : { _, _ in }
        textView.onKey = enabled ? onKey : nil
        let coordinator = context.coordinator
        coordinator.parent = self
        if textView.string != text && !textView.hasMarkedText() {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        if let edit, edit.id != coordinator.appliedEdit, enabled {
            coordinator.appliedEdit = edit.id
            let range = NSIntersectionRange(edit.range, NSRange(location: 0, length: (textView.string as NSString).length))
            textView.insertText(edit.text, replacementRange: range)
            DispatchQueue.main.async { $edit.wrappedValue = nil }
        }
        if focus != coordinator.focus {
            coordinator.focus = focus
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
        coordinator.measure(textView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        var appliedEdit: UUID?
        var focus: Int

        init(_ parent: ComposerField) {
            self.parent = parent
            focus = parent.focus
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            measure(textView)
            report(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            report(textView)
        }

        /// Out of the update that may be under way, where the panel's state can't change.
        private func report(_ textView: NSTextView) {
            let text = textView.string, caret = textView.selectedRange().location
            DispatchQueue.main.async { [weak self] in self?.parent.onChange?(text, caret) }
        }

        /// The box is as high as the text, one line at least and six at most.
        func measure(_ textView: NSTextView) {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: ComposerField.font)
            let wanted = min(max(layout.usedRect(for: container).height, line), line * ComposerField.maxLines).rounded(.up)
            if abs(parent.height - wanted) > 0.5 {
                DispatchQueue.main.async { [parent] in parent.height = wanted }
            }
        }
    }
}
