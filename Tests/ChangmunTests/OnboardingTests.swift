import Foundation
import Testing
@testable import Changmun

/// The last screen of first run: what came over is the sum over the browsers, and only what there is shows.
@MainActor
struct OnboardingTests {
    @Test func theNumbersAreTheSumOverAllBrowsersAndOnlyWhatThereIsShows() {
        let model = ImportModel(sources: [])
        model.reports = [ImportReport(source: "Safari", bookmarks: 1_000, history: 8_000), ImportReport(source: "Chrome", bookmarks: 204, history: 310, passwords: 42, keptPasswords: 3)]
        #expect(model.totals.bookmarks == 1_204 && model.totals.history == 8_310 && model.totals.passwords == 42 && model.totals.keptPasswords == 3)
        #expect(model.stats.map(\.value) == [1_204, 8_310, 42])
        #expect(model.stats.map(\.label) == [String(localized: "Bookmarks"), String(localized: "History"), String(localized: "Passwords")])
        model.reports = [ImportReport(source: "Safari")]
        #expect(model.stats.isEmpty, "nothing imported: the screen says so in words instead")
        #expect(model.totals.summary == String(localized: "No items imported"))
    }

    @Test func laterGoesStraightToTheLastScreenWithNoNumbers() {
        let model = ImportModel(sources: [])
        AIAvailability.detector = { .none }
        defer { AIAvailability.detector = { AIAvailability.detect() } }
        model.showAI()
        #expect(model.step == .ai && model.ai == .none && model.reports.isEmpty)
    }

