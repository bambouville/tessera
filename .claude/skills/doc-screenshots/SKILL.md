---
name: doc-screenshots
description: Capture real Tessera screenshots on an iPad simulator against the disposable fixtures and wire them into the public docs at bambouville.com. Use when refreshing docs images for a release, adding a screenshot to a docs page, or when a docs section needs a visual because text alone is unintuitive.
---

# Tessera doc screenshots

Produces screenshots of the **real app** — real build, real SSH/mosh connections
to the disposable fixtures — and places them in the public user guide. No
mockups, no simulated UI.

Two repos are involved:

- `~/tessera` — app, capture probe, driver script, fixtures, **and the docs
  themselves**: `docs/site/pages/*.md` plus `template.html`, `build.mjs`, and
  `assets/`.
- `~/bambousite` — the published site. `main` auto-deploys to bambouville.com
  via Cloudflare, so a push is a publish.

**`bambousite/site/docs/` is build output, never a source.** Both
`scripts/deploy-docs.sh` and the `Publish docs` GitHub Action run
`rsync -a --delete docs/site/dist/ bambousite/site/docs/`, so anything edited
there directly — prose, figures, images, scripts — is deleted on the next docs
build. Every change belongs in `docs/site/`:

| Change | Where it goes |
|---|---|
| Prose, headings, figures | `docs/site/pages/*.md` |
| Page shell, CSS, script tags | `docs/site/template.html` |
| Screenshots, JS | `docs/site/assets/` → served at `/docs/assets/…` |
| Generated data (search index) | emitted by `docs/site/build.mjs` |

Build and preview with `cd docs/site && node build.mjs`, then
`rsync -a --delete dist/ ~/bambousite/site/docs/` and serve `~/bambousite/site`
locally. Pushing `docs/site/**` triggers the Action, which commits the rebuilt
output to bambousite on its own.

## Prerequisites

1. `scripts/integration/fixture.env` exists and points at two disposable
   servers (see `scripts/integration/README.md`). It is gitignored; the root
   control key is `~/.ssh/id_ed25519_bambouville`.
2. Fixtures are provisioned: `./scripts/integration/provision-fixtures.sh`.
   This creates the app-facing sshd on port 2222, the `tessera` user, the
   loopback HTTP target on 18080, and the demo `~/projects/nebula` repo that
   the terminal and files captures show.
3. `jq`, `sqlite3`, `sips`, and Xcode are present.

## Run

```sh
cd ~/tessera
./scripts/integration/capture-doc-screenshots.sh
```

It builds for testing, prepares a dedicated simulator, runs both probe flows,
and writes PNGs to `scripts/integration/out/docshots-<timestamp>/docshots/`.
Budget **~35 minutes** — the mosh flow alone takes about 17.

Captures: keys page, host editor, forwarding rule, tmux panes, tmux bell,
files panel, tunnels page, known hosts, swipe pad, agent center.

## Authentication: always keys, never passwords

The probe generates an Ed25519 key through Tessera's own Keys UI; the driver
reads the resulting `authorized_keys` line out of the app's SwiftData store and
installs it on both fixtures over the root key.

Do not try to drive the editor's password field. `Host.init(from:transientPassword:)`
only adopts a transient password when the host already has a `.password`-mode
identity, and a host created in the UI has no identity, so the password is
dropped and the connection fails in ~200 ms with `authKind=unknown` in the
app's diagnostics. A persisted identity has no such problem and is also immune
to the SwiftData writes that re-create the editor view.

## Traps, each of which costs a 30-minute cycle

- **Screenshots must come from `simctl`, not XCUIScreenshot.** SwiftTerm renders
  through `CAMetalLayer` and XCUIScreenshot captures it black. Take three and
  keep the largest; a single grab can be partially composited.
- **Env reaches the runner through the simulator's launchd**, not xcodebuild's
  process environment: `xcrun simctl spawn "$UDID" launchctl setenv NAME value`.
- **`app.buttons["x"].firstMatch` is unsafe.** The collapsed sidebar carries
  buttons with the same labels at tiny frames, and other "connect" controls act
  on the *saved* host. Prefer the widest hittable match; the editor's connect
  bar is ≥400 pt wide.
- **Segmented tab buttons report `isHittable == false`** while still accepting
  taps, so a hittable-only search never finds "forwarding". Fall back to a plain
  label match.
- **`identifier BEGINSWITH "tmux-window-"` also matches every tab's ✕.** Tapping
  one raises "Close tmux window?" and blocks everything after it. Require
  `ENDSWITH "-tab"`.
- **Never use `app.swipeDown()`** or any large downward drag over a non-scrolling
  view: iPadOS takes it as the window-minimize gesture, recreates the scene, and
  drops transient view state.
- **`simctl pbpaste` comes back empty** for the simulator pasteboard; read the
  SwiftData store instead (`ZSTOREDKEY.ZAUTHORIZEDKEYSLINE`).
- **The trust-on-first-use sheet cannot be driven reliably.** The ~10 s connect
  timeout keeps running underneath it while XCUITest's idle-wait delays the tap.
  The driver pre-seeds `known_hosts.json`; capture that sheet on its own.
