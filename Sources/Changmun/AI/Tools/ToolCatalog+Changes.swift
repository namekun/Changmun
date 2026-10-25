import AppKit
import WebKit

extension ToolCatalog {
    // MARK: What an action changed

    /// Most lines of changes told after an action (a change of the focus alone takes none of them).
    static let maxChangeLines = 40
    /// How long each frame of another site is given to tell what changed in it, and how long all of them are given together.
    static let frameChangeTimeout = 1.5, framesChangeDeadline = 3.0

    /// After an action, once the page has settled: what changed in its interactive elements since the AI last saw them (its read,
    /// or the last report), with the address and title if they changed, so that it needn't read the whole page again. New elements
    /// are numbered on and work with the tools. Everything told is page content, so the sites it came from (the page's, and
    /// those of the frames that answered) are recorded as read, as a read does. Empty when the tab is not one the caller may be
    /// told about; after a navigation, only says so.
    @MainActor
    static func changes(_ tab: Tab, _ webView: WKWebView, session: Session) async -> String {
        guard Approvals.mayShow(tab, caller: session.caller), session.approved == nil || Approvals.site(of: tab.url) == session.approved else { return "" }
        return await tab.agent.gate.run { await changesAlone(tab, webView, session: session) } ?? ""
    }

    @MainActor
    private static func changesAlone(_ tab: Tab, _ webView: WKWebView, session: Session) async -> String {
        guard let seen = tab.agent.seen else {
            return tab.agent.navigated ? "\n\nWhat changed: the page navigated. Read the page (read_page) to see it and number its elements."
                : "\n\nWhat changed: not told, since this page was not read before. Read the page (read_page) to number its elements."
        }
        let page = await run(PageScripts.changes, ["args": ["start": seen.lastID, "budget": maxChangeLines, "settle": 1200]], in: webView, timeout: 8)
        guard case .answered(let json) = look(page) else {
            return "\n\nWhat changed: the page did not answer. Read the page (read_page) to see it."
        }
        if json["navigated"] as? Bool == true {
            return "\n\nWhat changed: the page navigated. Read the page (read_page) to see it and number its elements."
        }
        let url = json["url"] as? String ?? "", title = json["title"] as? String ?? ""
        Approvals.noteRead(tab, readHost: Approvals.site(of: URL(string: url)), caller: session.caller)
        var lines = (json["lines"] as? [String] ?? []), more = int(json["more"]) ?? 0, last = seen.lastID + (int(json["added"]) ?? 0)
        // The frames of other sites that the latest read reached, each numbered on after the page. They are asked all at once, each
        // given a short time and all of them a deadline; one that hangs is left alone for a while. The lines that are told are shared out
        // among them, and each starts its numbers where the ones before it end at most, so that the numbers they hand out at the same
        // time can't meet (a frame that tells fewer than its share leaves a gap in the numbers, which nothing depends on).
        let now = Date()
        let known = tab.agent.frames.known
        let asked = known.filter { now.timeIntervalSince(tab.agent.hung[$0.slot] ?? .distantPast) >= AgentState.hungFor }.prefix(maxShownFrames)
        var skipped = known.filter { now.timeIntervalSince(tab.agent.hung[$0.slot] ?? .distantPast) < AgentState.hungFor }.count
        let remaining = max(maxChangeLines - (int(json["spent"]) ?? lines.count), 0)
        var plans: [(slot: String, frame: WKFrameInfo, start: Int, budget: Int)] = []
        var next = last
        for (index, entry) in asked.enumerated() {
            let share = remaining / max(asked.count, 1) + (index < remaining % max(asked.count, 1) ? 1 : 0)
            plans.append((entry.slot, entry.frame, next, share))
            next += share
        }
        let deadline = Date().addingTimeInterval(framesChangeDeadline)
        var answers: [Int: Look] = [:]
        await withTaskGroup(of: (Int, Look).self) { group in
            for (index, plan) in plans.enumerated() {
                group.addTask { @MainActor in
                    let timeout = min(frameChangeTimeout, max(deadline.timeIntervalSinceNow, 0.3))
                    return (index, look(await run(PageScripts.changes, ["args": ["start": plan.start, "budget": plan.budget, "settle": 0]], in: webView, frame: plan.frame, timeout: timeout)))
                }
            }
            for await (index, result) in group { answers[index] = result }
        }
        for (index, plan) in plans.enumerated() {
            let result = answers[index] ?? .hung
            if result == .gone { tab.agent.frames.drop(slot: plan.slot) }
            if result == .hung {
                tab.agent.hung[plan.slot] = Date()
                skipped += 1
            }
            guard case .answered(let part) = result, part["navigated"] as? Bool != true else { continue }
            let host = host(ofOrigin: part["origin"] as? String ?? "")
            // A tab the user isn't looking at is approved for one site: what a frame of another says is not told.
            if let approved = session.approved, host != approved { continue }
            Approvals.noteRead(tab, readHost: host.isEmpty ? Approvals.unknownFrame : host, caller: session.caller)
            lines += (part["lines"] as? [String] ?? []).map { $0 + " (in a frame of \(host.isEmpty ? "another site" : host))" }
            more += int(part["more"]) ?? 0
            if let added = int(part["added"]), added > 0 {
                tab.agent.ranges.append((plan.start + 1...plan.start + added, plan.slot))
                last = max(last, plan.start + added)
            }
        }
        tab.agent.seen = AgentState.Seen(url: url, title: title, lastID: last)
        var report: [String] = []
        if url != seen.url { report.append("URL: \(Approvals.shown(seen.url, limit: 300).text) → \(Approvals.shown(url, limit: 300).text)") }
        if title != seen.title { report.append("Title: \(Approvals.shown(seen.title, limit: 120).text) → \(Approvals.shown(title, limit: 120).text)") }
        report += lines
        if more > 0 { report.append("(\(more) more changes are not listed. Read the page (read_page) for the rest.)") }
        if skipped > 0 { report.append("(\(skipped) frame\(skipped == 1 ? "" : "s") from another site did not answer in time, so changes in \(skipped == 1 ? "it are" : "them are") not listed.)") }
        if lines.isEmpty && more == 0 {
            report.append(tab.isLoading ? "No interactive element changed yet; the page is still loading — use wait_for if you expect more."
                                        : "No interactive element changed yet; the page may still be loading — use wait_for if you expect more.")
        }
        return "\n\nWhat changed (+ new, ~ changed, - gone; new elements are numbered and the numbers of your last read still work, except for those gone):\n" + report.joined(separator: "\n")
    }

    /// The progress line for an action on `aims`: with the AI's title after the app's words, unless the action asks the user every time.
    @MainActor
    static func announce(_ text: String, aims: [Aim], caller: String) {
        let asksEveryTime = aims.contains { foreignDestination(of: $0) != nil || IrreversibleAction.tier(of: $0.facts) == .high }
        AgentActivity.shared.step(text, caller: caller, titled: !asksEveryTime)
    }
}
