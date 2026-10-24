import Foundation
import Testing
@testable import Changmun

@MainActor
struct SavePageFileNameTests {
    @Test func longKoreanAndEmojiTitlesStayWithinTheFileNameLimit() {
        let korean = String(repeating: "가나다라마바사", count: 30)
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 60)
        for title in [korean, family, korean + family, String(repeating: "é", count: 150)] {
            let name = SavePage.filename(title: title, host: nil) + ".pdf"
            #expect(name.utf8.count <= 255, "\(name.utf8.count) bytes")
            #expect(!name.isEmpty && name.hasSuffix(".pdf"))
        }
        let cut = SavePage.filename(title: family, host: nil)
        #expect(cut.allSatisfy { $0 == "👨‍👩‍👧‍👦" } && !cut.isEmpty, "an emoji is never cut in two")
        #expect(SavePage.filename(title: "", host: String(repeating: "a", count: 250)).utf8.count <= SavePage.maxNameBytes)
        // A name that fits is left as it was.
        #expect(SavePage.filename(title: "한글 제목", host: nil) == "한글 제목")
    }

    @Test func aLongTitleCanReallyBeUsedAsAFileName() throws {
        let folder = try persistenceScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = SavePage.filename(title: String(repeating: "가나다라마바사", count: 30), host: nil) + ".pdf"
        try Data("x".utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
    }
}
