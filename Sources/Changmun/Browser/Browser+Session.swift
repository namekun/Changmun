import AppKit
import WebKit

extension Browser {
    // MARK: Session

    struct SavedTab: Codable {
        var url: String?
        var title: String
        /// The name the user gave the tab, which shows in place of the page's title.
        var customTitle: String?
        var state: Data?
        var bookmarkKey: String?
        var group: UUID?
        /// When it was last shown, for archiving tabs not looked at in a while.
        var shown: Date?
        /// The space it is in; sessions from before spaces have none, and their tabs go to the first space.
        var space: UUID?
        /// The tab its space showed last.
        var selected: Bool?
        /// A start tab (see Tab.isStart): written only when it is one, so sessions from before have none and read as page tabs.
        var start: Bool?
    }

    struct SavedSession: Codable {
        var tabs: [SavedTab]
        var active: Int?
        var previous: Int?
        var groups: [TabGroup]?
        /// When it was written: time with the app closed doesn't count toward archiving a tab.
        var saved: Date?
        /// The space the window was showing.
        var space: UUID?
        /// The last tabs closed in it, most recent last, for ⌘⇧T; sessions from before have none.
        var closed: [ClosedTab]?
    }

    /// How many of a window's closed tabs the session keeps.
    static let keptClosedTabs = 20

    /// The open windows, the one in front last. Older versions saved one window as a bare `SavedSession`.
    struct SavedWindows: Codable {
        var windows: [SavedSession]

        static func decode(_ data: Data) -> [SavedSession] { decodeIfValid(data) ?? [] }

        /// Nil only when the data is no session at all; an empty list is a session with nothing open.
        static func decodeIfValid(_ data: Data) -> [SavedSession]? {
            if let saved = try? JSONDecoder().decode(SavedWindows.self, from: data) { return saved.windows }
            if let single = try? JSONDecoder().decode(SavedSession.self, from: data) { return [single] }
            return nil
        }
    }

    typealias Lossy = DurableFile.Lossy

    private static var sessionFile: URL { Library.folder.appendingPathComponent("session.json") }
    /// The last session that was read back whole, kept in case the next one can't be.
    private static var previousSessionFile: URL { Library.folder.appendingPathComponent("session-previous.json") }

    var savedSession: SavedSession { savedSession(fresh: true) }

    /// `fresh` asks every open page for its back and forward list; the periodic save uses what each tab kept when
    /// its last page finished loading, so it doesn't walk every web view on the main thread.
    func savedSession(fresh: Bool) -> SavedSession {
        SavedSession(
            tabs: tabs.map { SavedTab(url: $0.url?.absoluteString, title: $0.title, customTitle: $0.customTitle, state: fresh ? $0.sessionState : $0.lastSessionState,
                                  bookmarkKey: $0.bookmarkKey, group: $0.groupID, shown: $0.lastShown, space: $0.spaceID,
                                  selected: spaceSelection[$0.spaceID] == $0.id, start: $0.isStart ? true : nil) },
            active: tabs.firstIndex { $0.id == activeID },
            previous: tabs.firstIndex { $0.id == previousActiveID },
            groups: groups,
            saved: Date(),
            space: spaceID,
            closed: isPrivate ? nil : Array(closedTabs.suffix(Self.keptClosedTabs))
        )
    }

    /// Writes the ordinary windows; with none open (the last one just closed and saved itself) it leaves the file alone.
    /// `inBackground` encodes and writes off the main thread (the periodic save); quitting writes before returning.
    static func saveSession(_ browsers: [Browser]? = nil, inBackground: Bool = false) {
        let normal = (browsers ?? all).filter { !$0.isPrivate }
        guard !normal.isEmpty else { return }
        let saved = SavedWindows(windows: normal.reversed().map { $0.savedSession(fresh: !inBackground) }.filter { !$0.tabs.isEmpty })
        let file = sessionFile
        let write = { (try? JSONEncoder().encode(saved).write(to: file, options: .atomic)) != nil }
        if inBackground {
            sessionQueue.async {
                // A write that failed (a full disk) is tried again at the next tick.
                if !write() { DispatchQueue.main.async { savedSignature = [] } }
            }
        } else {
            sessionQueue.sync { _ = write() }
        }
    }

