import AppKit
import SwiftUI

/// The one dialog of the app: a sheet on a window, drawn from the design system, for every question the app asks that is not a
/// page's own alert (those stay the system's, because they show text a page wrote). It is a real window sheet, so it stays modal
/// to its window, the system handles the focus, and nothing in a page can draw over it.
@MainActor
enum Dialog {
    /// What happens when the window already has a sheet up.
    enum WhenBusy {
        /// Waits its turn, first come first served. For what the user asked for.
        case wait
        /// Is not shown and answers nil, unless it is the question of one already up or waiting (see `DialogKey`). For what a page or a server can
        /// start by itself: it cannot pile dialogs up, and it cannot jump the ones that wait.
        case refuse
    }

    /// Lets the one who asked take the dialog away again (the question timed out, the tab went, or it was answered elsewhere), whether it is up or
    /// still waiting its turn.
    final class Handle {
        fileprivate var close: (() -> Void)?
        fileprivate var stopWaiting: (() -> Void)?
        fileprivate(set) var closed = false

        func end() {
            closed = true
            stopWaiting?()
            close?()
        }
    }

    /// The window a sheet goes on is the window under any sheets: a window that is itself a sheet never gets one, so sheets don't stack.
    static func root(of window: NSWindow) -> NSWindow {
        var window = window
        while let parent = window.sheetParent { window = parent }
        return window
    }

    /// Shows the dialog on `window` and waits for the user. nil when there is no window, when the window is busy and `whenBusy` is `.refuse`, when
    /// the window closes first, when `handle` ends it, or when the asking task is cancelled while it waits. The same `key` as a question that is up
    /// or waiting does not ask again: it waits for that question and gets its answer.
    static func present(in window: NSWindow?, _ spec: DialogSpec, whenBusy: WhenBusy = .wait, key: DialogKey? = nil, handle: Handle? = nil) async -> DialogResult? {
        guard let start = window else { return nil }
        let window = root(of: start)
        if let key, shared[key] != nil {
            return await withCheckedContinuation { shared[key]?.append($0) }
        }
        let queue = queue(for: window)
        if whenBusy == .refuse, !queue.isIdle(window), key.map({ groups[$0.group, default: 0] == 0 }) ?? true { return nil }
        if let key {
            shared[key] = []
            groups[key.group, default: 0] += 1
        }
        let result = await show(spec, on: window, queue: queue, handle: handle)
        if let key {
            groups[key.group, default: 1] -= 1
            if groups[key.group] == 0 { groups[key.group] = nil }
            for waiter in shared.removeValue(forKey: key) ?? [] { waiter.resume(returning: result) }
        }
        return result
    }

    /// The others that asked the same question while it was up.
    private static var shared: [DialogKey: [CheckedContinuation<DialogResult?, Never>]] = [:]
    /// How many questions of each group are up or waiting.
    private static var groups: [String: Int] = [:]
    private static var queues: [ObjectIdentifier: SheetQueue] = [:]

    private static func queue(for window: NSWindow) -> SheetQueue {
        if let queue = queues[ObjectIdentifier(window)] { return queue }
        let queue = SheetQueue(window: window) { queues[ObjectIdentifier($0)] = nil }
        queues[ObjectIdentifier(window)] = queue
        return queue
    }

    private static func show(_ spec: DialogSpec, on window: NSWindow, queue: SheetQueue, handle: Handle?) async -> DialogResult? {
        guard await queue.acquire(handle: handle) else { return nil }
        guard handle?.closed != true, window.isVisible else {
            queue.give(up: window)
            return nil
        }
        return await withCheckedContinuation { continuation in
            let state = DialogState(spec)
            var sheet: NSWindow?
            var answered = false
            var watch: NSObjectProtocol?
            let resume = { (result: DialogResult?) in
                guard !answered else { return }
                answered = true
                state.stop()
                if let watch { NotificationCenter.default.removeObserver(watch) }
                continuation.resume(returning: result)
                // The next in line goes once the sheet is really gone.
                Task { @MainActor in queue.give(up: window) }
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
            let controller = DialogController(rootView: DialogView(spec: spec, state: state) { press($0) })
            controller.title = spec.title
            controller.sizingOptions = [.preferredContentSize]
            // The moment the sheet is on screen is when its buttons start to count down.
            controller.onShown = { state.shown() }
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
            queue.began()
            lastSheet = panel
            lastState = state
        }
    }

    /// The sheet most recently put up, and what it knows, for the test copy's picture of it.
    private(set) static weak var lastSheet: NSWindow?
    private(set) static weak var lastState: DialogState?
}

/// The questions of one window, in the order they came: one sheet at a time, and nobody jumps the line.
@MainActor
private final class SheetQueue {
    private struct Waiter {
        var id: UUID
        var resume: (Bool) -> Void
    }

