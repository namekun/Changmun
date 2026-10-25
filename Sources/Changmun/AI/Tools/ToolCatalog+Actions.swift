import AppKit
import WebKit

extension ToolCatalog {
    // MARK: Tools

    @MainActor
    static func clickElement(_ id: Int, tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        do {
            let aim = try await Self.aim(["id": id], tab: tab, in: webView, session: session)
            let step = String(localized: "Clicking “\(aim.label)”")
            announce(step, aims: [aim], caller: session.caller)
            try await approve(.act(step), aims: [aim], irreversible: [aim], tab: tab, session: session)
            let result = await act(PageScripts.click, aim.script(), aim: aim, tab: tab, webView: webView)
            if result.isError { return result }
            return .text("Clicked [\(id)]. \(now(tab, caller: session.caller))." + (await changes(tab, webView, session: session)))
        } catch let failure as ToolFailure {
            return failure.result
        } catch {
            return .text("Error: \(error.localizedDescription)", error: true)
        }
    }

    @MainActor
    static func clickAt(_ args: [String: Any], tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        guard let x = number(args["x"]), let y = number(args["y"]) else { return .text("x and y are required.", error: true) }
        do {
            let aim = try await Self.aim(["x": x, "y": y], tab: tab, in: webView, session: session)
            let step = String(localized: "Clicking at \(pixels(x)), \(pixels(y))")
            announce(step, aims: [aim], caller: session.caller)
            try await approve(.act(step), aims: [aim], irreversible: [aim], tab: tab, session: session)
            let result = await act(PageScripts.clickAt, aim.script(), aim: aim, tab: tab, webView: webView)
            if result.isError { return result }
            return .text("Clicked at (\(pixels(x)), \(pixels(y))), which was \(aim.description). \(now(tab, caller: session.caller))." + (await changes(tab, webView, session: session)))
        } catch let failure as ToolFailure {
            return failure.result
        } catch {
            return .text("Error: \(error.localizedDescription)", error: true)
        }
    }

    @MainActor
    static func typeText(_ id: Int, text: String, submit: Bool, tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        do {
            let aim = try await Self.aim(["id": id], key: submit ? "Enter" : nil, typing: submit, tab: tab, in: webView, session: session)
            if aim.secret { return .text("Error: Changmun does not let the AI type into password fields. Ask the user to.", error: true) }
            announce(String(localized: "Typing into “\(aim.label)”"), aims: submit ? [aim] : [], caller: session.caller)
            try await approve(.type(text), aims: [aim], irreversible: submit ? [aim] : [], tab: tab, session: session)
            let result = await act(PageScripts.type, aim.script(["text": text, "submit": submit]), aim: aim, tab: tab, webView: webView)
            if result.isError { return result }
            return .text("Typed into [\(id)]\(submit ? " and pressed Enter" : ""). \(now(tab, caller: session.caller))" + (await changes(tab, webView, session: session)))
        } catch let failure as ToolFailure {
            return failure.result
        } catch {
            return .text("Error: \(error.localizedDescription)", error: true)
        }
    }

    @MainActor
    static func pressKey(_ args: [String: Any], tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        guard let key = AgentKey.name(args["key"]), let modifiers = AgentKey.modifiers(args["modifiers"]) else { return .text("Invalid key.", error: true) }
        let wanted: [String: Any] = int(args["element_id"]).map { ["id": $0] } ?? ["active": true]
        do {
            let aim = try await Self.aim(wanted, key: key, mods: modifiers, tab: tab, in: webView, session: session)
            if aim.secret { return .text("Error: Changmun does not let the AI press keys in password fields. Ask the user to.", error: true) }
            let step = String(localized: "Pressing \(key)")
            announce(step, aims: [aim], caller: session.caller)
            // Enter or Space on a button or in a form does what a click does, and Enter in a message box sends it.
            try await approve(.act(step), aims: [aim], irreversible: [aim], tab: tab, session: session)
            let result = await act(PageScripts.pressKey, aim.script(["mods": modifiers]), aim: aim, tab: tab, webView: webView)
            if result.isError { return result }
            return .text("Pressed \(key) on \(aim.description): \(said(result)). \(now(tab, caller: session.caller))." + (await changes(tab, webView, session: session)))
        } catch let failure as ToolFailure {
            return failure.result
        } catch {
            return .text("Error: \(error.localizedDescription)", error: true)
        }
    }

