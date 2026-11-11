import AppKit
import SwiftUI
import Testing
@testable import Changmun

/// A favorite's tile with its tab making sound or muted: the speaker sits on the tile's corner, not over the site's icon.
extension SharedAgentState {
    @MainActor @Suite(.serialized)
    struct FavoriteTileTests {
        /// The tile drawn on the sidebar's ground, as a bitmap at 2x.
        private func bitmap(_ entry: Library.Entry, tab: Changmun.Tab?) throws -> NSBitmapImageRep {
            let tile = FavoriteTile(entry: entry, state: .open, tab: tab, renaming: false, finishRenaming: { _ in }, open: {}) { EmptyView() }
                .frame(width: 44)
                .background(Theme.background)
            let renderer = ImageRenderer(content: tile)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            return try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        }

        @Test func theSpeakerLeavesTheIconAlmostWhole() throws {
            let b = Browser()
            defer { b.windowClosed() }
            let entry = Library.Entry(url: "https://video.example/", title: "Video")
            let tab = b.openTab(url: URL(string: entry.url))
            tab.toggleMute()
            #expect(tab.isMuted)
            let plain = try bitmap(entry, tab: nil)
            let marked = try bitmap(entry, tab: tab)
            let width = plain.pixelsWide, height = plain.pixelsHigh
            #expect(marked.pixelsWide == width)
            #expect(marked.pixelsHigh == height)
            // The site's icon: 20 pt square in the middle of the tile.
            let scale = 2, icon = 20 * scale
            let left = (width - icon) / 2, top = (height - icon) / 2
            var changed = 0
            for x in left..<(left + icon) {
                for y in top..<(top + icon) where plain.colorAt(x: x, y: y) != marked.colorAt(x: x, y: y) { changed += 1 }
            }
            #expect(changed > 0, "the speaker is there")
            // The button that sat on the corner covered a fifth of the icon; the badge covers under a tenth.
            #expect(Double(changed) / Double(icon * icon) < 0.12, "covers \(changed) of \(icon * icon) of the icon's pixels")
        }
    }
}
