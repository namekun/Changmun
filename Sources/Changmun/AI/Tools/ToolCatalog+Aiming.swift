import AppKit
import WebKit

extension ToolCatalog {
    // MARK: Aiming

    /// Where a tool's target is and what acting on it would do: the frame to run the action in, the target in that
    /// frame's own pixels or numbers, and what the target is.
    struct Aim {
        var frame: WKFrameInfo?
        var slot: String?
        /// What was asked of the page to find it (an element number, a point, the focus, the key to be pressed).
        var args: [String: Any]
        var facts: IrreversibleAction.Facts
        var secret: Bool
        var description: String
        /// The origin of the document it is in, as that document says: "null" for a sandboxed frame or a data: page.
        var origin: String
        /// What the page showed of it, so that the action can tell it is still the same thing.
        var fingerprint: String
        /// The fingerprint keeps the digits of the names (an amount or a count that changes is another thing): what asks every time.
        var exact: Bool
        /// The site it is in, by what the document says: "" when it has none (a frame with no site). The page of the tab itself,
        /// when it has none (a file: page), is the site of its scheme.
        var host: String
        var label: String { facts.label.isEmpty ? (args["id"] as? Int).map { "[\($0)]" } ?? "" : facts.label }

        /// The arguments the script that acts looks at: where, what it must still be, and anything the action needs.
        func scriptArgs(_ extra: [String: Any] = [:]) -> [String: Any] {
            args.merging(["expect": ["origin": origin, "fp": fingerprint, "exact": exact]]) { $1 }.merging(extra) { $1 }
        }

        func script(_ extra: [String: Any] = [:]) -> [String: Any] { ["args": scriptArgs(extra)] }

        /// The same target, judged by other facts (the option a list would choose, not the list).
        func judged(as facts: IrreversibleAction.Facts) -> Aim {
            var copy = self
            copy.facts = facts
            return copy
        }
    }

