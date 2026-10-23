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
    /// How deep quotes nest and how far a list indents: what goes deeper is plain text (a quote) or sits at the deepest level (a list),
    /// so an answer made of thousands of ">" or of indentation can't take the parser or the view down.
    static let maxQuoteDepth = 4
    static let maxListDepth = 6

    /// The inline styling of a piece of text, with its line breaks kept. Only http and https links stay links, and each one says
    /// where it goes (see `ChatLinks`).
    static func inline(_ text: String) -> AttributedString {
        ChatLinks.annotate((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }

    /// Splits an answer into blocks. A code fence that isn't closed yet (the answer is still streaming) runs to the end.
    static func parse(_ text: String) -> [MarkdownBlock] {
        parse(lines: text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"), quoteDepth: 0)
    }

    private static func parse(lines: [String], quoteDepth: Int) -> [MarkdownBlock] {
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
            } else if trimmed.hasPrefix(">"), quoteDepth < maxQuoteDepth {
                flush()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var rest = Substring(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    index += 1
                }
                blocks.append(.quote(parse(lines: quoted, quoteDepth: quoteDepth + 1)))
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
                        entries.append(.init(depth: min(indents.count - 1, maxListDepth), marker: marker, text: text))
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
                MarkdownBlockView(block: block, quoteDepth: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    /// How many quotes this one is inside: past `ChatMarkdown.maxQuoteDepth` it is drawn without a bar, however it was made.
    let quoteDepth: Int

    var body: some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .heading(let level, let text):
            linked(text)
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
                    .padding(.leading, CGFloat(min(entry.depth, ChatMarkdown.maxListDepth)) * 14)
                }
            }
        case .code(let language, let text):
            CodeBlockView(language: language, code: text)
        case .quote(let blocks):
            if quoteDepth >= ChatMarkdown.maxQuoteDepth {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in MarkdownBlockView(block: inner, quoteDepth: quoteDepth) }
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous).fill(Theme.hairline).frame(width: 2)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in MarkdownBlockView(block: inner, quoteDepth: quoteDepth + 1) }
                    }
                    .foregroundStyle(Theme.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, cell in linked(cell).font(.system(size: 12, weight: .bold)) } }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in linked(cell).font(.system(size: 12, weight: .medium)) } }
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
        linked(text).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    /// The text with its links, which show where they go, and the whole addresses as the tooltip.
    private func linked(_ text: String) -> some View {
        Text(ChatMarkdown.inline(text)).help(ChatLinks.urls(in: text).map(\.absoluteString).joined(separator: "\n"))
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


/// What an answer's links may be and say. The AI's text can come from a page, so a link in it is a place the page chose: it opens only if it
/// is http(s) with no user name or password, it always names its host in ASCII next to its words (unless the words are that very address),
/// and once the chat has read a site other than the one a link goes to, the link is asked about first, with the whole address in front of
/// the user: what was read can ride out in any part of an address.
enum ChatLinks {
    /// Whether the address may be opened from an answer: http or https, with a host and no user name or password.
    static func isSafe(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return false }
        return true
    }

    /// The host as it is shown next to a link: as `Approvals.site` writes it (lowercased, an international name in its ASCII "xn--" form,
    /// with the port when it isn't the scheme's own), so a look-alike name can be told from the one it imitates.
    static func host(of url: URL) -> String? {
        guard isSafe(url), let site = Approvals.site(of: url) else { return nil }
        return site.hasPrefix("http://") ? String(site.dropFirst(7)) : site
    }

    /// Whether the words of a link are themselves the address it goes to, so that naming the host again would add nothing: the host alone
    /// (or with or without "www."), or the address written out (with or without a scheme) whose host is exactly that, in plain ASCII.
    /// Words that only contain the host, or have more in them, don't count.
    static func textIs(_ text: String, host: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), host = host.lowercased()
        guard !text.isEmpty, !host.isEmpty, text.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return false }
        if text == host || text == "www." + host || host == "www." + text { return true }
        let written = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: written), isSafe(url), let shown = Self.host(of: url) else { return false }
        return shown == host || shown == "www." + host || host == "www." + shown
    }

    /// The links of an answer's text that may be opened.
    static func urls(in text: String) -> [URL] {
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return [] }
        return parsed.runs.compactMap(\.link).filter(isSafe)
    }

    /// Takes the link off what may not be opened, and puts the host after the words of every link that aren't the address itself.
    static func annotate(_ input: AttributedString) -> AttributedString {
        var output = AttributedString()
        var group: Range<AttributedString.Index>?
        var groupLink: URL?
        func finish() {
            guard let range = group else { return }
            var piece = AttributedString(input[range])
            if let link = groupLink {
                if let host = host(of: link) {
                    output.append(piece)
                    if !textIs(String(piece.characters), host: host) {
                        var note = AttributedString(" (\(host))")
                        note.font = .system(size: 10.5, weight: .medium)
                        note.foregroundColor = Theme.secondary
                        output.append(note)
                    }
                    group = nil
                    return
                }
                piece.link = nil
            }
            output.append(piece)
            group = nil
        }
        for run in input.runs {
            if group != nil, run.link == groupLink {
                group = group.map { $0.lowerBound..<run.range.upperBound }
            } else {
                finish()
                group = run.range
                groupLink = run.link
            }
        }
        finish()
        return output
    }

    /// Whether to ask before opening, as `Approvals.allowInteraction` asks about using a page: the chat has read a site other than the one
    /// the link goes to (`read`, as `Approvals.sitesRead` lists them). Then a page it read could have slipped the link in to carry what it
    /// read elsewhere to the destination, in any part of the address; a site that is open in a tab is no safer, so that doesn't count.
    static func needsConfirmation(_ url: URL, read: [String]) -> Bool {
        guard let site = Approvals.site(of: url) else { return !read.isEmpty }
        return !Set(read).subtracting([site]).isEmpty
    }

    /// Opens a link of an answer in a new tab, after the question when it needs one.
    @MainActor
    static func open(_ url: URL) -> OpenURLAction.Result {
        guard isSafe(url) else { return .discarded }
        if needsConfirmation(url, read: Approvals.sitesRead(caller: ChatStore.caller)) {
            let alert = NSAlert()
            let host = host(of: url) ?? ""
            alert.messageText = String(localized: "Open a link to \(host)?")
            alert.informativeText = String(localized: "This chat has read other sites, and a page could have slipped this link in to send what the AI read there.")
                + "\n\n" + Approvals.shown(url.absoluteString, limit: 1000).text
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Open"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .handled }
        }
        let target = Browser.recent ?? BrowserWindow.open()
        target.openTab(url: url, after: target.active)
        return .handled
    }
}
