import AppKit
import SwiftUI

// What the AI panel's box does besides typing: "@" to attach a tab, ↑ to bring back the last message, ⌘E and Esc.

/// The "@word" the cursor is at the end of, which asks for a tab.
enum ComposerMention {
    struct Token: Equatable {
        /// From the "@" to the cursor.
        var range: NSRange
        /// What was typed after the "@".
        var query: String
    }

    /// The token ending at `caret`: an "@" that starts the text or follows a space or a line break, and letters after it with
    /// none of those in between. An address like "me@example.com" has no such "@".
    static func token(in text: String, caret: Int) -> Token? {
        let string = text as NSString
        guard caret >= 1, caret <= string.length else { return nil }
        var start = caret
        while start > 0 {
            let unit = string.character(at: start - 1)
            if unit == 0x40 {
                guard start == 1 || isSpace(string.character(at: start - 2)) else { return nil }
                let range = NSRange(location: start - 1, length: caret - start + 1)
                return Token(range: range, query: string.substring(with: NSRange(location: start, length: caret - start)))
            }
            if isSpace(unit) { return nil }
            start -= 1
        }
        return nil
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        Unicode.Scalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }

    /// How well a tab fits what was typed: 0 for one whose title or host starts with it, 1 for one that has it somewhere, nil for none.
    static func rank(title: String, host: String?, query: String) -> Int? {
        let wanted = query.lowercased()
        if wanted.isEmpty { return 0 }
        let title = title.lowercased(), host = (host ?? "").lowercased().replacingOccurrences(of: "www.", with: "", options: .anchored)
        if title.hasPrefix(wanted) || host.hasPrefix(wanted) { return 0 }
        return title.contains(wanted) || host.contains(wanted) ? 1 : nil
    }

    /// The tabs that fit, the best fits first and the rest in the order given.
    @MainActor
    static func filter(_ tabs: [Tab], query: String) -> [Tab] {
        let ranked = tabs.compactMap { tab in rank(title: tab.displayTitle, host: tab.url?.host(), query: query).map { (tab, $0) } }
        return ranked.filter { $0.1 == 0 }.map(\.0) + ranked.filter { $0.1 == 1 }.map(\.0)
    }

    /// What to cut out of the text once the tab is picked: the token, and a space beside it so that no gap is left.
    static func removalRange(for token: Token, in text: String) -> NSRange {
        let string = text as NSString
        var range = token.range
        let end = NSMaxRange(range)
        if end < string.length, string.character(at: end) == 0x20 {
            range.length += 1
        } else if end == string.length, range.location > 0, string.character(at: range.location - 1) == 0x20 {
            range.location -= 1
            range.length += 1
        }
        return range
    }
}

/// The messages sent, for ↑ in an empty box to bring back (↓ goes forward again, and out to the empty box).
final class ComposerHistory {
    static let shared = ComposerHistory()
    static let limit = 50
    private(set) var entries: [String] = []
    private var cursor: Int?

    func add(_ message: String) {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        cursor = nil
        guard !message.isEmpty, entries.last != message else { return }
        entries.append(message)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// The message ↑ brings back: the last one into an empty box, then the one before it, as long as the text is still what was
    /// brought back. Nil when ↑ is the box's own (there is text of the user's, or nothing was sent).
    func older(current: String) -> String? {
        if let cursor {
            guard entries.indices.contains(cursor), entries[cursor] == current else { self.cursor = nil; return nil }
            self.cursor = max(cursor - 1, 0)
            return entries[self.cursor!]
        }
        guard current.isEmpty, let last = entries.indices.last else { return nil }
        cursor = last
        return entries[last]
    }

    /// The message ↓ brings back after ↑, or the empty box once the last is passed. Nil when nothing was brought back.
    func newer(current: String) -> String? {
        guard let cursor, entries.indices.contains(cursor), entries[cursor] == current else { self.cursor = nil; return nil }
        if cursor == entries.count - 1 {
            self.cursor = nil
            return ""
        }
        self.cursor = cursor + 1
        return entries[cursor + 1]
    }
}

/// What ⌘E does while the AI panel is up: it is where the cursor goes first, and the key that shuts it from there.
enum AIPanelShortcut {
    enum Box { case missing, elsewhere, focused }
    enum Action { case open, focusBox, close }

