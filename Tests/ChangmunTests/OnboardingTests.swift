import Foundation
import Testing
@testable import Changmun

/// The last screen of first run: what came over is the sum over the browsers, and only what there is shows.
@MainActor
struct OnboardingTests {
    @Test func theNumbersAreTheSumOverAllBrowsersAndOnlyWhatThereIsShows() {
        let model = ImportModel()
        model.reports = [ImportReport(source: "Safari", bookmarks: 1_000, history: 8_000), ImportReport(source: "Chrome", bookmarks: 204, history: 310, passwords: 42, keptPasswords: 3)]
        #expect(model.totals.bookmarks == 1_204 && model.totals.history == 8_310 && model.totals.passwords == 42 && model.totals.keptPasswords == 3)
        #expect(model.stats.map(\.value) == [1_204, 8_310, 42])
        #expect(model.stats.map(\.label) == [String(localized: "Bookmarks"), String(localized: "History"), String(localized: "Passwords")])
        model.reports = [ImportReport(source: "Safari")]
        #expect(model.stats.isEmpty, "nothing imported: the screen says so in words instead")
        #expect(model.totals.summary == String(localized: "No items imported"))
    }

    @Test func laterGoesStraightToTheLastScreenWithNoNumbers() {
        let model = ImportModel()
        AIAvailability.detector = { .none }
        defer { AIAvailability.detector = { AIAvailability.detect() } }
        model.showAI()
        #expect(model.step == .ai && model.ai == .none && model.reports.isEmpty)
    }
}
