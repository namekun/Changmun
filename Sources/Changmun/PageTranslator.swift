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
    static func translate(_ webView: WKWebView, from source: Locale.Language, to target: Locale.Language = target,
                          while current: () -> Bool = { true }) async -> Outcome {
        guard #available(macOS 26.0, *) else { return .unsupported }
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: break
        case .supported: return .needsDownload
        default: return .unsupported
        }
        let session = TranslationSession(installedSource: source, target: target)
        guard let count = try? await webView.callAsyncJavaScript(collectScript, contentWorld: .defaultClient) as? Int else { return .failed }
        var start = 0
        while start < count {
            // A page that went away mid-way (navigated, put to sleep) leaves nothing to read: that is a failure, not the end.
            guard current(), let texts = try? await webView.callAsyncJavaScript("return globalThis.changmunTranslation.texts.slice(start, start + size)",
                                                                                 arguments: ["start": start, "size": 60], contentWorld: .defaultClient) as? [String]
            else { return .failed }
            guard !texts.isEmpty else { break }
            let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String(start + $0)) }
            guard let responses = try? await session.translations(from: requests), current() else { return start == 0 ? .failed : .translated }
            let translated = Dictionary(responses.compactMap { r in r.clientIdentifier.map { ($0, r.targetText) } }) { first, _ in first }
            _ = try? await webView.callAsyncJavaScript(applyScript, arguments: ["texts": translated], contentWorld: .defaultClient)
            start += texts.count
        }
        return .translated
    }

    static func showOriginal(_ webView: WKWebView) async {
        _ = try? await webView.callAsyncJavaScript(
            "const t = globalThis.changmunTranslation; if (t) t.nodes.forEach((n, i) => { n.nodeValue = t.originals[i]; }); delete globalThis.changmunTranslation;",
            contentWorld: .defaultClient)
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
