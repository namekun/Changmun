import Foundation
import Testing
@testable import Changmun

struct DurableFileTests {
    @Test func readingAFileSaysMissingUnreadableOrItsBytes() throws {
        let folder = try persistenceScratchFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent("locked.json").path)
            try? FileManager.default.removeItem(at: folder)
        }
        guard case .missing = Library.FileRead(folder.appendingPathComponent("none.json")) else { Issue.record("a file that isn't there is missing"); return }
        let file = folder.appendingPathComponent("ok.json")
        try Data("hello".utf8).write(to: file)
        guard case .data(let data) = Library.FileRead(file) else { Issue.record("a file that is there gives its bytes"); return }
        #expect(data == Data("hello".utf8))
        let locked = folder.appendingPathComponent("locked.json")
        try Data("secret".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        guard case .unreadable = Library.FileRead(locked) else { Issue.record("a file that can't be opened is unreadable, not missing"); return }
    }

    @Test func aDamagedCopyKeepsTheNameOfItsFileAndKeepsNothingForAFileThatIsNotThere() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!Library.keepDamaged(folder.appendingPathComponent("none.json")))
        let file = folder.appendingPathComponent("notes")
        try Data("bad".utf8).write(to: file)
        #expect(Library.keepDamaged(file))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("notes-damaged-") }
        #expect(names.count == 1 && !names[0].contains("."), "a file with no extension gets a copy with none: \(names)")
    }

    @Test func aValueThatDoesNotDecodeIsSkippedAndTheOthersStay() throws {
        let decoded = try JSONDecoder().decode([Browser.Lossy<Int>].self, from: Data(#"[1, "two", 3, null, {"a": 1}, 6]"#.utf8))
        #expect(decoded.map(\.value) == [1, nil, 3, nil, nil, 6])
        #expect(decoded.compactMap(\.value) == [1, 3, 6])
    }

    @Test func aPrivateFileIsMadeWithOwnerOnlyPermissionsAndNeverReusesANameOrFollowsALink() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("made.tmp")
        let descriptor = try #require(DurableFile.createPrivate(at: file))
        close(descriptor)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(DurableFile.createPrivate(at: file) == nil, "a name that is taken is refused")
        let link = folder.appendingPathComponent("link.tmp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent("target.tmp"))
        #expect(DurableFile.createPrivate(at: link) == nil, "a link is not followed")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("target.tmp").path))
        #expect(DurableFile.createPrivate(at: folder.appendingPathComponent("missing-folder/x.tmp")) == nil)
    }
}