    private static let sessionQueue = DispatchQueue(label: "Changmun.session", qos: .utility)
    private static var savedSignature: [String] = []

    /// Saves whenever the ordinary windows' tabs or addresses changed, so a crash or a forced quit loses little.
    static func saveSessionIfChanged() {
        let signature = sessionSignature()
        guard signature != savedSignature else { return }
        savedSignature = signature
        saveSession(inBackground: true)
    }

    /// What `saveSessionIfChanged` compares: the parts of the ordinary windows that the session file keeps.
    static func sessionSignature() -> [String] {
        all.filter { !$0.isPrivate }.map { browser in
            browser.tabs.map { "\($0.id) \($0.spaceID) \($0.groupID?.uuidString ?? "") \($0.bookmarkKey ?? "") \($0.url?.absoluteString ?? "") \($0.customTitle ?? "")" }.joined(separator: "|")
                + " #\(browser.activeID ?? 0) \(browser.spaceID) " + browser.groups.map { "\($0.id) \($0.isOpen) \($0.name)" }.joined(separator: "|")
                + " ~" + browser.closedTabs.suffix(keptClosedTabs).map(\.id.uuidString).joined(separator: "|")
        }
    }

    // MARK: Clearing history

    /// Clearing history forgets the tabs closed since `date`: in every window, and in the session files at once, with no window open too.
    /// `files` stands in for the session file and the copy of the one before in tests.
    static func forgetClosedTabs(since date: Date, files: [URL]? = nil, defaults: UserDefaults = .standard) {
        noteCleared(since: date, defaults: defaults)
        for browser in all { browser.removeClosedTabs(since: date) }
        forgetClosedTabs(files: files) { $0.closedAt >= date }
    }

    /// Removing a page from the history forgets the closed tabs that were on it, in the same way.
    static func forgetClosedTabs(at address: String, files: [URL]? = nil) {
        for browser in all { browser.closedTabs.removeAll { $0.url?.absoluteString == address } }
        forgetClosedTabs(files: files) { $0.url?.absoluteString == address }
    }

    /// Rewrites the session files at once without the closed tabs `forgets` picks; `files` stands in for them in tests.
    private static func forgetClosedTabs(files: [URL]?, where forgets: (ClosedTab) -> Bool) {
        if files == nil { saveSession() }
        sessionQueue.sync {
            for file in files ?? [sessionFile, previousSessionFile] { scrubClosedTabs(in: file, where: forgets) }
        }
    }

    /// Takes the closed tabs `forgets` picks out of a session file. A file that can't be read, or written back, goes: what was cleared must not
    /// come back at the next launch.
    nonisolated static func scrubClosedTabs(in file: URL, where forgets: (ClosedTab) -> Bool) {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let windows = SavedWindows.decodeIfValid(data) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let kept = windows.map { window in
            var window = window
            window.closed = window.closed?.filter { $0.closedAt < date }
            return window
        }
        guard (try? JSONEncoder().encode(SavedWindows(windows: kept)).write(to: file, options: .atomic)) != nil else {
            try? FileManager.default.removeItem(at: file)
            return
        }
    }

    private static let clearedKey = "closedTabsCleared"

    /// Notes the span of time whose closed tabs were cleared, so a session file that couldn't be scrubbed or removed still doesn't bring them back.
    static func noteCleared(since date: Date, at now: Date = Date(), defaults: UserDefaults = .standard) {
        let spans = (defaults.array(forKey: clearedKey) as? [[Double]] ?? []) + [[date.timeIntervalSinceReferenceDate, now.timeIntervalSinceReferenceDate]]
        defaults.set(Array(spans.suffix(10)), forKey: clearedKey)
    }

    /// Whether a tab closed at `date` was closed in a span whose history was cleared.
    static func wasCleared(_ date: Date, defaults: UserDefaults = .standard) -> Bool {
        let time = date.timeIntervalSinceReferenceDate
        return (defaults.array(forKey: clearedKey) as? [[Double]] ?? []).contains { $0.count == 2 && time >= $0[0] && time <= $0[1] }
    }

