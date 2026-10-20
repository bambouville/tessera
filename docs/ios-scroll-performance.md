# iOS scrolling: painter cost and release momentum

Tessera uses SwiftTerm's CoreGraphics painter on iOS. Every viewport movement used
to reconstruct attributed strings and CoreText lines for every visible terminal
row, including rows whose cells had not changed. This work competes with gesture
and display-link callbacks on the main thread.

The SwiftTerm fork, pinned at `93b8353f6dee85ecdf249a8943fea771dda49919`,
retains prepared text rows for the visible viewport. A
cache hit requires equal character codes, cell widths, attributes, link payloads,
column counts, link style and custom-block-glyph mode. Palette/default-color and
font changes invalidate the cache. Cell comparison handles output, history
recycling, synchronized snapshots and buffer swaps without relying on mutable
line identity. Grapheme references take the uncached path because their code
mapping belongs to the terminal. Selection, hover/modifier links and images also
use the uncached path. Row origin, fractional offset, clipping, and transforms
are still applied by the existing painter on every frame.

The cache serves the common renderer for SSH, SSH+tmux, mosh and mosh+tmux. It
changes no gesture routing, scroll multiplier, deceleration, speed preference,
remote wheel/key semantics, history fetch scheduling, or touch targets. iPhone
uses the same renderer and keeps native touch scrolling and keyboard behavior.

## Repeatable simulator gate

Run in a fresh output directory:

```sh
bash scripts/integration/run-ios-scroll-performance-tests.sh qa/scroll-performance-run
```

The runner builds the integration product, creates one owned landscape iPad,
checks native painter equivalence across content and presentation changes, then
records matched cache-disabled and cache-enabled motion. Its exit trap deletes
only its owned simulator. `TESSERA_INTEGRATION_PREBUILT=1` reuses a product that
has already been built for testing.

The debug-only workload uses a CADisplayLink and identical absolute-time point
offsets for idle, slow movement, deceleration, reversal and settling. It isolates
painter cost; it does not simulate real touch input or network latency. Metrics
are written to the app's Documents directory after sampling. A large NSLog
payload can block simulator console capture and is deliberately avoided.

`TerminalScrollbackOracleTests.testCoreGraphicsRowCacheMatchesUncachedPixelsAcrossMutations`
compares painter pixels after scrolling, output, palette, foreground, selection,
font, Unicode, link, synchronized-buffer and alternate-screen changes. It invokes
the painter directly to exclude independently settling UIKit caret/selection
child layers from the comparison. Existing native hidden-terminal and live S1/S6
cases cover the composed surface and real input paths.

## Evidence and limits

The September 12 matched landscape simulator run reduced median repaint CPU time
from 10.40 ms to 4.31 ms and the 95th percentile from 11.02 ms to 4.88 ms. The
original pre-cache binary measured 10.84 ms median, corroborating the disabled
cache baseline. The renderer comparison preserves exact settled terminal pixels.

These are Debug simulator measurements. Both recordings present at approximately
60 Hz; lower painter cost creates headroom for the 8.3 ms budget of 120 Hz devices
but does not establish physical-device frame rate or trackpad feel. The Metal
experiment had worse frame gaps in this workload and was not enabled in production.
Live scroll acceptance still requires the integration S1/S6 four-transport
sequence, plus the established human checks for deep Mosh paging and plain-Mosh
Vim. Run artifacts and the watchable comparison are under
`qa/ios-scroll-20260912/`.

## Follow-up: first-flick momentum and Mosh history

The follow-up recording showed that reducing repaint CPU did not fix interrupted
momentum. The earlier live S1/S6 harness disabled smooth scrolling for stable
screenshots, so those passes did not establish release behavior.

The live pointer path now uses UIKit's release velocity for its continuous
scroll recognizer. A separate discrete recognizer feeds the same dispatcher
without starting inertia. A short flick can consist entirely of began/ended
callbacks, so callback count cannot reliably distinguish it from a wheel notch.
Deceleration, the threefold
point multiplier and the user's speed setting are unchanged.

Mosh requests another page only near the loaded top boundary. Signed gesture and
inertia points accumulate while capture, repaint and placement are pending, then
apply once to the accepted page. A transient empty buffer or tail during rebind
does not terminate the glide. An initial attach's exact accepted frame also
settles its authority reservation; previously, the unacknowledged reservation
could replay on a later history bind and retire the page being presented.
Detached iPad history preserves the same signed placement, can deepen during the
originating glide, and releases back to the live tail after a pending reversal
reaches it. The Apple controller's initial page is 512 rows rather than 240 to
accommodate a typical default-speed flick without recapturing mid-glide.
Compact/iPhone presentation
uses the shared live-history route. Mouse-off primary finger scrolling remains
UIKit-owned. When tmux enables mouse reporting, the shared semantic recognizer
owns primary finger scrolling and compensates for the pointer multiplier so
translation remains 1:1. The same release velocity and decay model apply.

`S3-live-scroll-momentum` complements S1/S6 with real pointer flicks, production
physics, continuous video and first-release timing checks on all four transports.
The follow-up reproduction and comparison live under
`qa/ios-scroll-followup-20260912/`. These are simulator pointer measurements;
physical trackpad feel and 120 Hz pacing still require device inspection.

The aggregate review also exposed gaps in plain-Mosh numbered history. The prior
build's recording already has the same gaps (237 → 287 and 534 → 553).
The unchanged Mosh bridge diffs remote visible framebuffers; plain Mosh has no
tmux capture-pane source for recovering missing history. The momentum work does
not restore that absent output. Mosh+tmux history remains graded for complete,
coherent captured rows.

The copy-mode regression check enables mouse reporting on the actual tmux view
session after the fixture is ready, then asserts `pane_in_mode=0` before and
after primary gestures. Tracked tmux pane metadata decides primary versus TUI
routing even for a single pane; the outer tmux mouse flag must not turn primary
history gestures into remote wheel reports. Direct finger and horizontal-biased
diagonal drags exercise the same local route. Actual TUI mouse input remains
remote. S1/S6 checks primary, htop and Vim across the transport matrix.

History release now requires reaching the actual bottom, in both shared and
detached presentations. A paging proximity threshold must not discard newly
loaded history after a small upward gesture. Regression recordings, pane-mode
probes, and a copy-mode before/after comparison are archived in
`qa/ios-scroll-copymode-20260912/`.

At the shared live tail, a non-inertial downward gesture also queries tmux pane
interaction state when local mode flags are absent. This matches the detached
history route and preserves the first htop/Vim gesture after returning from a
history repaint. The asynchronous reply rechecks the view, session, control,
and agent-protection gates before forwarding queued input.
