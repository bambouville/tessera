// Click-to-enlarge for docs screenshots.
//
// The enlarged view is the same figure promoted, not a new surface: the image
// animates from its exact position on the page to the centre of the viewport
// (FLIP — only transform and opacity are animated), and keeps the hairline
// border and radius it has inline. Its only chrome is the caption and an esc
// keycap, matching the accessory-bar chips in the app the docs describe.
//
// Anchors keep their href, so with JS off a click still opens the image.
(function () {
  "use strict";

  var OPEN_MS = 260;
  var CLOSE_MS = 200;
  var EASE = "cubic-bezier(0.22, 0.61, 0.36, 1)";

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");

  var css = [
    ".bv-lightbox{position:fixed;inset:0;z-index:100;display:flex;",
    "align-items:center;justify-content:center;",
    "padding:max(24px,4vh) max(24px,4vw);cursor:zoom-out;",
    "padding:max(24px,4dvh) max(24px,4vw);",
    // Keep touch scrolling from reaching the page behind the overlay.
    "touch-action:none;overscroll-behavior:contain;",
    "-webkit-tap-highlight-color:transparent;",
    "background:rgba(10,10,10,0.78);opacity:0;",
    "transition:opacity " + OPEN_MS + "ms ease}",
    ".bv-lightbox.is-open{opacity:1}",
    "@media (prefers-color-scheme: dark){.bv-lightbox{background:rgba(0,0,0,0.88)}}",
    // The image carries the same hairline treatment as the inline figure.
    // min-height:0 so the image can shrink inside the column flex container
    // on short viewports; flex items default to min-height:auto.
    ".bv-lightbox img{display:block;max-width:100%;max-height:82vh;width:auto;height:auto;min-height:0;",
    // dvh tracks the *visible* viewport; iOS Safari's vh is the toolbars-hidden
    // height, which would let the image sit under the toolbar.
    "max-height:82dvh;",
    "border:1px solid rgba(245,242,236,0.18);border-radius:10px;",
    "box-shadow:0 24px 70px rgba(0,0,0,0.45);transform-origin:top left;will-change:transform}",
    // The frame shrink-wraps the image so the caption row lines up exactly
    // with its edges rather than floating at some arbitrary width.
    ".bv-lightbox .bv-frame{display:flex;flex-direction:column;align-items:center;",
    "gap:14px;margin:0;max-width:100%;max-height:100%;min-height:0}",
    // Caption row: text left, keycap right, spanning the image width.
    ".bv-lightbox figcaption{display:flex;align-items:center;justify-content:space-between;",
    "gap:20px;margin:0;",
    'font-family:"JetBrains Mono","SF Mono",ui-monospace,monospace;',
    "font-size:11.5px;line-height:1.5;color:rgba(245,242,236,0.62);",
    "opacity:0;transition:opacity 160ms ease " + Math.round(OPEN_MS * 0.5) + "ms}",
    ".bv-lightbox.is-open figcaption{opacity:1}",
    ".bv-lightbox .bv-esc{flex:none;appearance:none;background:rgba(245,242,236,0.08);",
    "color:rgba(245,242,236,0.72);border:1px solid rgba(245,242,236,0.16);border-radius:4px;",
    "padding:2px 8px;font:inherit;cursor:pointer}",
    "@media (hover:hover){.bv-lightbox .bv-esc:hover{color:#F5F2EC;border-color:rgba(245,242,236,0.38)}}",
    ".bv-lightbox .bv-esc:focus-visible{outline:2px solid #5B9FFF;outline-offset:2px}",
    "@media (prefers-reduced-motion: reduce){",
    ".bv-lightbox,.bv-lightbox img,.bv-lightbox figcaption{transition-duration:1ms!important}}",
    // The image must not exceed the viewport once the caption row is allowed
    // for; 82vh leaves room for it plus the container padding.
    "@media (max-height:620px){.bv-lightbox img{max-height:72vh}}"
  ].join("");

  var style = document.createElement("style");
  style.textContent = css;
  document.head.appendChild(style);

  var active = null;

  var scrollY = 0;

  // overflow:hidden alone does not hold in iOS Safari, so the body is pinned
  // at its current offset and restored on close.
  function lockScroll() {
    scrollY = window.scrollY || window.pageYOffset || 0;
    var bar = window.innerWidth - document.documentElement.clientWidth;
    var b = document.body.style;
    b.position = "fixed";
    b.top = -scrollY + "px";
    b.left = "0";
    b.right = "0";
    b.width = "100%";
    b.overflow = "hidden";
    if (bar > 0) b.paddingRight = bar + "px";
  }

  function unlockScroll() {
    var b = document.body.style;
    b.position = "";
    b.top = "";
    b.left = "";
    b.right = "";
    b.width = "";
    b.overflow = "";
    b.paddingRight = "";
    window.scrollTo(0, scrollY);
  }

  // Map the element from its laid-out rect back onto `from`, so the opening
  // transition can run to identity.
  function invert(el, from) {
    var to = el.getBoundingClientRect();
    var sx = from.width / to.width;
    var sy = from.height / to.height;
    return "translate(" + (from.left - to.left) + "px," + (from.top - to.top) + "px) scale(" +
      sx + "," + sy + ")";
  }

  // The image is height-constrained, so the frame cannot shrink-wrap it with
  // CSS alone. Match the caption to the image's rendered width so the keycap
  // sits exactly on the image's right edge.
  function syncCaption() {
    if (!active) return;
    // offsetWidth, not getBoundingClientRect: the latter reports the visual
    // rect, which during the opening FLIP is still the inline thumbnail size.
    var w = active.img.offsetWidth;
    if (w > 0) active.caption.style.width = w + "px";
  }

  function close() {
    if (!active) return;
    var box = active.box;
    var img = active.img;
    var source = active.source;
    var restore = active.restore;
    active = null;

    document.removeEventListener("keydown", onKeydown, true);
    window.removeEventListener("resize", syncCaption);
    box.classList.remove("is-open");

    var rect = source.getBoundingClientRect();
    var visible = rect.width > 0 && rect.height > 0;
    if (visible && !reduced.matches) {
      img.style.transition = "transform " + CLOSE_MS + "ms " + EASE;
      img.style.transform = invert(img, rect);
    }

    window.setTimeout(function () {
      box.remove();
      unlockScroll();
      source.style.visibility = "";
      if (restore && document.contains(restore)) restore.focus({ preventScroll: true });
    }, reduced.matches ? 10 : CLOSE_MS);
  }

  function onKeydown(event) {
    if (!active) return;
    if (event.key === "Escape") {
      event.preventDefault();
      close();
    } else if (event.key === "Tab") {
      // Only one focusable control inside, so keep focus on it.
      event.preventDefault();
      active.esc.focus();
    }
  }

  function open(source, caption) {
    if (active) return;
    var rect = source.getBoundingClientRect();

    var box = document.createElement("div");
    box.className = "bv-lightbox";
    box.setAttribute("role", "dialog");
    box.setAttribute("aria-modal", "true");
    box.setAttribute("aria-label", source.alt || "Screenshot");
    // Focus the dialog, not the keycap: a programmatic focus on the button
    // draws a focus ring even for touch taps. Tab still reaches the keycap.
    box.tabIndex = -1;

    var img = document.createElement("img");
    img.src = source.currentSrc || source.src;
    img.alt = source.alt || "";

    var figcaption = document.createElement("figcaption");
    var text = document.createElement("span");
    text.textContent = caption || source.alt || "";
    var esc = document.createElement("button");
    esc.type = "button";
    esc.className = "bv-esc";
    esc.textContent = "esc";
    figcaption.appendChild(text);
    figcaption.appendChild(esc);

    var frame = document.createElement("figure");
    frame.className = "bv-frame";
    frame.appendChild(img);
    frame.appendChild(figcaption);
    box.appendChild(frame);

    var restore = document.activeElement;
    lockScroll();
    document.body.appendChild(box);

    active = { box: box, img: img, source: source, restore: restore, esc: esc,
      caption: figcaption };

    // Hide the inline image so the enlarged one reads as the same object
    // moving, rather than a copy peeling off a duplicate.
    source.style.visibility = "hidden";

    if (!reduced.matches) {
      img.style.transition = "none";
      img.style.transform = invert(img, rect);
    }
    // Flush the initial state (backdrop opacity 0, image mapped onto the
    // inline figure) before changing it, so both transitions actually run.
    // A forced reflow is used rather than requestAnimationFrame, which does
    // not fire in a background tab and would leave the overlay invisible.
    void box.offsetWidth;
    if (!reduced.matches) {
      img.style.transition = "transform " + OPEN_MS + "ms " + EASE;
      img.style.transform = "none";
    }
    box.classList.add("is-open");

    // Attach after the opening click has finished propagating. The overlay is
    // inserted under the cursor, so a listener added synchronously receives
    // that same click and closes immediately.
    window.setTimeout(function () {
      if (!active || active.box !== box) return;
      box.addEventListener("click", function () { close(); });
    }, 0);
    syncCaption();
    // The enlarged image may not have its final layout width yet on a cold
    // load; re-sync once it does.
    if (!img.complete) img.addEventListener("load", syncCaption);
    window.setTimeout(syncCaption, OPEN_MS + 40);
    window.addEventListener("resize", syncCaption);
    document.addEventListener("keydown", onKeydown, true);
    box.focus({ preventScroll: true });
  }

  function wire() {
    var links = document.querySelectorAll('.docs-content figure a[href$=".png"]');
    Array.prototype.forEach.call(links, function (link) {
      var img = link.querySelector("img");
      if (!img) return;
      var fig = link.closest("figure");
      var cap = fig ? fig.querySelector("figcaption") : null;
      var text = cap ? cap.textContent.trim() : "";
      link.addEventListener("click", function (event) {
        // Leave modified clicks to the browser: opening in a new tab or
        // saving the file are still reasonable things to want.
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey ||
            event.button !== 0) return;
        event.preventDefault();
        open(img, text);
      });
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", wire);
  } else {
    wire();
  }
})();
