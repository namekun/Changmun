import SwiftUI

/// What can be taken back now: the last tidying and the last notice, one under the other, so one never hides the other.
struct UndoNotices: View {
    @ObservedObject var browser: Browser

    var body: some View {
        VStack(spacing: Metrics.rowGap) {
            if let tidy = browser.lastTidy {
                UndoNotice(message: tidy.message) { browser.undoTidy() }.transition(.opacity)
            }
            if let notice = browser.notice {
                UndoNotice(message: notice.message) { browser.undoNotice() }.transition(.opacity)
            }
        }
        .animation(Motion.standard, value: browser.lastTidy)
        .animation(Motion.standard, value: browser.notice)
    }
}

/// The same notices over the bottom of the page while the sidebar is hidden, for as long as they last there.
struct PageUndoNotice: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Group {
            if Browser.undoOnPage(sidebarShown: browser.showSidebar, focusMode: browser.focusMode), browser.lastTidy != nil || browser.notice != nil {
                UndoNotices(browser: browser)
                    .frame(width: 320)
                    .padding(.horizontal, 4)
                    .floatingPanel(radius: Metrics.fieldRadius)
                    .padding(Metrics.inset)
                    .transition(.opacity)
            }
        }
        .animation(Motion.standard, value: browser.notice == nil && browser.lastTidy == nil)
    }
}

extension Browser {
    /// Where an Undo shows: in the sidebar while it is there, else over the page; focus mode shows no notices.
    nonisolated static func undoOnPage(sidebarShown: Bool, focusMode: Bool) -> Bool { !sidebarShown && !focusMode }
}
