import AppKit
import WebKit

extension Browser {
    // MARK: Find in page

    func showFindBar() {
        guard let active, !active.isStart else { return }
        findBarVisible = true
        overlay.findFocusRequest += 1
        // Text selected in the page is what ⌘F looks for.
        let current = findText
        active.webView?.callAsyncJavaScript("""
            const el = document.activeElement;
            if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') && el.type !== 'password' && el.selectionEnd > el.selectionStart) {
                return el.value.slice(el.selectionStart, el.selectionEnd);
            }
            return window.getSelection().toString();
            """, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.findText == current, self.findBarVisible,
                  let text = Self.findPrefill(selection: (try? result.get()) as? String, current: current) else { return }
            self.findText = text
        }
    }

    /// Closing keeps what was found selected in the page, and the keyboard goes back to the page, so ⌘C copies it.
    func hideFindBar(refocusPage: Bool = false) {
        findBarVisible = false
        findMatches = nil
        if refocusPage, let page = active?.webView, let window = page.window { window.makeFirstResponder(page) }
    }

    /// The text ⌘F starts from: the first line of what is selected in the page, nothing when it is blank or already what is searched for.
    static func findPrefill(selection: String?, current: String) -> String? {
        guard let line = selection?.split(whereSeparator: \.isNewline).first.map({ String($0).trimmingCharacters(in: .whitespaces) }),
              !line.isEmpty else { return nil }
        let text = String(line.prefix(200))
        return text.caseInsensitiveCompare(current) == .orderedSame ? nil : text
    }

    /// How many matches to show: none when WebKit found none, never none when it did; nothing when the count could not be taken.
    static func findCount(matchFound: Bool, scanned: Int?) -> Int? {
        guard matchFound else { return 0 }
        return scanned.map { max($0, 1) }
    }

    func find(backwards: Bool = false) {
        guard let webView = active?.webView, !findText.isEmpty else {
            findMatches = nil
            return
        }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        let query = findText
        webView.find(query, configuration: config) { [weak self] found in
            guard let self, self.findText == query else { return }
            guard found.matchFound else { return self.findMatches = Self.findCount(matchFound: false, scanned: nil) }
            webView.callAsyncJavaScript("""
                const text = document.body ? document.body.innerText.toLowerCase() : '';
                const needle = query.toLowerCase();
                let count = 0, at = text.indexOf(needle);
                while (at !== -1 && count < 9999) { count++; at = text.indexOf(needle, at + needle.length); }
                return count;
                """, arguments: ["query": query], in: nil, in: .defaultClient) { [weak self] result in
                guard let self, self.findText == query else { return }
                self.findMatches = Self.findCount(matchFound: true, scanned: (try? result.get()) as? Int)
            }
        }
    }
}
