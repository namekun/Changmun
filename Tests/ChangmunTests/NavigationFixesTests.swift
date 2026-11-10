import AppKit
import Foundation
import Testing
import WebKit
@testable import Changmun

/// A click on a link as WebKit hands it to the tab's delegate, with the keys held, without a real page behind it.
private final class LinkClick: WKNavigationAction {
    var flags: NSEvent.ModifierFlags = []
    var address = "https://link.example/"
    var byUser = true
    override var navigationType: WKNavigationType { .linkActivated }
    override var request: URLRequest { URLRequest(url: URL(string: address)!) }
    override var targetFrame: WKFrameInfo? { nil }
    override var shouldPerformDownload: Bool { false }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var buttonNumber: Int { 1 }
    @objc func _isUserInitiated() -> Bool { byUser }

    static func make(_ flags: NSEvent.ModifierFlags, address: String = "https://link.example/", byUser: Bool = true) -> LinkClick {
        let action = unsafeDowncast(class_createInstance(LinkClick.self, 0) as AnyObject, to: LinkClick.self)
        action.flags = flags
        action.address = address
        action.byUser = byUser
        return action
    }
}

extension SharedAgentState {
    /// Moving around a page: reload after an error, failures and crashes said, the history menu, keys, zoom, a page's dialogs and its question
    /// about leaving, ⌥-click, dropped files, the source, and quitting with downloads running.
    @MainActor @Suite(.serialized)
    struct NavigationFixesTests {
        private func pageTab() -> (Browser, Tab, WKWebView) {
            let browser = Browser()
            let tab = browser.openTab(url: nil, activate: false)
            return (browser, tab, tab.wake())
        }

        private func answer(_ button: Int, remembered: Bool = false, fields: [String] = []) -> DialogResult {
            DialogResult(button: button, fields: fields, remembered: remembered, picked: 0)
        }

        // MARK: Reload on our page for an error

        @Test func reloadOnTheErrorPageLoadsTheAddressThatFailed() {
            let failed = URL(string: "https://down.example/page")!
            #expect(Tab.reloadAddress(failed: failed, shown: URL(string: "about:blank")) == failed, "our page has no address of its own")
            #expect(Tab.reloadAddress(failed: failed, shown: nil) == failed)
            #expect(Tab.reloadAddress(failed: nil, shown: URL(string: "about:blank")) == nil, "no error: the page reloads itself")
            #expect(Tab.reloadAddress(failed: failed, shown: URL(string: "https://other.example/")) == nil, "a real page is shown: it reloads itself")
            #expect(Tab.reloadAddress(failed: URL(string: "file:///tmp/x.html"), shown: nil) == nil, "only a web address, as the Try Again link")
        }

        @Test func aTabShowingAnErrorReloadsTheFailedAddressAndANewPageForgetsIt() {
            let (browser, tab, view) = pageTab()
            defer { browser.windowClosed() }
            let failed = URL(string: "http://127.0.0.1:9/")!
            tab.shownError = (nil, failed)
            tab.reload()
            #expect(tab.url == failed)
            view.stopLoading()
            tab.webView(view, didCommit: nil)
            #expect(tab.shownError == nil, "a page that commits takes the error away")
        }

        // MARK: Failures and crashes

