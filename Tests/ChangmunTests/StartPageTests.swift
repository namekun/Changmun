import Foundation
import SwiftUI
import Testing
@testable import Changmun

@MainActor
private func isolatedDefaults() -> UserDefaults {
    let name = "StartPageTests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: The favorites

struct StartPageArrangementTests {
    @Test func favoritesNeverRunWiderThanTheColumn() {
        for width in stride(from: CGFloat(320), through: 2000, by: 40) {
            let shown = StartPageArrangement.favoritesShown(count: 40, pageWidth: width)
            let column = min(StartPageArrangement.column, width - 2 * StartPageArrangement.pageMargin)
            #expect(shown >= 1)
            #expect(shown == 1 || CGFloat(shown) * StartPageArrangement.favoritePitch <= column, "\(width): \(shown) tiles in \(column)")
        }
    }

    @Test func aFewFavoritesAreAllShownAndManyAreCutToTheRow() {
        #expect(StartPageArrangement.favoritesShown(count: 3, pageWidth: 1440) == 3)
        #expect(StartPageArrangement.favoritesShown(count: 14, pageWidth: 1440) == 6, "the 620 pt column holds six tiles of 90")
        #expect(StartPageArrangement.favoritesShown(count: 14, pageWidth: 400) == 3)
        #expect(StartPageArrangement.favoritesShown(count: 0, pageWidth: 300) == 0)
    }

    @Test func aRowThatOverflowsEndsInAMoreTileThatShowsTheRest() {
        let few = StartPageArrangement.favoriteLayout(count: 3, pageWidth: 1440, expanded: false)
        #expect(few.rows == [0..<3] && few.shown == 3 && few.hidden == 0 && !few.hasActionTile)
        let exact = StartPageArrangement.favoriteLayout(count: 6, pageWidth: 1440, expanded: false)
        #expect(exact.hidden == 0 && exact.tiles == 6, "six fit the 620 pt column: nothing to fold")
        let many = StartPageArrangement.favoriteLayout(count: 14, pageWidth: 1440, expanded: false)
        #expect(many.shown == 5 && many.hidden == 9 && many.rows == [0..<6] && many.hasActionTile, "five tiles and '+9' fill the six places of the row")
        let seven = StartPageArrangement.favoriteLayout(count: 7, pageWidth: 1440, expanded: false)
        #expect(seven.shown == 5 && seven.hidden == 2)
        let narrow = StartPageArrangement.favoriteLayout(count: 14, pageWidth: 400, expanded: false)
        #expect(narrow.shown == 2 && narrow.hidden == 12 && narrow.tiles == 3)
    }

    @Test func expandedTheFavoritesRunOnInMoreRowsAndTheLastTileFoldsThemBack() {
        let layout = StartPageArrangement.favoriteLayout(count: 14, pageWidth: 1440, expanded: true)
        #expect(layout.shown == 14 && layout.hidden == 0 && layout.folds && layout.hasActionTile)
        #expect(layout.rows == [0..<6, 6..<12, 12..<15], "fourteen tiles and the fold tile, six to a row")
        #expect(layout.tiles == 15)
        let fits = StartPageArrangement.favoriteLayout(count: 4, pageWidth: 1440, expanded: true)
        #expect(!fits.folds && fits.rows == [0..<4], "nothing to unfold when everything fits")
    }

    @Test func everyFavoriteIsEitherShownOrCountedOnTheMoreTile() {
        for count in 0...30 {
            for width in stride(from: CGFloat(320), through: 1600, by: 80) {
                for expanded in [false, true] {
                    let layout = StartPageArrangement.favoriteLayout(count: count, pageWidth: width, expanded: expanded)
                    #expect(layout.shown + layout.hidden == count, "\(count) at \(width)")
                    #expect(layout.tiles == layout.shown + (layout.hasActionTile ? 1 : 0))
                }
            }
        }
    }

    @Test func iconsAreFullSmallOrALetter() {
        #expect(StartIconStyle.style(pixelWidth: 128) == .full)
        #expect(StartIconStyle.style(pixelWidth: 32) == .plate)
        #expect(StartIconStyle.style(pixelWidth: 16) == .plate)
        #expect(StartIconStyle.style(pixelWidth: 8) == .letter)
        #expect(StartIconStyle.style(pixelWidth: nil) == .letter)
        #expect(StartIconStyle.letter(for: "https://www.github.com/x") == "G")
        #expect(StartIconStyle.letter(for: "https://5ch.example/") == "5")
        #expect(StartIconStyle.letter(for: "") == "?")
        #expect(StartIconStyle.colorIndex(for: "https://a.test/", count: 8) == StartIconStyle.colorIndex(for: "https://a.test/x", count: 8))
        #expect((0..<8).contains(StartIconStyle.colorIndex(for: "https://zzz.test/", count: 8)))
    }
}

// MARK: The keyboard

struct StartPageCursorTests {
    @Test func tabGoesFromTheFieldToTheFirstFavoriteAndBack() {
        #expect(StartPageCursor().tab(count: 5, backwards: false).item == 0)
        #expect(StartPageCursor().tab(count: 5, backwards: true).item == 0)
        #expect(StartPageCursor(item: 3).tab(count: 5, backwards: false).item == nil)
        #expect(StartPageCursor(item: 3).tab(count: 5, backwards: true).item == nil)
        #expect(StartPageCursor().tab(count: 0, backwards: false).item == nil, "no favorites: the field keeps the keyboard")
    }

    @Test func arrowsMoveAlongTheRowAndUpToTheField() {
        #expect(StartPageCursor().move(.down, count: 5).item == 0)
        #expect(StartPageCursor().move(.down, count: 0).item == nil)
        #expect(StartPageCursor().move(.right, count: 5).item == nil, "in the field the arrows are the field's")
        #expect(StartPageCursor(item: 0).move(.right, count: 5).item == 1)
        #expect(StartPageCursor(item: 4).move(.right, count: 5).item == 4, "the last stays")
        #expect(StartPageCursor(item: 0).move(.left, count: 5).item == 0, "the first stays")
        #expect(StartPageCursor(item: 2).move(.up, count: 5).item == nil, "up is the search field")
        #expect(StartPageCursor(item: 2).move(.down, count: 5).item == 2)
    }
}

// MARK: The settings' model

@MainActor
struct StartPageSettingsModelTests {
    final class Spy {
        var announcements: [String] = []
    }

    private func make(spy: Spy = Spy()) -> (model: StartPageSettingsModel, store: StartPageStore, spy: Spy) {
        let store = StartPageStore(defaults: isolatedDefaults())
        return (StartPageSettingsModel(store: store, announce: { spy.announcements.append($0) }), store, spy)
    }

    @Test func theAddressIsCheckedWhenCommittedAndGetsHTTPS() {
        let (model, store, spy) = make()
        model.setNewTab(.address)
        #expect(model.addressState == nil, "nothing typed, nothing checked")
        model.address = "example.com/news"
        model.addressEdited()
        #expect(model.addressState == nil, "not while it is typed")
        model.commitAddress()
        #expect(model.address == "https://example.com/news" && store.settings.address == "https://example.com/news")
        if case .ok = model.addressState {} else { Issue.record("an https address is ok: \(String(describing: model.addressState))") }
        model.address = "example,com/news"
        model.commitAddress()
        #expect(model.addressState == .invalid && spy.announcements.last == String(localized: "That isn’t a valid address"))
        model.address = "   "
        model.commitAddress()
        #expect(model.addressState == .empty)
        model.address = "http://intranet.local/home"
        model.commitAddress()
        if case .insecure = model.addressState {} else { Issue.record("http is an insecure note: \(String(describing: model.addressState))") }
        model.useHTTPS()
        #expect(model.address == "https://intranet.local/home")
        if case .ok = model.addressState {} else { Issue.record("after \"Use https://\": \(String(describing: model.addressState))") }
        model.useHTTPS()
        #expect(model.address == "https://intranet.local/home", "nothing to change")
    }

    @Test func theArrowsAndTabAreTheSearchFieldsWhileSomethingIsTypedInIt() {
        for key in [KeyEquivalent.upArrow, .downArrow, .leftArrow, .rightArrow, .tab] {
            #expect(StartPageKeys.leavesToSearch(key, typing: true, inSearch: true), "\(key)")
            #expect(!StartPageKeys.leavesToSearch(key, typing: false, inSearch: true), "with nothing typed the page takes ↓ and ⇥ into its favorites")
            #expect(!StartPageKeys.leavesToSearch(key, typing: true, inSearch: false), "on a favorite the page has the keys")
        }
        #expect(!StartPageKeys.leavesToSearch(.return, typing: true, inSearch: true))
        #expect(!StartPageKeys.leavesToSearch(.escape, typing: true, inSearch: true))
    }
}
