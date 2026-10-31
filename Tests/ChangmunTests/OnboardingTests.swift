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

    @Test func theLineBesideImportFollowsWhatIsTicked() {
        let model = ImportModel()
        let chrome = ImportSource(browser: "Chrome", directory: URL(fileURLWithPath: "/tmp/chrome"), kind: .chromium(safeStorage: "Chrome Safe Storage"))
        let safari = ImportSource(browser: "Safari", directory: URL(fileURLWithPath: "/tmp/safari"), kind: .safari)
        model.sources = [chrome, safari]
        model.selected = [chrome.id, safari.id]
        model.options = ImportOptions()
        #expect(model.willCome == String(localized: "Will come over: \(AIGuidance.list([String(localized: "bookmarks"), String(localized: "history"), String(localized: "passwords"), String(localized: "sign-ins")]))"))
        model.selected = [safari.id]
        #expect(!model.willCome.contains(String(localized: "passwords")) && !model.willCome.contains(String(localized: "sign-ins")), "Safari has none to give")
        model.selected = [chrome.id]
        model.options.passwords = false
        #expect(!model.willCome.contains(String(localized: "passwords")) && model.willCome.contains(String(localized: "sign-ins")))
        model.options = ImportOptions(bookmarks: false, history: false, passwords: false, cookies: false)
        #expect(model.willCome == String(localized: "Nothing will come over"))
    }
}