        @Test func aStoppedOrReplacedLoadIsNoFailure() {
            #expect(Tab.isInterruption(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            #expect(Tab.isInterruption(domain: "WebKitErrorDomain", code: 102))
            #expect(Tab.isInterruption(domain: "WebKitErrorDomain", code: 204))
            #expect(!Tab.isInterruption(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost), "a connection lost halfway is said")
            #expect(!Tab.isInterruption(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        }

        // MARK: History menu

        @Test func theHistoryMenuStartsAtThePageOnePressAway() {
            let pages: [(title: String?, url: URL)] = [
                ("Oldest", URL(string: "https://a.example/")!), ("  ", URL(string: "https://b.example/x")!), (nil, URL(string: "data:text/plain,hi")!),
            ]
            let back = Tab.historyMenu(pages, back: true)
            #expect(back.map(\.index) == [2, 1, 0], "back: the newest first")
            #expect(back.map(\.title) == ["data:text/plain,hi", "b.example", "Oldest"], "no title: the host, else the address")
            #expect(Tab.historyMenu(pages, back: false).map(\.index) == [0, 1, 2], "forward: the next page first")
            #expect(Tab.historyMenu([], back: true).isEmpty)
        }

        // MARK: Keys

        @Test func escStopsAndCommandArrowsGoBackAndForward() {
            #expect(PageWebView.pageKey(keyCode: 53, modifiers: [], isRepeat: false) == .stop)
            #expect(PageWebView.pageKey(keyCode: 123, modifiers: [.command, .function, .numericPad], isRepeat: false) == .back)
            #expect(PageWebView.pageKey(keyCode: 124, modifiers: [.command, .function, .numericPad], isRepeat: false) == .forward)
            #expect(PageWebView.pageKey(keyCode: 123, modifiers: [.command, .shift], isRepeat: false) == nil, "⇧⌘← selects to the line's start")
            #expect(PageWebView.pageKey(keyCode: 123, modifiers: [.command, .option], isRepeat: false) == nil, "⌥⌘← is another tab")
            #expect(PageWebView.pageKey(keyCode: 123, modifiers: [], isRepeat: false) == nil)
            #expect(PageWebView.pageKey(keyCode: 53, modifiers: [.shift], isRepeat: false) == nil)
            #expect(PageWebView.pageKey(keyCode: 123, modifiers: .command, isRepeat: true) == nil, "held down, once")
        }

        // MARK: Zoom

        @Test func actualSizeUndoesAPinchAndTheSizeIsSaid() {
            let (browser, tab, view) = pageTab()
            defer { browser.windowClosed() }
            view.magnification = 2
            tab.setZoom(1.5)
            tab.resetZoom()
            #expect(view.magnification == 1)
            #expect(abs(view.pageZoom - Preferences.shared.defaultZoom) < 0.001)
            #expect(Tab.zoomLabel(1.1) == "110%")
            #expect(Tab.zoomLabel(0.3) == "30%")
        }

        // MARK: A page's dialogs

        @Test func fromTheSecondDialogThePageCanBeToldToStop() {
            #expect(Tab.pageDialogTurn(shownThisLoad: 0, refused: false, headless: false) == .ask(offerToStop: false))
            #expect(Tab.pageDialogTurn(shownThisLoad: 1, refused: false, headless: false) == .ask(offerToStop: true))
            #expect(Tab.pageDialogTurn(shownThisLoad: 5, refused: true, headless: false) == .answerQuietly)
            #expect(Tab.pageDialogTurn(shownThisLoad: 0, refused: false, headless: true) == .answerQuietly)
        }

        @Test func aPageDialogSaysWhoAsksAndKeepsThePageWordsApart() {
            let alert = Tab.pageDialogSpec(.alert, message: "Saved", site: "a.example", background: true, offerToStop: false)
            #expect(alert.title.contains("a.example") && alert.detail == .text("Saved") && alert.message == nil)
            #expect(alert.buttons.count == 1 && alert.cancelIndex == 0, "an alert closes with Esc too")
            #expect(alert.note != nil && alert.remember == nil)
            let confirm = Tab.pageDialogSpec(.confirm, message: "Sure?", site: "", background: false, offerToStop: true)
            #expect(confirm.defaultIndex == 1 && confirm.cancelIndex == 0 && confirm.note == nil && confirm.remember != nil && confirm.guarded)
            let prompt = Tab.pageDialogSpec(.prompt("Kim"), message: "Name?", site: "a.example", background: false, offerToStop: false)
            #expect(prompt.fields.map(\.text) == ["Kim"])
        }

        @Test func toldToStopThePageGetsTheSafeAnswerUntilItsNextPage() async {
            let (browser, tab, view) = pageTab()
            defer { browser.windowClosed(); Tab.pageDialogAnswerForTests = nil }
            var asked: [DialogSpec] = []
            Tab.pageDialogAnswerForTests = { asked.append($0); return DialogResult(button: 1, fields: ["x"], remembered: asked.count == 2, picked: 0) }
            #expect(await tab.askPageDialog(.confirm, message: "1", site: "a.example", in: nil)?.button == 1)
            #expect(asked.last?.remember == nil, "the first dialog has no way to stop the page")
            #expect(await tab.askPageDialog(.confirm, message: "2", site: "a.example", in: nil)?.remembered == true)
            #expect(asked.last?.remember != nil)
            #expect(await tab.askPageDialog(.alert, message: "3", site: "a.example", in: nil) == nil, "answered at once")
            #expect(asked.count == 2, "nothing more is shown")
            tab.webView(view, didCommit: nil)
            _ = await tab.askPageDialog(.alert, message: "4", site: "a.example", in: nil)
            #expect(asked.count == 3 && asked.last?.remember == nil, "the next page starts over")
        }

        @Test func withNoWindowAPageDialogGetsTheSafeAnswer() async {
            let (browser, tab, _) = pageTab()
            defer { browser.windowClosed() }
            #expect(await tab.askPageDialog(.confirm, message: "Sure?", site: "a.example", in: nil) == nil)
        }

        // MARK: Leaving a page with unsaved changes

        @Test func webKitFindsTheQuestionAboutLeaving() {
            let (browser, tab, _) = pageTab()
            defer { browser.windowClosed() }
            #expect(tab.responds(to: NSSelectorFromString("_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:")))
            let spec = Tab.leavePageSpec(background: false)
            #expect(spec.buttons[spec.defaultIndex!].title == String(localized: "Stay") && spec.cancelIndex == spec.defaultIndex, "Return and Esc stay")
        }

        @Test func theAnswerAboutLeavingGoesToWebKitExactlyOnce() async {
            let (browser, tab, view) = pageTab()
            defer { browser.windowClosed(); Tab.pageDialogAnswerForTests = nil }
            for (given, expected) in [(DialogResult?.some(answer(0)), true), (answer(1), false), (nil, false)] {
                Tab.pageDialogAnswerForTests = { _ in given }
                var answers: [Bool] = []
                tab.webViewRunBeforeUnloadConfirmPanel(view, message: "", frame: nil) { answers.append($0) }
                #expect(await waitUntil { !answers.isEmpty })
                try? await Task.sleep(for: .milliseconds(100))
                #expect(answers == [expected], "Leave leaves; Stay, or no answer, stays; once each time")
            }
        }

        // MARK: ⌥-click

        @Test func optionClickOnALinkDownloadsIt() async {
            #expect(Tab.isDownloadClick(.linkActivated, modifiers: .option, url: URL(string: "https://a.example/f.zip"), userInitiated: true))
            #expect(!Tab.isDownloadClick(.linkActivated, modifiers: [.option, .command], url: URL(string: "https://a.example/"), userInitiated: true), "⌘ opens a tab")
            #expect(!Tab.isDownloadClick(.linkActivated, modifiers: [], url: URL(string: "https://a.example/"), userInitiated: true))
            #expect(!Tab.isDownloadClick(.other, modifiers: .option, url: URL(string: "https://a.example/"), userInitiated: true))
            #expect(!Tab.isDownloadClick(.linkActivated, modifiers: .option, url: URL(string: "mailto:a@a.example"), userInitiated: true))
            #expect(!Tab.isDownloadClick(.linkActivated, modifiers: .option, url: URL(string: "https://a.example/f.zip"), userInitiated: false),
                    "a click the page's script made downloads nothing, whatever key is held")
            let (browser, tab, view) = pageTab()
            defer { browser.windowClosed() }
            #expect(await tab.webView(view, decidePolicyFor: LinkClick.make(.option), preferences: WKWebpagePreferences()).0 == .download)
            #expect(await tab.webView(view, decidePolicyFor: LinkClick.make(.option, byUser: false), preferences: WKWebpagePreferences()).0 != .download,
                    "a link the page clicked by itself is followed, not downloaded")
            #expect(await tab.webView(view, decidePolicyFor: LinkClick.make([]), preferences: WKWebpagePreferences()).0 != .download)
        }

