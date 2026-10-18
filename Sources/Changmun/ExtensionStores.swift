import AppKit
import Compression
import WebKit

/// Extensions from the Chrome Web Store: downloaded as a CRX, unpacked under Application Support and loaded like an
/// unpacked folder, so WebKit's extension support runs them as it runs Safari's.
enum ChromeWebStore {
    static let folder: URL = {
        let url = Library.folder.appendingPathComponent("Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The 32-letter id (a–p) in a store address (`chromewebstore.google.com/detail/name/<id>`), or the id itself.
    static func extensionID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        func isID(_ part: String) -> Bool { part.unicodeScalars.count == 32 && part.unicodeScalars.allSatisfy { (0x61...0x70).contains($0.value) } }
        if isID(text) { return text }
        guard let url = URL(string: text), let host = url.host()?.lowercased(),
              host == "chromewebstore.google.com" || host == "chrome.google.com" else { return nil }
        return url.pathComponents.last(where: isID)
    }

    static func downloadURL(for id: String) -> URL {
        URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0.0.0&acceptformat=crx2,crx3&x=id%3D\(id)%26uc")!
    }

    enum Failure: LocalizedError {
        case notCRX, download(Int), unsafeArchive, noManifest, tooLarge

        var errorDescription: String? {
            switch self {
            case .notCRX: "확장 파일 형식이 아니에요"
            case .download(let status): "받지 못했어요 (HTTP \(status))"
            case .unsafeArchive: "압축 파일 안에 확장 폴더 밖을 가리키는 항목이 있어요"
            case .noManifest: "manifest.json이 없는 확장이에요"
            case .tooLarge: "확장 파일이 너무 커요"
            }
        }
    }

    /// The zip inside a CRX: version 3 is "Cr24", 3, a header length and the header; version 2 has a key and a signature.
    static func zipData(fromCRX data: Data) throws -> Data {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0x50, 0x4B]) { return data }
        guard bytes.count > 16, bytes.starts(with: Array("Cr24".utf8)) else { throw Failure.notCRX }
        func uint32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        let start: Int
        switch uint32(4) {
        case 3: start = 12 + uint32(8)
        case 2: start = 16 + uint32(8) + uint32(12)
        default: throw Failure.notCRX
        }
        guard start < bytes.count, bytes[start...].starts(with: [0x50, 0x4B]) else { throw Failure.notCRX }
        return Data(bytes[start...])
    }

    /// Entries that would land outside the folder (absolute paths, `..`) make the whole archive unsafe.
    static func isSafeEntry(_ name: String) -> Bool {
        !name.hasPrefix("/") && !name.contains("\\") && !name.split(separator: "/").contains("..")
    }

    struct Entry {
        var name: String
        var method: Int
        var compressedSize: Int
        var size: Int
        var dataOffset: Int
    }

    /// Unpacked size an extension may reach; a larger archive is refused (a zip bomb, most likely).
    static let maximumSize = 256 << 20

    /// Reads the archive's central directory, failing closed: a name that isn't UTF-8 or leaves the folder, a symbolic
    /// link (by its mode bits, whatever system made it), encryption, ZIP64, a method other than stored or deflate, a
    /// local header that disagrees with its directory entry, or counts that don't add up. Unpacking uses exactly these
    /// entries, so what is checked is what gets written.
    static func entries(of zip: Data) throws -> [Entry] {
        let bytes = [UInt8](zip)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard bytes.count >= 22 else { throw Failure.unsafeArchive }
        // The end-of-central-directory record: within the last 22 bytes plus the longest comment.
        var end = bytes.count - 22
        while end >= max(0, bytes.count - 22 - 0xFFFF), u32(end) != 0x0605_4B50 { end -= 1 }
        guard end >= 0, u32(end) == 0x0605_4B50, end + 22 + u16(end + 20) == bytes.count else { throw Failure.unsafeArchive }
        let count = u16(end + 10), size = u32(end + 12), start = u32(end + 16)
        guard count > 0, count != 0xFFFF, start != 0xFFFF_FFFF, start + size <= end else { throw Failure.unsafeArchive }
        var entries: [Entry] = []
        var total = 0
        var at = start
        for _ in 0..<count {
            guard at + 46 <= end, u32(at) == 0x0201_4B50 else { throw Failure.unsafeArchive }
            let flags = u16(at + 8), method = u16(at + 10)
            let compressedSize = u32(at + 20), uncompressedSize = u32(at + 24)
            let nameLength = u16(at + 28), extraLength = u16(at + 30), commentLength = u16(at + 32)
            let mode = u32(at + 38) >> 16, local = u32(at + 42)
            guard at + 46 + nameLength <= end else { throw Failure.unsafeArchive }
            let nameBytes = Array(bytes[(at + 46)..<(at + 46 + nameLength)])
            guard let name = String(bytes: nameBytes, encoding: .utf8), !name.isEmpty, isSafeEntry(name),
                  mode & 0o170000 != 0o120000, flags & 1 == 0, method == 0 || method == 8,
                  compressedSize != 0xFFFF_FFFF, uncompressedSize != 0xFFFF_FFFF,
                  local + 30 <= start, u32(local) == 0x0403_4B50, u16(local + 26) == nameLength else { throw Failure.unsafeArchive }
            let localNameEnd = local + 30 + nameLength
            let dataOffset = localNameEnd + u16(local + 28)
            guard localNameEnd <= start, Array(bytes[(local + 30)..<localNameEnd]) == nameBytes,
                  dataOffset + compressedSize <= start else { throw Failure.unsafeArchive }
            total += uncompressedSize
            guard total <= maximumSize else { throw Failure.unsafeArchive }
            entries.append(Entry(name: name, method: method, compressedSize: compressedSize, size: uncompressedSize, dataOffset: dataOffset))
            at += 46 + nameLength + extraLength + commentLength
        }
        guard at == start + size else { throw Failure.unsafeArchive }
        return entries
    }

    static func checkArchive(_ zip: Data) throws { _ = try entries(of: zip) }

    private static func contents(of entry: Entry, in bytes: [UInt8]) throws -> Data {
        let compressed = bytes[entry.dataOffset..<(entry.dataOffset + entry.compressedSize)]
        if entry.method == 0 {
            guard entry.compressedSize == entry.size else { throw Failure.unsafeArchive }
            return Data(compressed)
        }
        guard entry.size > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: entry.size)
        // COMPRESSION_ZLIB is raw deflate, which is what zip stores.
        let written = compressed.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, entry.size, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == entry.size else { throw Failure.unsafeArchive }
        return Data(output)
    }

    /// Downloads the extension and unpacks it into a staging folder beside its place; `swapIn` puts it there.
    static func download(id: String) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: downloadURL(for: id))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.download(status) }
        guard data.count <= maximumSize else { throw Failure.tooLarge }
        let zip = try zipData(fromCRX: data)
        return try await Task.detached { try stage(zip, id: id) }.value
    }

    /// Unpacks into `<parent>/.<id>-new` and puts that in place of `<parent>/<id>`.
    static func unpack(_ zip: Data, id: String, into parent: URL = folder) throws -> URL {
        let backup = try swapIn(try stage(zip, id: id, into: parent), id: id, into: parent)
        if let backup { try? FileManager.default.removeItem(at: backup) }
        return parent.appendingPathComponent(id, isDirectory: true)
    }

    /// Puts a staged copy in place; the copy it replaces is kept aside (returned) until the new one is known to load.
    static func swapIn(_ staging: URL, id: String, into parent: URL = folder) throws -> URL? {
        let fm = FileManager.default
        let destination = parent.appendingPathComponent(id, isDirectory: true)
        let backup = parent.appendingPathComponent(".\(id)-old", isDirectory: true)
        try? fm.removeItem(at: backup)
        let hadOld = fm.fileExists(atPath: destination.path)
        if hadOld { try fm.moveItem(at: destination, to: backup) }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            if hadOld { try? fm.moveItem(at: backup, to: destination) }
            throw error
        }
        return hadOld ? backup : nil
    }

    /// Undoes `swapIn`: the old copy goes back, or with none the new one is removed.
    static func restore(_ backup: URL?, id: String, into parent: URL = folder) throws {
        let fm = FileManager.default
        let destination = parent.appendingPathComponent(id, isDirectory: true)
        try? fm.removeItem(at: destination)
        if let backup { try fm.moveItem(at: backup, to: destination) }
    }

    static func stage(_ zip: Data, id: String, into parent: URL = folder) throws -> URL {
        let fm = FileManager.default
        let entries = try entries(of: zip)
        let bytes = [UInt8](zip)
        let staging = parent.appendingPathComponent(".\(id)-new", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            // Only regular files and folders are written, under names checked above, into a folder made just now.
            for entry in entries {
                let target = staging.appendingPathComponent(entry.name)
                if entry.name.hasSuffix("/") {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try contents(of: entry, in: bytes).write(to: target)
                }
            }
            // Chrome's own signature files; WebKit reserves names starting with "_".
            try? fm.removeItem(at: staging.appendingPathComponent("_metadata"))
            guard fm.fileExists(atPath: staging.appendingPathComponent("manifest.json").path) else { throw Failure.noManifest }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return staging
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return output
    }
}

