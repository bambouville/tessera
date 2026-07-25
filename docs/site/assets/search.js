// Docs search: a keyboard-first palette over a per-section index.
//
// These are docs for a keyboard-driven terminal, so search is driven the same
// way: ⌘K (or ctrl+K, or "/") opens it, ↑/↓ move, ↵ opens, esc closes. The
// palette borrows the lightbox's language — dimmed backdrop, hairline border,
// mono type, keycap chips — so the two feel like one system.
//
// The index is fetched on first open, never on page load, so it costs nothing
// to readers who don't search.
(function () {
  "use strict";

  var INDEX_URL = "/docs/assets/search-index.json";
  var MAX_RESULTS = 12;

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  var index = null;
  var loading = null;
  var box = null;
  var input = null;
  var list = null;
  var results = [];
  var cursor = 0;
  var restore = null;
  var scrollY = 0;

  var css = [
    ".bv-search{position:fixed;inset:0;z-index:110;display:flex;",
    "align-items:flex-start;justify-content:center;",
    "padding:max(48px,10vh) 20px 20px;padding:max(48px,10dvh) 20px 20px;",
    "background:rgba(10,10,10,0.62);opacity:0;",
    "touch-action:none;overscroll-behavior:contain;",
    "-webkit-tap-highlight-color:transparent;",
    "transition:opacity 160ms ease}",
    ".bv-search.is-open{opacity:1}",
    "@media (prefers-color-scheme: dark){.bv-search{background:rgba(0,0,0,0.74)}}",
    ".bv-search-panel{display:flex;flex-direction:column;width:100%;max-width:640px;",
    "max-height:74vh;max-height:74dvh;background:var(--paper);",
    "border:1px solid var(--line);border-radius:12px;overflow:hidden;",
    "box-shadow:0 30px 80px rgba(0,0,0,0.35);cursor:auto;",
    "transform:translateY(-6px);transition:transform 160ms ease}",
    ".bv-search.is-open .bv-search-panel{transform:none}",
    ".bv-search-field{display:flex;align-items:center;gap:10px;padding:14px 16px;",
    "border-bottom:1px solid var(--line)}",
    ".bv-search-field .sigil{color:var(--ink-dim);font-size:13px}",
    ".bv-search-field input{flex:1;min-width:0;appearance:none;background:none;border:0;",
    "font-family:var(--mono);font-size:14px;color:var(--ink);padding:0}",
    ".bv-search-field input:focus{outline:none}",
    ".bv-search-field input::placeholder{color:var(--ink-faint)}",
    ".bv-search-results{list-style:none;margin:0;padding:6px;overflow-y:auto;",
    "-webkit-overflow-scrolling:touch;overscroll-behavior:contain}",
    ".bv-search-results li{margin:0}",
    ".bv-search-results a{display:block;padding:9px 10px;border-radius:7px;",
    "text-decoration:none;color:inherit}",
    ".bv-search-results .crumb{font-size:10.5px;letter-spacing:0.06em;",
    "text-transform:uppercase;color:var(--ink-dim)}",
    ".bv-search-results .title{font-size:13px;color:var(--ink);margin-top:2px}",
    ".bv-search-results .snip{font-size:11.5px;color:var(--ink-mute);margin-top:3px;",
    "display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}",
    ".bv-search-results mark{background:none;color:var(--blue);font-weight:600}",
    ".bv-search-results li.sel a{background:rgba(91,159,255,0.12)}",
    ".bv-search-empty{padding:22px 16px;font-size:12.5px;color:var(--ink-dim)}",
    ".bv-search-foot{display:flex;align-items:center;gap:14px;padding:9px 14px;",
    "border-top:1px solid var(--line);font-size:10.5px;color:var(--ink-dim)}",
    ".bv-search-foot .n{margin-left:auto}",
    ".bv-search-foot kbd{font-family:var(--mono);font-size:10px;",
    "background:rgba(10,10,10,0.055);border:1px solid rgba(10,10,10,0.09);",
    "border-radius:4px;padding:1px 5px}",
    "@media (prefers-color-scheme: dark){.bv-search-foot kbd{",
    "background:rgba(245,242,236,0.07);border-color:rgba(245,242,236,0.1)}}",
    "@media (prefers-reduced-motion: reduce){",
    ".bv-search,.bv-search-panel{transition-duration:1ms!important}}",
    // iPadOS does not shrink the visual viewport for the software keyboard,
    // so on touch devices start the palette higher to keep more results above
    // it. The list scrolls for the rest.
    "@media (pointer:coarse){.bv-search{padding-top:max(16px,2dvh)}}"
  ].join("");

  var style = document.createElement("style");
  style.textContent = css;
  document.head.appendChild(style);

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  function lockScroll() {
    scrollY = window.scrollY || window.pageYOffset || 0;
    var b = document.body.style;
    b.position = "fixed";
    b.top = -scrollY + "px";
    b.left = "0";
    b.right = "0";
    b.width = "100%";
    b.overflow = "hidden";
  }

  // `keepScroll` is false when a result is being opened: for a same-page
  // anchor the browser has already jumped, and restoring the old offset would
  // yank the reader straight back to where they were searching from.
  function unlockScroll(keepScroll) {
    var b = document.body.style;
    b.position = ""; b.top = ""; b.left = ""; b.right = ""; b.width = ""; b.overflow = "";
    if (keepScroll !== false) window.scrollTo(0, scrollY);
  }

  function load() {
    if (index) return Promise.resolve(index);
    if (loading) return loading;
    loading = fetch(INDEX_URL)
      .then(function (r) { return r.ok ? r.json() : []; })
      .then(function (data) { index = data; return index; })
      .catch(function () { index = []; return index; });
    return loading;
  }

  function score(entry, terms) {
    var heading = (entry.h || entry.p).toLowerCase();
    var page = entry.p.toLowerCase();
    var body = entry.x.toLowerCase();
    var total = 0;
    for (var i = 0; i < terms.length; i++) {
      var t = terms[i];
      var inHeading = heading.indexOf(t);
      var inPage = page.indexOf(t);
      var inBody = body.indexOf(t);
      if (inHeading === -1 && inPage === -1 && inBody === -1) return 0; // all terms must appear
      if (inHeading === 0) total += 12;
      else if (inHeading > 0) total += 8;
      if (inPage !== -1) total += 3;
      if (inBody !== -1) total += 1;
    }
    // A section heading is a better landing spot than a page intro.
    if (entry.h) total += 1;
    return total;
  }

  function snippet(text, terms) {
    var lower = text.toLowerCase();
    var at = -1;
    for (var i = 0; i < terms.length && at === -1; i++) at = lower.indexOf(terms[i]);
    var start = at > 60 ? at - 50 : 0;
    // Snap to word boundaries so snippets don't start or end mid-word.
    if (start > 0) {
      var sp = text.indexOf(" ", start);
      start = sp === -1 ? start : sp + 1;
    }
    var slice = text.slice(start, start + 190);
    if (start + 190 < text.length) {
      var lastSp = slice.lastIndexOf(" ");
      if (lastSp > 120) slice = slice.slice(0, lastSp) + "…";
    }
    var html = esc((start > 0 ? "…" : "") + slice);
    terms.forEach(function (t) {
      if (!t) return;
      var re = new RegExp("(" + t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + ")", "ig");
      html = html.replace(re, "<mark>$1</mark>");
    });
    return html;
  }

  function render(query) {
    var terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    results = [];
    if (terms.length && index) {
      results = index
        .map(function (e) { return { e: e, s: score(e, terms) }; })
        .filter(function (r) { return r.s > 0; })
        .sort(function (a, b) { return b.s - a.s; })
        .slice(0, MAX_RESULTS)
        .map(function (r) { return r.e; });
    }
    cursor = 0;
    if (!terms.length) {
      list.innerHTML = '<li class="bv-search-empty">Search the guide by feature, ' +
        'setting, or error — “tmux”, “port forwarding”, “host key”.</li>';
    } else if (!results.length) {
      list.innerHTML = '<li class="bv-search-empty">No matches for “' +
        esc(query) + '”.</li>';
    } else {
      list.innerHTML = results.map(function (e, i) {
        var href = e.u + (e.a ? "#" + e.a : "");
        return '<li class="' + (i === 0 ? "sel" : "") + '" role="option" id="bv-r' + i +
          '" aria-selected="' + (i === 0) + '"><a href="' + esc(href) + '">' +
          (e.h ? '<div class="crumb">' + esc(e.p) + "</div>" : "") +
          '<div class="title">' + esc(e.h || e.p) + "</div>" +
          '<div class="snip">' + snippet(e.x, terms) + "</div></a></li>";
      }).join("");
    }
    var n = box.querySelector(".bv-search-foot .n");
    n.textContent = terms.length ? results.length + (results.length === 1 ? " result" : " results") : "";
    input.setAttribute("aria-activedescendant", results.length ? "bv-r0" : "");
  }

  function move(delta) {
    if (!results.length) return;
    var items = list.querySelectorAll("li");
    items[cursor].classList.remove("sel");
    items[cursor].setAttribute("aria-selected", "false");
    cursor = (cursor + delta + results.length) % results.length;
    items[cursor].classList.add("sel");
    items[cursor].setAttribute("aria-selected", "true");
    input.setAttribute("aria-activedescendant", "bv-r" + cursor);
    items[cursor].scrollIntoView({ block: "nearest" });
  }

  function go() {
    if (!results.length) return;
    var e = results[cursor];
    close(false);
    window.location.href = e.u + (e.a ? "#" + e.a : "");
  }

  // The iPad software keyboard covers the bottom of the screen without
  // changing the layout viewport, so results would hide behind it. Track the
  // visual viewport instead and size the overlay to what is actually visible.
  function fitViewport() {
    var vv = window.visualViewport;
    if (!box || !vv) return;
    box.style.top = vv.offsetTop + "px";
    box.style.height = vv.height + "px";
  }

  function close(keepScroll) {
    if (!box) return;
    var node = box;
    box = null;
    node.classList.remove("is-open");
    document.removeEventListener("keydown", onKeydown, true);
    if (window.visualViewport) {
      window.visualViewport.removeEventListener("resize", fitViewport);
      window.visualViewport.removeEventListener("scroll", fitViewport);
    }
    var navigating = keepScroll === false;
    if (navigating) {
      // Unpin immediately; the browser is about to act on the new anchor.
      node.remove();
      unlockScroll(false);
      return;
    }
    window.setTimeout(function () {
      node.remove();
      unlockScroll();
      if (restore && document.contains(restore)) restore.focus({ preventScroll: true });
    }, reduced.matches ? 10 : 160);
  }

  function onKeydown(event) {
    if (!box) return;
    if (event.key === "Escape") { event.preventDefault(); close(); }
    else if (event.key === "ArrowDown") { event.preventDefault(); move(1); }
    else if (event.key === "ArrowUp") { event.preventDefault(); move(-1); }
    else if (event.key === "Enter") { event.preventDefault(); go(); }
  }

  function open() {
    if (box) return;
    restore = document.activeElement;

    box = document.createElement("div");
    box.className = "bv-search";
    box.setAttribute("role", "dialog");
    box.setAttribute("aria-modal", "true");
    box.setAttribute("aria-label", "Search the guide");
    box.innerHTML =
      '<div class="bv-search-panel">' +
        '<div class="bv-search-field"><span class="sigil" aria-hidden="true">&#8981;</span>' +
        '<input type="search" autocomplete="off" autocorrect="off" autocapitalize="none" ' +
        'spellcheck="false" placeholder="Search the guide" aria-label="Search the guide" ' +
        'role="combobox" aria-expanded="true" aria-controls="bv-search-results"></div>' +
        '<ul class="bv-search-results" id="bv-search-results" role="listbox" ' +
        'aria-label="Search results"></ul>' +
        '<div class="bv-search-foot"><span><kbd>&#8593;</kbd><kbd>&#8595;</kbd> move</span>' +
        '<span><kbd>&#8629;</kbd> open</span><span><kbd>esc</kbd> close</span>' +
        '<span class="n"></span></div>' +
      "</div>";

    lockScroll();
    document.body.appendChild(box);
    input = box.querySelector("input");
    list = box.querySelector(".bv-search-results");

    void box.offsetWidth;
    box.classList.add("is-open");

    render("");
    load().then(function () { if (box) render(input.value); });

    fitViewport();
    if (window.visualViewport) {
      window.visualViewport.addEventListener("resize", fitViewport);
      window.visualViewport.addEventListener("scroll", fitViewport);
    }

    input.addEventListener("input", function () { render(input.value); });
    list.addEventListener("mousemove", function (event) {
      var li = event.target.closest("li[role=option]");
      if (!li) return;
      var items = Array.prototype.slice.call(list.querySelectorAll("li"));
      var i = items.indexOf(li);
      if (i === -1 || i === cursor) return;
      move(i - cursor);
    });
    box.addEventListener("click", function (event) {
      if (event.target.closest("a")) { close(false); return; }   // let the link navigate
      if (!event.target.closest(".bv-search-panel")) close();     // backdrop
    });
    document.addEventListener("keydown", onKeydown, true);
    input.focus({ preventScroll: true });
  }

  function typingInField(el) {
    if (!el) return false;
    var tag = el.tagName;
    return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || el.isContentEditable;
  }

  document.addEventListener("keydown", function (event) {
    if (box) return;
    var mod = event.metaKey || event.ctrlKey;
    if (mod && event.key.toLowerCase() === "k") { event.preventDefault(); open(); return; }
    if (event.key === "/" && !mod && !event.altKey && !typingInField(document.activeElement)) {
      event.preventDefault();
      open();
    }
  });

  function wire() {
    var triggers = document.querySelectorAll("[data-search-open]");
    Array.prototype.forEach.call(triggers, function (t) {
      t.addEventListener("click", function (event) { event.preventDefault(); open(); });
    });
    // The sidebar trigger shows ⌘K; on non-Apple platforms say ctrl K.
    if (!/Mac|iPhone|iPad|iPod/.test(navigator.platform || "")) {
      Array.prototype.forEach.call(document.querySelectorAll("[data-search-open] .k"), function (k) {
        k.textContent = "ctrl K";
      });
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", wire);
  } else {
    wire();
  }
})();
