# Android Mosh gesture and shutdown recovery

Primary Mosh history arrives asynchronously through the tmux SSH side channel.
The terminal must retain drag distance and native release motion while a capture
rebuilds its transcript. Previously, the first capture placed the terminal one
row above the tail using a setter that also stopped its fling. A retired history
delivery could additionally leave the presentation latch set after typing.

The primary history controller now opts into native pixel accumulation during
capture. A matching capture bind preserves motion; typing, owner changes,
failed/refused/timed-out requests and disposal cancel it. Placement consumes the
accumulated position and preserves an already running fling. Reaching the oldest loaded
row requests a deeper page before the native scroller clamps away its overflow.
If the finger releases before the first capture is visible, retain its release
velocity and start the native animation at presentation. Advancing an invisible
fling during network wait otherwise turns a slow first capture into a jump to an
already-settled position. A new touch, typing, cancellation or disabled smoothing
retires that deferred release.
SSH scrollback and alternate-screen mouse/arrow dispatch retain their existing
routes. The shared render ledger reports terminal scroll-request refusals;
Find's existing idempotent behavior is unchanged.

Returning to the live tail retires the captured transcript, so re-entering
history requires a fresh authoritative capture. Previously, that request waited
for pane metadata before sending `capture-pane`, adding a second SSH round trip
before any text could move. The shared ledger now queues metadata and capture
together for the same pane ID. Metadata still validates the pane and primary
screen before the capture is accepted; cancellation retires both queued replies
by generation. This request-path improvement applies to Android and iOS,
including iPhone, while plain SSH and inline SSH+tmux keep their existing paths.

Android Mosh shutdown had a separate deadlock: a native callback could hold the
driver mutex while suspended on a full output channel. Closing that channel did
not release the already-suspended sender, and synchronous teardown waited for
the mutex on the main thread. Teardown now cancels the channel before waiting
for the driver. See the coroutine API contracts for
[close](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines.channels/-send-channel/close.html)
and [cancel](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines.channels/-receive-channel/cancel.html).

## Regression gates

Use JDK 21 and set `ANDROID_SDK_ROOT`. Every runner creates and deletes its own
AVD. The live runner uses the integration suite's disposable VPS credentials.

```sh
bash scripts/integration/run-android-scroll-harness-tests.sh qa/<run>/pixel
bash scripts/integration/run-android-mosh-scroll-tests.sh qa/<run>/history
TESSERA_MOSH_SCROLL_TEST_CLASS=com.bambouville.tessera.feature.session.MoshShutdownInstrumentedTest \
TESSERA_MOSH_SCROLL_TEST_COUNT=1 \
bash scripts/integration/run-android-mosh-scroll-tests.sh qa/<run>/shutdown
TESSERA_ANDROID_MOSH_OPENSSL_ROOT=<native-openssl-root> \
bash scripts/integration/run-android-live-scroll-tests.sh qa/<run>/live
swift test --package-path Packages/TmuxControl --filter RenderLedgerTests
```

The delayed-capture tests use the real terminal and Compose presentation
controller, including a 1.5-second delay longer than a typical Android fling.
Sample display frames from the presentation acknowledgement: eventual total
displacement alone does not prove that the first visible release glides.
The shutdown test uses the real output queue and main looper with a
controlled native producer; it backgrounds and relaunches a test Activity.
The live test uses production transports, checks first/second gestures, typing
invalidation, slow presentation, keyboard dismissal during active output,
end-of-history reversal and tmux copy-mode. It explicitly returns to the live
tail before re-entering history on the second gesture.

For a measurable request-latency comparison, set
`TESSERA_SCROLL_TRANSPORT=mosh-tmux`,
`TESSERA_SCROLL_PRESENTATION_DELAY_MS=0`, and
`TESSERA_SCROLL_TCP_DELAY_MS=150` on the live runner. This creates a temporary TCP
relay on the disposable VPS, delays each direction independently, and removes
the relay on exit. Mosh UDP remains direct. Evidence separates request-to-placement
from request-to-first-history-draw timings; the usual 1500ms presentation-delay
run verifies momentum rather than network latency. `TESSERA_SCROLL_TEST_APK`
can select a separately built baseline APK, whose SHA-256 is recorded.

The iOS driver uses asynchronous queue cleanup and non-suspending AsyncStream
output delivery, so it does not share Android's shutdown deadlock. Its history
presentation and scrolling implementation is separate. Run the existing
`S1-S6-live-scroll-transports` and `S3-live-scroll-momentum` integration cases for
cross-platform comparison. iPhone keeps its existing touch implementation;
these fixes add no UI or per-device preference. Physical finger/trackpad feel,
long background dwell, and deep Mosh paging still require device checks.