/// Safari content blockers (Unicorn, AdGuard and the like). Safari asks them for their rules, but macOS lets only Safari
/// ask; the rules they keep in their app group folder are read instead (macOS asks the user once), along with any list
/// bundled inside the extension, and compiled for WebKit like the built-in lists.
struct ContentBlockerExtension: Identifiable, Hashable {
    var bundleID: String
    var name: String
    var path: String
    var id: String { bundleID }

    /// `pluginkit -mAvvv` prints each extension as an `id(version)` line followed by indented `Key = value` lines.
    static func parse(_ pluginkitOutput: String) -> [ContentBlockerExtension] {
        var found: [ContentBlockerExtension] = []
        var current: (id: String, fields: [String: String])?
        func finish() {
            if let current, let path = current.fields["Path"] {
                found.append(ContentBlockerExtension(bundleID: current.id, name: current.fields["Display Name"] ?? current.id, path: path))
            }
        }
        for line in pluginkitOutput.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let equals = text.range(of: " = ") {
                current?.fields[String(text[..<equals.lowerBound])] = String(text[equals.upperBound...])
            } else if !text.isEmpty {
                finish()
                let id = text.split(separator: "(").first.map(String.init) ?? text
                current = (id.trimmingCharacters(in: CharacterSet(charactersIn: "+-!= ")), [:])
            }
        }
        finish()
        return found
    }

    static func installed() -> [ContentBlockerExtension] {
        guard let output = try? ChromeWebStore.run("/usr/bin/pluginkit", ["-mAvvv", "-p", "com.apple.Safari.content-blocker"]) else { return [] }
        return parse(output)
    }

    /// The app groups the extension may write to, from its code signature.
    var appGroups: [String] {
        guard let output = try? ChromeWebStore.run("/usr/bin/codesign", ["-d", "--entitlements", ":-", path]),
              let plist = try? PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil) as? [String: Any] else { return [] }
        return plist["com.apple.security.application-groups"] as? [String] ?? []
    }

    /// Every rule list the blocker has: JSON arrays of `{trigger, action}` in its bundle and its group folders, in path
    /// order so rules that depend on order (`ignore-previous-rules`) come out the same each time.
    func rules(groups: [String]) -> [[String: Any]] {
        let fm = FileManager.default
        var folders = [URL(fileURLWithPath: path).appendingPathComponent("Contents/Resources")]
        let containers = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers")
        folders += groups.map { containers.appendingPathComponent($0) }
        var rules: [[String: Any]] = []
        for folder in folders {
            guard let items = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            let files = items.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.path < $1.path }
            for file in files {
                guard ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) <= 64 << 20,
                      let data = try? Data(contentsOf: file), let list = Self.ruleList(data) else { continue }
                rules += list
            }
        }
        return rules
    }

    /// The actions WebKit understands; a rule with another kind would make WebKit refuse the whole list.
    static let actions: Set<String> = ["block", "block-cookies", "css-display-none", "ignore-previous-rules", "make-https"]

    static func ruleList(_ data: Data) -> [[String: Any]]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !list.isEmpty,
              list.allSatisfy({ $0["trigger"] is [String: Any] && $0["action"] is [String: Any] }) else { return nil }
        let usable = list.filter { (($0["action"] as? [String: Any])?["type"] as? String).map(actions.contains) == true }
        return usable.isEmpty ? nil : usable
    }

    /// WebKit compiles at most 150,000 rules a list; longer ones are split, each part ending with the allowlist
    /// (`ignore-previous-rules` only covers rules before it in the same list).
    static func chunks(_ rules: [[String: Any]], allowlist: [[String: Any]], size: Int = 140_000) -> [[[String: Any]]] {
        stride(from: 0, to: rules.count, by: size).map { Array(rules[$0..<min($0 + size, rules.count)]) + allowlist }
    }
}

