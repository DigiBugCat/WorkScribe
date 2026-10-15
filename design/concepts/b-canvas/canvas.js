// Concept B · Canvas — theme toggle, pan, card drag, connectors, minimap.
(function () {
  var root = document.documentElement;
  var order = ["auto", "light", "dark"], names = { auto: "auto", light: "Paper", dark: "Chalkboard" };
  var saved = null;
  try { saved = localStorage.getItem("ws-theme"); } catch (e) {}
  var mode = order.indexOf(saved) >= 0 ? saved : "auto";
  function apply(m) {
    if (m === "auto") root.removeAttribute("data-theme"); else root.setAttribute("data-theme", m);
    var b = document.querySelector(".theme-toggle");
    if (b) { b.textContent = "Theme: " + names[m]; b.setAttribute("aria-label", "Theme: " + names[m] + ". Click to change."); }
  }
  apply(mode);

  // Small stroked icons
  var I = {
    select: '<path d="M4 2.5l8 5-3.6.9L10.5 13l-1.6.7-2-4.4L4 12z"/>',
    jot: '<path d="M3 13l1-3.5L11 2.5l2.5 2.5L6.5 12z"/><path d="M9.5 4l2.5 2.5"/>',
    link: '<path d="M3 12c3-1 4-8 10-8"/><path d="M10.5 2.8 13 4l-1.2 2.5"/>',
    frame: '<rect x="2.5" y="3.5" width="11" height="9" rx="1.5"/><path d="M2.5 6h11"/>',
    ask: '<path d="M2.5 3.5h11v7H7l-3 2.5v-2.5H2.5z"/>',
    search: '<circle cx="7" cy="7" r="4.2"/><path d="M10.2 10.2 13.5 13.5"/>',
    fit: '<path d="M2.5 6V2.5H6M10 2.5h3.5V6M13.5 10v3.5H10M6 13.5H2.5V10"/>',
    play: '<path d="M5.5 3.5v9l7-4.5z" fill="currentColor" stroke="none"/>',
    stop: '<rect x="4" y="4" width="8" height="8" rx="1.2" fill="currentColor" stroke="none"/>'
  };
  document.addEventListener("DOMContentLoaded", function () {
    document.querySelectorAll("i[data-i]").forEach(function (el) {
      var s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      s.setAttribute("viewBox", "0 0 16 16"); s.setAttribute("class", "ico"); s.setAttribute("aria-hidden", "true");
      s.innerHTML = I[el.dataset.i] || ""; el.replaceWith(s);
    });

    var tb = document.querySelector(".theme-toggle");
    if (tb) { apply(mode); tb.addEventListener("click", function () {
      mode = order[(order.indexOf(mode) + 1) % 3]; apply(mode);
      try { localStorage.setItem("ws-theme", mode); } catch (e) {}
    }); }

    document.querySelectorAll(".viewport").forEach(setup);
  });

  function setup(vp) {
    var board = vp.querySelector(".board");
    var svg = board.querySelector("svg.links");
    var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    function box(el) { return { x: el.offsetLeft, y: el.offsetTop, w: el.offsetWidth, h: el.offsetHeight }; }
    function anchor(b, side) {
      if (side === "l") return [b.x, b.y + b.h / 2];
      if (side === "r") return [b.x + b.w, b.y + b.h / 2];
      if (side === "t") return [b.x + b.w / 2, b.y];
      return [b.x + b.w / 2, b.y + b.h];
    }
    function draw() {
      if (!svg) return;
      svg.querySelectorAll("path[data-a]").forEach(function (p) {
        var a = document.getElementById(p.dataset.a), b = document.getElementById(p.dataset.b);
        if (!a || !b) return;
        var A = box(a), B = box(b), sa, sb;
        var dx = (B.x + B.w / 2) - (A.x + A.w / 2), dy = (B.y + B.h / 2) - (A.y + A.h / 2);
        if (p.dataset.s) { sa = p.dataset.s[0]; sb = p.dataset.s[1]; }
        else if (Math.abs(dx) > Math.abs(dy) * 0.6) { sa = dx > 0 ? "r" : "l"; sb = dx > 0 ? "l" : "r"; }
        else { sa = dy > 0 ? "b" : "t"; sb = dy > 0 ? "t" : "b"; }
        var p1 = anchor(A, sa), p2 = anchor(B, sb);
        var k = Math.max(40, Math.min(160, Math.hypot(p2[0] - p1[0], p2[1] - p1[1]) / 2.4));
        function off(s, pt, sign) {
          return s === "l" ? [pt[0] - k, pt[1]] : s === "r" ? [pt[0] + k, pt[1]] : s === "t" ? [pt[0], pt[1] - k] : [pt[0], pt[1] + k];
        }
        var c1 = off(sa, p1), c2 = off(sb, p2);
        var d = "M" + p1.join(" ") + " C" + c1.join(" ") + " " + c2.join(" ") + " " + p2.join(" ");
        p.setAttribute("d", d);
        // open arrowhead (never filled)
        var ah = p.nextElementSibling;
        if (ah && ah.classList.contains("arrow")) {
          var ang = Math.atan2(p2[1] - c2[1], p2[0] - c2[0]), L = 7;
          var a1 = [p2[0] - L * Math.cos(ang - 0.45), p2[1] - L * Math.sin(ang - 0.45)];
          var a2 = [p2[0] - L * Math.cos(ang + 0.45), p2[1] - L * Math.sin(ang + 0.45)];
          ah.setAttribute("d", "M" + a1.join(" ") + " L" + p2.join(" ") + " L" + a2.join(" "));
        }
      });
      mini();
    }

    // minimap
    var mm = vp.parentElement.querySelector(".minimap"), vpr;
    function mini() {
      if (!mm) return;
      var W = board.offsetWidth, H = board.offsetHeight, s = Math.min(mm.clientWidth / W, mm.clientHeight / H);
      if (!mm.dataset.built) {
        mm.dataset.built = 1;
        board.querySelectorAll(".frame, .card").forEach(function (el) {
          var d = document.createElement("i"); d.className = el.classList.contains("frame") ? "mf" : "mm"; d._src = el; mm.appendChild(d);
        });
        vpr = document.createElement("i"); vpr.className = "vp"; mm.appendChild(vpr);
      }
      mm.querySelectorAll(".mm, .mf").forEach(function (d) {
        var b = box(d._src);
        d.style.cssText = "left:" + b.x * s + "px;top:" + b.y * s + "px;width:" + Math.max(2, b.w * s) + "px;height:" + Math.max(2, b.h * s) + "px";
      });
      vpr = mm.querySelector(".vp");
      vpr.style.cssText = "left:" + vp.scrollLeft * s + "px;top:" + vp.scrollTop * s + "px;width:" + vp.clientWidth * s + "px;height:" + vp.clientHeight * s + "px";
    }
    vp.addEventListener("scroll", mini, { passive: true });
    window.addEventListener("resize", draw);

    // initial position
    if (vp.dataset.x) vp.scrollLeft = +vp.dataset.x;
    if (vp.dataset.y) vp.scrollTop = +vp.dataset.y;

    // pan on background, drag on cards
    var drag = null;
    vp.addEventListener("pointerdown", function (e) {
      if (e.button !== 0 || e.target.closest("button, a, input, .dock")) return;
      var card = e.target.closest(".card");
      if (card) {
        drag = { el: card, sx: e.clientX, sy: e.clientY, x: card.offsetLeft, y: card.offsetTop };
        card.classList.add("dragging");
      } else if (e.pointerType === "mouse") {
        drag = { pan: true, sx: e.clientX, sy: e.clientY, x: vp.scrollLeft, y: vp.scrollTop };
        vp.classList.add("panning");
      } else return;
      vp.setPointerCapture(e.pointerId);
    });
    vp.addEventListener("pointermove", function (e) {
      if (!drag) return;
      var dx = e.clientX - drag.sx, dy = e.clientY - drag.sy;
      if (drag.pan) { vp.scrollLeft = drag.x - dx; vp.scrollTop = drag.y - dy; return; }
      drag.el.style.left = Math.max(0, drag.x + dx) + "px"; drag.el.style.top = Math.max(0, drag.y + dy) + "px";
      draw();
    });
    function end() { if (!drag) return; if (drag.el) drag.el.classList.remove("dragging"); vp.classList.remove("panning"); drag = null; }
    vp.addEventListener("pointerup", end); vp.addEventListener("pointercancel", end);

    // keyboard: arrow keys nudge a focused card
    board.querySelectorAll(".card").forEach(function (c) {
      if (!c.hasAttribute("tabindex")) c.setAttribute("tabindex", "0");
      c.addEventListener("keydown", function (e) {
        var m = { ArrowLeft: [-12, 0], ArrowRight: [12, 0], ArrowUp: [0, -12], ArrowDown: [0, 12] }[e.key];
        if (!m || e.target !== c) return;
        e.preventDefault();
        c.style.left = Math.max(0, c.offsetLeft + m[0]) + "px"; c.style.top = Math.max(0, c.offsetTop + m[1]) + "px"; draw();
      });
    });

    // fit button scrolls back to start position
    var fit = vp.parentElement.querySelector("[data-fit]");
    if (fit) fit.addEventListener("click", function () {
      vp.scrollTo({ left: +(vp.dataset.x || 0), top: +(vp.dataset.y || 0), behavior: reduce ? "auto" : "smooth" });
    });

    draw();
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(draw);
  }
})();
