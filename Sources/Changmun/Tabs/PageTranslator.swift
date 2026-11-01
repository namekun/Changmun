import NaturalLanguage
import os
import Translation
import WebKit

/// Translates a page into the user's language, by default on this Mac with the system's translation models, where the text never
/// leaves the machine; or, when the user has chosen it, with Claude (see ClaudeTranslation), which is sent the text. Text is replaced
/// node by node, so links and layout stay; the original comes back on request.
@MainActor
enum PageTranslator {
    /// What went wrong when a page wouldn't translate, in Console (subsystem io.github.namekun.Changmun, category translation).
    /// Never the page's text, its address or a translation.
    nonisolated static let log = Logger(subsystem: "io.github.namekun.Changmun", category: "translation")

    /// The first language in System Settings, which pages are translated into: "ko-KR", "en-KR" or "ko-Kore-KR" are the
    /// language alone, as the models are by language (Chinese keeps its script, the one place the models tell them apart).
    nonisolated static var target: Locale.Language { normalized(Locale.preferredLanguages.first ?? "ko") }

    nonisolated static func normalized(_ identifier: String) -> Locale.Language {
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode else { return language }
        return Locale.Language(languageCode: code, script: code == "zh" ? language.script : nil, region: nil)
    }

    /// The language most of the page is written in, when it isn't the user's.
    static func foreignLanguage(of webView: WKWebView) async -> Locale.Language? {
        let sample = try? await webView.callAsyncJavaScript(sampleScript, contentWorld: .defaultClient) as? String
        guard let sample, sample.count > 40, let language = dominantLanguage(sample) else { return nil }
        return language.languageCode == target.languageCode ? nil : language
    }

