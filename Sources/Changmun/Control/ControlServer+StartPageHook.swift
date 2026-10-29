import Foundation
import Network

extension ControlServer {
    /// Tests only: where new tabs go and what the start page is doing, on the front window (the private one if that is in front).
    /// Settings: "newTab" (startPage, commandBar, blank, address), "address", "reset" (the defaults again). Actions, run in this order:
    /// "window" (new or private: a window opens as ⌘N and ⇧⌘N do), "newTab" ("action": "newTab" is ⌘T), "action" (newTab, openLocation, closeActive, closeAll),
    /// "type" (what the start page's search field does with typed text: it opens in the tab in front), "seed" ({"history": [[url, title]], "closed":
    /// [[url, title]]}: what the start page's sections would show, so a test can look for it where it must never be). The answer says how things stand.
    func handleStartPageTestRequest(_ request: HTTPRequest, on connection: NWConnection) -> Bool {
        guard Headless.isTestCopy, request.method == "POST", request.path == "/start-page",
              let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return false }
        Task { @MainActor in
            let store = StartPageStore.shared
            if body["reset"] as? Bool == true { store.reset() }
            if let name = body["newTab"] as? String, let opens = NewTabOpens(rawValue: name) { store.setNewTab(opens) }
            if let address = body["address"] as? String { store.setAddress(address) }
            switch body["window"] as? String {
            case "new": BrowserWindow.open().openNewTab(.windowOpen)
            case "private": BrowserWindow.open(private: true).openNewTab(.windowOpen)
            default: break
            }
            guard let browser = Browser.current else { return self.respond(connection, status: "404 Not Found", body: ["error": "no window"]) }
            if let seed = body["seed"] as? [String: Any] {
                for page in seed["history"] as? [[String]] ?? [] where page.count == 2 { Library.shared.recordVisit(url: page[0], title: page[1]) }
                for page in seed["closed"] as? [[String]] ?? [] where page.count == 2 {
                    browser.closedTabs.append(Browser.ClosedTab(url: URL(string: page[0]), title: page[1], index: 0, space: browser.spaceID))
                }
            }
            switch body["action"] as? String {
            case "newTab": browser.openNewTab()
            case "openLocation": browser.openLocation()
            case "closeActive": if let id = browser.activeID { browser.close(id) }
            case "closeAll": for tab in browser.tabs { browser.close(tab.id) }
            default: break
            }
            if let text = body["type"] as? String { browser.open(text, in: .editCurrent) }
            try? await Task.sleep(for: .milliseconds(body["wait"] as? Int ?? 300))
            let active = browser.active
            self.respond(connection, status: "200 OK", body: [
                "showsStartPage": browser.showsStartPage, "activeTabIsStart": active?.isStart == true, "activeID": browser.activeID ?? -1,
                "focusRequests": browser.startPageFocusRequest, "commandBar": browser.commandBar.map { "\($0)" } ?? "none",
                "private": browser.isPrivate, "mayShowHistory": browser.startPageMayShowHistory, "windows": Browser.all.count,
                "newTab": store.settings.newTab.rawValue, "closedTabs": browser.closedTabs.count, "hasWebView": active?.webView != nil,
                "tabs": browser.spaceTabs.map { ["id": $0.id, "isStart": $0.isStart, "url": $0.url?.absoluteString ?? "", "title": $0.displayTitle] as [String: Any] },
            ])
        }
        return true
    }
}
