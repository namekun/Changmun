import Foundation

/// Where the app keeps its durable files.
package enum DataFolder {
    /// The user's data folder, for the app and for the headless apps only. Anything else (the test runner, a bare
    /// `swift run` binary) gets a folder of its own in the temporary directory, so it can never touch that data.
    package static var url: URL {
        let url = location(forBundle: Bundle.main.bundleIdentifier)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Made once per process (a lazy static), so every caller of a non-app process shares the one folder.
    private static let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("changmun-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)

    package static func location(forBundle bundleID: String?) -> URL {
        guard bundleID?.hasPrefix("io.github.namekun.Changmun") == true else { return scratch }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProfileNames.profileName(forBundle: bundleID) ?? "Changmun", isDirectory: true)
    }
}
