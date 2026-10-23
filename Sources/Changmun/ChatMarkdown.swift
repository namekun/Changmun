import AppKit
import SwiftUI

/// A block of an answer. Inline styling (bold, italics, code, links) stays in the text and is drawn by `ChatMarkdown.inline`.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list([ListEntry])
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    case table(header: [String], rows: [[String]])
    case rule

    struct ListEntry: Equatable {
        /// How deep the entry is nested: 0 for the outermost list.
        var depth: Int
        /// "•" for a bullet, else the number as written ("2.").
        var marker: String
        var text: String
    }
}

enum ChatMarkdown {
    /// The inline styling of a piece of text, with its line breaks kept.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// Splits an answer into blocks. A code fence that isn't closed yet (the answer is still streaming) runs to the end.
    static func parse(_ text: String) -> [MarkdownBlock] {
        parse(lines: text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
    }

    private static func parse(lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = fence(trimmed) {
                flush()
                var body: [String] = []
                index += 1
                while index < lines.count, !closes(fence, lines[index].trimmingCharacters(in: .whitespaces)) {
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flush()
                index += 1
            } else if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
                index += 1
            } else if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                index += 1
            } else if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var rest = Substring(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    index += 1
                }
                blocks.append(.quote(parse(lines: quoted)))
            } else if trimmed.contains("|"), index + 1 < lines.count, isSeparator(lines[index + 1]) {
                flush()
                let header = cells(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    var row = cells(lines[index].trimmingCharacters(in: .whitespaces))
                    while row.count < header.count { row.append("") }
                    rows.append(Array(row.prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
            } else if listItem(line) != nil {
                flush()
                var entries: [MarkdownBlock.ListEntry] = []
                var indents: [Int] = []
                while index < lines.count {
                    if let (indent, marker, text) = listItem(lines[index]) {
                        while let last = indents.last, indent < last { indents.removeLast() }
                        if indents.last.map({ indent > $0 }) ?? true { indents.append(indent) }
                        entries.append(.init(depth: indents.count - 1, marker: marker, text: text))
                        index += 1
                    } else if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        // A blank line inside a list that goes on after it.
                        var next = index
                        while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                        guard next < lines.count, listItem(lines[next]) != nil else { break }
                        index = next
                    } else if lines[index].first?.isWhitespace == true, !entries.isEmpty, fence(lines[index].trimmingCharacters(in: .whitespaces)) == nil {
                        entries[entries.count - 1].text += "\n" + lines[index].trimmingCharacters(in: .whitespaces)
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(entries))
            } else {
                paragraph.append(line)
                index += 1
            }
        }
        flush()
        return blocks
    }

    private struct Fence { var marker: Character; var length: Int; var language: String? }

    private static func fence(_ trimmed: String) -> Fence? {
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string has no backticks (`` ```x``` `` on one line is inline code).
        guard marker == "~" || !info.contains("`") else { return nil }
        return Fence(marker: marker, length: length, language: info.split(separator: " ").first.map(String.init))
    }

    private static func closes(_ fence: Fence, _ trimmed: String) -> Bool {
        trimmed.count >= fence.length && trimmed.allSatisfy { $0 == fence.marker }
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level), trimmed.dropFirst(level).first == " " else { return nil }
        var text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: level, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// `- item`, `* item`, `+ item`, `1. item` or `1) item`, with the indentation it has.
    private static func listItem(_ line: String) -> (indent: Int, marker: String, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard !isRule(String(rest)) else { return nil }
            return (indent, "•", text)
        }
        let digits = rest.prefix { $0.isNumber && $0.isASCII }
        guard (1...9).contains(digits.count), let after = rest.dropFirst(digits.count).first, after == "." || after == ")",
              rest.dropFirst(digits.count + 1).first == " " else { return nil }
        return (indent, String(digits) + String(after), rest.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces))
    }

    private static func isSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var text = line.replacingOccurrences(of: "\\|", with: "\u{1}")
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.replacingOccurrences(of: "\u{1}", with: "|").trimmingCharacters(in: .whitespaces) }
    }
}

/// An answer drawn block by block: paragraphs, lists, code (monospaced, scrolling sideways, with a copy button), quotes, headings and tables.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatMarkdown.parse(text).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .heading(let level, let text):
            Text(ChatMarkdown.inline(text))
                .font(.system(size: level == 1 ? 16 : level == 2 ? 15 : 13.5, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
        case .list(let entries):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.marker == "•" && entry.depth > 0 ? "◦" : entry.marker)
                            .foregroundStyle(Theme.secondary)
                            .frame(minWidth: 12, alignment: .trailing)
                        inline(entry.text)
                    }
                    .padding(.leading, CGFloat(entry.depth) * 14)
                }
            }
        case .code(let language, let text):
            CodeBlockView(language: language, code: text)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1, style: .continuous).fill(Theme.hairline).frame(width: 2)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in MarkdownBlockView(block: inner) }
                }
                .foregroundStyle(Theme.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, cell in Text(ChatMarkdown.inline(cell)).font(.system(size: 12, weight: .bold)) } }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(ChatMarkdown.inline(cell)).font(.system(size: 12, weight: .medium)) } }
                    }
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.selected))
        case .rule:
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func inline(_ text: String) -> some View {
        Text(ChatMarkdown.inline(text)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.faint)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9, weight: .semibold))
                        Text(copied ? String(localized: "Copied") : String(localized: "Copy")).font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Copy code"))
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.selected))
    }
}

/// A copy button that says it has copied.
struct CopyTextButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9, weight: .semibold))
                Text(copied ? String(localized: "Copied") : String(localized: "Copy")).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 6).frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Copy answer"))
    }
}
