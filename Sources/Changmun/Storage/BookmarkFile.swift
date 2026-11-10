import Foundation

/// Bookmarks as the Netscape bookmark file every browser exports and imports (an HTML page of `<DL>` lists): written from the library, and
/// read from Chrome's, Firefox's, Safari's or Changmun's own. The reader only looks at the text: it follows no address, runs no script and
/// loads nothing, and it takes in web addresses only.
enum BookmarkFile {
    /// What a file's bookmarks are filed under: the folders of one imported source, as for any other browser.
    static let source = "Imported"
    static let readingListName = "Reading List"
    static let maxFileSize = 64 << 20
    static let maxBookmarks = 200_000
    static let maxDepth = 64

    struct Bookmark: Equatable {
        var url: String
        var title: String
        /// The library's folder key (see ImportedFolders).
        var folder: String
    }

    struct Parsed: Equatable {
        var bookmarks: [Bookmark] = []
        /// The links of a folder called "Reading List": only the links, as unread pages.
        var readingList: [ReadingItem] = []
    }

    // MARK: Reading

    private struct Folder {
        var name: String
        var isToolbar = false
        var isOther = false
    }

    /// A tolerant reader: tags in any case, tags never closed (`<DT>`, `<p>`), lists that are not closed, attributes with or without quotes.
    static func parse(_ html: String, now: Date = Date()) -> Parsed {
        let bytes = Array(html.utf8)
        var parsed = Parsed()
        var path: [Folder?] = []
        var overflow = 0
        var pending: Folder?
        var index = 0

        func text(from start: Int) -> String {
            var end = start
            while end < bytes.count, bytes[end] != UInt8(ascii: "<") { end += 1 }
            return clean(decode(String(decoding: bytes[start..<end], as: UTF8.self)))
        }

        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<") else { index += 1; continue }
            if matches(bytes, at: index, pattern: commentStart) {
                index = find(bytes, "-->", from: index + 4).map { $0 + 3 } ?? bytes.count
                continue
            }
            var cursor = index + 1
            let closing = cursor < bytes.count && bytes[cursor] == UInt8(ascii: "/")
            if closing { cursor += 1 }
            let nameStart = cursor
            while cursor < bytes.count, isNameByte(bytes[cursor]) { cursor += 1 }
            let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased()
            guard !name.isEmpty else { index += 1; continue }
            let (attributes, next) = attributes(bytes, from: cursor)
            index = next
            switch name {
            case "script", "style":
                // What is inside is not bookmarks, whatever it says.
                if !closing { index = find(bytes, "</" + name, from: index) ?? bytes.count }
            case "dl":
                if closing {
                    if overflow > 0 { overflow -= 1 } else if !path.isEmpty { path.removeLast() }
                } else if path.count >= maxDepth {
                    overflow += 1
                } else {
                    path.append(pending)
                }
                pending = nil
            case "h3" where !closing:
                var folder = Folder(name: text(from: index))
                folder.isToolbar = attributes["personal_toolbar_folder"]?.lowercased() == "true"
                folder.isOther = attributes["unfiled_bookmarks_folder"]?.lowercased() == "true"
                pending = folder
            case "a" where !closing:
                pending = nil
                guard parsed.bookmarks.count + parsed.readingList.count < maxBookmarks, let url = attributes["href"].flatMap(importableURL) else { continue }
                let title = String(text(from: index).prefix(Tab.maxNameLength))
                add(url: url, title: title, added: attributes["add_date"], path: path.compactMap { $0 }, now: now, to: &parsed)
            default:
                break
            }
        }
        return parsed
    }

    private static func add(url: String, title: String, added: String?, path: [Folder], now: Date, to parsed: inout Parsed) {
        if let first = path.first, first.name.lowercased() == readingListName.lowercased() {
            guard let key = ReadingList.key(for: url) else { return }
            let date = added.flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }.flatMap { $0 <= now ? $0 : nil } ?? now
            parsed.readingList.append(ReadingItem(url: key, title: ReadingList.title(title, for: key), added: date, read: false))
        } else {
            parsed.bookmarks.append(Bookmark(url: url, title: title, folder: folderKey(path)))
        }
    }

    /// The library's key for the folders a link is in. The outermost one is named as the other importers name theirs, when it is one of
    /// the usual ones (the bookmarks bar, other bookmarks, a menu, mobile); any other keeps its name. A link in no folder is in "Other Bookmarks".
    private static func folderKey(_ path: [Folder]) -> String {
        guard let first = path.first else { return ImportedFolders.chromiumRoot(source, ImportedFolders.otherLabel) }
        let lower = first.name.lowercased()
        let label: String
        if first.isToolbar || ["bookmarks bar", "bookmarks toolbar"].contains(lower) {
            label = ImportedFolders.barLabel
        } else if first.isOther || lower == "other bookmarks" {
            label = ImportedFolders.otherLabel
        } else if lower == "bookmarks menu" {
            label = ImportedFolders.menuLabel
        } else if lower == "mobile bookmarks" {
            label = ImportedFolders.mobileLabel
        } else {
            label = folderName(first.name)
        }
        return ([ImportedFolders.chromiumRoot(source, label)] + path.dropFirst().map { folderName($0.name) }).joined(separator: " / ")
    }

    /// A name that can be part of a key: the key's separator is " / ", so one inside a name is written with the division slash.
    private static func folderName(_ name: String) -> String {
        let name = String(name.replacingOccurrences(of: " / ", with: " ∕ ").prefix(Tab.maxNameLength))
        return name.isEmpty ? String(localized: "Folder") : name
    }

    /// The address as it is written when it is a web page that can be kept (http or https, with a site, no spaces, not absurdly long); nil for
    /// everything else, `javascript:` and `data:` included.
    static func importableURL(_ raw: String) -> String? {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.count <= ReadingList.maxURLLength, !address.contains(where: { $0.isWhitespace || $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }),
              let parts = URLComponents(string: address), let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty else { return nil }
        return address
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7a)
    }

    private static func lower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5a ? byte + 0x20 : byte }

    private static let commentStart = Array("<!--".utf8)

    private static func matches(_ bytes: [UInt8], at index: Int, pattern: [UInt8]) -> Bool {
        guard index + pattern.count <= bytes.count else { return false }
        for offset in pattern.indices where lower(bytes[index + offset]) != lower(pattern[offset]) { return false }
        return true
    }

    /// Where the text is next found (letters in either case), at or after `start`. The text is made into bytes once: a file with a comment
    /// or a script that never ends is read to its end in one pass.
    private static func find(_ bytes: [UInt8], _ text: String, from start: Int) -> Int? {
        let pattern = Array(text.utf8)
        var index = start
        while index < bytes.count {
            if matches(bytes, at: index, pattern: pattern) { return index }
            index += 1
        }
        return nil
    }

    /// The attributes of a tag (names in lower case, values with their entities decoded), and where the tag ends. A tag that is not closed
    /// ends at the next "<": what follows it is read as it would be after a closed one.
    private static func attributes(_ bytes: [UInt8], from start: Int) -> ([String: String], Int) {
        var result: [String: String] = [:]
        var index = start
        func skipSpace() { while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) { index += 1 } }
        while true {
            skipSpace()
            guard index < bytes.count, bytes[index] != UInt8(ascii: ">"), bytes[index] != UInt8(ascii: "<") else { break }
            let nameStart = index
            while index < bytes.count, ![0x20, 0x09, 0x0a, 0x0d, 0x3d, 0x3e, 0x3c].contains(bytes[index]) { index += 1 }
            let name = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()
            skipSpace()
            var value = ""
            if index < bytes.count, bytes[index] == UInt8(ascii: "=") {
                index += 1
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") {
                    let quote = bytes[index]
                    let valueStart = index + 1
                    var end = valueStart
                    while end < bytes.count, bytes[end] != quote { end += 1 }
                    value = String(decoding: bytes[valueStart..<end], as: UTF8.self)
                    index = min(end + 1, bytes.count)
                } else {
                    let valueStart = index
                    while index < bytes.count, ![0x20, 0x09, 0x0a, 0x0d, 0x3e, 0x3c].contains(bytes[index]) { index += 1 }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                }
            }
            if !name.isEmpty, result[name] == nil { result[name] = decode(value) }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ">") { index += 1 }
        return (result, index)
    }

    private static let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]

    /// The text with its character references (`&amp;`, `&#39;`, `&#x27;`) replaced by what they stand for; one it does not know stays as written.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            rest = rest[amp...]
            if let semicolon = rest.prefix(12).firstIndex(of: ";") {
                let body = rest[rest.index(after: rest.startIndex)..<semicolon]
                var replacement: String?
                if body.hasPrefix("#") {
                    let digits = body.dropFirst()
                    let value = digits.lowercased().hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                    replacement = value.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
                } else {
                    replacement = entities[String(body)]
                }
                if let replacement {
                    result += replacement
                    rest = rest[rest.index(after: semicolon)...]
                    continue
                }
            }
            result.append("&")
            rest = rest.dropFirst()
        }
        return result + rest
    }

    /// A title or folder name as one line: line breaks and runs of spaces become one space, and control characters go.
    private static func clean(_ text: String) -> String {
        text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7f ? " " : String($0) }.joined()
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    // MARK: Writing

    /// The library as a bookmark file: the favorites in a folder of their own (another space's in a folder inside it), each imported source in
    /// a folder with its own folders nested in it (the folders of an earlier file import, which have no source of their own, at the top), and
    /// the reading list as a folder of links with no read state. `sources` are as `Library.groupBySource` gives them, labels in English.
    static func export(favorites: [Library.Entry], spaceFavorites: [(name: String, entries: [Library.Entry])] = [],
                       sources: [(source: String, folders: [Library.Folder])], readingList: [ReadingItem]) -> String {
        var lines = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<!-- This is an automatically generated file. It will be read and overwritten. DO NOT EDIT! -->",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>",
        ]
        func links(_ entries: [Library.Entry], _ depth: Int) {
            for entry in entries {
                lines.append(indent(depth) + "<DT><A HREF=\"\(escape(entry.url))\">\(escape(entry.title.isEmpty ? entry.url : entry.title))</A>")
            }
        }
        func folder(_ name: String, _ depth: Int, attributes: String = "", body: () -> Void) {
            lines.append(indent(depth) + "<DT><H3\(attributes)>\(escape(name))</H3>")
            lines.append(indent(depth) + "<DL><p>")
            body()
            lines.append(indent(depth) + "</DL><p>")
        }
        func tree(_ folders: [Library.Folder], _ depth: Int) {
            for item in folders {
                let toolbar = depth == 1 && item.label == ImportedFolders.barLabel && item.key.hasPrefix(source + " ")
                folder(item.label, depth, attributes: toolbar ? " PERSONAL_TOOLBAR_FOLDER=\"true\"" : "") {
                    links(item.entries, depth + 1)
                    tree(item.children, depth + 1)
                }
            }
        }
        if !favorites.isEmpty || spaceFavorites.contains(where: { !$0.entries.isEmpty }) {
            folder("Favorites", 1) {
                links(favorites, 2)
                for space in spaceFavorites where !space.entries.isEmpty { folder(space.name, 2) { links(space.entries, 3) } }
            }
        }
        for group in sources {
            if group.source == source {
                tree(group.folders, 1)
            } else {
                folder(group.source, 1) { tree(group.folders, 2) }
            }
        }
        if !readingList.isEmpty {
            folder(readingListName, 1) {
                for item in readingList {
                    lines.append(indent(2) + "<DT><A HREF=\"\(escape(item.url))\" ADD_DATE=\"\(Int(item.added.timeIntervalSince1970))\">\(escape(item.title))</A>")
                }
            }
        }
        lines.append("</DL><p>")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func indent(_ depth: Int) -> String { String(repeating: "    ", count: depth) }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: Importing

    enum Outcome: Equatable {
        case imported(bookmarks: Int, readingList: Int)
        case nothingFound
        case tooLarge
    }

    /// Reads a file's bookmarks into the library as any other source's are put in (so a page already in a folder is not added twice).
    /// Call it off the main thread: a large file takes a while.
    static func importBookmarks(from data: Data, into library: Library = .shared) throws -> Outcome {
        guard data.count <= maxFileSize else { return .tooLarge }
        let parsed = parse(String(decoding: data, as: UTF8.self))
        guard !parsed.bookmarks.isEmpty || !parsed.readingList.isEmpty else { return .nothingFound }
        let added = try library.importBookmarks(parsed.bookmarks.map { ($0.url, $0.title, $0.folder) })
        let saved = try library.importReadingList(parsed.readingList)
        return .imported(bookmarks: added, readingList: saved)
    }
}
