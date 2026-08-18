# Which key chords never reach Tessera — and why

Research backing the shortcut recorder's exclusion list (keyboard sprint, mock 2 §02–03).
Evidence is source-level where possible; folklore is marked as such and pushed behind a
runtime check rather than a static list.

Sources of truth:

- SwiftTerm **bambouville fork** at `d135aeb`, `Sources/SwiftTerm/iOS/iOSTerminalView.swift`
  (`pressesBegan` ~L2244, `pressesEnded` ~L2502) and `iOSTextInput.swift` (`extension TerminalView: UITextInput`).
- `Tessera/TesseraTerminalView.swift` `keyCommands` / `canPerformAction`, plus the failure
  notes already recorded in its doc comments (⌃Tab, ⌘+arrows, ⌘⌥[).
- Apple: [`wantsPriorityOverSystemBehavior`](https://developer.apple.com/documentation/uikit/uikeycommand/wantspriorityoversystembehavior),
  [Focus on iPad keyboard navigation (WWDC21)](https://developer.apple.com/videos/play/wwdc2021/10260/),
  [Learn iPad keyboard shortcuts](https://support.apple.com/en-us/102393),
  [Think Globally (Six Colors)](https://sixcolors.com/post/2021/06/think-globally-the-ipads-new-universal-keyboard-shortcuts/).

---

## 1. Dispatch order — the thing that makes the rest make sense

A hardware key press is offered to four gates, in order. The first one that takes it wins,
and later gates never see the event:

1. **iPadOS system reservations.** Never delivered to any app.
2. **Focus engine + text input** for the current first responder. `TerminalView` conforms to
   `UITextInput`, so it sits squarely in this gate.
3. **`UIKeyCommand` matching across the whole responder chain.**
   `wantsPriorityOverSystemBehavior = true` promotes a command *above* gate 2 — that is
   exactly what the property means ("takes precedence over text input or focus movements").
   It does **not** promote anything above gate 1.
4. **`pressesBegan` delivery**, first responder first, walking up the chain via `super`.

This ordering is why Tessera's existing chords work at all: `⌘⇧K` is matched at gate 3 on
`TesseraTerminalContainer` even though `TerminalView` is first responder and would otherwise
swallow the press at gate 4.

**Consequence for the feature:** app shortcuts keep firing through `UIKeyCommand` (gate 3).
The recorder, however, must observe *arbitrary* presses, which only gate 4 provides — so it
runs on its own capture view with the terminal resigned. The two mechanisms have different
matching semantics, and §4 below is where that bites.

---

## 2. What SwiftTerm consumes (gate 4)

From the fork's `pressesBegan`. When it produces `data`, it sets `didHandleEvent = true` and
**does not call `super`** — the chord dies there and no ancestor sees it. Modifiers are *not*
checked for most of these: the switch is on `key.keyCode` alone, so holding ⌘ does not save them.

| keyCode | consumed? | notes |
|---|---|---|
| `upArrow`, `downArrow` | **always** | app-cursor aware |
| `leftArrow`, `rightArrow` | **always** | ⌥ → emacs word, ⌃ → controlLeft/Right |
| `home`, `end`, `deleteForward`, `escape` | **always** | |
| `tab` | **always** | ⇧⇥ → back-tab |
| `F1`–`F11` | **always** | `F12`–`F24` fall through (`break`, no data) |
| `pageUp`, `pageDown` | **only in app-cursor mode** | otherwise scrolls *and* propagates |
| any key + `.control` | **always** | `applyControlToEventCharacters` |
| any key + `.alternate` | **always**, because `optionAsMetaKey` defaults to `true` (fork L172) → sends `ESC`+char |
| modifier keys, caps/num/scroll lock, F12+, media keys | never | |
| plain letters/digits with ⌘ or ⌘⇧ only | never | falls to `super` — this is the corridor our shortcuts use |

Two escapes from the table: `_markedTextRange != nil` (IME composition) bails to `super`
immediately, and a non-empty `terminal.keyboardEnhancementFlags` (kitty protocol) takes a
completely different branch. Neither changes the conclusion for gate 3 chords.

**So:** every chord containing ⌃ or ⌥ is claimed by the terminal at gate 4. Such a chord can
still work as a `UIKeyCommand` (gate 3 runs first), but binding one *steals a key the shell
needs* — `⌃E` is end-of-line, `⌥f` is forward-word. That is a product rule, not a platform
limit, and it's the reason the recorder requires ⌘.

---

## 3. What the focus engine and text input claim (gate 2)

`TerminalView: UITextInput` puts the terminal inside the system's text-editing and focus
machinery. Empirically confirmed on-device and recorded in `TesseraTerminalView.swift`:

- **`⌃Tab` / `⌃⇧Tab`** — iPadOS's focus engine claims the Tab family app-wide. Never reaches
  gate 3, so a `UIKeyCommand` for it never fires.
- **`⌘←` `⌘→` `⌘↑` `⌘↓`** — arrows are text-input/focus territory for a `UITextInput` first
  responder and are consumed before an *ancestor's* `keyCommands` is consulted.
  `wantsPriorityOverSystemBehavior` cannot rescue a command that is never consulted.

Since iPadOS 15 the focus system also reserves bare arrows, Tab, Space and Return for
keyboard navigation when nothing is focused — which is why `wantsPriorityOverSystemBehavior`
exists at all. Tessera already sets it on the chords that need it.

---

## 4. The ⌥ character-remapping trap (not interception)

`⌘⌥[` was tried and abandoned: the selector never fired. The cause is **not** interception —
it is that `UIKeyCommand` matches on the character the key *produces*, and Option remaps the
base character (US layout: `⌥[` → `“`, `⌥e` → dead-key `´`, `⌥n` → `˜`). A command registered
for `input: "["` with `.alternate` therefore never matches anything the keyboard can emit.

This is the one failure mode that is **detectable at record time**, and it is worth far more
than a hard-coded list: at gate 4 the recorder holds a `UIKey` with both `characters` and
`charactersIgnoringModifiers`. When ⌥ is held and those two differ, the chord is exactly the
`⌘⌥[` case and gets rejected with a real reason. Layout-independent, and correct on keyboards
this list's author has never seen.

Bindings are therefore stored and registered from **`charactersIgnoringModifiers`**, matching
how the shipped chords are written (`input: "["`, `input: "k"`).

---

## 5. iPadOS system reservations (gate 1)

The important structural finding: **iPadOS 15 moved system-global shortcuts onto the Globe
key**, deliberately leaving ⌘/⌃/⌥ to apps. The reserved-⌘ list is consequently much shorter
than the folklore suggests — but it is not empty:

| chord | claimed by |
|---|---|
| `⌘Space` | Spotlight |
| `⌘Tab` | app switcher |
| `⌘H` | Home |
| `⌘⇧3` / `⌘⇧4` | screenshot |
| `⌘⌥D` | Dock |
| `⌘W` | closes the window under Stage Manager — already worked around app-wide via `⌘⇧W` |
| any `Globe`+key | every system-global shortcut lives here now |

`Globe` (`.keyboardLeftAlt`-adjacent in UIKit terms) is not offerable as an app modifier at
all, so the recorder simply cannot capture it — which is the correct outcome.

**This table is deliberately treated as advisory.** It is documentation-derived, it varies by
iPadOS version and by whether Stage Manager is on, and a stale hard-coded list that wrongly
rejects a working chord is worse than no list. Hence:

---

## 6. What the implementation actually does

Three layers, weakest reliance on the static list:

1. **Structural rule (hard reject).** A chord must contain ⌘. Enforced because ⌃/⌥ chords
   steal keys the shell owns (§2), not because the platform stops them.
2. **Runtime detection from the press itself.**
   - *Hard reject:* ⌥ held and `characters != charactersIgnoringModifiers` → the §4 trap.
     Layout-independent, and the chord is refused with a real reason.
   - *Diagnostic:* modifiers went down and were released with no key ever arriving. This is
     shown as an explanation ("nothing arrived — iPadOS or the focus engine is keeping it"),
     **not** a rejection, because it is indistinguishable from the user tapping ⌘ and letting
     go. It is nevertheless the only signal the app gets when gate 1 or gate 2 swallows a
     chord — it covers `⌃Tab`, `⌘Space`, `Globe`+anything, and anything a future iPadOS
     starts reserving, without knowing the list in advance. A 250 ms hold threshold keeps a
     stray brush of ⌘ from producing an explanation.
3. **Static advisory list (§5 + the arrow/Tab families).** Used only to explain *why* in the
   error copy when detection fires, and to pre-empt the few chords that are delivered but are
   still a bad idea. Wrong entries degrade to a worse error message, never to a false reject.

The static tables live in `Tessera/Keyboard/KeyBinding.swift` as
`reservedBySystem` / `unavailableToKeyCommands`, each entry carrying the sentence the recorder
shows. They are data, not logic; updating them is a one-line change.

---

## 7. Left as human checks

- Real-device confirmation of the §5 table under Stage Manager on and off. The Simulator is
  unusable for this: the Mac host claims chords before iPadOS sees them (`⌘1`–`⌘9` are eaten
  by Simulator.app — see memory `feedback_simulator_cmd_digit_intercept`), so a simulator probe
  produces false "reserved" results.
- Non-US keyboard layouts. §4's detection is layout-independent by construction, but the
  `charactersIgnoringModifiers` values stored for punctuation chords are not, and a chord
  recorded on one layout may print oddly on another.