    /// Finds the target (an element number, a point, or what has the focus), following a point or the focus into
    /// frames of other sites, without acting on it. `key` is the key about to be pressed on it, if any, with the modifiers held in `mods`; `typing` says the
    /// tool types the text itself, with Enter after it when `key` is Enter; `drop` says a drag ends on it.
    @MainActor
    static func aim(_ wanted: [String: Any], key: String? = nil, mods: [String: Bool]? = nil, typing: Bool = false, drop: Bool = false, tab: Tab, in webView: WKWebView, session: Session) async throws -> Aim {
        var target = wanted, frame: WKFrameInfo?, slot: String?
        if let id = target["id"] as? Int {
            switch await Self.frame(ofElement: id, in: tab) {
            case .failure(let failure): throw failure
            case .success(let found):
                frame = found
                slot = tab.agent.ranges.first { $0.range.contains(id) }?.slot
            }
        }
        for _ in 0..<5 {
            var args = target
            if let key { args["key"] = key }
            if let mods { args["mods"] = mods }
            if typing { args["typing"] = true }
            if drop { args["drop"] = true }
            let result = await run(PageScripts.inspect, ["args": args], in: webView, frame: frame)
            if result.isError { throw ToolFailure(result: result) }
            guard let text = result.content.first?["text"] as? String,
                  let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                throw ToolFailure(result: .text("Error: the page did not answer.", error: true))
            }
            if let next = json["relay"] as? String {
                tab.agent.frames.expect(slot: next, nonce: json["nonce"] as? String ?? "")
                guard let info = await tab.frame(named: next) else { throw ToolFailure(result: unreachableFrame) }
                frame = info
                slot = next
                if json["active"] as? Bool == true {
                    target = ["active": true]
                } else if let x = number(json["x"]), let y = number(json["y"]) {
                    target = ["x": x, "y": y]
                } else {
                    throw ToolFailure(result: .text("Error: the page did not answer.", error: true))
                }
                continue
            }
            var facts = IrreversibleAction.Facts(json)
            if facts.label.isEmpty, let x = target["x"] as? Double, let y = target["y"] as? Double { facts.label = "\(pixels(x)), \(pixels(y))" }
            let tabHost = Approvals.site(of: tab.url) ?? ""
            let origin = json["origin"] as? String ?? "null"
            var host = ToolCatalog.host(ofOrigin: origin)
            if host.isEmpty && frame == nil { host = tabHost }
            // What asks every time is fingerprinted with its digits (an amount, a quantity); the rest without, since a count on a
            // page changes by itself.
            let exact = IrreversibleAction.tier(of: facts) == .high
            let aim = Aim(frame: frame, slot: slot, args: args, facts: facts, secret: json["secret"] as? Bool ?? false,
                          description: json["description"] as? String ?? "", origin: origin, fingerprint: json[exact ? "fpExact" : "fp"] as? String ?? "", exact: exact, host: host)
            // The site is the one the document says it is, from inside it. What it showed of the target counts as read from
            // there; and a site other than the one the tab was approved for (a frame of another site, or the tab having gone to
            // another site since) is another site: using it from a tab the user isn't looking at is asked about for that site.
            let approvedSite = session.approved ?? tabHost
            if frame != nil || aim.host != tabHost || aim.host != approvedSite {
                let inFront = tab.browser.map { tab.id == $0.activeID && $0 === Browser.recent } ?? false
                if !aim.host.isEmpty, aim.host != approvedSite, !inFront {
                    let allowed = await Approvals.allowTab(tab, caller: session.caller, host: aim.host)
                    if session.stopped { throw ToolFailure(result: stopped) }
                    if !allowed { throw ToolFailure(result: declined) }
                }
                let read = aim.host.isEmpty ? Approvals.unknownFrame : aim.host
                Approvals.noteRead(tab, readHost: read, caller: session.caller)
            }
            return aim
        }
        throw ToolFailure(result: .text("Error: frames are nested too deeply there.", error: true))
    }

    /// The questions before the page is touched, in this order, each followed by a check that the call was not stopped
    /// while the user thought about it: the interaction itself (after reading other sites), then, for what looks like it
    /// pays, orders, sends, posts, deletes or confirms, that, every time. Throws what to answer when the answer is no.
    @MainActor
    static func approve(_ interaction: Approvals.Interaction?, aims: [Aim], irreversible: [Aim] = [], tab: Tab, session: Session) async throws {
        if session.stopped { throw ToolFailure(result: stopped) }
        if let interaction {
            let allowed = await Approvals.allowInteraction(interaction, on: tab, caller: session.caller, site: aims[0].host, mark: highlighting(aims[0], on: tab))
            if session.stopped { throw ToolFailure(result: stopped) }
            if !allowed { throw ToolFailure(result: declined) }
        }
        for aim in irreversible {
            // A form that sends what is typed in it to another site is asked about every time, whatever the button says.
            let destination = foreignDestination(of: aim)
            let tier = destination == nil ? IrreversibleAction.tier(of: aim.facts) : .high
            guard tier != .none else { continue }
            let name = IrreversibleAction.name(of: aim.facts, tier: tier)
            let markupOnly = destination == nil && IrreversibleAction.restsOnMarkup(aim.facts)
            let allowed = await Approvals.allowAction(tier, name.isEmpty ? aim.label : name, on: tab, caller: session.caller, site: aim.host, destination: destination,
                                                      markupOnly: markupOnly, mark: highlighting(aim, on: tab))
            if session.stopped { throw ToolFailure(result: stopped) }
            if !allowed { throw ToolFailure(result: declined(tier, markupOnly: markupOnly)) }
        }
    }

    /// What a question in the panel shows of its target while it waits: the AI's outline around it.
    @MainActor
    private static func highlighting(_ aim: Aim, on tab: Tab) -> Approvals.Mark? {
        guard let webView = tab.webView else { return nil }
        return Approvals.Mark(show: { _ = await run(PageScripts.highlight, aim.script(), in: webView, frame: aim.frame) },
                              clear: { webView.appScript(PageScripts.unhighlight, in: aim.frame) })
    }

    /// The site a form is sent to, when the action submits one to a site other than the one it is on.
    static func foreignDestination(of aim: Aim) -> String? {
        guard aim.facts.submits, let url = URL(string: aim.facts.action), ["http", "https"].contains(url.scheme?.lowercased()),
              let destination = Approvals.site(of: url), destination != aim.host else { return nil }
        return destination
    }

    static func said(_ result: ToolResult) -> String {
        let text = result.content.first?["text"] as? String ?? ""
        return text.hasPrefix("ok: ") ? String(text.dropFirst(4)) : text
    }

    /// Runs the script that acts, and gives a navigation it started a moment to begin and end.
    @MainActor
    static func act(_ script: String, _ arguments: [String: Any], aim: Aim, tab: Tab, webView: WKWebView, waits: Bool = true) async -> ToolResult {
        let before = webView.url
        let result = await run(script, arguments, in: webView, frame: aim.frame)
        if waits, !result.isError { await waitForLoad(tab, expectingChangeFrom: before) }
        return result
    }
}
