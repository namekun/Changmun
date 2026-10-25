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

    @Test func onlyOldTemporaryPartFilesOfOursAreCleanedUp() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func make(_ name: String, daysOld: Double) throws -> URL {
            let file = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -daysOld * 86_400)], ofItemAtPath: file.path)
            return file
        }
        let id = UUID().uuidString
        let oldPart = try make(".changmun-\(id).part", daysOld: 2)
        let freshPart = try make(".changmun-\(UUID().uuidString).part", daysOld: 0.1)
        let others = try [make("movie.part", daysOld: 5), make(".changmun-notes.part", daysOld: 5), make(".changmun-\(id).part.txt", daysOld: 5),
                          make("report.pdf", daysOld: 5), make(".other-\(id).part", daysOld: 5)]
        Downloads.removeOrphanedParts(in: folder, olderThan: Date(timeIntervalSinceNow: -86_400))
        #expect(!FileManager.default.fileExists(atPath: oldPart.path))
        #expect(FileManager.default.fileExists(atPath: freshPart.path), "a download still going is written to now and then")
        #expect(others.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "nothing that doesn't match exactly")
    }
}

