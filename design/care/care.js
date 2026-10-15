/* WorkScribe · Care — shared behaviour for the exploration pages.
 * Theme toggle, stage scaling, the icon sprite, a pausable timeline, and the
 * AI line animator (draft, rewrite by word diff, ink drying). No dependencies. */
(function () {
  "use strict";
  const Care = (window.Care = {});
  const reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  Care.reduce = reduce;
  Care.instant = false; // set while seeking so state builds without animation

  /* ---------------------------------------------------------------- theme */
  const THEMES = ["auto", "light", "dark"];
  function readTheme() { try { return localStorage.getItem("ws-care-theme") || "auto"; } catch (e) { return "auto"; } }
  function applyTheme(t) {
    if (t === "auto") document.documentElement.removeAttribute("data-theme");
    else document.documentElement.setAttribute("data-theme", t);
    document.querySelectorAll("[data-theme-btn]").forEach((b) => { b.textContent = "Theme: " + t; });
  }
  // URL #dark / #light lets screenshots pick a theme without storage
  const hashTheme = /(^|[#&])(dark|light)\b/.exec(location.hash);
  applyTheme(hashTheme ? hashTheme[2] : readTheme());
  if (/(^|[#&])bare\b/.test(location.hash)) document.documentElement.classList.add("bare");
  document.addEventListener("click", (e) => {
    const b = e.target.closest("[data-theme-btn]");
    if (!b) return;
    const cur = document.documentElement.getAttribute("data-theme") || "auto";
    const next = THEMES[(THEMES.indexOf(cur) + 1) % THEMES.length];
    applyTheme(next);
    try { localStorage.setItem("ws-care-theme", next); } catch (e2) { /* private window */ }
  });

  /* ---------------------------------------------------------------- icons (Lucide shapes, as Obsidian uses) */
  const P = {
    "chevron-left": '<path d="m15 18-6-6 6-6"/>',
    "chevron-right": '<path d="m9 18 6-6-6-6"/>',
    "chevron-down": '<path d="m6 9 6 6 6-6"/>',
    folder: '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>',
    "folder-plus": '<path d="M12 10v6"/><path d="M9 13h6"/><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>',
    file: '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>',
    search: '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
    bookmark: '<path d="m19 21-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v16z"/>',
    more: '<circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/><circle cx="5" cy="12" r="1"/>',
    book: '<path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/>',
    calendar: '<rect width="18" height="18" x="3" y="4" rx="2"/><path d="M16 2v4"/><path d="M8 2v4"/><path d="M3 10h18"/>',
    mic: '<path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><path d="M12 19v3"/>',
    message: '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
    x: '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
    plus: '<path d="M5 12h14"/><path d="M12 5v14"/>',
    "arrow-up": '<path d="m5 12 7-7 7 7"/><path d="M12 19V5"/>',
    settings: '<path d="M20 7h-9"/><path d="M14 17H5"/><circle cx="17" cy="17" r="3"/><circle cx="7" cy="7" r="3"/>',
    help: '<circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><path d="M12 17h.01"/>',
    "panel-left": '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M9 3v18"/>',
    "panel-right": '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M15 3v18"/>',
    pencil: '<path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z"/>',
    check: '<path d="M20 6 9 17l-5-5"/>',
    clock: '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>',
    link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
    graph: '<circle cx="12" cy="18" r="3"/><circle cx="6" cy="6" r="3"/><circle cx="18" cy="6" r="3"/><path d="M18 9v2c0 .6-.4 1-1 1H7c-.6 0-1-.4-1-1V9"/><path d="M12 12v3"/>',
    canvas: '<rect width="7" height="9" x="3" y="3" rx="1"/><rect width="7" height="5" x="14" y="3" rx="1"/><rect width="7" height="9" x="14" y="12" rx="1"/><rect width="7" height="5" x="3" y="16" rx="1"/>',
    terminal: '<path d="m7 11 2-2-2-2"/><path d="M11 13h4"/><rect width="18" height="18" x="3" y="3" rx="2"/>',
    wave: '<path d="M2 10v3"/><path d="M6 6v11"/><path d="M10 3v18"/><path d="M14 8v7"/><path d="M18 5v13"/><path d="M22 10v3"/>',
    list: '<path d="M3 12h.01"/><path d="M3 18h.01"/><path d="M3 6h.01"/><path d="M8 12h13"/><path d="M8 18h13"/><path d="M8 6h13"/>',
    edit: '<path d="M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.375 2.625a1 1 0 0 1 3 3l-9.013 9.014a2 2 0 0 1-.853.505l-2.873.84a.5.5 0 0 1-.62-.62l.84-2.873a2 2 0 0 1 .506-.852z"/>',
    sort: '<path d="m21 16-4 4-4-4"/><path d="M17 20V4"/><path d="m3 8 4-4 4 4"/><path d="M7 4v16"/>',
    clip: '<path d="m21.44 11.05-9.19 9.19a6 6 0 0 1-8.49-8.49l8.57-8.57A4 4 0 1 1 18 8.84l-8.59 8.57a2 2 0 0 1-2.83-2.83l8.49-8.48"/>',
    globe: '<circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>',
    laptop: '<path d="M20 16V7a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v9m16 0H4m16 0 1.28 2.55a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45L4 16"/>',
    insert: '<polyline points="9 10 4 15 9 20"/><path d="M20 4v7a4 4 0 0 1-4 4H4"/>',
    hourglass: '<path d="M5 22h14"/><path d="M5 2h14"/><path d="M17 22v-4.172a2 2 0 0 0-.586-1.414L12 12l-4.414 4.414A2 2 0 0 0 7 17.828V22"/><path d="M7 2v4.172a2 2 0 0 0 .586 1.414L12 12l4.414-4.414A2 2 0 0 0 17 6.172V2"/>',
    play: '<polygon points="6 3 20 12 6 21 6 3"/>',
    pause: '<rect x="14" y="4" width="4" height="16" rx="1"/><rect x="6" y="4" width="4" height="16" rx="1"/>',
    replay: '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>',
    wifi: '<path d="M12 20h.01"/><path d="M2 8.82a15 15 0 0 1 20 0"/><path d="M5 12.859a10 10 0 0 1 14 0"/><path d="M8.5 16.429a5 5 0 0 1 7 0"/>',
    battery: '<rect width="16" height="10" x="2" y="7" rx="2" ry="2"/><path d="M22 11v2"/><path d="M6 11v2" /><path d="M10 11v2"/><path d="M14 11v2"/>',
    toggles: '<rect width="20" height="12" x="2" y="6" rx="6"/><circle cx="8" cy="12" r="2"/>',
    sparkle: '<path d="M12 3v3"/><path d="M12 18v3"/><path d="M3 12h3"/><path d="M18 12h3"/><path d="m5.6 5.6 2.1 2.1"/><path d="m16.3 16.3 2.1 2.1"/><path d="m5.6 18.4 2.1-2.1"/><path d="m16.3 7.7 2.1-2.1"/>',
    trash: '<path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/>',
    video: '<path d="m16 13 5.223 3.482a.5.5 0 0 0 .777-.416V7.87a.5.5 0 0 0-.752-.432L16 10.5"/><rect x="2" y="6" width="14" height="12" rx="2"/>',
  };
  function sprite() {
    if (document.getElementById("care-sprite")) return;
    const s = Object.entries(P).map(([k, v]) => '<symbol id="i-' + k + '" viewBox="0 0 24 24">' + v + "</symbol>").join("");
    const div = document.createElement("div");
    div.innerHTML = '<svg id="care-sprite" width="0" height="0" style="position:absolute" aria-hidden="true">' + s + "</svg>";
    document.body.prepend(div.firstChild);
  }
  Care.icon = (name, cls) => '<svg class="i ' + (cls || "") + '" aria-hidden="true"><use href="#i-' + name + '"/></svg>';

  /* ---------------------------------------------------------------- stage: real-size window, scaled to fit */
  function fitStages() {
    document.querySelectorAll(".stage").forEach((st) => {
      const sc = st.querySelector(":scope > .scaler");
      if (!sc) return;
      const w = +st.dataset.w, h = +st.dataset.h;
      sc.style.width = w + "px"; sc.style.height = h + "px";
      const s = Math.min(1, st.clientWidth / w);
      sc.style.transform = s < 1 ? "scale(" + s + ")" : "none";
      st.style.height = Math.ceil(h * s) + "px";
      st.dataset.scale = s.toFixed(3);
    });
  }
  Care.fitStages = fitStages;
  window.addEventListener("resize", fitStages);

  /* ---------------------------------------------------------------- tokens for an AI line
   * "**Ship date.** v2.4 moves …" → [{t:"Ship", lead:true}, {t:"date.", lead:true}, {t:"v2.4"}, …] */
  function tokens(text) {
    const out = [];
    const re = /\*\*(.+?)\*\*|(\S+)/g;
    let m;
    while ((m = re.exec(text))) {
      if (m[1]) m[1].split(/\s+/).forEach((t) => out.push({ t, lead: true }));
      else out.push({ t: m[2], lead: false });
    }
    return out;
  }
  Care.tokens = tokens;
  const key = (tk) => (tk.lead ? "*" : "") + tk.t;
  function span(tk) {
    const s = document.createElement("span");
    s.className = "w" + (tk.lead ? " lead" : "");
    s.textContent = tk.t;
    s.dataset.k = key(tk);
    return s;
  }
  function layout(el, spans) {
    el.textContent = "";
    spans.forEach((s, i) => { if (i) el.appendChild(document.createTextNode(" ")); el.appendChild(s); });
  }
  /** Set an AI line's text with no animation. */
  Care.setLine = function (el, text) { layout(el, tokens(text).map(span)); };

  /** Longest common subsequence over word keys: which old words survive into the new line. */
  function lcs(a, b) {
    const n = a.length, m = b.length;
    const dp = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--)
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    const pairs = [];
    let i = 0, j = 0;
    while (i < n && j < m) {
      if (a[i] === b[j]) { pairs.push([i, j]); i++; j++; }
      else if (dp[i + 1][j] >= dp[i][j + 1]) i++;
      else j++;
    }
    return pairs;
  }

  function animateHeight(el, mutate) {
    if (Care.instant || reduce) { mutate(); return; }
    const h0 = el.offsetHeight;
    el.style.height = h0 + "px";
    mutate();
    el.style.height = "auto";
    const h1 = el.offsetHeight;
    el.style.height = h0 + "px";
    void el.offsetHeight;
    el.style.height = h1 + "px";
    setTimeout(() => { el.style.height = ""; }, 220);
  }

  /**
   * Rewrite an AI line in place. Only the words that changed move:
   *   0–140 ms   removed words fade out where they stand
   *   140 ms     layout settles; the line's height eases over 180 ms
   *   140 ms+    new words fade in, 24 ms apart, 220 ms each, fresh ("wet")
   *   +500 ms    each new word dries to the line's colour over 2.4 s
   * opts.slow multiplies every duration (the spec page plays it at 4×).
   */
  Care.rewrite = function (el, text, opts) {
    opts = opts || {};
    const k = opts.slow || 1;
    const old = Array.from(el.querySelectorAll(".w"));
    const next = tokens(text);
    const pairs = lcs(old.map((s) => s.dataset.k), next.map(key));
    const keepOld = new Set(pairs.map((p) => p[0]));
    const fromNew = new Map(pairs.map((p) => [p[1], p[0]]));
    const removed = old.filter((_, i) => !keepOld.has(i));
    const instant = Care.instant || opts.instant;
    if (opts.slow) el.style.setProperty("--k", k);

    const build = () => {
      const added = [];
      const spans = next.map((tk, j) => {
        if (fromNew.has(j)) return old[fromNew.get(j)];
        const s = span(tk);
        if (!instant) { s.classList.add("in", "wet"); added.push(s); }
        return s;
      });
      animateHeight(el, () => layout(el, spans));
      if (opts.freezeWet) { added.forEach((s) => s.classList.remove("in")); return added; }
      added.forEach((s, i) => {
        if (k !== 1) s.style.transition = "opacity " + 220 * k + "ms cubic-bezier(.16,1,.3,1)";
        setTimeout(() => s.classList.remove("in"), (reduce ? 0 : 24 * i * k) + 16);
        setTimeout(() => {
          if (k !== 1) s.style.transition = "color " + 2400 * k + "ms cubic-bezier(.16,1,.3,1), background-color " + 2400 * k + "ms cubic-bezier(.16,1,.3,1)";
          s.classList.remove("wet");
        }, (reduce ? 0 : 24 * i * k) + 500 * k);
      });
      return added;
    };
    if (instant || !removed.length || reduce) { removed.forEach((s) => s.remove()); return build(); }
    removed.forEach((s) => {
      if (k !== 1) s.style.transition = "opacity " + 140 * k + "ms ease-out";
      s.classList.add("out");
    });
    setTimeout(build, 140 * k);
  };

  /** Draft a line from nothing: words arrive one at a time (no wet ink: everything is new). */
  Care.draft = function (el, text, opts) {
    opts = opts || {};
    const tks = tokens(text);
    const every = opts.every || 70;
    if (Care.instant || reduce) { layout(el, tks.map(span)); opts.done && opts.done(); return; }
    animateHeight(el, () => { el.textContent = ""; });
    let i = 0;
    const step = () => {
      if (i >= tks.length) { opts.done && opts.done(); return; }
      const s = span(tks[i]);
      s.classList.add("in");
      animateHeight(el, () => { if (i) el.appendChild(document.createTextNode(" ")); el.appendChild(s); });
      requestAnimationFrame(() => requestAnimationFrame(() => s.classList.remove("in")));
      i++;
      setTimeout(step, every + (Math.random() * every * 0.5));
    };
    step();
  };

  /* ---------------------------------------------------------------- a pausable timeline for scripted scenes */
  Care.Timeline = function () {
    const ev = [];
    let t = 0, last = 0, playing = false, speed = 1, idx = 0, raf = 0, onTick = null, onEnd = null;
    const tl = {
      at(time, fn) { ev.push({ time, fn }); ev.sort((a, b) => a.time - b.time); return tl; },
      /** Type text into el char by char starting at t0 (seconds); returns the end time. */
      type(t0, el, text, cps) {
        let tt = t0;
        const step = 1 / (cps || 13);
        for (let i = 1; i <= text.length; i++) {
          const s = text.slice(0, i);
          const ch = text[i - 1];
          tt += step * (ch === " " ? 1.5 : 0.7 + ((i * 7919) % 10) / 16);
          tl.at(tt, () => { el.textContent = s; });
        }
        return tt;
      },
      get time() { return t; },
      get playing() { return playing; },
      set speed(s) { speed = s; },
      onTick(fn) { onTick = fn; return tl; },
      onEnd(fn) { onEnd = fn; return tl; },
      end() { return ev.length ? ev[ev.length - 1].time : 0; },
      play() {
        if (playing) return;
        playing = true; last = performance.now();
        const loop = (now) => {
          if (!playing) return;
          t += ((now - last) / 1000) * speed; last = now;
          while (idx < ev.length && ev[idx].time <= t) ev[idx++].fn();
          onTick && onTick(t);
          if (idx >= ev.length && t > tl.end() + 0.5) { playing = false; onEnd && onEnd(); return; }
          raf = requestAnimationFrame(loop);
        };
        raf = requestAnimationFrame(loop);
      },
      pause() { playing = false; cancelAnimationFrame(raf); },
      /** Jump forward to time T, applying every event on the way without animation. */
      seek(T) {
        Care.instant = true;
        while (idx < ev.length && ev[idx].time <= T) ev[idx++].fn();
        Care.instant = false;
        t = T; onTick && onTick(t);
      },
      reset() { tl.pause(); t = 0; idx = 0; },
    };
    return tl;
  };

  Care.clock = function (sec) {
    sec = Math.max(0, Math.floor(sec));
    const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    return (h ? h + ":" + String(m).padStart(2, "0") : m) + ":" + String(s).padStart(2, "0");
  };

  /* ---------------------------------------------------------------- shared chrome builders */
  const I = (n) => Care.icon(n);

  /** macOS menu bar. opts: {app, menus[], tally (html), clock} */
  Care.menubar = function (el, opts) {
    const apple = '<svg class="apple" viewBox="0 0 14 17" aria-hidden="true"><path d="M11.6 9c0-2 1.7-3 1.7-3a3.7 3.7 0 0 0-2.9-1.6c-1.2-.1-2.4.7-3 .7s-1.6-.7-2.6-.7A3.9 3.9 0 0 0 1.5 6.5C0 9 1.1 12.8 2.6 14.9c.7 1 1.5 2.1 2.6 2.1s1.4-.7 2.6-.7 1.6.7 2.6.7 1.8-1 2.5-2a8.6 8.6 0 0 0 1.1-2.4S11.6 12 11.6 9ZM9.6 3A3.6 3.6 0 0 0 10.4.4a3.7 3.7 0 0 0-2.4 1.2 3.4 3.4 0 0 0-.9 2.5A3 3 0 0 0 9.6 3Z"/></svg>';
    el.innerHTML = apple + "<b>" + opts.app + "</b>" + (opts.menus || []).map((m) => "<span>" + m + "</span>").join("") +
      '<span class="sp"></span>' +
      '<span class="st">' + Care.icon("wifi") + "</span>" +
      '<span class="st">' + Care.icon("battery") + "</span>" +
      '<span class="st" id="' + (opts.tallyId || "tally") + '">' + (opts.tally || "") + "</span>" +
      '<span class="st">' + Care.icon("toggles") + "</span>" +
      '<span class="st">' + Care.icon("search") + "</span>" +
      '<span class="clockm">' + (opts.clock || "Wed 14 Oct 10:12") + "</span>";
  };
  /** The WorkScribe status item, by state. */
  Care.tally = function (state, time) {
    const g = '<svg class="glyph" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M4 9v6"/><path d="M8 6v12"/><path d="M12 3v18"/><path d="M16 7v10"/><path d="M20 10v4"/></svg>';
    if (state === "recording") return '<span class="tally"><span class="rd"></span><span class="tm">' + time + "</span></span>";
    if (state === "soon") return '<span class="tally">' + g + '<span class="soon"></span></span>';
    if (state === "attention") return '<span class="tally"><span class="amber"></span><span class="tm">' + (time || "") + "</span></span>";
    if (state === "finishing") return '<span class="tally"><svg class="ring" viewBox="0 0 14 14"><circle cx="7" cy="7" r="5.5" fill="none" stroke="currentColor" stroke-opacity=".3" stroke-width="1.6"/><path d="M7 1.5a5.5 5.5 0 0 1 5.2 7.3" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg></span>';
    return '<span class="tally">' + g + "</span>";
  };

  /** Obsidian window chrome around page-supplied .ob-main and .ob-right. */
  Care.obChrome = function (win, o) {
    o = o || {};
    const tree = o.tree || [
      ["d", "Clips"], ["d", "Daily"], ["d", "Meetings", true],
      ["f", "2026-10-09 Halvorsen site visit"], ["f", "2026-10-13 Design crit"],
      ["f", "2026-10-14 Offline sync — v2.4 scope", "on"],
      ["d", "People"], ["d", "PRDs", true], ["f", "Offline PRD v3"],
    ];
    const treeHtml = tree.map(([k, name, x]) => k === "d"
      ? '<div class="d">' + Care.icon(x ? "chevron-down" : "chevron-right") + name + "</div>"
      : '<div class="f' + (x === "on" ? " on" : "") + '">' + name + "</div>").join("");
    const pre =
      '<div class="ob-titlebar-left"><span class="lights"><i></i><i></i><i></i></span>' +
        '<span class="ic">' + I("panel-left") + '</span><span class="grow" style="flex:1"></span>' +
        '<span class="ic on">' + I("folder") + '</span><span class="ic">' + I("search") + '</span><span class="ic">' + I("bookmark") + "</span></div>" +
      '<div class="ob-ribbon">' +
        '<span class="ic">' + I("graph") + '</span><span class="ic">' + I("canvas") + '</span><span class="ic">' + I("calendar") + '</span><span class="ic">' + I("terminal") + "</span>" +
        '<span class="ic' + (o.recording ? " rec" : "") + '" title="WorkScribe">' + I("wave") + "</span>" +
        '<span class="grow"></span><span class="ic">' + I("help") + '</span><span class="ic">' + I("settings") + "</span></div>" +
      '<div class="ob-left"><div class="nav-actions"><span class="ic">' + I("edit") + '</span><span class="ic">' + I("folder-plus") + '</span><span class="ic">' + I("sort") + "</span></div>" +
        '<div class="ob-tree">' + treeHtml + "</div>" +
        '<div class="ob-vault">' + I("chevron-down") + '<span class="grow">work</span><span class="ic">' + I("help") + '</span><span class="ic">' + I("settings") + "</span></div></div>" +
      '<div class="ob-tabs">' + (o.tabs || ["2026-10-14 Offline sync — v2.4 scope", "Offline PRD v3"]).map((t, i) =>
        '<div class="ob-tab' + (i === 0 ? " on" : "") + '">' + (i === 0 && o.recording ? '<span class="dot" data-tabdot></span>' : "") + t + (i === 0 ? Care.icon("x") : "") + "</div>").join("") +
        '<span class="ic plus">' + I("plus") + "</span></div>" +
      '<div class="ob-right-head"><span class="ic">' + I("link") + '</span><span class="ic">' + I("list") + '</span><span class="ic on">' + I("wave") + '</span><span class="grow"></span><span class="ic">' + I("panel-right") + "</span></div>";
    win.insertAdjacentHTML("afterbegin", pre);
  };

  Care.ready = function (fn) {
    const go = () => { sprite(); fitStages(); fn && fn(); fitStages(); };
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", go);
    else go();
  };
})();
