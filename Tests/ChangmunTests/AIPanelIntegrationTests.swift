import Combine
import AppKit
import Foundation
import Testing
@testable import Changmun

extension SharedAgentState {
    @MainActor
    struct AIPanelIntegrationTests {
        private func picture() -> ChatImage {
            ChatImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mediaType: "image/png", thumbnail: NSImage(), label: "a", sites: [Approvals.addedImage])
        }

        private func standIn() -> ChatStore {
            let chat = ChatStore()
            chat.history = ChatHistory(file: FileManager.default.temporaryDirectory.appendingPathComponent("chats-\(UUID().uuidString).json"))
            chat.launch = { _, _ in true }
            return chat
        }

        @Test func aKeptMessageThatHadPicturesSaysSoInsteadOfKeepingThem() {
            let chat = standIn()
            chat.history.record(id: UUID(), started: Date(), items: [ChatItem(kind: .user, text: "what is this", images: [picture(), picture()]), ChatItem(kind: .assistant, text: "a cat")])
            let kept = chat.history.chats[0].items
            #expect(kept[0].images.isEmpty && kept[0].text.hasPrefix("what is this") && kept[0].text.contains("2"), "the read-only view says pictures were attached")
        }

        @Test func tryAgainSendsTheSamePicturesAndTheyCountAsReadAgain() {
            let chat = standIn()
            defer { Approvals.forgetReads(caller: ChatStore.caller) }
            Approvals.forgetReads(caller: ChatStore.caller)
            chat.images = [picture()]
            chat.submit("what is this")
            #expect(Approvals.sitesRead(caller: ChatStore.caller).contains(Approvals.addedImage))
            chat.handle(["type": "result", "is_error": true, "result": "Overloaded"])
            chat.endRun()
            Approvals.forgetReads(caller: ChatStore.caller)
            chat.retryLast()
            #expect(chat.isRunning && chat.items.filter { $0.kind == .user }.count == 1 && chat.items.first?.images.count == 1, "the pictures are not lost or shown twice")
            #expect(Approvals.sitesRead(caller: ChatStore.caller).contains(Approvals.addedImage), "they are given to the AI again, so they are read again")
        }

        @Test func anAddedPictureIsListedAsReadButIsNeverASiteToAllowOrRevoke() {
            #expect(Approvals.display(Approvals.addedImage) == "an image you added")
            #expect(Approvals.hostname(ofSite: Approvals.addedImage) == nil)
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            var told = 0
            let listener = Approvals.changes.sink { told += 1 }
            defer { listener.cancel() }
            Approvals.noteRead(sites: [Approvals.addedImage], caller: panel)
            Approvals.noteRead(sites: [Approvals.addedImage], caller: panel)
            #expect(told == 1, "the row under the header is told once, when something new was read")
            #expect(Approvals.sitesRead(caller: panel) == [Approvals.addedImage] && Approvals.sitesAllowed(caller: panel).isEmpty)
        }
    }
}
