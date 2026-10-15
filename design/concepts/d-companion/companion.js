// Theme toggle (auto -> Paper -> Chalkboard) and small interactions for Concept D.
(function () {
  var root = document.documentElement, order = ["auto", "light", "dark"],
      names = { auto: "auto", light: "Paper", dark: "Chalkboard" }, saved = null;
  try { saved = localStorage.getItem("ws-theme"); } catch (e) {}
  var mode = order.indexOf(saved) >= 0 ? saved : "auto";
  function apply() {
    if (mode === "auto") root.removeAttribute("data-theme"); else root.setAttribute("data-theme", mode);
    var b = document.querySelector(".theme-toggle");
    if (b) { b.textContent = "Theme: " + names[mode]; b.setAttribute("aria-label", "Theme: " + names[mode] + ". Click to change."); }
  }
  apply();
  var S = {
    pin: '<path d="M8 10.5V14M5 2.5h6M6 2.5v4L4 9h8l-2-2.5v-4"/>',
    open: '<rect x="2.5" y="2.5" width="11" height="11" rx="1.2"/><path d="M9.5 2.5v11"/>',
    play: '<path d="M5.5 3.5v9l7-4.5z" fill="currentColor" stroke="none"/>',
    search: '<circle cx="7" cy="7" r="4.2"/><path d="M10.2 10.2 13.5 13.5"/>',
    mic: '<rect x="6" y="2" width="4" height="7.5" rx="2"/><path d="M3.8 8a4.2 4.2 0 0 0 8.4 0M8 12.2V14"/>',
    stop: '<rect x="4" y="4" width="8" height="8" rx="1.2" fill="currentColor" stroke="none"/>',
    up: '<path d="M8 13V3.5M4 7.5l4-4 4 4"/>',
    close: '<path d="M4 4l8 8M12 4l-8 8"/>',
    clip: '<path d="M12.5 7.5 8 12a2.8 2.8 0 0 1-4-4l4.8-4.8a1.9 1.9 0 0 1 2.7 2.7L6.8 10.6a.9.9 0 0 1-1.3-1.3L9.6 5.2"/>',
    more: '<circle cx="3.5" cy="8" r=".9"/><circle cx="8" cy="8" r=".9"/><circle cx="12.5" cy="8" r=".9"/>',
    chev: '<path d="M6 3.5 10.5 8 6 12.5"/>',
    check: '<path d="M3.5 8.5 6.5 11.5 12.5 4.5"/>',
    vault: '<path d="M8 2 13 5v6l-5 3-5-3V5z"/><path d="M8 2v12M3 5l5 3 5-3"/>',
    link: '<path d="M7 9a2.5 2.5 0 0 0 3.5 0l2-2A2.5 2.5 0 0 0 9 3.5l-.8.8M9 7a2.5 2.5 0 0 0-3.5 0l-2 2A2.5 2.5 0 0 0 7 12.5l.8-.8"/>'
  };
  var sp = '<svg width="0" height="0" style="position:absolute" aria-hidden="true" focusable="false"><defs>' +
    '<filter id="iw-gouache" x="-5%" y="-5%" width="110%" height="110%"><feTurbulence type="fractalNoise" baseFrequency="0.06" numOctaves="2" seed="2" result="n"/><feDisplacementMap in="SourceGraphic" in2="n" scale="3.5" xChannelSelector="R" yChannelSelector="G"/></filter>' +
    '<filter id="iw-wash" x="-8%" y="-8%" width="116%" height="116%"><feTurbulence type="fractalNoise" baseFrequency="0.028" numOctaves="3" seed="4" result="n"/><feDisplacementMap in="SourceGraphic" in2="n" scale="9" xChannelSelector="R" yChannelSelector="G"/></filter>';
  Object.keys(S).forEach(function (k) { sp += '<symbol id="i-' + k + '" viewBox="0 0 16 16">' + S[k] + '</symbol>'; });
  sp += '</defs></svg>';
  document.addEventListener("DOMContentLoaded", function () {
    document.body.insertAdjacentHTML("afterbegin", sp);
    apply();
    var b = document.querySelector(".theme-toggle");
    if (b) b.addEventListener("click", function () {
      mode = order[(order.indexOf(mode) + 1) % 3];
      try { localStorage.setItem("ws-theme", mode); } catch (e) {}
      apply();
    });
    // Toggle buttons (pin, mode switches, moment cards)
    document.querySelectorAll("[data-toggle]").forEach(function (el) {
      el.addEventListener("click", function () {
        var group = el.getAttribute("data-toggle");
        if (group && group !== "self") document.querySelectorAll('[data-toggle="' + group + '"]').forEach(function (o) { o.setAttribute("aria-pressed", "false"); });
        el.setAttribute("aria-pressed", group === "self" ? String(el.getAttribute("aria-pressed") !== "true") : "true");
        var t = el.getAttribute("data-sheet");
        if (t) document.querySelectorAll("[data-panel]").forEach(function (p) { p.hidden = p.getAttribute("data-panel") !== t; });
      });
    });
  });
})();
