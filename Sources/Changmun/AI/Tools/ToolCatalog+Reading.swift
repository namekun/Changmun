import AppKit
import WebKit

extension ToolCatalog {
    // MARK: Reading, with frames

    private struct Part {
        var title = "", url = "", origin = "", text = ""
        var scroll = 0, height = 0, viewport = 0, count = 0
        var capped = false
        var lines: [String] = []
        var frames: [(slot: String, nonce: String, src: String, title: String)] = []
    }

    private static func readPart(_ arguments: [String: Any], frame: WKFrameInfo?, in webView: WKWebView, timeout: Double) async -> Part? {
        let result = await run(PageScripts.read, arguments, in: webView, frame: frame, timeout: timeout)
        guard !result.isError, let text = result.content.first?["text"] as? String,
              let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        return Part(title: json["title"] as? String ?? "", url: json["url"] as? String ?? "", origin: json["origin"] as? String ?? "", text: json["text"] as? String ?? "",
                    scroll: int(json["scroll"]) ?? 0, height: int(json["height"]) ?? 0, viewport: int(json["viewport"]) ?? 0, count: int(json["count"]) ?? 0,
                    capped: json["capped"] as? Bool ?? false, lines: json["lines"] as? [String] ?? [],
                    frames: (json["frames"] as? [[String: Any]] ?? []).map { ($0["slot"] as? String ?? "", $0["nonce"] as? String ?? "", $0["src"] as? String ?? "", $0["title"] as? String ?? "") })
    }

    /// The site an origin names, as the approvals know sites: "" for an origin that has none (a sandboxed frame, a data: page).
    static func host(ofOrigin origin: String) -> String {
        Approvals.site(ofOrigin: origin)
    }

    static let readTimeout = 10.0, frameTimeout = 5.0, pageReadDeadline = 25.0

    /// The page as text: its elements are numbered on through the frames of the same site (read from the page) and then
    /// the frames of other sites (each read by the script run inside it), so every number works with the tools.
    @MainActor
    static func readPage(_ tab: Tab, _ webView: WKWebView, maxChars: Int, session: Session) async -> (ToolResult, frameHosts: Set<String>) {
        await tab.agent.gate.run { await readPageAlone(tab, webView, maxChars: maxChars, session: session) } ?? (stopped, [])
    }