@MainActor
final class ContentBlockerHost: ObservableObject {
    static let shared = ContentBlockerHost()

    @Published private(set) var blockers: [ContentBlockerExtension] = []
    /// "규칙 1,234개 적용 중" or what went wrong, by bundle id.
    @Published private(set) var status: [String: String] = [:]
    /// Bumped by every apply and switch-off, so a slower, older apply can't put back rules that were turned off or changed.
    private var generation: [String: Int] = [:]
    private var groups: [String: [String]] = [:]

    func start() async {
        blockers = await Task.detached { ContentBlockerExtension.installed() }.value
        for blocker in blockers where Preferences.shared.enabledContentBlockers.contains(blocker.bundleID) {
            await apply(blocker)
        }
    }

    func rescan() {
        Task { blockers = await Task.detached { ContentBlockerExtension.installed() }.value }
    }

    func isEnabled(_ blocker: ContentBlockerExtension) -> Bool {
        Preferences.shared.enabledContentBlockers.contains(blocker.bundleID)
    }

    func setEnabled(_ blocker: ContentBlockerExtension, _ on: Bool) async {
        Preferences.shared.enabledContentBlockers.removeAll { $0 == blocker.bundleID }
        if on {
            Preferences.shared.enabledContentBlockers.append(blocker.bundleID)
            await apply(blocker)
        } else {
            generation[blocker.bundleID, default: 0] += 1
            AdBlocker.shared.setExternal(blocker.bundleID, [])
            status[blocker.bundleID] = nil
        }
        objectWillChange.send()
    }

