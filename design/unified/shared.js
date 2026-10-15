// Theme toggle for the mockups (auto -> Paper -> Chalkboard), live switches,
// and the shared icon sprite + Indigo Wash SVG filters (injected once per page).
(function () {
  var root = document.documentElement;
  var order = ["auto", "light", "dark"];
  var names = { auto: "auto", light: "Paper", dark: "Chalkboard" };
  var saved = null;
  try { saved = localStorage.getItem("ws-theme"); } catch (e) {}
  function apply(mode) {
    if (mode === "auto") root.removeAttribute("data-theme"); else root.setAttribute("data-theme", mode);
    var b = document.querySelector(".theme-toggle");
    if (b) {
      b.textContent = "Theme: " + names[mode];
      b.setAttribute("aria-label", "Theme: " + names[mode] + ". Click to change.");
    }
  }
  var mode = order.indexOf(saved) >= 0 ? saved : "auto";
  apply(mode);

  // 16px line icons, stroked with currentColor (see .ico in shared.css).
  var S = {
    sidebar: '<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M6 3v10"/>',
    back: '<path d="M10 3.5 5.5 8 10 12.5"/>',
    chev: '<path d="M6 3.5 10.5 8 6 12.5"/>',
    search: '<circle cx="7" cy="7" r="4.2"/><path d="M10.2 10.2 13.5 13.5"/>',
    plus: '<path d="M8 3v10M3 8h10"/>',
    ask: '<path d="M2.5 3.5h11v7H7l-3 2.5v-2.5H2.5z"/>',
    today: '<rect x="2.5" y="3.5" width="11" height="10" rx="1.2"/><path d="M2.5 6.5h11M5.5 2v3M10.5 2v3"/>',
    meetings: '<path d="M3 8v0M5.5 5.5v5M8 3v10M10.5 5.5v5M13 7.5v1"/>',
    notes: '<path d="M4 2.5h5.5L12 5v8.5H4z"/><path d="M9.5 2.5V5H12M6 8h4M6 10.5h3"/>',
    people: '<circle cx="6" cy="5.5" r="2.2"/><path d="M2.5 13c.4-2.3 1.8-3.5 3.5-3.5s3.1 1.2 3.5 3.5"/><circle cx="11" cy="6" r="1.7"/><path d="M10.5 9.6c1.5 0 2.6.9 3 3"/>',
    folder: '<path d="M2 4.5a1 1 0 0 1 1-1h3l1.5 1.5H13a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1z"/>',
    sliders: '<path d="M2.5 5h4.2M9.8 5h3.7M2.5 11h1.7M7.3 11h6.2"/><circle cx="8.2" cy="5" r="1.5"/><circle cx="5.7" cy="11" r="1.5"/>',
    mic: '<rect x="6" y="2" width="4" height="7.5" rx="2"/><path d="M3.8 8a4.2 4.2 0 0 0 8.4 0M8 12.2V14"/>',
    sys: '<path d="M2.5 6.2h2.3L8 3.5v9L4.8 9.8H2.5z"/><path d="M10.5 6a2.8 2.8 0 0 1 0 4M12.3 4.2a5.3 5.3 0 0 1 0 7.6"/>',
    stop: '<rect x="4" y="4" width="8" height="8" rx="1.2" fill="currentColor" stroke="none"/>',
    rec: '<circle cx="8" cy="8" r="4" fill="currentColor" stroke="none"/>',
    play: '<path d="M5.5 3.5v9l7-4.5z" fill="currentColor" stroke="none"/>',
    popout: '<rect x="2.5" y="5.5" width="8" height="8" rx="1.2"/><path d="M9 2.5h4.5V7M13.5 2.5 8 8"/>',
    pin: '<path d="M8 10.5V14M5 2.5h6M6 2.5v4L4 9h8l-2-2.5v-4"/>',
    share: '<path d="M8 2.5v8M5 5.5 8 2.5l3 3M3.5 9v3.5h9V9"/>',
    more: '<circle cx="3.5" cy="8" r=".9"/><circle cx="8" cy="8" r=".9"/><circle cx="12.5" cy="8" r=".9"/>',
    up: '<path d="M8 13V3.5M4 7.5l4-4 4 4"/>',
    at: '<circle cx="8" cy="8" r="2.4"/><path d="M10.4 8v1.2a1.6 1.6 0 0 0 3.2 0V8A5.6 5.6 0 1 0 11 12.8"/>',
    clip: '<path d="M12.5 7.5 8 12a2.8 2.8 0 0 1-4-4l4.8-4.8a1.9 1.9 0 0 1 2.7 2.7L6.8 10.6a.9.9 0 0 1-1.3-1.3L9.6 5.2"/>',
    bell: '<path d="M4 11.5V7.5a4 4 0 0 1 8 0v4l1 1H3z"/><path d="M6.8 14h2.4"/>',
    link: '<path d="M7 9a2.5 2.5 0 0 0 3.5 0l2-2A2.5 2.5 0 0 0 9 3.5l-.8.8M9 7a2.5 2.5 0 0 0-3.5 0l-2 2A2.5 2.5 0 0 0 7 12.5l.8-.8"/>',
    check: '<path d="M3.5 8.5 6.5 11.5 12.5 4.5"/>',
    edit: '<path d="M10.5 3 13 5.5 6 12.5H3.5V10z"/>',
    window: '<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M2 6h12"/>',
    md: '<rect x="1.8" y="4" width="12.4" height="8" rx="1.2"/><path d="M4 10V6.2l1.6 1.9L7.2 6.2V10M10.6 6.2V10M9.2 8.6l1.4 1.4 1.4-1.4"/>',
    wave: '<path d="M3 8v0M6 5v6M9 2.5v11M12 5.5v5M15 7.5v1"/>'
  };
  var sprite =
    '<svg width="0" height="0" style="position:absolute" aria-hidden="true" focusable="false"><defs>' +
    '<filter id="iw-gouache" x="-5%" y="-5%" width="110%" height="110%"><feTurbulence type="fractalNoise" baseFrequency="0.06" numOctaves="2" seed="2" result="n"/><feDisplacementMap in="SourceGraphic" in2="n" scale="3.5" xChannelSelector="R" yChannelSelector="G"/></filter>' +
    '<filter id="iw-wash" x="-8%" y="-8%" width="116%" height="116%"><feTurbulence type="fractalNoise" baseFrequency="0.028" numOctaves="3" seed="4" result="n"/><feDisplacementMap in="SourceGraphic" in2="n" scale="9" xChannelSelector="R" yChannelSelector="G" result="d"/><feTurbulence type="fractalNoise" baseFrequency="0.09" numOctaves="3" seed="9" result="m"/><feColorMatrix in="m" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -0.7 1.15" result="ma"/><feComposite in="d" in2="ma" operator="in"/></filter>' +
    '<filter id="iw-wobble" x="-5%" y="-5%" width="110%" height="110%"><feTurbulence type="fractalNoise" baseFrequency="0.03" numOctaves="1" seed="6" result="n"/><feDisplacementMap in="SourceGraphic" in2="n" scale="1.2" xChannelSelector="R" yChannelSelector="G"/></filter>';
  Object.keys(S).forEach(function (k) {
    sprite += '<symbol id="i-' + k + '" viewBox="0 0 ' + (k === "wave" ? "18 16" : "16 16") + '">' + S[k] + '</symbol>';
  });
  sprite += '</defs></svg>';

  document.addEventListener("DOMContentLoaded", function () {
    document.body.insertAdjacentHTML("afterbegin", sprite);
    apply(mode);
    var b = document.querySelector(".theme-toggle");
    if (b) b.addEventListener("click", function () {
      mode = order[(order.indexOf(mode) + 1) % order.length];
      try { localStorage.setItem("ws-theme", mode); } catch (e) {}
      apply(mode);
    });
    // Paper-tab switches: role="switch" buttons flip aria-checked and their state word.
    document.querySelectorAll('.tog[role="switch"]').forEach(function (t) {
      t.addEventListener("click", function () {
        var on = t.getAttribute("aria-checked") !== "true";
        t.setAttribute("aria-checked", String(on));
        var s = t.querySelector(".state");
        if (s) s.textContent = on ? "On" : "Off";
      });
    });
    // Segmented controls: one choice at a time.
    document.querySelectorAll('.seg[role="radiogroup"]').forEach(function (g) {
      g.addEventListener("click", function (e) {
        var btn = e.target.closest('button[role="radio"]');
        if (!btn) return;
        g.querySelectorAll('button[role="radio"]').forEach(function (x) { x.setAttribute("aria-checked", String(x === btn)); });
      });
    });
  });
})();
