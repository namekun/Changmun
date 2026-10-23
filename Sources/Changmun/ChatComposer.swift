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
    private var composingAtKeyDown = false

    private static func isReturn(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }

    override func keyDown(with event: NSEvent) {
        composingAtKeyDown = hasMarkedText()
        defer { composingAtKeyDown = false }
        guard Self.isReturn(event), !composingAtKeyDown else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) || flags.contains(.option) || flags.contains(.control) || onReturn == nil {
            return super.keyDown(with: event)
        }
        onReturn?(string, flags.contains(.command))
    }

    /// A picture on the clipboard (or a picture file copied in Finder) is not text: it becomes an image for the next message.
    override func paste(_ sender: Any?) {
        guard ImageIntake.hasPicture(.general) else { return super.paste(sender) }
        Task { @MainActor in ChatStore.shared.addImages(ImageIntake.sources(on: .general)) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageIntake.hasPicture(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard ImageIntake.hasPicture(sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        let sources = ImageIntake.sources(on: sender.draggingPasteboard)
        Task { @MainActor in ChatStore.shared.addImages(sources) }
        return true
    }

    /// The line break an input method passes on after it committed what it composed is not the user asking for one.
    override func insertNewline(_ sender: Any?) {
        if composingAtKeyDown { return }
        super.insertNewline(sender)
    }
}

/// `ComposerTextView` in a scroll view, as high as its text (up to `maxLines`).
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
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
        context.coordinator.parent = self
        if textView.string != text && !textView.hasMarkedText() { textView.string = text }
        context.coordinator.measure(textView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField

        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            measure(textView)
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
