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

/// Nunsseop's "working" state: a green dot and a word.
struct Working: View {
    /// What the AI is doing, when a tool says; else just that it is working.
    var step: String?
    @State private var on = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.working).frame(width: 6, height: 6).opacity(on ? 1 : 0.35)
            Text(step ?? String(localized: "Working")).lineLimit(1).truncationMode(.middle)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Working") + (step.map { ", " + $0 } ?? ""))
    }
}
