import AppKit
import SwiftUI

struct QueuedChip: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock").font(.system(size: 8.5, weight: .bold))
            Text(text).lineLimit(1).truncationMode(.tail).frame(maxWidth: 140)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .help("Remove from the queue")
                .accessibilityLabel(String(localized: "Remove from the queue"))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Theme.selected))
        .help(text)
    }
}

struct AttachedTabChip: View {
    @ObservedObject var tab: Tab
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.displayTitle).lineLimit(1).truncationMode(.tail).frame(maxWidth: 110)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .help("Remove from the AI's tabs")
                .accessibilityLabel(String(localized: "Remove from the AI's tabs"))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Theme.selected))
        .help(tab.url?.absoluteString ?? "")
    }
}

struct ChatWelcome: View {
    /// Two or more tabs are attached: suggestions for working across them.
    var several = false
    /// The page in front, which the suggestions fit.
    var kind = PageKind.general
    /// Tapping a suggestion hands it over to be put in the box.
    let send: (String) -> Void
    private var prompts: [String] {
        several
            ? [String(localized: "Compare the attached tabs"), String(localized: "Sum up only the key points of each attached tab")]
            : kind.prompts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How can I help?").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
            Text("I can read the page you're viewing, click, type and open tabs.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(prompts, id: \.self) { prompt in
                    PromptChip(text: prompt) { send(prompt) }
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 4)
    }
}

struct PromptChip: View {
    let text: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "text.cursor").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
                Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(hover ? Theme.field : Theme.hoverTab))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Nunsseop's "working" state: a green dot and how long the run has lasted, to open for the steps it has taken so far.
struct Working: View {
    /// When the run began; the seconds count up from it.
    var started: Date?
    /// What the AI is doing, when a tool says; else just that it is working.
    var step: String?
    /// The steps of the run under way (a `.live` row of the transcript), which opening the line shows.
    var steps: ChatRowModel?
    @State private var on = false
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                TimelineView(.periodic(from: started ?? .now, by: 1)) { context in
                    let elapsed = started.map { ElapsedText.text(seconds: Int(context.date.timeIntervalSince($0))) }
                    let label = elapsed.map { String(localized: "Working for \($0)") } ?? String(localized: "Working")
                    HStack(spacing: 6) {
                        Circle().fill(Theme.working).frame(width: 6, height: 6).opacity(on ? 1 : 0.35)
                        Text(verbatim: label)
                        if let step {
                            Text(verbatim: "·").foregroundStyle(Theme.faint)
                            Text(verbatim: step).lineLimit(1).truncationMode(.middle)
                        }
                        if steps != nil {
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(open ? 180 : 0))
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .contentShape(Rectangle())
                    // The time is a value that keeps changing, not a label to be read again every second.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "Working"))
                    .accessibilityValue(Accessibility.workingValue(elapsed: elapsed, step: step))
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .buttonStyle(.plain)
            .disabled(steps == nil)
            if open, let steps { ChatStepsRow(row: steps) }
        }
        // With Reduce Motion on the dot stays lit instead of pulsing.
        .onAppear { if Motion.reduced { on = true } else { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true } } }
    }
}

/// The card of a page a message went with: its icon, title and site. A saved chat has no icon to show, only the words.
struct AttachedPageCard: View {
    let page: AttachedPage

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let id = page.tabID, let tab = ToolCatalog.findTab(id) {
                    Favicon(tab: tab)
                } else {
                    Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(Theme.faint).frame(width: 16, height: 16)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: page.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.primary)
                    .lineLimit(1).truncationMode(.tail)
                Text(verbatim: page.host).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.faint)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.hoverTab))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline.opacity(0.5), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: page.title + ", " + page.host))
    }
}
