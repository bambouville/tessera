# Agent Center conversation scrolling

The conversation behaves like a chat, independently of how its provider
delivers records. This applies to iOS and Android, compact phones and landscape
tablets, over SSH, SSH+tmux, mosh and mosh+tmux. Transport adapters do not own
scrolling. Reading position is local to each device; an iPad must not move
because the same thread was opened or scrolled on a phone.

## Contract

- A newly loaded live conversation opens at its actual end, after layout has
  settled. A delayed first page must not leave it at the top. Reopening a
  thread lands at its end in the first frame that draws it.
- A transcript shorter than the viewport rests against the composer. It
  cannot be scrolled, so no gesture can ask for history: it pages older
  history itself while Core reports `olderPageFits` (at the live head, with
  room in both the window and the derived model), and stops before a page
  would trim the live head. Core enforces that: an older page that overruns
  the derived model under a following reader (no anchor) is refused, never
  admitted by evicting the newest segment, and no more is offered until the
  content shrinks. A reader paging history always reports an anchor row. A
  fill backs off an unchanged cursor, stops after eight pages without
  filling, waits for a read in progress (including the initial prefetch)
  instead of cancelling it, and leaves a failed read and its Retry on screen.
- While following, same-record text growth, tool grouping/expansion, streaming
  preview, optimistic outgoing bubbles and receipt replacement keep the end
  visible. The end is after all content, not the top of the last tall row.
  The end position lands in the same layout pass as the change; a correction
  one frame later draws the stale position first and reads as a stutter.
- A full head page rolls: each append drops its oldest record. While it still
  holds the viewport's newest record, a following reader keeps its retained
  history and the transcript continues through the head's newest record.
  When a roll, or a Codex/OpenCode revision that splits the head (the host
  keeps only its last part), leaves rows between the viewport and the head,
  Core keeps presenting the rows it already showed (`bridgesToHead`, read as
  live) and a following reader asks for the newer page that retains them, so
  the newest rows never vanish and history stays. Only when more than a page
  would need bridging, or the derived model cannot hold both, does the reader
  fall back to the head page alone; a gap nothing bridges returns a following
  reader to the latest page instead of leaving them on history.
- Scrolling toward older content suspends following. Live updates must not
  steal the reader's position, including when the newest retained record is
  still in the current page. Preserve the visible keyed row and pixel offset
  across older-page prepend and retained-window resegmentation.
- Return to Latest is available after viewport detachment, not only after
  history-window eviction. It resumes following; it fetches a fresh head only
  when the retained window is behind or paused. Sending a new message also
  resumes following, but a later user scroll can suspend it again while the
  message is still awaiting its receipt.
- The return control has its own layout space and a full 44-point touch target;
  transcript glyphs must not show through or collide with its label. An explicit
  return requested during a refresh is coalesced and runs next, ahead of stale
  history demand. Backgrounding, disabling, or retiring the route clears it.
- Scrolling back to the actual end resumes following. Keyboard, composer and
  viewport resizing preserve the current mode. Layout changes are not user
  gestures and do not request history.
- Retained historical windows remain pageable immediately after mount/remount;
  readiness for pagination is independent of eligibility to follow live data.
  Native Pi windows page backward at the top edge like Codex/Claude; legacy
  provider paging direction never overrides an acknowledged native window.
- Read receipts require the latest canonical record to be visibly present.
  An optimistic bubble, eager row construction or follow intention is not a
  receipt.

## Mechanism

Keep user follow intention separate from geometry. Native user scroll input
updates intention and ranged-history demand; layout measurements trigger one
end-position correction only while following. Stable record/block and tool-run
keys continue to preserve detached anchors. iOS pins the bottom from the
scroll view's content-size and bounds observers, deferring a pin under a
finger or fling until it settles; Android requests the end item in
composition (`requestScrollToItem`) so the next measure applies it, and again
from the list's own layout when a resize such as the IME skips composition.
No permanent timer, provider poll, network request or transport-specific
scroll implementation is introduced.

## Recorded regression

Before production changes, both production detail views failed an isolated
real-Core fixture: a delayed 100-record bootstrap with grouped tools followed
by an 80-line replacement of the same final record ID. Initial bottom placement
passed; the replacement left the reply end offscreen. iPad measured the text
bottom at 1477.5 points against viewport bottom 973 (3-point assertion margin).
Android's final text block was not displayed. Original recordings and private
test artifacts are referenced in the implementation ledger, not tracked here.

Acceptance includes repeated same-ID growth, detached growth, explicit return,
changed tool coalescing, initially detached paging, older/newer window traversal,
outgoing/receipt replacement and keyboard/composer resizing. Synthetic fixtures
exercise production UI and shared reduction; real-provider/SSH and physical
device checks remain separately identified evidence boundaries.
