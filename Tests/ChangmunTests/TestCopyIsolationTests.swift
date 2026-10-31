import Foundation
import Testing
@testable import Changmun

/// The test copy never touches the user's real browsers, their folders or their Keychain items: macOS would ask for access on the screen the user
/// is at, and no off-screen window can stop that. What it is shown instead is a fixed list of made-up browsers.
@MainActor
struct TestCopyIsolationTests {
    @Test func theTestCopysSourcesAreMadeUpAndNoRealPathIsInThem() {
        let found = BrowserDiscovery.sources(testCopy: true)
        #expect(found.map(\.browser) == BrowserDiscovery.rehearsal.map(\.browser) && found.count == 3)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        for source in found {
            #expect(source.directory.path.hasPrefix("/var/empty/changmun-test/"), "\(source.directory.path)")
            #expect(!source.directory.path.hasPrefix(home) && !source.directory.path.hasPrefix(support))
            #expect(!FileManager.default.fileExists(atPath: source.directory.path), "nothing is there to read")
        }
    }

    @Test func theTestCopyReadsNothingEvenWhenOnlyOneFolderIsGiven() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("isolation-\(UUID().uuidString)")
        #expect(BrowserDiscovery.sources(applicationSupport: folder, testCopy: true).count == 3)
        #expect(BrowserDiscovery.sources(safariFolder: folder, testCopy: true).count == 3)
    }

    @Test func anImportInTheTestCopyWritesNothingAndAsksForNothing() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }
        let library = Library(path: data.appendingPathComponent("library.sqlite").path)
        let chrome = BrowserDiscovery.rehearsal[1]
        let report = await ImportRunner.run(chrome, options: ImportOptions(), library: library, testCopy: true) { _ in }
        #expect(report.bookmarks > 0 && report.history > 0 && report.passwords > 0 && report.problems.isEmpty, "numbers for the screens that follow")
        #expect(library.bookmarks(limit: 100).isEmpty && library.history(limit: 100).isEmpty, "nothing reached the library")
        let safari = await ImportRunner.run(BrowserDiscovery.rehearsal[0], options: ImportOptions(), library: library, testCopy: true) { _ in }
        #expect(safari.passwords == 0, "Safari has no passwords to give")
    }

    @Test func theAppItselfStillLooksAtTheFoldersItIsGiven() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("isolation-\(UUID().uuidString)")
        let chrome = support.appendingPathComponent("Google/Chrome/Default")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: support.appendingPathComponent("Google/Chrome/Local State"))
        for name in ["History", "Login Data"] { try Data().write(to: chrome.appendingPathComponent(name)) }
        defer { try? FileManager.default.removeItem(at: support) }
        let found = BrowserDiscovery.sources(applicationSupport: support, safariFolder: support.appendingPathComponent("Safari"), testCopy: false)
        #expect(found.contains { $0.browser == "Chrome" })
    }
}
