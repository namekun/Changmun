import WebKit

/// Reader Mode: lays the article of a page over it as clean text, and takes it away again. The page stays underneath,
/// untouched, so leaving brings it back as it was. It finds the article itself, with a small heuristic: the block
/// holding the most paragraph text, copied tag by tag (only text, links, images and plain structure survive; no
/// scripts, attributes or styles of the page), into a closed shadow tree the page's own CSS can't reach.
enum Reader {
    enum Mode: String {
        /// What the page is like now: showing the article, or whether it looks like one.
        case check
        /// Shows the article, or takes it away when it is up.
        case toggle
        /// Takes the article away when it is up.
        case close
    }

    enum State: String {
        /// The article is showing.
        case up
        /// It was showing and is gone.
        case down
        /// The page has an article that can be shown, or has none.
        case readable, unreadable
        /// Asked to show it, but there is nothing to show (or the page didn't answer).
        case none
    }

    @MainActor
    static func run(_ mode: Mode, in webView: WKWebView) async -> State {
        let arguments: [String: Any] = ["mode": mode.rawValue, "exitLabel": String(localized: "Exit Reader Mode")]
        let answer = try? await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .defaultClient) as? String
        return answer.flatMap(State.init) ?? .none
    }

    static let script = #"""
    const SKIP = new Set(['script', 'style', 'noscript', 'template', 'iframe', 'object', 'embed', 'form', 'nav', 'aside', 'footer', 'button',
      'select', 'input', 'textarea', 'dialog', 'svg', 'canvas', 'audio', 'video', 'menu', 'head', 'link', 'meta']);
    const ROLES = /^(navigation|banner|complementary|search|dialog|alert|contentinfo)$/;
    const JUNK = /(^|[^a-z])(ad|ads|advert|advertisement|banner|breadcrumbs?|comments?|cookie|disqus|footer|masthead|menu|modal|newsletter|outbrain|popup|promo|related|share|sharing|sidebar|social|sponsor|sponsored|subscribe|taboola|toolbar|widget)([^a-z]|$)/i;
    const structural = el => SKIP.has(el.localName) || el.hidden || el.getAttribute('aria-hidden') === 'true' || ROLES.test(el.getAttribute('role') || '');
    const classy = el => JUNK.test((typeof el.className === 'string' ? el.className : '') + ' ' + el.id);
    const text = el => el.textContent.replace(/\s+/g, ' ').trim();

    // The container holding the most paragraph text: each paragraph counts for its parent, and less for the two above.
    function find() {
      if (!document.body) return null;
      const scores = new Map();
      for (const p of [...document.body.querySelectorAll('p')].slice(0, 600)) {
        const t = text(p);
        if (t.length < 40) continue;
        let hidden = false;
        for (let e = p; e && e !== document.body; e = e.parentElement) if (structural(e)) { hidden = true; break; }
        if (hidden) continue;
        const score = 1 + Math.min(t.length / 100, 3) + (t.match(/[,，、。]/g) || []).length;
        let e = p.parentElement;
        for (let depth = 0; e && e !== document.documentElement && depth < 3; e = e.parentElement, depth++) {
          scores.set(e, (scores.get(e) || 0) + score / (depth === 0 ? 1 : depth * 2));
        }
      }
      let root = null, best = 0;
      for (const [e, s] of scores) if (s > best) { root = e; best = s; }
      if (!root) return null;
      const article = root.closest('article');
      if (article && article !== root && text(article).length <= text(root).length * 1.6) root = article;
      const length = text(root).length;
      const links = [...root.querySelectorAll('a')].reduce((n, a) => n + text(a).length, 0);
      return { root, readable: length >= 600 && root.querySelectorAll('p').length >= 3 && links < length * 0.4 };
    }

    const shown = globalThis.changmunReader;
    if (mode === 'check') { if (shown) return 'up'; const found = find(); return found && found.readable ? 'readable' : 'unreadable'; }
    if (shown) { shown.exit(); return 'down'; }
    if (mode === 'close') return 'down';
    const found = find();
    if (!found) return 'none';

    const root = found.root;
    // A wrapper that holds most of the article ("page-with-sidebar") is not junk, however it is named.
    const wrapper = text(root).length * 0.6;
    const junk = el => structural(el) || (classy(el) && text(el).length < wrapper);
    const heading = root.querySelector('h1') || (root.closest('article') || document).querySelector('h1');
    const title = (heading && text(heading)) || document.title;
    const link = a => { try { const u = new URL(a.getAttribute('href'), document.baseURI); return /^https?:$/.test(u.protocol) ? u.href : null; } catch (e) { return null; } };
    const INLINE = new Set(['a', 'em', 'strong', 'b', 'i', 'u', 'code', 'sup', 'sub', 'mark', 'small', 'abbr', 'cite', 'q', 'time', 'kbd', 's', 'del', 'ins']);
    // 1: holds text; 2: holds blocks; 0: nothing inside.
    const BLOCKS = { p: 1, h2: 1, h3: 1, h4: 1, h5: 1, h6: 1, pre: 1, figcaption: 1, ul: 2, ol: 2, li: 2, blockquote: 2, figure: 2,
      table: 2, thead: 2, tbody: 2, tfoot: 2, tr: 2, td: 2, th: 2, hr: 0 };
    const BLOCK_INSIDE = 'img, picture, p, div, ul, ol, blockquote, figure, pre, table, h1, h2, h3, h4, h5, h6';

    function inlineNode(n, out) {
      if (n.nodeType === 3) { out.appendChild(document.createTextNode(n.nodeValue)); return; }
      if (n.nodeType !== 1 || junk(n)) return;
      const tag = n.localName;
      if (tag === 'br') { out.appendChild(document.createElement('br')); return; }
      let el = out;
      if (tag === 'a') {
        const href = link(n), id = n.id || n.getAttribute('name');
        if (href || id) el = document.createElement('a');
        if (href) el.href = href;
        if (id && el !== out) el.id = id;
      } else if (INLINE.has(tag)) {
        el = document.createElement(tag);
        if (n.id) el.id = n.id;
      }
      for (const child of n.childNodes) inlineNode(child, el);
      if (el !== out) out.appendChild(el);
    }

    function image(n) {
      const img = n.localName === 'img' ? n : n.querySelector('img');
      if (!img) return null;
      let src = img.currentSrc || img.src;
      const lazy = img.getAttribute('data-src') || img.getAttribute('data-original') || img.getAttribute('data-lazy-src');
      if (lazy && (!src || src.startsWith('data:'))) { try { src = new URL(lazy, document.baseURI).href; } catch (e) {} }
      const width = img.naturalWidth || img.width;
      if (!/^https?:/.test(src) || (width && width < 120)) return null;
      const copy = document.createElement('img');
      copy.src = src;
      copy.alt = img.alt || '';
      return copy;
    }

    let titleSeen = false;
    function blocks(src, out) {
      let run = null;
      const loose = () => { if (!run) { run = document.createElement('p'); out.appendChild(run); } return run; };
      for (const n of src.childNodes) {
        if (n.nodeType === 3) { if (run || n.nodeValue.trim()) loose().appendChild(document.createTextNode(n.nodeValue)); continue; }
        if (n.nodeType !== 1 || junk(n)) continue;
        let tag = n.localName;
        if (tag === 'h1') {
          if (!titleSeen && text(n) === title) { titleSeen = true; continue; }
          tag = 'h2';
        }
        if (tag === 'img' || tag === 'picture') {
          run = null;
          const copy = image(n);
          if (copy) out.appendChild(copy);
          continue;
        }
        const kind = BLOCKS[tag];
        if (kind === undefined) {
          const flow = /^inline/.test(getComputedStyle(n).display) && !n.querySelector(BLOCK_INSIDE);
          if (flow) { inlineNode(n, loose()); } else { run = null; blocks(n, out); }
          continue;
        }
        run = null;
        const el = document.createElement(tag);
        if (n.id) el.id = n.id;
        if (kind === 1) {
          if (tag === 'pre') el.textContent = n.textContent; else for (const child of n.childNodes) inlineNode(child, el);
          if (!el.textContent.trim()) continue;
        } else if (kind === 2) {
          blocks(n, el);
          if (!el.childNodes.length) continue;
        }
        out.appendChild(el);
      }
    }

    const content = document.createElement('div');
    blocks(root, content);
    if (text(content).length < 200) return 'none';

    const dark = matchMedia('(prefers-color-scheme: dark)').matches;
    const c = dark ? { bg: '#1c1c1e', fg: '#e6e6e8', muted: '#98989f', line: '#3a3a3c', code: '#2c2c2e', link: '#6cb2ff' }
                   : { bg: '#fbfbfa', fg: '#1d1d1f', muted: '#6e6e73', line: '#d2d2d7', code: '#f0f0f2', link: '#0066cc' };
    const host = document.createElement('div');
    host.id = 'changmun-reader';
    host.tabIndex = -1;
    const pinned = { position: 'fixed', inset: '0', 'z-index': '2147483647', overflow: 'auto', display: 'block', margin: '0', padding: '0', border: '0',
      outline: 'none', transform: 'none', opacity: '1', visibility: 'visible', 'overscroll-behavior': 'contain', background: c.bg };
    for (const [name, value] of Object.entries(pinned)) host.style.setProperty(name, value, 'important');
    const shadow = host.attachShadow({ mode: 'closed' });
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(`
      .page { box-sizing: border-box; max-width: 728px; margin: 0 auto; padding: 72px 24px 120px; color: ${c.fg};
        font: 19px/1.65 -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif; overflow-wrap: break-word; }
      .title { font-size: 34px; line-height: 1.2; font-weight: 700; letter-spacing: -0.01em; margin: 0 0 10px; }
      .meta { font-size: 14px; color: ${c.muted}; margin: 0 0 40px; }
      p { margin: 0 0 1.1em; }
      h2, h3, h4, h5, h6 { line-height: 1.3; margin: 1.8em 0 0.6em; }
      h2 { font-size: 1.45em; } h3 { font-size: 1.2em; } h4, h5, h6 { font-size: 1em; }
      a { color: ${c.link}; }
      img { display: block; max-width: 100%; height: auto; margin: 1.5em auto; border-radius: 8px; }
      figure { margin: 1.6em 0; } figure img { margin: 0 auto; }
      figcaption { font-size: 14px; color: ${c.muted}; text-align: center; margin-top: 8px; }
      blockquote { margin: 1.4em 0; padding-left: 1.1em; border-left: 3px solid ${c.line}; color: ${c.muted}; }
      ul, ol { margin: 0 0 1.1em; padding-left: 1.4em; } li { margin: 0.3em 0; } li > p, td > p, th > p { margin: 0; }
      pre { overflow: auto; margin: 1.4em 0; padding: 14px 16px; background: ${c.code}; border-radius: 8px; font: 13px/1.5 ui-monospace, Menlo, monospace; }
      code, kbd { font-family: ui-monospace, Menlo, monospace; font-size: 0.88em; }
      table { display: block; overflow-x: auto; border-collapse: collapse; margin: 1.4em 0; font-size: 0.9em; }
      td, th { border: 1px solid ${c.line}; padding: 6px 10px; text-align: left; }
      hr { border: 0; border-top: 1px solid ${c.line}; margin: 2em 0; }
      .close { position: fixed; top: 14px; right: 18px; width: 30px; height: 30px; border: 0; border-radius: 15px; cursor: pointer;
        background: ${c.code}; color: ${c.muted}; font: 18px/30px -apple-system, sans-serif; padding: 0; }
      .close:hover { color: ${c.fg}; }
    `);
    shadow.adoptedStyleSheets = [sheet];

    const page = document.createElement('div');
    page.className = 'page';
    page.lang = document.documentElement.lang;
    page.dir = document.dir || 'auto';
    const head = document.createElement('h1');
    head.className = 'title';
    head.textContent = title;
    const meta = document.createElement('div');
    meta.className = 'meta';
    const authorTag = document.querySelector('meta[name=author], meta[property="article:author"]');
    const author = (authorTag && authorTag.content) || (document.querySelector('[rel=author], [itemprop=author]') || {}).textContent || '';
    // The author goes in the line under the title, unless the article itself already opens with it.
    const byline = author.replace(/\s+/g, ' ').trim().slice(0, 80);
    meta.textContent = [text(content).slice(0, 300).includes(byline) ? '' : byline, location.hostname.replace(/^www\./, '')].filter(Boolean).join(' · ');
    page.append(head, meta, content);
    const close = document.createElement('button');
    close.className = 'close';
    close.textContent = '×';
    close.title = exitLabel;
    close.setAttribute('aria-label', exitLabel);
    shadow.append(page, close);

    const html = document.documentElement;
    const previousOverflow = [html.style.getPropertyValue('overflow'), html.style.getPropertyPriority('overflow')];
    const onKey = e => { if (e.key === 'Escape') exit(); };
    function exit() {
      host.remove();
      document.removeEventListener('keydown', onKey, true);
      html.style.removeProperty('overflow');
      if (previousOverflow[0]) html.style.setProperty('overflow', previousOverflow[0], previousOverflow[1]);
      globalThis.changmunReader = null;
      try { window.webkit.messageHandlers.changmunReader.postMessage(false); } catch (e) {}
    }
    close.addEventListener('click', exit);
    // A link to a place in this same page scrolls the article, not the page under it.
    shadow.addEventListener('click', e => {
      const a = e.target.closest ? e.target.closest('a[href]') : null;
      if (!a || !a.href.includes('#') || a.href.split('#')[0] !== location.href.split('#')[0]) return;
      e.preventDefault();
      let id = a.href.slice(a.href.indexOf('#') + 1);
      try { id = decodeURIComponent(id); } catch (err) {}
      const target = id && shadow.getElementById(id);
      if (target) target.scrollIntoView(); else if (!id) host.scrollTo(0, 0);
    });
    document.addEventListener('keydown', onKey, true);
    document.querySelectorAll('video, audio').forEach(m => { try { m.pause(); } catch (e) {} });
    html.style.setProperty('overflow', 'hidden', 'important');
    html.appendChild(host);
    host.focus({ preventScroll: true });
    globalThis.changmunReader = { exit, shadow };
    return 'up';
    """#
}

/// Hears from the page when Reader Mode was left from inside it (Esc, the close button).
final class ReaderWatcher: NSObject, WKScriptMessageHandler {
    static let name = "changmunReader"

    static func install(in controller: WKUserContentController) {
        controller.add(ReaderWatcher(), contentWorld: .defaultClient, name: name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let webView = message.webView, let tab = Browser.tab(showing: webView) else { return }
            tab.isReading = false
        }
    }
}
