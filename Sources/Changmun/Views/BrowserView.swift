import AppKit
import SwiftUI
import WebKit

/// Where the page is: right of the sidebar and left of the AI panel, when they are showing. What opens over the page (the command bar,
/// the peek card) is centred in it, so it never covers the sidebar.
struct PageArea: Equatable {
    var leading: CGFloat
    var trailing: CGFloat
    /// The room between the two.
    var width: CGFloat

    static let window = PageArea(leading: 0, trailing: 0, width: 10_000)
}

struct BrowserView: View {
    @ObservedObject var browser: Browser
    @ObservedObject var chat: ChatStore
    @ObservedObject private var prefs = Preferences.shared
    /// The room the page and the AI panel share, which the panel's width is held within.
    @State private var contentWidth = 10_000.0

    var body: some View {
        // With the tabs on top there is no sidebar column: the strip runs along the top of the window, and the sidebar opens over the page.
        let tabsOnTop = prefs.tabLayout == .top
        let stripShown = tabsOnTop && !browser.focusMode
        let sidebar = browser.showSidebar && !browser.focusMode && !tabsOnTop
        let chatWidth = Preferences.aiPanelWidth(prefs.aiPanelWidth, available: contentWidth)
        let chatShown = browser.showChat && !browser.focusMode
        let area = PageArea(leading: sidebar ? prefs.sidebarWidth : 0, trailing: chatShown ? chatWidth : 0,
                            width: contentWidth - (chatShown ? chatWidth : 0))
        ZStack {
            WindowMaterial()
            if browser.focusMode { WindowDragArea() }
            HStack(spacing: 0) {
                if sidebar {
                    Sidebar(browser: browser)
                        .frame(width: prefs.sidebarWidth)
                        .background { SpaceGlass(tint: browser.space.tint).animation(Motion.standard, value: browser.space.tint) }
                        .overlay(alignment: .trailing) { SidebarResizeHandle(width: $prefs.sidebarWidth) }
                        .transition(Motion.slide(.leading))
                }
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if !browser.focusMode && !(sidebar && prefs.toolbarPlace == .sidebar) { PageBar(browser: browser) }
                        WebCard(browser: browser)
                    }
                    .background(Theme.card)
                    // The card runs to the window's edges, which clip its corners; only the sidebar, or the strip, gets a hairline.
                    .overlay(alignment: .leading) { if sidebar { Rectangle().fill(Theme.cardEdge).frame(width: 1) } }
                    .overlay(alignment: .top) { if stripShown { Rectangle().fill(Theme.cardEdge).frame(height: 1) } }
                    if browser.showChat && !browser.focusMode {
                        ChatPanel(chat: chat, browser: browser)
                            .padding(.top, BrowserWindow.cardInset)
                            .padding([.leading, .trailing, .bottom], Metrics.inset)
                            .frame(width: chatWidth)
                            .overlay(alignment: .leading) { Rectangle().fill(Theme.cardEdge).frame(width: 1) }
                            .overlay(alignment: .leading) { AIPanelResizeHandle(width: Binding(get: { chatWidth }, set: { prefs.aiPanelWidth = $0 })) }
                            .transition(Motion.slide(.trailing))
                    }
                }
                .onGeometryChange(for: Double.self) { $0.size.width } action: { contentWidth = $0 }
            }
            // The strip is laid over the window's top, which the row below leaves room for: the row itself stays as it is in either layout.
            .padding(.top, stripShown ? BrowserWindow.tabStripHeight : 0)
            if stripShown {
                TabStrip(browser: browser)
                    .background { SpaceGlass(tint: browser.space.tint).animation(Motion.standard, value: browser.space.tint) }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }
            if tabsOnTop && browser.showSidebarOverlay && !browser.focusMode {
                sidebarOverlay
            }
            if let peek = browser.peek {
                PeekCard(tab: peek, browser: browser, area: area).transition(Motion.pop(.center))
            }
            if let switcher = browser.tabSwitcher {
                TabSwitcherView(browser: browser, switcher: switcher)
            }
            if let mode = browser.commandBar, !browser.showOnboarding {
                CommandBar(browser: browser, chat: chat, area: area, mode: mode).transition(Motion.pop(.top))
            }
            if let mode = browser.spaceSheet {
                SpaceSheet(browser: browser, mode: mode).id(mode).transition(Motion.pop(.center))
            }
            if browser.showOnboarding {
                OnboardingView(browser: browser)
            }
        }
        .ignoresSafeArea()
        .environment(\.windowNumber, browser.window?.windowNumber)
        .animation(Motion.standard, value: browser.showChat)
        .animation(Motion.standard, value: browser.showSidebar)
        .animation(Motion.standard, value: browser.focusMode)
        .animation(Motion.standard, value: prefs.addressBarOnTop)
        .animation(Motion.standard, value: prefs.toolbarPlace)
        .animation(Motion.standard, value: prefs.tabLayout)
        .animation(Motion.standard, value: browser.showSidebarOverlay)
        // The overlay belongs to the strip layout only: switching back to the sidebar leaves it put away.
        .onChange(of: prefs.tabLayout) { browser.showSidebarOverlay = false }
        .animation(Motion.standard, value: browser.fullScreen)
        .animation(Motion.quick, value: browser.commandBar)
        .animation(Motion.quick, value: browser.spaceSheet)
        .animation(Motion.quick, value: browser.peek?.id)
    }

    /// The sidebar over the page, below the strip and the page bar, with the rest of the window behind a click-to-dismiss layer.
    private var sidebarOverlay: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { browser.showSidebarOverlay = false }
            Sidebar(browser: browser, overlay: true)
                .frame(width: prefs.sidebarWidth)
                .background { SpaceGlass(tint: browser.space.tint).animation(Motion.standard, value: browser.space.tint) }
                .floatingPanel(radius: Metrics.cardRadius)
                .padding(.leading, Metrics.inset)
                .padding(.bottom, Metrics.inset)
                .transition(Motion.slide(.leading))
        }
        .padding(.top, BrowserWindow.tabStripHeight + BrowserWindow.pageBarHeight)
    }
}
