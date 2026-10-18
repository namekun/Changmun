import AppKit
import WebKit

/// Extensions from the Chrome Web Store: downloaded as a CRX, unpacked under Application Support and loaded like an
/// unpacked folder, so WebKit's extension support runs them as it runs Safari's.
enum ChromeWebStore {
    static var folder: URL {
        let url = Library.folder.appendingPathComponent("Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The 32-letter id (a–p) in a store address (`chromewebstore.google.com/detail/name/<id>`), or the id itself.
    static func extensionID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        func isID(_ part: String) -> Bool { part.count == 32 && part.allSatisfy { ("a"..."p").contains($0) } }
        if isID(text) { return text }
        guard let url = URL(string: text), let host = url.host()?.lowercased(),
              host == "chromewebstore.google.com" || host == "chrome.google.com" else { return nil }
        return url.pathComponents.last(where: isID)
    }

    static func downloadURL(for id: String) -> URL {
        URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0.0.0&acceptformat=crx2,crx3&x=id%3D\(id)%26uc")!
    }

    enum Failure: LocalizedError {
        case notCRX, download(Int), unsafeArchive, noManifest

        var errorDescription: String? {
            switch self {
            case .notCRX: "확장 파일 형식이 아니에요"
            case .download(let status): "받지 못했어요 (HTTP \(status))"
            case .unsafeArchive: "압축 파일 안에 확장 폴더 밖을 가리키는 항목이 있어요"
            case .noManifest: "manifest.json이 없는 확장이에요"
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
        !name.hasPrefix("/") && !name.split(separator: "/").contains("..")
    }

    /// Downloads and unpacks the extension, replacing an older copy; returns its folder.
    static func download(id: String) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: downloadURL(for: id))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.download(status) }
        let zip = try zipData(fromCRX: data)
        return try await Task.detached { try unpack(zip, id: id) }.value
    }

    static func unpack(_ zip: Data, id: String, into parent: URL = folder) throws -> URL {
        let fm = FileManager.default
        let archive = fm.temporaryDirectory.appendingPathComponent("changmun-\(id).zip")
        try zip.write(to: archive)
        defer { try? fm.removeItem(at: archive) }
        let names = try run("/usr/bin/zipinfo", ["-1", archive.path]).split(whereSeparator: \.isNewline).map(String.init)
        guard names.allSatisfy(isSafeEntry) else { throw Failure.unsafeArchive }
        let destination = parent.appendingPathComponent(id, isDirectory: true)
        let staging = parent.appendingPathComponent(".\(id)-new", isDirectory: true)
        try? fm.removeItem(at: staging)
        _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
        // Links could point anywhere on disk; an extension has no need for them.
        if let items = fm.enumerator(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let item as URL in items where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                try fm.removeItem(at: item)
            }
        }
        // Chrome's own signature files; WebKit reserves names starting with "_".
        try? fm.removeItem(at: staging.appendingPathComponent("_metadata"))
        guard fm.fileExists(atPath: staging.appendingPathComponent("manifest.json").path) else {
            try? fm.removeItem(at: staging)
            throw Failure.noManifest
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: staging, to: destination)
        return destination
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
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
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

    /// Every rule list the blocker has: JSON arrays of `{trigger, action}` in its bundle and its group folders.
    func rules() -> [[String: Any]] {
        let fm = FileManager.default
        var folders = [URL(fileURLWithPath: path).appendingPathComponent("Contents/Resources")]
        let groups = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers")
        folders += appGroups.map { groups.appendingPathComponent($0) }
        var rules: [[String: Any]] = []
        for folder in folders {
            guard let items = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in items where file.pathExtension.lowercased() == "json" {
                guard let data = try? Data(contentsOf: file), let list = Self.ruleList(data) else { continue }
                rules += list
            }
        }
        return rules
    }

    static func ruleList(_ data: Data) -> [[String: Any]]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !list.isEmpty,
              list.allSatisfy({ $0["trigger"] is [String: Any] && $0["action"] is [String: Any] }) else { return nil }
        return list
    }
}

@MainActor
final class ContentBlockerHost: ObservableObject {
    static let shared = ContentBlockerHost()

    @Published private(set) var blockers: [ContentBlockerExtension] = []
    /// "규칙 1,234개 적용 중" or what went wrong, by bundle id.
    @Published private(set) var status: [String: String] = [:]

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
            AdBlocker.shared.setExternal(blocker.bundleID, nil)
            status[blocker.bundleID] = nil
        }
        objectWillChange.send()
    }

    /// Rebuilds the enabled blockers' rules (after a site was allowed, so the allowlist applies to them too).
    func reload() async {
        for blocker in blockers where isEnabled(blocker) { await apply(blocker) }
    }

    private func apply(_ blocker: ContentBlockerExtension) async {
        status[blocker.bundleID] = "규칙을 읽는 중…"
        let allowlist = Preferences.shared.adBlockAllowlist
        let json = await Task.detached { () -> (String, Int)? in
            var rules = blocker.rules()
            guard !rules.isEmpty else { return nil }
            let count = rules.count
            for host in allowlist where !host.isEmpty {
                rules.append(["trigger": ["url-filter": ".*", "if-domain": ["*" + host.lowercased()]], "action": ["type": "ignore-previous-rules"]])
            }
            guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
            return (String(decoding: data, as: UTF8.self), count)
        }.value
        guard let (rules, count) = json else {
            status[blocker.bundleID] = "[ERROR] 규칙을 찾지 못했어요. 시스템 설정 › 개인정보 보호 및 보안에서 Changmun이 다른 앱의 데이터에 접근하도록 허용했는지 확인하세요."
            AdBlocker.shared.setExternal(blocker.bundleID, nil)
            return
        }
        do {
            let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "changmun-cb-" + blocker.bundleID, encodedContentRuleList: rules)
            AdBlocker.shared.setExternal(blocker.bundleID, list)
            status[blocker.bundleID] = "규칙 \(count.formatted())개 적용 중"
        } catch {
            status[blocker.bundleID] = "[ERROR] WebKit이 규칙을 받아들이지 않았어요: \(error.localizedDescription)"
        }
    }
}

enum SafariExtensionGallery {
    /// The App Store's "Safari 확장 프로그램" page.
    static let url = URL(string: "macappstore://apps.apple.com/story/id1377753262")!
}