        // MARK: Dropped files

        @Test func onlyAFileTheUserJustDroppedOpens() {
            let now = Date()
            let page = URL(fileURLWithPath: "/tmp/drop/page.html"), photo = URL(fileURLWithPath: "/tmp/drop/photo.jpg")
            let doc = URL(fileURLWithPath: "/tmp/drop/doc.pdf"), archive = URL(fileURLWithPath: "/tmp/drop/a.zip")
            let folder = URL(fileURLWithPath: "/tmp/drop/site.html", isDirectory: true)
            let dropped = [page, photo, doc, archive, folder]
            #expect(PageWebView.filesToOpen(loading: page, dropped: dropped, droppedAt: now, now: now) == [page, photo, doc], "pages, images and PDFs")
            #expect(PageWebView.filesToOpen(loading: URL(fileURLWithPath: "/etc/hosts.html"), dropped: dropped, droppedAt: now, now: now) == nil, "not a dropped file")
            #expect(PageWebView.filesToOpen(loading: page, dropped: dropped, droppedAt: now, now: now.addingTimeInterval(10)) == nil, "too long after")
            #expect(PageWebView.filesToOpen(loading: archive, dropped: dropped, droppedAt: now, now: now) == nil, "nothing that doesn't open")
        }

        @Test func aPageStillCannotLoadAFileByItself() async {
            let (browser, tab, view) = pageTab()
            defer { browser.windowClosed() }
            let action = LinkClick.make([], address: "file:///etc/hosts")
            #expect(await tab.webView(view, decidePolicyFor: action, preferences: WKWebpagePreferences()).0 == .cancel)
            #expect((view as? PageWebView)?.takeDrop(leadingTo: URL(string: "file:///etc/hosts")!) == nil)
        }