    private var waiters: [Waiter] = []
    /// The one whose turn it is, until its sheet is up.
    private var reserved: UUID?
    private var current: UUID?
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    init(window: NSWindow, gone: @escaping (NSWindow) -> Void) {
        self.window = window
        // A sheet of anyone's that ends hands the window to the next waiter; a window that closes lets all of them go.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let all = self.waiters
                self.waiters = []
                for waiter in all { waiter.resume(false) }
                for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
                self.observers = []
                gone(window)
            }
        })
    }

    func isIdle(_ window: NSWindow) -> Bool { reserved == nil && waiters.isEmpty && window.attachedSheet == nil && current == nil }

    /// True when it is this question's turn (its sheet is to go up now); false when it was taken back while it waited.
    func acquire(handle: Dialog.Handle?) async -> Bool {
        let id = UUID()
        if let window, isIdle(window) {
            reserved = id
            current = id
            return true
        }
        handle?.stopWaiting = { [weak self] in self?.cancel(id) }
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters.append(Waiter(id: id) { continuation.resume(returning: $0) })
                if handle?.closed == true { cancel(id) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
        if granted { current = id }
        return granted
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).resume(false)
    }

    /// The sheet is up.
    func began() { reserved = nil }

    /// This question is over (answered, or it never went up).
    func give(up window: NSWindow) {
        reserved = nil
        current = nil
        advance()
    }

    private func advance() {
        guard reserved == nil, current == nil, window?.attachedSheet == nil, !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        reserved = next.id
        next.resume(true)
    }
}

/// A sheet's window: Esc presses the Cancel button even when the keyboard focus is in a field.
private final class DialogWindow: NSWindow {
    var onEscape: () -> Void = {}

    override func cancelOperation(_ sender: Any?) { onEscape() }
}

/// The sheet's content, which says when it is on screen.
private final class DialogController: NSHostingController<DialogView> {
    var onShown: () -> Void = {}

    override func viewDidAppear() {
        super.viewDidAppear()
        onShown()
    }
}

/// What the user has typed and ticked so far, and what tells a click of theirs from one meant for something else.
@MainActor
final class DialogState: ObservableObject {
    @Published var fields: [String]
    @Published var remembered = false
    @Published var picked = 0
    /// False until a guarded question has been on screen for a moment.
    @Published private(set) var armed: Bool
    private let guarded: Bool
    private var shownAt: Date?
    private var lastMouseDown: Date?
    private var lastMouseUp: Date?
    private var lastKeyDown: (at: Date, isRepeat: Bool)?
    private var monitor: Any?
    private var timer: Task<Void, Never>?

    init(_ spec: DialogSpec) {
        fields = spec.fields.map(\.text)
        guarded = spec.guarded
        armed = !spec.guarded
    }

    /// The sheet is on screen: the clicks and keys that count are those that come from here on, after the delay.
    func shown() {
        guard guarded, shownAt == nil else { return }
        shownAt = Date()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
            switch event.type {
            case .leftMouseDown: self?.lastMouseDown = Date()
            case .leftMouseUp: self?.lastMouseUp = Date()
            default: self?.lastKeyDown = (Date(), event.isARepeat)
            }
            return event
        }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(ApprovalKeys.yesDelay)) } catch { return }
            self?.armed = true
        }
    }

    func stop() {
        timer?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func mayPress(_ index: Int, in spec: DialogSpec, now: Date = Date()) -> Bool {
        DialogGate.mayPress(guarded: guarded, safe: spec.isSafe(index), shownAt: shownAt, mouseDownAt: lastMouseDown, mouseUpAt: lastMouseUp, keyDown: lastKeyDown, now: now)
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
                if let note = spec.note {
                    Text(verbatim: note).font(.caption).foregroundStyle(Theme.secondary)
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
            // Three or more answers, or a long one, go one under the other at the full width, so that no word is cut off.
            if spec.buttons.count >= 3 {
                VStack(spacing: 8) {
                    ForEach(Array(spec.buttons.enumerated()), id: \.offset) { index, button in buttonView(index, button, full: true) }
                }
                .padding(.top, 8)
            } else {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ForEach(Array(spec.buttons.enumerated()), id: \.offset) { index, button in buttonView(index, button, full: false) }
                }
                .padding(.top, 8)
            }
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
            if index + 1 < spec.fields.count { focusedField = index + 1 } else if let button = spec.defaultIndex, state.mayPress(button, in: spec) { press(button) }
        }
    }

    @ViewBuilder
    private func buttonView(_ index: Int, _ button: DialogButton, full: Bool) -> some View {
        let action = Button { if state.mayPress(index, in: spec) { press(index) } } label: {
            Text(verbatim: button.title).lineLimit(3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: full ? .infinity : nil)
        }
        let isDefault = spec.defaultIndex == index
        let styled = Group {
            switch spec.style(of: index) {
            case .primary: action.buttonStyle(PrimaryButton(size: .regular))
            case .secondary: action.buttonStyle(SecondaryButton(size: .regular))
            case .danger: action.buttonStyle(DangerButton(size: .regular))
            }
        }
        .disabled(!state.armed && !spec.isSafe(index))
        if isDefault {
            styled.keyboardShortcut(.defaultAction).accessibilityFocused($defaultFocused)
        } else {
            styled
        }
    }
}
