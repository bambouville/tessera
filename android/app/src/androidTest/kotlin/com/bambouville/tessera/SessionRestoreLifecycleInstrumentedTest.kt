package com.bambouville.tessera

import android.content.Intent
import android.os.SystemClock
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.bambouville.tessera.data.AndroidHostRepository
import com.bambouville.tessera.data.AndroidSessionRestoreRepository
import com.bambouville.tessera.data.HostDraft
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.data.continuity.AndroidForegroundRestoreStore
import com.bambouville.tessera.data.continuity.ForegroundRestoreDocument
import com.bambouville.tessera.data.continuity.ForegroundRestoreSnapshot
import com.bambouville.tessera.data.continuity.SessionRestoreCoordinator
import com.bambouville.tessera.data.continuity.SessionRestorePolicy
import com.bambouville.tessera.data.continuity.SessionRestoreTaskRemoval
import com.bambouville.tessera.feature.session.LiveSessionStore
import com.bambouville.tessera.lifecycle.DiagnosticLogStore
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The restore machinery's wiring, driven through real Activity lifecycle edges.
 *
 * The *decisions* restore makes are the shared core's and are pinned in
 * `Packages/TesseraCore` and by `ForegroundRestoreWindowTest`. Nothing here
 * re-tests them. What these cases cover is the layer above, which is where
 * every restore bug on both platforms has actually lived: whether the write
 * that arms the next wake survives the edge that triggers it, whether one user
 * launch produces one restore, and whether a gesture the user did not mean as
 * "forget my sessions" is treated as one.
 *
 * Several of these fail today. That is deliberate — they describe how restore
 * should behave, and a suite written against current behaviour would only
 * freeze the defects in place. `docs/android-session-restore-plan.md` maps each
 * case to the defect it covers.
 *
 * **Offline by construction.** The fixture hosts point at a closed loopback
 * port, so restore's reconnect refuses immediately: no DNS, no network, and no
 * connection to anything the user owns. A refused connect leaves the tab in
 * `Failed` rather than `Terminated`, so the tab and its snapshot survive, which
 * is what these cases need.
 *
 * **Run on a disposable emulator.** Every case writes to the real host database
 * and the real restore stores. `scripts/android/run-restore-lifecycle-gate.sh`
 * creates and deletes its own AVD.
 */
