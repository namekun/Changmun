import AppKit
import Foundation
import Testing
import WebKit
@testable import Changmun

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The Help menu, and the Keyboard Shortcuts list that is read from the menu so it cannot say anything the menu does not.
@MainActor
struct HelpMenuTests {
    private let base = "https://github.com/namekun/Changmun/blob/main/"

    @Test func theGuideIsOpenedInTheLanguageTheAppIsShownIn() {
        #expect(ShortcutList.guideURL(localizations: ["ko"]).absoluteString == base + "GUIDE.ko.md")
        #expect(ShortcutList.guideURL(localizations: ["zh-Hans"]).absoluteString == base + "GUIDE.zh-Hans.md")
        #expect(ShortcutList.guideURL(localizations: ["zh-Hans-CN", "en"]).absoluteString == base + "GUIDE.zh-Hans.md")
        #expect(ShortcutList.guideURL(localizations: ["fr-CA"]).absoluteString == base + "GUIDE.fr.md")
        #expect(ShortcutList.guideURL(localizations: ["en"]).absoluteString == base + "GUIDE.md")
        #expect(ShortcutList.guideURL(localizations: ["en", "ko"]).absoluteString == base + "GUIDE.md", "the first language wins, and English is the guide itself")
        #expect(ShortcutList.guideURL(localizations: ["tr", "de"]).absoluteString == base + "GUIDE.de.md", "the first one the guide has been translated to")
        #expect(ShortcutList.guideURL(localizations: []).absoluteString == base + "GUIDE.md")
    }

    @Test func everyGuideTheLinkCanPickIsInTheRepositoryAndNoneIsLeftOut() throws {
        for code in ShortcutList.guideLanguages {
            #expect(FileManager.default.fileExists(atPath: repository.appendingPathComponent("GUIDE.\(code).md").path), "GUIDE.\(code).md")
        }
        let translated = try FileManager.default.contentsOfDirectory(atPath: repository.path)
            .filter { $0.hasPrefix("GUIDE.") && $0 != "GUIDE.md" }
            .map { String($0.dropFirst("GUIDE.".count).dropLast(".md".count)) }
        #expect(Set(translated) == Set(ShortcutList.guideLanguages), "a new translation of the guide is linked to")
    }

    @Test func theMenuHasAHelpMenuAtItsEnd() throws {
        for scheme in ShortcutScheme.allCases {
            let menu = AppMenu.make(scheme: scheme)
            let help = try #require(menu.items.last?.submenu)
            #expect(help.title == String(localized: "Help"))
            #expect(help.items.map(\.action) == [#selector(AppDelegate.openGuide(_:)), #selector(AppDelegate.showShortcuts(_:))])
            #expect(ShortcutList.keys(of: help.items[1]) == "⌘/")
        }
    }

