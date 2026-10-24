import Foundation
import Testing
@testable import Changmun

@MainActor
struct DownloadLandingTests {
    @Test func aFileAlreadyAtTheTargetStaysUntilTheNewOneIsWhole() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("report.pdf")
        try Data("original".utf8).write(to: target)
        let landing = Downloads.landing(for: target)
        #expect(landing.place != target && landing.place.deletingLastPathComponent() == folder)
        #expect(try Data(contentsOf: target) == Data("original".utf8), "choosing the name does not remove the file")
        // The download breaks off: the temporary file goes, the original was never touched.
        try Data("half".utf8).write(to: landing.place)
        try FileManager.default.removeItem(at: landing.place)
        #expect(try Data(contentsOf: target) == Data("original".utf8))
        // A download that finishes replaces it.
        let second = Downloads.landing(for: target)
        try Data("new".utf8).write(to: second.place)
        try Downloads.install(second)
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["report.pdf"], "no temporary file is left")
    }

    @Test func aNewNameIsWrittenWhereItIsAndAFolderThatIsGoneIsMade() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("Downloads/inner/new.zip")
        let landing = Downloads.landing(for: target)
        #expect(landing.place == target && landing.target == target)
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path, isDirectory: &isFolder) && isFolder.boolValue)
        try Data("x".utf8).write(to: landing.place)
        try Downloads.install(landing)
        #expect(try Data(contentsOf: target) == Data("x".utf8))
    }
}