@RunWith(AndroidJUnit4::class)
class SessionRestoreLifecycleInstrumentedTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val hosts = AndroidHostRepository(context)
    private val records = AndroidSessionRestoreRepository(context)
    private val documents = AndroidForegroundRestoreStore(context)
    private val diagnostics = DiagnosticLogStore(context)

    private lateinit var fixtures: List<SavedHost>

    @Before
    fun seedTwoStoredSessions() {
        // Restore's state is process-scoped by design, and every case here runs
        // in one process. Without this the second case would inherit the
        // first's completed cold-start pass and never run one of its own.
        finishAllActivities()
        SessionRestoreCoordinator.resetForTests()
        // Sessions now outlive an Activity on purpose, so one case's tabs would
        // otherwise still be up when the next one launches — and its cold-start
        // pass would correctly find nothing left to restore.
        LiveSessionStore.resetForTests()
        runBlocking {
            records.deleteAll()
            documents.clear()
            documents.updateRestorePolicy(SessionRestorePolicy.ALWAYS)
            fixtures = listOf("alpha", "beta").map { name ->
                hosts.save(
                    HostDraft(
                        displayName = "restore-fixture-$name-$token",
                        // Port 1 on loopback: refused instantly, offline, and
                        // not a host the user owns.
                        hostname = "127.0.0.1",
                        port = 1,
                        username = "fixture",
                        transportKind = TransportKinds.SSH,
                    ),
                )
            }
            documents.save(storedDocument())
        }
        diagnostics.clear()
    }

    @After
    fun removeFixtures() {
        finishAllActivities()
        LiveSessionStore.resetForTests()
        runBlocking {
            records.deleteAll()
            documents.clear()
            fixtures.forEach { hosts.delete(it.id) }
        }
    }

    // MARK: - the write that arms the next wake

    @Test
    fun theBackgroundEdgeWriteLandsWhenTheActivityIsStopped() {
        // Covers D2. The wake path is gated on a latch that only the
        // background-edge write sets, and that write runs on the Activity's own
        // coroutine scope. Stopping is the gentle case: the scope survives, so
        // this is the edge that should be hardest to lose.
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            awaitRestorePlan()
            diagnostics.clear()

            scenario.moveToState(Lifecycle.State.CREATED)

            awaitLine("restore_persist detail=active=false")
        }
    }

    @Test
    fun theBackgroundEdgeWriteLandsWhenTheActivityIsDestroyed() {
        // Covers D2, the case that actually bites: on a real device ON_STOP and
        // composition disposal are ~30 ms apart, and the write does two
        // suspending DataStore round trips before it records anything. The
        // Activity's scope is cancelled at ON_DESTROY and takes the write with
        // it, so the next launch seeds from whatever the last foreground write
        // happened to leave.
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        awaitRestorePlan()
        diagnostics.clear()

        scenario.close()

        awaitLine("restore_persist detail=active=false")
        runBlocking {
            val document = documents.load()
            assertNotNull("the departing write must leave a document behind", document)
            assertEquals(2, document!!.snapshots.size)
        }
    }

    // MARK: - one launch, one restore

    @Test
    fun anActivityRecreationDoesNotRestoreASecondTime() {
        // Covers D4. Restore's own state moved out of the composition first,
        // which stopped the replay; the sessions themselves followed, which is
        // what makes the word "surviving" true. On the reporter's device this
        // produced two launches 370 ms apart, two plans, four reconnects and
        // one host holding two transports, with the first instance's
        // controllers closed mid-connect.
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            awaitRestorePlan()
            settle()
            val live = LiveSessionStore.get().liveHostIds
            assertEquals("the launch opened a tab per stored session", 2, live.size)
            diagnostics.clear()

            scenario.recreate()
            settle()

            assertEquals(
                "a recreation is not a new launch",
                0,
                diagnostics.read().lineSequence().count { it.contains("startup_restore_plan") },
            )
            assertEquals(
                "the surviving sessions must not be reconnected again",
                0,
                diagnostics.read().lineSequence().count { it.contains("restore_reconnect_start") },
            )
            // Was "not closed mid-connect", which was as much as could be asked
            // while every recreation closed every transport it found. Nothing
            // may be closed at all now: a window being rebuilt is not a session
            // being ended, and the tabs are the same ones, not replacements.
            assertTrue(
                "a recreation must not close a transport",
                diagnostics.read().lineSequence().none { it.contains("session_controller_close") },
            )
            assertEquals(
                "the same sessions are still live after the recreation",
                live,
                LiveSessionStore.get().liveHostIds,
            )
        }
    }

    @Test
    fun aRelaunchOnAWarmProcessGetsItsOwnPassAndFindsNothingToRebuild() {
        // The other half of `anActivityRecreationDoesNotRestoreASecondTime`,
        // and the case whose answer the D4 move changes.
        //
        // The pass is claimed for the process so a configuration change cannot
        // replay it. A relaunch onto a process Android kept alive looks exactly
        // like a recreation to that latch, so `94d65a0c` gave a real background
        // edge the right to re-arm it: without that, the reporter closed the app
        // with one session open, came back to a dormant `reconnect` row, and got
        // not one startup_restore line in 2473 lines of log to say which guard
        // held. That re-arm still has to happen, and is what the first two
        // assertions are about.
        //
        // What it then decides is the part that moved. The sessions no longer
        // go with the destroyed composition, so the relaunch's own cold-start
        // pass correctly finds every stored host already on screen and plans
        // nothing — and must keep the document rather than clearing over the
        // entries it excluded. A session that really did die is reconnected by
        // the wake window, not by rebuilding a tab that never went away.
        ActivityScenario.launch(MainActivity::class.java).use { first ->
            awaitRestorePlan()
        }
        // Closing the first scenario is a real background edge: ON_STOP sees no
        // configuration change, so it notes the edge the next composition
        // consumes. The process stays warm, which is the whole point.
        awaitLine("restore_persist detail=active=false")
        assertEquals(
            "the tabs outlive the Activity that showed them",
            2,
            LiveSessionStore.get().liveHostIds.size,
        )
        diagnostics.clear()

        ActivityScenario.launch(MainActivity::class.java).use {
            awaitLine("startup_restore_skip reason=nothingRestorable")
            settle()

            // Exactly once, which is the whole difficulty: the pass has to come
            // back for a relaunch without coming back for a recreation. The
            // effect is keyed on `continuityState`/`loadedHosts`, so it re-runs
            // as those settle and the later runs correctly report the pass as
            // already spent — an `already-evaluated` line here is the latch
            // working, not leaking. The count is what distinguishes them.
            assertEquals(
                "a relaunch owes its sessions exactly one cold-start pass",
                1,
                diagnostics.read().lineSequence()
                    .count { it.contains("startup_restore_skip reason=nothingRestorable") },
            )
            assertEquals(
                "nothing died, so nothing is rebuilt",
                0,
                diagnostics.read().lineSequence().count { it.contains("startup_restore_plan") },
            )
            assertEquals(
                "and the sessions are the ones the first launch opened",
                2,
                LiveSessionStore.get().liveHostIds.size,
            )
        }
        runBlocking {
            val document = documents.load()
            assertNotNull(
                "entries excluded because their host is already open were not judged unrestorable",
                document,
            )
            assertEquals(2, document!!.snapshots.size)
        }
    }

    // MARK: - every wake gets a window

    @Test
    fun everyForegroundReturnOpensAWakeWindow() {
        // Covers D3. The latch is a plain field on a remembered object, armed
        // at the end of an asynchronous write and read once, synchronously, by
        // an effect whose keys never change when the arm lands. A wake that
        // recomposes first gets no window at all and nothing retries it, so the
        // failure is a race and shows up as a count, not a crash.
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            awaitRestorePlan()
            diagnostics.clear()

            repeat(WAKE_CYCLES) {
                scenario.moveToState(Lifecycle.State.CREATED)
                scenario.moveToState(Lifecycle.State.RESUMED)
                settle()
            }

            assertEquals(
                "each foreground return owes its sessions one wake window",
                WAKE_CYCLES,
                diagnostics.read().lineSequence().count { it.contains("restore_window_open") },
            )
        }
    }

    @Test
    fun aConfigurationChangeIsNotABackgroundEdge() {
        // Covers D5. `MainActivity.onStop` already refuses to treat a
        // configuration change or an app-launched external screen as a real
        // background edge; the composable's own ON_STOP observer does not, so a
        // file picker or a permission screen closes the window mid-wake and
        // reopens a fresh 60 s one over sessions that never died.
        //
        // Only meaningful once `theBackgroundEdgeWriteLandsWhenTheActivityIsDestroyed`
        // passes: while that write is being cancelled this asserts an absence
        // that holds for the wrong reason.
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            awaitRestorePlan()
            diagnostics.clear()

            scenario.recreate()
            settle()

            assertTrue(
                "a configuration change must not spend the wake budget",
                diagnostics.read().lineSequence().none { it.contains("restore_window_open") },
            )
        }
    }

    // MARK: - a launch that carries a payload still restores

    @Test
    fun aShareLaunchStillRestores() {
        // Covers D6. The cold-start path gives up silently whenever the tab
        // list is already non-empty, so any launch that opens a host first — a
        // share target, a direct-share shortcut, an agent notification — takes
        // restore with it, with nothing logged to say so.
        val share = Intent(context, MainActivity::class.java)
            .setAction(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, "restore fixture payload")
            // MainActivity is singleTask, so a share arriving while a task
            // already exists is delivered to the running instance through
            // onNewIntent and never reaches onCreate — which ActivityScenario
            // cannot track. Force a fresh instance so this case exercises the
            // cold-launch-with-a-payload it is about.
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)

        // Started directly rather than through ActivityScenario: MainActivity
        // is singleTask, and ActivityScenario cannot track an activity the
        // system routes into an existing task — it waits forever on an
        // onCreate that never comes, reporting PRE_ON_CREATE. Starting it the
        // way the share sheet does exercises the real path anyway.
        // Started, then waited for. A singleTask launch lands only once the
        // previous case's task is genuinely gone, and `finishAllActivities`
        // returns when the last Activity reports DESTROYED — which is earlier
        // than the system finishing with the task. Running alone this is never
        // visible; in a suite it is, so the start is retried rather than raced.
        context.startActivity(share)
        if (!awaitLiveActivity()) context.startActivity(share)
        awaitRestorePlan()
    }

    // MARK: - the gestures that mean "forget them" and the ones that do not

    @Test
    fun removingTheTaskKeepsTheDocumentWhenRestoreIsOn() {
        // Covers D1, and the likeliest cause of the reported symptom: swiping
        // Tessera out of recents deletes both restore stores on purpose, so the
        // most natural way to test "restart the app" can never restore. iOS
        // treats the same gesture as an ordinary termination.
        ActivityScenario.launch(MainActivity::class.java).use { awaitRestorePlan() }

        runBlocking {
            SessionRestoreTaskRemoval.apply(
                policy = SessionRestorePolicy.ALWAYS,
                records = records,
                documents = documents,
            )
            assertNotNull(
                "the restore setting decides what the next launch does, not the recents gesture",
                documents.load(),
            )
        }
    }

    @Test
    fun turningRestoreOffClearsTheDocumentAndRestoresNothing() {
        // Nothing broken here today. It is the counterweight to every other
        // case: as restore is made to survive more edges, NEVER must keep
        // meaning never, on all of them.
        runBlocking { documents.updateRestorePolicy(SessionRestorePolicy.NEVER) }

        ActivityScenario.launch(MainActivity::class.java).use {
            settle()
            assertTrue(
                "restore is off; nothing may be planned",
                diagnostics.read().lineSequence().none { line -> line.contains("startup_restore_plan") },
            )
            runBlocking {
                SessionRestoreTaskRemoval.apply(
                    policy = SessionRestorePolicy.NEVER,
                    records = records,
                    documents = documents,
                )
            }
        }
        runBlocking {
            assertEquals("restore is off; nothing may be kept", null, documents.load())
        }
    }

    // MARK: - fixtures

    private val token = UUID.randomUUID().toString().take(8)

    private fun storedDocument(): ForegroundRestoreDocument {
        val snapshots = fixtures.map { host ->
            ForegroundRestoreSnapshot(
                sessionId = UUID.randomUUID().toString(),
                hostId = host.id,
                displayName = host.displayName,
                createdAtEpochMilliseconds = System.currentTimeMillis(),
                transportKind = TransportKinds.SSH,
                tmuxTarget = null,
                lastSelection = null,
                reconnectRequired = true,
            )
        }
        return ForegroundRestoreDocument(
            savedAtEpochMilliseconds = System.currentTimeMillis(),
            snapshots = snapshots,
            selectedSessionId = snapshots.first().sessionId,
        )
    }

    /** Wait for the cold-start path to have acted, so a case starts from a known point. */
    private fun awaitRestorePlan() = awaitLine("startup_restore_plan")

    private fun awaitLine(needle: String) {
        val deadline = SystemClock.uptimeMillis() + AWAIT_TIMEOUT_MILLISECONDS
        while (SystemClock.uptimeMillis() < deadline) {
            if (diagnostics.read().lineSequence().any { it.contains(needle) }) return
            SystemClock.sleep(POLL_MILLISECONDS)
        }
        throw AssertionError(
            "timed out waiting for \"$needle\" in the diagnostics report\n" +
                diagnostics.read().lineSequence().toList().takeLast(40).joinToString("\n"),
        )
    }

    /**
     * Wait until no Activity is alive.
     *
     * A case that starts while the previous one's Activity is still winding
     * down inherits its foreground write: a live-only persist with an empty tab
     * list, which clears the document this case just seeded. The failure then
     * looks like restore losing the document, which is the very thing under
     * test — so the isolation is made explicit rather than raced.
     */
    private fun finishAllActivities() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val deadline = SystemClock.uptimeMillis() + AWAIT_TIMEOUT_MILLISECONDS
        while (SystemClock.uptimeMillis() < deadline) {
            var live = 0
            instrumentation.runOnMainSync {
                val registry = ActivityLifecycleMonitorRegistry.getInstance()
                Stage.values().filterNot { it == Stage.DESTROYED }.forEach { stage ->
                    registry.getActivitiesInStage(stage).forEach { activity ->
                        live += 1
                        if (!activity.isFinishing) activity.finish()
                    }
                }
            }
            if (live == 0) return
            SystemClock.sleep(POLL_MILLISECONDS)
        }
    }

    /** Whether an Activity came up within the launch window. */
    private fun awaitLiveActivity(): Boolean {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val deadline = SystemClock.uptimeMillis() + LAUNCH_TIMEOUT_MILLISECONDS
        while (SystemClock.uptimeMillis() < deadline) {
            var live = 0
            instrumentation.runOnMainSync {
                val registry = ActivityLifecycleMonitorRegistry.getInstance()
                live = Stage.values()
                    .filterNot { it == Stage.DESTROYED }
                    .sumOf { registry.getActivitiesInStage(it).size }
            }
            if (live > 0) return true
            SystemClock.sleep(POLL_MILLISECONDS)
        }
        return false
    }

    /** Let the 500 ms window tick and any pending write run to completion. */
    private fun settle() = SystemClock.sleep(SETTLE_MILLISECONDS)

    private companion object {
        const val AWAIT_TIMEOUT_MILLISECONDS = 20_000L
        const val POLL_MILLISECONDS = 100L
        const val SETTLE_MILLISECONDS = 3_000L
        const val LAUNCH_TIMEOUT_MILLISECONDS = 5_000L

        /** Enough repeats that a race shows as a count, not as a flake. */
        const val WAKE_CYCLES = 8
    }
}
