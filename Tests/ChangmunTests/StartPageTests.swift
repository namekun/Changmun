import Foundation
import SwiftUI
import Testing
@testable import Changmun

private func visit(_ url: String, _ title: String = "", minutesAgo: Double = 0, now: Date = Date(timeIntervalSince1970: 1_000_000)) -> Library.Visit {
    Library.Visit(url: url, title: title, lastVisit: now.addingTimeInterval(-minutesAgo * 60))
}

private func closedTab(_ url: String?, space: UUID, minutesAgo: Double = 0, title: String = "t") -> StartClosedTab {
    StartClosedTab(id: UUID(), url: url, title: title, closedAt: Date(timeIntervalSince1970: 1_000_000).addingTimeInterval(-minutesAgo * 60), space: space)
}

@MainActor
private func isolatedDefaults() -> UserDefaults {
    let name = "StartPageTests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: What the sections hold

struct StartPageDataTests {
    let space = UUID()

    @Test func closedTabsOfThisSpaceComeFirstNewestFirst() {
        let other = UUID()
        let closed = [closedTab("https://a.test/1", space: space, minutesAgo: 30), closedTab("https://other.test/", space: other), closedTab("https://b.test/", space: space, minutesAgo: 5)]
        let cards = StartPageData.continueCards(closed: closed, history: [visit("https://c.test/")], open: [], space: space, closedOnly: false, isPrivate: false)
        #expect(cards.map(\.url) == ["https://b.test/", "https://a.test/1", "https://c.test/"])
        #expect(cards.map(\.isClosedTab) == [true, true, false])
    }

    @Test func pagesThatAreOpenOrOnACardAlreadyAreLeftOut() {
        let closed = [closedTab("https://a.test/#top", space: space)]
        let history = [visit("https://a.test"), visit("https://open.test/"), visit("https://d.test/"), visit("https://d.test/")]
        let cards = StartPageData.continueCards(closed: closed, history: history, open: ["https://open.test"], space: space, closedOnly: false, isPrivate: false)
        #expect(cards.map(\.url) == ["https://a.test/#top", "https://d.test/"], "the same page twice, an open one and a closed tab's own page are each shown once")
    }

    @Test func theLimitAndTheClosedOnlyOptionApply() {
        let closed = (0..<6).map { closedTab("https://c\($0).test/", space: space, minutesAgo: Double($0)) }
        let history = (0..<6).map { visit("https://h\($0).test/") }
        #expect(StartPageData.continueCards(closed: closed, history: history, open: [], space: space, closedOnly: false, limit: 4, isPrivate: false).count == 4)
        #expect(StartPageData.continueCards(closed: Array(closed.prefix(2)), history: history, open: [], space: space, closedOnly: false, limit: 4, isPrivate: false).count == 4)
        let onlyClosed = StartPageData.continueCards(closed: Array(closed.prefix(2)), history: history, open: [], space: space, closedOnly: true, limit: 4, isPrivate: false)
        #expect(onlyClosed.count == 2 && onlyClosed.allSatisfy(\.isClosedTab))
        #expect(StartPageData.continueCards(closed: closed, history: history, open: [], space: space, closedOnly: false, limit: 3, isPrivate: false).count == 3)
    }

    @Test func aPrivateWindowHasNoCardsReadingItemsOrSites() {
        let closed = [closedTab("https://a.test/", space: space)]
        #expect(StartPageData.continueCards(closed: closed, history: [visit("https://b.test/")], open: [], space: space, closedOnly: false, isPrivate: true).isEmpty)
        #expect(StartPageData.readingItems([ReadingItem(url: "https://a.test/", title: "a", added: Date(), read: false)], all: true, isPrivate: true).shown.isEmpty)
        #expect(StartPageData.frequentSites([StartFrequentSite(host: "a.test", title: "a", url: "https://a.test/", visits: 3)], eight: true, isPrivate: true).isEmpty)
    }

    @Test func pagesWithoutAWebAddressAreNeverCards() {
        let closed = [closedTab(nil, space: space), closedTab("about:blank", space: space), closedTab("", space: space)]
        #expect(StartPageData.continueCards(closed: closed, history: [visit("file:///x")], open: [], space: space, closedOnly: false, isPrivate: false).isEmpty)
    }

    @Test func hiddenPagesAreSkipped() {
        let cards = StartPageData.continueCards(closed: [], history: [visit("https://a.test/"), visit("https://b.test/")], open: [], space: space, closedOnly: false,
                                                isHidden: { $0.contains("a.test") }, isPrivate: false)
        #expect(cards.map(\.url) == ["https://b.test/"])
    }

    @Test func theReadingListShowsUnreadOrAllWithTheirCount() {
        let items = (0..<8).map { ReadingItem(url: "https://r\($0).test/", title: "r\($0)", added: Date(), read: $0 % 2 == 1) }
        let unread = StartPageData.readingItems(items, all: false, isPrivate: false)
        #expect(unread.shown.count == 4 && unread.shown.allSatisfy { !$0.read } && unread.unread == 4)
        let all = StartPageData.readingItems(items, all: true, isPrivate: false)
        #expect(all.shown.count == StartPageData.readingAllLimit && all.unread == 4)
    }

    @Test func visitsAreCountedBySiteAndNamedByTheirFrontPage() {
        let pages: [(url: String, title: String, visits: Int)] = [
            ("https://www.github.com/namekun/Changmun", "namekun/Changmun: A browser", 30), ("https://github.com/", "GitHub: Let's build from here", 12),
            ("https://news.example.com/a", "A story", 20), ("https://bad", "", 1), ("not a url", "x", 99),
        ]
        let sites = StartFrequentSite.group(pages)
        #expect(sites.map(\.host) == ["github.com", "news.example.com", "bad"].filter { $0 != "bad" || sites.count == 3 })
        #expect(sites[0].visits == 42 && sites[0].title == "GitHub", "visits add up, the front page names the site")
        #expect(sites[0].url == "https://www.github.com/namekun/Changmun", "and the most visited page is what opens")
        #expect(sites[1].title == "news.example.com", "a site without a front page in the history is called by its address")
        #expect(StartPageData.frequentSites(sites, eight: false, isPrivate: false).count == sites.count)
    }

    @Test func frequentSitesShowFourOrEight() {
        let sites = (0..<10).map { StartFrequentSite(host: "s\($0).test", title: "s", url: "https://s\($0).test/", visits: 10 - $0) }
        #expect(StartPageData.frequentSites(sites, eight: false, isPrivate: false).count == 4)
        #expect(StartPageData.frequentSites(sites, eight: true, isPrivate: false).count == 8)
        #expect(StartPageData.frequentSites(sites, eight: true, isHidden: { $0 == "s0.test" }, isPrivate: false).first?.host == "s1.test")
    }
}

// MARK: When

struct StartPageTimeTests {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    let now = Date(timeIntervalSince1970: 1_700_000_000 + 12 * 3600)  // 2023-11-15 02:13 UTC + 12h

    @Test func buckets() {
        let c = calendar
        #expect(StartPageTime.bucket(now.addingTimeInterval(-8 * 60), now: now, calendar: c) == .minutes(8))
        #expect(StartPageTime.bucket(now.addingTimeInterval(-10), now: now, calendar: c) == .minutes(0))
        #expect(StartPageTime.bucket(now.addingTimeInterval(-3 * 3600), now: now, calendar: c) == .today)
        #expect(StartPageTime.bucket(now.addingTimeInterval(-20 * 3600), now: now, calendar: c) == .yesterday)
        #expect(StartPageTime.bucket(now.addingTimeInterval(-3 * 86400), now: now, calendar: c) == .days(3))
        #expect(StartPageTime.bucket(now.addingTimeInterval(-9 * 86400), now: now, calendar: c) == .weeks(1))
        #expect(StartPageTime.bucket(now.addingTimeInterval(-60 * 86400), now: now, calendar: c) == .older)
    }

    @Test func labelsSayWhenInTheLocalesWords() {
        let en = Locale(identifier: "en_US")
        let eight = StartPageTime.label(now.addingTimeInterval(-8 * 60), now: now, calendar: calendar, locale: en)
        #expect(eight.contains("8") && eight.contains("ago"))
        #expect(StartPageTime.label(now.addingTimeInterval(-20 * 3600), now: now, calendar: calendar, locale: en) == "yesterday")
        let ko = StartPageTime.label(now.addingTimeInterval(-8 * 60), now: now, calendar: calendar, locale: Locale(identifier: "ko_KR"))
        #expect(ko.contains("8") && ko.contains("전"))
        #expect(StartPageTime.label(now.addingTimeInterval(-20 * 3600), now: now, calendar: calendar, locale: Locale(identifier: "ko_KR")) == "어제")
    }
}

// MARK: Which part of the page shows

struct StartPageRulesTests {
    private func contents(private isPrivate: Bool = false, ai: Bool = true, favorites: Int = 3, cards: Int = 2, reading: Int = 1, frequent: Int = 4, data: Bool = true) -> StartPageContents {
        StartPageContents(isPrivate: isPrivate, aiReady: ai, favorites: favorites, continueCards: cards, reading: reading, frequent: frequent, hasData: data)
    }

    @Test func sectionsWithoutDataHideThemselves() {
        let layout = StartPageSettings.defaultLayout(.dashboard)
        #expect(StartPageRules.mode(layout: layout, style: .dashboard, contents: contents()) == .sections([.aiSuggestions, .favorites, .continueViewing, .readingList]))
        #expect(StartPageRules.mode(layout: layout, style: .dashboard, contents: contents(cards: 0, reading: 0)) == .sections([.aiSuggestions, .favorites]))
        #expect(StartPageRules.mode(layout: layout, style: .dashboard, contents: contents(ai: false, cards: 0, reading: 0)) == .sections([.favorites]), "no AI, no suggestions")
        let all = layout.toggled(.frequent)
        #expect(StartPageRules.mode(layout: all, style: .dashboard, contents: contents(frequent: 0)) == .sections([.aiSuggestions, .favorites, .continueViewing, .readingList]))
    }

    @Test func favoritesAreAlwaysShownWhenOn() {
        let layout = StartPageSettings.defaultLayout(.quiet)
        #expect(StartPageRules.mode(layout: layout, style: .quiet, contents: contents(favorites: 0, cards: 0, reading: 0, frequent: 0, data: true)) == .sections([.favorites]))
        #expect(StartPageRules.mode(layout: layout.toggled(.favorites), style: .quiet, contents: contents()) == .sections([]))
    }

    @Test func aFreshProfileShowsTheFirstSteps() {
        let fresh = contents(favorites: 0, cards: 0, reading: 0, frequent: 0, data: false)
        for style in [StartStyle.dashboard, .quiet] { #expect(StartPageRules.mode(layout: StartPageSettings.defaultLayout(style), style: style, contents: fresh) == .firstRun) }
        #expect(StartPageRules.mode(layout: StartPageSettings.defaultLayout(.aiFirst), style: .aiFirst, contents: fresh) != .firstRun, "the AI box needs no data")
    }

    @Test func aPrivateWindowShowsOnlyItsNotice() {
        for style in StartStyle.allCases {
            #expect(StartPageRules.mode(layout: StartPageSettings.defaultLayout(style), style: style, contents: contents(private: true)) == .privateNotice)
        }
    }

    @Test func aSectionThatIsOnButEmptyIsSaidToBe() {
        #expect(StartPageRules.isEmpty(.readingList, contents: contents(reading: 0)))
        #expect(!StartPageRules.isEmpty(.readingList, contents: contents()))
        #expect(!StartPageRules.isEmpty(.favorites, contents: contents(favorites: 0)))
        #expect(StartPageRules.isEmpty(.aiSuggestions, contents: contents(ai: false)))
    }

    @Test func halfWidthSectionsPairWhenTheyFollowEachOther() {
        #expect(StartPageArrangement.rows([.favorites, .continueViewing, .readingList, .frequent], style: .dashboard) == [.full(.favorites), .full(.continueViewing), .pair(.readingList, .frequent)])
        #expect(StartPageArrangement.rows([.readingList, .favorites, .frequent], style: .dashboard) == [.wide(.readingList), .full(.favorites), .wide(.frequent)])
        #expect(StartPageArrangement.rows([.readingList], style: .dashboard) == [.wide(.readingList)])
        #expect(StartPageArrangement.rows([.favorites, .readingList, .frequent], style: .quiet) == [.full(.favorites), .full(.readingList), .full(.frequent)])
        #expect(StartPageArrangement.rows([.aiSuggestions, .favorites], style: .aiFirst) == [.full(.favorites)], "the AI cards belong to the box above")
    }

    @Test func twoRowsOfFavoritesAreBalanced() {
        #expect(StartPageArrangement.favoriteRows(count: 8, twoRows: true) == [0..<4, 4..<8])
        #expect(StartPageArrangement.favoriteRows(count: 7, twoRows: true) == [0..<4, 4..<7])
        #expect(StartPageArrangement.favoriteRows(count: 8, twoRows: false) == [0..<8])
        #expect(StartPageArrangement.favoriteRows(count: 1, twoRows: true) == [0..<1])
        #expect(StartPageArrangement.favoriteRows(count: 0, twoRows: true).isEmpty)
    }

    @Test func theAISuggestionsFitWhatIsOpen() {
        #expect(StartPageAI.suggestions(tabs: 0, limit: 4).map(\.id) == ["research", "find", "explain"])
        #expect(StartPageAI.suggestions(tabs: 1, limit: 4).map(\.id) == ["summarize", "research", "find", "explain"])
        #expect(StartPageAI.suggestions(tabs: 4, limit: 4).map(\.id) == ["summarize", "compare", "research", "group"])
        #expect(StartPageAI.suggestions(tabs: 4, limit: 3).count == 3)
        #expect(StartPageAI.suggestions(tabs: 2, limit: 4).allSatisfy { !$0.prompt.isEmpty })
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
    let shapes: [StartPageCursor.Shape] = [
        .init(part: .section(.favorites), count: 6, columns: 3), .init(part: .section(.continueViewing), count: 2, columns: 2),
        .init(part: .section(.readingList), count: 0, columns: 1), .init(part: .customize, count: 1, columns: 1),
    ]

    @Test func tabGoesFromPartToPartAndBackToTheSearchField() {
        var cursor = StartPageCursor()
        cursor = cursor.tab(shapes, backwards: false)
        #expect(cursor.stop == .init(part: .section(.favorites), item: 0))
        cursor = cursor.tab(shapes, backwards: false)
        #expect(cursor.stop == .init(part: .section(.continueViewing), item: 0), "an empty part is passed over")
        cursor = cursor.tab(shapes, backwards: false)
        #expect(cursor.stop == .init(part: .customize, item: 0))
        #expect(cursor.tab(shapes, backwards: false).stop == nil)
        #expect(StartPageCursor().tab(shapes, backwards: true).stop == .init(part: .customize, item: 0))
        #expect(StartPageCursor(stop: .init(part: .section(.favorites), item: 4)).tab(shapes, backwards: true).stop == nil)
    }

    @Test func arrowsMoveAlongTheRowsAndOnIntoTheNextPart() {
        var cursor = StartPageCursor(stop: .init(part: .section(.favorites), item: 0))
        cursor = cursor.move(.right, shapes)
        #expect(cursor.stop?.item == 1)
        cursor = cursor.move(.down, shapes)
        #expect(cursor.stop == .init(part: .section(.favorites), item: 4))
        cursor = cursor.move(.down, shapes)
        #expect(cursor.stop == .init(part: .section(.continueViewing), item: 0))
        cursor = cursor.move(.up, shapes)
        #expect(cursor.stop == .init(part: .section(.favorites), item: 5), "up goes to the last item of the part before")
        #expect(StartPageCursor(stop: .init(part: .section(.favorites), item: 1)).move(.up, shapes).stop == nil, "off the top is the search field")
        #expect(StartPageCursor(stop: .init(part: .section(.favorites), item: 5)).move(.right, shapes).stop?.item == 5, "the last item stays")
        #expect(StartPageCursor(stop: .init(part: .customize, item: 0)).move(.down, shapes).stop?.part == .customize)
        #expect(StartPageCursor().move(.down, shapes).stop == .init(part: .section(.favorites), item: 0))
    }
}

// MARK: Hidden items

@MainActor
struct StartHiddenItemsTests {
    @Test func theListKeepsOnlySaltedHashes() throws {
        let defaults = isolatedDefaults()
        let hidden = StartHiddenItems(defaults: defaults)
        hidden.hide(page: "https://secret-clinic.example/appointments?id=7")
        hidden.hide(site: "Secret-Clinic.example")
        let data = try #require(defaults.data(forKey: StartHiddenItems.defaultsKey))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("clinic") && !text.contains("appointments") && !text.contains("example"))
        #expect(hidden.count == 2)
        #expect(hidden.isHidden(page: "https://secret-clinic.example/appointments?id=7#part"), "a fragment does not tell pages apart")
        #expect(hidden.isHidden(site: "secret-clinic.example"))
        #expect(!hidden.isHidden(page: "https://secret-clinic.example/appointments?id=8"))
    }

    @Test func eachInstallHasItsOwnSalt() {
        let a = StartHiddenList.fresh(), b = StartHiddenList.fresh()
        #expect(a.salt != b.salt)
        #expect(StartHiddenList.digest("page:https://a.test/", salt: a.salt) != StartHiddenList.digest("page:https://a.test/", salt: b.salt))
        #expect(a.salt.count == 16)
    }

    @Test func theListIsCappedAndTheOldestGoFirst() {
        var list = StartHiddenList.fresh()
        for index in 0..<(StartHiddenList.limit + 20) { list.hide("page:https://s\(index).test/") }
        #expect(list.hashes.count == StartHiddenList.limit)
        #expect(!list.contains("page:https://s0.test/") && !list.contains("page:https://s19.test/"))
        #expect(list.contains("page:https://s20.test/") && list.contains("page:https://s519.test/"))
    }

    @Test func whatNothingMatchesAnyMoreIsPruned() {
        let hidden = StartHiddenItems(defaults: isolatedDefaults())
        hidden.hide(page: "https://gone.test/")
        hidden.hide(page: "https://kept.test/")
        hidden.hide(site: "gone.test")
        hidden.prune(pages: ["https://kept.test/#x"], sites: ["other.test"])
        #expect(hidden.count == 1 && hidden.isHidden(page: "https://kept.test/") && !hidden.isHidden(site: "gone.test"))
        hidden.prune(pages: [], sites: [])
        #expect(hidden.count == 0 && hidden.list == nil)
    }

    @Test func showAllLeavesNothingOnDiskAndTheOldRawListIsDroppedAtStart() {
        let defaults = isolatedDefaults()
        defaults.set(["https://raw.test/"], forKey: StartHiddenItems.legacyKey)
        let hidden = StartHiddenItems(defaults: defaults)
        #expect(defaults.object(forKey: StartHiddenItems.legacyKey) == nil)
        hidden.hide(page: "https://a.test/")
        #expect(defaults.data(forKey: StartHiddenItems.defaultsKey) != nil)
        hidden.showAll()
        #expect(defaults.data(forKey: StartHiddenItems.defaultsKey) == nil && hidden.count == 0)
        #expect(StartHiddenItems(defaults: defaults).count == 0)
    }

    @Test func theListComesBackAfterARestart() {
        let defaults = isolatedDefaults()
        StartHiddenItems(defaults: defaults).hide(site: "a.test")
        #expect(StartHiddenItems(defaults: defaults).isHidden(site: "a.test"))
    }
}

// MARK: The scrim

struct StartScrimTests {
    private func flat(_ value: UInt8, count: Int = 32 * 32) -> [UInt8] { (0..<count).flatMap { _ in [value, value, value, 255] } }

    @Test func luminanceAndContrastRatioFollowWCAG() {
        #expect(abs(StartScrim.relativeLuminance(red: 1, green: 1, blue: 1) - 1) < 0.0001)
        #expect(StartScrim.relativeLuminance(red: 0, green: 0, blue: 0) == 0)
        #expect(abs(StartScrim.contrastRatio(1, 0) - 21) < 0.0001)
        #expect(abs(StartScrim.relativeLuminance(red: 1, green: 0, blue: 0) - 0.2126) < 0.0001)
    }

    @Test func aFlatPictureHasNoLocalContrastAndACheckerHasTheMost() {
        let flatStats = StartScrim.measure(rgba: flat(128), width: 32, height: 32)
        #expect(flatStats.contrast == 0 && !flatStats.isBusy)
        var checker: [UInt8] = []
        for y in 0..<32 { for x in 0..<32 { let v: UInt8 = (x + y) % 2 == 0 ? 255 : 0; checker += [v, v, v, 255] } }
        let busy = StartScrim.measure(rgba: checker, width: 32, height: 32)
        #expect(abs(busy.luminance - 0.5) < 0.001 && abs(busy.contrast - 1) < 0.001 && busy.isBusy)
        #expect(StartScrim.measure(rgba: [1, 2], width: 32, height: 32).luminance == 0.5, "too few pixels is not a measurement")
    }

    @Test func aBrightPictureNeedsLittleInLightModeAndADarkOneMoreInDark() {
        let bright = StartImageStats(luminance: 0.9, contrast: 0.02)
        #expect(StartScrim.scrim(stats: bright, dark: false).opacity == StartScrim.minimum, "already pale enough: the least there is")
        #expect(StartScrim.scrim(stats: bright, dark: true).opacity == StartScrim.maximum, "a bright picture under light text needs all of it")
        let dim = StartImageStats(luminance: 0.01, contrast: 0.01)
        #expect(StartScrim.scrim(stats: dim, dark: true).opacity == StartScrim.minimum)
        #expect(StartScrim.scrim(stats: dim, dark: false).opacity == StartScrim.maximum)
    }

    @Test func theScrimGrowsWithTheBrightnessAndBusynessAndMeetsTheTarget() {
        var last = 0.0
        for luminance in stride(from: 0.2, through: 0.7, by: 0.1) {
            let result = StartScrim.scrim(stats: StartImageStats(luminance: luminance, contrast: 0.02), dark: true)
            #expect(result.opacity >= last)
            last = result.opacity
        }
        let calm = StartScrim.scrim(stats: StartImageStats(luminance: 0.1, contrast: 0), dark: true)
        let busy = StartScrim.scrim(stats: StartImageStats(luminance: 0.1, contrast: 0.05), dark: true)
        #expect(busy.opacity > calm.opacity)
        // What the scrim leaves is dark enough for the secondary text to have 4.5 : 1.
        let stats = StartImageStats(luminance: 0.05, contrast: 0.02)
        let result = StartScrim.scrim(stats: stats, dark: true)
        let left = (1 - result.opacity) * min(1, 0.05 + 2.5 * 0.02) + result.opacity * 0.005
        #expect(result.reachesTarget && StartScrim.contrastRatio(0.33, left) >= 4.4)
    }

    @Test func aPictureNothingCanFixIsSaidToBe() {
        #expect(!StartScrim.scrim(stats: StartImageStats(luminance: 0.05, contrast: 0.0), dark: false).reachesTarget)
        #expect(StartScrim.scrim(stats: StartImageStats(luminance: 0.8, contrast: 0.0), dark: false).reachesTarget)
    }

    @Test func theUsersOwnDimmingCountsAndReduceTransparencyRaisesTheFloor() {
        let stats = StartImageStats(luminance: 0.08, contrast: 0.02)
        let plain = StartScrim.scrim(stats: stats, dark: true, dim: 0)
        let dimmed = StartScrim.scrim(stats: stats, dark: true, dim: 1)
        #expect(dimmed.opacity < plain.opacity)
        #expect(StartScrim.scrim(stats: StartImageStats(luminance: 0.9, contrast: 0), dark: false, reduceTransparency: true).opacity == StartScrim.minimumOpaque)
        let high = StartScrim.scrim(stats: stats, dark: true, highContrast: true)
        let left = (1 - high.opacity) * min(1, 0.08 + 2.5 * 0.02) + high.opacity * 0.005
        #expect(high.reachesTarget && StartScrim.contrastRatio(0.75, left) >= 6.9, "Increase Contrast aims at 7 : 1 against its stronger text")
        #expect((StartScrim.minimum...StartScrim.maximum).contains(plain.opacity))
    }

    @Test func swatchesHaveALightAndADarkToneAndCustomColoursFollow() {
        for id in StartBackground.swatches {
            let light = StartSwatch.tone(id, dark: false), dark = StartSwatch.tone(id, dark: true)
            #expect(light != nil && dark != nil && light != dark)
            let lightLuminance = StartScrim.relativeLuminance(red: light!.red, green: light!.green, blue: light!.blue)
            let darkLuminance = StartScrim.relativeLuminance(red: dark!.red, green: dark!.green, blue: dark!.blue)
            #expect(lightLuminance > 0.6 && darkLuminance < 0.05, "\(id)")
        }
        #expect(StartSwatch.tone("nope", dark: false) == nil)
        #expect(StartSwatch.parseHex("#3A7BE0") != nil && StartSwatch.parseHex("3a7be0") != nil)
        #expect(StartSwatch.parseHex("#3A7BE") == nil && StartSwatch.parseHex("zzzzzz") == nil)
        #expect(StartSwatch.hex(of: StartSwatch.parseHex("#3A7BE0")!) == "#3A7BE0")
        let custom = StartBackground(kind: .color, colorID: "custom", customHex: "#FF0000")
        #expect(StartSwatch.page(custom, dark: false) != StartSwatch.page(custom, dark: true))
        #expect(StartSwatch.page(StartBackground(kind: .color, colorID: "custom", customHex: "bad"), dark: false) == StartSwatch.tone("slate", dark: false), "an unreadable colour is the slate")
    }
}

// MARK: The popover's model

@MainActor
struct StartPageCustomizeModelTests {
    final class Spy {
        var announcements: [String] = []
        var undo: (message: String, run: () -> Void)?
        var imports: [URL] = []
    }

    private func make(spy: Spy = Spy(), imported: Bool = true, file: String? = "pic.jpg") -> (model: StartPageCustomizeModel, store: StartPageStore, hidden: StartHiddenItems, spy: Spy) {
        let defaults = isolatedDefaults()
        let store = StartPageStore(defaults: defaults)
        let hidden = StartHiddenItems(defaults: defaults)
        let model = StartPageCustomizeModel(store: store, offerUndo: { spy.undo = ($0, $1) }, importImage: { url in
            spy.imports.append(url)
            if imported, let file { store.update { $0.background.imageFile = file } }
            return imported
        }, announce: { spy.announcements.append($0) }, hidden: hidden)
        return (model, store, hidden, spy)
    }

    @Test func aStyleIsChosenAndEachKeepsItsSections() {
        let (model, store, _, spy) = make()
        model.toggle(.frequent)
        #expect(store.settings.dashboard.item(.frequent)?.enabled == true)
        model.setStyle(.quiet)
        #expect(store.settings.style == .quiet && model.items.first { $0.section == .frequent }?.enabled == false)
        #expect(spy.announcements.last?.contains("selected") == true)
        model.setStyle(.dashboard)
        #expect(model.items.first { $0.section == .frequent }?.enabled == true)
    }

    @Test func switchesAnnounceTheirState() {
        let (model, store, _, spy) = make()
        model.toggle(.readingList)
        #expect(store.settings.current.item(.readingList)?.enabled == false)
        #expect(spy.announcements.last == "\(StartSection.readingList.title), \(Accessibility.onOffValue(false))")
    }

    @Test func oneOptionRowIsOpenAtATimeAndAnOffSectionClosesItsRow() {
        let (model, _, _, _) = make()
        model.toggleOptions(.favorites)
        #expect(model.expanded == .favorites)
        model.toggleOptions(.readingList)
        #expect(model.expanded == .readingList)
        model.toggleOptions(.readingList)
        #expect(model.expanded == nil)
        model.toggleOptions(.aiSuggestions)
        #expect(model.expanded == nil, "the AI suggestions have no options")
        model.toggleOptions(.continueViewing)
        model.toggle(.continueViewing)
        #expect(model.expanded == nil)
    }

    @Test func optionsStepThroughTheirChoicesAndStayInRange() {
        let (model, store, _, _) = make()
        model.cycleOption(.favorites)
        #expect(store.settings.current.item(.favorites)?.option == 1)
        model.cycleOption(.favorites)
        #expect(store.settings.current.item(.favorites)?.option == 0)
        model.setOption(.frequent, 5)
        #expect(model.option(.frequent) == 0, "there is no third choice")
        model.setOption(.aiSuggestions, 1)
        #expect(model.option(.aiSuggestions) == 0)
        for section in StartSection.allCases { #expect(section.optionCount == (section == .aiSuggestions ? 0 : 2)) }
    }

    @Test func rowsMoveByStepsAndTheNewPlaceIsAnnounced() {
        let (model, _, _, spy) = make()
        #expect(model.position(of: .readingList) == 4 && model.reorderValue(.readingList) == "4 of 5")
        model.move(.readingList, by: -1)
        #expect(model.position(of: .readingList) == 3)
        #expect(spy.announcements.last == "\(StartSection.readingList.title), 3 of 5")
        let count = spy.announcements.count
        model.move(.aiSuggestions, by: -1)
        #expect(model.position(of: .aiSuggestions) == 1 && spy.announcements.count == count, "the top row stays, and nothing is said")
        #expect(model.reorderLabel(.readingList).contains(StartSection.readingList.title))
    }

    @Test func theKeyboardMovesWithOptionAndArrowsOnly() {
        #expect(StartPageCustomizeModel.step(up: true, option: true) == -1)
        #expect(StartPageCustomizeModel.step(up: false, option: true) == 1)
        #expect(StartPageCustomizeModel.step(up: true, option: false) == nil)
    }

    @Test func aDragRearrangesTheListAtOnce() {
        let h = StartPageCustomizeModel.rowHeight
        #expect(StartPageCustomizeModel.dragIndex(start: 3, translation: -h * 1.4, count: 5) == 2)
        #expect(StartPageCustomizeModel.dragIndex(start: 3, translation: -h * 2.6, count: 5) == 0)
        #expect(StartPageCustomizeModel.dragIndex(start: 3, translation: -h * 9, count: 5) == 0)
        #expect(StartPageCustomizeModel.dragIndex(start: 3, translation: h * 9, count: 5) == 4)
        #expect(StartPageCustomizeModel.dragIndex(start: 1, translation: h * 0.4, count: 5) == 1)
        let (model, store, _, spy) = make()
        model.toggleOptions(.favorites)
        model.beginDrag(.readingList)
        #expect(model.dragging == .readingList && model.expanded == nil)
        model.drag(.readingList, over: 0)
        #expect(store.settings.current.items.first?.section == .readingList)
        model.endDrag(.readingList)
        #expect(model.dragging == nil && spy.announcements.last == "\(StartSection.readingList.title), 1 of 5")
    }

    @Test func theBackgroundTilesSetTheKindAndThePictureAsksForAFileFirst() {
        let (model, store, _, _) = make()
        #expect(model.selectBackground(.plain) == false && store.settings.background.kind == .plain)
        #expect(model.selectBackground(.image) == true && store.settings.background.kind == .plain, "no picture yet: the panel opens and nothing changes")
        model.setColor("green")
        #expect(store.settings.background.kind == .color && store.settings.background.colorID == "green")
        model.setCustomColor(hex: "#112233")
        #expect(store.settings.background.colorID == "custom" && store.settings.background.customHex == "#112233")
        model.setCustomColor(hex: "nope")
        #expect(store.settings.background.customHex == "#112233")
        model.setBlur(2)
        model.setDim(-1)
        #expect(store.settings.background.blur == 1 && store.settings.background.dim == 0, "kept within 0 and 1")
    }

    @Test func aPictureThatWorksBecomesTheBackground() async {
        let (model, store, _, spy) = make()
        let url = URL(fileURLWithPath: "/tmp/anything.jpg")
        await model.chooseImage(url)
        #expect(spy.imports == [url] && model.imageState == .idle)
        #expect(store.settings.background.kind == .image && store.settings.background.imageFile == "pic.jpg")
        #expect(model.selectBackground(.plain) == false)
        #expect(model.selectBackground(.image) == false && store.settings.background.kind == .image, "its tile switches back with no panel")
    }

    @Test func aPictureThatFailsLeavesTheBackgroundAndSaysSo() async {
        let (model, store, _, spy) = make(imported: false)
        model.setColor("blue")
        await model.chooseImage(URL(fileURLWithPath: "/tmp/broken.jpg"))
        #expect(model.imageState == .failed)
        #expect(store.settings.background.kind == .color && store.settings.background.imageFile == nil)
        #expect(spy.announcements.last == String(localized: "Couldn’t use that image"))
    }

    @Test func removingThePictureDeletesItsCopyAndGoesBackToTheGlow() throws {
        let (model, store, _, _) = make()
        let name = "removal-test-\(UUID().uuidString).png"
        let url = try #require(StartPageFiles.imageURL(name))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
        store.setBackground(StartBackground(kind: .image, imageFile: name))
        model.removeImage()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.settings.background.kind == .spaceGlow && store.settings.background.imageFile == nil)
    }

    @Test func theAddressIsCheckedWhenCommittedAndGetsHTTPS() {
        let (model, store, _, spy) = make()
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

    @Test func resetGoesBackToTheDefaultsAtOnceAndUndoRestoresThem() {
        let (model, store, hidden, spy) = make()
        model.setStyle(.aiFirst)
        model.toggle(.frequent)
        model.setColor("pink")
        model.setNewTab(.blank)
        hidden.hide(site: "a.test")
        let changed = store.settings
        model.reset()
        #expect(store.settings == .default && model.expanded == nil)
        #expect(hidden.count == 0, "what was taken off the page is wiped, not kept for Undo")
        #expect(spy.undo != nil)
        spy.undo?.run()
        #expect(store.settings == changed)
        #expect(hidden.count == 0, "and Undo does not bring it back")
    }

    @Test func theArrowsAndTabAreTheSearchFieldsWhileSomethingIsTypedInIt() {
        for key in [KeyEquivalent.upArrow, .downArrow, .leftArrow, .rightArrow, .tab] {
            #expect(StartPageKeys.leavesToSearch(key, typing: true, inSearch: true), "\(key)")
            #expect(!StartPageKeys.leavesToSearch(key, typing: false, inSearch: true), "with nothing typed the page takes ↓ and ⇥ into its sections")
            #expect(!StartPageKeys.leavesToSearch(key, typing: true, inSearch: false), "on a section the page has the keys")
        }
        #expect(!StartPageKeys.leavesToSearch(.return, typing: true, inSearch: true))
        #expect(!StartPageKeys.leavesToSearch(.escape, typing: true, inSearch: true))
    }
}
