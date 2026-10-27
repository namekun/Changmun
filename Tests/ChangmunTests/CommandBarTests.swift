import AppKit
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

    // MARK: The bar's own field

    /// The window's field editor, lent to `field` while it has the focus, as AppKit does it.
    @MainActor private func editor(of field: NSTextField, in window: NSWindow) throws -> NSTextView {
        #expect(window.makeFirstResponder(field))
        return try #require(field.currentEditor() as? NSTextView)
    }

    @MainActor private func window(with fields: NSTextField...) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        for (index, field) in fields.enumerated() {
            field.frame = NSRect(x: 0, y: 40 * index, width: 200, height: 24)
            window.contentView?.addSubview(field)
        }
        return window
    }

    @Test @MainActor func onlyTheEditorOfTheBarsOwnFieldIsTheBars() throws {
        let bar = NSTextField(string: "wiki"), find = NSTextField(string: "needle")
        bar.placeholderString = "Search"
        find.placeholderString = "Find"
        let window = window(with: bar, find)
        let own = try editor(of: bar, in: window)
        #expect(CommandBar.ownEditor(own, in: window, placeholder: "Search") === own)
        // ⌘F, or Tab to another field: the window lends the same editor to that field, and its typing is not the bar's.
        let lent = try editor(of: find, in: window)
        #expect(lent === own, "one editor serves every field of the window")
        #expect(CommandBar.ownEditor(lent, in: window, placeholder: "Search") == nil)
        #expect(CommandBar.ownEditor(window.firstResponder, in: window, placeholder: "Search") == nil)
    }

    @Test @MainActor func theEditorOfAnotherWindowsBarIsNotThisBars() throws {
        let bar = NSTextField(string: "wiki"), otherBar = NSTextField(string: "wiki")
        bar.placeholderString = "Search"
        otherBar.placeholderString = "Search"
        let here = window(with: bar), there = window(with: otherBar)
        let editor = try editor(of: otherBar, in: there)
        #expect(CommandBar.ownEditor(editor, in: there, placeholder: "Search") === editor)
        #expect(CommandBar.ownEditor(editor, in: here, placeholder: "Search") == nil)
        #expect(CommandBar.ownEditor(editor, in: nil, placeholder: "Search") == nil)
        #expect(CommandBar.ownEditor(NSView(), in: here, placeholder: "Search") == nil)
    }

    // MARK: Rows and the highlight

    private func tab(_ id: Int, title: String, url: String = "https://a.example/") -> CommandBar.Suggestion {
        .tab(id: id, url: url, title: title, space: nil)
    }

    /// A background tab's title changes as its page loads: its row is still its row, and the highlight stays on it.
    @Test func aTabsRowKeepsItsNameWhenItsTitleChanges() {
        let before: [CommandBar.Suggestion] = [.search("a"), .ask("a"), tab(7, title: "Loading"), .suggested("apple")]
        let after: [CommandBar.Suggestion] = [.search("a"), .ask("a"), tab(7, title: "Apples – a.example", url: "https://a.example/apples"), .suggested("apple")]
        #expect(CommandBar.rowIDs(before) == CommandBar.rowIDs(after))
        #expect(CommandBar.keptSelection(2, old: before, new: after) == 2, "Return still switches to the tab that was highlighted")
        #expect(CommandBar.chosen(after, at: CommandBar.keptSelection(2, old: before, new: after)) == after[2])
    }

    @Test func twoTabsAreTwoRowsAndTheHighlightFollowsItsTab() {
        let list: [CommandBar.Suggestion] = [.search("a"), tab(1, title: "One"), tab(2, title: "Two")]
        #expect(Set(CommandBar.rowIDs(list)).count == 3)
        let reordered: [CommandBar.Suggestion] = [.search("a"), tab(2, title: "Two!"), tab(1, title: "One!")]
        #expect(CommandBar.keptSelection(2, old: list, new: reordered) == 2 - 1, "the highlighted tab moved up one place")
        #expect(CommandBar.keptSelection(1, old: list, new: [.search("a"), tab(2, title: "Two")]) == 0, "a tab that is gone leaves the highlight on the first row")
        #expect(CommandBar.keptSelection(9, old: list, new: list) == 0)
    }

    // MARK: The pointer

    @Test func aListChangingUnderARestingPointerIsNotThePointerMoving() {
        var pointer = PointerMovement()
        func moved(_ x: Double, _ y: Double) -> Bool { pointer.moved(to: CGPoint(x: x, y: y)) }
        #expect(!moved(100, 200), "the first sighting only notes the place")
        #expect(!moved(100, 200), "a row built under it says hovered again, without movement")
        #expect(moved(101, 200))
        #expect(!moved(101, 200))
        #expect(moved(101, 230))
    }
}