- **`ensure-test-simulator.sh` pins one iOS runtime** and fails with "Invalid
  runtime" after an Xcode update. `capture-doc-screenshots.sh` falls back to the
  newest installed runtime.

If a stage fails, read the app's own log — it is far more informative than the
XCUITest failure:

```sh
C=$(xcrun simctl get_app_container <UDID> com.bambouville.TesseraApp data)
grep -a 'SSHDiag' "$C/Library/Application Support/Diagnostics/tessera-diagnostics.log" | tail
```

## Curate before publishing

Review every PNG. Recurring rejects: an iOS **Passwords autofill bar** over the
form, a modal opened by a stray tap, and the **"N orphaned Keychain items"**
warning on the keys page after repeated installs. Re-run or drop the shot —
never ship a frame with system chrome or error banners over the UI.

## Wire into the docs

Resize to 1500 px wide into the generator's assets:

```sh
sips -Z 1500 <src>.png --out ~/tessera/docs/site/assets/img/<name>.png
```

Then add the figure to the relevant `docs/site/pages/<page>.md`, at the end of
the section it illustrates (raw HTML passes straight through Markdown). The
image is wrapped in a link to itself — the inline column is only ~700 px wide,
far too narrow to read terminal text:

```html
<figure>
<a href="/docs/assets/img/<name>.png" aria-label="Enlarge screenshot">
<img src="/docs/assets/img/<name>.png" alt="<what is visible, specifically>" loading="lazy" width="1500" height="1125">
</a>
<figcaption>What the reader should notice.</figcaption>
</figure>
```

`assets/lightbox.js` enlarges it in place: the image animates from its exact
position to the centre of a dimmed backdrop, and any click, `Esc`, or the `esc`
keycap closes it. The `href` stays put so the page still works with JS off, and
modified clicks (cmd/ctrl/shift) fall through to the browser. The template
already loads the script and carries the figure CSS, so a new figure needs
nothing else.

If you touch `lightbox.js`, three things there are load-bearing and were each a
bug first:

- The close-on-click listener is attached in a `setTimeout(…, 0)`. The overlay
  is inserted under the cursor, so a listener added synchronously catches the
  *opening* click and closes immediately.
- The opening state is flushed with a forced reflow (`void box.offsetWidth`),
  not `requestAnimationFrame` — rAF does not fire in a background tab, which
  leaves the overlay stuck at `opacity: 0`.
- Caption width is synced from `img.offsetWidth`, never
  `getBoundingClientRect().width`; the latter reports the visual rect, which
  mid-FLIP is still the thumbnail size.

## Search

`build.mjs` emits `assets/search-index.json` — one entry per heading section,
so a hit lands on the exact anchor rather than the top of a long page. It is
regenerated on every build; adding or renaming a heading needs no other work.

`assets/search.js` renders the palette: ⌘K / ctrl+K / `/` opens it, ↑↓ move, ↵
opens, `esc` closes, and the sidebar carries a visible trigger for touch. The
index is fetched on first open, never on page load. Two things to preserve:

- Opening a result must **not** restore the saved scroll offset. For a
  same-page anchor the browser has already jumped, and restoring would yank the
  reader back — hence `close(false)` on navigate.
- iPadOS does not shrink the visual viewport for the software keyboard, so the
  palette sits higher under `@media (pointer:coarse)` to keep results visible
  above it. The `visualViewport` listeners still earn their keep on iPhone.

## Verify on iPad, not just a desktop browser

Tessera is an iPad app, so that is where the docs are read. `xcrun simctl
openurl <UDID> <url>` opens a page in the simulator's Safari and `xcrun simctl
io <UDID> screenshot` captures it; check both orientations. A scratch XCUITest
driving `com.apple.mobilesafari` can tap through an interaction when behaviour
(not just layout) needs checking — measure the tap point from a screenshot
first rather than guessing.

WebKit specifics already handled in `lightbox.js`, worth preserving: `dvh`
alongside `vh` (iOS `vh` is the toolbars-hidden height, so a `vh`-sized image
can sit under the toolbar), a pinned body for scroll lock (`overflow:hidden`
alone does not hold in iOS Safari), `touch-action:none` and
`overscroll-behavior:contain` on the overlay, `-webkit-tap-highlight-color`
cleared, `:hover` rules gated behind `@media (hover:hover)` so they do not
stick after a tap, and focus placed on the dialog rather than the keycap so a
touch does not draw a focus ring.

Verify before committing: every `src` resolves, `<figure>` tags balance, every
`<img>` has alt text and sits inside an anchor, and **every figure is before
`</main>`**.

## Honesty rules

- The **agent center** image comes from the app's demo harness
  (`TESSERA_AGENT_CENTER_HARNESS`), not a live session. Say so in the commit
  message wherever it is used.
- Screenshots taken against the fixtures show a **real burner IP**. Once those
  droplets are destroyed the address recycles to another customer, so ask
  whether to keep it or re-shoot with a placeholder before publishing.
- Only claim a feature the screenshot actually demonstrates.

## Which sections earn a screenshot

Favour spatial layouts, multi-panel UI, and visual indicators — host editor
tabs, the TOFU sheet, tmux panes, the files panel, the tunnels list, known
hosts, the agents page. Skip conceptual prose, shortcut tables, and command
listings; those read fine as text. Aim for one figure per section at most.