    /// Ordinary windows closed while others stayed open, most recent last; ⌘⇧T brings them back once no tab is left to reopen.
    static var closedWindows: [SavedSession] = []

    static func savedWindows() -> [SavedSession] {
        guard Preferences.shared.restoreTabs else { return [] }
        let read = { (file: URL) in (try? Data(contentsOf: file)).flatMap(SavedWindows.decodeIfValid)?.filter { !$0.tabs.isEmpty } }
        if let windows = read(sessionFile) {
            if !windows.isEmpty, let data = try? Data(contentsOf: sessionFile) { try? data.write(to: previousSessionFile, options: .atomic) }
            return windows
        }
        // A session that can't be read at all (damaged): the one before it, rather than an empty window.
        return read(previousSessionFile) ?? []
    }

    /// Restores a saved window asleep, apart from the tab that was shown.
    func restore(_ saved: SavedSession, defaults: UserDefaults = .standard) {
        // A tab whose bookmark was deleted since (by a crash before the next save, or another window) is a plain tab.
        let known = saved.tabs.contains { $0.bookmarkKey != nil } ? Self.libraryKeys() : nil
        for item in saved.tabs {
            let tab = Tab(id: Self.takeID(), url: item.url.flatMap(URL.init(string:)), title: item.title, state: item.state, browser: self, isStart: item.start == true)
            tab.spaceID = spaces.space(item.space).id
            tab.bookmarkKey = item.bookmarkKey.flatMap { Self.keeps($0, in: spaces.space(tab.spaceID)) && (known?.contains($0) ?? true) ? $0 : nil }
            tab.groupID = item.group
            tab.customTitle = item.customTitle
            if item.selected == true { spaceSelection[tab.spaceID] = tab.id }
            if let shown = item.shown { tab.lastShown = Date(timeIntervalSinceNow: -max(0, (saved.saved ?? shown).timeIntervalSince(shown))) }
            tabs.append(tab)
        }
        groups = saved.groups ?? []
        pruneGroups()
        if !isPrivate { closedTabs = (saved.closed ?? []).filter { !Self.wasCleared($0.closedAt, defaults: defaults) } }
        guard !tabs.isEmpty else { return }
        let shown = tabs[min(saved.active ?? 0, tabs.count - 1)]
        // The space the window was in, with the tab it showed there; a space with none shows its first tab, or is empty.
        if let space = saved.space, spaces.contains(space), !isPrivate { spaceID = space } else if !isPrivate { spaceID = shown.spaceID }
        if let start = shown.spaceID == spaceID ? shown : switchTarget(in: spaceID) {
            activate(start.id)
        } else {
            activeID = nil
            if !isPrivate { openNewTab(.emptied) }
        }
        if let previous = saved.previous, tabs.indices.contains(previous), tabs[previous].spaceID == spaceID { previousActiveID = tabs[previous].id }
    }
}

extension Browser.SavedSession {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let all = try values.decode([Browser.Lossy<Browser.SavedTab>].self, forKey: .tabs)
        tabs = all.compactMap(\.value)
        // Positions were saved among all the tabs; count only the ones that came through.
        let position = { (index: Int?) -> Int? in
            guard let index, all.indices.contains(index), all[index].value != nil else { return nil }
            return all[..<index].filter { $0.value != nil }.count
        }
        active = position((try? values.decodeIfPresent(Int.self, forKey: .active)) ?? nil)
        previous = position((try? values.decodeIfPresent(Int.self, forKey: .previous)) ?? nil)
        groups = try? values.decodeIfPresent([Browser.TabGroup].self, forKey: .groups)
        saved = try? values.decodeIfPresent(Date.self, forKey: .saved)
        space = try? values.decodeIfPresent(UUID.self, forKey: .space)
        closed = ((try? values.decodeIfPresent([Browser.Lossy<Browser.ClosedTab>].self, forKey: .closed)) ?? nil)?.compactMap(\.value)
    }
}

extension Browser.SavedWindows {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windows = try values.decode([Browser.Lossy<Browser.SavedSession>].self, forKey: .windows).compactMap(\.value)
    }
}
