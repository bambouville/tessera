package com.bambouville.tessera.feature.agentcenter

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.view.FrameMetrics
import android.view.InputDevice
import android.view.MotionEvent
import android.view.Window
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composer
import androidx.compose.runtime.CompositionTracer
import androidx.compose.runtime.InternalComposeTracingApi
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraTheme
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Other agents' activity reaches Agent Center as Core's lifecycle + list
 * snapshot pair. Neither changes the selected transcript, so neither may
 * recompose it: on a reader's fling each such recomposition is a stall.
 * Counts use the Compose compiler's trace hooks, which fire only for a body
 * that actually ran, so a skipped composable costs nothing and counts zero.
 */
@RunWith(AndroidJUnit4::class)
class AgentTranscriptSiblingUpdateInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<AgentFixtureActivity>()

    @Test fun splitSiblingUpdatesLeaveTheSelectedTranscriptComposed() = assertSiblingUpdatesSkipTranscript(compact = false)

    @Test fun compactSiblingUpdatesLeaveTheSelectedTranscriptComposed() = assertSiblingUpdatesSkipTranscript(compact = true)

    private fun assertSiblingUpdatesSkipTranscript(compact: Boolean) {
        val fixture = SiblingActivityFixture()
        val state = MutableStateFlow(fixture.initialState())
        val actions = SiblingHarnessActions()
        compose.activityRule.scenario.onActivity { it.installFixture { TesseraTheme {
            SiblingActivityHarness(state, actions, compact, Modifier.fillMaxSize().safeDrawingPadding())
        } } }
        compose.waitUntil(10_000) {
            compose.onAllNodes(androidx.compose.ui.test.hasTestTag("agent-transcript-list"))
                .fetchSemanticsNodes(atLeastOneRootRequired = false).size == 1
        }
        // A reader has left the live tail: the scenario the user reported.
        repeat(2) {
            compose.onNodeWithTag("agent-transcript-list").performTouchInput { swipeDown(durationMillis = 300) }
            compose.waitForIdle()
        }
        val counter = BodyCounter()
        var publishedListTicks = 0
        compose.runOnIdle { counter.install() }
        try {
            repeat(SIBLING_EVENTS) { event ->
                // Core emits lifecycleAccepted then listSnapshot for one hook.
                compose.runOnIdle { state.value = state.value.withThreadSnapshot(fixture.siblingDetail(event)) }
                compose.waitForIdle()
                compose.runOnIdle {
                    val before = state.value
                    state.value = fixture.listTick(before, event)
                    // StateFlow drops an equal state; only a reordered list reaches Compose.
                    if (state.value !== before) publishedListTicks++
                }
                compose.waitForIdle()
            }
        } finally { compose.runOnIdle { counter.uninstall() } }
        val counts = compose.runOnIdle { counter.summary() }.put("publishedListTicks", publishedListTicks)
        android.util.Log.i(LOG_TAG, "TESSERA_SIBLING_RECOMPOSE ${if (compact) "compact" else "split"} $counts")
        assertTrue("no list tick reached the UI: $counts", publishedListTicks > 0)
        // The updates reached the UI: rows (split) or the screen body (compact) ran.
        assertTrue("sibling updates never reached composition: $counts",
            counts.getInt(if (compact) "harness" else "threadRow") > 0)
        for (name in listOf("detailPane", "transcriptItem", "blockCard", "toolRunCard", "markdown", "composer")) {
            assertEquals("$name recomposed for an unrelated thread: $counts", 0, counts.getInt(name))
        }
    }
}

/**
 * Measurement only (not an assertion): real Choreographer frames, real touch
 * flings and sibling updates at Core's observed cadence. Enable with
 * `-e tesseraSiblingJank <split|compact>` so aggregate runs stay deterministic.
 */
