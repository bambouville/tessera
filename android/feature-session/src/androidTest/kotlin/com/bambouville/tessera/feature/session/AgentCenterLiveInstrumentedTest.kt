package com.bambouville.tessera.feature.session

import android.os.ParcelFileDescriptor
import android.content.Context
import android.util.Base64
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertTextContains
import com.bambouville.tessera.design.TesseraTheme
import com.bambouville.tessera.feature.agentcenter.AgentCenterScreen
import com.bambouville.tessera.feature.agentcenter.targetsLiveSession
import com.bambouville.tessera.feature.agentcenter.navigateToExistingAgentTerminal
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationCoordinator
import com.bambouville.tessera.agent.platform.AndroidAgentSessionCoordinator
import com.bambouville.tessera.agent.platform.LiveAgentSessionRegistry
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityShowSource
import com.bambouville.tessera.core.bridge.SharedTmuxGridPresentation
import com.bambouville.tessera.data.AndroidAgentCenterViewPreferences
import com.bambouville.tessera.data.AndroidAgentMetadataRepository
import com.bambouville.tessera.data.CredentialKinds
import com.bambouville.tessera.data.HostDraft
import com.bambouville.tessera.data.HostRepository
import com.bambouville.tessera.data.HostTrustEvaluation
import com.bambouville.tessera.data.IdentityRepository
import com.bambouville.tessera.data.KnownHostsRepository
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.SavedIdentity
import com.bambouville.tessera.data.SavedKnownHost
import com.bambouville.tessera.data.SessionRestoreRecord
import com.bambouville.tessera.data.SessionRestoreRepository
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.feature.agentcenter.AgentCenterPresenter
import com.bambouville.tessera.feature.agentcenter.AgentBlock
import com.bambouville.tessera.feature.agentcenter.AgentTerminalCandidate
import com.bambouville.tessera.feature.agentcenter.AgentThreadDetail
import com.bambouville.tessera.feature.agentcenter.AgentThreadRow
import com.bambouville.tessera.lifecycle.DiagnosticLogStore
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import com.bambouville.tessera.terminal.TermuxTerminalSurface
import com.bambouville.tessera.terminal.GeometryNeutralTerminalViewport
import java.util.Properties
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.async
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.Rule
import org.junit.runner.RunWith

/**
 * End-to-end Agent Center proof against a host that is actually running agents.
 *
 * This is the rig the "Agent Center is empty / every row says unavailable"
 * reports needed and never had: it stands up the production
 * `SshSessionController` and the production `AgentCenterPresenter` over one
 * shared [LiveAgentSessionRegistry], attaches to a real tmux session whose
 * panes carry real `@tessera_agent_state`, and asserts on the rows a user would
 * see. Every earlier fixture in this tree hand-modelled Core's wire output, so a
 * disagreement between Kotlin's JSON and Swift's decoder was invisible to all of
 * them.
 *
 * The runner script owns credentials: it watches logcat for
 * `TESSERA_AGENT_RIG_PUBKEY`, authorizes that key on the host, and drops the go
 * file this test waits on. Nothing here can connect on its own.
 */
