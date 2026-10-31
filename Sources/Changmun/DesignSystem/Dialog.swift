import AppKit
import SwiftUI

/// The one dialog of the app: a sheet on a window, drawn from the design system, for every question the app asks that is not a
/// page's own alert (those stay the system's, because they show text a page wrote). It is a real window sheet, so it stays modal
/// to its window, the system handles the focus, and nothing in a page can draw over it.
@MainActor
enum Dialog {
    /// What happens when the window already has a sheet up.
    enum WhenBusy {
        /// Waits for it to end, as sheets always have. For what the user asked for.
        case wait
        /// Is not shown and answers nil. For what a page or a server can start by itself: it cannot pile dialogs up.
        case refuse
    }

    /// Lets the one who asked take the dialog away again (the question timed out, or was answered elsewhere).
    final class Handle {
        fileprivate var close: (() -> Void)?
        fileprivate var closed = false

        func end() {
            closed = true
            close?()
        }
    }

    /// Shows the dialog on `window` and waits for the user. nil when there is no window, when the window is busy and `whenBusy` is
    /// `.refuse`, when the window closes first, or when `handle` ends it.
    static func present(in window: NSWindow?, _ spec: DialogSpec, whenBusy: WhenBusy = .wait, handle: Handle? = nil) async -> DialogResult? {
        guard let window else { return nil }
        if whenBusy == .refuse, window.attachedSheet != nil { return nil }
        // A sheet that is up is waited for, here and not by AppKit's queue: a dialog that is not up yet can then still be taken back.
        while window.attachedSheet != nil, handle?.closed != true {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard handle?.closed != true, window.isVisible else { return nil }
        return await withCheckedContinuation { continuation in
            let state = DialogState(spec)
            var sheet: NSWindow?
            var answered = false
            var watch: NSObjectProtocol?
            let resume = { (result: DialogResult?) in
                guard !answered else { return }
                answered = true
                if let watch { NotificationCenter.default.removeObserver(watch) }
                continuation.resume(returning: result)
            }
            var chosen: DialogResult?
            let press = { (index: Int?) in
                if let index, spec.buttons.indices.contains(index) {
                    chosen = DialogResult(button: index, fields: state.fields, remembered: state.remembered, picked: state.picked)
                }
                guard let sheet, sheet.sheetParent != nil else { return resume(chosen) }
                window.endSheet(sheet)
                resume(chosen)
            }
            let controller = NSHostingController(rootView: DialogView(spec: spec, state: state) { press($0) })
            controller.title = spec.title
            controller.sizingOptions = [.preferredContentSize]
            let panel = DialogWindow(contentViewController: controller)
            panel.styleMask = [.titled]
            panel.onEscape = { if let index = spec.cancelIndex { press(index) } }
            sheet = panel
            handle?.close = { press(nil) }
            // The window going away takes its sheet with it: nobody is left to answer.
            watch = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { press(nil) }
            }
            window.beginSheet(panel) { _ in MainActor.assumeIsolated { resume(chosen) } }
            lastSheet = panel
        }
    }

    /// The sheet most recently put up, for the test copy's picture of it.
    private(set) static weak var lastSheet: NSWindow?
}

/// A sheet's window: Esc presses the Cancel button even when the keyboard focus is in a field.
private final class DialogWindow: NSWindow {
    var onEscape: () -> Void = {}

    override func cancelOperation(_ sender: Any?) { onEscape() }
}

/// What the user has typed and ticked so far.
@MainActor
final class DialogState: ObservableObject {
    @Published var fields: [String]
    @Published var remembered = false
    @Published var picked = 0

    init(_ spec: DialogSpec) {
        fields = spec.fields.map(\.text)
    }
}

struct DialogView: View {
    let spec: DialogSpec
    @ObservedObject var state: DialogState
    let press: (Int) -> Void
    @FocusState private var focusedField: Int?
    @AccessibilityFocusState private var defaultFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: spec.title).font(.title).foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let message = spec.message {
                    Text(verbatim: message).font(.body).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let detail = spec.detail { detailBox(detail) }
            ForEach(Array(spec.fields.enumerated()), id: \.offset) { index, field in fieldView(index, field) }
            if !spec.choices.isEmpty {
                Picker(selection: $state.picked) {
                    ForEach(Array(spec.choices.enumerated()), id: \.offset) { index, choice in Text(verbatim: choice).tag(index) }
                } label: { Text(verbatim: spec.choicesLabel) }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel(spec.choicesLabel)
            }
            if let remember = spec.remember {
                Toggle(isOn: $state.remembered) { Text(verbatim: remember).font(.secondary).foregroundStyle(Theme.secondary) }
                    .toggleStyle(.checkbox)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(Array(spec.buttons.enumerated()), id: \.offset) { index, button in buttonView(index, button) }
            }
            .padding(.top, 8)
        }
        // Esc presses the Cancel button, which may be the very button Return presses, so it has a button of its own that nobody sees.
        .background {
            if let cancel = spec.cancelIndex {
                Button { press(cancel) } label: { EmptyView() }.keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(Theme.card)
        .onAppear {
            // The keyboard goes to the first field; with none, VoiceOver lands on the button Return presses, after the title and the message.
            if spec.fields.isEmpty { DispatchQueue.main.async { defaultFocused = true } } else { focusedField = 0 }
        }
    }

    @ViewBuilder
    private func detailBox(_ detail: DialogDetail) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
        switch detail {
        case .text(let text):
            ScrollView {
                Text(verbatim: text).font(.secondary).foregroundStyle(Theme.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxHeight: 200)
            .fixedSize(horizontal: false, vertical: true)
            .background(shape.fill(Theme.field))
        }
    }

    @ViewBuilder
    private func fieldView(_ index: Int, _ field: DialogField) -> some View {
        Group {
            if field.isSecure {
                SecureField(field.placeholder, text: $state.fields[index])
            } else {
                TextField(field.placeholder, text: $state.fields[index])
            }
        }
        .textFieldStyle(.plain).font(.body)
        .padding(.horizontal, 16).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).fill(Theme.field))
        .focused($focusedField, equals: index)
        .accessibilityLabel(field.placeholder)
        // Return in a field goes on to the next one, and from the last presses the button Return presses.
        .onSubmit {
            if index + 1 < spec.fields.count { focusedField = index + 1 } else if let button = spec.defaultIndex { press(button) }
        }
    }

    @ViewBuilder
    private func buttonView(_ index: Int, _ button: DialogButton) -> some View {
        let action = Button { press(index) } label: { Text(verbatim: button.title).lineLimit(1) }
        let isDefault = spec.defaultIndex == index
        let styled = Group {
            switch spec.style(of: index) {
            case .primary: action.buttonStyle(PrimaryButton(size: .regular))
            case .secondary: action.buttonStyle(SecondaryButton(size: .regular))
            case .danger: action.buttonStyle(DangerButton(size: .regular))
            }
        }
        if isDefault {
            styled.keyboardShortcut(.defaultAction).accessibilityFocused($defaultFocused)
        } else {
            styled
        }
    }
}
