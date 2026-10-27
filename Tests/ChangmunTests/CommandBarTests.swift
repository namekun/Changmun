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

    @Test func aClickRunsTheItemItWentDownOnWhateverTheRowHoldsWhenItComesUp() {
        var press = RowPress<String>()
        press.began(on: "wikipedia")
        press.began(on: "위키")   // the list changed under the pointer, and the row is asked again while the button is still down
        #expect(press.ended(inside: true) == "wikipedia")
    }

    @Test func aClickThatComesUpOutsideTheRowOrNeverWentDownRunsNothing() {
        var press = RowPress<String>()
        press.began(on: "wikipedia")
        #expect(press.ended(inside: false) == nil)
        #expect(press.ended(inside: true) == nil)
    }

    @Test func aPressIsForgottenOnceItIsDone() {
        var press = RowPress<String>()
        press.began(on: "a")
        _ = press.ended(inside: true)
        press.began(on: "b")
        #expect(press.ended(inside: true) == "b")
    }

    /// Rows are named by what they hold, so one that stays in a changed list is the same row, and a new list never hands a row another's item.
    @Test func rowsAreNamedByTheirItemsAndTwoEqualOnesByWhichIsWhich() {
        let ids = CommandBar.rowIDs([.suggested("a"), .suggested("b"), .suggested("a")])
        #expect(Set(ids).count == 3)
        let shorter = CommandBar.rowIDs([.suggested("b"), .suggested("a")])
        #expect(shorter[0] == ids[1] && shorter[1] == ids[0])
        #expect(CommandBar.rowIDs([.search("위"), .ask("위")]) != CommandBar.rowIDs([.search("위키"), .ask("위키")]))
    }

    /// A syllable an input method is still composing is in the field editor and not yet in the field's text: the list goes by what is shown.
    @Test func theFieldShowsWhatItsEditorHoldsComposingTextIncluded() {
        #expect(CommandBar.shownText(editor: "위키", binding: "위") == "위키")
        #expect(CommandBar.shownText(editor: nil, binding: "위") == "위")
        #expect(CommandBar.shownText(editor: "", binding: "위") == "")
    }
}