@RunWith(AndroidJUnit4::class)
class AgentTranscriptSiblingJankInstrumentedTest {
    @Test fun siblingUpdatesWhileFlingingFrameTimings() {
        val mode = InstrumentationRegistry.getArguments().getString("tesseraSiblingJank")
        assumeTrue(mode == "split" || mode == "compact")
        val compact = mode == "compact"
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val fixture = SiblingActivityFixture()
        val state = MutableStateFlow(fixture.initialState())
        val actions = SiblingHarnessActions()
        ActivityScenario.launch(AgentFixtureActivity::class.java).use { scenario ->
            var window: Window? = null
            scenario.onActivity { activity ->
                window = activity.window
                activity.installFixture { TesseraTheme {
                    SiblingActivityHarness(state, actions, compact, Modifier.fillMaxSize().safeDrawingPadding())
                } }
            }
            settle(instrumentation, 2_000)
            val frames = FrameRecorder(checkNotNull(window))
            val main = Handler(Looper.getMainLooper())
            try {
                val results = JSONObject()
                // Leave the live tail first, as the reader did.
                repeat(3) { fling(instrumentation, down = true); settle(instrumentation, 900) }
                // Per-update cost with nothing else drawing: each frame is one update pair.
                results.put("idleUpdates", frames.record { runUpdates(main, fixture, state, 21, scrolling = null, instrumentation) })
                results.put("flingNoUpdates", frames.record { flings(instrumentation, 8) })
                results.put("flingWithUpdates", frames.record {
                    runUpdates(main, fixture, state, 56, scrolling = { flings(instrumentation, 8) }, instrumentation)
                })
                android.util.Log.i(LOG_TAG, "TESSERA_SIBLING_JANK $mode $results")
            } finally { frames.close() }
        }
    }

    private fun runUpdates(main: Handler, fixture: SiblingActivityFixture, state: MutableStateFlow<AgentCenterUiState>, count: Int,
        scrolling: (() -> Unit)?, instrumentation: android.app.Instrumentation) {
        val start = SystemClock.uptimeMillis() + 50
        repeat(count) { event ->
            // ~7 Hz: one lifecycle snapshot then one list snapshot per hook.
            main.postAtTime({ state.value = state.value.withThreadSnapshot(fixture.siblingDetail(event)) }, start + event * UPDATE_PERIOD_MS)
            main.postAtTime({ state.value = fixture.listTick(state.value, event) }, start + event * UPDATE_PERIOD_MS + 1)
        }
        scrolling?.invoke()
        val end = start + count * UPDATE_PERIOD_MS + 400
        while (SystemClock.uptimeMillis() < end) SystemClock.sleep(50)
        instrumentation.waitForIdleSync()
    }

    private fun flings(instrumentation: android.app.Instrumentation, count: Int) {
        repeat(count) { index ->
            fling(instrumentation, down = index % 2 == 0)
            settle(instrumentation, 800)
        }
    }

