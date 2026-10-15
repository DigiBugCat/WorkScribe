// Theme toggle (auto -> Paper -> Chalkboard). localStorage is a convenience only.
(function () {
  var root = document.documentElement;
  var order = ["auto", "light", "dark"];
  var names = { auto: "auto", light: "Paper", dark: "Chalkboard" };
  var mode = "auto";
  try { var s = localStorage.getItem("ws-daybook-theme"); if (order.indexOf(s) >= 0) mode = s; } catch (e) {}
  function apply(m) {
    if (m === "auto") root.removeAttribute("data-theme"); else root.setAttribute("data-theme", m);
    var b = document.querySelector(".theme-toggle");
    if (b) { b.textContent = "Theme: " + names[m]; b.setAttribute("aria-label", "Theme: " + names[m] + ". Click to change."); }
  }
  apply(mode);
  document.addEventListener("DOMContentLoaded", function () {
    apply(mode);
    var b = document.querySelector(".theme-toggle");
    if (b) b.addEventListener("click", function () {
      mode = order[(order.indexOf(mode) + 1) % order.length];
      apply(mode);
      try { localStorage.setItem("ws-daybook-theme", mode); } catch (e) {}
    });
    // Static segmented controls: make them feel live
    document.querySelectorAll(".seg").forEach(function (g) {
      g.addEventListener("click", function (ev) {
        var t = ev.target.closest("button"); if (!t) return;
        g.querySelectorAll("button").forEach(function (x) { x.setAttribute("aria-pressed", x === t ? "true" : "false"); });
      });
    });
  });
})();
