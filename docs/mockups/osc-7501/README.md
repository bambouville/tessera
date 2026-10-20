# Tessera program status preview

Open `index.html` directly, or serve this folder locally:

```sh
cd docs/mockups/osc-7501
python3 -m http.server 8001 --bind 127.0.0.1
```

Then open `http://127.0.0.1:8001/`. All assets are local; keep
`JetBrainsMono.ttf` and its license beside the HTML, CSS, and JavaScript.

Controls switch appearance, iPad/iPhone, iOS/Android tokens, transport, Claude's
report, generic-program records, the phone keyboard, and proposed outlines.
The 1194×834 iPad and 402×844 phone frames scale to the available page width.
Controls use 44px hit frames (48px with Android tokens) at device scale.

- Start on devbox's `logs` window; use tabs, the sidebar (`≡`), or the phone's
  host dropdown to switch panes. The phone's back button opens the sessions
  root, including its `sessions | agents` selector and attention badge.
- On iPhone, tapping the host name opens the switcher, which mirrors the
  existing command palette. Window, pane and session rows carry the proposed
  status words (scroll the list to reach sessions). Sparkles in a window's icon
  slot mark a detected agent.
- Attention text uses one noun-free vocabulary ("2 need input · 1 finished");
  agent rows in the chip's list carry the sparkles glyph instead of the word.
- The tablet chip lists global attention, ordered needs input, failed, finished.
  Its row body opens an agent thread or a generic program's pane. `open pane`
  visits the exact sample pane. Opening a list or Agent Center checks nothing.
- On iPad, the host pill opens the connection popover with the proposed
  `programs` section: every record in the session, including working progress
  and checked results. On iPhone with raw SSH, the switcher's session row
  carries the status.
- Visiting a finished or failed pane checks that result; blocked reports stay
  blocked. Every Claude state selection is a fresh report, including when its
  pane is active. It clears the checked flag without moving focus.
- Choose `status unavailable` while the attention popover is open to retain
  its previous Claude row as historical, with `pane unavailable`. Channel loss
  contributes no current attention; newly opened lists contain current
  attention only. Agent Center and the window list show historical text dimmed.
- Hide other programs to compare agent-only cues. Terraform/cargo remain ordinary
  windows with no program record. Raw SSH has only Claude and no window strip.
- Set `agent center` to off (the app default) to see a default install, with
  program status on. Claude's and Codex's own reports then use the generic
  cues: no sparkles, no Agents row, selector or popover footer, and rows open
  the pane. Combining it with other programs hidden shows why an agents-only
  release would show nothing by default.
- `highlight proposed` outlines additions, including Android session attention
  parity. Generic programs never appear in Agent Center or its sidebar counts.
- Escape or the backdrop closes overlays. Phone sheets sit above the optional
  keyboard. Find, files, home, new/close window, disconnect, and other navigation
  buttons open local presentation placeholders; they do not alter sessions.

Reports and transcripts are illustrative; this does not claim that Claude,
Codex, terraform, or cargo emit OSC 7501. Web material and system glyphs are
approximations of the native presentation.

## Token sources

| Source | Used for |
| --- | --- |
| `Tessera/Design/DesignTokens.swift` | Preserved semantic colors and alpha values, blue accent; clear iOS light background over a `#F8F8FA` canvas. |
| `android/design/src/main/kotlin/com/bambouville/tessera/design/TesseraTheme.kt` | Opaque Android light background/panel/input surfaces and 48px targets. |
| `Tessera/Design/Typography.swift` | Local JetBrains Mono for chrome and identity; system sans for reported messages and transcript prose. |
| `Tessera/Navigation/SessionTmuxChrome.swift` | Regular/compact bars, host pill, tabs, global attention chip, and window list. |
| `Tessera/AgentCenterV2/Views/AgentAttentionPopover.swift` | 380px attention popover, compact rows, pane actions, and footer. |
| `Tessera/SessionSidebar.swift` | Overlay session rows, bottom navigation, and agent-only badges. |
| `Tessera/AgentCenterV2/Views/AgentThreadListView.swift` | Attention groups and status dots; working remains green here. |
| `Tessera/ContentView.swift` | Phone sessions root, segmented selector, session rows, and tab bar. |
| `Tessera/Navigation/CommandPaletteView.swift` | Phone top-bar switcher: card, sections, window/pane/session rows, footer. |
