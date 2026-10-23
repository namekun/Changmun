import NaturalLanguage
import Translation
import WebKit

/// Translates a page into the user's language on this Mac, with the system's translation models: the text never
/// leaves the machine. Text is replaced node by node, so links and layout stay; the original comes back on request.
@MainActor
enum PageTranslator {
    /// The first language in System Settings, which pages are translated into.
    nonisolated static var target: Locale.Language { Locale.Language(identifier: Locale.preferredLanguages.first ?? "ko") }

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
        case translated, needsDownload, unsupported, failed
    }

    /// Translates the page from `source` in batches, showing each batch as it comes back, for as long as `current` holds.
    /// A piece of text the system can't translate is left as it was; only a page with nothing translated is a failure.
    static func translate(_ webView: WKWebView, from source: Locale.Language, to target: Locale.Language = target,
                          while current: () -> Bool = { true }) async -> Outcome {
        guard #available(macOS 26.0, *) else { return .unsupported }
        let (opened, otherwise) = await openSession(from: source, to: target)
        guard let session = opened else { return otherwise }
        guard let count = try? await webView.callAsyncJavaScript(collectScript, contentWorld: .defaultClient) as? Int else { return .failed }
        var start = 0
        var translatedAny = false
        while start < count {
            // A page that went away mid-way (navigated, put to sleep) leaves nothing to read: that is a failure, not the end.
            guard current(), let texts = try? await webView.callAsyncJavaScript("return globalThis.changmunTranslation.texts.slice(start, start + size)",
                                                                                 arguments: ["start": start, "size": 60], contentWorld: .defaultClient) as? [String]
            else { return .failed }
            guard !texts.isEmpty else { break }
            let pieces = texts.enumerated().map { (id: start + $0, text: $1) }
            let translated = await translateKeepingWhatWorks(pieces, while: current) { batch in
                let responses = try await session.translations(from: batch.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) })
                return Dictionary(responses.compactMap { r in r.clientIdentifier.flatMap(Int.init).map { ($0, r.targetText) } }) { first, _ in first }
            }
            guard current() else { return translatedAny ? .translated : .failed }
            if !translated.isEmpty {
                translatedAny = true
                _ = try? await webView.appScript(applyScript, arguments: ["texts": Dictionary(uniqueKeysWithValues: translated.map { (String($0.key), $0.value) })])
            }
            start += texts.count
        }
        return translatedAny ? .translated : .failed
    }

    /// A session on the models that are on this Mac, or why there is none: they aren't downloaded, or can't be.
    @available(macOS 26.0, *)
    private static func openSession(from source: Locale.Language, to target: Locale.Language) async -> (TranslationSession?, Outcome) {
        if #available(macOS 26.4, *) {
            // An app built for an older system is given the low latency models unless it says otherwise, while the languages
            // downloaded in System Settings may be the high fidelity ones: either is good enough, so use whichever is there.
            let found = await firstInstalled([TranslationSession.Strategy.lowLatency, .highFidelity]) {
                await LanguageAvailability(preferredStrategy: $0).status(from: source, to: target)
            }
            if let strategy = found.installed {
                return (TranslationSession(installedSource: source, target: target, preferredStrategy: strategy), .translated)
            }
            return (nil, found.downloadable ? .needsDownload : .unsupported)
        }
        let found = await firstInstalled([()]) { await LanguageAvailability().status(from: source, to: target) }
        guard found.installed != nil else { return (nil, found.downloadable ? .needsDownload : .unsupported) }
        return (TranslationSession(installedSource: source, target: target), .translated)
    }

    /// The first of `engines` that has the language installed, and whether any of them could download it.
    @available(macOS 15.0, *)
    nonisolated static func firstInstalled<Engine>(_ engines: [Engine], status: (Engine) async -> LanguageAvailability.Status)
        async -> (installed: Engine?, downloadable: Bool) {
        var downloadable = false
        for engine in engines {
            switch await status(engine) {
            case .installed: return (engine, downloadable)
            case .supported: downloadable = true
            default: break
            }
        }
        return (nil, downloadable)
    }

    /// Translates `pieces` (each with a number of its own) in one go, and if the system refuses the whole batch because of
    /// one piece, one by one, so that only the piece it can't translate stays as it was.
    nonisolated static func translateKeepingWhatWorks(_ pieces: [(id: Int, text: String)], while current: () -> Bool,
                                                      using translate: ([(id: Int, text: String)]) async throws -> [Int: String]) async -> [Int: String] {
        if let all = try? await translate(pieces) { return all }
        var translated: [Int: String] = [:]
        for piece in pieces {
            guard current() else { break }
            if let one = try? await translate([piece]) { translated.merge(one) { first, _ in first } }
        }
        return translated
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

    /// Finds the page's words: text nodes outside code, form fields and anything marked not to translate.
    static let collectScript = """
    const skip = 'script, style, noscript, textarea, input, select, code, pre, kbd, samp, svg, math, [translate=no], .notranslate, [contenteditable=""], [contenteditable=true]';
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: n => /\\p{L}/u.test(n.nodeValue) && n.nodeValue.trim().length > 1 && !(n.parentElement && n.parentElement.closest(skip))
        ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT,
    });
    const nodes = [];
    while (walker.nextNode() && nodes.length < 4000) nodes.push(walker.currentNode);
    const previous = globalThis.changmunTranslation;
    if (previous) previous.nodes.forEach((n, i) => { n.nodeValue = previous.originals[i]; });
    globalThis.changmunTranslation = { nodes, originals: nodes.map(n => n.nodeValue), texts: nodes.map(n => n.nodeValue.trim()) };
    return nodes.length;
    """

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