    @Test func theLineBesideImportFollowsWhatIsTicked() {
        let model = ImportModel(sources: [])
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

    // MARK: Leaving, stopping, trying again

    private let chrome = ImportSource(browser: "Chrome", directory: URL(fileURLWithPath: "/var/empty/changmun-test/Chrome"), kind: .chromium(safeStorage: "Test Safe Storage"))
    private let safari = ImportSource(browser: "Safari", directory: URL(fileURLWithPath: "/var/empty/changmun-test/Safari"), kind: .safari)
    private let arc = ImportSource(browser: "Arc", directory: URL(fileURLWithPath: "/var/empty/changmun-test/Arc"), kind: .chromium(safeStorage: "Test Safe Storage"))

    private func makeModel(_ sources: [ImportSource], firstRun: Bool = true) -> ImportModel {
        let model = ImportModel(firstRun: firstRun, sources: sources)
        model.selected = Set(sources.map(\.id))
        return model
    }

    @Test func escAndCancelGoBackWhereTheUserWasAfterALaterRunButToTheLastScreenOnTheFirst() {
        AIAvailability.detector = { .none }
        defer { AIAvailability.detector = { AIAvailability.detect() } }
        var left = 0
        let later = makeModel([chrome], firstRun: false)
        later.skip { left += 1 }
        #expect(left == 1 && later.step == .welcome, "a run from Settings or the sidebar returns to the page, not to the last screen")
        let first = makeModel([chrome], firstRun: true)
        first.skip { left += 1 }
        #expect(left == 1 && first.step == .ai, "the first run goes on to its last screen")
    }

    @Test func aRunCanBeStoppedBetweenBrowsersAndNeverInTheMiddleOfOne() async {
        AIAvailability.detector = { .none }
        defer { AIAvailability.detector = { AIAvailability.detect() } }
        let model = makeModel([chrome, safari, arc])
        let during = Recorded<Bool>()
        model.runner = { source, _, _ in
            await during.add(MainActor.run { model.canStop })
            if source.browser == "Chrome" { await MainActor.run { model.stop() } }
            return ImportReport(source: source.title, bookmarks: 1)
        }
        await model.start().value
        #expect(model.reports.map(\.source) == ["Chrome"], "the browser in hand finished; the others were not started")
        #expect(model.stopped && model.step == .done)
        #expect(await during.values == [true], "it could be stopped while there was a browser after it")
        let single = makeModel([chrome])
        let last = Recorded<Bool>()
        single.runner = { source, _, _ in
            await last.add(MainActor.run { single.canStop })
            return ImportReport(source: source.title)
        }
        await single.start().value
        #expect(await last.values == [false], "the last one cannot be stopped partway, and the screen says so instead of showing a dead button")
        #expect(!single.stopped)
    }

    @Test func tryAgainImportsOnlyTheBrowsersThatNeededFullDiskAccess() async {
        AIAvailability.detector = { .none }
        defer { AIAvailability.detector = { AIAvailability.detect() } }
        let model = makeModel([chrome, safari])
        let calls = Recorded<String>()
        let granted = Recorded<Bool>()
        model.runner = { source, _, _ in
            await calls.add(source.browser)
            if source.browser == "Safari", await granted.values.isEmpty { return ImportReport(source: source.title, problems: [ImportRunner.fullDiskAccessProblem]) }
            return ImportReport(source: source.title, bookmarks: 5)
        }
        await model.start().value
        #expect(model.reports.contains { $0.needsFullDiskAccess })
        await granted.add(true)
        await model.tryAgain().value
        #expect(await calls.values == ["Chrome", "Safari", "Safari"], "Chrome came over the first time and is left alone")
        #expect(model.reports.count == 2 && !model.reports.contains { $0.needsFullDiskAccess })
        #expect(model.totals.bookmarks == 10)
        #expect(!model.offersReopen)
    }

    @Test func quitAndReopenIsOfferedOnlyOnceTryAgainStillCouldNotRead() async {
        #expect(!ImportModel.offersReopen(triedAgain: false, needsAccess: true), "first Try Again, which may be enough")
        #expect(ImportModel.offersReopen(triedAgain: true, needsAccess: true))
        #expect(!ImportModel.offersReopen(triedAgain: true, needsAccess: false))
        AIAvailability.detector = { .none }
        defer { AIAvailability.detector = { AIAvailability.detect() } }
        let model = makeModel([safari])
        model.runner = { source, _, _ in ImportReport(source: source.title, problems: [ImportRunner.fullDiskAccessProblem]) }
        await model.start().value
        #expect(!model.offersReopen)
        await model.tryAgain().value
        #expect(model.offersReopen, "macOS applies the grant only after the app reopens")
    }

    @Test func theResultNamesEveryTickedKindThatBroughtNothing() {
        let model = makeModel([chrome])
        model.reports = [ImportReport(source: chrome.title, bookmarks: 3)]
        #expect(model.nothingFound == [String(localized: "\(String(localized: "History")): none found"), String(localized: "\(String(localized: "Passwords")): none found"),
                                       String(localized: "\(String(localized: "Cookies")): none found")])
        model.options.history = false
        model.options.cookies = false
        #expect(model.nothingFound == [String(localized: "\(String(localized: "Passwords")): none found")], "what was not ticked is not reported")
        model.reports = [ImportReport(source: chrome.title, bookmarks: 3, history: 9, passwords: 2)]
        #expect(model.nothingFound.isEmpty)
    }

    @Test func aBrowserWithNoPasswordsToGiveIsNotReportedAsHavingNone() {
        let model = makeModel([safari])
        model.reports = [ImportReport(source: safari.title, readingList: 4)]
        #expect(model.nothingFound == [String(localized: "\(String(localized: "History")): none found")], "Safari has no passwords or sign-ins; its reading list counts as bookmarks")
    }

    @Test func aRunThatWasStoppedDoesNotReportTheBrowsersItNeverReached() {
        let model = makeModel([chrome, safari])
        model.reports = [ImportReport(source: safari.title, bookmarks: 1, history: 1)]
        #expect(model.nothingFound.isEmpty, "Chrome was never reached, so its passwords are not 'none found'")
    }
}

/// What a fake import runner saw, from whichever task it ran on.
private actor Recorded<Value: Sendable> {
    private(set) var values: [Value] = []
    func add(_ value: Value) { values.append(value) }
}