@RunWith(AndroidJUnit4::class)
class AgentCenterLiveInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @Test
    fun liveAgentPanesReachAgentCenterWithTitlesAndStatus(): Unit = runBlocking {
        val fixture = readFixture()
        assumeTrue("no rig fixture at $FIXTURE_PATH; the runner script pushes one", fixture != null)
        checkNotNull(fixture)

        val keystore = AndroidKeystoreCredentialStore()
        val credential = keystore.generateP256(alias = KEY_ALIAS, ownerAuthenticationRequired = false)
        val authorizedKey = "ecdsa-sha2-nistp256 " +
            Base64.encodeToString(credential.publicKeyBlob, Base64.NO_WRAP) + " tessera-agent-center-rig"
        log("TESSERA_AGENT_RIG_PUBKEY $authorizedKey")
        val authorized = awaitGoFile()
        check(authorized) { "runner never authorized the rig key within ${AUTHORIZE_TIMEOUT_MS}ms" }

        val verdicts = linkedMapOf<String, String>()
        var live: LiveAgentCenter? = null
        try {
            live = createLiveAgentCenter(fixture)
            live.connectAndAwait()
            verdicts["connected"] = "yes"

            val outcome = live.awaitThreads()
            verdicts["threads"] = outcome.threads.size.toString()
            verdicts["candidates"] = outcome.candidates.size.toString()
            verdicts["titled"] = outcome.titled.size.toString()
            verdicts["notice"] = if (outcome.notice == null) "none" else "present"
            verdicts["unavailableReason"] = if (outcome.unavailableReason == null) "none" else "present"
            outcome.threads.groupBy { it.providerID }.forEach { (providerID, rows) ->
                log(
                    "provider=$providerID threads=${rows.size} usableTitles=${rows.count(::hasUsableTitle)} " +
                        "states=${rows.map { it.status }.distinct().joinToString(",")} " +
                        "title=${tinyTitle(rows.firstOrNull()?.title)}",
                )
            }
            // Providers with no lifecycle hooks (opencode, pi) can only ever
            // reach the list as Tier-A candidates, so the count alone cannot
            // say whether they were detected or merely named "Agent".
            outcome.candidates.groupBy { it.providerID }.forEach { (providerID, candidates) ->
                log(
                    "candidateProvider=$providerID count=${candidates.size} " +
                        "states=${candidates.map { it.status }.distinct().joinToString(",")} " +
                        "title=${tinyTitle(candidates.firstOrNull()?.title)}",
                )
            }

            if (fixture.expectedCandidateProviders.isEmpty()) {
                val threadsByProvider = fixture.expectedThreadProviders.associateWith { providerID ->
                    outcome.threads.sortedWith(compareBy<AgentThreadRow> {
                        !it.title.startsWith("Tessera Agent Center verification")
                    }.thenBy { it.providerSessionID }).firstOrNull {
                        it.providerID == providerID && hasUsableTitle(it)
                    }
                }
                assertTrue(
                    "missing usable live rows for ${fixture.expectedThreadProviders}: " +
                        outcome.threads.joinToString { threadState(it) },
                    threadsByProvider.values.all { it != null },
                )
                val details = live.awaitProjectedDetails(threadsByProvider.mapValues { checkNotNull(it.value) })
                details.forEach { (providerID, detail) -> assertLiveProse(providerID, detail) }
                fixture.expectedHistoricalProviders.forEach { providerID ->
                    assertLiveProse(providerID, live.awaitHistoricalDetail(providerID))
                }
            } else {
                val seen = outcome.candidates.mapTo(mutableSetOf()) { it.providerID }
                assertTrue(
                    "expected Tier-A candidates for ${fixture.expectedCandidateProviders} but saw " +
                        "${outcome.candidates.map { "${it.providerID}/${it.provider}" }}",
                    seen.containsAll(fixture.expectedCandidateProviders),
                )
                // The row a reader sees carries the provider name, not the
                // generic "Agent" a platform reports for a detected pane.
                val unnamed = outcome.candidates.filter {
                    it.providerID in fixture.expectedCandidateProviders &&
                        it.provider.equals("Agent", ignoreCase = true)
                }
                assertTrue(
                    "a candidate row is still labelled the generic \"Agent\": " +
                        "${unnamed.map { it.providerID }}",
                    unnamed.isEmpty(),
                )
            }
            assertTrue(
                "the ABI refused a command: noticePresent=${outcome.notice != null}",
                outcome.notice?.contains("abi") != true,
            )
            if (fixture.verifyMultipleSessions) live.verifyMultipleSessions()
            if (fixture.readOnlyThread != null) {
                live.verifyReadOnlyLiveRefresh(fixture.readOnlyThread)
                verdicts["readOnlyLiveRefresh"] = "passed"
            }
            if (fixture.ownedPane != null) {
                live.verifyOwnedComposer()
                verdicts["ownedComposer"] = "passed"
            }
        } finally {
            log("TESSERA_AGENT_CENTER_RIG " + verdicts.entries.joinToString(" ") { "${it.key}=${it.value}" })
            live?.dumpDiagnostics()
            runCatching { live?.close() }.onFailure { log("close failed: $it") }
            runCatching { keystore.delete(KEY_ALIAS) }.onFailure { log("key delete failed: $it") }
        }
    }

    // ---- rig -------------------------------------------------------------------

    private data class Outcome(
        val threads: List<AgentThreadRow>,
        val titled: List<AgentThreadRow>,
        val candidates: List<AgentTerminalCandidate>,
        val notice: String?,
        val unavailableReason: String?,
    )

    private fun hasUsableTitle(row: AgentThreadRow): Boolean {
        val title = row.title.trim()
        return title.isNotEmpty() &&
            !title.equals("untitled", ignoreCase = true) &&
            !title.equals("agent", ignoreCase = true) &&
            !title.equals(row.provider, ignoreCase = true) &&
            row.titleProvenance != "placeholder" &&
            row.status.isNotBlank() && (row.status != "unavailable" || row.providerID in setOf("opencode", "pi", "kimi"))
    }

    private fun isLiveProse(block: AgentBlock): Boolean =
        block.kind == "text" && block.body.isNotBlank()

    private fun assertLiveProse(providerID: String, detail: AgentThreadDetail) {
        val prose = detail.live.filter { block ->
            block.role in setOf("user", "assistant") && isLiveProse(block)
        }
        assertTrue("provider=$providerID has no user live prose", prose.any { it.role == "user" })
        assertTrue("provider=$providerID has no assistant live prose", prose.any { it.role == "assistant" })
        assertTrue(
            "provider=$providerID leaked an encoded block wrapper into live prose",
            prose.none { block ->
                val objectBody = runCatching { org.json.JSONObject(block.body) }.getOrNull()
                objectBody?.has("_0") == true || objectBody?.optJSONObject("text")?.has("_0") == true
            },
        )
        assertTrue(
            "provider=$providerID leaked internal context into live prose",
            prose.none {
                // A real conversation can discuss these strings (including
                // this parsing bug). Reject injected envelopes, not mentions.
                val body = it.body.trimStart()
                body.startsWith("# AGENTS.md instructions for ") ||
                    body.startsWith("<environment_context>") ||
                    body.startsWith("<permissions instructions>")
            },
        )
    }

    private fun tinyTitle(value: String?): String = value.orEmpty()
        .replace(Regex("\\s+"), " ")
        .take(48)
        .ifBlank { "none" }

    private fun threadState(row: AgentThreadRow): String =
        "${row.providerID}:${row.status}:${row.titleProvenance}:${tinyTitle(row.title)}"

    private inner class LiveAgentCenter(
        val controller: SshSessionController,
        private val surface: TermuxTerminalSurface,
        private val presenter: AgentCenterPresenter,
        private val integration: AgentSessionIntegrationCoordinator,
        private val coordinator: AndroidAgentSessionCoordinator,
        private val agentSessions: LiveAgentSessionRegistry,
        private val diagnostics: DiagnosticLogStore,
        private val scope: CoroutineScope,
        private val authentication: Job,
        private val expectedThreadProviders: Set<String>,
        private val expectedCandidateProviders: Set<String>,
        private val fixture: Fixture,
        private val context: Context,
        private val identity: SavedIdentity,
        private val primaryHostID: String,
    ) {
        private var secondary: AdditionalSession? = null
        private val diagnosticsPrefix = diagnostics.read().length

        suspend fun connectAndAwait() {
            connectAndDeclare(controller, "primary")
            // The user connected and saw this terminal before opening Agent
            // Center: report the show edge the screen reports (§6.9 R1).
            // Attach alone only reads authority, and Agent Center's
            // mutations are refused while a peer holds the grid (D7).
            onMain { controller.shown(SharedTmuxAuthorityShowSource.SHOW) }
            withTimeoutOrNull(SHOW_DECISION_TIMEOUT_MS) {
                while (controller.tmuxAuthorityPresentation.value is TmuxAuthorityPresentation.Resuming) delay(POLL_MS)
            }
            log("primary show decided: authority=${controller.tmuxAuthority.value} presentation=${controller.tmuxAuthorityPresentation.value}")
        }

        suspend fun verifyOwnedComposer() {
            val pane = checkNotNull(fixture.ownedPane)
            val marker = checkNotNull(fixture.ownedMarker)
            check(pane.matches(Regex("%[0-9]+")) && marker.startsWith("tessera-approved-"))
            var owned: AgentThreadDetail? = null
            val ready = withTimeoutOrNull(THREAD_TIMEOUT_MS) {
                while (true) {
                    val state = presenter.state.value
                    owned = state.projectedDetails.values.firstOrNull {
                        (it.binding?.fields?.get("paneID") as? com.bambouville.tessera.core.bridge.SharedAgentValue.StringValue)?.value?.removePrefix("%") == pane.removePrefix("%") &&
                            it.live.any { block -> block.role == "user" && marker in block.body }
                    }
                    if (owned?.row?.actionAvailable == true && owned?.toolRuns?.isNotEmpty() == true) return@withTimeoutOrNull true
                    state.projectedDetails.values.firstOrNull {
                        (it.binding?.fields?.get("paneID") as? com.bambouville.tessera.core.bridge.SharedAgentValue.StringValue)?.value == pane && it.hasMore
                    }?.takeIf { candidate -> candidate.live.none { it.role == "user" && marker in it.body } }
                        ?.let { candidate -> onMain { presenter.loadMore(candidate.row.key) } }
                    state.threads.filter { it.providerID in expectedThreadProviders }.forEach { row -> onMain { presenter.select(row.key) } }
                    delay(1_000)
                }
                @Suppress("UNREACHABLE_CODE") false
            }
            check(ready == true) { "owned pane never produced proven actionable tool groups" }
            val detail = checkNotNull(owned)
            // The runner independently checked the pane's @tessera_verify_owner.
            // Requiring its unique opening prompt prevents selecting a user's thread.
            var showingTerminal by mutableStateOf(false)
            compose.setContent { TesseraTheme {
                if (showingTerminal) AndroidView(
                    factory = { GeometryNeutralTerminalViewport(it, surface) },
                    onRelease = { it.releaseTerminal() },
                    modifier = Modifier.fillMaxSize().safeDrawingPadding().testTag("rig-existing-terminal"),
                ) else AgentCenterScreen(presenter, onOpenTerminal = { selected ->
                    scope.launch {
                        val opened = navigateToExistingAgentTerminal(
                            isCurrentCarrier = { selected.targetsLiveSession(primaryHostID, controller.agentEndpointBinding.value?.key?.liveSessionID).also { log("ownedTerminalNavigation=currentCarrier=$it selected=${selected.binding} current=${controller.agentEndpointBinding.value}") } },
                            focus = { presenter.focusExact(selected).also { log("ownedTerminalNavigation=focus=$it") } },
                            reveal = {
                                controller.setTmuxScreenRenderPresentation(TmuxScreenRenderPresentation.Single)
                                controller.declareTmuxRenderSurfaces(tmuxScreenRenderSurfaceDeclarations(
                                    presentation = TmuxScreenRenderPresentation.Single,
                                    activeWindowId = controller.tmuxSnapshot.value?.activeWindowId,
                                    activePaneId = pane.removePrefix("%").toInt(),
                                    activePaneIds = setOf(pane.removePrefix("%").toInt()),
                                    mountedGridPaneIds = emptySet(),
                                    mountedOverlayPaneIds = emptySet(),
                                ))
                                controller.setPresentationActive(true)
                                // Agent Center's "open terminal" is an explicit
                                // open (§6.9), as MainActivity reports it.
                                controller.shown(SharedTmuxAuthorityShowSource.EXPLICIT_OPEN)
                                showingTerminal = true
                            },
                        )
                        if (!opened) presenter.reportTerminalUnavailable()
                    }
                }, modifier = Modifier.safeDrawingPadding().imePadding())
            } }
            compose.onNodeWithText(detail.row.title, substring = false).performScrollTo().performClick()
            captureOwnedEvidence("before-send", pane)
            val toolGroup = "agent-tool-run-${detail.toolRuns.first().key}"
            compose.onNodeWithTag("agent-transcript-list").performScrollToNode(hasTestTag(toolGroup))
            compose.onNodeWithTag(toolGroup).performScrollTo()
            captureOwnedScreen("collapsed")
            compose.onNodeWithTag(toolGroup).performClick().assertIsEnabled()
            captureOwnedScreen("expanded")
            compose.onNodeWithTag(toolGroup).performScrollTo().performClick()
            if (fixture.verifyWorkingQueue) {
                val busy = "Run the single shell command sleep 45, then reply exactly TESSERA_BUSY_DONE. Do not modify files."
                compose.onNodeWithTag("agent-composer").performTextReplacement(busy)
                compose.onNodeWithTag("agent-send").performClick()
                check(withTimeoutOrNull(30_000) {
                    while (true) {
                        check(presenter.state.value.notice == null) { "busy setup failed: ${presenter.state.value.notice}" }
                        if (presenter.state.value.projectedDetails[detail.row.key]?.row?.status == "working") return@withTimeoutOrNull true
                        delay(100)
                    }
                    @Suppress("UNREACHABLE_CODE") false
                } == true) { "owned agent never became working" }
                log("ownedComposer=working-before-queue")
            }
            val reply = "TESSERA_ANDROID_SEND_OK_${System.currentTimeMillis()}"
            val messageBody = if (fixture.verifyMultiline)
                "Reply exactly $reply.\n\nDo not run tools or modify files.\n"
            else if (fixture.verifyWorkingQueue)
                "Testing sending a longer message from Agent Center while you are working. When you receive this message reply exactly $reply. Do not run tools or modify files."
            else "Reply exactly $reply. Do not run tools or modify files."
            val message = if (fixture.verifyComposerMargins) "  $messageBody  " else messageBody
            compose.onNodeWithTag("agent-composer").performTextReplacement(message)
            compose.onNodeWithTag("agent-composer").assertIsEnabled().assertTextContains(message)
            compose.onNodeWithTag("agent-send").assertIsEnabled()
            log("ownedComposer=before-send selected=${presenter.state.value.selectedThreadKey} expected=${detail.row.key}")
            val sendStartedNanos = System.nanoTime()
            compose.onNodeWithTag("agent-send").performClick()
            log("ownedComposer=after-send notice=${presenter.state.value.notice}")
            check(withTimeoutOrNull(5_000) {
                while (presenter.state.value.projectedDetails[detail.row.key]?.outgoingMessages?.none { it.text == message } != false) delay(20)
                true
            } == true) { "accepted send did not immediately publish its pending message" }
            val deliveryTiming = scope.async {
                withTimeout(10_000) {
                    while (presenter.state.value.projectedDetails[detail.row.key]?.outgoingMessages?.any {
                            it.text == message && it.status in setOf("sending", "queueing")
                        } == true) delay(10)
                    val elapsed = (System.nanoTime() - sendStartedNanos) / 1_000_000
                    log("ownedDeliveryMs=$elapsed notice=${presenter.state.value.notice}")
                    elapsed
                }
            }
            compose.waitForIdle()
            compose.onNodeWithTag("agent-dictation").assertIsDisplayed()
            captureOwnedScreen("pending")
            // Native IME insets continue animating after Compose becomes idle.
            // Require the bubble without driving a scroll or altering the UI.
            val bubbleVisible = runCatching { compose.waitUntil(3_000) {
                // A fast real receipt may replace pending (and normalize outer
                // newlines) before the IME animation ends. Either visible state
                // is valid, but a vanished/offscreen message is not.
                runCatching { compose.onNodeWithText(message).assertIsDisplayed() }.isSuccess ||
                    (presenter.state.value.projectedDetails[detail.row.key]?.outgoingMessages?.none { it.text == message } == true &&
                        // Real user messages render Markdown paragraphs as
                        // separate nodes; match the unique first paragraph.
                        runCatching { compose.onNodeWithText("Reply exactly $reply.", substring = true).assertIsDisplayed() }.isSuccess)
            } }.isSuccess
            captureOwnedScreen("pending-settled")
            check(bubbleVisible) { "neither pending nor its actual receipt became visible after keyboard layout" }
            check(deliveryTiming.await() < 2_000) { "local send delivery exceeded two seconds" }
            log("ownedComposer=pending-visible")
            val replied = withTimeoutOrNull(THREAD_TIMEOUT_MS) {
                while (true) {
                    val latest = presenter.state.value.projectedDetails[detail.row.key]
                    if (presenter.state.value.notice != null) {
                        captureOwnedScreen("failure")
                        captureOwnedEvidence("failure", pane)
                        error("owned composer failed: ${presenter.state.value.notice}")
                    }
                    if (latest?.live?.any { it.role == "assistant" && it.body.trim() == reply } == true) {
                        check(latest.live.any { it.role == "user" && it.body.trim() == message.trim() }) {
                            "reply appeared without the exact submitted user message in the conversation"
                        }
                        check(latest.outgoingMessages.none { it.text == message }) { "actual transcript receipt did not replace pending bubble" }
                        return@withTimeoutOrNull true
                    }
                    delay(500)
                }
                @Suppress("UNREACHABLE_CODE") false
            }
            check(replied == true) { "owned composer did not receive an actual reply; notice=${presenter.state.value.notice}" }
            if (fixture.verifyWorkingQueue) {
                val messages = checkNotNull(presenter.state.value.projectedDetails[detail.row.key]).live
                val completedBusy = messages.indexOfLast { it.role == "assistant" && it.body.trim() == "TESSERA_BUSY_DONE" }
                val completedQueue = messages.indexOfLast { it.role == "assistant" && it.body.trim() == reply }
                check(completedBusy >= 0 && completedQueue > completedBusy) { "queued message interrupted or bypassed the active turn" }
            }
            check(presenter.state.value.notice?.contains("proof", ignoreCase = true) != true)
            compose.onNodeWithTag("agent-transcript-list").performScrollToNode(hasText(reply))
            compose.onNodeWithText(reply).assertIsDisplayed()
            captureOwnedScreen("reply")
            log("ownedComposer=passed pane=$pane toolRuns=${detail.toolRuns.size} reply=$reply")
            fixture.ownedOtherWindow?.let { otherWindow ->
                onMain { controller.selectTmuxWindow(otherWindow.removePrefix("@").toInt()) }
                check(withTimeoutOrNull(10_000) {
                    while (controller.tmuxSnapshot.value?.activeWindowId != otherWindow.removePrefix("@").toInt()) delay(50)
                    true
                } == true) { "owned alternate window was not focused" }
                // Let endpoint inventory observe the focus change. Previously
                // it retired every thread on this still-live carrier, so only
                // an immediate click could win the race and open its terminal.
                delay(2_000)
                check(presenter.state.value.projectedDetails[detail.row.key] != null) {
                    "switching windows retired a thread on the same live carrier"
                }
                compose.onNodeWithContentDescription("open terminal").performClick()
                check(withTimeoutOrNull(10_000) {
                    while (!showingTerminal || controller.tmuxSnapshot.value?.activePaneId != pane.removePrefix("%").toInt()) delay(50)
                    true
                } == true) { "terminal icon did not focus and reveal the exact owned pane; revealed=$showingTerminal active=${controller.tmuxSnapshot.value?.activePaneId} notice=${presenter.state.value.notice}" }
                compose.onNodeWithTag("rig-existing-terminal").assertIsDisplayed()
                check(withTimeoutOrNull(10_000) {
                    while (onMain { surface.snapshotText()?.visibleText?.contains(reply) } != true) delay(50)
                    true
                } == true) { "focused terminal did not render the actual agent reply" }
                captureOwnedScreen("terminal")
                log("ownedTerminalNavigation=passed from=$otherWindow to=$pane")
            }
        }

        /** Watches the user's explicitly scoped running thread, never writes
         * terminal input or changes its tmux window selection. */
        suspend fun verifyReadOnlyLiveRefresh(providerSessionID: String) {
            val row = checkNotNull(presenter.state.value.threads.firstOrNull { it.providerSessionID == providerSessionID })
            compose.setContent { TesseraTheme { AgentCenterScreen(presenter, onOpenTerminal = {}, modifier = Modifier.safeDrawingPadding()) } }
            compose.onNodeWithText(row.title, substring = false).performScrollTo().performClick()
            check(withTimeoutOrNull(10_000) {
                while (presenter.state.value.projectedDetails[row.key]?.live.isNullOrEmpty()) delay(100)
                true
            } == true)
            val baseline = presenter.state.value.projectedDetails[row.key]?.live?.takeLast(3)?.map { it.body }
            log("readOnlyLiveRefresh=watching thread=$providerSessionID")
            var refreshed = false
            onMain { controller.setPresentationActive(false) }
            repeat(120) {
                delay(500)
                val state = presenter.state.value
                if (state.notice != null) {
                    captureOwnedScreen("failure")
                    error("read-only live session surfaced Core failure: ${state.notice}")
                }
                val current = state.projectedDetails[row.key]?.live?.takeLast(3)?.map { it.body }
                if (current != null && current != baseline) refreshed = true
            }
            captureOwnedScreen(if (refreshed) "reply" else "failure")
            check(refreshed) { "active transcript did not refresh during 60 seconds with its terminal surface inactive" }
            log("readOnlyLiveRefresh=passed thread=$providerSessionID")
        }

        private suspend fun captureOwnedEvidence(name: String, pane: String) {
            check(pane == fixture.ownedPane) { "refusing capture outside the owned pane" }
            val detail = checkNotNull(presenter.state.value.projectedDetails[presenter.state.value.selectedThreadKey])
            check((detail.binding?.fields?.get("paneID") as? com.bambouville.tessera.core.bridge.SharedAgentValue.StringValue)?.value == pane)
            val window = (detail.binding?.fields?.get("windowID") as? com.bambouville.tessera.core.bridge.SharedAgentValue.StringValue)?.value
            val binding = checkNotNull(controller.agentEndpointBinding.value).copy(paneID = pane, windowID = window)
            val endpoint = checkNotNull(coordinator.directory.resolve(binding.key))
            check(endpoint.isCurrentRoute(binding)) { "owned evidence route is stale" }
            val observed = (endpoint.inspect(binding) as? com.bambouville.tessera.agent.platform.AgentEndpointResult.Success)?.value ?: return
            val capturedRows = observed.visibleTail.decodeToString().split('\n').size
            if (name == "before-send") {
                check(capturedRows >= PHONE_ROWS) { "capture lost physical rows: $capturedRows/$PHONE_ROWS" }
                check(observed.cursorRow != null && observed.cursorRow!! in 0 until capturedRows) { "cursor row missing from capture" }
                log("ownedCaptureRows=$capturedRows cursorRow=${observed.cursorRow} cursorVisible=${observed.cursorVisible}")
            }
            val output = org.json.JSONObject().put("visibleText", observed.visibleTail.decodeToString())
                .put("cursorLine", observed.currentCursorLine).put("cursorRow", observed.cursorRow).put("cursorVisible", observed.cursorVisible).put("authoritative", observed.authoritative)
            java.io.File("/sdcard/Download/agent-center-rig-$name.json").writeText(output.toString())
        }

        private fun captureOwnedScreen(name: String) {
            compose.waitForIdle()
            val screenshot = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
            java.io.FileOutputStream("/sdcard/Download/agent-center-rig-$name.png").use {
                check(screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
            }
            screenshot.recycle()
        }

        private suspend fun connectAndDeclare(target: SshSessionController, label: String) {
            onMain { target.connect() }
            val connected = withTimeoutOrNull(CONNECT_TIMEOUT_MS) {
                while (true) {
                    when (val state = target.state.value) {
                        SshSessionUiState.Connected -> return@withTimeoutOrNull true
                        is SshSessionUiState.Failed -> error("$label controller failed: ${state.message}")
                        else -> Unit
                    }
                    delay(POLL_MS)
                }
                @Suppress("UNREACHABLE_CODE")
                false
            }
            check(connected == true) { "$label controller did not connect within ${CONNECT_TIMEOUT_MS}ms" }
            onMain { declareSurfaces(target) }
        }

        /**
         * Waits for rows that are actually usable, not merely present. A thread
         * appears as soon as one lifecycle frame is admitted, but its title,
         * status and model only arrive once a transcript projection applies —
         * which is exactly the step that used to be refused at the ABI. Settling
         * for a non-empty list would have graded the reported bug as a pass.
         */
        suspend fun awaitThreads(): Outcome {
            var last = snapshot()
            withTimeoutOrNull(THREAD_TIMEOUT_MS) {
                // Stopping at the first titled row graded a host running two
                // agents as a pass while listing only one of them: whichever
                // pane won the race ended the wait, and the other was still
                // arriving. A pane announces `@tessera_agent_state` once per
                // subscribe, and an idle agent's frame can trail a working
                // one's by a second, so settle on a thread set that has stopped
                // changing rather than on the first usable row.
                var stableFor = 0
                var previousKeys = emptySet<String>()
                while (true) {
                    last = snapshot()
                    // Candidates settle on their own schedule: a Tier-A row
                    // needs a process discovery sweep, which lands after the
                    // first lifecycle frames. Grading on thread keys alone
                    // ended the wait before opencode or pi had been seen.
                    val keys = last.threads.mapTo(mutableSetOf()) { it.key } +
                        last.candidates.mapTo(mutableSetOf()) { "candidate:${it.key}" }
                    stableFor = if (keys == previousKeys) stableFor + 1 else 0
                    previousKeys = keys
                    val ready = if (expectedCandidateProviders.isEmpty()) {
                        last.threads.filter(::hasUsableTitle).mapTo(mutableSetOf()) { it.providerID }
                            .containsAll(expectedThreadProviders)
                    } else {
                        last.candidates.mapTo(mutableSetOf()) { it.providerID }
                            .containsAll(expectedCandidateProviders)
                    }
                    if (ready && stableFor >= SETTLE_POLLS) return@withTimeoutOrNull true
                    delay(POLL_MS)
                }
                @Suppress("UNREACHABLE_CODE")
                false
            }
            return last
        }

        suspend fun awaitProjectedDetails(rows: Map<String, AgentThreadRow>): Map<String, AgentThreadDetail> {
            val details = linkedMapOf<String, AgentThreadDetail>()
            rows.forEach { (providerID, row) ->
                onMain { presenter.select(row.key) }
                val detail = withTimeoutOrNull(THREAD_TIMEOUT_MS) {
                    while (true) {
                        val current = presenter.state.value
                        val projected = current.projectedDetails[row.key]
                        if (projected != null) {
                            // A long tool-only tail need not contain its opening
                            // human prompt. Exercise paging before grading it.
                            if (projected.hasMore && projected.live.none { it.role == "user" && isLiveProse(it) }) {
                                onMain { presenter.loadMore(row.key) }
                                delay(2_000)
                                continue
                            }
                            return@withTimeoutOrNull projected
                        }
                        delay(POLL_MS)
                    }
                    @Suppress("UNREACHABLE_CODE")
                    null
                }
                checkNotNull(detail) { "provider=$providerID never produced selected projected details" }
                log(
                    "provider=$providerID detailLive=${detail.live.size} " +
                        "assistant=${detail.live.count { it.role == "assistant" && isLiveProse(it) }} " +
                        "user=${detail.live.count { it.role == "user" && isLiveProse(it) }}",
                )
                details[providerID] = detail
            }
            return details
        }

        suspend fun awaitHistoricalDetail(providerID: String): AgentThreadDetail {
            // Completed print-mode verification sessions belong in transcript
            // search, not in the list of currently running agents.
            val query = "Tessera ${if (providerID == "pi") "Pi" else "OpenCode"} verification complete"
            onMain { presenter.search(query) }
            val result = withTimeoutOrNull(THREAD_TIMEOUT_MS) {
                while (true) {
                    delay(2_000)
                    val found = presenter.state.value.searchResults.firstOrNull { ":$providerID:" in it.threadKey }
                    if (found != null) {
                        onMain { presenter.select(found.threadKey) }
                        delay(2_000)
                        val current = presenter.state.value
                        val detail = current.projectedDetails[found.threadKey]
                        if (current.selectedThreadKey == found.threadKey && detail != null &&
                            detail.live.any { it.role == "assistant" && isLiveProse(it) }) return@withTimeoutOrNull detail
                    }
                }
                @Suppress("UNREACHABLE_CODE")
                null
            }
            if (result == null) {
                val state = presenter.state.value
                log("historyFailure provider=$providerID results=${state.searchResults.size} selected=${state.selectedThreadKey?.split(':')?.getOrNull(1)} detailProviders=${state.projectedDetails.values.map { it.row.providerID }.distinct()}")
            }
            checkNotNull(result) { "provider=$providerID historical search did not open readable conversation" }
            log("provider=$providerID historicalSearch=passed live=${result.live.size}")
            return result
        }

        private fun snapshot(): Outcome {
            val state = presenter.state.value
            return Outcome(
                threads = state.threads,
                titled = state.threads.filter(::hasUsableTitle),
                candidates = state.candidates,
                notice = state.notice,
                unavailableReason = state.unavailableReason,
            )
        }

        private fun declareSurfaces(target: SshSessionController) {
            val snapshot = target.tmuxSnapshot.value
            target.setTmuxScreenRenderPresentation(TmuxScreenRenderPresentation.Single)
            target.declareTmuxRenderSurfaces(
                tmuxScreenRenderSurfaceDeclarations(
                    presentation = TmuxScreenRenderPresentation.Single,
                    activeWindowId = snapshot?.activeWindowId,
                    activePaneId = snapshot?.activePaneId,
                    activePaneIds = snapshot?.activeWindow?.panes?.mapTo(mutableSetOf()) { it.id } ?: emptySet(),
                    mountedGridPaneIds = emptySet(),
                    mountedOverlayPaneIds = emptySet(),
                ),
            )
        }

        suspend fun verifyMultipleSessions() {
            check(secondary == null) { "secondary session leaked from an earlier rig phase" }
            val secondaryHost = SavedHost(
                id = UUID.randomUUID().toString(),
                displayName = "agent center rig secondary",
                hostname = fixture.stableHost,
                port = fixture.port,
                username = fixture.user,
                jumpHostId = null,
                identityId = identity.id,
                transportKind = if (fixture.transportKind == TransportKinds.SSH) TransportKinds.MOSH else TransportKinds.SSH,
                tmuxMode = TmuxModes.PINNED,
                tmuxTarget = fixture.session,
            )
            val secondaryController = SshSessionController(
                host = secondaryHost,
                hosts = RigHostRepository(secondaryHost),
                identities = RigIdentityRepository(identity),
                knownHosts = RigKnownHostsRepository(),
                restore = RigRestoreRepository(),
                credentialStore = AndroidKeystoreCredentialStore(),
                diagnostics = diagnostics,
                scope = scope,
                agentSessions = agentSessions,
                initialTmuxGridPresentation = SharedTmuxGridPresentation.SINGLE_PANE,
                tmuxDeviceIdentity = TmuxDeviceIdentity("android-agentcenter-secondary-${UUID.randomUUID()}", "Android-Rig"),
                scrollbackLines = 2_000,
            )
            lateinit var secondarySurface: TermuxTerminalSurface
            onMain {
                secondarySurface = TermuxTerminalSurface(context, transcriptRows = 4_000)
                secondarySurface.resize(PHONE_COLUMNS, PHONE_ROWS)
                secondaryController.attachTerminal(secondarySurface)
                secondaryController.setPresentationActive(true)
                secondaryController.updateTmuxViewport(PHONE_COLUMNS, PHONE_ROWS)
                // Deliberately no show edge: this session is never displayed
                // (§6.9: non-presented sessions never show). A show would
                // take the shared grid from the primary, which would then
                // stay yielded after this one closes (departure moves nothing).
            }
            val secondaryAuthentication = scope.launch {
                secondaryController.state.collect { state ->
                    if (state is SshSessionUiState.AwaitingHostKey) secondaryController.decideHostKey(true)
                }
            }
            val added = AdditionalSession(secondaryController, secondarySurface, secondaryAuthentication, secondaryHost.id)
            secondary = added
            try {
                connectAndDeclare(added.controller, "secondary")
                awaitProvidersOnHosts(setOf(primaryHostID, added.hostID), fixture.expectedThreadProviders)
                log("multipleSessions=passed hosts=2 transports=ssh,mosh providers=${fixture.expectedThreadProviders.joinToString()}")
                closeAdditional(added)
                secondary = null
                awaitProvidersOnHosts(setOf(primaryHostID), fixture.expectedThreadProviders, removedHostID = added.hostID)
                log("multipleSessionsTeardown=passed remainingHosts=1")
            } finally {
                secondary?.let { closeAdditional(it) }
                secondary = null
            }
        }

        private suspend fun awaitProvidersOnHosts(hostIDs: Set<String>, providers: Set<String>, removedHostID: String? = null) {
            val available = withTimeoutOrNull(THREAD_TIMEOUT_MS) {
                while (true) {
                    val grouped = presenter.state.value.threads.filter(::hasUsableTitle).groupBy { it.hostID.lowercase(java.util.Locale.ROOT) }
                    if (hostIDs.all { hostID ->
                            grouped[hostID.lowercase(java.util.Locale.ROOT)].orEmpty().mapTo(mutableSetOf()) { it.providerID }.containsAll(providers)
                        } && (removedHostID == null || removedHostID.lowercase(java.util.Locale.ROOT) !in grouped)
                    ) return@withTimeoutOrNull true
                    delay(POLL_MS)
                }
                @Suppress("UNREACHABLE_CODE")
                false
            }
            check(available == true) {
                "missing $providers on hosts=$hostIDs; rows=" +
                    presenter.state.value.threads.joinToString { "${it.hostID}:${it.providerID}:${it.providerSessionID}" }
            }
        }

        private suspend fun closeAdditional(value: AdditionalSession) {
            onMain { value.controller.close(); value.surface.close() }
            value.authentication.cancel()
        }

        fun dumpDiagnostics() {
            val count = diagnostics.read().drop(diagnosticsPrefix).lineSequence()
                .filter { it.isNotBlank() }
                .count()
            log("diagnostics=$count")
            diagnostics.read().drop(diagnosticsPrefix).lineSequence()
                .filter { " agent_" in it }
                .toList().takeLast(1_000).forEach(::log)
        }

        suspend fun close() {
            secondary?.let { closeAdditional(it) }
            secondary = null
            onMain {
                presenter.close()
                integration.close()
                coordinator.close()
                controller.close()
                surface.close()
            }
            agentSessions.close()
            authentication.cancel()
            scope.cancel()
        }

        suspend fun <T> onMain(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }

    }

    private data class AdditionalSession(
        val controller: SshSessionController,
        val surface: TermuxTerminalSurface,
        val authentication: Job,
        val hostID: String,
    )

    private fun createLiveAgentCenter(fixture: Fixture): LiveAgentCenter {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val identityId = UUID.randomUUID().toString()
        val host = SavedHost(
            id = UUID.randomUUID().toString(),
            displayName = "agent center rig",
            hostname = fixture.stableHost,
            port = fixture.port,
            username = fixture.user,
            jumpHostId = null,
            identityId = identityId,
            transportKind = fixture.transportKind,
            tmuxMode = TmuxModes.PINNED,
            tmuxTarget = fixture.session,
        )
        val identity = SavedIdentity(
            id = identityId,
            displayName = "agent center rig key",
            credentialKind = CredentialKinds.ANDROID_KEYSTORE_P256,
            credentialReference = KEY_ALIAS,
        )
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val diagnostics = DiagnosticLogStore(context)
        diagnostics.clear()
        val agentSessions = LiveAgentSessionRegistry()
        val coordinator = AndroidAgentSessionCoordinator(agentSessions)
        val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
        val presenter = AgentCenterPresenter(
            coordinator = coordinator,
            metadata = AndroidAgentMetadataRepository(context),
            viewPreferences = AndroidAgentCenterViewPreferences(context),
            scope = scope,
            sessionIntegration = integration,
            diagnostics = diagnostics::record,
        )
        val controller = SshSessionController(
            host = host,
            hosts = RigHostRepository(host),
            identities = RigIdentityRepository(identity),
            knownHosts = RigKnownHostsRepository(),
            restore = RigRestoreRepository(),
            credentialStore = AndroidKeystoreCredentialStore(),
            diagnostics = diagnostics,
            scope = scope,
            agentSessions = agentSessions,
            initialTmuxGridPresentation = SharedTmuxGridPresentation.SINGLE_PANE,
            tmuxDeviceIdentity = TmuxDeviceIdentity("android-agentcenter-${UUID.randomUUID()}", "Android-Rig"),
            scrollbackLines = 2_000,
        )
        lateinit var surface: TermuxTerminalSurface
        runOnMain {
            surface = TermuxTerminalSurface(context, transcriptRows = 4_000)
            surface.resize(PHONE_COLUMNS, PHONE_ROWS)
            controller.attachTerminal(surface)
            controller.setPresentationActive(true)
            controller.updateTmuxViewport(PHONE_COLUMNS, PHONE_ROWS)
            // `activate()` alone is a no-op: the presenter stays gated until
            // MainActivity applies the Agent Center preference. Calling only
            // `activate()` — as AgentSessionViewModel's init does — leaves the
            // directory unobserved, so no lifecycle frame is ever collected.
            integration.setEnabled(true)
            presenter.setEnabled(true)
        }
        val authentication = scope.launch {
            controller.state.collect { state ->
                when (state) {
                    is SshSessionUiState.AwaitingHostKey -> controller.decideHostKey(true)
                    else -> Unit
                }
            }
        }
        return LiveAgentCenter(
            controller, surface, presenter, integration, coordinator,
            agentSessions, diagnostics, scope, authentication,
            fixture.expectedThreadProviders,
            fixture.expectedCandidateProviders,
            fixture,
            context,
            identity,
            host.id,
        )
    }

    // ---- runner handshake ------------------------------------------------------

    private suspend fun awaitGoFile(): Boolean = withTimeoutOrNull(AUTHORIZE_TIMEOUT_MS) {
        while (true) {
            if (shell("ls $GO_PATH").contains(GO_PATH)) return@withTimeoutOrNull true
            delay(500)
        }
        @Suppress("UNREACHABLE_CODE")
        false
    } == true

    private fun shell(command: String): String {
        val descriptor = InstrumentationRegistry.getInstrumentation().uiAutomation
            .executeShellCommand(command)
        return ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { it.readBytes().decodeToString() }
    }

    private fun readFixture(): Fixture? {
        val properties = Properties().apply {
            runCatching { load(shell("cat $FIXTURE_PATH").byteInputStream()) }
        }
        if (properties.getProperty("stableHost").isNullOrBlank()) return null
        fun value(name: String): String = properties.getProperty(name)?.takeIf { it.isNotBlank() }
            ?: error("rig fixture is missing $name")
        return Fixture(
            stableHost = value("stableHost"),
            port = value("port").toInt(),
            user = value("user"),
            session = value("rigSession"),
            expectedThreadProviders = properties.getProperty("expectedThreadProviders")
                .orEmpty().ifBlank { "claude,codex" }.split(',').map(String::trim)
                .filter(String::isNotEmpty).map { it.lowercase() }.toSet(),
            expectedHistoricalProviders = properties.getProperty("expectedHistoricalProviders")
                .orEmpty().split(',').map(String::trim).filter(String::isNotEmpty).toSet(),
            expectedCandidateProviders = (properties.getProperty("expectedCandidateProviders")
                ?: properties.getProperty("expectCandidateProviders"))
                .orEmpty().split(',').map(String::trim).filter(String::isNotEmpty).map { it.lowercase() }.toSet(),
            transportKind = when (properties.getProperty("transportKind").orEmpty().trim().lowercase()) {
                "", "ssh" -> TransportKinds.SSH
                "mosh" -> TransportKinds.MOSH
                else -> error("rig fixture transportKind must be ssh or mosh")
            },
            verifyMultipleSessions = properties.getProperty("verifyMultipleSessions")?.trim()?.equals("true", ignoreCase = true) == true,
            ownedPane = properties.getProperty("ownedPane")?.takeIf { it.isNotBlank() },
            ownedMarker = properties.getProperty("ownedMarker")?.takeIf { it.isNotBlank() },
            verifyWorkingQueue = properties.getProperty("verifyWorkingQueue") == "true",
            ownedOtherWindow = properties.getProperty("ownedOtherWindow")?.takeIf { it.matches(Regex("@[0-9]+")) },
            readOnlyThread = properties.getProperty("readOnlyThread")?.takeIf(String::isNotBlank),
            verifyComposerMargins = properties.getProperty("verifyComposerMargins") == "true",
            verifyMultiline = properties.getProperty("verifyMultiline") == "true",
        )
    }

    private data class Fixture(
        val stableHost: String,
        val port: Int,
        val user: String,
        val session: String,
        /**
         * Provider ids that must show up as Tier-A candidates. opencode and pi
         * emit no lifecycle frames at all, so a run that only counts threads
         * cannot tell "detected and named" from "never seen".
         */
        val expectedCandidateProviders: Set<String> = emptySet(),
        val expectedThreadProviders: Set<String> = setOf("claude", "codex"),
        val expectedHistoricalProviders: Set<String> = emptySet(),
        val transportKind: String = TransportKinds.SSH,
        val verifyMultipleSessions: Boolean = false,
        val ownedPane: String? = null,
        val ownedMarker: String? = null,
        val verifyWorkingQueue: Boolean = false,
        val ownedOtherWindow: String? = null,
        val readOnlyThread: String? = null,
        val verifyComposerMargins: Boolean = false,
        val verifyMultiline: Boolean = false,
    )

    private class RigHostRepository(private val host: SavedHost) : HostRepository {
        private val hosts = MutableStateFlow(listOf(host))
        override val loadedHosts: StateFlow<List<SavedHost>?> = hosts
        override fun observeHosts(): Flow<List<SavedHost>> = hosts
        override suspend fun host(id: String): SavedHost? = hosts.value.firstOrNull { it.id == id }
        override suspend fun save(draft: HostDraft): SavedHost = error("rig must not persist hosts")
        override suspend fun delete(id: String): Boolean = false
        override suspend fun resolveRoute(hostId: String): List<SavedHost> =
            listOf(host).takeIf { host.id == hostId } ?: error("rig route host missing")
    }

    private class RigIdentityRepository(private val identity: SavedIdentity) : IdentityRepository {
        private val identities = MutableStateFlow(listOf(identity))
        override val loadedIdentities: StateFlow<List<SavedIdentity>?> = identities
        override fun observeIdentities(): Flow<List<SavedIdentity>> = identities
        override suspend fun identity(id: String): SavedIdentity? = identity.takeIf { it.id == id }
        override suspend fun save(
            displayName: String,
            credentialKind: String,
            credentialReference: String,
            id: String?,
        ): SavedIdentity = error("rig must not persist identities")
        override suspend fun delete(id: String): Boolean = false
    }

    private class RigKnownHostsRepository : KnownHostsRepository {
        private val known = MutableStateFlow<List<SavedKnownHost>>(emptyList())
        private val trusted = mutableMapOf<String, Pair<String, ByteArray>>()
        override val loadedKnownHosts: StateFlow<List<SavedKnownHost>?> = known
        override fun observeKnownHosts(): Flow<List<SavedKnownHost>> = known
        override suspend fun evaluate(
            hostname: String,
            port: Int,
            algorithm: String,
            canonicalKeyBlob: ByteArray,
        ): HostTrustEvaluation {
            val entry = trusted["$hostname:$port"] ?: return HostTrustEvaluation.Unknown
            return if (entry.first == algorithm && entry.second.contentEquals(canonicalKeyBlob)) {
                HostTrustEvaluation.Trusted
            } else {
                HostTrustEvaluation.Changed(entry.second.copyOf())
            }
        }
        override suspend fun trust(hostname: String, port: Int, algorithm: String, canonicalKeyBlob: ByteArray) {
            trusted["$hostname:$port"] = algorithm to canonicalKeyBlob.copyOf()
        }
        override suspend fun forget(hostname: String, port: Int): Boolean = trusted.remove("$hostname:$port") != null
    }

    private class RigRestoreRepository : SessionRestoreRepository {
        override fun observeRecords(): Flow<List<SessionRestoreRecord>> = MutableStateFlow(emptyList())
        override suspend fun records(): List<SessionRestoreRecord> = emptyList()
        override suspend fun record(sessionId: String): SessionRestoreRecord? = null
        override suspend fun save(record: SessionRestoreRecord) = Unit
        override suspend fun delete(sessionId: String) = Unit
        override suspend fun deleteForHost(hostId: String) = Unit
        override suspend fun deleteAll() = Unit
    }

    private fun log(message: String) {
        Log.i(TAG, message)
    }

    private companion object {
        const val TAG = "TesseraAgentCenterRig"
        const val FIXTURE_PATH = "/data/local/tmp/tessera-agent-center-rig-fixture.properties"
        const val GO_PATH = "/data/local/tmp/tessera-agent-center-rig-go"
        const val KEY_ALIAS = "tessera-agent-center-rig"
        // A connected phone can target a taller terminal owned by another
        // device. Keep the composer below row 32 to catch reply truncation.
        const val PHONE_COLUMNS = 56
        const val PHONE_ROWS = 43
        const val AUTHORIZE_TIMEOUT_MS = 120_000L
        const val CONNECT_TIMEOUT_MS = 90_000L
        const val SHOW_DECISION_TIMEOUT_MS = 15_000L
        const val THREAD_TIMEOUT_MS = 90_000L
        const val POLL_MS = 250L

        /** Consecutive unchanged polls before the thread set counts as settled. */
        const val SETTLE_POLLS = 12
    }
}

private fun <T> runOnMain(block: () -> T): T {
    val value = java.util.concurrent.atomic.AtomicReference<T>()
    val failure = java.util.concurrent.atomic.AtomicReference<Throwable?>()
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
        try {
            value.set(block())
        } catch (error: Throwable) {
            failure.set(error)
        }
    }
    failure.get()?.let { throw it }
    @Suppress("UNCHECKED_CAST")
    return value.get() as T
}