    @MainActor
    static func readPageAlone(_ tab: Tab, _ webView: WKWebView, maxChars: Int, session: Session) async -> (ToolResult, frameHosts: Set<String>) {
        tab.agent.beginRead()
        defer { tab.agent.endRead() }
        let maxElements = 250
        let deadline = Date().addingTimeInterval(pageReadDeadline)
        guard let page = await readPart(["maxChars": maxChars, "start": 0, "limit": maxElements], frame: nil, in: webView, timeout: readTimeout) else {
            return (.text("Error: the page did not answer in time (a dialog may be open).", error: true), [])
        }
        var lines = page.lines, count = page.count, capped = page.capped, framesText = "", hosts = Set<String>()
        func readFrames(_ frames: [(slot: String, nonce: String, src: String, title: String)], depth: Int) async {
            let refs = Array(frames.prefix(8))
            for ref in refs { tab.agent.frames.expect(slot: ref.slot, nonce: ref.nonce) }
            // The frames are given their moment to answer the greeting all at once, not one after the other.
            let infos = depth < 2 && Date() < deadline && !session.stopped ? await tab.frames(named: refs.map(\.slot)) : [:]
            for ref in refs {
                // What is told of a frame that couldn't be read (its address or title, which its page chose) is cut, and its address is
                // a site the model was told of.
                let name = Approvals.shown(ref.src.isEmpty ? ref.title : ref.src, limit: 200)
                guard depth < 2, Date() < deadline, !session.stopped, let info = infos[ref.slot],
                      let part = await readPart(["maxChars": min(maxChars, 4000), "start": count, "limit": max(maxElements - count, 0)], frame: info, in: webView,
                                                timeout: min(frameTimeout, max(deadline.timeIntervalSinceNow, 1))) else {
                    framesText += "\n\n--- Frame: \(name.text)\(name.cut > 0 ? "…" : "") (from another site; its content could not be read) ---"
                    if !ref.src.isEmpty, let site = Approvals.site(of: URL(string: ref.src)), Approvals.hasSite(site) { hosts.insert(site) }
                    continue
                }
                // The site is the one the frame says it is in, from inside: where it was when it greeted may be another by now.
                let host = Self.host(ofOrigin: part.origin)
                // Whatever of a frame goes to the model (its address, a word of its text, an element) is read from its site and
                // recorded as such; a frame that showed nothing at all (a tracking pixel, an empty box) sends nothing and records nothing.
                if part.lines.isEmpty && part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await readFrames(part.frames, depth: depth + 1)
                    continue
                }
                hosts.insert(host.isEmpty ? Approvals.unknownFrame : host)
                lines += part.lines.map { $0 + " (in a frame of \(host.isEmpty ? "another site" : host))" }
                if part.count > count { tab.agent.ranges.append((count + 1...part.count, ref.slot)) }
                count = max(count, part.count)
                capped = capped || part.capped
                let address = Approvals.shown(part.url, limit: 300)
                framesText += "\n\n--- Frame: \(address.text)\(address.cut > 0 ? "…" : "") ---\n" + part.text
                await readFrames(part.frames, depth: depth + 1)
            }
        }
        await readFrames(page.frames, depth: 0)
        tab.agent.seen = AgentState.Seen(url: page.url, title: page.title, lastID: count)
        let cut = capped ? "\n(Only the first \(maxElements) elements are listed. Scroll, or use click_at for the rest.)" : ""
        return (.text("Title: \(page.title)\nURL: \(page.url)\nScroll: \(page.scroll) of \(page.height) (viewport \(page.viewport))"
                      + "\n\n--- Interactive elements ---\n" + (lines.isEmpty ? "(none)" : lines.joined(separator: "\n")) + cut
                      + "\n\n--- Page text ---\n" + page.text + framesText), hosts)
    }

    /// The frame an element number from the last read lives in: nil for the page itself or a frame of its own site.
    @MainActor
    static func frame(ofElement id: Int, in tab: Tab) async -> Result<WKFrameInfo?, ToolFailure> {
        guard let slot = tab.agent.ranges.first(where: { $0.range.contains(id) })?.slot else { return .success(nil) }
        guard let frame = await tab.frame(named: slot) else { return .failure(ToolFailure(result: unreachableFrame)) }
        return .success(frame)
    }

    /// The frames a picture shows, from the answer of the script that lists them: nil when it gave none, and `more` when there
    /// are more than the app asks about.
    static func shownFrames(from answer: String?) -> (refs: [(slot: String, nonce: String)], more: Bool)? {
        guard let answer, let list = (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [[String: String]] else { return nil }
        let first = list.prefix(maxShownFrames)
        let refs = first.compactMap { ref in ref["slot"].flatMap { slot in ref["nonce"].map { (slot, $0) } } }
        return (refs, list.count > first.count || refs.count < first.count)
    }

    static let maxShownFrames = 8

    /// The sites of the frames a picture of the page shows (also those inside frames of other sites), each asked where it
    /// really is. A frame that can't be reached or has no site, one beyond the first few, and a list that could not be had
    /// all count as an unknown frame, which is a site of its own for the approvals: the picture may show anything there.
    /// Every such frame counts, whatever it says about itself or whoever's lists it is on.
    @MainActor
    static func shownFrameHosts(_ tab: Tab, _ webView: WKWebView) async -> Set<String> {
        var hosts = Set<String>()
        func visit(_ frame: WKFrameInfo?, depth: Int) async {
            let result = await run(PageScripts.visibleFrames, [:], in: webView, frame: frame, timeout: 5)
            guard let shown = shownFrames(from: result.isError ? nil : result.content.first?["text"] as? String) else {
                hosts.insert(Approvals.unknownFrame)
                return
            }
            // Frames in frames in frames are not followed any further.
            if shown.more || (depth >= 3 && !shown.refs.isEmpty) { hosts.insert(Approvals.unknownFrame) }
            guard depth < 3 else { return }
            for ref in shown.refs { tab.agent.frames.expect(slot: ref.slot, nonce: ref.nonce) }
            let infos = await tab.frames(named: shown.refs.map(\.slot))
            for ref in shown.refs {
                var host = Approvals.unknownFrame
                if let info = infos[ref.slot] {
                    let origin = await run(PageScripts.origin, [:], in: webView, frame: info, timeout: 3)
                    if !origin.isError, let origin = origin.content.first?["text"] as? String, !Self.host(ofOrigin: origin).isEmpty { host = Self.host(ofOrigin: origin) }
                    await visit(info, depth: depth + 1)
                }
                hosts.insert(host)
            }
        }
        await visit(nil, depth: 0)
        return hosts
    }
}
