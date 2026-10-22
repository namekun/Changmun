import Foundation

/// The page scripts of the AI's tools that act on elements. They run in the isolated world like the others and share
/// `lib`: finding an element by its number or its place on the screen (also in frames of the same site), the pointer
/// and key events a real visit would produce, what an action would do (`factsOf`, which the approvals judge), and the
/// AI's mark drawn around what it is about to use.
///
/// What the page can't be allowed to change lives in the isolated world's memory, not in the page's DOM: the element
/// numbers (a map of weak references), the frame names, and the fields seen as passwords. Form properties are read
/// through the prototypes, because a field named "action" or "elements" replaces them on the form itself.
extension PageScripts {
    static let lib = #"""
    const registry = globalThis.changmunIds || (globalThis.changmunIds = new Map());
    const seenPasswords = globalThis.changmunPasswords || (globalThis.changmunPasswords = new WeakSet());
    const frameTags = globalThis.changmunFrames || (globalThis.changmunFrames = new WeakMap());
    const attr = (el, name) => Element.prototype.getAttribute.call(el, name);
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const norm = s => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();
    const squash = s => (s || '').replace(/\s+/g, ' ').trim();
    const clip = (s, n) => squash(s).slice(0, n);
    // The fingerprint of what was judged is a hash of all of it, so that nothing past a cut can change unseen (SHA-256, in hex).
    const digest = text => {
      const bytes = new TextEncoder().encode(text), n = bytes.length;
      const w = new Uint32Array(((n + 9 + 63) >> 6) << 4);
      for (let i = 0; i < n; i++) w[i >> 2] |= bytes[i] << (24 - (i & 3) * 8);
      w[n >> 2] |= 0x80 << (24 - (n & 3) * 8);
      w[w.length - 2] = Math.floor(n * 8 / 4294967296);
      w[w.length - 1] = (n * 8) >>> 0;
      const primes = [];
      for (let q = 2; primes.length < 64; q++) if (primes.every(r => q % r)) primes.push(q);
      const fraction = x => Math.floor((x % 1) * 4294967296);
      const K = primes.map(r => fraction(Math.cbrt(r))), H = primes.slice(0, 8).map(r => fraction(Math.sqrt(r)));
      const rotr = (x, k) => (x >>> k) | (x << (32 - k));
      for (let o = 0; o < w.length; o += 16) {
        const x = new Uint32Array(64);
        x.set(w.subarray(o, o + 16));
        for (let i = 16; i < 64; i++) {
          const a = x[i - 15], b = x[i - 2];
          x[i] = x[i - 16] + (rotr(a, 7) ^ rotr(a, 18) ^ (a >>> 3)) + x[i - 7] + (rotr(b, 17) ^ rotr(b, 19) ^ (b >>> 10));
        }
        let [a, b, c, d, e, f, g, h] = H;
        for (let i = 0; i < 64; i++) {
          const t1 = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + x[i];
          const t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
          h = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
        }
        [a, b, c, d, e, f, g, h].forEach((v, i) => { H[i] = (H[i] + v) >>> 0; });
      }
      return H.map(v => v.toString(16).padStart(8, '0')).join('');
    };
    const token = n => Array.from(crypto.getRandomValues(new Uint8Array(n)), b => b.toString(16).padStart(2, '0')).join('');

    // A field that holds a secret: a password (also after a "show password" button made it plain text), a code sent to the
    // user, or card details. The AI never gets such a value, and never types or presses keys in it.
    const SECRET_WORDS = /pass[-_ ]?(?:word|wd|code|phrase)|(?:^|[^a-z0-9])(?:pwd|pw|otp|pin|cvc|cvv|ssn)(?:[^a-z0-9]|$)|pin[-_ ]?code|card[-_ ]?(?:number|num|no)(?:[^a-z0-9]|$)|비밀번호|密码|密碼|パスワード|contrase[ñn]a|mot de passe|passwort|kennwort/i;
    // A name is looked at as it is written ("passWord", "PassCode") and told in words ("otpCode", "userPin" and "cvv2" are an otp, a pin and a cvv; "Shipping" is not a pin).
    const spaced = v => String(v || '').replace(/([a-z])([A-Z])/g, '$1 $2').replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2').replace(/([a-zA-Z])(\d)|(\d)([a-zA-Z])/g, '$1$3 $2$4');
    const SECRET_AUTOCOMPLETE = /one-time-code|(?:^|\s)cc-|current-password|new-password/i;
    const isSecret = el => {
      if (!el || el.nodeType !== 1) return false;
      if (el.localName === 'input' && el.type === 'password') { seenPasswords.add(el); return true; }
      if (seenPasswords.has(el) || el.hasAttribute('data-cm-secret') || SECRET_AUTOCOMPLETE.test(attr(el, 'autocomplete') || '')) return true;
      // Whatever the page draws as dots is a secret to it, whatever the field is called.
      const hidden = viewOf(el).getComputedStyle(el).getPropertyValue('-webkit-text-security');
      if (hidden && hidden !== 'none') return true;
      if (!/^(input|textarea)$/.test(el.localName)) return false;
      if ([el.name, el.id, attr(el, 'aria-label'), attr(el, 'placeholder')].some(v => SECRET_WORDS.test(String(v || '')) || SECRET_WORDS.test(spaced(v)))) return true;
      // Called a password by its label (the words beside it), for a field that takes text.
      return el.localName === 'textarea' || !/^(checkbox|radio|button|submit|reset|image|file|hidden|range|color)$/.test(el.type)
        ? Array.from(el.labels || []).some(l => SECRET_WORDS.test(String(l.textContent || '').slice(0, 200)) || SECRET_WORDS.test(spaced(String(l.textContent || '').slice(0, 200)))) : false;
    };

    // This document and the frames of the same site in it. dx, dy and s say where a frame's top left sits in this
    // document's viewport and how much a pixel of the frame is worth there (frames can be scaled).
    function docs(root = document, frame = null, dx = 0, dy = 0, s = 1, depth = 0, out = []) {
      out.push({doc: root, frame, dx, dy, s});
      if (depth < 4) for (const f of root.querySelectorAll('iframe,frame')) {
        let d = null;
        try { d = f.contentDocument; } catch (e) {}
        if (!d || !d.documentElement) continue;
        const r = f.getBoundingClientRect();
        const k = f.clientWidth ? r.width / f.clientWidth : 1;
        docs(d, f, dx + s * (r.left + f.clientLeft * k), dy + s * (r.top + f.clientTop * k), s * k, depth + 1, out);
      }
      return out;
    }
    // Everything that matches, also inside the (open) shadow trees of web components.
    function deepAll(root, selector, out = [], depth = 0) {
      out.push(...root.querySelectorAll(selector));
      if (depth < 4) for (const host of root.querySelectorAll('*')) if (host.shadowRoot) deepAll(host.shadowRoot, selector, out, depth + 1);
      return out;
    }
    // Every password field there is, also in web components, is known as one from the start: it stays secret when a button
    // makes it show its text.
    for (const e of docs()) for (const x of deepAll(e.doc, 'input[type=password]')) seenPasswords.add(x);
    const byId = id => {
      const ref = registry.get(id), el = ref && ref.deref();
      return el && el.isConnected ? el : null;
    };
    const where = el => docs().find(e => e.doc === el.ownerDocument) || {dx: 0, dy: 0, s: 1};
    const focusable = el => el.closest('a[href],button,input,select,summary,textarea,[tabindex],[contenteditable]') || el;
    // A form, or the document, with a field named "ownerDocument", "baseURI" or "defaultView" has that field there instead:
    // what the approvals rely on is read through the prototypes.
    const protoGet = (cls, name, node) => Object.getOwnPropertyDescriptor(cls.prototype, name).get.call(node);
    const docOf = node => protoGet(Node, 'ownerDocument', node);
    const baseOf = node => protoGet(Node, 'baseURI', node);
    const viewOf = node => protoGet(Document, 'defaultView', docOf(node));
    const originOf = el => String(viewOf(el).origin || 'null');

    // Forms: the properties a field of that name would replace are read from the prototypes.
    const formEls = f => Array.from(Object.getOwnPropertyDescriptor(HTMLFormElement.prototype, 'elements').get.call(f));
    const submitForm = f => HTMLFormElement.prototype.requestSubmit.call(f);
    const defaultButton = f => formEls(f).find(b => b.type === 'submit' || b.type === 'image');
    const textInputs = f => formEls(f).filter(x => x.localName === 'input' && /^(text|search|url|tel|email|password|number|date|)$/.test(x.type));
    const resolveUrl = (raw, node) => { try { return new URL(raw, baseOf(node)).href; } catch (e) { return ''; } };
    const actionOf = (f, submitter) => resolveUrl((submitter && attr(submitter, 'formaction')) ?? attr(f, 'action') ?? '', f);
    // What Enter in a field does when the page leaves it alone: press the form's default button, or submit the form
    // (with no button: when it has one text field, or when text is typed into it by the tool).
    function enterEffect(el, typing) {
      const f = el.form;
      if (!f) return {};
      const b = defaultButton(f);
      if (b) return b.disabled ? {} : {button: b};
      return typing || textInputs(f).length <= 1 ? {submit: true} : {};
    }

