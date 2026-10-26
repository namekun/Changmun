import Testing
@testable import Changmun

struct CommandBarTests {
    private let rows: [CommandBar.Suggestion] = [.search("wiki"), .ask("wiki"), .suggested("wikipedia"), .page(url: "https://en.wikipedia.org/", title: "Wikipedia")]

    @Test func returnRunsTheHighlightedRowOfTheListItIsGiven() {
        #expect(CommandBar.chosen(rows, at: 0) == .search("wiki"))
        #expect(CommandBar.chosen(rows, at: 2) == .suggested("wikipedia"))
        #expect(CommandBar.chosen(rows, at: 3) == .page(url: "https://en.wikipedia.org/", title: "Wikipedia"))
    }

    /// The same highlight in a longer list is another row: Return has to be given the list on screen, not the one the field was set up with.
    @Test func theSameHighlightIsAnotherRowOnceMoreResultsHaveCome() {
        let before = Array(rows.prefix(2))
        #expect(CommandBar.chosen(before, at: 2) == nil)
        #expect(CommandBar.chosen(rows, at: 2) == .suggested("wikipedia"))
    }

    @Test func aHighlightPastTheEndOrBeforeTheStartRunsNothing() {
        #expect(CommandBar.chosen(rows, at: rows.count) == nil)
        #expect(CommandBar.chosen(rows, at: -1) == nil)
        #expect(CommandBar.chosen([], at: 0) == nil)
    }
}
