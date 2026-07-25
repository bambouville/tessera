---
name: doc-screenshots
description: Capture real Tessera screenshots on an iPad simulator against the disposable fixtures and wire them into the public docs at bambouville.com. Use when refreshing docs images for a release, adding a screenshot to a docs page, or when a docs section needs a visual because text alone is unintuitive.
---

# Tessera doc screenshots

Produces screenshots of the **real app** — real build, real SSH/mosh connections
to the disposable fixtures — and places them in the public user guide. No
mockups, no simulated UI.

Two repos are involved:

- `~/tessera` — app, capture probe, driver script, fixtures.
- `~/bambousite` — the published site. Docs pages are `site/docs/<page>/index.html`,
  images live in `site/docs/img/`. `main` auto-deploys to bambouville.com via
  Cloudflare, so a push is a publish.

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

Resize to 1500 px wide and place in `~/bambousite/site/docs/img/`:

```sh
sips -Z 1500 <src>.png --out ~/bambousite/site/docs/img/<name>.png
```

Insert at the end of the relevant `<h2 id="...">` section. The image is always
wrapped in a link to itself so readers can open it full size — the inline
column is only ~700 px wide, far too narrow to read terminal text:

```html
<figure>
<a href="/docs/img/<name>.png" target="_blank" rel="noopener" aria-label="Open full-size screenshot">
<img src="/docs/img/<name>.png" alt="<what is visible, specifically>" loading="lazy" width="1500" height="1125">
</a>
<figcaption>What the reader should notice.</figcaption>
</figure>
```

**Placement trap:** if you insert by scanning forward to the next
`<h2 id="...">`, a figure destined for the page's *last* section has no next
heading to stop at and gets appended after `</html>`, where it renders
full-bleed under the footer. Anchor to `</main>` instead — that is the end of
the content column regardless of which section is last.

Pages that already carry figures have the CSS. A page getting its first figure
needs this block added after `.docs-content blockquote p { margin: 4px 0; }`:

```css
  .docs-content figure { margin: 22px 0; }
  .docs-content figure a {
    display: block; cursor: zoom-in; text-decoration: none;
  }
  .docs-content figure img {
    display: block; width: 100%; height: auto;
    border: 1px solid var(--line); border-radius: 10px;
    transition: border-color 0.15s ease;
  }
  .docs-content figure a:hover img { border-color: var(--ink-dim); }
  .docs-content figure a:focus-visible img {
    outline: 2px solid var(--blue); outline-offset: 2px;
  }
  .docs-content figcaption {
    margin-top: 8px; font-size: 11.5px; color: var(--ink-dim);
  }
```

`text-decoration: none` on the anchor is load-bearing — `.docs-content a`
underlines links by default. The token colours adapt to dark mode already.

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
