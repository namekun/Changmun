import AppKit

/// What a new tab is asked for from.
enum NewTabContext: Equatable, Sendable {
    /// ⌘T, "New Tab" in the sidebar or the strip: a tab is wanted.
    case shortcut
    /// A window that has just opened (⌘N, the Dock, a launch with nothing to restore).
    case windowOpen
    /// The window or space has no tab left (the last one closed, a space with none, a session that shows none): something is wanted to look at.
    case emptied
}

/// Where a new tab goes, decided from the setting alone so that every way of asking agrees (and the matrix can be tested without a window).
enum NewTabRoute: Equatable, Sendable {
    /// An empty tab (see `Tab.isStart`) showing the start page, its search field focused.
    case startTab
    /// Today's behaviour: the command bar over whatever is there.
    case commandBar
    case blankTab
    /// A tab loading the address the user chose.
    case loadAddress(URL)
    /// No tab at all: the window or space shows the start page, its search field focused.
    case startPageNoTab

    /// `tabsInSpace` is how many tabs the space shown has now. A window or space with none shows the start page rather than making an empty tab for it;
    /// "blank" and "address" make their tab when a window opens or a tab is asked for, but a window that lost its last tab is left to the start page
    /// (closing a tab does not load a site). In a private window a custom address is ignored: the start page, with its private notice, is shown.
    static func decide(_ setting: NewTabOpens, isPrivate: Bool, addressCheck: StartAddressCheck, tabsInSpace: Int, context: NewTabContext) -> NewTabRoute {
        func startPage() -> NewTabRoute { context != .shortcut && tabsInSpace == 0 ? .startPageNoTab : .startTab }
        switch setting {
        case .commandBar:
            return .commandBar
        case .startPage:
            return startPage()
        case .blank:
            return context == .emptied && tabsInSpace == 0 ? .startPageNoTab : .blankTab
        case .address:
            guard !isPrivate, let url = addressCheck.url else { return startPage() }
            return context == .emptied && tabsInSpace == 0 ? .startPageNoTab : .loadAddress(url)
        }
    }
}

extension Browser {
    // MARK: Start page

    /// The route a new tab takes now, from the settings.
    func newTabRoute(_ context: NewTabContext) -> NewTabRoute {
        let settings = startPageStore.settings
        return NewTabRoute.decide(settings.newTab, isPrivate: isPrivate, addressCheck: StartAddressCheck.check(settings.address),
                                  tabsInSpace: spaceTabs.count, context: context)
    }

    /// The one way to ask for a new tab: ⌘T, the sidebar's and the strip's buttons, a new window, the last tab closing, an empty space.
    func openNewTab(_ context: NewTabContext = .shortcut) {
        switch newTabRoute(context) {
        case .commandBar:
            commandBar = .newTab
        case .startTab:
            // A start tab already in front is that tab: it is not piled up, the cursor just goes to its field.
            if active?.isStart == true {
                commandBar = nil
            } else {
                openStartTab()
            }
            focusStartPage()
        case .blankTab:
            openTab(url: URL(string: "about:blank"))
        case .loadAddress(let url):
            openTab(url: url)
        case .startPageNoTab:
            commandBar = nil
            focusStartPage()
        }
    }

    /// An empty tab for the start page, in the space shown, after the others (or after `after`).
    @discardableResult
    func openStartTab(activate: Bool = true, after: Tab? = nil) -> Tab {
        openTab(url: nil, activate: activate, after: after, start: true)
    }

    /// The cursor goes to the start page's search field.
    func focusStartPage() { startPageFocusRequest += 1 }

    /// Whether the page card shows the start page in place of a page: a start tab, or no tab at all where a new tab would show the start page
    /// (with the command bar as the setting, an empty window is the empty card with the bar over it, as it was).
    func showsStartPage(for tab: Tab?) -> Bool {
        if let tab { return tab.isStart }
        // Only the setting "command bar" routes to the command bar (see `NewTabRoute.decide`): the custom address needn't be checked on every redraw.
        return startPageStore.settings.newTab != .commandBar
    }

    var showsStartPage: Bool { showsStartPage(for: active) }

    /// The recent pages, closed tabs, reading list and frequent sites are history: a private window keeps none, so it never reads them either.
    var startPageMayShowHistory: Bool { !isPrivate }

    /// ⌘L: on a start tab (or an empty window that shows the start page) the field of the start page is the address entry; on a page it is the address bar.
    func openLocation() {
        if showsStartPage {
            commandBar = nil
            focusStartPage()
        } else if active == nil {
            commandBar = .newTab
        } else if Preferences.shared.addressBarOnTop && !focusMode {
            addressFocusRequest += 1
        } else {
            commandBar = .editCurrent
        }
    }
}