    /// Rebuilds the enabled blockers' rules (after a site was allowed, so the allowlist applies to them too).
    func reload() async {
        for blocker in blockers where isEnabled(blocker) { await apply(blocker) }
    }

    private func apply(_ blocker: ContentBlockerExtension) async {
        let id = blocker.bundleID
        generation[id, default: 0] += 1
        let mine = generation[id]
        status[id] = "규칙을 읽는 중…"
        let allowlist = Preferences.shared.adBlockAllowlist.filter { !$0.isEmpty }.map { host -> [String: Any] in
            ["trigger": ["url-filter": ".*", "if-domain": ["*" + host.lowercased()]], "action": ["type": "ignore-previous-rules"]]
        }
        let knownGroups = groups[id]
        let read = await Task.detached { () -> (parts: [String], count: Int, groups: [String]) in
            let groups = knownGroups ?? blocker.appGroups
            let rules = blocker.rules(groups: groups)
            let parts = ContentBlockerExtension.chunks(rules, allowlist: allowlist).compactMap { part in
                (try? JSONSerialization.data(withJSONObject: part)).map { String(decoding: $0, as: UTF8.self) }
            }
            return (parts, rules.count, groups)
        }.value
        groups[id] = read.groups
        guard generation[id] == mine, isEnabled(blocker) else { return }
        guard !read.parts.isEmpty else {
            status[id] = "[ERROR] 규칙을 찾지 못했어요. 시스템 설정 › 개인정보 보호 및 보안에서 Changmun이 다른 앱의 데이터에 접근하도록 허용했는지 확인하세요."
            AdBlocker.shared.setExternal(id, [])
            return
        }
        do {
            var lists: [WKContentRuleList] = []
            for (index, part) in read.parts.enumerated() {
                if let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "changmun-cb-\(id)-\(index)", encodedContentRuleList: part) {
                    lists.append(list)
                }
            }
            guard generation[id] == mine, isEnabled(blocker) else { return }
            AdBlocker.shared.setExternal(id, lists)
            status[id] = "규칙 \(read.count.formatted())개 적용 중"
        } catch {
            guard generation[id] == mine else { return }
            status[id] = "[ERROR] WebKit이 규칙을 받아들이지 않았어요: \(error.localizedDescription)"
        }
    }
}

enum SafariExtensionGallery {
    /// The App Store's "Safari 확장 프로그램" page.
    static let url = URL(string: "macappstore://apps.apple.com/story/id1377753262")!
}
