import Foundation

/// The scripts of read_structured and read_markdown. They run in the isolated world like the others, read the page's DOM through
/// the prototypes (a form with a field named "childNodes" has that field there instead) and make text of what the page chose:
/// every string is cut, stripped of control and invisible characters, and the answer is framed as read_page frames its text.
extension PageScripts {
    /// The page's machine-readable metadata as one line of JSON: JSON-LD blocks, OpenGraph and Twitter-card tags, a few meta tags,
    /// the language and the canonical and alternate links (feeds, translations, Markdown versions). Main frame only, no request.
    /// Arguments: `maxChars`, the most the answer may be.
    static let readStructured = #"""
    const CTRL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029\u200b\u200e\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]/g;
    const cut = (s, n) => {
      if (s.length <= n) return s;
      let t = s.slice(0, n);
      const c = t.charCodeAt(n - 1);
      if (c >= 0xd800 && c <= 0xdbff) t = t.slice(0, -1);
      return t + '…';
    };
    const clean = (s, n) => cut(String(s == null ? '' : s).replace(CTRL, ' ').replace(/\s+/g, ' ').trim(), n);
    const attr = (el, name) => Element.prototype.getAttribute.call(el, name);
    const all = selector => Array.from(Document.prototype.querySelectorAll.call(document, selector));
    const baseURI = Object.getOwnPropertyDescriptor(Node.prototype, 'baseURI').get.call(document);
    const textContent = Object.getOwnPropertyDescriptor(Node.prototype, 'textContent').get;
    const absolute = raw => {
      try {
        const u = new URL(String(raw).trim(), baseURI);
        return /^https?:$/.test(u.protocol) && u.href.length <= 1000 ? u.href : '';
      } catch (e) { return ''; }
    };
    const bag = () => Object.create(null);

    // Tags that repeat (several og:image) keep their values in a list; the bag has a size of its own.
    const add = (into, key, value, maxKeys) => {
      if (!key || !value) return;
      if (!(key in into)) {
        if (Object.keys(into).length < maxKeys) into[key] = value;
      } else if (Array.isArray(into[key])) {
        if (into[key].length < 10) into[key].push(value);
      } else {
        into[key] = [into[key], value];
      }
    };

    const named = bag(), og = bag(), twitter = bag();
    const PLAIN = {description: 500, author: 200, keywords: 300, robots: 100, 'theme-color': 40};
    for (const m of all('meta')) {
      const property = clean(attr(m, 'property'), 60).toLowerCase(), name = clean(attr(m, 'name'), 60).toLowerCase();
      const key = property || name;
      if (/^(og|article|book|profile|product|music|video):/.test(key)) add(og, key, clean(attr(m, 'content'), 500), 60);
      else if (/^twitter:/.test(key)) add(twitter, key, clean(attr(m, 'content'), 500), 40);
      else if (Object.prototype.hasOwnProperty.call(PLAIN, name)) add(named, name, clean(attr(m, 'content'), PLAIN[name]), 10);
    }

    let canonical = '';
    const alternates = [];
    for (const l of all('link[href]')) {
      const rel = clean(attr(l, 'rel'), 200).toLowerCase().split(' ').filter(Boolean);
      if (rel.includes('canonical')) {
        if (!canonical) canonical = absolute(attr(l, 'href'));
      } else if (rel.includes('alternate') && !rel.includes('stylesheet') && alternates.length < 25) {
        const href = absolute(attr(l, 'href'));
        if (!href) continue;
        const entry = bag();
        const type = clean(attr(l, 'type'), 100).toLowerCase(), lang = clean(attr(l, 'hreflang'), 35), title = clean(attr(l, 'title'), 200);
        if (type) entry.type = type;
        if (lang) entry.hreflang = lang;
        if (title) entry.title = title;
        entry.href = href;
        alternates.push(entry);
      }
    }

    // A JSON-LD block is cut by tiers (what a string, a list, an object and the depth may hold) until it is small enough.
    const TIERS = [{s: 500, a: 30, k: 40, d: 8}, {s: 200, a: 10, k: 25, d: 5}, {s: 80, a: 4, k: 12, d: 3}];
    const BLOCK_CHARS = 6000, MAX_BLOCKS = 8, RAW_CHARS = 200000;
    const shrink = (v, t, depth) => {
      if (typeof v === 'string') return clean(v, t.s);
      if (v === null || typeof v === 'number' || typeof v === 'boolean') return v;
      if (depth >= t.d) return '…';
      if (Array.isArray(v)) {
        const list = v.slice(0, t.a).map(x => shrink(x, t, depth + 1));
        if (v.length > t.a) list.push('…(' + (v.length - t.a) + ' more)');
        return list;
      }
      const out = bag(), keys = Object.keys(v);
      for (const k of keys.slice(0, t.k)) out[clean(k, 80)] = shrink(v[k], t, depth + 1);
      if (keys.length > t.k) out['…'] = (keys.length - t.k) + ' more';
      return out;
    };
    const jsonld = [];
    for (const s of all('script[type]')) {
      if (jsonld.length >= MAX_BLOCKS) break;
      if (attr(s, 'type').trim().toLowerCase() !== 'application/ld+json') continue;
      const raw = textContent.call(s);
      if (raw.length > RAW_CHARS) continue;
      let data;
      try { data = JSON.parse(raw); } catch (e) { continue; }
      if (typeof data !== 'object' || data === null) continue;
      let kept = null;
      for (const tier of TIERS) {
        const candidate = shrink(data, tier, 0);
        if (JSON.stringify(candidate).length <= BLOCK_CHARS) { kept = candidate; break; }
      }
      jsonld.push(kept || {'@truncated': cut(JSON.stringify(shrink(data, TIERS[2], 0)), 1500)});
    }

    const out = bag();
    const lang = clean(attr(document.documentElement, 'lang'), 35);
    if (lang) out.lang = lang;
    if (canonical) out.canonical = canonical;
    if (Object.keys(named).length) out.meta = named;
    if (Object.keys(og).length) out.opengraph = og;
    if (Object.keys(twitter).length) out.twitter = twitter;
    if (alternates.length) out.alternate = alternates;
    if (jsonld.length) out.jsonld = jsonld;

    const head = 'Title: ' + clean(document.title, 300) + '\nURL: ' + location.href + '\n\n--- Structured data (what the page says about itself) ---\n';
    if (!Object.keys(out).length) return head + '(none found)';
    let text = JSON.stringify(out);
    while (head.length + text.length > maxChars && out.jsonld && out.jsonld.length) {
      out.jsonld.pop();
      if (!out.jsonld.length) delete out.jsonld;
      text = JSON.stringify(out);
    }
    const room = Math.max(maxChars - head.length, 200);
    return head + (text.length > room ? text.slice(0, room) + '\n…(truncated)' : text);
    """#

    /// The Markdown versions the page offers (`<link rel="alternate" type="text/markdown">`, any letter case), as absolute addresses,
    /// with the page's own address. The app decides which of them is on the page's site.
    static let markdownAlternates = #"""
    const attr = (el, name) => Element.prototype.getAttribute.call(el, name);
    const baseURI = Object.getOwnPropertyDescriptor(Node.prototype, 'baseURI').get.call(document);
    const links = [];
    for (const l of Array.from(Document.prototype.querySelectorAll.call(document, 'link[href]'))) {
      const rel = (attr(l, 'rel') || '').toLowerCase().split(/\s+/);
      const type = (attr(l, 'type') || '').toLowerCase().split(';')[0].trim();
      if (!rel.includes('alternate') || type !== 'text/markdown' || links.length >= 5) continue;
      try {
        const u = new URL((attr(l, 'href') || '').trim(), baseURI);
        if (/^https?:$/.test(u.protocol)) links.push(u.href);
      } catch (e) {}
    }
    return JSON.stringify({url: location.href, links});
    """#

    /// Fetches the site's own Markdown version from inside the page: same origin only, with the page's cookies, at most five
    /// seconds and about a megabyte, a 200 with a text/markdown or text/plain body. Answers the page's usual header and the text,
    /// or "" when anything is not as asked, so that the page is converted instead. Arguments: `href`, `maxChars`.
    static let fetchMarkdown = #"""
    const CTRL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\u2028\u2029\u200b\u200e\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]/g;
    const MAX_BYTES = 1048576;
    let u;
    try { u = new URL(href); } catch (e) { return ''; }
    if (location.origin === 'null' || u.origin !== location.origin) return '';
    const control = new AbortController(), timer = setTimeout(() => control.abort(), 5000);
    let text = '';
    try {
      const res = await fetch(u.href, {credentials: 'same-origin', mode: 'same-origin', signal: control.signal, headers: {Accept: 'text/markdown, text/plain;q=0.5'}});
      const type = (res.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
      if (res.status !== 200 || (type !== 'text/markdown' && type !== 'text/plain') || !res.body) return '';
      if (new URL(res.url).origin !== location.origin) return '';
      const reader = res.body.getReader(), chunks = [];
      let total = 0;
      for (;;) {
        const {done, value} = await reader.read();
        if (done) break;
        const room = MAX_BYTES - total;
        chunks.push(value.length > room ? value.subarray(0, room) : value);
        total += Math.min(value.length, room);
        if (total >= MAX_BYTES) { reader.cancel().catch(() => {}); break; }
      }
      const bytes = new Uint8Array(total);
      let at = 0;
      for (const c of chunks) { bytes.set(c, at); at += c.length; }
      text = new TextDecoder('utf-8').decode(bytes);
    } catch (e) {
      return '';
    } finally {
      clearTimeout(timer);
    }
    text = text.replace(/\r\n?/g, '\n').replace(CTRL, '').trim();
    if (!text) return '';
    if (text.length > maxChars) text = text.slice(0, maxChars) + '\n…(truncated)';
    const title = document.title.replace(CTRL, ' ').replace(/\s+/g, ' ').trim().slice(0, 300);
    return 'Title: ' + title + '\nURL: ' + location.href + "\nSource: the site's own Markdown version, " + u.href + '\n\n--- Page Markdown ---\n' + text;
    """#

    /// The page's visible content as Markdown, by walking its DOM. Arguments: `maxChars`, and the tracking parameters to leave out of
    /// addresses: `names` (exact) and `prefixes`.
    static let readMarkdown = #"""
    const CTRL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\u2028\u2029\u200b\u200e\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]/g;
    const proto = (cls, name) => Object.getOwnPropertyDescriptor(cls.prototype, name).get;
    const kidsOf = proto(Node, 'childNodes'), typeOf = proto(Node, 'nodeType'), nameOf = proto(Element, 'localName');
    const dataOf = proto(CharacterData, 'data'), rootOf = proto(Element, 'shadowRoot'), baseOf = proto(Node, 'baseURI');
    const textOfNode = proto(Node, 'textContent');
    const attr = (el, name) => Element.prototype.getAttribute.call(el, name);
    const has = (el, name) => Element.prototype.hasAttribute.call(el, name);
    const assigned = slot => HTMLSlotElement.prototype.assignedNodes.call(slot, {flatten: true});
    const all = selector => Array.from(Document.prototype.querySelectorAll.call(document, selector));
    const BASE = baseOf.call(document);
    const trackingNames = new Set(names), trackingPrefixes = Array.from(prefixes);
    const squash = s => String(s == null ? '' : s).replace(CTRL, ' ').replace(/\s+/g, ' ').trim();

    const SKIP = new Set(['script', 'style', 'noscript', 'template', 'nav', 'aside', 'footer', 'svg', 'canvas', 'iframe', 'frame', 'frameset',
      'object', 'embed', 'audio', 'video', 'map', 'head', 'title', 'meta', 'link', 'base', 'button', 'input', 'select', 'textarea', 'option',
      'optgroup', 'datalist', 'dialog']);
    const INLINE = new Set(['a', 'abbr', 'acronym', 'b', 'bdi', 'bdo', 'big', 'br', 'cite', 'code', 'data', 'del', 'dfn', 'em', 'font', 'i', 'img',
      'ins', 'kbd', 'label', 'mark', 'q', 's', 'samp', 'small', 'span', 'strike', 'strong', 'sub', 'sup', 'time', 'tt', 'u', 'var', 'wbr', 'picture']);
    const BLOCK = new Set(['address', 'article', 'blockquote', 'body', 'caption', 'dd', 'details', 'div', 'dl', 'dt', 'fieldset', 'figcaption', 'figure',
      'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hgroup', 'hr', 'li', 'main', 'menu', 'ol', 'p', 'pre', 'section', 'summary', 'table',
      'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'ul']);
    const BOILER_ROLES = new Set(['navigation', 'complementary', 'contentinfo', 'banner', 'search', 'dialog', 'alertdialog']);
    const BOILER_WORDS = new Set(['cookie', 'cookies', 'cookie-banner', 'cookie-notice', 'cookie-consent', 'cookiebanner', 'cookie-bar', 'cc-window',
      'consent', 'consent-banner', 'gdpr', 'advert', 'advertisement', 'ads', 'ad', 'ad-container', 'ad-slot', 'adsbygoogle', 'sponsored', 'newsletter',
      'newsletter-signup', 'popup', 'skip-link', 'skip-to-content', 'skiplink', 'breadcrumb', 'breadcrumbs', 'social', 'social-share', 'share',
      'share-buttons', 'sharing', 'sidebar']);

    let produced = 0, visited = 0;
    const stop = () => produced > maxChars + 3000 || visited > 60000;

    const boilerplate = el => {
      const words = (attr(el, 'class') || '').toLowerCase().split(/\s+/);
      const id = (attr(el, 'id') || '').toLowerCase();
      return words.some(w => BOILER_WORDS.has(w)) || BOILER_WORDS.has(id);
    };
    // Whether an element is left out: not for reading, hidden, or boilerplate. Hidden is told by the attribute, by aria-hidden and by what
    // the page's styles make of it. A field that draws its text as dots holds a secret whatever it is called.
    const skipped = (el, name) => {
      visited++;
      if (SKIP.has(name)) return true;
      if ((has(el, 'hidden') && attr(el, 'hidden') !== 'until-found') || attr(el, 'aria-hidden') === 'true' || attr(el, 'aria-modal') === 'true') return true;
      if (BOILER_ROLES.has((attr(el, 'role') || '').toLowerCase()) || boilerplate(el)) return true;
      const style = getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return true;
      const dots = style.getPropertyValue('-webkit-text-security');
      return !!dots && dots !== 'none';
    };

    // The children of a node as they are drawn: an element with an open shadow tree shows that (its slots filled by the light children).
    const kids = node => {
      const out = [];
      const add = list => {
        for (const c of list) {
          if (typeOf.call(c) === 1 && nameOf.call(c) === 'slot') {
            const filled = assigned(c);
            add(filled.length ? filled : kidsOf.call(c));
          } else out.push(c);
        }
      };
      const root = typeOf.call(node) === 1 ? rootOf.call(node) : null;
      add(Array.from(kidsOf.call(root || node)));
      return out;
    };

    const textOf = node => dataOf.call(node).replace(CTRL, '').replace(/\u00a0/g, ' ').replace(/[ \t\r\n\f]+/g, ' ');
    const esc = s => s.replace(/([\\`*\[\]])/g, '\\$1').replace(/(?<![\p{L}\p{N}])_|_(?![\p{L}\p{N}])/gu, '\\_');
    const tidy = s => s.replace(/ {2,}/g, ' ').replace(/ *\n */g, '\n').replace(/\n{2,}/g, '\n').trim();
    const oneLine = s => s.replace(/\s+/g, ' ').trim();
    // A line that would be taken for markup when it only starts like it.
    const guard = s => /^(#{1,6}\s|>|[-+*]\s|\d+[.)]\s|(?:---|\*\*\*|___)\s*$|```|~~~)/.test(s) ? '\\' + s : s;
    const mark = (s, m) => {
      const parts = s.match(/^(\s*)([\s\S]*?)(\s*)$/);
      return parts[2] ? parts[1] + m + parts[2] + m + parts[3] : s;
    };
    const fence = (s, least) => '`'.repeat(Math.max(least, Math.max(0, ...(s.match(/`+/g) || []).map(r => r.length)) + 1));
    const codeSpan = raw => {
      const s = oneLine(raw);
      if (!s) return '';
      const f = fence(s, 1), pad = s.startsWith('`') || s.endsWith('`') ? ' ' : '';
      return f + pad + s + pad + f;
    };

    const isTracking = name => {
      let n = name;
      try { n = decodeURIComponent(name); } catch (e) {}
      n = n.toLowerCase();
      return trackingNames.has(n) || trackingPrefixes.some(p => n.startsWith(p));
    };
    // An address as the reader gets it: without tracking parameters, with its fragment. Only web, mail and phone links count.
    const linkUrl = el => {
      const raw = attr(el, 'href');
      if (!raw || !raw.trim()) return '';
      let u;
      try { u = new URL(raw.trim(), BASE); } catch (e) { return ''; }
      if (!/^(https?|mailto|tel):$/.test(u.protocol)) return '';
      if (/^https?:$/.test(u.protocol) && u.search) {
        const items = u.search.slice(1).split('&'), kept = items.filter(i => !isTracking(i.split('=')[0]));
        if (kept.length !== items.length) u.search = kept.length ? '?' + kept.join('&') : '';
      }
      // Long pages are mostly links, so one on this site is written as its path (and one on this page as its fragment): the URL line says where they start.
      const here = u.origin === location.origin && !u.pathname.startsWith('//');
      const onPage = here && u.hash && u.pathname === location.pathname && u.search === location.search;
      const shown = onPage ? u.hash : here ? u.pathname + u.search + u.hash : u.href;
      return shown.replace(/\(/g, '%28').replace(/\)/g, '%29');
    };
    const link = (text, href) => {
      const parts = text.match(/^(\s*)([\s\S]*?)(\s*)$/);
      return parts[2] ? parts[1] + '[' + parts[2].replace(/\s*\n\s*/g, ' ') + '](' + href + ')' + parts[3] : text;
    };
    const wrap = (text, st) => st.href ? link(text, st.href) : text;

    // Text with its line breaks kept, for code: no markup, no collapsing.
    const rawText = (node, depth = 0) => {
      let out = '';
      if (depth > 60) return out;
      for (const c of kids(node)) {
        const t = typeOf.call(c);
        if (t === 3) { out += dataOf.call(c).replace(CTRL, '').replace(/\u00a0/g, ' '); continue; }
        if (t !== 1) continue;
        const name = nameOf.call(c);
        if (SKIP.has(name) || has(c, 'hidden') || attr(c, 'aria-hidden') === 'true') continue;
        if (name === 'br') { out += '\n'; continue; }
        out += rawText(c, depth + 1);
        if (/^(div|p|li|tr)$/.test(name) && !out.endsWith('\n')) out += '\n';
      }
      return out;
    };

    const inlineKids = (el, st) => kids(el).map(c => inline(c, st)).join('');
    function inline(node, st) {
      const t = typeOf.call(node);
      if (t === 3) return esc(textOf(node));
      if (t !== 1) return '';
      const name = nameOf.call(node);
      if (skipped(node, name)) return '';
      switch (name) {
        case 'br': return '\n';
        case 'img': { const alt = squash(attr(node, 'alt')); return alt ? esc(alt) : ''; }
        case 'code': case 'kbd': case 'samp': case 'tt': return codeSpan(rawText(node));
        case 'strong': case 'b': return mark(inlineKids(node, st), '**');
        case 'em': case 'i': case 'cite': return mark(inlineKids(node, st), '*');
        case 's': case 'del': case 'strike': return mark(inlineKids(node, st), '~~');
        case 'q': return '"' + inlineKids(node, st) + '"';
        case 'a': {
          const inner = inlineKids(node, {...st, linked: true});
          const href = st.linked ? '' : linkUrl(node);
          if (!href) return inner;
          if (inner.trim()) return link(inner, href);
          const label = squash(attr(node, 'aria-label') || attr(node, 'title'));
          return label ? link(esc(label), href) : '';
        }
        default: {
          const inner = inlineKids(node, st);
          return INLINE.has(name) ? inner : ' ' + inner + ' ';
        }
      }
    }

    const hasBlockChild = el => kids(el).some(c => typeOf.call(c) === 1 && !INLINE.has(nameOf.call(c)) && !SKIP.has(nameOf.call(c)));
    // A web component is inline until the page's styles say otherwise, but one that holds blocks is a container.
    const isInline = (el, name) => INLINE.has(name) || (!BLOCK.has(name) && getComputedStyle(el).display.startsWith('inline') && !hasBlockChild(el));

    // The blocks of an element's content: paragraphs of its inline runs, and what each block-level child makes.
    function blocks(parent, st, depth = 0) {
      const out = [];
      if (depth > 80) return out;
      let run = '';
      const flush = () => {
        const text = tidy(run);
        run = '';
        if (!text) return;
        produced += text.length;
        out.push({k: 'p', t: wrap(guard(text), st)});
      };
      for (const c of kids(parent)) {
        if (stop()) break;
        const type = typeOf.call(c);
        if (type === 3) { run += esc(textOf(c)); continue; }
        if (type !== 1) continue;
        const name = nameOf.call(c);
        if (skipped(c, name)) continue;
        if (name === 'a' && !st.linked && hasBlockChild(c)) {
          // A link around a card or a headline: the blocks inside it are linked one by one.
          flush();
          out.push(...blocks(c, {...st, linked: true, href: linkUrl(c)}, depth + 1));
        } else if (isInline(c, name)) {
          run += inline(c, st);
        } else {
          flush();
          out.push(...block(c, name, st, depth + 1));
        }
      }
      flush();
      return out;
    }

    function listBlock(el, name, st, depth) {
      const ordered = name === 'ol';
      let n = ordered ? (parseInt(attr(el, 'start'), 10) || 1) : 0;
      const items = [];
      const render = inner => {
        if (!inner.length) return;
        const marker = ordered ? (n++) + '. ' : '- ', pad = ' '.repeat(marker.length);
        let text = inner[0].t;
        for (let i = 1; i < inner.length; i++) text += (inner[i].k === 'list' && inner[i - 1].k === 'p' ? '\n' : '\n\n') + inner[i].t;
        items.push(text.split('\n').map((l, i) => i === 0 ? marker + l : l ? pad + l : '').join('\n'));
      };
      for (const c of kids(el)) {
        if (stop()) break;
        if (typeOf.call(c) !== 1) continue;
        const cname = nameOf.call(c);
        if (skipped(c, cname)) continue;
        if ((cname === 'ul' || cname === 'ol') && items.length) {
          const nested = listBlock(c, cname, st, depth + 1);
          if (nested.length) items[items.length - 1] += '\n' + nested[0].t.split('\n').map(l => '  ' + l).join('\n');
        } else {
          render(blocks(c, st, depth + 1));
        }
      }
      return items.length ? [{k: 'list', t: items.join('\n')}] : [];
    }

    function tableBlock(el, st, depth) {
      const role = (attr(el, 'role') || '').toLowerCase();
      if (role === 'presentation' || role === 'none') return blocks(el, st, depth);
      const rows = [];
      let caption = '';
      const walk = node => {
        for (const c of kids(node)) {
          if (typeOf.call(c) !== 1) continue;
          const cname = nameOf.call(c);
          if (skipped(c, cname)) continue;
          if (cname === 'caption') caption = oneLine(tidy(inlineKids(c, st)));
          else if (cname === 'tr') rows.push(c);
          else if (cname === 'thead' || cname === 'tbody' || cname === 'tfoot') walk(c);
        }
      };
      walk(el);
      const grid = [];
      for (const tr of rows.slice(0, 500)) {
        if (stop()) break;
        const cells = [];
        for (const c of kids(tr)) {
          if (typeOf.call(c) !== 1) continue;
          const cname = nameOf.call(c);
          if ((cname !== 'td' && cname !== 'th') || skipped(c, cname)) continue;
          cells.push(oneLine(inlineKids(c, st)).replace(/\|/g, '\\|'));
          for (let i = Math.min(parseInt(attr(c, 'colspan'), 10) || 1, 20); i > 1; i--) cells.push('');
        }
        if (cells.some(Boolean)) grid.push(cells.slice(0, 40));
      }
      if (!grid.length) return [];
      const width = Math.max(...grid.map(r => r.length));
      const out = caption ? [{k: 'p', t: caption}] : [];
      if (grid.length === 1 && width === 1) return out.concat([{k: 'p', t: guard(grid[0][0])}]);
      const line = r => '| ' + Array.from({length: width}, (_, i) => r[i] || '').join(' | ') + ' |';
      const text = [line(grid[0]), '|' + ' --- |'.repeat(width), ...grid.slice(1).map(line)].join('\n');
      produced += text.length;
      return out.concat([{k: 'other', t: text}]);
    }

    const languageOf = el => {
      const holders = [el, ...kids(el).filter(c => typeOf.call(c) === 1 && nameOf.call(c) === 'code')];
      for (const h of holders) {
        for (const word of (attr(h, 'class') || '').split(/\s+/)) {
          const m = word.match(/^(?:language|lang)-(.+)$/i);
          if (m) return m[1].replace(/[^A-Za-z0-9_+#.-]/g, '').slice(0, 30);
        }
        const given = attr(h, 'data-lang') || attr(h, 'data-language');
        if (given) return given.replace(/[^A-Za-z0-9_+#.-]/g, '').slice(0, 30);
      }
      return '';
    };

    function block(el, name, st, depth) {
      if (/^h[1-6]$/.test(name)) {
        const text = oneLine(tidy(inlineKids(el, st)));
        if (!text) return [];
        produced += text.length;
        return [{k: 'p', t: '#'.repeat(+name[1]) + ' ' + wrap(text, st)}];
      }
      switch (name) {
        case 'ul': case 'ol': case 'menu': return listBlock(el, name === 'menu' ? 'ul' : name, st, depth);
        case 'table': return tableBlock(el, st, depth);
        case 'hr': return [{k: 'other', t: '---'}];
        case 'blockquote': {
          const inner = blocks(el, st, depth);
          if (!inner.length) return [];
          return [{k: 'other', t: inner.map(b => b.t).join('\n\n').split('\n').map(l => l ? '> ' + l : '>').join('\n')}];
        }
        case 'pre': {
          const code = rawText(el).replace(/\r\n?/g, '\n').replace(/^\n/, '').replace(/\s+$/, '');
          if (!code.trim()) return [];
          const f = fence(code, 3);
          produced += code.length;
          return [{k: 'other', t: f + languageOf(el) + '\n' + code + '\n' + f}];
        }
        case 'dl': {
          const lines = [];
          const walk = node => {
            for (const c of kids(node)) {
              if (typeOf.call(c) !== 1) continue;
              const cname = nameOf.call(c);
              if (skipped(c, cname)) continue;
              if (cname === 'div') walk(c);
              else if (cname === 'dt') { const t = oneLine(tidy(inlineKids(c, st))); if (t) lines.push(mark(t, '**')); }
              else if (cname === 'dd') { const t = oneLine(tidy(inlineKids(c, st))); if (t) lines.push(': ' + t); }
            }
          };
          walk(el);
          return lines.length ? [{k: 'other', t: lines.join('\n')}] : [];
        }
        case 'details': {
          if (has(el, 'open')) return blocks(el, st, depth);
          const summary = kids(el).find(c => typeOf.call(c) === 1 && nameOf.call(c) === 'summary');
          return summary ? blocks(summary, st, depth) : [];
        }
        default: return blocks(el, st, depth);
      }
    }

    // The part of the page that is the content: <main>, or the one <article>, else the body.
    const body = document.body || document.documentElement;
    const shown = el => !!el && getComputedStyle(el).display !== 'none' && !has(el, 'hidden');
    let root = all('main, [role=main]').find(shown);
    if (!root) {
      const articles = all('article').filter(shown);
      if (articles.length === 1) root = articles[0];
    }
    if (!root || textOfNode.call(root).trim().length < 80) root = body;

    const md = blocks(root, {}).map(b => b.t).join('\n\n');
    let text = md.trim() ? md : '(no readable content found)';
    if (text.length > maxChars) {
      let cutAt = maxChars;
      const c = text.charCodeAt(cutAt - 1);
      if (c >= 0xd800 && c <= 0xdbff) cutAt--;
      text = text.slice(0, cutAt) + '\n…(truncated)';
    }
    return 'Title: ' + squash(document.title).slice(0, 300) + '\nURL: ' + location.href + '\n\n--- Page Markdown ---\n' + text;
    """#
}