    @Test func theFavoritesKeyIsCalledFavorites() {
        let item = AppMenu.make(scheme: .safari).items.flatMap { $0.submenu?.items ?? [] }.first { $0.action == #selector(AppDelegate.toggleBookmark(_:)) }
        #expect(item?.title == String(localized: "Add/Remove Favorite"))
    }

    @Test func everyKeyOfTheMenuIsInTheList() {
        for scheme in ShortcutScheme.allCases {
            let menu = AppMenu.make(scheme: scheme)
            let rows = ShortcutList.groups(in: menu).flatMap(\.rows)
            for item in menu.items.flatMap({ $0.submenu?.items ?? [] }) where !item.keyEquivalent.isEmpty {
                let keys = ShortcutList.keys(of: item) ?? ""
                if [#selector(AppDelegate.selectNumberedTab(_:)), #selector(AppDelegate.selectNumberedSpace(_:))].contains(item.action) { continue }
                #expect(rows.contains { $0.title == item.title && $0.keys.contains(keys) }, "\(scheme): \(item.title) \(keys)")
            }
        }
    }

    @Test func theNumberedTabsAndSpacesAreOneRowEach() {
        let rows = ShortcutList.groups(in: AppMenu.make(scheme: .safari)).flatMap(\.rows)
        #expect(rows.first { $0.title == String(localized: "Go to Tab 1–9") }?.keys == "⌘1–9")
        #expect(rows.first { $0.title == String(localized: "Go to Space 1–9") }?.keys == "⌃1–9")
        #expect(!rows.contains { $0.title == "Tab 3" || $0.title == "Space 3" })
    }

    @Test func theListShowsTheKeysOfTheSchemeInUse() {
        func keys(_ title: String, _ scheme: ShortcutScheme) -> String? {
            ShortcutList.groups(in: AppMenu.make(scheme: scheme)).flatMap(\.rows).first { $0.title == String(localized: LocalizedStringResource(stringLiteral: title)) }?.keys
        }
        #expect(keys("Sidebar", .safari) == "⇧⌘L" && keys("Sidebar", .chrome) == "⌘S")
        #expect(keys("Hard Reload", .safari) == "⌥⌘R" && keys("Hard Reload", .chrome) == "⇧⌘R")
        #expect(keys("Next Tab", .safari) == "⇧⌘]", "one key in Safari's scheme")
        #expect(keys("Next Tab", .chrome) == "⇧⌘] · ⌥⌘→", "both of Chrome's, as one row")
        #expect(keys("Web Inspector (Network)", .safari) == "F12 · ⌥⌘I")
        #expect(keys("Recent Tab", .safari) == "⌃⇥ · ⌃⇧⇥")
    }

    @Test func theGesturesNobodyCanFindAreInTheTable() {
        let rows = ShortcutList.gestures
        #expect(rows.count == 7 && rows.allSatisfy { !$0.title.isEmpty && !$0.keys.isEmpty })
        #expect(rows.map(\.keys).contains(String(localized: "⌘Return in the search field")))
        #expect(rows.map(\.keys).contains(String(localized: "Mouse side buttons")))
    }
}

/// The search in Settings knows every setting of every pane, and a pane that gains one the search does not know fails this.
@MainActor
struct SettingsSearchTests {
    private let sources = repository.appendingPathComponent("Sources/Changmun")

    /// The files that draw each pane.
    private func files(_ page: SettingsPage) -> [String] {
        switch page {
        case .general: ["Settings/GeneralSettings.swift", "Settings/CustomSearchEnginesSettings.swift"]
        case .appearance: ["Settings/AppearanceSettings.swift"]
        case .tabs: ["Settings/TabSettings.swift"]
        case .startPage: ["StartPage/StartPageSettingsView.swift", "StartPage/StartPageControls.swift"]
        case .privacy: ["Settings/PrivacySettings.swift"]
        case .extensions: ["Settings/ExtensionSettings.swift"]
        case .ai: ["Settings/AISettings.swift"]
        case .advanced: ["Settings/AdvancedSettings.swift", "Settings/NotificationSettings.swift"]
        }
    }

    /// What a pane writes as the label of a control or a section, as a literal. Not settings: a sheet's own search field, the examples shown in empty fields,
    /// and the fields of the form that adds a search engine.
    private static let notSettings: Set<String> = ["Search", "https://example.com", "e.g. music.youtube.com", "Name", "Keyword", "Address"]
    private static let kinds = #"(Toggle|Picker|LabeledContent|Section|TextField)"#

    private func labels(of page: SettingsPage) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: Self.kinds + #"\("([^"]+)""#)
        var found = Set<String>()
        for file in files(page) {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let kind = (text as NSString).substring(with: match.range(at: 1)), label = (text as NSString).substring(with: match.range(at: 2))
                // Only an empty field's example or a sheet's own search field is no setting; a section may well be called "Search".
                if kind == "TextField", Self.notSettings.contains(label) { continue }
                found.insert(label)
            }
        }
        return found
    }

    @Test func everyLabelOfEveryPaneIsKnownToTheSearch() throws {
        for page in SettingsPage.allCases {
            let known = Set(page.settings.map(\.key))
            let missing = try labels(of: page).subtracting(known)
            #expect(missing.isEmpty, "\(page.rawValue): the search does not know \(missing.sorted())")
        }
    }

    @Test func theSearchKnowsNothingThatIsNoLongerInItsPane() throws {
        for page in SettingsPage.allCases {
            let stale = Set(page.settings.map(\.key)).subtracting(try labels(of: page))
            #expect(stale.isEmpty, "\(page.rawValue): no longer in the pane: \(stale.sorted())")
        }
    }

    @Test func everySettingIsFoundByItsEnglishLabelAndByItsOwnLanguage() {
        for page in SettingsPage.allCases {
            for label in page.settings {
                #expect(page.matches(label.key), "\(page.rawValue): \(label.key)")
                #expect(page.matches(String(localized: label)), "\(page.rawValue): \(String(localized: label))")
            }
        }
    }