    private fun fling(instrumentation: android.app.Instrumentation, down: Boolean) {
        val metrics = instrumentation.targetContext.resources.displayMetrics
        val x = metrics.widthPixels * 0.75f
        val from = metrics.heightPixels * (if (down) 0.35f else 0.70f)
        val to = metrics.heightPixels * (if (down) 0.70f else 0.35f)
        val downTime = SystemClock.uptimeMillis()
        fun inject(action: Int, y: Float, time: Long) {
            val event = MotionEvent.obtain(downTime, time, action, x, y, 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
            instrumentation.uiAutomation.injectInputEvent(event, true)
            event.recycle()
        }
        inject(MotionEvent.ACTION_DOWN, from, downTime)
        val steps = 8
        for (step in 1..steps) {
            SystemClock.sleep(10)
            inject(MotionEvent.ACTION_MOVE, from + (to - from) * step / steps, SystemClock.uptimeMillis())
        }
        inject(MotionEvent.ACTION_UP, to, SystemClock.uptimeMillis())
    }

    private fun settle(instrumentation: android.app.Instrumentation, millis: Long) {
        SystemClock.sleep(millis)
        instrumentation.waitForIdleSync()
    }

    /** FrameMetrics for the fixture window; durations are per rendered frame. */
    private class FrameRecorder(private val window: Window) : AutoCloseable {
        private val thread = HandlerThread("sibling-frame-metrics").apply { start() }
        private val lock = Any()
        private var active: MutableList<LongArray>? = null
        private val listener = Window.OnFrameMetricsAvailableListener { _, metrics, _ ->
            // Compose recomposes in the animation callback and measures,
            // lays out and records in draw; together with input and sync
            // this is the UI thread's share of the frame.
            val ui = metrics.getMetric(FrameMetrics.INPUT_HANDLING_DURATION) + metrics.getMetric(FrameMetrics.ANIMATION_DURATION) +
                metrics.getMetric(FrameMetrics.LAYOUT_MEASURE_DURATION) + metrics.getMetric(FrameMetrics.DRAW_DURATION) +
                metrics.getMetric(FrameMetrics.SYNC_DURATION)
            val row = longArrayOf(metrics.getMetric(FrameMetrics.TOTAL_DURATION),
                metrics.getMetric(FrameMetrics.ANIMATION_DURATION),
                metrics.getMetric(FrameMetrics.DRAW_DURATION), ui)
            synchronized(lock) { active?.add(row) }
        }
        init { window.addOnFrameMetricsAvailableListener(listener, Handler(thread.looper)) }

        fun record(block: () -> Unit): JSONObject {
            val rows = mutableListOf<LongArray>()
            synchronized(lock) { active = rows }
            try { block() } finally {
                SystemClock.sleep(300) // FrameMetrics are delivered after the frame.
                synchronized(lock) { active = null }
            }
            val snapshot = synchronized(lock) { rows.toList() }
            fun ms(nanos: Long) = nanos / 1_000_000.0
            fun percentile(values: List<Long>, p: Double) = if (values.isEmpty()) 0.0 else ms(values.sorted()[((values.size - 1) * p).toInt()])
            fun mean(values: List<Long>) = if (values.isEmpty()) 0.0 else ms(values.sum() / values.size)
            val total = snapshot.map { it[0] }
            val animation = snapshot.map { it[1] }
            val draw = snapshot.map { it[2] }
            val ui = snapshot.map { it[3] }
            return JSONObject()
                .put("frames", snapshot.size)
                .put("totalP50", percentile(total, 0.50)).put("totalP90", percentile(total, 0.90)).put("totalMax", percentile(total, 1.0))
                .put("uiMean", mean(ui)).put("uiP50", percentile(ui, 0.50)).put("uiP90", percentile(ui, 0.90))
                .put("uiP99", percentile(ui, 0.99)).put("uiMax", percentile(ui, 1.0))
                .put("uiOver8ms", ui.count { it > 8_000_000L }).put("uiOver16ms", ui.count { it > 16_666_667L })
                .put("animationMean", mean(animation)).put("animationP90", percentile(animation, 0.90)).put("animationMax", percentile(animation, 1.0))
                .put("drawMean", mean(draw)).put("drawP90", percentile(draw, 0.90))
        }

        override fun close() {
            window.removeOnFrameMetricsAvailableListener(listener)
            thread.quitSafely()
        }
    }
}

private const val LOG_TAG = "TesseraSiblingUpdates"
private const val SIBLING_EVENTS = 14
private const val UPDATE_PERIOD_MS = 143L
private const val SIBLINGS = 6

/**
 * Counts composable bodies by the compiler's trace name. Skipped calls never
 * reach [traceEventStart]. Main-thread only, installed between frames.
 */
@OptIn(InternalComposeTracingApi::class)
private class BodyCounter : CompositionTracer {
    private val counts = HashMap<String, Int>()
    override fun isTraceInProgress(): Boolean = true
    override fun traceEventStart(key: Int, dirty1: Int, dirty2: Int, info: String) {
        val name = info.substringBefore(" (")
        counts[name] = (counts[name] ?: 0) + 1
    }
    override fun traceEventEnd() {}
    fun install() = Composer.setTracer(this)
    fun uninstall() = Composer.setTracer(null)

    fun summary(): JSONObject {
        fun count(predicate: (String) -> Boolean) = counts.filterKeys(predicate).values.sum()
        return JSONObject()
            .put("harness", count { it.endsWith(".SiblingActivityHarness") })
            .put("threadRow", count { it == "$PACKAGE.AgentThreadRow" })
            .put("listPane", count { it == "$PACKAGE.AgentListPane" })
            .put("detailPane", count { it == "$PACKAGE.AgentDetailPane" })
            .put("detailPaneTree", count { it.startsWith("$PACKAGE.AgentDetailPane") })
            // The transcript's lazy item bodies (outgoing messages are empty here).
            .put("transcriptItem", count { it == "androidx.compose.foundation.lazy.items.<anonymous>" })
            .put("lazyInternals", count { it.startsWith("androidx.compose.foundation.lazy.") })
            .put("blockCard", count { it.startsWith("$PACKAGE.AgentBlockCard") })
            .put("toolRunCard", count { it == "$PACKAGE.AgentToolRunCard" })
            .put("markdown", count { it.startsWith("com.bambouville.tessera.markdown.") })
            .put("composer", count { it == "$PACKAGE.Composer" })
            .put("allBodies", counts.values.sum())
    }