    /// Choosing an option, in steps: the page says which option the words name (a list that is closed is opened first, which
    /// is a click, and asked about as one), that option is judged by what it says, and it is chosen only if still the same.
    @MainActor
    static func selectOption(_ args: [String: Any], tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        guard let id = int(args["element_id"]), let option = args["option"] as? String else { return .text("element_id and option are required.", error: true) }
        do {
            let aim = try await Self.aim(["id": id], tab: tab, in: webView, session: session)
            if aim.secret { return .text("Error: Changmun does not let the AI use password fields. Ask the user to.", error: true) }
            AgentActivity.shared.step(String(localized: "Choosing “\(option)”"), caller: session.caller)
            // The option is the AI's own text, picked from a list the page wrote, and a page can write a list to read it back from.
            try await approve(.choose(option), aims: [aim], tab: tab, session: session)

            func ask(_ stage: String, open: Bool = false, expect: String? = nil, exact: Bool = false) async -> ToolResult {
                var extra: [String: Any] = ["stage": stage, "option": option, "open": open, "expectExact": exact]
                if let expect { extra["expectFp"] = expect }
                return await act(PageScripts.selectOption, aim.script(extra), aim: aim, tab: tab, webView: webView, waits: stage == "choose")
            }
            func answer(_ result: ToolResult) -> [String: Any]? {
                (result.content.first?["text"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            }
            var resolved = await ask("resolve")
            if resolved.isError { return resolved }
            if answer(resolved)?["needsOpen"] as? Bool == true {
                // Opening the list is a click on it (the use of the page was approved with the choice).
                try await approve(nil, aims: [aim], irreversible: [aim], tab: tab, session: session)
                resolved = await ask("resolve", open: true)
                if resolved.isError { return resolved }
            }
            guard let chosen = answer(resolved), chosen["label"] is String, let fingerprint = chosen["fp"] as? String, let exactFingerprint = chosen["fpExact"] as? String else {
                return .text("Error: the page did not answer.", error: true)
            }
            // An option that asks every time is fingerprinted with its digits (a quantity, an amount).
            let optionFacts = IrreversibleAction.Facts(chosen)
            let exact = IrreversibleAction.tier(of: optionFacts) == .high
            // A menu item named "Delete" is a button by another name, and so is the option of a list that acts when it changes
            // (a native list that submits its form takes the form's card details and address along). It is judged by every
            // name its markup gives it, and chosen only if it is still that very option.
            // What the option does decides how the step is told, as for a click.
            announce(String(localized: "Choosing “\(option)”"), aims: [aim.judged(as: optionFacts)], caller: session.caller)
            try await approve(nil, aims: [aim], irreversible: [aim.judged(as: optionFacts)], tab: tab, session: session)
            let result = await ask("choose", expect: exact ? exactFingerprint : fingerprint, exact: exact)
            if result.isError { return result }
            return .text("Selected in [\(id)]: \(said(result)). \(now(tab, caller: session.caller))." + (await changes(tab, webView, session: session)))
        } catch let failure as ToolFailure {
            return failure.result
        } catch {
            return .text("Error: \(error.localizedDescription)", error: true)
        }
    }

    @MainActor
    static func hover(_ id: Int, tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        do {
            let aim = try await Self.aim(["id": id], tab: tab, in: webView, session: session)
            let step = String(localized: "Pointing at “\(aim.label)”")
            AgentActivity.shared.step(step, caller: session.caller)
            try await approve(.act(step), aims: [aim], tab: tab, session: session)
            let result = await act(PageScripts.hover, aim.script(), aim: aim, tab: tab, webView: webView)
            if result.isError { return result }
            return .text("Moved the pointer over [\(id)]. \(now(tab, caller: session.caller))." + (await changes(tab, webView, session: session)))
        } catch let failure as ToolFailure {
            return failure.result
        } catch {
            return .text("Error: \(error.localizedDescription)", error: true)
        }
    }

    @MainActor
    static func drag(_ args: [String: Any], tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        func wanted(_ prefix: String) -> [String: Any]? {
            if let id = int(args[prefix + "element_id"]) { return ["id": id] }
            guard let x = number(args[prefix + "x"]), let y = number(args[prefix + "y"]) else { return nil }
            return ["x": x, "y": y]
        }
        guard let fromTarget = wanted("from_"), let toTarget = wanted("to_") else { return .text("Say where to drag from and where to drop.", error: true) }
        do {
            let from = try await Self.aim(fromTarget, tab: tab, in: webView, session: session)
            let to = try await Self.aim(toTarget, drop: true, tab: tab, in: webView, session: session)
            if from.secret || to.secret { return .text("Error: Changmun does not let the AI use password fields. Ask the user to.", error: true) }
            guard from.slot == to.slot else { return .text("Error: dragging from one frame to another isn't supported.", error: true) }
            let step = String(localized: "Dragging “\(from.label)” to “\(to.label)”")
            announce(step, aims: [from, to], caller: session.caller)
            // Dropping something on a control named "Delete" or "Send" does what pressing it would, and dragging a control
            // named so drops it into something.
            try await approve(.act(step), aims: [from], irreversible: [from, to], tab: tab, session: session)
            let result = await act(PageScripts.drag, ["args": ["from": from.scriptArgs(), "to": to.scriptArgs()]], aim: from, tab: tab, webView: webView)
            if result.isError { return result }
            return .text("Dragged \(from.description) to \(to.description): \(said(result)). \(now(tab, caller: session.caller))." + (await changes(tab, webView, session: session)))
        } catch let failure as ToolFailure {
            return failure.result
        } catch {
            return .text("Error: \(error.localizedDescription)", error: true)
        }
    }

    /// Waits until the text is on the page (or is gone), or until the page has loaded when no text is given. The stop
    /// button ends it at once. A look at the page that gets no answer says nothing: the wait goes on.
    @MainActor
    static func waitFor(_ args: [String: Any], tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        let timeout = min(max(number(args["timeout"]) ?? 10, 1), 30)
        let text = args["text"] as? String, gone = args["gone"] as? Bool ?? false
        if let text {
            AgentActivity.shared.step(gone ? String(localized: "Waiting for “\(text)” to go away") : String(localized: "Waiting for “\(text)”"), caller: session.caller)
        } else {
            AgentActivity.shared.step(String(localized: "Waiting for the page to load"), caller: session.caller)
        }
        let started = Date()
        // No look at the page ever got an answer: the last one may have been cut short by the end of the wait.
        var unknown = true
        var unreachable: [String: Date] = [:]
        func seconds() -> String { String(format: "%.1f", Date().timeIntervalSince(started)) }
        // A page that has just been told to load hasn't started yet.
        try? await Task.sleep(for: .milliseconds(250))
        var pause = 250
        while true {
            if session.stopped || Task.isCancelled { return stopped }
            if let text {
                let has = await pageHas(text, tab: tab, webView: webView, caller: session.caller, until: started.addingTimeInterval(timeout), unreachable: &unreachable)
                if session.stopped || Task.isCancelled { return stopped }
                if has != nil { unknown = false }
                if waitIsOver(has: has, gone: gone) {
                    return .text(gone ? "“\(text)” is gone (after \(seconds()) s). \(now(tab, caller: session.caller))" : "“\(text)” is on the page (after \(seconds()) s). \(now(tab, caller: session.caller))")
                }
            } else if !tab.isLoading {
                return .text("The page has loaded (after \(seconds()) s). \(now(tab, caller: session.caller))")
            }
            if Date().timeIntervalSince(started) >= timeout {
                let what = text.map { gone ? (unknown ? "the page did not answer, so “\($0)” could not be checked" : "“\($0)” was still on the page")
                    : (unknown ? "“\($0)” did not appear where Changmun could look (a frame from another site could not be reached)" : "“\($0)” did not appear") } ?? "the page was still loading"
                return .text("Timed out after \(Int(timeout)) s: \(what). \(now(tab, caller: session.caller))", error: true)
            }
            try? await Task.sleep(for: .milliseconds(pause))
            pause = min(pause * 3 / 2, 1000)
        }
    }

    /// Waiting for the text to show (or, with `gone`, to go): a look at the page that got no answer says neither.
    static func waitIsOver(has: Bool?, gone: Bool) -> Bool {
        has.map { $0 != gone } ?? false
    }

    /// What a look at one place of the page came to: its answer, a script that could not be run there at all (the frame is gone), or
    /// no answer (the place is busy, or hung, or the answer was not one).
    enum Look: Equatable {
        case answered([String: Any]), gone, hung

        static func == (a: Look, b: Look) -> Bool {
            switch (a, b) {
            case (.gone, .gone), (.hung, .hung): return true
            case (.answered(let x), .answered(let y)): return NSDictionary(dictionary: x).isEqual(to: y)
            default: return false
            }
        }
    }

    static func look(_ result: ToolResult) -> Look {
        let text = result.content.first?["text"] as? String
        if result.isError { return text == didNotAnswer ? .hung : .gone }
        guard let text, let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return .hung }
        return .answered(json)
    }

    /// How long one frame is given to answer a look at the page, when the wait it belongs to ends at `end`.
    static func lookTimeout(until end: Date, now: Date = Date()) -> Double {
        min(frameTimeout, max(end.timeIntervalSince(now), 1))
    }

    /// Greets the frames of other sites that the page shows now (those a read has not named too), so that a look at the page can
    /// include them; says whether every one of them answered. A frame that did not answer (it may still be loading) is not waited
    /// for again until a moment has passed (`unreachable` says when each was tried). The frames of one document are greeted at the same time.
    @MainActor
    private static func greetShownFrames(_ tab: Tab, _ webView: WKWebView, unreachable: inout [String: Date]) async -> Bool {
        var all = true
        func visit(_ frame: WKFrameInfo?, depth: Int) async {
            let result = await run(PageScripts.visibleFrames, [:], in: webView, frame: frame, timeout: 3)
            guard let shown = shownFrames(from: result.isError ? nil : result.content.first?["text"] as? String) else {
                all = false
                return
            }
            if shown.more { all = false }
            var waiting: [String] = []
            for ref in shown.refs where tab.agent.frames.frame(for: ref.slot) == nil {
                if let tried = unreachable[ref.slot], Date().timeIntervalSince(tried) < 1.5 {
                    all = false
                    continue
                }
                tab.agent.frames.expect(slot: ref.slot, nonce: ref.nonce)
                waiting.append(ref.slot)
            }
            let answered = await tab.frames(named: waiting)
            for slot in waiting {
                if answered[slot] == nil {
                    unreachable[slot] = Date()
                    all = false
                } else {
                    unreachable[slot] = nil
                }
            }
            for ref in shown.refs where depth < 2 {
                if let info = tab.agent.frames.frame(for: ref.slot) { await visit(info, depth: depth + 1) }
            }
        }
        await visit(nil, depth: 0)
        return all
    }

    /// Whether the text is on the page, in a frame of its site, or in a frame of another site (greeted first, so that a frame the
    /// latest read did not name is looked in too); nil when a place that might hold it did not answer or could not be reached.
    /// The looks are over by `end` (one frame that hangs can't hold the wait past it), and a frame that is gone or can't be
    /// asked is not asked again.
    @MainActor
    private static func pageHas(_ text: String, tab: Tab, webView: WKWebView, caller: String, until end: Date, unreachable: inout [String: Date]) async -> Bool? {
        var unanswered = await !greetShownFrames(tab, webView, unreachable: &unreachable)
        let places: [(slot: String?, frame: WKFrameInfo?)] = [(nil, nil)] + tab.agent.frames.known.map { ($0.slot, $0.frame) }
        for place in places {
            if place.frame != nil, end.timeIntervalSinceNow <= 0 {
                unanswered = true
                break
            }
            let timeout = lookTimeout(until: end)
            let result = await run(PageScripts.hasText, ["args": ["text": text]], in: webView, frame: place.frame, timeout: timeout)
            guard case .answered(let json) = look(result) else {
                // A frame the page script could not be run in is gone: it is not asked again. One that did not answer in time is
                // slow or hung, which says nothing about its text: the wait goes on without an answer from it.
                if let slot = place.slot, look(result) == .gone {
                    tab.agent.frames.drop(slot: slot)
                } else {
                    unanswered = true
                }
                continue
            }
            // The answer says something about what the frame shows, so it was read from where it is.
            let host = host(ofOrigin: json["origin"] as? String ?? "")
            if place.frame == nil {
                Approvals.noteRead(tab, readHost: host.isEmpty ? nil : host, caller: caller)
            } else {
                Approvals.noteRead(tab, readHost: host.isEmpty ? Approvals.unknownFrame : host, caller: caller)
            }
            if json["found"] as? Bool == true { return true }
        }
        return unanswered ? nil : false
    }
}
