import AppKit
import SwiftUI

struct QueuedChip: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock").font(.symbolInline)
            Text(text).lineLimit(1).truncationMode(.tail).frame(maxWidth: 140)
            Button(action: remove) { Image(systemName: "xmark").font(.symbolInline) }
                .buttonStyle(.plain)
                .help("Remove from the queue")
                .accessibilityLabel(String(localized: "Remove from the queue"))
        }
        .font(.captionStrong)
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 8)
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
            Button(action: remove) { Image(systemName: "xmark").font(.symbolInline) }
                .buttonStyle(.plain)
                .help("Remove from the AI's tabs")
                .accessibilityLabel(String(localized: "Remove from the AI's tabs"))
        }
        .font(.captionStrong)
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 8)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("How can I help?").font(.title).foregroundStyle(Theme.primary)
            Text("I can read the page you're viewing, click, type and open tabs.")
                .font(.secondary).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
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
            HStack(spacing: 4) {
                Image(systemName: "text.cursor").font(.symbolInline).foregroundStyle(Theme.tertiary)
                Text(text).font(.secondaryStrong).foregroundStyle(Theme.primary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Capsule().fill(hover ? Theme.field : Theme.hoverTab))
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hover = $0 }
    }
}

/// The "working" state: how long the run has lasted, in words, to open for the steps it has taken so far.
struct Working: View {
    /// When the run began; the seconds count up from it.
    var started: Date?
    /// What the AI is doing, when a tool says; else just that it is working.
    var step: String?
    /// The steps of the run under way (a `.live` row of the transcript), which opening the line shows.
    var steps: ChatRowModel?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                TimelineView(.periodic(from: started ?? .now, by: 1)) { context in
                    let elapsed = started.map { ElapsedText.text(seconds: Int(context.date.timeIntervalSince($0))) }
                    let label = elapsed.map { String(localized: "Working for \($0)") } ?? String(localized: "Working")
                    HStack(spacing: 4) {
                        Text(verbatim: label)
                        if let step {
                            Text(verbatim: "·").foregroundStyle(Theme.secondary)
                            Text(verbatim: step).lineLimit(1).truncationMode(.middle)
                        }
                        if steps != nil {
                            Image(systemName: "chevron.down").font(.symbolInline).rotationEffect(.degrees(open ? 180 : 0))
                        }
                    }
                    .font(.caption)
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
                    Image(systemName: "globe").font(.symbolToolbar).foregroundStyle(Theme.tertiary).frame(width: 16, height: 16)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: page.title).font(.captionStrong).foregroundStyle(Theme.primary)
                    .lineLimit(1).truncationMode(.tail)
                Text(verbatim: page.host).font(.caption).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Theme.hoverTab))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Theme.hairline.opacity(0.5), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: page.title + ", " + page.host))
    }
}