    function labelOf(el) {
      const tag = el.localName;
      const isButtonInput = tag === 'input' && /^(submit|button|reset)$/.test(el.type);
      const raw = attr(el, 'aria-label') || (tag === 'input' || tag === 'textarea' || tag === 'select' ? '' : el.innerText)
        || (isButtonInput ? el.value : '') || (el.labels && el.labels[0] ? el.labels[0].innerText : '') || attr(el, 'placeholder') || attr(el, 'title') || attr(el, 'alt') || attr(el, 'name') || '';
      return clip(raw, 80);
    }
    const describe = el => {
      const tag = el.localName;
      const kind = attr(el, 'role') || (tag === 'input' ? 'input[' + (el.type || 'text') + ']' : tag);
      return isSecret(el) ? kind + ' (password field)' : kind + ' "' + labelOf(el) + '"';
    };

    // What an action on an element is called by the page, for the approvals: every name it has (the label the user
    // sees, the accessible name, the picture's alt, the title), whole. A big container's text is the page's, not a name.
    const CONTROL = 'button,a[href],input,select,textarea,summary,label,[onclick],[contenteditable=true],[contenteditable=""],[role=button],[role=link],[role=menuitem],[role=menuitemcheckbox],[role=option],[role=tab],[role=switch],[role=checkbox],[role=combobox],[role=listbox],[role=textbox]';
    function controlOf(el) {
      // Up from the element, out of a shadow tree into the element that holds it, to the nearest control.
      for (let n = el; n; ) {
        const c = n.closest(CONTROL);
        if (c) return c;
        const root = n.getRootNode();
        n = root && root.host ? root.host : null;
      }
      // A div or span the page made clickable: the outermost element up from here that shows the hand cursor.
      const view = viewOf(el);
      let best = null;
      for (let n = el, i = 0; n && n.nodeType === 1 && n !== docOf(el).body && i < 6; n = n.parentElement, i++) {
        if (view.getComputedStyle(n).cursor === 'pointer') best = n; else if (best) break;
      }
      return best || el;
    }
    // Something made to be used: a control, or what shows the hand cursor. Anything else is a part of the page's own layout,
    // and what is inside it (a button somewhere in the body) isn't what clicking it does.
    const isReal = ctl => ctl.matches(CONTROL) || viewOf(ctl).getComputedStyle(ctl).cursor === 'pointer';
    // What only holds a value or a state (a field, a list, a checkbox, a label for one) does nothing by being used on its own
    // but take the focus or flip: what it is called says what it holds, not what it does. A click handler of the page's own
    // makes it an action again.
    const passive = ctl => {
      if (ctl.hasAttribute('onclick')) return false;
      const t = ctl.localName === 'label' ? ctl.control : ctl;
      if (!t || t.hasAttribute('onclick')) return false;
      return /^(textarea|select)$/.test(t.localName) || (t.localName === 'input' && /^(text|search|url|tel|email|password|number|date|datetime-local|month|week|time|color|range|file|checkbox|radio|)$/.test(t.type));
    };
    // A link that only goes somewhere: a navigation, named by its short text and nothing longer (a headline is not a name), and
    // judged by whole segments of its path. One with a handler of its own, or no address of its own, is a button by another name.
    const LINK_MAX = 40;
    const plainLink = ctl => ctl.localName === 'a' && !ctl.hasAttribute('onclick') && !/^(button|menuitem|menuitemcheckbox|option|tab|switch|checkbox)$/.test(attr(ctl, 'role') || '')
      && !/^(#|javascript:|$)/i.test((attr(ctl, 'href') || '').trim());
    // What says a lot even in a long sentence ("I agree to the terms and place my order"): a button, whole. A link around a
    // card of text says little of what it does: only its short names count.
    const WORDY = 'button,input,summary,[role=button],[role=menuitem],[role=menuitemcheckbox],[role=option],[role=tab],[role=switch]';
    // The words of an element that aren't those of a control inside it: a card's title, not the "Save" button on it.
    const ownText = el => {
      let out = '';
      for (const c of el.childNodes) {
        if (out.length > 2000) break;
        if (c.nodeType === 3) out += c.data;
        else if (c.nodeType === 1 && !c.matches(CONTROL)) out += ' ' + ownText(c) + ' ';
      }
      return out;
    };
    // The beginning of a long text: its first three words, or its first characters when it has no spaces.
    const lead = text => { const w = text.split(' '); return w.length > 1 ? w.slice(0, 3).join(' ') : text.slice(0, 4); };
    // The AI's own mark, which sits in the page's root while it shows, is no child of the page's.
    const kids = el => el.childElementCount - (globalThis.changmunMark && globalThis.changmunMark.host.parentElement === el ? 1 : 0);
    function namesOf(ctl) {
      const out = [];
      if (passive(ctl)) return out;
      const link = plainLink(ctl);
      const add = s => { s = squash(s); if (s && !(link && s.length > LINK_MAX)) out.push(s.slice(0, 20000)); };
      const doc = docOf(ctl);
      const acts = ctl.matches(WORDY);
      add(attr(ctl, 'aria-label'));
      for (const id of (attr(ctl, 'aria-labelledby') || '').split(/\s+/)) if (id) { const n = Document.prototype.getElementById.call(doc, id); if (n) add(n.textContent); }
      add(attr(ctl, 'title'));
      add(attr(ctl, 'alt'));
      if (ctl.localName === 'input' && /^(submit|button|reset|image)$/.test(ctl.type)) add(ctl.value);
      if (ctl.labels && ctl.labels.length) add(ctl.labels[0].textContent);
      if (!/^(input|textarea|select)$/.test(ctl.localName)) {
        const text = squash(ctl.matches(WORDY) ? ctl.innerText || ctl.textContent : ownText(ctl));
        const room = link ? LINK_MAX : acts ? 1000 : ctl.matches(CONTROL) ? 160 : (kids(ctl) <= 2 ? 40 : 0);
        if (text && text.length <= room) add(text);
        else if (text && room && !link) add(lead(text));
        // A web component's own words are in its shadow tree.
        if (ctl.shadowRoot) add(clip(ctl.shadowRoot.textContent, 160));
      }
      // What is inside is called what it is called by itself (a button in a card is not the card), except for an icon with no
      // words of its own, and a button, whose picture says what it does.
      if (isReal(ctl) && (!out.length || acts)) {
        for (const n of Array.from(ctl.querySelectorAll('img[alt],svg title,[aria-label],[title]')).slice(0, 6)) {
          const own = n.closest(CONTROL);
          if (own && own !== ctl) continue;
          add(attr(n, 'alt') || attr(n, 'aria-label') || attr(n, 'title') || n.textContent);
        }
      }
      return out;
    }
    // A control with no words at all (an icon) is told by its markup: class, id, name and data names, and the picture it shows.
    // What a drag drops onto is told by it too when it is no control (`force`): a bare div called "trash", and the element around it (`parent`).
    const words = s => String(s || '').slice(0, 200).replace(/([a-z])([A-Z])/g, '$1 $2').replace(/[^A-Za-zÀ-￿]+/g, ' ').trim().toLowerCase();
    const fileWords = (raw, node) => { if (/^data:/i.test(raw)) return ''; try { return words(new URL(raw, baseOf(node)).pathname.split('/').pop().replace(/\.[a-z0-9]+$/i, '')); } catch (e) { return ''; } };
    function hintsOf(ctl, force = false, parent = false) {
      if (!force && (!isReal(ctl) || passive(ctl) || namesOf(ctl).length)) return [];
      const out = [];
      const nodes = [ctl, ...Array.from(ctl.querySelectorAll('*')).slice(0, 8)];
      if (parent && ctl.parentElement && ctl.parentElement !== docOf(ctl).body) nodes.push(ctl.parentElement);
      const view = viewOf(ctl);
      for (const n of nodes) {
        out.push(words(attr(n, 'class')), words(attr(n, 'id')), words(attr(n, 'name')));
        for (const a of Array.from(n.attributes)) if (a.name.startsWith('data-')) out.push(words(a.name.slice(5) + ' ' + a.value));
        // The picture of an icon: a sprite symbol (<use href="#trash">), an image file (trash.svg), a background image.
        if (n.localName === 'use') out.push(words((attr(n, 'href') || attr(n, 'xlink:href') || '').replace(/^.*#/, '')));
        if (n.localName === 'img' && attr(n, 'src')) out.push(fileWords(attr(n, 'src'), n));
        const back = /url\(["']?([^"')]+)/.exec(view.getComputedStyle(n).backgroundImage || '');
        if (back) out.push(fileWords(back[1], n));
      }
      // Where a plain link goes is judged by its path, whole segment by segment, not by the words of a slug.
      const href = attr(ctl, 'href') || attr(ctl, 'formaction');
      if (href && !plainLink(ctl)) { try { out.push(words(new URL(href, baseOf(ctl)).pathname)); } catch (e) {} }
      return out.filter(Boolean).slice(0, 30);
    }
    // Where a control goes, whatever it is called: the path and query of its address (a link, a formaction) and a button's name and
    // value (<button name=action value=delete>). A query value counts when it is one short word.
    function destsOf(ctl) {
      const out = [];
      const url = raw => { try { const u = new URL(raw, baseOf(ctl)); return u.pathname + ' ' + Array.from(u.searchParams).map(([k, v]) => k + (/^[\w-]{1,20}$/.test(v) ? ' ' + v : '')).join(' '); } catch (e) { return ''; } };
      // A plain link is a navigation: only the path of its address says where it goes.
      const pathOf = raw => { try { return new URL(raw, baseOf(ctl)).pathname; } catch (e) { return ''; } };
      for (const name of ['href', 'formaction']) {
        const raw = (attr(ctl, name) || '').trim();
        if (raw && !/^#/.test(raw)) out.push(/^javascript:/i.test(raw) ? raw.slice(0, 300) : (name === 'href' && plainLink(ctl) ? pathOf(raw) : url(raw)).slice(0, 300));
      }
      if (ctl.localName === 'button' || (ctl.localName === 'input' && /^(submit|button|image)$/.test(ctl.type))) out.push(clip(attr(ctl, 'name'), 80), clip(attr(ctl, 'value'), 80));
      return out.filter(Boolean);
    }

    const PAY = '[autocomplete^="cc-"],[name*="card" i],[name*="cvc" i],[name*="cvv" i],[name*="iban" i],[name*="securitycode" i],[id*="card-number" i],[id*="cardnumber" i],[data-stripe]';
    const hasPayment = form => formEls(form).some(e => e.matches(PAY)) || !!Element.prototype.querySelector.call(form, PAY);
    const isRich = el => el.localName === 'textarea' || el.isContentEditable || attr(el, 'role') === 'textbox';
    // Somewhere the keyboard types or chooses: a text field, a text area, an editable element, a list.
    const editableKind = e => !!e && (e.localName === 'textarea' || e.localName === 'select' || e.isContentEditable || attr(e, 'role') === 'textbox'
      || (e.localName === 'input' && /^(text|search|url|tel|email|password|number|date|datetime-local|month|week|time|)$/.test(e.type)));
    // A cookie banner: the control's own name speaks of cookies (`cookie`), or it sits in the container of a known consent manager
    // (`banner`, which only the markup says, and which a page can fake with an id). That is what makes "Accept" and "Allow" a consent
    // to a banner and not a permission to something. The text around the control does not count: anyone can write "cookie" next to
    // an "Accept invitation" button.
    const COOKIE = /cookie|쿠키|クッキー|galleta|kekse|témoin|temoin/i;
    const CMP = '#onetrust-banner-sdk,#onetrust-consent-sdk,#CybotCookiebotDialog,#CybotCookiebotDialogBodyUnderlay,#didomi-host,#didomi-popup,.didomi-popup-container,'
      + '.qc-cmp2-container,#qc-cmp2-ui,#truste-consent-track,#teconsent,#consent_blackbar,.osano-cm-window,.osano-cm-dialog,.cky-consent-container,.cky-consent-bar,'
      + '#iubenda-cs-banner,.iubenda-cs-container,#usercentrics-root,#uc-center-container,[id^=sp_message_container],.cmpbox,#cmpbox';
    const namesCookies = ctl => [labelOf(ctl), ...namesOf(ctl)].some(t => COOKIE.test(t));
    function inConsentContainer(ctl) {
      // Up out of shadow trees too (a consent manager draws its banner in one).
      for (let n = ctl, i = 0; n && i < 60; i++) {
        if (n.nodeType === 1 && n.matches(CMP)) return true;
        const root = n.getRootNode && n.getRootNode();
        n = n.parentElement || (root && root.host) || null;
      }
      return false;
    }
    // The digits of a name are a count or a price that changes by itself on a page; for what asks every time they are kept.
    const mask = (text, exact) => exact ? text : text.replace(/\d+/g, '#');

    // Aims like the tools will, and says what the action would do. `key` is the key about to be pressed on it (with the modifiers
    // `mods`), `typing` says the text is typed by the tool (which sets the value, whatever the element is, then presses Enter and
    // submits any form around it), and `drop` that it is what a drag drops onto.
    function factsOf(el, args) {
      const ctl = controlOf(el);
      const form = ctl.form || el.closest('form');
      const role = attr(ctl, 'role') || '';
      const activates = /^(button|a|summary|label)$/.test(ctl.localName) || /^(submit|button|reset|image|checkbox|radio)$/.test(ctl.type || '')
        || /^(button|link|menuitem|menuitemcheckbox|option|tab|switch|checkbox)$/.test(role) || ctl.hasAttribute('onclick');
      // A browser doesn't toggle a checkbox or a radio button on Enter: it submits the form around it, as from any field.
      const toggles = /^(checkbox|radio)$/.test(ctl.type || '') && !ctl.hasAttribute('onclick');
      const mods = args.mods || {};
      const editable = editableKind(el) || editableKind(ctl);
      let names = namesOf(ctl), hints = hintsOf(ctl, !!args.drop, !!args.drop), dests = destsOf(ctl), label = labelOf(ctl);
      let submits = ctl.type === 'submit' || ctl.type === 'image', sends = false, keyRisk = false, submitter = submits ? ctl : null;
      if (args.key) {
        const key = args.key;
        // The tool types into anything it is pointed at and then presses Enter itself, so a button or a checkbox is a field here.
        if (args.typing || editable || (toggles && key === 'Enter')) {
          // Enter in a field sends what it holds: by the form's default button, or by submitting the form.
          names = []; hints = []; dests = []; submits = false; submitter = null;
          if (key === 'Enter' && (args.typing || ctl.localName !== 'select')) {
            const effect = enterEffect(args.typing ? el : ctl, !!args.typing);
            if (effect.button) { submits = true; submitter = effect.button; names = namesOf(submitter); hints = hintsOf(submitter); dests = destsOf(submitter); label = labelOf(submitter); }
            else if (effect.submit) submits = true;
          }
        } else if (key !== 'Enter' && key !== 'Space' && key !== 'Delete' && key !== 'Backspace') { names = []; hints = []; dests = []; }
        // A message box sends on Enter, whatever the form says: typed there by the tool or pressed by the AI (also with ctrl or meta).
        if (key === 'Enter' && (isRich(ctl) || (editable && (mods.ctrl || mods.meta)))) sends = true;
        // Delete and Backspace outside a text field, and any combination with ctrl or meta there, are for the page's own handlers
        // (delete this mail, undo, send): they act by themselves.
        if (!editable && (key === 'Delete' || key === 'Backspace' || mods.ctrl || mods.meta)) keyRisk = true;
      }
      const action = form ? actionOf(form, submitter) : '', payment = !!form && hasPayment(form), link = plainLink(ctl), cookie = namesCookies(ctl);
      const banner = !cookie && inConsentContainer(ctl);
      // Everything the approvals judged on is in the fingerprint: what the page may change while the user thinks (a checkout
      // step that appears under the same "Continue") must make the action stop.
      const print = exact => digest(JSON.stringify([ctl.localName, role, ctl.type || '', mask(names.join('|'), exact), hints.join('|'),
        mask(dests.join('|'), exact), submits, sends, payment, mask(action.replace(/[?#].*$/, ''), exact), !!form, link, keyRisk, cookie, banner]));
      return {label, names, hints, dests, submits, sends, payment, action, link, keyRisk, cookie, banner, secret: isSecret(ctl) || isSecret(el), description: describe(el), origin: originOf(el),
        fp: print(false), fpExact: print(true)};
    }
    // The page may change between looking and acting (and the user takes their time to answer): the action goes ahead
    // only on what was looked at.
    function stale(el, args) {
      if (!el.isConnected) return 'Error: the element is gone. Read the page again.';
      if (!args.expect) return null;
      const f = factsOf(el, args);
      // Only that it changed: what it changed into is the page's to say, and may be from another site.
      return f.origin === args.expect.origin && (args.expect.exact ? f.fpExact : f.fp) === args.expect.fp ? null : 'Error: the page changed since Changmun looked at it. Read the page again.';
    }

    // A frame of another site can't be reached from here. It gets a name the app uses to find it again, and is asked
    // (by a message only the app's own script in that frame understands) to report itself to the app, with a number
    // used once that only this script and the app know.
    function tagFrame(f) {
      let slot = frameTags.get(f);
      if (!slot) { slot = 'f' + token(6); frameTags.set(f, slot); }
      const nonce = token(16);
      try { f.contentWindow.postMessage({changmunFrame: slot, nonce}, '*'); } catch (e) {}
      return {slot, nonce};
    }
    const sameSite = f => { try { return !!(f.contentDocument && f.contentDocument.documentElement); } catch (e) { return false; } };

    // What a tool aims at: an element by its number, the one in focus, or the topmost one at a point of the viewport.
    // A point (or the focus) inside a frame of another site is handed over as {relay, x, y}, in that frame's pixels.
    function pick(args) {
      if (args.id != null) {
        const el = byId(args.id);
        return el ? {el} : {error: 'element ' + args.id + ' is gone. Read the page again.'};
      }
      if (args.active) {
        let d = document, a = d.activeElement;
        for (let depth = 0; depth < 5 && a && /^i?frame$/.test(a.localName); depth++) {
          if (!sameSite(a)) return {relay: tagFrame(a), active: true};
          d = a.contentDocument; a = d.activeElement;
        }
        return {el: a || d.body};
      }
      let doc = document, x = args.x, y = args.y;
      if (!(x >= 0 && y >= 0 && x < innerWidth && y < innerHeight)) {
        return {error: 'the point (' + x + ', ' + y + ') is outside the visible page, which is ' + innerWidth + 'x' + innerHeight + ' CSS pixels'};
      }
      for (let depth = 0; depth < 5; depth++) {
        let el = doc.elementFromPoint(x, y);
        if (!el) return {error: 'there is nothing at (' + args.x + ', ' + args.y + ')'};
        // The element in a web component's (open) shadow tree, not the element that holds the tree.
        for (let i = 0; i < 8 && el.shadowRoot; i++) {
          const inner = el.shadowRoot.elementFromPoint(x, y);
          if (!inner || inner === el) break;
          el = inner;
        }
        if (!/^i?frame$/.test(el.localName)) return {el, x, y};
        const r = el.getBoundingClientRect();
        const k = el.clientWidth ? r.width / el.clientWidth : 1;
        x = (x - r.left - el.clientLeft * k) / k;
        y = (y - r.top - el.clientTop * k) / k;
        if (!sameSite(el)) return {relay: tagFrame(el), x, y};
        doc = el.contentDocument;
      }
      return {error: 'frames are nested too deeply there'};
    }

    // The AI's mark: an outline with a small "AI" label around what it is about to use, drawn into a closed shadow
    // tree the page's own scripts and styles can't reach, never taking the pointer. It goes by itself soon after.
    function clearMark() {
      const m = globalThis.changmunMark;
      if (m) { clearTimeout(m.timer); m.host.remove(); globalThis.changmunMark = null; }
    }
    async function mark(els, hold = 350) {
      clearMark();
      if (document.visibilityState !== 'visible') return;
      const host = document.createElement('div');
      for (const [name, value] of [['all', 'initial'], ['position', 'fixed'], ['inset', '0'], ['pointer-events', 'none'], ['z-index', '2147483647']]) host.style.setProperty(name, value, 'important');
      const shadow = host.attachShadow({mode: 'closed'});
      const sheet = new CSSStyleSheet();
      const calm = matchMedia('(prefers-reduced-motion: reduce)').matches;
      sheet.replaceSync('.box { position: fixed; box-sizing: border-box; border: 2px solid #7c5cff; border-radius: 6px; background: rgba(124, 92, 255, .12);'
        + ' box-shadow: 0 0 0 3px rgba(124, 92, 255, .25);' + (calm ? '' : ' animation: pop .3s ease-out;') + ' }'
        + ' .tag { position: absolute; left: -2px; top: -22px; padding: 0 6px; border-radius: 4px; background: #7c5cff; color: #fff;'
        + ' font: 600 11px/18px -apple-system, system-ui, sans-serif; }'
        + ' @keyframes pop { from { transform: scale(1.08); } to { transform: none; } }');
      shadow.adoptedStyleSheets = [sheet];
      for (const el of els) {
        const r = el.getBoundingClientRect(), w = where(el);
        const box = document.createElement('div');
        box.className = 'box';
        box.style.left = (w.dx + w.s * r.left - 2) + 'px';
        box.style.top = (w.dy + w.s * r.top - 2) + 'px';
        box.style.width = Math.max(w.s * r.width, 6) + 'px';
        box.style.height = Math.max(w.s * r.height, 6) + 'px';
        const tag = document.createElement('div');
        tag.className = 'tag';
        tag.textContent = 'AI';
        if (w.dy + w.s * r.top < 26) tag.style.top = 'calc(100% + 2px)';
        box.append(tag);
        shadow.append(box);
      }
      document.documentElement.append(host);
      globalThis.changmunMark = {host, timer: setTimeout(clearMark, 3000)};
      await sleep(hold);
    }
    const settle = () => { const m = globalThis.changmunMark; if (m) { clearTimeout(m.timer); m.timer = setTimeout(clearMark, 600); } };
    // Outlines the targets, waits a moment, and says whether they are still what the AI looked at.
    async function aimAt(pairs, hold) {
      const stops = globalThis.changmunStops || 0;
      await mark(pairs.map(p => p.el), hold);
      if ((globalThis.changmunStops || 0) !== stops) return 'Error: stopped by the user.';
      for (const p of pairs) { const bad = stale(p.el, p.args); if (bad) return bad; }
      return null;
    }

    function fire(el, type, x, y, extra = {}) {
      const view = el.ownerDocument.defaultView;
      const pointer = type.startsWith('pointer');
      const init = {bubbles: !/enter$|leave$/.test(type), cancelable: !/enter$|leave$/.test(type), composed: true, view, clientX: x, clientY: y,
        screenX: x + (view.screenX || 0), screenY: y + (view.screenY || 0), button: 0, ...extra};
      if (pointer) Object.assign(init, {pointerId: 1, pointerType: 'mouse', isPrimary: true});
      return el.dispatchEvent(new (pointer ? view.PointerEvent : view.MouseEvent)(type, init));
    }
    function center(el) {
      const r = el.getBoundingClientRect();
      return [Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2)];
    }
    // The pointer going down on an element, as a mouse does it, and coming up again; `native` ends with the element's own
    // click (links and buttons then do exactly what a click does), else with a click event at the point.
    function pointerDown(el, x, y) {
      fire(el, 'pointerdown', x, y, {buttons: 1});
      fire(el, 'mousedown', x, y, {buttons: 1});
      focusable(el).focus({preventScroll: true});
    }
    function pointerUp(el, x, y) {
      fire(el, 'pointerup', x, y);
      fire(el, 'mouseup', x, y);
    }
    function pointerClick(el, x, y, native) {
      pointerDown(el, x, y);
      pointerUp(el, x, y);
      if (native) el.click(); else fire(el, 'click', x, y);
    }
    """#

    /// What read_page lists and how: the elements a person can use, each with its kind, name, value and states. Shared by the
    /// scripts that number elements.
    static let listing = #"""

    const SCAN_LIMIT = 1500;
    const selector = 'a[href],button,input,textarea,select,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=radio],[role=option],[role=switch],[role=combobox],[role=listbox],[role=textbox],[draggable=true],[contenteditable=""],[contenteditable=true],[onclick]';
    // Whether the element is one to list: it takes room on the page and is not hidden.
    const listed = (el, view) => {
      const r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) return false;
      const style = view.getComputedStyle(el);
      return style.visibility !== 'hidden' && style.display !== 'none' && el.type !== 'hidden';
    };
    // What an element shows of itself: its kind, its name, its value (never a secret's) and its states, as words.
    // A secret field shows no value and only the states that say nothing about what it holds.
    function infoOf(el) {
      const tag = el.localName, type = el.type || '', role = attr(el, 'role') || '', secret = isSecret(el);
      const isButtonInput = tag === 'input' && /^(submit|button|reset|image)$/.test(type);
      let kind = role || tag;
      if (tag === 'input') kind = 'input[' + (type || 'text') + ']';
      let value = null, options = null;
      if (!secret) {
        if ((tag === 'input' || tag === 'textarea') && !isButtonInput && !/^(checkbox|radio|file)$/.test(type) && el.value) value = clip(el.value, 60);
        if (tag === 'select' && el.selectedOptions[0]) {
          value = clip(el.selectedOptions[0].text, 40);
          options = Array.from(el.options).slice(0, 20).map(o => clip(o.text, 30));
        }
      }
      const states = [];
      const aria = name => attr(el, name);
      if (tag === 'input' && (type === 'checkbox' || type === 'radio')) states.push(el.indeterminate ? 'mixed' : el.checked ? 'checked' : 'unchecked');
      else if (/^(checkbox|radio|switch|menuitemcheckbox|menuitemradio)$/.test(role)) states.push(aria('aria-checked') === 'true' ? 'checked' : aria('aria-checked') === 'mixed' ? 'mixed' : 'unchecked');
      if (aria('aria-selected') === 'true') states.push('selected');
      if (aria('aria-expanded') === 'true') states.push('expanded');
      else if (aria('aria-expanded') === 'false') states.push('collapsed');
      else if (tag === 'summary' && el.parentElement && el.parentElement.localName === 'details') states.push(el.parentElement.open ? 'expanded' : 'collapsed');
      if (el.matches(':disabled') || aria('aria-disabled') === 'true') states.push('disabled');
      if (docOf(el).activeElement === el) states.push('focused');
      if (aria('aria-pressed') === 'true') states.push('pressed');
      if (el.required === true || aria('aria-required') === 'true') states.push('required');
      if (!secret) {
        const v = el.validity;
        if ((aria('aria-invalid') && aria('aria-invalid') !== 'false') || (el.willValidate && v && (v.badInput || v.typeMismatch || v.patternMismatch || v.rangeOverflow || v.rangeUnderflow || v.stepMismatch || v.tooLong || v.tooShort || v.customError))) states.push('invalid');
      }
      return {kind, label: labelOf(el), value, options, secret, states: secret ? states.filter(s => /^(disabled|focused|required)$/.test(s)) : states,
        href: tag === 'a' ? el.href.slice(0, 120) : null};
    }
    // The line the AI reads for an element: its number, kind and name, then its address or value, then its states.
    function lineOf(n, info, offscreen, framed) {
      let extra = '';
      if (info.href) extra = ' -> ' + info.href;
      if (info.secret) extra = ' (password field)';
      else if (info.options) extra = ' selected="' + info.value + '" options=[' + info.options.join(' | ') + ']';
      else if (info.value != null) extra = ' value="' + info.value + '"';
      return '[' + n + '] ' + info.kind + ' "' + info.label + '"' + extra + info.states.map(s => ' [' + s + ']').join('') + (offscreen ? ' (off screen)' : '') + (framed ? ' (in a frame)' : '');
    }
    """#

    /// The page's title, address, numbered interactive elements and text, as data. Also run in a frame of another site
    /// (by `start`, which numbers its elements on from the page's). The frames it can't enter are listed for the app.
    static let read = lib + listing + #"""

    registry.clear();
    // What the page looked like when it was read, to tell what an action changed: the info of each numbered element, and the
    // elements seen without being numbered (beyond the limit), which are not "new" later.
    const snap = globalThis.changmunSnap = new Map(), known = globalThis.changmunKnown = new WeakSet();
    const lines = [], frames = [];
    let n = start, capped = false, beyond = 0;
    for (const e of docs()) {
      const view = e.doc.defaultView;
      for (const el of e.doc.querySelectorAll(selector)) {
        if (!listed(el, view)) continue;
        if (n - start >= limit) { capped = true; if (++beyond > SCAN_LIMIT) break; known.add(el); continue; }
        registry.set(++n, new WeakRef(el));
        known.add(el);
        const r = el.getBoundingClientRect(), info = infoOf(el);
        snap.set(n, info);
        lines.push(lineOf(n, info, !(r.bottom > 0 && r.top < view.innerHeight), !!e.frame));
      }
      for (const f of e.doc.querySelectorAll('iframe,frame')) {
        const r = f.getBoundingClientRect();
        if (sameSite(f) || r.width < 20 || r.height < 20 || e.doc.defaultView.getComputedStyle(f).visibility === 'hidden') continue;
        frames.push({...tagFrame(f), src: f.src || attr(f, 'src') || '', title: f.title || f.name || ''});
      }
    }
    const textOf = d => (d.body ? d.body.innerText : '').replace(/\n{3,}/g, '\n\n');
    let text = textOf(document);
    if (text.length > maxChars) text = text.slice(0, maxChars) + '\n…(truncated)';
    for (const e of docs().slice(1)) {
      text += '\n\n--- Frame: ' + e.doc.URL + ' ---\n' + clip(textOf(e.doc), 3000);
    }
    return JSON.stringify({title: document.title, url: location.href, origin: String(window.origin || 'null'), scroll: Math.round(scrollY), height: document.documentElement.scrollHeight,
      viewport: innerHeight, lines, count: n, capped, text, frames});
    """#

    /// What an action changed in the page since the latest read (or the latest report of changes): the interactive elements that
    /// came, went or changed, compared by element and not by number. New ones are numbered on from `start`, so they work with the
    /// tools like the rest. At most `budget` lines are told (new ones first); the rest is counted. Run in the page and in every
    /// frame of another site that the latest read reached. `settle` is how long (at most) to wait for the page to stop changing.
    static let changes = lib + listing + #"""

    if (!globalThis.changmunSnap) return JSON.stringify({navigated: true});
    if (args.settle) await new Promise(resolve => {
      let idle, cap;
      const watch = new MutationObserver(() => { clearTimeout(idle); idle = setTimeout(done, 150); });
      const done = () => { watch.disconnect(); clearTimeout(idle); clearTimeout(cap); resolve(); };
      watch.observe(document, {childList: true, subtree: true, attributes: true, characterData: true});
      idle = setTimeout(done, 150);
      cap = setTimeout(done, args.settle);
    });
    const snap = globalThis.changmunSnap, known = globalThis.changmunKnown;
    const nowAt = new Map(), order = [];
    let scanned = 0;
    for (const e of docs()) {
      const view = e.doc.defaultView;
      for (const el of e.doc.querySelectorAll(selector)) {
        if (!listed(el, view)) continue;
        if (++scanned > SCAN_LIMIT) break;
        nowAt.set(el, e);
        order.push(el);
      }
    }
    const byEl = new Map();
    for (const [id, ref] of registry) { const el = ref.deref(); if (el) byEl.set(el, id); }
    const ids = [...registry.keys()].sort((a, b) => a - b);
    const gone = [], changed = [], fresh = [];
    for (const id of ids) {
      const el = registry.get(id).deref();
      if (!el || !nowAt.has(el)) { gone.push(id); continue; }
      const was = snap.get(id), now = infoOf(el);
      const parts = [];
      const show = v => v == null ? '(empty)' : '"' + v + '"';
      if (was.label !== now.label) parts.push('name "' + was.label + '" → "' + now.label + '"');
      if (was.value !== now.value) parts.push('value ' + show(was.value) + ' → ' + show(now.value));
      const gained = now.states.filter(s => !was.states.includes(s)), lost = was.states.filter(s => !now.states.includes(s));
      const group = [['checked', 'unchecked', 'mixed'], ['expanded', 'collapsed']];
      const swapped = s => group.some(g => g.includes(s) && gained.some(t => g.includes(t)));
      for (const s of gained) parts.push('now [' + s + ']');
      for (const s of lost) if (!swapped(s)) parts.push('no longer [' + s + ']');
      if (parts.length) changed.push({id, el, now, text: '~ [' + id + '] ' + now.kind + ' "' + now.label + '": ' + parts.join('; ')});
    }
    for (const el of order) if (!byEl.has(el) && !known.has(el)) fresh.push(el);
    let budget = args.budget, next = args.start, more = 0, added = 0;
    const out = [];
    for (const el of fresh) {
      if (budget <= 0) { more++; continue; }
      budget--;
      const id = ++next, info = infoOf(el), e = nowAt.get(el), r = el.getBoundingClientRect();
      registry.set(id, new WeakRef(el));
      snap.set(id, info);
      known.add(el);
      added++;
      out.push('+ ' + lineOf(id, info, !(r.bottom > 0 && r.top < e.doc.defaultView.innerHeight), !!e.frame));
    }
    for (const c of changed) {
      if (budget <= 0) { more++; continue; }
      budget--;
      snap.set(c.id, c.now);
      out.push(c.text);
    }
    for (const id of gone) {
      if (budget <= 0) { more++; continue; }
      budget--;
      const was = snap.get(id), ref = registry.get(id), goneEl = ref && ref.deref();
      // No longer known as seen: a node the page reuses (a menu, a modal, an accordion toggled with display) that comes back is new again.
      if (goneEl) known.delete(goneEl);
      registry.delete(id);
      snap.delete(id);
      out.push('- [' + id + '] ' + was.kind + ' "' + was.label + '"');
    }
    return JSON.stringify({title: document.title, url: location.href, origin: String(window.origin || 'null'), lines: out, more, added});
    """#

    /// Aims like the tool will, and says what the action would do, without doing it: the element's name for the
    /// approvals and the AI's progress line, and what decides whether it looks irreversible.
    static let inspect = lib + #"""

    const p = pick(args);
    if (p.relay) return JSON.stringify({relay: p.relay.slot, nonce: p.relay.nonce, x: p.x, y: p.y, active: !!p.active});
    if (p.error) return 'Error: ' + p.error;
    return JSON.stringify(factsOf(p.el, args));
    """#

    static let click = lib + #"""

    const p = pick(args);
    if (p.error) return 'Error: ' + p.error;
    const el = p.el;
    let bad = stale(el, args);
    if (bad) return bad;
    el.scrollIntoView({block: 'center', inline: 'center'});
    bad = await aimAt([{el, args}]);
    if (bad) return bad;
    const [x, y] = center(el);
    pointerClick(el, x, y, true);
    settle();
    return 'ok';
    """#

    static let clickAt = lib + #"""

    const p = pick(args);
    if (p.error) return 'Error: ' + p.error;
    const el = p.el;
    let bad = stale(el, args);
    if (bad) return bad;
    bad = await aimAt([{el, args}]);
    if (bad) return bad;
    pointerClick(el, p.x, p.y, false);
    settle();
    return 'ok: ' + describe(el);
    """#

    static let type = lib + #"""

    const p = pick(args);
    if (p.error) return 'Error: ' + p.error;
    const el = p.el, text = args.text, doc = el.ownerDocument;
    if (isSecret(el)) return 'Error: Changmun does not let the AI type into password fields. Ask the user to.';
    if (el.localName === 'select') return 'Error: this is a list. Choose its option with select_option, which asks about the option.';
    let bad = stale(el, args);
    if (bad) return bad;
    el.scrollIntoView({block: 'center'});
    bad = await aimAt([{el, args}]);
    if (bad) return bad;
    el.focus();
    if (el.isContentEditable) {
      doc.execCommand('selectAll', false);
      doc.execCommand('insertText', false, text);
    } else {
      const proto = el.localName === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
      el.dispatchEvent(new Event('input', {bubbles: true}));
      el.dispatchEvent(new Event('change', {bubbles: true}));
    }
    if (args.submit) {
      // The page may have answered the typing by changing the form (a disabled Post button that is enabled now): what was approved
      // was what the form was before, so nothing is sent.
      const f = factsOf(el, args);
      if (f.origin !== args.expect.origin || (args.expect.exact ? f.fpExact : f.fp) !== args.expect.fp) {
        settle();
        return 'Error: the page changed after the text was typed, so Changmun did not press Enter. Read the page again to see what it is now.';
      }
      const key = {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true};
      // As a browser does it: the form is sent only if the page left the key alone (a keydown or a keypress it cancelled stops
      // that) and didn't click or submit anything itself because of it.
      let mine = false, browser = false;
      const watch = () => { if (!mine) browser = true; };
      doc.addEventListener('click', watch, true);
      doc.addEventListener('submit', watch, true);
      let go = el.dispatchEvent(new KeyboardEvent('keydown', key));
      if (go) go = el.dispatchEvent(new KeyboardEvent('keypress', {...key, charCode: 13}));
      if (go && !browser) {
        // The same rule the approvals judged: the form's default button is pressed, or any form around the field is submitted.
        mine = true;
        const effect = enterEffect(el, true);
        if (effect.button) effect.button.click(); else if (effect.submit) submitForm(el.form);
      }
      el.dispatchEvent(new KeyboardEvent('keyup', key));
      doc.removeEventListener('click', watch, true);
      doc.removeEventListener('submit', watch, true);
    }
    settle();
    return 'ok';
    """#

    /// Chooses an option in stages, so that the app can judge the option itself before anything is changed: `resolve`
    /// says which option the words name (opening a list first, when `open` says it may) and what it is called and does,
    /// and `choose` picks it, but only if it is still the very option that was judged.
    static let selectOption = lib + #"""

    const p = pick(args);
    if (p.error) return 'Error: ' + p.error;
    const el = p.el;
    if (isSecret(el)) return 'Error: Changmun does not let the AI use password fields. Ask the user to.';
    let bad = stale(el, args);
    if (bad) return bad;
    const want = norm(args.option);
    const isNative = el.localName === 'select', role = attr(el, 'role');
    const openable = !isNative && role !== 'option' && (role === 'combobox' || role === 'listbox' || el.hasAttribute('aria-haspopup'));
    const pickBy = (items, textOf, valueOf) => {
      const live = items.filter(o => !o.disabled && attr(o, 'aria-disabled') !== 'true');
      const exact = live.filter(o => norm(textOf(o)) === want || (valueOf(o) != null && String(valueOf(o)) === args.option));
      const part = live.filter(o => norm(textOf(o)).includes(want));
      return exact[0] || (part.length === 1 ? part[0] : null);
    };
    const ariaText = o => attr(o, 'aria-label') || o.innerText || o.textContent;
    const visible = list => list.filter(o => o.getBoundingClientRect().height > 0);
    // ARIA: an option itself, a listbox, or a combobox whose list (aria-controls/aria-owns) may need opening first.
    const listOf = (anywhere) => {
      if (role === 'option') return [el];
      let box = el;
      if (role === 'combobox') {
        const ids = (attr(el, 'aria-controls') || attr(el, 'aria-owns') || '').split(/\s+/).filter(Boolean);
        box = ids.map(i => el.ownerDocument.getElementById(i)).find(Boolean) || null;
      }
      const own = box ? visible(Array.from(box.querySelectorAll('[role=option]'))) : [];
      return own.length || !anywhere ? own : visible(Array.from(el.ownerDocument.querySelectorAll('[role=listbox] [role=option]')));
    };
    const find = anywhere => {
      const options = isNative ? Array.from(el.options) : listOf(anywhere);
      const o = isNative ? pickBy(options, o => o.text, o => o.value) : pickBy(options, ariaText, o => attr(o, 'data-value') ?? attr(o, 'value'));
      return {options, o, label: o ? squash(isNative ? o.text : ariaText(o)) : ''};
    };
    // What the option is called, by every name its markup gives it (not only the words it shows), and what choosing it does: a
    // native list that submits its form when it changes (an onchange handler) takes the form's payment and address along.
    const wordsOf = o => isNative ? [o.text, o.label, attr(o, 'title'), o.value] : [...namesOf(o), attr(o, 'data-value') ?? attr(o, 'value')];
    const optionNames = o => wordsOf(o).map(squash).filter(Boolean).map(w => w.slice(0, 20000));
    // The option is always judged by every name it has. A native list in a form is taken to submit it when it changes: a page can
    // make it so in more ways than one (an onchange handler, a listener, the form's own), so the form's card details and
    // checkout-like address decide, as for a submit button. A list in no form (a menu for the page's own scripts) just acts.
    const submits = isNative && !!el.form;
    const optionAction = submits ? actionOf(el.form, null).replace(/[?#].*$/, '').replace(/\d+/g, '#') : '';
    const optionFp = (o, exact) => digest(JSON.stringify([isNative, isNative ? o.index : listOf(true).indexOf(o), mask(optionNames(o).join('|'), exact), submits, submits && hasPayment(el.form), optionAction]));
    function optionFacts(o, label) {
      return {label, role: isNative ? 'option' : (attr(o, 'role') || 'option'), native: isNative, names: [label, ...optionNames(o)], hints: hintsOf(o, true),
        submits, payment: submits && hasPayment(el.form), action: submits ? actionOf(el.form, null) : '', fp: optionFp(o, false), fpExact: optionFp(o, true)};
    }
    const missing = f => 'Error: no option "' + args.option + '". Options: ' + f.options.map(o => clip(isNative ? o.text : ariaText(o), 40)).join(', ');

    if (args.stage === 'resolve') {
      let f = find(false);
      if (!f.options.length && openable) {
        if (!args.open) return JSON.stringify({needsOpen: true});
        el.scrollIntoView({block: 'center'});
        bad = await aimAt([{el, args}]);
        if (bad) return bad;
        const [x, y] = center(el);
        pointerClick(el, x, y, false);
        await sleep(250);
        f = find(true);
      }
      if (!f.options.length) return 'Error: this element has no options Changmun can see. If it is a custom menu, click it and read the page again.';
      if (!f.o) return missing(f);
      return JSON.stringify(optionFacts(f.o, f.label));
    }

    const f = find(true);
    if (!f.o || optionFp(f.o, !!args.expectExact) !== args.expectFp) return 'Error: the options changed since Changmun looked at them. Try again.';
    if (isNative) {
      el.scrollIntoView({block: 'center'});
      bad = await aimAt([{el, args}]);
      if (bad) return bad;
      el.focus();
      if (el.multiple) f.o.selected = true; else el.selectedIndex = f.o.index;
      el.dispatchEvent(new Event('input', {bubbles: true}));
      el.dispatchEvent(new Event('change', {bubbles: true}));
      settle();
      return 'ok: selected "' + f.label + '"' + (el.multiple ? ' (added to the selection)' : '');
    }
    f.o.scrollIntoView({block: 'nearest'});
    const [x, y] = center(f.o);
    pointerClick(f.o, x, y, false);
    settle();
    return 'ok: chose "' + clip(f.label, 60) + '"';
    """#

    static let hover = lib + #"""

    const p = pick(args);
    if (p.error) return 'Error: ' + p.error;
    const el = p.el;
    let bad = stale(el, args);
    if (bad) return bad;
    el.scrollIntoView({block: 'center', inline: 'center'});
    bad = await aimAt([{el, args}]);
    if (bad) return bad;
    const [x, y] = center(el);
    const chain = e => { const out = []; for (let n = e; n; n = n.parentElement) out.unshift(n); return out; };
    const before = globalThis.changmunHover;
    const now = chain(el);
    // Leave what the pointer was over and isn't over now, innermost first; then enter what is new, outermost first.
    if (before && before.isConnected && before !== el) {
      fire(before, 'pointerout', x, y); fire(before, 'mouseout', x, y);
      for (const n of chain(before).reverse()) if (!now.includes(n)) { fire(n, 'pointerleave', x, y); fire(n, 'mouseleave', x, y); }
    }
    const was = before && before.isConnected ? chain(before) : [];
    fire(el, 'pointerover', x, y); fire(el, 'mouseover', x, y);
    for (const n of now) if (!was.includes(n)) { fire(n, 'pointerenter', x, y); fire(n, 'mouseenter', x, y); }
    fire(el, 'pointermove', x, y); fire(el, 'mousemove', x, y);
    globalThis.changmunHover = el;
    settle();
    return 'ok: ' + describe(el);
    """#

    static let drag = lib + #"""

    const a = pick(args.from), b = pick(args.to);
    if (a.error || b.error) return 'Error: ' + (a.error || b.error);
    const src = a.el, dst = b.el;
    if (isSecret(src) || isSecret(dst)) return 'Error: Changmun does not let the AI use password fields. Ask the user to.';
    let bad = stale(src, args.from) || stale(dst, args.to);
    if (bad) return bad;
    // A point is a place on the screen as it is now, so the page isn't moved for it.
    if (a.x == null) src.scrollIntoView({block: 'nearest', inline: 'nearest'});
    if (b.x == null) dst.scrollIntoView({block: 'nearest', inline: 'nearest'});
    bad = await aimAt([{el: src, args: args.from}, {el: dst, args: args.to}], 400);
    if (bad) return bad;
    const from = a.x == null ? center(src) : [a.x, a.y], to = b.x == null ? center(dst) : [b.x, b.y];
    const view = src.ownerDocument.defaultView;
    const dragEvent = (type, target, point, dt) => target.dispatchEvent(new view.DragEvent(type, {bubbles: true, cancelable: true, composed: true, view,
      clientX: point[0], clientY: point[1], dataTransfer: dt}));
    pointerDown(src, from[0], from[1]);
    let how;
    if (src.draggable && view.DataTransfer) {
      // HTML5 drag and drop: while it runs, browsers send no mouse events.
      const dt = new view.DataTransfer();
      if (!dragEvent('dragstart', src, from, dt)) { dragEvent('dragend', src, from, dt); settle(); return 'Error: the page cancelled the drag.'; }
      dragEvent('drag', src, from, dt);
      dragEvent('dragenter', dst, to, dt);
      const accepts = !dragEvent('dragover', dst, to, dt);
      if (accepts) dragEvent('drop', dst, to, dt); else dragEvent('dragleave', dst, to, dt);
      dragEvent('dragend', src, from, dt);
      how = accepts ? 'dropped' : 'let go, but the target does not accept drops';
    } else if (src.localName === 'input' && src.type === 'range') {
      // Mouse events don't move a native slider: its value is set from where the drag ends along it.
      const r = src.getBoundingClientRect(), min = Number(src.min) || 0, max = src.max === '' ? 100 : Number(src.max);
      const t = Math.min(1, Math.max(0, (to[0] - r.left) / Math.max(r.width, 1)));
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(src, String(min + t * (max - min)));
      src.dispatchEvent(new Event('input', {bubbles: true}));
      src.dispatchEvent(new Event('change', {bubbles: true}));
      pointerUp(src, to[0], to[1]);
      how = 'set the slider to ' + src.value;
    } else {
      // Pointer and mouse events along the way, for scripts that follow the pointer (sliders, sortable lists, maps).
      const steps = 8;
      for (let i = 1; i <= steps; i++) {
        const x = Math.round(from[0] + (to[0] - from[0]) * i / steps), y = Math.round(from[1] + (to[1] - from[1]) * i / steps);
        const over = i === steps ? dst : (src.ownerDocument.elementFromPoint(x, y) || src);
        fire(over, 'pointermove', x, y, {buttons: 1}); fire(over, 'mousemove', x, y, {buttons: 1});
        await sleep(20);
      }
      pointerUp(dst, to[0], to[1]);
      how = 'moved the pointer across and let go';
    }
    settle();
    return 'ok: ' + how;
    """#

    /// Whether the text is on the page (visible, in this document or a frame of the same site).
    static let hasText = lib + #"""

    const want = norm(args.text);
    const found = docs().some(e => norm(e.doc.body ? e.doc.body.innerText : '').includes(want));
    return JSON.stringify({found, origin: String(window.origin || 'null')});
    """#

    /// Takes the marks off, and ends what is waiting to act (the pause after an outline): the user pressed stop.
    static let clearMarks = lib + "\nglobalThis.changmunStops = (globalThis.changmunStops || 0) + 1;\nclearMark();\nreturn 'ok';"

    /// Finds the sign-in form's username and password fields (the form of the element given, else the page's visible password field)
    /// and, in the `fill` stage, puts a saved login in them, for the app, which is the only one that holds it. It says what it found
    /// and nothing of what it was given. Both fields are known as secrets from then on: their values are not read, typed over or
    /// shown in a picture.
    static let signIn = lib + #"""

    const all = (root, selector) => Array.from((root.nodeType === 9 ? Document.prototype : Element.prototype).querySelectorAll.call(root, selector));
    let el = null;
    if (args.id != null) {
      el = byId(args.id);
      if (!el) return JSON.stringify({error: 'gone'});
    }
    const doc = el ? docOf(el) : document;
    const visible = e => { const r = e.getBoundingClientRect(); return r.width >= 1 && r.height >= 1 && viewOf(e).getComputedStyle(e).visibility !== 'hidden'; };
    const usable = e => visible(e) && !e.disabled && !e.readOnly;
    const textual = e => e.localName === 'input' && /^(text|email|tel|)$/.test(e.type) && usable(e);
    let scope = el ? (el.form || el.closest('form') || doc) : doc;
    const pw = (el && el.localName === 'input' && el.type === 'password' && usable(el) ? el : null) || all(scope, 'input').find(e => e.type === 'password' && usable(e)) || null;
    if (pw && pw.form) scope = pw.form;
    const inputs = all(scope, 'input');
    let user = el && textual(el) ? el : null;
    if (!user && pw) user = inputs.filter(e => textual(e) && (e.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING)).pop() || null;
    if (!user && el) user = inputs.find(e => textual(e) && (attr(e, 'autocomplete') === 'username' || e.type === 'email')) || null;
    if (!pw && !user) return JSON.stringify({error: 'none'});
    if (!pw && !el) return JSON.stringify({error: 'none'});
    const form = (pw && pw.form) || (user && user.form) || (el && (el.form || el.closest('form'))) || null;
    const origin = originOf(pw || user);
    if (args.stage !== 'fill') return JSON.stringify({origin, user: !!user, password: !!pw, action: form ? actionOf(form, null) : ''});
    if (origin !== args.expectOrigin) return JSON.stringify({error: 'changed'});
    const set = (e, v) => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(e, v);
      e.dispatchEvent(new Event('input', {bubbles: true}));
      e.dispatchEvent(new Event('change', {bubbles: true}));
      seenPasswords.add(e);
    };
    if (user) set(user, args.username);
    if (pw) set(pw, args.password);
    return JSON.stringify({user: !!user, password: !!pw});
    """#

    /// Where each element the latest read numbered is in the visible page, for the boxes drawn on a picture: [number, x, y, width, height]
    /// in CSS pixels from the top left of this window's viewport (the part in view only), and where the frames of other sites sit in
    /// it (x, y and the scale of a frame's pixel), so that their own answers can be put in place. Nothing is added to the page.
    static let rects = lib + #"""

    const out = [];
    for (const [id, ref] of registry) {
      const el = ref.deref();
      if (!el || !el.isConnected) continue;
      const r = el.getBoundingClientRect(), w = where(el);
      let left = w.dx + w.s * r.left, top = w.dy + w.s * r.top, right = left + w.s * r.width, bottom = top + w.s * r.height;
      if (right <= 0 || bottom <= 0 || left >= innerWidth || top >= innerHeight) continue;
      left = Math.max(left, 0); top = Math.max(top, 0); right = Math.min(right, innerWidth); bottom = Math.min(bottom, innerHeight);
      out.push([id, left, top, right - left, bottom - top]);
    }
    const frames = {};
    for (const e of docs()) for (const f of e.doc.querySelectorAll('iframe,frame')) {
      const slot = frameTags.get(f);
      if (!slot) continue;
      const r = f.getBoundingClientRect(), k = f.clientWidth ? r.width / f.clientWidth : 1;
      frames[slot] = [e.dx + e.s * (r.left + f.clientLeft * k), e.dy + e.s * (r.top + f.clientTop * k), e.s * k];
    }
    return JSON.stringify({rects: out, frames});
    """#

    /// The frames of other sites that a picture of the page shows, greeted so that the app can ask each where it really is:
    /// also those in web components, and the documents of <object> and <embed>.
    static let visibleFrames = lib + #"""

    const out = [];
    for (const e of docs()) for (const f of deepAll(e.doc, 'iframe,frame,object,embed')) {
      const r = f.getBoundingClientRect();
      if (sameSite(f) || r.width < 20 || r.height < 20 || e.doc.defaultView.getComputedStyle(f).visibility === 'hidden') continue;
      out.push(tagFrame(f));
    }
    return JSON.stringify(out);
    """#

    static let origin = "return String(window.origin || 'null');"

    /// Makes every password field known as one from the moment its document begins to exist, in the isolated world like the other
    /// scripts: also one that is added later, and one the page turns into a plain text field before anything else looks.
    static let watchPasswords = #"""
    (() => {
      const seen = globalThis.changmunPasswords || (globalThis.changmunPasswords = new WeakSet());
      const take = node => {
        if (!node || node.nodeType !== 1) return;
        if (node.localName === 'input' && node.type === 'password') seen.add(node);
        for (const x of node.querySelectorAll('input[type=password]')) seen.add(x);
        if (node.shadowRoot) for (const x of node.shadowRoot.querySelectorAll('input[type=password]')) seen.add(x);
      };
      new MutationObserver(records => {
        for (const r of records) {
          if (r.type === 'attributes') {
            if (String(r.oldValue || '').toLowerCase() === 'password' && r.target.localName === 'input') seen.add(r.target);
            take(r.target);
          } else for (const n of r.addedNodes) take(n);
        }
      }).observe(document, {childList: true, subtree: true, attributes: true, attributeFilter: ['type'], attributeOldValue: true});
      take(document.documentElement);
    })();
    """#

    /// Hides the values of secret fields for the picture: a password shown by a "show" button, or a code, never gets out in it.
    static let maskSecrets = lib + #"""

    const masked = globalThis.changmunMasked || (globalThis.changmunMasked = []);
    for (const e of docs()) for (const el of deepAll(e.doc, 'input,textarea')) {
      if (!isSecret(el) || masked.some(m => m.el === el)) continue;
      masked.push({el, value: el.style.getPropertyValue('-webkit-text-security'), priority: el.style.getPropertyPriority('-webkit-text-security')});
      el.style.setProperty('-webkit-text-security', 'disc', 'important');
    }
    await Promise.race([new Promise(resolve => requestAnimationFrame(() => resolve())), sleep(150)]);
    return String(masked.length);
    """#

    static let unmaskSecrets = lib + #"""

    const masked = globalThis.changmunMasked || [];
    for (const m of masked) {
      if (m.value) m.el.style.setProperty('-webkit-text-security', m.value, m.priority); else m.el.style.removeProperty('-webkit-text-security');
    }
    globalThis.changmunMasked = [];
    return 'ok';
    """#

    static let pressKey = lib + #"""

    const KEYS = {Enter: 13, Escape: 27, Tab: 9, Backspace: 8, Delete: 46, Space: 32, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39,
      Home: 36, End: 35, PageUp: 33, PageDown: 34};
    const name = args.key, code = KEYS[name];
    if (!code) return 'Error: ' + name + ' is not a key the AI may press.';
    const mods = args.mods;
    const p = pick(args);
    if (p.error) return 'Error: ' + p.error;
    let target = p.el;
    if (isSecret(target)) return 'Error: Changmun does not let the AI press keys in password fields. Ask the user to.';
    let bad = stale(target, args);
    if (bad) return bad;
    const doc = target.ownerDocument, view = doc.defaultView;
    // A list is chosen from with select_option, which judges the option; the arrows would choose one unjudged.
    const selects = el => el.localName === 'select' && /^(ArrowUp|ArrowDown|ArrowLeft|ArrowRight|Home|End)$/.test(name);
    if (selects(target)) return 'Error: a list is chosen from with select_option, which asks about the option.';
    if (args.id != null) {
      target.scrollIntoView({block: 'center'});
      // Not a link around it that was not judged: the key goes to the control that was.
      const judged = controlOf(p.el);
      let f = focusable(target);
      if (controlOf(f) !== judged) f = judged;
      f.focus();
      // The key goes to what was judged: the element itself, or what inside it took the focus. Whatever else has the focus (an
      // autofocused button, a dialog's focus trap) is not what the AI named and not what was judged.
      const a = doc.activeElement;
      target = a && a !== f && f.contains(a) && controlOf(a) === controlOf(p.el) ? a : f;
      if (isSecret(target)) return 'Error: Changmun does not let the AI press keys in password fields. Ask the user to.';
      if (selects(target)) return 'Error: a list is chosen from with select_option, which asks about the option.';
    }
    if (target !== doc.body && target !== doc.documentElement) {
      bad = await aimAt([{el: p.el, args}]);
      if (bad) return bad;
    }

    const init = {key: name === 'Space' ? ' ' : name, code: name === 'Space' ? 'Space' : name, keyCode: code, which: code,
      shiftKey: !!mods.shift, altKey: !!mods.alt, ctrlKey: !!mods.ctrl, metaKey: !!mods.meta, bubbles: true, cancelable: true, composed: true, view};
    const plain = !mods.alt && !mods.ctrl && !mods.meta;
    // WebKit itself submits a form, or clicks a button or link, for a keypress of Enter that the page leaves alone. What
    // it does is seen here, so that the same is not done twice.
    let mine = false, browser = null;
    const watch = e => { if (!mine) browser = browser || e.type; };
    doc.addEventListener('click', watch, true);
    doc.addEventListener('submit', watch, true);
    const down = new view.KeyboardEvent('keydown', init);
    let go = target.dispatchEvent(down);
    const types = name === 'Enter' || name === 'Space';
    if (go && types) go = target.dispatchEvent(new view.KeyboardEvent('keypress', {...init, charCode: code}));
    let did = 'the page handled it';
    if (go && browser) did = 'the browser did its default (' + browser + ')';
    else if (go) did = ((el) => {
      mine = true;
      const local = el.localName, type = el.type || '';
      const textControl = local === 'textarea' || (local === 'input' && /^(text|search|url|tel|email|number|password|)$/.test(type));
      const editable = textControl || el.isContentEditable;
      const button = /^(button|a|summary)$/.test(local) || /^(submit|button|reset|image|checkbox|radio)$/.test(type)
        || /^(button|link|menuitem|menuitemcheckbox|option|tab|switch|checkbox)$/.test(attr(el, 'role') || '');
      // A browser doesn't toggle a checkbox or a radio button on Enter; it submits the form around it.
      const toggle = /^(checkbox|radio)$/.test(type);
      const edit = (command, value) => doc.execCommand(command, false, value);
      const scroll = (dx, dy) => { view.scrollBy(dx, dy); return 'scrolled the page'; };
      if (!plain && !(mods.shift && !mods.alt && !mods.ctrl && !mods.meta)) return 'nothing else (the page did not handle this combination)';
      switch (name) {
        case 'Enter':
          if ((button && !toggle) || (local === 'a' && el.href)) { el.click(); return 'activated it'; }
          if (editable && !textControl) { edit('insertLineBreak'); return 'inserted a line break'; }
          if (local === 'textarea') { edit('insertText', '\n'); return 'inserted a line break'; }
          if (local === 'input') {
            // What was judged: the form's own default button, or the form itself when it has no button and one text field.
            const effect = enterEffect(el, false);
            if (effect.button) { effect.button.click(); return 'clicked the form\'s submit button'; }
            if (effect.submit) { submitForm(el.form); return 'submitted the form'; }
            return el.form ? 'nothing (the form has no submit button)' : 'nothing (no form around the field)';
          }
          return 'nothing';
        case 'Escape': {
          const dialog = el.closest('dialog[open]') || doc.querySelector('dialog[open]');
          if (dialog && dialog.dispatchEvent(new view.Event('cancel', {cancelable: true}))) { dialog.close(); return 'closed the dialog'; }
          return 'nothing (no open dialog)';
        }
        case 'Tab': {
          const sel = 'a[href],button,input,select,textarea,summary,[tabindex],[contenteditable=""],[contenteditable=true]';
          const usable = Array.from(doc.querySelectorAll(sel)).filter(e => {
            if (e.disabled || e.tabIndex < 0 || e.type === 'hidden') return false;
            const r = e.getBoundingClientRect(), s = view.getComputedStyle(e);
            return r.width >= 1 && r.height >= 1 && s.visibility !== 'hidden' && s.display !== 'none';
          });
          const order = usable.filter(e => e.tabIndex > 0).sort((a, b) => a.tabIndex - b.tabIndex).concat(usable.filter(e => e.tabIndex === 0));
          if (!order.length) return 'nothing (nothing to focus)';
          const at = order.indexOf(el);
          const next = order[(at < 0 ? (mods.shift ? order.length - 1 : 0) : at + (mods.shift ? -1 : 1) + order.length) % order.length];
          next.focus();
          next.scrollIntoView({block: 'nearest'});
          return 'moved focus to ' + describe(next);
        }
        case 'Backspace': case 'Delete':
          if (!editable) return 'nothing (not in a text field)';
          edit(name === 'Backspace' ? 'delete' : 'forwardDelete');
          return 'deleted';
        case 'Space':
          if (textControl || el.isContentEditable) { edit('insertText', ' '); return 'typed a space'; }
          if (button) { el.click(); return 'activated it'; }
          if (local === 'select') return 'nothing';
          return scroll(0, (mods.shift ? -1 : 1) * view.innerHeight * 0.875);
        default: {
          if (textControl && el.selectionStart != null) {
            const v = el.value, a = el.selectionStart, b = el.selectionEnd, back = el.selectionDirection === 'backward';
            const focus = back ? a : b, anchor = back ? b : a;
            const lineStart = i => v.lastIndexOf('\n', i - 1) + 1;
            const lineEnd = i => { const j = v.indexOf('\n', i); return j < 0 ? v.length : j; };
            let to = focus;
            if (!mods.shift && a !== b && (name === 'ArrowLeft' || name === 'ArrowRight')) to = name === 'ArrowLeft' ? a : b;
            else if (name === 'ArrowLeft') to = Math.max(0, focus - 1);
            else if (name === 'ArrowRight') to = Math.min(v.length, focus + 1);
            else if (name === 'Home') to = lineStart(focus);
            else if (name === 'End') to = lineEnd(focus);
            else if (name === 'ArrowUp' || name === 'ArrowDown') {
              if (local !== 'textarea') to = name === 'ArrowUp' ? 0 : v.length;
              else if (name === 'ArrowUp') { const s = lineStart(focus); to = s === 0 ? 0 : Math.min(lineStart(s - 1) + focus - s, s - 1); }
              else { const e = lineEnd(focus); to = e >= v.length ? v.length : Math.min(e + 1 + focus - lineStart(focus), lineEnd(e + 1)); }
            } else return scroll(0, (name === 'PageUp' ? -1 : 1) * view.innerHeight * 0.875);
            if (mods.shift) el.setSelectionRange(Math.min(anchor, to), Math.max(anchor, to), to < anchor ? 'backward' : 'forward');
            else el.setSelectionRange(to, to);
            return 'moved the cursor';
          }
          if (el.isContentEditable && view.getSelection().modify) {
            const move = {ArrowLeft: ['left', 'character'], ArrowRight: ['right', 'character'], ArrowUp: ['backward', 'line'], ArrowDown: ['forward', 'line'],
              Home: ['backward', 'lineboundary'], End: ['forward', 'lineboundary']}[name];
            if (move) { view.getSelection().modify(mods.shift ? 'extend' : 'move', move[0], move[1]); return 'moved the cursor'; }
          }
          if (local === 'select') return 'nothing';
          const page = view.innerHeight * 0.875;
          const by = {ArrowUp: [0, -40], ArrowDown: [0, 40], ArrowLeft: [-40, 0], ArrowRight: [40, 0], PageUp: [0, -page], PageDown: [0, page]}[name];
          if (by) return scroll(...by);
          view.scrollTo(0, name === 'Home' ? 0 : doc.documentElement.scrollHeight);
          return 'scrolled the page';
        }
      }
    })(target);
    mine = false;
    target.dispatchEvent(new view.KeyboardEvent('keyup', init));
    doc.removeEventListener('click', watch, true);
    doc.removeEventListener('submit', watch, true);
    if (go && browser && did === 'the page handled it') did = 'the browser did its default (' + browser + ')';
    settle();
    return 'ok: ' + did;
    """#
}