    static func action(panelOpen: Bool, focusMode: Bool, box: Box) -> Action {
        // In focus mode the panel is hidden whatever its setting: the key opens it, which ends focus mode.
        if focusMode || !panelOpen { return .open }
        return box == .elsewhere ? .focusBox : .close
    }

    /// ⌘E while the panel is popped out (so it is open): it never opens. In the pop-out with the cursor elsewhere than in its box, the cursor goes
    /// to the box; anywhere else it closes the panel, as the X in the header does.
    static func popOutAction(inPopOut: Bool, box: Box) -> Action {
        inPopOut && box == .elsewhere ? .focusBox : .close
    }
}

extension Browser {
    /// Closes the AI panel and gives the cursor back to the page, which the box was holding.
    func closeChat() {
        showChat = false
        DispatchQueue.main.async { [weak self] in
            guard let self, let window, let page = active?.webView, !showChat else { return }
            window.makeFirstResponder(page)
        }
    }
}

/// A selection from a page, as the block quoted at the top of the box.
enum ComposerQuote {
    static let limit = 2000

    static func block(from selection: String) -> String? {
        var text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > limit { text = String(text.prefix(limit)) + "…" }
        return text.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n") + "\n\n"
    }
}

// MARK: Views

/// The card the box's choices come up in, over the panel.
struct ComposerPopup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) { content }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardEdge, lineWidth: 1))
            .shadow(color: Theme.cardShadow, radius: 10, y: 3)
    }
}

struct ComposerPopupRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected || hover ? Theme.selected : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The window's tabs that fit what follows the "@", for ↑ ↓ and Return (or a click) to pick one.
struct TabMentionList: View {
    let tabs: [Tab]
    let selection: Int
    let pick: (Tab) -> Void

    var body: some View {
        ComposerPopup {
            if tabs.isEmpty {
                Text("No matching tabs").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 8).frame(height: 28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                TabMentionRow(tab: tab, selected: index == selection) { pick(tab) }.id(tab.id)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(height: min(CGFloat(tabs.count), 6) * 29)
                    .onChange(of: selection) { if tabs.indices.contains(selection) { proxy.scrollTo(tabs[selection].id) } }
                }
            }
        }
    }
}

private struct TabMentionRow: View {
    @ObservedObject var tab: Tab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        ComposerPopupRow(selected: selected, action: action) {
            HStack(spacing: 8) {
                Favicon(tab: tab)
                Text(tab.displayTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let host = tab.url?.host() {
                    Text(verbatim: host).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 110, alignment: .trailing)
                }
            }
        }
    }
}

/// The tab the AI will take as the current one, which follows the tab in front. Only told, not a choice: it can't be taken off, and
/// it is drawn as an outline where the tabs the user attached are filled.
struct CurrentTabChip: View {
    @ObservedObject var tab: Tab

    var body: some View {
        HStack(spacing: 5) {
            Favicon(tab: tab)
            Text(tab.displayTitle).lineLimit(1).truncationMode(.tail).frame(maxWidth: 110, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.secondary)
        .padding(.leading, 5)
        .padding(.trailing, 9)
        .frame(height: 22)
        .background(Capsule().strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .help("The tab the AI treats as current: it follows the tab you are viewing")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current tab: \(tab.displayTitle)")
    }
}

/// The panel's left edge: drag to resize, double-click for the default width.
struct AIPanelResizeHandle: View {
    @Binding var width: Double
    @State private var start: Double?
    @State private var hover = false

    var body: some View {
        Rectangle()
            .fill(hover || start != nil ? Theme.hairline : .clear)
            .frame(width: 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let base = start ?? width
                        start = base
                        width = Preferences.clampedAIPanelWidth((base - drag.translation.width).rounded())
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { width = Preferences.defaultAIPanelWidth }
            .help("Drag to resize the AI panel · double-click for default width")
            .accessibilityElement()
            .accessibilityLabel(String(localized: "AI Panel Width"))
            .accessibilityValue(Accessibility.widthValue(width))
            .accessibilityAdjustableAction { direction in
                width = Preferences.clampedAIPanelWidth(Accessibility.adjusted(width, direction, step: 20, in: 0...10_000))
            }
    }
}