    nonisolated static func dominantLanguage(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    enum Outcome: Equatable {
        case translated, needsDownload, unsupported, nothingToTranslate, failed
        /// The page's text was read, but the system's translation refused all of it with every kind of model it has.
        case engineFailed
        /// Claude was asked and none of the page was translated: it stays as it was.
        case claudeFailed
        /// Claude translated some of the page and could not do the rest, which stays as it was.
        case translatedPartly
        /// The page has a password or payment field: it is not sent to Claude.
        case sensitivePage
    }

    /// How a page is to be translated, or why it can't be.
    enum Route: Equatable {
        case onDevice
        case claude(model: String)
        case refused(Refusal)
    }

    enum Refusal: Equatable {
        /// Claude is chosen and Claude Code is not there; the page is not translated some other way.
        case claudeUnavailable
        /// The tab may not go to Claude, and this Mac's own translation needs macOS 26.
        case onDeviceUnavailable
    }

    /// Whether the system's translation can be used on this Mac.
    nonisolated static var onDeviceAvailable: Bool { if #available(macOS 26.0, *) { true } else { false } }

    /// Which way a page goes. Claude only gets pages the AI may see (`seenByAI`: not a private window's, not another profile's):
    /// those of other tabs are translated on this Mac, or not at all. Claude chosen and missing is a refusal, never a quiet turn to
    /// the system's translation, and the system's translation is never a reason to ask Claude.
    nonisolated static func route(engine: TranslationEngine, model: String, claude: AIAvailability, seenByAI: Bool, onDeviceAvailable: Bool = onDeviceAvailable) -> Route {
        guard engine == .claude else { return .onDevice }
        guard seenByAI else { return onDeviceAvailable ? .onDevice : .refused(.onDeviceUnavailable) }
        return claude == .ready ? .claude(model: TranslationEngine.model(stored: model)) : .refused(.claudeUnavailable)
    }

    /// The kinds of models a session can be asked for: the two strategies of macOS 26.4 and later, then the system's default.
    enum Engine: String, Equatable {
        case lowLatency, highFidelity, standard
    }

    /// Translates the page from `source` in batches, showing each batch as it comes back, for as long as `current` holds.
    /// A piece of text the system can't translate is left as it was; only a page with nothing translated is a failure.
    static func translate(_ webView: WKWebView, from source: Locale.Language, to target: Locale.Language = target,
                          while current: () -> Bool = { true }) async -> Outcome {
        guard #available(macOS 26.0, *) else { return .unsupported }
        let (engines, otherwise, availability) = await engines(from: source, to: target)
        log.notice("""
            translate: macOS \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public), \
            preferred \(Locale.preferredLanguages.first ?? "-", privacy: .public), \
            from \(source.maximalIdentifier, privacy: .public) to \(target.maximalIdentifier, privacy: .public), \
            availability \(availability, privacy: .public), engines \(engines.map(\.rawValue).joined(separator: ","), privacy: .public)
            """)
        guard !engines.isEmpty else {
            log.notice("translate: outcome \(String(describing: otherwise), privacy: .public) (no model installed)")
            return otherwise
        }
        let count: Int
        do {
            guard let found = try await webView.callAsyncJavaScript(collectScript, contentWorld: .defaultClient) as? Int else {
                log.error("translate: reading the page gave no count; outcome failed")
                return .failed
            }
            count = found
        } catch {
            log.error("translate: reading the page failed: \(describe(error), privacy: .public); outcome failed")
            return .failed
        }
        log.notice("translate: \(count, privacy: .public) pieces of text")
        guard count > 0 else { return .nothingToTranslate }
        let (outcome, used) = await firstEngineThatWorks(engines) { engine in
            log.notice("translate: trying \(engine.rawValue, privacy: .public)")
            return await translatePage(webView, count: count, session: session(engine, from: source, to: target), while: current)
        }
        if let used, used != engines[0] { log.notice("translate: \(used.rawValue, privacy: .public) worked after \(engines[0].rawValue, privacy: .public) did not") }
        log.notice("translate: outcome \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    /// Asks each of `engines` in turn for the whole page, until one does not refuse it all (the first batch of the page
    /// refused by every piece is what an engine that doesn't work on this Mac looks like), and which one that was.
    nonisolated static func firstEngineThatWorks(_ engines: [Engine], run: (Engine) async -> Outcome) async -> (outcome: Outcome, engine: Engine?) {
        var outcome = Outcome.engineFailed
        for engine in engines {
            outcome = await run(engine)
            if outcome != .engineFailed { return (outcome, engine) }
        }
        return (outcome, nil)
    }

    /// Translates the page into `target` with Claude, batch by batch, showing each batch as it comes back, for as long as `current` holds
    /// (when it turns false the `claude` processes are ended). `permitted` is asked before every batch is started and again before its
    /// answer is used: the tab may stop being one that may go to Claude (a profile that is no longer the one shown, the setting changed),
    /// and then the work stops. What Claude doesn't translate is left as it was. A page with a password or a payment field is not sent at all.
    static func translateWithClaude(_ webView: WKWebView, model: String, to target: Locale.Language = target, while current: @escaping () -> Bool,
                                    permitted: @escaping @MainActor () -> Bool = { true }) async -> Outcome {
        let run: ClaudeTranslation.Run
        do { run = try ClaudeTranslation.makeRun(model) } catch {
            log.error("translate: Claude can't be run: \(String(describing: error), privacy: .public)")
            return .claudeFailed
        }
        let texts: [String]
        do {
            // One run of one script decides whether the page may be sent and collects it: the page can't change between the two.
            guard let found = try await webView.callAsyncJavaScript(claudeCollectScript, contentWorld: .defaultClient) as? [String: Any] else { return .failed }
            if found["sensitive"] as? Bool != false { return .sensitivePage }
            guard let all = found["texts"] as? [String] else { return .failed }
            guard !all.isEmpty else { return .nothingToTranslate }
            texts = all
        } catch {
            log.error("translate: reading the page failed: \(describe(error), privacy: .public); outcome failed")
            return .failed
        }
        log.notice("translate: \(texts.count, privacy: .public) pieces of text, with Claude")
        let language = ClaudeTranslation.languageName(target)
        let work = Task {
            await ClaudeTranslation.translate(texts.enumerated().map { (id: $0, text: $1) }, language: language, run: run, allowed: { current() && permitted() }) { translated in
                guard current() else { return }
                _ = try? await webView.appScript(applyScript, arguments: ["texts": Dictionary(uniqueKeysWithValues: translated.map { (String($0.key), $0.value) })])
            }
        }
        // The page going away, or the user asking for the original, ends the processes: the task is cancelled, and each `claude` with it.
        let watcher = Task {
            while !Task.isCancelled {
                if !current() { return work.cancel() }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        let report = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        watcher.cancel()
        log.notice("translate: Claude translated \(report.translated, privacy: .public) pieces, \(report.failedBatches, privacy: .public) batches failed, \(report.skippedBatches, privacy: .public) not asked, \(report.leftOut, privacy: .public) left out, \(report.dropped, privacy: .public) dropped, denied \(report.denied, privacy: .public)")
        if report.translated == 0 { return .claudeFailed }
        return report.failedBatches > 0 || report.skippedBatches > 0 || report.leftOut > 0 || report.dropped > 0 || report.denied ? .translatedPartly : .translated
    }

    /// The page's `count` pieces of text (already collected) translated with `session`, batch by batch.
    @available(macOS 26.0, *)
    private static func translatePage(_ webView: WKWebView, count: Int, session: TranslationSession, while current: () -> Bool) async -> Outcome {
        var start = 0
        var translatedAny = false
        var batchErrorLogged = false
        var firstPieceError: Error?
        while start < count {
            // A page that went away mid-way (navigated, put to sleep) leaves nothing to read: that is a failure, not the end.
            guard current(), let texts = try? await webView.callAsyncJavaScript("return globalThis.changmunTranslation.texts.slice(start, start + size)",
                                                                                 arguments: ["start": start, "size": 60], contentWorld: .defaultClient) as? [String]
            else { return translatedAny ? .translated : .failed }
            guard !texts.isEmpty else { break }
            let pieces = texts.enumerated().map { (id: start + $0, text: $1) }
            let (translated, gaveUp) = await translateKeepingWhatWorks(pieces, while: current, onError: { error, onePiece in
                if onePiece { firstPieceError = firstPieceError ?? error } else if !batchErrorLogged {
                    batchErrorLogged = true
                    log.error("translate: the batch at \(start, privacy: .public) was refused: \(describe(error), privacy: .public)")
                }
            }) { batch in
                let responses = try await session.translations(from: batch.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) })
                return Dictionary(responses.compactMap { r in r.clientIdentifier.flatMap(Int.init).map { ($0, r.targetText) } }) { first, _ in first }
            }
            guard current() else { return translatedAny ? .translated : .failed }
            if !translated.isEmpty {
                translatedAny = true
                _ = try? await webView.appScript(applyScript, arguments: ["texts": Dictionary(uniqueKeysWithValues: translated.map { (String($0.key), $0.value) })])
            }
            // Pieces refused one by one, all of them: the session is broken, and the rest of the page would be as many calls.
            if gaveUp {
                log.error("translate: gave up at \(start, privacy: .public) of \(count, privacy: .public); a single piece was refused: \(firstPieceError.map(describe) ?? "-", privacy: .public)")
                return translatedAny ? .translated : .engineFailed
            }
            start += texts.count
        }
        return translatedAny ? .translated : .failed
    }

    /// The error for the log: its type and the domain and code it has as an NSError, and no more than the Translation framework says.
    nonisolated static func describe(_ error: Error) -> String {
        let bridged = error as NSError
        var text = "\(type(of: error)) [\(bridged.domain) \(bridged.code)]"
        // Only the Translation framework's own wording: a web view's error can carry the page's script, text or address.
        if #available(macOS 15.0, *), let translation = error as? TranslationError { text += " " + String(translation.localizedDescription.prefix(200)) }
        return text
    }

    /// The models that can be asked for a session, best guess first, or why there are none: they aren't downloaded, or can't
    /// be. Also what the system says about each kind, for the log.
    @available(macOS 26.0, *)
    private static func engines(from source: Locale.Language, to target: Locale.Language) async -> (engines: [Engine], otherwise: Outcome, availability: String) {
        var statuses: [(engine: Engine, status: LanguageAvailability.Status)] = []
        if #available(macOS 26.4, *) {
            // An app built for an older system is given the low latency models unless it says otherwise, while the languages
            // downloaded in System Settings may be the high fidelity ones: either is good enough, so use whichever is there,
            // low latency first, as it was before: it is the quicker of the two on a big page.
            statuses.append((.lowLatency, await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: target)))
            statuses.append((.highFidelity, await LanguageAvailability(preferredStrategy: .highFidelity).status(from: source, to: target)))
        }
        statuses.append((.standard, await LanguageAvailability().status(from: source, to: target)))
        let usable = usableEngines(statuses)
        return (usable.engines, usable.downloadable ? .needsDownload : .unsupported, statuses.map { "\($0.engine.rawValue)=\($0.status)" }.joined(separator: " "))
    }

    /// A session on `engine`'s models, which are on this Mac.
    @available(macOS 26.0, *)
    private static func session(_ engine: Engine, from source: Locale.Language, to target: Locale.Language) -> TranslationSession {
        if #available(macOS 26.4, *), engine != .standard {
            return TranslationSession(installedSource: source, target: target, preferredStrategy: engine == .lowLatency ? .lowLatency : .highFidelity)
        }
        return TranslationSession(installedSource: source, target: target)
    }

    /// The engines that have the language installed, in the order given (the system's own choice, which is always the
    /// last of them, is also there as a last resort when another has it installed), and whether any of them could download it.
    @available(macOS 15.0, *)
    nonisolated static func usableEngines(_ statuses: [(engine: Engine, status: LanguageAvailability.Status)]) -> (engines: [Engine], downloadable: Bool) {
        var engines = statuses.filter { $0.status == .installed }.map(\.engine)
        if !engines.isEmpty, !engines.contains(.standard) { engines.append(.standard) }
        return (engines, statuses.contains { $0.status == .supported })
    }

    /// Translates `pieces` (each with a number of its own) in one go, and if the system refuses the whole batch because of
    /// one piece, one by one, so that only the piece it can't translate stays as it was. When not one piece could be
    /// translated, `gaveUp` says so, so that the caller doesn't go on to ask for the next batch piece by piece.
    /// `onError` is told of each error the system gives, and whether it was for a single piece.
    nonisolated static func translateKeepingWhatWorks(_ pieces: [(id: Int, text: String)], while current: () -> Bool,
                                                      onError: (Error, Bool) -> Void = { _, _ in },
                                                      using translate: ([(id: Int, text: String)]) async throws -> [Int: String])
        async -> (translated: [Int: String], gaveUp: Bool) {
        do { return (try await translate(pieces), false) } catch { onError(error, false) }
        var translated: [Int: String] = [:]
        for piece in pieces {
            guard current() else { break }
            do { translated.merge(try await translate([piece])) { first, _ in first } } catch { onError(error, true) }
        }
        return (translated, translated.isEmpty && current())
    }

    static func showOriginal(_ webView: WKWebView) async {
        _ = try? await webView.appScript(
            "const t = globalThis.changmunTranslation; if (t) t.nodes.forEach((n, i) => { n.nodeValue = t.originals[i]; }); delete globalThis.changmunTranslation;")
    }

    /// The first 4000 or so characters of the page's text, without laying the whole page out for `innerText`.
    static let sampleScript = """
    if (!document.body) return '';
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let sample = '';
    while (sample.length < 4000 && walker.nextNode()) {
      const parent = walker.currentNode.parentElement;
      if (parent && !parent.closest('script, style, noscript')) sample += walker.currentNode.nodeValue + ' ';
    }
    return sample;
    """

    /// Finds the page's words: text nodes outside code, form fields and anything marked not to translate. A form field's value is
    /// never a text node (an `input`, a password, a code or a card number has no children, a `textarea` and a `select` are skipped), so
    /// none of it is read.
    static let collectScript = makeCollectScript(skipping: "")

    /// What goes to Claude is collected with more care than what stays on this Mac, in one run that also decides whether the page may go at
    /// all: it answers `{sensitive: true}` for a page with a field for a password (by `type`, or `autocomplete` as `current-password` or
    /// `new-password`, which a button that shows the password doesn't change), a one-time code or a card (`autocomplete`), looking into open
    /// shadow roots too, and otherwise `{sensitive: false, texts}`. Not what a page lets the user type into without an input
    /// (`contenteditable` of any kind, `role=textbox`, `searchbox` and `combobox`), not the suggestions of a `datalist` and not a form's
    /// options, and only what is to be seen: not what is `hidden` or `aria-hidden`, nor what can't be seen (`checkVisibility`, or the
    /// computed style where a page has no such function: `display: none`, `visibility: hidden`, no opacity), nor what has no width or
    /// height, nor the inside of a closed `details`. It doesn't look into frames of other sites.
    static let claudeCollectScript = makeCollectScript(skipping: ", option, datalist, [contenteditable]:not([contenteditable=false i]), [role=textbox], [role=searchbox], [role=combobox]", forClaude: true)

    private static func makeCollectScript(skipping more: String, forClaude: Bool = false) -> String {
        let before = forClaude ? """
        const sensitive = root => {
          if (root.querySelector('input[type=password i], input[autocomplete~="one-time-code" i], input[autocomplete*="cc-" i], input[autocomplete~="current-password" i], input[autocomplete~="new-password" i]')) return true;
          for (const el of root.querySelectorAll('*')) if (el.shadowRoot && sensitive(el.shadowRoot)) return true;
          return false;
        };
        if (sensitive(document)) return { sensitive: true };
        // The element that has a box where a text is drawn: one with `display: contents` has none, and its text is drawn in its parent's.
        const boxOf = el => {
          while (el && getComputedStyle(el).display === 'contents') el = el.parentElement;
          return el;
        };
        const hiddenOnce = el => {
          if (el.closest('[hidden], [aria-hidden="true"]')) return true;
          const box = boxOf(el);
          if (!box) return true;
          if (box.checkVisibility) {
            if (!box.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return true;
          } else {
            for (let e = box; e; e = e.parentElement) {
              const s = getComputedStyle(e);
              if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return true;
            }
          }
          const r = box.getBoundingClientRect();
          if (!(r.width > 0 && r.height > 0)) return true;
          const summary = el.closest('summary');
          for (let d = el.closest('details'); d; d = d.parentElement ? d.parentElement.closest('details') : null) {
            if (!d.open && !(summary && summary.parentElement === d)) return true;
          }
          return false;
        };
        const seen = new Map();
        const hidden = el => { if (!seen.has(el)) seen.set(el, hiddenOnce(el)); return seen.get(el); };

        """ : "const hidden = () => false;\n"
        let after = forClaude ? "return { sensitive: false, texts: globalThis.changmunTranslation.texts };" : "return nodes.length;"
        return """
        const skip = 'script, style, noscript, textarea, input, select, code, pre, kbd, samp, svg, math, [translate=no], .notranslate, [contenteditable=""], [contenteditable=true]\(more)';
        \(before)const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode: n => /\\p{L}/u.test(n.nodeValue) && n.nodeValue.trim().length > 1 && !(n.parentElement && (n.parentElement.closest(skip) || hidden(n.parentElement)))
            ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT,
        });
        const nodes = [];
        while (walker.nextNode() && nodes.length < 4000) nodes.push(walker.currentNode);
        const previous = globalThis.changmunTranslation;
        if (previous) previous.nodes.forEach((n, i) => { n.nodeValue = previous.originals[i]; });
        globalThis.changmunTranslation = { nodes, originals: nodes.map(n => n.nodeValue), texts: nodes.map(n => n.nodeValue.trim()) };
        \(after)
        """
    }

    /// Puts translations in place, keeping the spaces around each piece of text.
    static let applyScript = """
    const t = globalThis.changmunTranslation;
    if (!t) return;
    for (const [i, text] of Object.entries(texts)) {
      const original = t.originals[i];
      const lead = original.match(/^\\s*/)[0], trail = original.match(/\\s*$/)[0];
      t.nodes[i].nodeValue = lead + text + trail;
    }
    """
}
