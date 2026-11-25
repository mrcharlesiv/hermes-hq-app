// [preview-tab] In-page automation engine and live visual overlay for Hermes's `drive_preview` and `annotate_preview`
// tools (`preview.act`), plus the subtle read-sweep cue for `desktop_preview action=read` (`preview.read`).
// Matches Hermes Desktop's ref naming (`btn-sign-in`, `inp-email`), delta protocol (`same`/`added`/`changed`/`removed`/
// `rebound`), React/contenteditable typing, and persistent element annotations while staying 100% CSP-safe (per-property
// inline styles + closed shadow root + popover="manual" top-layer fallback so page scripts and element scans never see it).

import Foundation

enum PreviewActEngine {
    /// Normalize what a person typed in the address bar into a loadable URL (or a web search query).
    static func normalizeAddress(_ raw: String, allowLoopback: Bool) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        // Never run script/data payloads from an address bar.
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:") { return nil }
        if lower == "about:blank" { return URL(string: "about:blank") }
        // Multi-word input or bare words with no dot/colon/localhost → web search.
        let looksLikeHost = trimmed.contains("://")
            || trimmed.contains(".")
            || PreviewTarget.isLoopback(trimmed)
        if trimmed.contains(" ") || !looksLikeHost {
            guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return URL(string: "https://www.google.com/search?q=\(encoded)")
        }
        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            let scheme = PreviewTarget.isLoopback(trimmed) ? "http://" : "https://"
            candidate = scheme + trimmed
        }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else {
            return nil
        }
        if !allowLoopback && PreviewTarget.isLoopback(host) { return nil }
        return url
    }

    /// Encode a failure answer in Hermes Desktop's `preview.act` JSON shape.
    static func errorJSON(_ message: String, url: String = "", title: String = "") -> String {
        encode(["success": false, "error": message, "url": url, "title": title])
    }

    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"success":false,"error":"Failed to encode browser response."}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Build a human-readable activity banner label for a `preview.act` call ("Hermes is scanning page…", etc.).
    static func statusSummary(action: String, target: String?, botName: String) -> String {
        let who = botName.isEmpty ? "Hermes" : botName
        switch action {
        case "elements": return "\(who) is inspecting the page…"
        case "click": return target.map { "\(who) clicked \($0)" } ?? "\(who) clicked an element"
        case "hover": return target.map { "\(who) hovered \($0)" } ?? "\(who) hovered an element"
        case "type": return target.map { "\(who) typed in \($0)" } ?? "\(who) typed in a field"
        case "press": return "\(who) pressed a key"
        case "scroll": return "\(who) scrolled the page"
        case "back": return "\(who) went back"
        case "forward": return "\(who) went forward"
        case "reload": return "\(who) reloaded the page"
        case "pin": return "\(who) highlighted an element"
        case "hold": return "\(who) marked elements on screen"
        case "unpin": return "\(who) cleared highlights"
        case "strobe": return "\(who) scanned the page"
        default: return "\(who) is working on this page…"
        }
    }

    /// Self-contained JS function invoked via `WKWebView.callAsyncJavaScript` with `arguments: ["payload": dict]`.
    /// Returns a JSON string matching Hermes Desktop's `PreviewActResult` schema.
    static let actScript: String = #"""
    const action = payload || {};
    const doc = document;
    const win = window;
    const w = win;
    w.__hermesActHolder = w.__hermesActHolder || {};
    const holder = w.__hermesActHolder;

    const cssEscape = (value) =>
      (typeof CSS !== 'undefined' && CSS.escape) ? CSS.escape(value) : String(value).replace(/["\\]/g, '\\$&');
    const clamp = (text, max) => (text.length > max ? text.slice(0, max - 1) + '…' : text);

    const labelOf = (el) => {
      const aria = el.getAttribute('aria-label');
      if (aria) return clamp(aria.trim(), 80);
      const labelledBy = el.getAttribute('aria-labelledby');
      const labelled = labelledBy ? doc.getElementById(labelledBy) : null;
      const text = ((labelled || el).textContent || '').trim().replace(/\s+/g, ' ');
      if (text) return clamp(text, 80);
      for (const attr of ['placeholder', 'title', 'alt', 'name', 'value']) {
        const value = el.getAttribute(attr);
        if (value) return clamp(value.trim(), 80);
      }
      return '';
    };

    const stableOf = (el) =>
      el.id || el.getAttribute('data-testid') || el.getAttribute('name') || el.getAttribute('aria-label') || '';

    const stemOf = (role) => {
      if (role === 'button' || role === 'summary') return 'btn';
      if (role === 'a' || role === 'link') return 'lnk';
      if (role === 'input:search' || role === 'searchbox') return 'srch';
      if (role === 'input:checkbox' || role === 'checkbox') return 'chk';
      if (role === 'input:radio' || role === 'radio') return 'rdo';
      if (role === 'select' || role === 'combobox') return 'sel';
      if (role === 'textarea') return 'txt';
      if (role === 'switch') return 'sw';
      if (role === 'menuitem') return 'mi';
      if (role === 'option') return 'opt';
      if (role === 'tab') return 'tab';
      return (role.indexOf('input') === 0 || role === 'textbox') ? 'inp' : 'el';
    };

    const slug = (name) => {
      let out = '';
      let dash = false;
      for (let i = 0; i < name.length && out.length < 24; i++) {
        const ch = name[i];
        if (/[a-zA-Z0-9]/.test(ch)) {
          out += ch.toLowerCase();
          dash = false;
        } else if (!dash && out) {
          out += '-';
          dash = true;
        }
      }
      return out.replace(/-+$/, '');
    };

    const anchorOf = (el) => {
      const near = el.closest(
        'main,nav,header,footer,aside,[role="main"],[role="navigation"],[role="banner"],' +
        '[role="contentinfo"],[role="complementary"],[role="search"],form[aria-label],section[aria-label]'
      );
      if (!near) return 'root';
      const named = near.getAttribute('aria-label') || '';
      return near.tagName.toLowerCase() + (named ? '#' + slug(named) : '');
    };

    const selectorFor = (el) => {
      if (el.id) return '#' + cssEscape(el.id);
      const testId = el.getAttribute('data-testid');
      return testId ? '[data-testid="' + cssEscape(testId) + '"]' : '';
    };

    const valueOf = (el) => {
      const kind = (el.type || '').toLowerCase();
      if (kind === 'checkbox' || kind === 'radio') return el.checked ? 'checked' : 'unchecked';
      const role = el.getAttribute('role') || '';
      if (role === 'checkbox' || role === 'radio' || role === 'switch') {
        return el.getAttribute('aria-checked') === 'true' ? 'checked' : 'unchecked';
      }
      if (typeof el.value === 'string' && el.value) return clamp(el.value, 60);
      return '';
    };

    const shifted = (was, entry) => {
      const off = !!entry.disabled;
      const value = entry.value || '';
      if (was.label === entry.label && was.value === value && was.off === off) return null;
      const moved = { ref: was.ref };
      if (was.label !== entry.label) moved.label = entry.label;
      if (was.value !== value) moved.value = value;
      if (was.off !== off) moved.disabled = off;
      return moved;
    };

    const alike = (a, b) => {
      if (!a || !b) return false;
      const one = a.toLowerCase().split(/\s+/).filter(Boolean);
      const two = b.toLowerCase().split(/\s+/).filter(Boolean);
      const both = one.filter((word) => two.indexOf(word) !== -1).length;
      const all = one.length + two.filter((word) => one.indexOf(word) === -1).length;
      return all > 0 && both / all >= 0.5;
    };

    const affinity = (was, now) => {
      if (was.role !== now.role) return 0;
      if (was.stable && now.stable) return was.stable === now.stable ? 1 : 0;
      let score = 0;
      if (was.name && was.name === now.name) score += 0.6;
      else if (alike(was.name, now.name)) score += 0.4;
      if (was.path && was.path === now.path) score += 0.3;
      return score;
    };

    const coin = (coined, role, name) => {
      const named = slug(name);
      const stem = stemOf(role) + (named ? '-' + named : '');
      const nth = coined[stem] || 0;
      coined[stem] = nth + 1;
      return nth ? stem + '-' + nth : stem;
    };

    const onScreen = (el) => {
      const box = el.getBoundingClientRect();
      if (box.right <= 0 || box.bottom <= 0 || box.left >= win.innerWidth || box.top >= win.innerHeight) return false;
      return !(box.width >= win.innerWidth * 0.95 && box.height >= win.innerHeight * 0.9);
    };

    const shown = (el) => {
      if (typeof el.checkVisibility === 'function' && !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) {
        return false;
      }
      const style = win.getComputedStyle ? win.getComputedStyle(el) : null;
      if (style) {
        if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
        if ((style.clip && style.clip !== 'auto') || (style.clipPath || '').indexOf('inset(50%') !== -1) return false;
      }
      return true;
    };

    const visible = (el) => {
      if (!shown(el)) return false;
      if (el.closest('[aria-hidden="true"], [inert]')) return false;
      const rect = el.getBoundingClientRect();
      if (rect.right <= 0 || rect.bottom <= 0) return false;
      if (rect.width < 3 || rect.height < 3) return false;
      const midX = rect.left + rect.width / 2;
      const midY = rect.top + rect.height / 2;
      if (typeof doc.elementFromPoint === 'function' && midX >= 0 && midY >= 0 && midX < win.innerWidth && midY < win.innerHeight) {
        const over = doc.elementFromPoint(midX, midY);
        if (!over || !(over === el || el.contains(over) || over.contains(el))) return false;
      }
      return true;
    };

    // MARK: Live collaborative overlay (closed shadow root, CSP-safe inline properties)
    const ensureOverlay = () => {
      if (w.__hermesOverlay && doc.documentElement.contains(w.__hermesOverlay.host)) {
        return w.__hermesOverlay;
      }
      const host = doc.createElement('div');
      host.setAttribute('data-hermes-overlay', '1');
      host.style.setProperty('position', 'fixed', 'important');
      host.style.setProperty('inset', '0', 'important');
      host.style.setProperty('width', '100vw', 'important');
      host.style.setProperty('height', '100vh', 'important');
      host.style.setProperty('max-width', 'none', 'important');
      host.style.setProperty('max-height', 'none', 'important');
      host.style.setProperty('pointer-events', 'none', 'important');
      host.style.setProperty('z-index', '2147483647', 'important');
      host.style.setProperty('margin', '0', 'important');
      host.style.setProperty('padding', '0', 'important');
      host.style.setProperty('border', 'none', 'important');
      host.style.setProperty('background', 'transparent', 'important');
      host.style.setProperty('overflow', 'visible', 'important');
      const shadow = host.attachShadow({ mode: 'closed' });
      const layer = doc.createElement('div');
      layer.style.setProperty('position', 'fixed');
      layer.style.setProperty('inset', '0');
      layer.style.setProperty('pointer-events', 'none');
      shadow.appendChild(layer);
      doc.documentElement.appendChild(host);
      try {
        if ('popover' in host) {
          host.setAttribute('popover', 'manual');
          host.showPopover();
        }
      } catch (_) {}
      const state = { host, layer, pins: [], raf: 0 };
      const syncPins = () => {
        state.pins = state.pins.filter((p) => {
          if (!doc.contains(p.el)) {
            p.box.remove();
            return false;
          }
          const r = p.el.getBoundingClientRect();
          p.box.style.setProperty('transform', 'translate(' + Math.round(r.left - 3) + 'px,' + Math.round(r.top - 3) + 'px)');
          p.box.style.setProperty('width', Math.max(8, Math.round(r.width + 6)) + 'px');
          p.box.style.setProperty('height', Math.max(8, Math.round(r.height + 6)) + 'px');
          return true;
        });
        if (state.pins.length > 0) {
          state.raf = win.requestAnimationFrame(syncPins);
        } else {
          state.raf = 0;
        }
      };
      state.ensureLoop = () => {
        if (!state.raf && state.pins.length > 0) state.raf = win.requestAnimationFrame(syncPins);
      };
      w.__hermesOverlay = state;
      return state;
    };

    const reducedMotion = !!(win.matchMedia && win.matchMedia('(prefers-reduced-motion: reduce)').matches);
    const ACCENT = '#EC008C';

    const makeBox = (el, label, persistent) => {
      const r = el.getBoundingClientRect();
      const box = doc.createElement('div');
      box.style.setProperty('position', 'fixed');
      box.style.setProperty('left', '0');
      box.style.setProperty('top', '0');
      box.style.setProperty('transform', 'translate(' + Math.round(r.left - 3) + 'px,' + Math.round(r.top - 3) + 'px)');
      box.style.setProperty('width', Math.max(8, Math.round(r.width + 6)) + 'px');
      box.style.setProperty('height', Math.max(8, Math.round(r.height + 6)) + 'px');
      box.style.setProperty('border', (persistent ? '2px' : '2px') + ' solid ' + ACCENT);
      box.style.setProperty('border-radius', '6px');
      box.style.setProperty('background', persistent ? 'rgba(236, 0, 140, 0.08)' : 'rgba(236, 0, 140, 0.14)');
      box.style.setProperty('box-sizing', 'border-box');
      box.style.setProperty('pointer-events', 'none');
      if (label) {
        const tag = doc.createElement('div');
        tag.textContent = label;
        tag.style.setProperty('position', 'absolute');
        tag.style.setProperty('left', '-2px');
        tag.style.setProperty('top', r.top < 24 ? '100%' : '-20px');
        tag.style.setProperty('padding', '1px 6px');
        tag.style.setProperty('border-radius', '4px');
        tag.style.setProperty('background', ACCENT);
        tag.style.setProperty('color', '#FFFFFF');
        tag.style.setProperty('font-family', '-apple-system, BlinkMacSystemFont, sans-serif');
        tag.style.setProperty('font-size', '11px');
        tag.style.setProperty('font-weight', '600');
        tag.style.setProperty('line-height', '16px');
        tag.style.setProperty('white-space', 'nowrap');
        tag.style.setProperty('max-width', '220px');
        tag.style.setProperty('overflow', 'hidden');
        tag.style.setProperty('text-overflow', 'ellipsis');
        box.appendChild(tag);
      }
      return box;
    };

    const flashMark = (el, label, durationMs) => {
      try {
        const ov = ensureOverlay();
        const box = makeBox(el, label, false);
        ov.layer.appendChild(box);
        const ttl = durationMs || 2400;
        if (!reducedMotion && typeof box.animate === 'function') {
          box.animate(
            [
              { opacity: 0 },
              { opacity: 1, offset: 0.08 },
              { opacity: 1, offset: 0.78 },
              { opacity: 0 }
            ],
            { duration: ttl, fill: 'forwards' }
          );
        }
        setTimeout(() => { try { box.remove(); } catch (_) {} }, ttl + 60);
      } catch (_) {}
    };

    const pinMark = (el, label) => {
      const ov = ensureOverlay();
      ov.pins = ov.pins.filter((p) => {
        if (p.el === el) { p.box.remove(); return false; }
        return true;
      });
      const box = makeBox(el, label, true);
      ov.layer.appendChild(box);
      ov.pins.push({ el, box });
      ov.ensureLoop();
    };

    const unpinMarks = (targetEl) => {
      if (!w.__hermesOverlay) return 0;
      const ov = w.__hermesOverlay;
      let removed = 0;
      ov.pins = ov.pins.filter((p) => {
        if (!targetEl || p.el === targetEl) {
          p.box.remove();
          removed++;
          return false;
        }
        return true;
      });
      return removed;
    };

    const flashReadSweep = () => {
      try {
        if (reducedMotion) return;
        const ov = ensureOverlay();
        const bar = doc.createElement('div');
        bar.style.setProperty('position', 'fixed');
        bar.style.setProperty('left', '0');
        bar.style.setProperty('right', '0');
        bar.style.setProperty('top', '0');
        bar.style.setProperty('height', '3px');
        bar.style.setProperty('background', 'linear-gradient(90deg, transparent, ' + ACCENT + ', transparent)');
        bar.style.setProperty('box-shadow', '0 0 14px ' + ACCENT);
        ov.layer.appendChild(bar);
        if (typeof bar.animate === 'function') {
          bar.animate(
            [
              { transform: 'translateY(0px)', opacity: 0.9 },
              { transform: 'translateY(' + Math.max(200, win.innerHeight) + 'px)', opacity: 0 }
            ],
            { duration: 750, easing: 'ease-out', fill: 'forwards' }
          );
        }
        setTimeout(() => { try { bar.remove(); } catch (_) {} }, 800);
      } catch (_) {}
    };

    // MARK: Core inventory & delta
    const maxElements = 120;
    const maxMarks = 200;
    const rebindBar = 0.6;
    const here = doc.location ? doc.location.href : '';
    const glide = reducedMotion ? 'auto' : 'smooth';

    const sight = (max) => {
      const nodes = [];
      const field = [];
      const elements = [];
      const candidates = doc.querySelectorAll(
        'a[href], button, input:not([type="hidden"]), select, textarea, summary, label[for], ' +
        '[role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="tab"], ' +
        '[role="menuitem"], [role="switch"], [role="option"], [role="combobox"], [role="searchbox"], ' +
        '[role="textbox"], [contenteditable=""], [contenteditable="true"], [onclick], ' +
        '[tabindex]:not([tabindex="-1"])'
      );
      for (const el of candidates) {
        if (elements.length >= max && field.length >= maxMarks) break;
        if (!visible(el)) continue;
        if (field.length < maxMarks && onScreen(el)) field.push(el);
        if (elements.length >= max) continue;
        const tag = el.tagName.toLowerCase();
        const role = el.getAttribute('role') || (tag === 'input' ? 'input:' + (el.type || 'text') : tag);
        const label = labelOf(el);
        const value = valueOf(el);
        if (!label && !value) continue;
        const entry = { label, ref: '', role };
        const selector = selectorFor(el);
        if (selector) entry.selector = selector;
        if (el.disabled) entry.disabled = true;
        if (value) entry.value = value;
        nodes.push(el);
        elements.push(entry);
      }
      holder.nodes = nodes;
      holder.field = field;
      return { elements, nodes };
    };

    const survey = (max, forceFull) => {
      const fresh = holder.url !== here;
      if (fresh) {
        holder.book = [];
        holder.coined = {};
      }
      const book = holder.book || (holder.book = []);
      const coined = holder.coined || (holder.coined = {});
      const seen = sight(max);
      const claimed = {};
      const kept = [];
      const added = [];
      const changed = [];
      const rebound = [];
      const known = new Map();
      const waiting = [];
      let same = 0;

      for (const bound of book) known.set(bound.el, bound);

      for (let i = 0; i < seen.elements.length; i++) {
        const entry = seen.elements[i];
        const bound = known.get(seen.nodes[i]);
        if (!bound) { waiting.push(i); continue; }
        const moved = shifted(bound, entry);
        entry.ref = bound.ref;
        claimed[bound.ref] = true;
        kept.push(bound);
        if (!moved) { same++; continue; }
        bound.label = entry.label;
        bound.name = entry.label || entry.value || '';
        bound.off = !!entry.disabled;
        bound.value = entry.value || '';
        changed.push(moved);
      }

      const pool = book.filter((b) => !claimed[b.ref] && !doc.contains(b.el));
      for (const i of waiting) {
        const entry = seen.elements[i];
        const el = seen.nodes[i];
        const now = {
          el,
          label: entry.label,
          name: entry.label || entry.value || '',
          off: !!entry.disabled,
          path: anchorOf(el),
          ref: '',
          role: entry.role,
          stable: stableOf(el),
          value: entry.value || ''
        };
        let best = null;
        let score = 0;
        for (const bound of pool) {
          if (claimed[bound.ref]) continue;
          const rung = affinity(bound, now);
          if (rung >= rebindBar && rung > score) { best = bound; score = rung; }
        }
        if (best) {
          entry.ref = best.ref;
          best.el = el;
          best.label = now.label;
          best.name = now.name;
          best.off = now.off;
          best.path = now.path;
          best.stable = now.stable;
          best.value = now.value;
          claimed[best.ref] = true;
          kept.push(best);
          rebound.push(best.ref);
          continue;
        }
        now.ref = coin(coined, entry.role, now.name);
        entry.ref = now.ref;
        claimed[now.ref] = true;
        kept.push(now);
        added.push(entry);
      }

      const removed = [];
      for (const bound of book) {
        if (claimed[bound.ref]) continue;
        if (doc.contains(bound.el) && visible(bound.el)) { kept.push(bound); continue; }
        removed.push(bound.ref);
      }

      holder.book = kept;
      holder.url = here;

      const churn = added.length + changed.length;
      if (fresh || forceFull || churn * 2 >= seen.elements.length) {
        return { elements: seen.elements, success: true };
      }
      const delta = { same };
      if (added.length) delta.added = added;
      if (changed.length) delta.changed = changed;
      if (removed.length) delta.removed = removed;
      if (rebound.length) delta.rebound = rebound;
      return { delta, success: true };
    };

    const resolveTarget = () => {
      const ref = (action.ref || '').trim();
      if (ref) {
        if (holder.url !== here) {
          return { error: 'The page navigated since the last snapshot, so ' + ref + ' no longer points anywhere. Call elements again.' };
        }
        const bound = (holder.book || []).find((entry) => entry.ref === ref);
        if (!bound) return { error: 'Unknown element ' + ref + '. Call elements to get current refs.' };
        if (!doc.contains(bound.el)) return { error: ref + ' has been removed from the page since the last snapshot. Call elements again.' };
        return { el: bound.el, ref: bound.ref };
      }
      const selector = (action.selector || '').trim();
      if (!selector) return { error: 'Pass a ref from elements, or a CSS selector.' };
      let el = null;
      try { el = doc.querySelector(selector); } catch (_) { return { error: 'Not a valid CSS selector: ' + selector }; }
      return el ? { el, ref: selector } : { error: 'No element matches ' + selector + '.' };
    };

    const describe = (el) => {
      const label = labelOf(el);
      return el.tagName.toLowerCase() + (label ? ' "' + label + '"' : '');
    };

    const answer = (result) => JSON.stringify(Object.assign({}, result, {
      title: doc.title || '',
      url: doc.location ? doc.location.href : ''
    }));

    const fail = (error) => answer({ error, success: false });

    const pointAt = (el) => {
      const rect = el.getBoundingClientRect();
      return { clientX: Math.round(rect.left + rect.width / 2), clientY: Math.round(rect.top + rect.height / 2) };
    };

    const waitMs = (ms) => new Promise((r) => setTimeout(r, ms));
    const kind = String(action.action || action.kind || '').trim().toLowerCase();

    if (kind === 'read_cue') {
      flashReadSweep();
      return answer({ success: true });
    }

    if (kind === 'elements') {
      const cap = Math.max(1, Math.min(Number(action.max) || maxElements, maxElements));
      const looked = survey(cap, action.full === true);
      const empty = !looked.delta && !(looked.elements || []).length;
      flashReadSweep();
      const out = Object.assign({}, looked);
      if (empty) out.note = 'No interactive elements found — the page may still be loading.';
      return answer(out);
    }

    if (kind === 'strobe') {
      const looked = survey(maxElements, false);
      const list = (holder.field || []).slice(0, 12);
      list.forEach((el, idx) => {
        setTimeout(() => flashMark(el, '', 550), idx * 90);
      });
      return answer(Object.assign({}, looked, { acted: 'scanned the visible page' }));
    }

    if (kind === 'hold') {
      const looked = survey(maxElements, false);
      unpinMarks(null);
      const book = holder.book || [];
      let count = 0;
      for (const b of book) {
        if (count >= 40) break;
        if (onScreen(b.el)) {
          pinMark(b.el, b.ref);
          count++;
        }
      }
      return answer(Object.assign({}, looked, { acted: 'held the field (' + count + ' marks)' }));
    }

    if (kind === 'unpin') {
      if (action.ref || action.selector) {
        const t = resolveTarget();
        if (t.error) return fail(t.error);
        const n = unpinMarks(t.el);
        return answer({ acted: n ? 'removed mark on ' + describe(t.el) : 'no mark on ' + describe(t.el), success: true });
      }
      const n = unpinMarks(null);
      return answer({ acted: 'cleared ' + n + ' mark(s)', success: true });
    }

    if (kind === 'scroll') {
      let scroller = null;
      if (action.ref || action.selector) {
        const t = resolveTarget();
        if (t.error) return fail(t.error);
        scroller = t.el;
      }
      const page = Math.round((win.innerHeight || 800) * 0.9);
      const hasAmount = action.amount !== undefined && action.amount !== null && !Number.isNaN(Number(action.amount));
      const by = action.to === 'top' ? -1e7 : action.to === 'bottom' ? 1e7 : (hasAmount ? Number(action.amount) : page);
      if (scroller) scroller.scrollBy({ behavior: glide, top: by });
      else win.scrollBy({ behavior: glide, top: by });
      await waitMs(180);
      const after = survey(maxElements, false);
      return answer(Object.assign({}, after, { acted: scroller ? 'scrolled ' + describe(scroller) : 'scrolled the page', success: true }));
    }

    const target = resolveTarget();
    if (target.error || !target.el) return fail(target.error || 'No target.');
    const el = target.el;
    holder.aimed = el;

    if (typeof el.scrollIntoView === 'function') {
      el.scrollIntoView({ behavior: 'instant', block: 'center', inline: 'nearest' });
    }

    if (kind === 'pin') {
      const caption = (action.text || target.ref || '').trim();
      pinMark(el, caption);
      return answer({ acted: 'pinned ' + describe(el), success: true });
    }

    if (kind === 'hover') {
      const init = Object.assign({ bubbles: true, cancelable: true }, pointAt(el));
      flashMark(el, target.ref || 'hover', 2000);
      if (typeof PointerEvent === 'function') {
        el.dispatchEvent(new PointerEvent('pointerover', init));
        el.dispatchEvent(new PointerEvent('pointermove', init));
      }
      el.dispatchEvent(new MouseEvent('mouseover', init));
      el.dispatchEvent(new MouseEvent('mousemove', init));
      await waitMs(160);
      const after = survey(maxElements, false);
      return answer(Object.assign({}, after, { acted: 'hovered over ' + describe(el), success: true }));
    }

    if (el.disabled) {
      flashMark(el, 'disabled', 1800);
      return fail(describe(el) + ' is disabled.');
    }

    if (kind === 'click') {
      const init = Object.assign({ bubbles: true, cancelable: true }, pointAt(el));
      flashMark(el, target.ref || 'click', 2200);
      if (typeof PointerEvent === 'function') {
        el.dispatchEvent(new PointerEvent('pointerdown', init));
        el.dispatchEvent(new PointerEvent('pointerup', init));
      }
      el.dispatchEvent(new MouseEvent('mousedown', init));
      el.dispatchEvent(new MouseEvent('mouseup', init));
      el.click();
      await waitMs(220);
      const after = survey(maxElements, false);
      return answer(Object.assign({}, after, { acted: 'clicked ' + describe(el), success: true }));
    }

    if (kind === 'type') {
      const text = action.text !== undefined && action.text !== null ? String(action.text) : '';
      const editable = el.isContentEditable || (el.getAttribute('contenteditable') || 'false') !== 'false';
      flashMark(el, target.ref || 'type', 2400);
      el.focus();
      if (editable) {
        try {
          doc.execCommand('selectAll', false, null);
          doc.execCommand('insertText', false, text);
        } catch (_) {
          el.textContent = text;
          el.dispatchEvent(new InputEvent('input', { data: text, inputType: 'insertText', bubbles: true }));
        }
      } else if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
        const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const desc = Object.getOwnPropertyDescriptor(proto, 'value');
        if (desc && desc.set) desc.set.call(el, text);
        else el.value = text;
      } else if (el.tagName === 'SELECT') {
        return fail(describe(el) + ' is a dropdown — click it and click the option you want.');
      } else {
        return fail(describe(el) + ' is not a text field.');
      }
      el.dispatchEvent(new InputEvent('input', { data: text, inputType: 'insertText', bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      if (action.submit) {
        const enter = { bubbles: true, cancelable: true, code: 'Enter', key: 'Enter', keyCode: 13, which: 13 };
        el.dispatchEvent(new KeyboardEvent('keydown', enter));
        el.dispatchEvent(new KeyboardEvent('keyup', enter));
        if (el.form) {
          if (typeof el.form.requestSubmit === 'function') el.form.requestSubmit();
          else el.form.submit();
        }
      }
      await waitMs(220);
      const after = survey(maxElements, false);
      return answer(Object.assign({}, after, {
        acted: 'typed into ' + describe(el) + (action.submit ? ' and submitted' : ''),
        success: true
      }));
    }

    if (kind === 'press') {
      const key = String(action.key || '');
      if (!key) return fail('Pass the key to press, e.g. "Enter" or "Escape".');
      const root = el.tagName === 'BODY' || el.tagName === 'HTML';
      if (key.length === 1 && root && action.allow_shortcut !== true && action.allowShortcut !== true) {
        return fail('Refused to press a printable key on ' + el.tagName + '. That would be a page shortcut; pass allow_shortcut to opt in.');
      }
      flashMark(el, key, 1800);
      const init = { bubbles: true, cancelable: true, code: key.length === 1 ? 'Key' + key.toUpperCase() : key, key };
      el.focus();
      el.dispatchEvent(new KeyboardEvent('keydown', init));
      el.dispatchEvent(new KeyboardEvent('keyup', init));
      await waitMs(180);
      const after = survey(maxElements, false);
      return answer(Object.assign({}, after, { acted: 'pressed ' + key + ' on ' + describe(el), success: true }));
    }

    return fail('Unknown action: ' + kind);
    """#
}
