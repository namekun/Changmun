import AppKit
import SwiftUI

/// The page bar's controls at the top of the sidebar, as in Arc: the sidebar switch and moving around beside the
/// window buttons, and the address below them.
struct SidebarToolbar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(spacing: Metrics.inset) {
            HStack(spacing: Metrics.rowGap) {
                Spacer(minLength: 0)
                BarButton(symbol: "sidebar.left", help: String(localized: "Hide Sidebar"), label: String(localized: "Sidebar"), value: Accessibility.shownValue(browser.showSidebar)) { browser.showSidebar.toggle() }
                if let tab = browser.active { NavigationButtons(tab: tab) } else { DisabledNavigationButtons() }
            }
            .padding(.leading, browser.fullScreen ? Metrics.inset : BrowserWindow.windowButtonsTrailing)
            .padding(.trailing, Metrics.inset)
            .frame(height: BrowserWindow.pageBarHeight)
            .padding(.top, BrowserWindow.cardInset)
            .background(WindowDragArea())
            Group {
                if let tab = browser.active {
                    if prefs.addressBarOnTop {
                        AddressField(tab: tab, browser: browser).id(tab.id)
                    } else {
                        AddressPill(tab: tab, compact: true, height: 32) { browser.commandBar = .editCurrent }
                    }
                } else {
                    AddressPlaceholder { browser.openNewTab(.emptied) }
                }
            }
            .padding(.horizontal, Metrics.inset)
        }
    }
}