        // MARK: Page source

        @Test func theSourceIsShownAsTextNeverRun() {
            let page = Tab.sourcePage("<script>alert(1)</script>&", title: "Source of <b>")
            #expect(page.contains("&lt;script&gt;alert(1)&lt;/script&gt;&amp;"))
            #expect(!page.contains("<script>") && !page.contains("<b>"))
            #expect(page.contains("ui-monospace"))
        }

        // MARK: Quitting with downloads running

        @Test func quittingAsksOnlyWhileFilesDownloadAndKeepingIsTheDefault() throws {
            #expect(AppDelegate.quitQuestion(runningDownloads: 0) == nil)
            let one = try #require(AppDelegate.quitQuestion(runningDownloads: 1))
            let three = try #require(AppDelegate.quitQuestion(runningDownloads: 3))
            #expect(one.title != three.title && three.title.contains("3"))
            #expect(three.buttons[0].title == String(localized: "Quit"))
            #expect(three.defaultIndex == 1 && three.cancelIndex == 1, "Return and Esc keep downloading")
        }

        @Test func onlyKeepDownloadingKeepsTheAppOpen() {
            #expect(AppDelegate.quits(after: DialogResult(button: 0, fields: [], remembered: false, picked: 0)))
            #expect(!AppDelegate.quits(after: DialogResult(button: 1, fields: [], remembered: false, picked: 0)))
            #expect(AppDelegate.quits(after: nil), "a question that couldn't be shown quits, never cancels the quit silently")
        }
    }
}
