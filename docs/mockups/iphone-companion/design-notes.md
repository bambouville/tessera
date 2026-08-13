# Tessera iPhone — design notes

Companion to `index.html` (interactive mock, self-contained, 375–430pt targets).
Principle: **thumb-first companion terminal, not a shrunken iPad.** Chrome floats as
glass (iOS 26 Liquid Glass) over full-bleed content; accent is state, never decoration.

## Layout decisions

- **Tab bar** — 4 tabs (hosts / sessions / keys / settings), floating glass capsule,
  icon+label; compact inline form in landscape. (HIG tab-bars)
- **Session top pill (44pt, not iPad's 32)** — `‹ back` (keeps session) · host name
  **is** the switcher (⇅ affordance) · find · files · tunnels (view-only) · red
  disconnect. No `· tmux` suffix, no `…` menu. Back ≠ disconnect: navigation leads,
  destructive trails. (HIG toolbars: ≤44pt targets, title <15 chars)
- **The switcher** (was command palette) — one searchable surface: hosts home,
  tmux **windows → panes** (two-layer: each pane opens full-screen, iPhone has no
  split panes), sessions, agents. Opened from the host name; magnifier is reserved
  for find-in-terminal. (HIG search-fields: single searchable location)
- **Accessory bar** — esc ⌃ ⌥ ⇥ arrows, one-shot modifiers, docks above home
  indicator, rides the keyboard. More critical on iPhone (no hw modifiers).
  (HIG virtual-keyboards input accessory)
- **SwipePad** — 52pt puck bottom-right in the thumb arc; petals + double-tap
  dictation. Hidden in landscape+keyboard (no room).
- **Files** — nonmodal medium-detent sheet, inset from edges, terminal stays live;
  browse / hidden toggle / send-path-to-terminal. (HIG sheets)
- **Settings toggles are wired** — theme, font size, accessory bar, hidden files,
  agent center all rewire the session live.

## Feature triage (surveyed all app surfaces)

**Ported (adapted):** hosts + quick-connect · sessions (sidebar → tab; hosts/agents
views) · agent center (sessions → agents; optional via settings → experimental) ·
accessory bar · SwipePad + dictation · files (card → sheet) · the switcher ·
keys + **known hosts** (TOFU pin + revoke; keys tab second view) · minimal host
editor (long-press → edit; jump chains/env/snippets stay iPad) · host-key trust card ·
find · Face ID lock · bell→attention dots.

**Left on iPad:** split panes (375–430pt ≈ 40 cols/pane — existing tmux panes become
separate full-screen targets instead) · agent timeline board (phone keeps the
actionable list) · port-forward editor (tunnels are view-only from the pill) ·
full host editor · hw-keyboard shortcut map · onboarding tour · theme gallery ·
session-restore sheet (collapses to a policy row).

## HIG basis (iOS 26)

materials (glass = chrome layer only) · tab-bars (floating, compact in landscape) ·
toolbars (trailing ≤ few, overflow→real buttons) · sheets (nonmodal, medium detent,
inset) · virtual-keyboards (input accessory) · going-full-screen (restore via
persistent pill, one-swipe home) · layout (59/34pt safe areas portrait, 59/21
landscape) · search-fields (switcher composition).

Tokens verbatim from `Tessera/Design/DesignTokens.swift` (dark+light, blue accent);
JetBrains Mono embedded (single variable woff2); chrome text mono lowercase.

## Implementation decisions (2026-07-18)

- This mock and these notes supersede conflicting details in
  `docs/iphone-adaptation-plan.html`. In particular, compact navigation has four
  tabs; Agent Center is the optional second view inside Sessions.
- **Handoff is deferred.** Do not add `NSUserActivity`, host/config sync, key
  enrollment, or iCloud work on the iPhone-port branch. Build that as a dedicated
  follow-up feature branch. The future design remains P8 in
  `docs/iphone-adaptation-plan.html`: a secret-free activity descriptor resolves
  an existing host and reconnects a second device to the same tmux session;
  credentials and private keys never transfer; unknown hosts require explicit
  confirmation; app-lock deferral is mandatory. Re-audit P8 against the finished
  compact shell before implementation. **The sync/continuity UX for that branch
  is now designed — see `sync.html` and the section below.**
- **Compact tmux presentation is geometry-neutral.** An iPhone attaching to an
  existing tmux session must not change the server-side window dimensions, split
  ratios, pane set, or zoom state. Do not enable `window-size latest` or
  `aggressive-resize`, and do not use remote `resize-pane -Z` to implement the
  mock's full-screen panes. Preserve the existing logical cell grid and present
  one pane at a time locally through the switcher's window → pane hierarchy.
  A brand-new tmux session created first on iPhone may use phone geometry.

## Sync & continuity (2026-07-19)

Storyboard mock: `sync.html` (static frames, same tokens/house style). UX design
for the P8 follow-up branch; confirmed feature list + decisions:

- **Scope confirmed: all three P8 layers mocked.** Layer 1 (Handoff continue) and
  layer 2 (enrollment + bootstrap) are the build target; layer 3 (iCloud host
  sync) is **design-ahead only** — surfaces mocked, build stays a separate
  proposal.
- **First-open bootstrap (new, user-requested).** Fresh install of either app
  offers: bootstrap from the other device (nearby, foreground, peer-to-peer over
  the local network — not Handoff, not iCloud), restore from iCloud (grayed until
  layer 3 ships), or start fresh. Transfers host configs, jump chains, settings;
  never passwords, private keys, or trust pins. Origin device approves with
  Face ID.
- **Auto key + biometric grant (new, user-requested).** During bootstrap or
  enrollment, a device with no key silently creates a default Secure Enclave
  key; the origin device gets a per-host checklist (password hosts shown
  excluded) and authorizes with one Face ID. Installs go through
  `RemoteAuthorizedKeysInstaller` over the origin's authenticated connections;
  grants land in the `remoteInstallations` ledger with one-screen revocation.
- **Informed TOFU approved.** Descriptor gains `hostKeyFP` (fingerprint only,
  public data); the peer's first-connect trust card shows "matches the key your
  iPad trusts" (green) or a demoted-action mismatch state (amber). Explicit
  per-device confirm kept; pins never sync.
- **Honest labels.** "Continue" (same screen, both attached) only for tmux modes;
  plain ssh/mosh say "reconnect". Discovery is system UI only (App Switcher /
  Dock) — no in-app nearby-sessions list, by API reality and by stance.
- **Lock posture.** Broadcast stops while locked; incoming continuations stash
  and replay after Face ID (existing ContentView pattern).
- Settings footprint: one "continuity" group (toggle + truth row) and one
  "icloud sync" row; first-run iCloud choice card is for existing installs when
  the feature ships — fresh installs decide on the welcome screen.
- **Bidirectional (2026-07-19 audit).** Both continuation directions are designed:
  iPad → iPhone (App Switcher banner) and iPhone → iPad (**Dock** affordance —
  iPadOS has no switcher banner). Enrollment/credential grants are
  direction-agnostic: whichever device holds the authenticated session grants,
  always behind Face ID, recorded in both ledgers and revocable from either end.
  Reverse-attach geometry rule: a phone-born session cedes the grid when an iPad
  attaches — the iPhone client flips itself to `ignore-size` and the iPad sizes
  the grid (larger screen wins; phone presents pane-at-a-time regardless; no
  `window-size latest` / `aggressive-resize`; grid stays put when the iPad
  detaches).
- **Bootstrap is mocked both directions too (audit round 2).** S1 now has
  "direction 1: new iPhone ← existing iPad" and "direction 2: new iPad ←
  existing iPhone" — iPad welcome screen, iPhone-side Face ID transfer approval,
  iPhone-side per-host key checklist (mercury excluded as a password host), iPad
  receipt. Every remaining single-device section (never-seen host, credentials,
  settings) states which side is shown and where the mirror lives.
- **Nearby peer binding (security review, 2026-07-19).** Face ID authenticates
  the local user, not the peer, and LAN device names are self-asserted — so the
  S1 nearby bootstrap now requires a SAS code compare: an ephemeral 6-digit code
  derived from the transfer's key exchange, shown full-screen on the new device
  and confirmed inside the origin's Face ID approval card. Mandatory order:
  discover → encrypted channel → code compare → Face ID → transfer; the manifest
  never moves first (a poisoned manifest could pre-seed false `hostKeyFP` pins,
  so integrity is trust-relevant). S7 enrollment needs no code: Handoff
  continuation streams only open between devices on the same Apple Account
  (mutually authenticated by Apple's identity service) — documented as
  transport-load-bearing; moving enrollment off continuation streams inherits
  the SAS requirement. Guarantees strip gained "no unverified peers."

## iCloud sync — layer 3 (2026-07-26)

Storyboard mock: `icloud-sync.html` (frames I1–I9, same tokens/house style). Full design for
the layer that sync.html kept design-ahead; resolves the §7 non-goal in
`sync-implementation-plan.md`. Decisions:

- **One envelope, three transports.** The bootstrap manifest allowlist + classification table
  is the wire format; iCloud records are a third transport beside the nearby channel and
  Handoff descriptors. Same UUIDs throughout → a device set up by nearby bootstrap that later
  turns on iCloud merges with **zero duplicates**; the two paths compose by construction.
- **Steady state syncs topology only** — hosts, jump chains, identities (credential-free),
  port forwards, trust hints. Appearance & settings move **once** at restore/first-join
  *(qualified in the round-3 review below: empty installs only, never on join)*;
  ongoing settings sync was rejected (devices fighting under your fingers, idiom-specific
  keys). Nearby "send setup" keeps its post-iCloud job: the deliberate settings push.
- **Merge rules, three sentences:** whole-record last-edit-wins (per-field merge rejected —
  franken-hosts no one can explain); same-endpoint-different-UUID collisions (typed
  coordinates, the continuity resolver's match rule) merge first-created *(superseded in the
  round-3 review below: last-edit-wins everywhere)* with tag/forward
  union, announced once on the join card, with a never-re-asked "keep both" escape; deletes
  propagate via 30-day tombstones, and "delete means delete" is printed on the opt-in card.
- **Trust hints sync; pins never.** First connect after a cloud restore still shows the S5
  card, with provenance ("matches the key pinned on your iPad · hint via icloud"). A hint can
  mislabel, never decide — mismatch still demotes. Every pin stays an explicit per-device
  confirm; the installation ledger also stays per-device.
- **No grants through the cloud.** iCloud has no live authenticated channel, so key installs
  remain a nearby Face ID ceremony (S7); a restored host asks for a credential once via the
  unchanged S6 card.
- **Transport honesty:** CloudKit private database, custom zone — labeled **not end-to-end**
  *(superseded in the round-4 review below: every content field goes end-to-end via encrypted
  record values)*; the fields that would demand E2E are exactly the `neverSyncs` set. SwiftData↔CloudKit
  mirroring rejected (no unique constraints, optional relationships, migration stages) in
  favor of a sidecar store through the manifest adapter — model schema byte-untouched,
  posture tests (`cloudKitDatabase: .none`, no `kSecAttrSynchronizable`) stay green. Status
  row reports data (count · recency), never a device list — CloudKit discloses none; this
  **corrects the S9 design-ahead "devices" row** in sync.html.
- Welcome-screen restore row is live only with an iCloud account + non-empty zone, and its
  subtitle previews the zone (count · when · from which device — records carry
  `originDevice`); grayed states name their reason ("no account" / "nothing to restore").
  Restoring turns sync on for the new device (one toggle to undo). Lock posture: config may
  land while locked; nothing acts.
- **Credential bridge (2026-07-26, round 2).** Synced hosts without credentials are a map with
  no keys — so a restore doesn't end at the receipt, it ends in an explicit access card that
  says passwords/private keys never sync and names the three honest closes: **nearby grant**
  (accent lane — the S1 "send/receive setup" flow rerun; idempotent manifest import makes the
  data half a no-op, so the transfer is precisely the key grants, with one added copy line on
  the origin's card: "setup already in sync via icloud — this transfer grants keys only") ·
  **manual install** (copy the device public key from keys → add to authorized_keys from any
  authorized machine) · **per-host password once** (the S6 card at first connect; password
  hosts always work this way; S7 grant still opportunistic when devices meet). The card
  appears once and never nags; "not now" means the lazy lane. Device key creation stays lazy —
  on first grant/credential tap, never at restore. No grant-only protocol fork; SAS + Face ID
  order inherited unchanged.

- **Review round (2026-07-26, round 3 — `icloud-sync-review.md` F1–F21 incorporated).** The mock
  was a storyboard of success; the round added the failure layer and reopened two decisions.
  Highlights: status row grew a ~9-state vocabulary (quota-full is billed against the user's
  *whole* iCloud quota — the most common silent failure; partial save; signed-out; version
  skew; zone-gone), stays alert-free, and is tappable-to-retry · opt-in pitch names recovery
  beside convenience, shows on the hosts page (never over a live session), and the access
  card gained a manual device-loss branch plus the durable line *"icloud restores your
  configuration, never your access"* · **reopened: first-created-wins → last-edit-wins
  everywhere** (F9 — an endpoint merge happens once, nothing to flip); merges are automatic,
  announced as a join-card count, owned as receipts with struck-through discarded values on
  each host's detail page; keep-both auto-suffixes · **reopened: uniform green hints → two
  assurance tiers** (F3) — neutral recall ("your iPad recorded this — not independently
  verified") for cloud-delivered, green reserved for verified channels; S5's Handoff-hint
  green is a named layers-1+2 follow-up; honest green over iCloud = hints signed with a key
  that never enters CloudKit, named as a separate project *(mostly dissolved in the round-4
  review below: encrypted fields authenticate hint contents — the residual gap is replay, not
  forgery)* · delete gains undo (toast +
  recently-deleted, tombstone-backed) and the stale-device rule (>30 days out of sync ⇒
  re-join via first-join merge, never silent republish) · "remove synced data" mechanism:
  devices stop on finding the zone gone — never republish into a missing zone — and both ends
  get a receipt · restore receipt carries the sync-stays-on consent line; welcome row renamed
  "restore & keep in sync", accent follows completability (never order) · appearance applies
  into empty installs only (never on join); moves-once key list = decision D3, named open ·
  grant results frame (partial failure is the norm); "access on this device" keys section is
  the bridge's permanent second door — action-anchored, no charts, or it becomes the
  dashboard this design refuses · timing honesty (arrival = next foreground; "new" expires;
  edits leave a detail-page provenance line) · edge states (empty zone, wrong-account named +
  tappable, zero-dup join copy, dangling chains validated on arrival) · valence rule stated
  (accent-filled = recommended proceed, white-filled = safe, ghost = unpushed; S9 card stays
  as contracted) *(refined in the round-4 review below: white-filled = the answer that changes
  nothing)* · 12px floor for consequence text · sync "while locked" truth row.

- **Review round 2 (2026-07-26, round 4 — `icloud-sync-review.md` F22–F41 incorporated).** Round 1
  made the mock tell the truth about failure; round 2 audited whether the recorded schema can keep
  the frames' promises — four places it couldn't, all cheapest to fix while the zone format is
  still ink. **Reopened: transport.** The "not end-to-end, deliberate choice" premise was outdated
  — per-field E2E has shipped since iOS 15 (keys chained through iCloud Keychain, which is E2E even
  under standard protection), and ADP users were already covered — so every content field moves to
  encrypted record values. Honest label: "contents end-to-end; record shape + timing standard
  iCloud." iCloud-Keychain-off gains explained states (welcome + status row); an engineering spike
  gates the I8 plumbing milestone — adopting after ship means re-uploading every record plus
  version-gating. The adoption collapses three findings: free text (notes · env vars · launch
  commands · snippets) joins the sync set — the real manifest already carries all four, so the
  three transports become literally one envelope · `authenticationHint` (already in the manifest)
  is inherited by the iCloud host record inside the encrypted fields, making the access card's
  counts and the access screen's rows knowable rather than guessed · the hint-signing project
  mostly dissolves (neutral stays the default tier: recorded ≠ verified, replay remains).
  **Schema fixes:** unknown fields round-trip opaquely per record — an old build's write can never
  roll back a new build's data (a deliberate, recorded departure from the manifest's reject-unknown
  posture: a poisoned nearby manifest is trust-relevant, your own newer build's fields are not) ·
  sortOrder sheds to one order record, list-level last-drag-wins — a drag is the lightest write in
  the zone and never clobbers a concurrent host edit · tombstones carry the final payload — undo
  and recently-deleted work on any device, and "delete means delete" gains the honest suffix
  "after 30 days" · hint records gain originDevice and rewrite only on change (no per-connect
  churn) · identities merge by the same endpoint rule as hosts (name + login) · ordering authority
  is CloudKit server receipt order, never device wall clocks. **New frames & states:** the rotation
  hint card (the changed-key card gains the tiered line — rotation is where hints earn their keep;
  no hint or hint ≠ presented key ⇒ exactly as alarming as today) · "checking icloud…" probe state
  + settle-once rule (the accent never jumps under a descending finger) · restricted (MDM — not a
  flavor of signed-out; copy doesn't blame; nearby bootstrap named in place) · keychain-off states
  · dangling-chain row treatment (amber "via atlas — missing" + a detail-page line, never a
  connect-time surprise) · compact restore receipt + access card drawn at 393pt (the budget rule
  is now falsifiable at a glance). **Copy & consistency:** the join card owns both directions
  ("sent 2 hosts") and titles name the account's data, not a guessed sibling; the copy deck passed
  the three-device test ("a device you already trust"; waiting cards accept whichever peer shows
  up) · grant-results fallback copy is auth-method-honest (a key-only host has nothing to "ask") ·
  the disclosure gains "deleting the app doesn't delete the zone — reinstall, and your hosts come
  back" beside "deletes propagate" · R4's consequence notes reach the 12px floor they invented ·
  valence rule refined (white-filled = the answer that changes nothing · accent-filled =
  recommended proceed · ghost = unpushed) — W2's fills swapped to pass it · zone-gone receipts
  appear once at next foreground over the hosts page, join-card posture, never an alert ·
  reduce-motion kills every animation (mocked in the file's CSS). Also caught in passing: the
  mock's principles strip still said "first-created wins a merge" — stale since round 3.