    @Test func theSettingsTheSearchUsedToMissAreFound() {
        #expect(SettingsPage.general.matches("translate"))
        #expect(SettingsPage.general.matches("quit when"))
        #expect(SettingsPage.ai.matches("approvals") && SettingsPage.ai.matches("effort") && SettingsPage.ai.matches("keep chat"))
        #expect(SettingsPage.privacy.matches("touch id") && SettingsPage.privacy.matches("tracking") && SettingsPage.privacy.matches("secure connections"))
        #expect(SettingsPage.privacy.matches("stay signed in"))
        #expect(!SettingsPage.appearance.matches("translate"))
    }
}

/// The Korean (and every other) table calls Tidy Tabs and the archive section by different names.
struct TabArchiveNameTests {
    @Test func theArchiveSectionIsNotCalledWhatTidyTabsIsCalled() throws {
        for language in ["ko", "ja", "zh-Hans", "es", "de", "fr"] {
            let table = repository.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
            let strings = try #require(NSDictionary(contentsOf: table) as? [String: String])
            #expect(strings["Tab Archive"] != nil && strings["Tidy Tabs"] != nil)
            #expect(strings["Tab Archive"] != strings["Tidy Tabs"], "\(language): one name for two things")
        }
    }
}

/// What Settings asks before it clears history or starts over, and what the extension prompt and the update note say.
@MainActor
struct SettingsWordsTests {
    @Test func clearHistorySaysWhatGoesForTheRangeChosen() {
        let all = PrivacySettings.clearQuestion(history: true, siteData: false, range: .all)
        #expect(all.message?.contains(String(localized: "the zoom level you set for each site")) == true)
        let hour = PrivacySettings.clearQuestion(history: true, siteData: false, range: .hour)
        #expect(hour.message?.contains(String(localized: "Zoom levels you set for sites stay.")) == true, "zoom carries no date: only All Time clears it")
        #expect(hour.title.contains(PrivacySettings.Range.hour.name))
        let both = PrivacySettings.clearQuestion(history: true, siteData: true, range: .today)
        #expect(both.message?.contains(String(localized: "Site data such as cookies and cache is removed too, which signs you out of sites.")) == true)
        let data = PrivacySettings.clearQuestion(history: false, siteData: true, range: .today)
        #expect(data.message?.contains(String(localized: "This removes the pages you visited, closed tabs and windows, and archived tabs from that time. Zoom levels you set for sites stay.")) == false)
    }

    @Test func clearingIsNeverWhatReturnPresses() {
        let spec = PrivacySettings.clearQuestion(history: true, siteData: true, range: .all)
        #expect(spec.buttons.map(\.role) == [.cancel, .destructive])
        #expect(spec.button(for: .return) == 0 && spec.button(for: .escape) == 0)
    }

    @Test func startingANewChatAsksOnlyWhileAReplyIsRunning() throws {
        #expect(AISettings.newChatQuestion(running: false) == nil)
        let spec = try #require(AISettings.newChatQuestion(running: true))
        #expect(spec.buttons.map(\.role) == [.cancel, .normal])
        #expect(spec.button(for: .return) == 0, "the safe answer is the one Return gives")
    }

    @Test func theAutomaticInstallSaysWhyItIsGreyed() {
        #expect(Updates.automaticInstallNote(available: true, checks: true) == nil)
        #expect(Updates.automaticInstallNote(available: true, checks: false) == String(localized: "Turn on “Check for updates automatically” to allow this."))
        #expect(Updates.automaticInstallNote(available: false, checks: false) == String(localized: "Updates are not available in this copy of Changmun."))
        #expect(Updates.automaticInstallNote(available: false, checks: true) == String(localized: "Updates are not available in this copy of Changmun."))
    }
}

/// Focus mode's way out: a button at the top edge that stays for as long as the pointer is over its room.
struct FocusModeExitTests {
    @Test func theRoomTheButtonKeepsIsBiggerThanTheStripThatWakesItAndHoldsTheButton() {
        #expect(FocusModeExit.zoneHeight(near: true) > FocusModeExit.zoneHeight(near: false))
        #expect(FocusModeExit.zoneHeight(near: true) >= 8 + ButtonSize.regular.height, "the pointer is still over the room when it is on the button")
    }
}
