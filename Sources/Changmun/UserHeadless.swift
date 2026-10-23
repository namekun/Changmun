import Foundation

/// `changmun headless start | stop | status`: the user's own headless Changmun, `Changmun Agent.app`, for agents to drive without
/// disturbing the browser in use. It is a copy of the app that runs the command, kept in its profile folder (not in /Applications),
/// with a bundle ID of its own (so its settings, website data and `control.json` are its own: none of the user's cookies, history
/// or passwords), no window, focus or sound, no Sparkle, and nobody to ask, see `Approvals.userHeadlessAnswer`.
enum UserHeadless {
    static let appName = "Changmun Agent"

    /// The profile folder in Application Support, which holds the app, `control.json` and everything the browser keeps.
    static var folder: URL { Library.location(forBundle: Headless.userBundleID) }
    static func app(in folder: URL = folder) -> URL { folder.appendingPathComponent("\(appName).app", isDirectory: true) }
    static func endpointFile(in folder: URL = folder) -> URL { folder.appendingPathComponent("control.json") }

    struct Failure: Error { let message: String }

    /// A bundle's Info.plist, as the copy has to have it: another identity, no window or Dock icon, not a browser to macOS (so it never
    /// shows up among the default browsers or gets sent links), and no update feed.
    static func headlessInfo(from info: [String: Any]) -> [String: Any] {
        var info = info
        info["CFBundleIdentifier"] = Headless.userBundleID
        info["CFBundleName"] = appName
        info["CFBundleDisplayName"] = appName
        info["LSBackgroundOnly"] = true
        for key in ["CFBundleURLTypes", "CFBundleDocumentTypes", "SUFeedURL", "SUEnableAutomaticChecks"] { info[key] = nil }
        return info
    }

    /// "0.6.1 (19)": which release of Changmun a bundle is.
    static func version(of info: [String: Any]?) -> String? {
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        return "\(short) (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    static func info(ofApp app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Whether the copy has to be made again: there is none, or it is another release than the app it was made from.
    static func needsCopy(copy: [String: Any]?, source: [String: Any]) -> Bool {
        guard let copy, copy["CFBundleIdentifier"] as? String == Headless.userBundleID else { return true }
        return version(of: copy) != version(of: source)
    }

    /// Runs a program and throws what it said when it fails.
    typealias Runner = (_ program: String, _ arguments: [String]) throws -> Void

    static let run: Runner = { program, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "\(URL(fileURLWithPath: program).lastPathComponent) failed\(text.isEmpty ? "" : ": " + text)")
        }
    }

    /// Makes `folder/Changmun Agent.app` from the app at `source` when it is missing or another release. Built and signed outside
    /// the profile folder, like scripts/headless.sh does (a synced folder adds Finder info that codesign rejects). Returns whether
    /// it made one.
    @discardableResult
    static func prepare(from source: URL, in folder: URL = folder, run: Runner = run) throws -> Bool {
        guard let sourceInfo = info(ofApp: source) else { throw Failure(message: "\(source.path) is not an app") }
        let target = app(in: folder)
        guard needsCopy(copy: info(ofApp: target), source: sourceInfo) else { return false }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("changmun-agent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let made = app(in: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", [source.path, made.path])
        let plist = made.appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: headlessInfo(from: sourceInfo), format: .xml, options: 0).write(to: plist)
        try run("/usr/bin/xattr", ["-cr", made.path])
        try run("/usr/bin/codesign", ["--force", "--sign", "-", made.path])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: made, to: target)
        return true
    }

    /// Where the running copy listens, if it is running. The process has to be this app: a stale `control.json` names a process ID
    /// that something else may have taken since.
    static func endpoint(in folder: URL = folder) -> ControlEndpoint? {
        guard let endpoint = ControlEndpoint.read(file: endpointFile(in: folder)), isCopy(pid: endpoint.pid, in: folder) else { return nil }
        return endpoint
    }

    private static func isCopy(pid: Int32, in folder: URL) -> Bool {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let running = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
        return running.hasPrefix(app(in: folder).resolvingSymlinksInPath().path + "/")
    }

    /// Starts the copy (making it first when needed) and waits for its control server; the endpoint at once when it is running.
    /// Starters take turns (a lock file in the profile folder), so two at once start one copy and neither makes it under the other.
    /// A stale `control.json` is left alone: it names a process that isn't the copy, and the copy overwrites it.
    static func start(from source: URL?, in folder: URL = folder) throws -> ControlEndpoint {
        if let endpoint = endpoint(in: folder) { return endpoint }
        guard let source else { throw Failure(message: "run this from the Changmun app (its `changmun` command), not from a bare binary") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = open(folder.appendingPathComponent(".start.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw Failure(message: "couldn't open the lock file in \(folder.path)") }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }
        if let endpoint = endpoint(in: folder) { return endpoint }
        try prepare(from: source, in: folder)
        try run("/usr/bin/open", ["-g", app(in: folder).path])
        for _ in 0..<200 {
            if let endpoint = endpoint(in: folder) { return endpoint }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw Failure(message: "\(appName) did not start")
    }

    enum Stopped: Equatable {
        case notRunning, stopped
        /// It did not quit when asked; its process ID.
        case stillRunning(Int32)
    }

    /// Quits the copy, and says whether it did. Its endpoint is removed only once the process is gone.
    static func stop(in folder: URL = folder) -> Stopped {
        guard let endpoint = endpoint(in: folder) else { return .notRunning }
        kill(endpoint.pid, SIGTERM)
        for _ in 0..<50 where kill(endpoint.pid, 0) == 0 { Thread.sleep(forTimeInterval: 0.1) }
        guard kill(endpoint.pid, 0) != 0 else { return .stillRunning(endpoint.pid) }
        try? FileManager.default.removeItem(at: endpointFile(in: folder))
        return .stopped
    }

    /// Said when the installed app is another release than the copy, which keeps running as it was until it is started again.
    static func updateHint(installed: [String: Any]?, running: Bool, in folder: URL = folder) -> String? {
        guard let made = version(of: info(ofApp: app(in: folder))), let current = version(of: installed), made != current else { return nil }
        return "The installed app is \(current), this copy is \(made): " + (running ? "`changmun headless stop` and then `changmun headless start` update it." : "`changmun headless start` updates it.")
    }

    /// What `changmun headless status` prints, and whether it is running. `installed` is the app running the command.
    static func status(installed: [String: Any]?, in folder: URL = folder) -> (text: String, running: Bool) {
        let endpoint = endpoint(in: folder)
        let made = version(of: info(ofApp: app(in: folder)))
        var lines = [endpoint == nil ? "headless: not running" : "headless: running"]
        if let endpoint { lines.append("pid: \(endpoint.pid)") }
        lines.append("version: \(made ?? "not made yet")")
        lines.append("profile: \(folder.path)")
        if let hint = updateHint(installed: installed, running: endpoint != nil, in: folder) { lines.append(hint) }
        return (lines.joined(separator: "\n"), endpoint != nil)
    }
}
