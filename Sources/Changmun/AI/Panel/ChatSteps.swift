import AppKit
import SwiftUI

/// How a tool step went, from the tool result the AI got back.
enum StepOutcome: String, Codable, Equatable {
    case ok, failed, denied
    /// Not allowed because the user didn't answer the question in time.
    case unanswered

    /// From a tool result's text: the user refusing (or the app refusing for them), and a question nobody answered, are told apart from a failure.
    static func of(error: Bool, text: String) -> StepOutcome {
        guard error else { return .ok }
        if text.hasPrefix("Not allowed: the user didn't answer") { return .unanswered }
        return text.localizedCaseInsensitiveContains("declined") || text.hasPrefix("Refused") ? .denied : .failed
    }

    var isProblem: Bool { self != .ok }
}

/// What the AI did to the user's tabs in one turn (a message and the answer to it), counted from its steps that worked.
struct TurnSummary: Equatable {
    var turn: Int
    var opened = 0
    var closed = 0
    var navigated = 0

    var isEmpty: Bool { opened + closed + navigated == 0 }

    var text: String {
        var parts: [String] = []
        if opened > 0 { parts.append(opened == 1 ? String(localized: "Opened \(opened) tab") : String(localized: "Opened \(opened) tabs")) }
        if closed > 0 { parts.append(closed == 1 ? String(localized: "Closed \(closed) tab") : String(localized: "Closed \(closed) tabs")) }
        if navigated > 0 { parts.append(navigated == 1 ? String(localized: "Went to \(navigated) page") : String(localized: "Went to \(navigated) pages")) }
        return parts.joined(separator: " · ")
    }
}

/// What the transcript shows: a message, a few live step chips, a folded run of steps, or what a turn did to the tabs.
enum ChatRowModel: Identifiable, Equatable {
    case item(ChatItem)
    /// Steps of the run under way: the latest ones, and how many earlier ones are left out.
    case live(id: UUID, hidden: Int, steps: [ChatItem])
    /// Steps of a run that is over, folded into one row.
    case folded(id: UUID, steps: [ChatItem])
    case summary(TurnSummary)

    var id: AnyHashable {
        switch self {
        case .item(let item): item.id
        case .live(let id, _, _), .folded(let id, _): id
        case .summary(let summary): "summary-\(summary.turn)"
        }
    }
}

enum ChatLayout {
    /// How many steps of a run under way are shown; more than `foldAt` steps and only these are.
    static let liveVisible = 4
    static let liveLimit = 5

    /// The rows for the items. A step that failed or was declined is always a row of its own; the others of a turn's run of steps are
    /// kept to the latest few while it lasts and folded into one row when it is over. Each turn that changed tabs ends with a line saying so.
    static func rows(_ items: [ChatItem], running: Bool) -> [ChatRowModel] {
        var rows: [ChatRowModel] = []
        var group: [ChatItem] = []
        var summary = TurnSummary(turn: 0)

        func flush(live: Bool) {
            guard !group.isEmpty else { return }
            defer { group.removeAll() }
            let fine = group.filter { !($0.outcome?.isProblem ?? false) }
            if live {
                let hide = fine.count > liveLimit ? fine.count - liveVisible : 0
                let hidden = Set(fine.prefix(hide).map(\.id))
                rows.append(.live(id: group[0].id, hidden: hide, steps: group.filter { !hidden.contains($0.id) }))
            } else if fine.count >= 2 {
                rows.append(.folded(id: fine[0].id, steps: fine))
                rows += group.filter { $0.outcome?.isProblem ?? false }.map(ChatRowModel.item)
            } else {
                rows += group.map(ChatRowModel.item)
            }
        }
        func endTurn(live: Bool) {
            flush(live: live)
            if !live, !summary.isEmpty { rows.append(.summary(summary)) }
        }

        for item in items {
            if item.kind == .user {
                endTurn(live: false)
                summary = TurnSummary(turn: summary.turn + 1)
                rows.append(.item(item))
            } else if item.kind == .tool {
                group.append(item)
                if item.outcome == .ok {
                    switch item.tool {
                    case "open_tab": summary.opened += 1
                    case "close_tab": summary.closed += 1
                    case "navigate": summary.navigated += 1
                    default: break
                    }
                }
            } else {
                flush(live: false)
                rows.append(.item(item))
            }
        }
        endTurn(live: running)
        return rows
    }
}

/// A tool step: a chip with the symbol of the tool, what it did, and a mark when it didn't work out.
struct StepChip: View {
    let item: ChatItem

    private var label: String { item.text + (item.title.map { " · " + $0 } ?? "") }

    private var outcomeWord: String? {
        switch item.outcome {
        case .failed: String(localized: "Failed")
        case .denied: String(localized: "Declined")
        case .unanswered: String(localized: "No answer")
        default: nil
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: item.symbol ?? "cursorarrow.rays").font(.symbolInline)
            Text(label).lineLimit(1).truncationMode(.middle)
            if item.outcome == .unanswered, let outcomeWord {
                // Said in words: a question that ran out of time is not the user's no.
                Image(systemName: "clock").font(.symbolInline)
                Text(verbatim: outcomeWord).lineLimit(1).fixedSize()
            } else if item.outcome?.isProblem == true {
                Image(systemName: item.outcome == .denied ? "hand.raised" : "exclamationmark.triangle").font(.symbolInline)
            }
        }
        .font(.captionStrong)
        .foregroundStyle(item.outcome?.isProblem == true ? Theme.waitingText : Theme.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Theme.selected))
        .help(label + (outcomeWord.map { " · " + $0 } ?? ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label + (outcomeWord.map { ", " + $0 } ?? ""))
    }
}

/// The steps of one run: while it lasts, the latest few; after it, one row to open.
struct ChatStepsRow: View {
    let row: ChatRowModel
    @State private var open = false

    var body: some View {
        switch row {
        case .live(_, let hidden, let steps):
            VStack(alignment: .leading, spacing: 8) {
                if hidden > 0 {
                    Text("+\(hidden) earlier steps").font(.captionStrong).foregroundStyle(Theme.secondary)
                }
                ForEach(steps) { StepChip(item: $0) }
            }
        case .folded(_, let steps):
            VStack(alignment: .leading, spacing: 8) {
                Button { open.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").font(.symbolInline).rotationEffect(.degrees(open ? 90 : 0))
                        Text("\(steps.count) steps").font(.captionStrong)
                    }
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Theme.selected))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(steps.count) steps"))
                if open { ForEach(steps) { StepChip(item: $0) } }
            }
        default:
            EmptyView()
        }
    }
}

/// The line after a turn that opened, closed or navigated tabs, with the way back for tabs the AI closed.
struct TurnSummaryRow: View {
    let summary: TurnSummary
    /// The panel's chat, which knows the tabs the AI closed and can bring them back; nil in a saved chat.
    var chat: ChatStore?
    @State private var reopened = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.on.square").font(.symbolInline)
            Text(summary.text).lineLimit(2)
            if let chat, !reopened, chat.canReopen(turn: summary.turn) {
                Button("Reopen") {
                    chat.reopenClosed(turn: summary.turn)
                    reopened = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.primary)
            }
        }
        .font(.captionStrong)
        .foregroundStyle(Theme.secondary)
        .accessibilityElement(children: .combine)
    }
}