    private companion object { const val PACKAGE = "com.bambouville.tessera.feature.agentcenter" }
}

/** Presenter stand-in: the harness captures it exactly where the screen captures the presenter. */
internal class SiblingHarnessActions {
    fun search(query: String) = Unit
    fun select(key: String?) = Unit
    fun setGrouping(value: String) = Unit
    fun requestPromptAnswer(detail: AgentThreadDetail, prompt: AgentPrompt, answer: AgentPromptAnswerChoice) = Unit
    fun requestCandidatePromptAnswer(candidate: AgentTerminalCandidate, prompt: AgentPrompt, option: AgentPromptOption) = Unit
    fun setTitleCharacterBudget(value: Int) = Unit
    fun setCardVisible(key: String, visible: Boolean) = Unit
    fun requestAction(detail: AgentThreadDetail, kind: String, text: String? = null): Boolean = false
    fun acknowledge(key: String, recordID: String) = Unit
    fun acknowledgeCompletion(key: String) = Unit
    fun loadNewer(key: String, latest: Boolean = false) = Unit
    fun viewportAnchor(key: String, recordID: String?) = Unit
    fun loadMore(key: String) = Unit
    fun beginAttachmentSelection(detail: AgentThreadDetail): Boolean = false
    fun setDraft(key: String, text: String) = Unit
    fun appendDraft(key: String, text: String) = Unit
}

/**
 * The split/compact composition of [AgentCenterScreen], with the presenter's
 * StateFlow collected the same way and the same values captured by each
 * callback. Only presenter side effects are stubbed.
 */
@Composable
internal fun SiblingActivityHarness(
    flow: StateFlow<AgentCenterUiState>,
    presenter: SiblingHarnessActions,
    forceCompact: Boolean,
    modifier: Modifier,
) {
    val state by flow.collectAsState()
    val draftKey = state.selectedThreadKey.orEmpty()
    val draft = state.drafts[draftKey].orEmpty()
    val setDraft: (String) -> Unit = { presenter.setDraft(draftKey, it) }
    val openAttachmentPicker = remember { {} }
    val onOpenTerminal: (AgentThreadDetail) -> Unit = remember { { } }
    val startSpeech = { presenter.appendDraft(draftKey, "") }
    var launchKind by remember { mutableStateOf<AgentLaunchKind?>(null) }
    val searchFocus = remember { androidx.compose.ui.focus.FocusRequester() }
    BoxWithConstraints(modifier) {
        val expanded = !forceCompact && maxWidth >= 760.dp
        val selected = state.detail ?: state.projectedDetails[state.selectedThreadKey] ?: state.threads.firstOrNull { it.key == state.selectedThreadKey }?.let {
            AgentThreadDetail(it, emptyList(), emptyList(), emptyList(), null, false)
        }
        if (expanded) {
            Row(Modifier.fillMaxSize()) {
                AgentListPane(
                    state = state,
                    onSearch = presenter::search,
                    onSelect = presenter::select,
                    onGroupingChange = presenter::setGrouping,
                    onSpawn = { launchKind = AgentLaunchKind.Spawn },
                    onPromptAnswer = presenter::requestPromptAnswer,
                    onCandidatePromptAnswer = presenter::requestCandidatePromptAnswer,
                    onOpenTerminal = onOpenTerminal,
                    searchFocus = searchFocus,
                    onTitleWidthChange = presenter::setTitleCharacterBudget,
                    onCardVisibility = presenter::setCardVisible,
                    modifier = Modifier.widthIn(min = 300.dp, max = 360.dp).fillMaxHeight(),
                )
                TesseraHairline(Modifier.width(1.dp).fillMaxHeight())
                AgentDetailPane(
                    detail = selected,
                    draft = draft,
                    onDraftChange = setDraft,
                    onSend = { selected?.let { detail -> presenter.requestAction(detail, "send", draft) } },
                    onInterrupt = { selected?.let { presenter.requestAction(it, "interrupt") } },
                    onPromptAnswer = { prompt, option -> selected?.let { presenter.requestPromptAnswer(it, prompt, option) } },
                    onNewestVisible = { recordID -> selected?.let { presenter.acknowledge(it.row.key, recordID) } },
                    onCompletionVisible = { selected?.let { presenter.acknowledgeCompletion(it.row.key) } },
                    onLoadNewer = { selected?.let { presenter.loadNewer(it.row.key) } },
                    onReturnToLatest = { selected?.let { presenter.loadNewer(it.row.key, latest = true) } },
                    onViewportAnchor = { recordID -> selected?.let { presenter.viewportAnchor(it.row.key, recordID) } },
                    onLoadMore = { selected?.let { presenter.loadMore(it.row.key) } },
                    onOpenTerminal = { selected?.let(onOpenTerminal) },
                    onFork = { launchKind = AgentLaunchKind.Fork },
                    onStartSpeech = startSpeech,
                    speechAvailable = false,
                    onAttach = { selected?.let { if (presenter.beginAttachmentSelection(it)) openAttachmentPicker() } },
                    onQueue = { selected?.let { presenter.requestAction(it, "queue", draft) } },
                    sending = draftKey in state.sendingThreads,
                    uploading = draftKey in state.uploadingThreads,
                    loadingTranscript = draftKey in state.loadingTranscriptThreads,
                    capacityLimited = draftKey in state.ingestionCapacityThreads,
                    readStatus = state.ingestionReadStatuses[draftKey],
                    modifier = Modifier.weight(1f),
                )
            }
        } else if (selected != null) { // The compact route with its detail open.
            AgentDetailPane(
                detail = selected,
                draft = draft,
                onDraftChange = setDraft,
                onSend = { presenter.requestAction(selected, "send", draft) },
                onInterrupt = { presenter.requestAction(selected, "interrupt") },
                onPromptAnswer = { prompt, option -> presenter.requestPromptAnswer(selected, prompt, option) },
                onNewestVisible = { recordID -> presenter.acknowledge(selected.row.key, recordID) },
                onCompletionVisible = { presenter.acknowledgeCompletion(selected.row.key) },
                onLoadNewer = { presenter.loadNewer(selected.row.key) },
                onReturnToLatest = { presenter.loadNewer(selected.row.key, latest = true) },
                onViewportAnchor = { presenter.viewportAnchor(selected.row.key, it) },
                onLoadMore = { presenter.loadMore(selected.row.key) },
                onOpenTerminal = { onOpenTerminal(selected) },
                onFork = { launchKind = AgentLaunchKind.Fork },
                onStartSpeech = startSpeech,
                speechAvailable = false,
                onAttach = { if (presenter.beginAttachmentSelection(selected)) openAttachmentPicker() },
                onQueue = { presenter.requestAction(selected, "queue", draft) },
                sending = draftKey in state.sendingThreads,
                uploading = draftKey in state.uploadingThreads,
                loadingTranscript = draftKey in state.loadingTranscriptThreads,
                capacityLimited = draftKey in state.ingestionCapacityThreads,
                readStatus = state.ingestionReadStatuses[draftKey],
                onBack = { },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

/** Synthetic, content-free-of-user-data transcript and sibling activity. */
internal class SiblingActivityFixture {
    private val selectedKey = "fixture-host:claude:selected-thread"
    private val baseMillis = 1_767_225_600_000L

    private fun row(key: String, session: String, provider: String, title: String, status: String, preview: String, activity: Long) = AgentThreadRow(
        key = key, title = title, provider = provider.replaceFirstChar(Char::uppercase), model = "fixture-model", preview = preview,
        status = status, attention = if (status == "waitingForInput") "needsYou" else "none", location = "fixture-project · main",
        queuedCount = null, isFork = false, actionAvailable = true, spawnAvailable = false, forkAvailable = false,
        hostID = "fixture-host", providerID = provider, providerSessionID = session, host = "fixture host",
        contextPercent = "41.0", totalCost = "0.80", lastActivityMillis = activity, titleProvenance = "generated",
    )

    private fun siblingKey(index: Int) = "fixture-host:codex:sibling-$index"
    /** Four agents work in turn, so each hook moves its row up; two others wait or idle. */
    private fun siblingRow(index: Int, event: Int) = row(siblingKey(index), "sibling-$index", "codex", "Sibling agent $index",
        if (index < 4) "working" else listOf("idle", "waitingForInput")[(event / SIBLINGS + index) % 2],
        "Step $event of the sibling task", baseMillis + event * 1_000L)

    private fun selectedRow() = row(selectedKey, "selected-thread", "claude", "Selected long transcript", "idle", "Reading", baseMillis)

    private fun transcript(): Pair<List<AgentBlock>, List<AgentToolRunDescriptor>> {
        val blocks = mutableListOf<AgentBlock>()
        val runs = mutableListOf<AgentToolRunDescriptor>()
        for (turn in 0 until 60) {
            val time = baseMillis + turn * 60_000L
            blocks += AgentBlock("", "Please review `module$turn` and fix the **flaky** assertion in the fixture suite.",
                kind = "text", recordID = "user-$turn", displayTimeMillis = time, role = "user")
            blocks += AgentBlock("thinking", "Consider the ordering of the fixture setup.\nThe second assertion races the first.",
                kind = "thinking", recordID = "thinking-$turn", displayTimeMillis = time)
            blocks += AgentBlock("Read", "fixture/module$turn/Suite.kt", kind = "toolCall", recordID = "call-$turn", displayTimeMillis = time)
            blocks += AgentBlock("result", (1..12).joinToString("\n") { "line $it: val fixture$it = build($it)" },
                kind = "toolResult", recordID = "result-$turn", displayTimeMillis = time)
            runs += AgentToolRunDescriptor("call-$turn#0", listOf("call-$turn#0", "result-$turn#0"), "Read 1 file", "Suite.kt")
            blocks += AgentBlock("", buildString {
                append("## Change $turn\n\nThe suite shares one **clock** between cases, so the second case observes the first.\n\n")
                append("- isolate the clock per case\n- keep the fixture *immutable*\n- assert on `elapsed` only\n\n")
                append("```kotlin\nval clock = FixtureClock(start = $turn)\nassertEquals(0, clock.elapsed())\n```\n\n")
                if (turn % 3 == 0) append("| case | before | after |\n| --- | --- | --- |\n| a | flaky | stable |\n| b | 12 ms | 3 ms |\n\n")
                append("Run `./gradlew test` again to confirm; the fix touches only the test source.")
            }, kind = "text", recordID = "answer-$turn", displayTimeMillis = time)
        }
        return blocks to runs
    }

    fun initialState(): AgentCenterUiState {
        val (blocks, runs) = transcript()
        val selected = AgentThreadDetail(row = selectedRow(), live = blocks, activity = emptyList(), changes = emptyList(),
            binding = null, hasMore = false, toolRuns = runs)
        val siblings = (0 until SIBLINGS).associate { index -> siblingKey(index) to siblingDetail(index, siblingRow(index, index)) }
        return AgentCenterUiState(
            loading = false,
            threads = coreListOrder(listOf(selected.row) + (0 until SIBLINGS).map { siblingRow(it, it) }),
            selectedThreadKey = selectedKey,
            detail = selected,
            projectedDetails = siblings + (selectedKey to selected),
        )
    }

    private fun siblingDetail(index: Int, row: AgentThreadRow) = AgentThreadDetail(row = row,
        live = (0..2).map { AgentBlock("", "Sibling $index message $it", kind = "text", recordID = "sibling-$index-$it") },
        activity = emptyList(), changes = emptyList(), binding = null, hasMore = false)

    /** What Core's lifecycleAccepted carries for one sibling hook. */
    fun siblingDetail(event: Int): AgentThreadDetail {
        val index = event % SIBLINGS
        return siblingDetail(index, siblingRow(index, event)).let { it.copy(live = it.live + AgentBlock("", "Sibling step $event",
            kind = "text", recordID = "sibling-$index-step-$event")) }
    }

    /**
     * Core's following listSnapshot: every row decoded afresh (the selected
     * one unchanged) in Core's attention order, so the newest sibling moves up.
     */
    fun listTick(state: AgentCenterUiState, event: Int): AgentCenterUiState {
        val rows = coreListOrder(state.threads.map { row ->
            if (row.key == siblingKey(event % SIBLINGS)) siblingRow(event % SIBLINGS, event) else row.copy()
        })
        val retained = resolveAgentHistoricalSelection(state.selectedThreadKey, state.projectedDetails.keys, rows.map { it.key },
            ownedThreadKeys = rows.map { it.key }.toSet())
        return state.withListSnapshot(rows, emptyList(), retained)
    }

    /** `AgentCenterRuntime.listSnapshot()` attention grouping: rank, then newest activity. */
    private fun coreListOrder(rows: List<AgentThreadRow>): List<AgentThreadRow> = rows.sortedWith(compareBy<AgentThreadRow> { row ->
        when {
            row.attention == "needsYou" -> 0
            row.status == "working" -> 1
            row.attention == "unreadCompletion" -> 2
            else -> 3
        }
    }.thenByDescending { it.lastActivityMillis ?: 0L })
}

