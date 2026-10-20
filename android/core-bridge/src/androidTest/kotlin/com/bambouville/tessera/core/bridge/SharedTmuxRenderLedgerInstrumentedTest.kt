package com.bambouville.tessera.core.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The checked-in ledger vectors cross the real Swift/JNI boundary here. Kotlin
 * only decodes and executes effects; it never re-derives the state machine.
 */
@RunWith(AndroidJUnit4::class)
class SharedTmuxRenderLedgerInstrumentedTest {
    @Test
    fun closeFromSynchronousRenderCallbackDefersNativeDestruction() {
        lateinit var runtime: SharedTmuxRuntime
        var callbackCount = 0
        runtime = SharedTmuxRuntime.create {
            callbackCount += 1
            runtime.close()
        }

        assertEquals(
            CoreCallResult.Accepted,
            runtime.submitFact(SharedTmuxRenderFact.TransportLost),
        )
        assertEquals(1, callbackCount)
        assertEquals(
            CoreCallResult.StaleHandle,
            runtime.submitFact(SharedTmuxRenderFact.AppForeground),
        )
    }

    @Test
    fun closeMayRaceFeedAndRenderByteTakeWithoutUsingFreedRuntime() {
        val executor = Executors.newFixedThreadPool(3)
        try {
            repeat(64) { iteration ->
                val runtime = SharedTmuxRuntime.create { }
                val start = CountDownLatch(1)
                val feed = executor.submit {
                    start.await()
                    repeat(8) {
                        val result = runtime.feed("%output %1 race-$it\r\n".encodeToByteArray())
                        assertTrue(result == CoreCallResult.Accepted || result == CoreCallResult.StaleHandle)
                    }
                }
                val take = executor.submit {
                    start.await()
                    repeat(8) {
                        val result = runtime.takeRenderBytes(1)
                        assertTrue(
                            result == SharedTmuxRenderBytes.InvalidReference ||
                                result == SharedTmuxRenderBytes.StaleHandle,
                        )
                    }
                }
                val close = executor.submit {
                    start.await()
                    runtime.close()
                }
                start.countDown()
                feed.get(10, TimeUnit.SECONDS)
                take.get(10, TimeUnit.SECONDS)
                close.get(10, TimeUnit.SECONDS)
                runtime.close()
            }
        } finally {
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(10, TimeUnit.SECONDS))
        }
    }

    @Test
    fun renderLedgerVectorsMatchSharedRuntimeIncludingRawFeedBytes() {
        val vectors = loadVectors()
        assertEquals(1, vectors.getInt("version"))
        runVectors(vectors.getJSONArray("cases"), "core")
        runVectors(vectors.getJSONArray("abiCases"), "ABI")
    }

    @Test
    fun paneOutputVectorBytesSurviveUntilDelayedFacadeTwoPassCopy() {
        val vectors = loadVectors()
        val cases = vectors.getJSONArray("cases")
        val vector = (0 until cases.length())
            .map { cases.getJSONObject(it) }
            .single { it.getString("name") == "inline-initial-deep-primary-feed" }
        val delivered = mutableListOf<SharedTmuxRenderEffect>()
        lateinit var runtime: SharedTmuxRuntime
        runtime = SharedTmuxRuntime.create { event ->
            delivered += event.renderEffects
        }
        runtime.use {
            driveVector(vector, runtime)

            // The callback has returned for every vector step; this façade call
            // performs the ABI's size query followed by its consuming copy.
            val feed = delivered.filterIsInstance<SharedTmuxRenderEffect.Feed>()
                .single { it.source == SharedTmuxRenderFeedSource.PaneOutput }
            val expected = vector.expectedPaneOutput().getJSONObject("bytes")
            val copied = runtime.takeRenderBytes(feed.bytesRef)
            assertTrue(
                "delayed pane-output ref ${feed.bytesRef} was not retained",
                copied is SharedTmuxRenderBytes.Available,
            )
            val bytes = (copied as SharedTmuxRenderBytes.Available).bytes
            assertEquals(expected.getInt("length"), bytes.size)
            assertEquals(expected.getString("sha256"), bytes.sha256())
            assertEquals(
                "the consuming copy must evict the rendered-bytes ref",
                SharedTmuxRenderBytes.InvalidReference,
                runtime.takeRenderBytes(feed.bytesRef),
            )
        }
    }

    @Test
    fun promisedFeedBytesSurviveNewerSameOwnerGeneration() {
        val delivered = mutableListOf<SharedTmuxRenderEffect>()
        val runtime = SharedTmuxRuntime.create { event ->
            delivered += event.renderEffects
        }
        runtime.use {
            val oldFeed = establishInlineLiveSurface(runtime, delivered)

            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(
                    SharedTmuxRenderFact.RefreshRequested(
                        surfaceId = "live",
                        stage = SharedTmuxRenderStage.ViewportOnly,
                        reason = "android-same-owner",
                    ),
                ),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed(
                    "%begin 2 1 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 2 1 1\r\n"
                        .encodeToByteArray(),
                ),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed(
                    "%begin 2 2 1\r\nnew authoritative payload\r\n%end 2 2 1\r\n"
                        .encodeToByteArray(),
                ),
            )
            submitLatestSurfaceState(runtime, delivered)
            val newFeed = latestFeed(delivered)

            assertTrue("new generation must use a distinct byte reference", newFeed.bytesRef != oldFeed.bytesRef)
            assertEquals("the refresh remains on the same render owner", oldFeed.owner, newFeed.owner)
            assertTrue(
                "a later same-owner generation must not revoke bytes already promised to Android",
                takeAvailableRenderBytes(runtime, oldFeed.bytesRef)
                    .decodeToString()
                    .contains("initial authoritative payload"),
            )
            assertTrue(
                takeAvailableRenderBytes(runtime, newFeed.bytesRef)
                    .decodeToString()
                    .contains("new authoritative payload"),
            )
        }
    }

    @Test
    fun promisedBytesSurviveAttachButTransportLossRevokesThem() {
        val delivered = mutableListOf<SharedTmuxRenderEffect>()
        val runtime = SharedTmuxRuntime.create { event ->
            delivered += event.renderEffects
        }
        runtime.use {
            establishInlineLiveSurface(runtime, delivered)
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed("%output %1 promised-survives-attach\r\n".encodeToByteArray()),
            )
            val preAttachFeed = latestFeed(delivered)
            assertEquals(SharedTmuxRenderFeedSource.PaneOutput, preAttachFeed.source)
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed("%output %1 promised-before-loss\r\n".encodeToByteArray()),
            )
            val preLossFeed = latestFeed(delivered)
            assertEquals(SharedTmuxRenderFeedSource.PaneOutput, preLossFeed.source)
            assertTrue(preLossFeed.bytesRef != preAttachFeed.bytesRef)

            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(
                    SharedTmuxRenderFact.TransportAttached(SharedTmuxRenderProfile.Inline),
                ),
            )
            assertTrue(
                "a fresh attach alone must preserve a promised reference",
                takeAvailableRenderBytes(runtime, preAttachFeed.bytesRef)
                    .decodeToString()
                    .contains("promised-survives-attach"),
            )

            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.TransportLost),
            )
            assertEquals(
                "transport loss ends every promised-reference lifetime",
                SharedTmuxRenderBytes.InvalidReference,
                runtime.takeRenderBytes(preLossFeed.bytesRef),
            )
        }
    }

    @Test
    fun transportReattachUsesRetainedLogicalTopologyUntilParserRehydrates() {
        val delivered = mutableListOf<SharedTmuxRenderEffect>()
        val runtime = SharedTmuxRuntime.create { event ->
            delivered += event.renderEffects
        }
        runtime.use {
            establishInlineLiveSurface(runtime, delivered)
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.TransportLost),
            )

            delivered.clear()
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(
                    SharedTmuxRenderFact.TransportAttached(SharedTmuxRenderProfile.Inline),
                ),
            )
            assertTrue(
                "reattach must repaint retained @1 topology before parser hydration",
                commands(delivered).any { it.startsWith("display-message -p -t @1 ") },
            )

            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed(
                    "%begin 2 1 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 2 1 1\r\n"
                        .encodeToByteArray(),
                ),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed(
                    "%begin 2 2 1\r\nreattached authoritative payload\r\n%end 2 2 1\r\n"
                        .encodeToByteArray(),
                ),
            )
            submitLatestSurfaceState(runtime, delivered)

            delivered.clear()
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed("%window-add @2\r\n%window-pane-changed @2 %2\r\n".encodeToByteArray()),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed("%session-window-changed $9 @2\r\n".encodeToByteArray()),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed(
                    "%begin 9 9 0\r\n__tessera_active_window__\t@2\r\n%end 9 9 0\r\n"
                        .encodeToByteArray(),
                ),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(
                    SharedTmuxRenderFact.RefreshRequested(
                        surfaceId = "live",
                        stage = SharedTmuxRenderStage.ViewportOnly,
                        reason = "pre-authority-window-add",
                    ),
                ),
            )
            assertTrue(commands(delivered).any { it.contains(" -t @1 ") })
            assertTrue(
                "a split-read window-add fallback must not replace retained topology",
                commands(delivered).none { it.contains(" -t @2 ") },
            )

            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed(
                    "%begin 3 1 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 3 1 1\r\n"
                        .encodeToByteArray(),
                ),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed(
                    "%begin 3 2 1\r\nretained target refresh\r\n%end 3 2 1\r\n"
                        .encodeToByteArray(),
                ),
            )
            submitLatestSurfaceState(runtime, delivered)

            delivered.clear()
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed("%session-window-changed $0 @2\r\n".encodeToByteArray()),
            )
            assertTrue(
                "a session broadcast without this client's identity is not a rehydration cut",
                commands(delivered).none { it.contains(" -t @2 ") },
            )

            delivered.clear()
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed("%session-changed $0 work\r\n".encodeToByteArray()),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(
                    SharedTmuxRenderFact.RefreshRequested(
                        surfaceId = "live",
                        stage = SharedTmuxRenderStage.ViewportOnly,
                        reason = "post-authority-session",
                    ),
                ),
            )
            assertTrue(
                "the explicit session active-window signal must release rehydration onto @2",
                commands(delivered).any { it.contains(" -t @2 ") },
            )
        }
    }

    @Test
    fun historyPresentationAcknowledgementStagesMoshHistoryUntilItsExactOwnerPresentsIt() {
        val delivered = mutableListOf<SharedTmuxRenderEffect>()
        val runtime = SharedTmuxRuntime.create { event ->
            delivered += event.renderEffects
        }
        runtime.use {
            val ready = establishSideChannelHistory(runtime, delivered)
            val beforeOutput = delivered.size

            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed("%output %1 output-before-platform-presentation\r\n".encodeToByteArray()),
            )
            val whileStaged = delivered.drop(beforeOutput)
            assertTrue(
                "output before the platform consumes historyReady must not freeze the staged history",
                whileStaged.none { it.isFrozenSideChannelDiagnostic() },
            )
            assertTrue(
                "output before presentation must not replace staged mosh history with a pane feed",
                whileStaged.none { it is SharedTmuxRenderEffect.Feed },
            )

            val beforeAck = delivered.size
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.HistoryPresented(ready.surfaceId, ready.owner)),
            )
            assertTrue(
                "the exact acknowledgement must reveal then freeze the history dirtied while staged",
                delivered.drop(beforeAck).any { it.isFrozenSideChannelDiagnostic() },
            )
        }
    }

    @Test
    fun historyPresentationFactIsCanonicalAndStaleOwnerFailsClosed() {
        val expectedOwner = SharedTmuxRenderOwner(windowId = 1, paneId = 1, epoch = 7)
        assertEquals(
            "{\"kind\":\"historyPresented\",\"owner\":{\"epoch\":7,\"paneID\":1,\"windowID\":1},\"surfaceID\":\"live\",\"version\":1}",
            SharedTmuxRenderFact.HistoryPresented("live", expectedOwner).canonicalBytes().decodeToString(),
        )

        val delivered = mutableListOf<SharedTmuxRenderEffect>()
        val runtime = SharedTmuxRuntime.create { event ->
            delivered += event.renderEffects
        }
        runtime.use {
            val ready = establishSideChannelHistory(runtime, delivered)
            val staleOwner = ready.owner.copy(epoch = ready.owner.epoch + 1)
            val beforeStaleAck = delivered.size

            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.HistoryPresented(ready.surfaceId, staleOwner)),
            )
            assertTrue(
                "a stale presentation acknowledgement must be visible in shared-ledger diagnostics",
                delivered.drop(beforeStaleAck).any {
                    it is SharedTmuxRenderEffect.Diagnostic &&
                        it.message.contains("history-presented-stale")
                },
            )

            val beforeOutput = delivered.size
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed("%output %1 output-after-stale-ack\r\n".encodeToByteArray()),
            )
            assertTrue(
                "a stale acknowledgement must leave history staged rather than freezing or revealing it",
                delivered.drop(beforeOutput).none { it.isFrozenSideChannelDiagnostic() },
            )

            val beforeExactAck = delivered.size
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.HistoryPresented(ready.surfaceId, ready.owner)),
            )
            assertTrue(
                "the original owner remains the only acknowledgement allowed to present staged history",
                delivered.drop(beforeExactAck).any { it.isFrozenSideChannelDiagnostic() },
            )
        }
    }

    @Test
    fun sideChannelGeometryStormDropsStaleCaptureAndDeliversLatestSamePaneHistory() {
        val delivered = mutableListOf<SharedTmuxRenderEffect>()
        val runtime = SharedTmuxRuntime.create { event ->
            delivered += event.renderEffects
        }
        runtime.use {
            // Start from a known presented history, then return to the live
            // tail.  The following find request is deliberately held at its
            // capture reply while geometry changes arrive, matching Mosh's
            // visible-client handoff/resize window.
            val priorReady = establishSideChannelHistory(runtime, delivered)
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.HistoryPresented(priorReady.surfaceId, priorReady.owner)),
            )
            delivered.clear()
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.ScrollbackReturnedToTail("live")),
            )
            delivered.clear()

            var commandIndex = 0
            var replySequence = 10
            var resolveIndex = 0

            fun replyToNextCommand(): String {
                val command = commands(delivered).getOrNull(commandIndex)
                    ?: error("no command at index $commandIndex")
                commandIndex += 1
                val lines = when {
                    command.startsWith("display-message -p -t %1 ") -> listOf(
                        "%1\t0\t0\t\twindow\thost\t0\t20",
                    )
                    command.startsWith("capture-pane -p -e -N -S -") -> listOf(
                        "latest older history",
                        "latest live row",
                    )
                    else -> emptyList()
                }
                assertEquals(
                    CoreCallResult.Accepted,
                    runtime.feed(commandResultWire(replySequence++, lines)),
                )
                return command
            }

            fun submitPendingSurfaceStates() {
                val resolves = delivered.filterIsInstance<SharedTmuxRenderEffect.ResolveSurfaceState>()
                while (resolveIndex < resolves.size) {
                    val resolve = resolves[resolveIndex++]
                    assertEquals(
                        CoreCallResult.Accepted,
                        runtime.submitFact(
                            SharedTmuxRenderFact.SurfaceState(
                                surfaceId = resolve.surfaceId,
                                request = resolve.request,
                                altScreen = false,
                                mouseMode = SharedTmuxRenderMouseMode.Off,
                                columns = 104,
                                rows = 30,
                            ),
                        ),
                    )
                }
            }

            // Resolve metadata first, so an actual capture command is in
            // flight when the storm begins. Its eventual reply is a stale
            // generation and must not surface a HistoryReady event.
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.FindOpened("live")),
            )
            assertTrue(replyToNextCommand().startsWith("display-message -p -t %1 "))
            assertTrue(
                "metadata must advance the admitted request to its capture",
                commands(delivered).drop(commandIndex).any {
                    it.startsWith("capture-pane -p -e -N -S -")
                },
            )

            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.ClientSize(columns = 100, rows = 30)),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed(
                    "%layout-change @1 8205,100x30,0,0,1 8205,100x30,0,0,1 *\r\n"
                        .encodeToByteArray(),
                ),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.ClientSize(columns = 102, rows = 30)),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed(
                    "%layout-change @1 8205,102x30,0,0,1 8205,102x30,0,0,1 *\r\n"
                        .encodeToByteArray(),
                ),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.ClientSize(columns = 104, rows = 30)),
            )

            val beforeStaleCapture = delivered.size
            assertTrue(replyToNextCommand().startsWith("capture-pane -p -e -N -S -"))
            assertTrue(
                "the superseded capture reply must be rejected rather than delivered",
                delivered.drop(beforeStaleCapture).any {
                    it is SharedTmuxRenderEffect.Diagnostic && it.message.contains("stale-reply")
                },
            )
            assertTrue(
                "a stale capture generation must not expose history",
                delivered.none { it is SharedTmuxRenderEffect.HistoryReady },
            )

            // The queued latest geometry request now drains. Fire-and-forget
            // size replays receive empty success replies; metadata and capture
            // commands receive the current pane response. The only accepted
            // history must therefore be the final generation for %1.
            repeat(64) {
                while (commandIndex < commands(delivered).size) {
                    replyToNextCommand()
                    submitPendingSurfaceStates()
                }
                submitPendingSurfaceStates()
                if (delivered.any { it is SharedTmuxRenderEffect.HistoryReady }) return@repeat
            }

            val latest = delivered.filterIsInstance<SharedTmuxRenderEffect.HistoryReady>()
            assertEquals("only the settled generation may deliver history", 1, latest.size)
            assertEquals("live", latest.single().surfaceId)
            assertEquals(1, latest.single().owner.windowId)
            assertEquals(1, latest.single().owner.paneId)
            assertTrue(
                "the geometry storm must advance ownership beyond the history it replaced",
                latest.single().owner.epoch > priorReady.owner.epoch,
            )

            val beforeAck = delivered.size
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(
                    SharedTmuxRenderFact.HistoryPresented(latest.single().surfaceId, latest.single().owner),
                ),
            )
            assertTrue(
                "the exact final owner must acknowledge without a stale-owner diagnostic",
                delivered.drop(beforeAck).none {
                    it is SharedTmuxRenderEffect.Diagnostic && it.message.contains("history-presented-stale")
                },
            )
        }
    }

    @Test
    fun sideChannelUserInputCancelsAnAdmittedCaptureWithoutRestartingIt() {
        val delivered = mutableListOf<SharedTmuxRenderEffect>()
        val runtime = SharedTmuxRuntime.create { event ->
            delivered += event.renderEffects
        }
        runtime.use {
            val ready = establishSideChannelHistory(runtime, delivered)
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.HistoryPresented(ready.surfaceId, ready.owner)),
            )
            delivered.clear()
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.ScrollbackReturnedToTail("live")),
            )
            delivered.clear()

            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.FindOpened("live")),
            )
            val commandsBeforeInput = commands(delivered)
            // Metadata and history now leave together to avoid an extra
            // round trip. User input must retire both admitted FIFO replies.
            assertEquals(2, commandsBeforeInput.size)
            assertTrue(commandsBeforeInput[0].startsWith("display-message -p -t %1 "))
            assertTrue(commandsBeforeInput[1].startsWith("capture-pane -p -e -N -S -"))
            assertTrue(commandsBeforeInput[1].endsWith(" -t %1"))

            assertEquals(CoreCallResult.Accepted, runtime.submitFact(SharedTmuxRenderFact.UserInput))
            assertEquals(
                "terminal input clears the request but must not resurrect it",
                commandsBeforeInput,
                commands(delivered),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed(commandResultWire(99, listOf("%1\t0\t0\t\twindow\thost\t0\t20"))),
            )
            assertTrue(
                "the retired metadata reply must stay stale after terminal input",
                delivered.any {
                    it is SharedTmuxRenderEffect.Diagnostic && it.message.contains("stale-reply")
                },
            )
            val beforeRetiredCapture = delivered.size
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed(commandResultWire(100, listOf("retired history", "retired live row"))),
            )
            assertTrue(
                "the batched capture reply must also stay stale after terminal input",
                delivered.drop(beforeRetiredCapture).any {
                    it is SharedTmuxRenderEffect.Diagnostic && it.message.contains("stale-reply")
                },
            )
            assertEquals(
                "neither retired reply may restart the cancelled request",
                commandsBeforeInput,
                commands(delivered),
            )
            assertTrue(
                delivered.none { it is SharedTmuxRenderEffect.HistoryReady },
            )
        }
    }

    /**
     * The adapter-owned switches and the releasing settlement across the real
     * Swift/JNI boundary; `TmuxRuntimeClaimSettlementABITests` covers their
     * semantics in depth. The JVM tests' `CoreClientSizeLedger` ports the
     * replay checked here.
     */
    @Test
    fun ledgerSwitchesAndAuthorityProjectionCrossTheRealBoundary() {
        val suppresses = SharedTmuxRenderLedgerOptions.SUPPRESSES_UNCHANGED_CLIENT_SIZE_REPLAY
        val belongs = SharedTmuxRenderLedgerOptions.INLINE_CLIENT_SIZE_REPLAY_BELONGS_TO_CLAIM
        val pipelines = SharedTmuxRenderLedgerOptions.PIPELINES_VISIBLE_CAPTURE
        val delivered = mutableListOf<SharedTmuxRenderEffect>()
        val runtime = SharedTmuxRuntime.create { event ->
            delivered += event.renderEffects
        }
        runtime.use {
            assertEquals(CoreCallResult.Accepted, runtime.setRenderLedgerOptions(suppresses or belongs or pipelines))
            assertEquals(
                "an undefined bit is refused, never ignored",
                CoreCallResult.InvalidArguments,
                runtime.setRenderLedgerOptions(8),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.TransportAttached(SharedTmuxRenderProfile.Inline)),
            )
            delivered.clear()
            assertEquals(CoreCallResult.Accepted, runtime.submitFact(SharedTmuxRenderFact.ClientSize(80, 24)))
            assertEquals("a claim's replay fences nothing itself", listOf("refresh-client -C 80,24"), commands(delivered))
            delivered.clear()
            assertEquals(CoreCallResult.Accepted, runtime.submitFact(SharedTmuxRenderFact.ClientSize(80, 24)))
            assertEquals("P6: already advertised", emptyList<String>(), commands(delivered))
            assertEquals(CoreCallResult.Accepted, runtime.setRenderLedgerOptions(suppresses or pipelines))
            assertEquals(CoreCallResult.Accepted, runtime.submitFact(SharedTmuxRenderFact.ClientSize(80, 24)))
            assertEquals(
                "an owner's replay keeps the fence alone",
                listOf(SharedTmuxCommands.clientSizeLatestFenceCommand),
                commands(delivered),
            )

            val settled = runtime.projectAuthorityReleasing(SharedTmuxGridAuthoritySnapshot.Mine(1))
            assertTrue("$settled", settled is SharedTmuxClaimSettlement.Released)
            assertEquals(
                "nothing was deferred",
                emptyList<String>(),
                commands((settled as SharedTmuxClaimSettlement.Released).renderEffects),
            )
        }
        assertEquals(SharedTmuxClaimSettlement.StaleHandle, runtime.projectAuthorityReleasing(SharedTmuxGridAuthoritySnapshot.Mine(2)))
        assertEquals(CoreCallResult.StaleHandle, runtime.setRenderLedgerOptions(0))
    }

    @Test
    fun projectionGrowsAShortBufferAndRejectsBadJsonWithoutMutation() {
        val events = mutableListOf<CoreEvent>()
        TmuxCoreRuntime.create { events += it }.use { core ->
            val authority = SharedTmuxGridAuthoritySnapshot.Mine(9).runtimeJSON()
            val grown = core.projectAuthorityReleasing(authority, initialOutputCapacity = 64)
            assertEquals(SharedTmuxClaimSettlement.Released(emptyList()),
                SharedTmuxClaimSettlement.decode(checkNotNull(grown)))
            assertTrue(events.isEmpty())
            assertEquals(0, checkNotNull(core.projectAuthorityReleasing("{}".encodeToByteArray())).size)
            assertEquals(CoreCallResult.Accepted, core.resyncSnapshot())
            val event = SharedTmuxRuntime.parse(events.last().bytes)
            assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(9), event.snapshot.authority)
        }
    }

    private fun runVectors(cases: JSONArray, section: String) {
        repeat(cases.length()) { index ->
            val vector = cases.getJSONObject(index)
            val actual = JSONArray()
            lateinit var runtime: SharedTmuxRuntime
            runtime = SharedTmuxRuntime.create { event ->
                event.renderEffects.forEach { effect -> actual.put(normalize(effect, runtime)) }
            }
            runtime.use {
                driveVector(vector, runtime)
            }
            assertEquals(
                "$section ${vector.getString("name")}",
                canonical(vector.getJSONArray("expectedEffects")),
                canonical(actual),
            )
        }
    }

    private fun driveVector(vector: JSONObject, runtime: SharedTmuxRuntime) {
        val steps = vector.getJSONArray("steps")
        repeat(steps.length()) { stepIndex ->
            val input = steps.getJSONObject(stepIndex).getJSONObject("input")
            when (input.getString("kind")) {
                "wire" -> assertEquals(
                    "${vector.getString("name")} step $stepIndex",
                    CoreCallResult.Accepted,
                    runtime.feed(input.getString("wire").encodeToByteArray()),
                )
                "fact" -> assertEquals(
                    "${vector.getString("name")} step $stepIndex",
                    CoreCallResult.Accepted,
                    runtime.submitFact(parseFact(input.getJSONObject("fact"))),
                )
                "platformCommand" -> assertTrue(
                    "${vector.getString("name")} step $stepIndex platform command was rejected",
                    runtime.sendCommand(input.getString("command")) is SharedTmuxCommandSubmission.Accepted,
                )
                else -> error("unknown render-ledger vector input")
            }
        }
    }

    private fun establishInlineLiveSurface(
        runtime: SharedTmuxRuntime,
        delivered: List<SharedTmuxRenderEffect>,
    ): SharedTmuxRenderEffect.Feed {
        assertEquals(
            CoreCallResult.Accepted,
            runtime.submitFact(SharedTmuxRenderFact.TransportAttached(SharedTmuxRenderProfile.Inline)),
        )
        assertEquals(
            CoreCallResult.Accepted,
            runtime.submitFact(
                SharedTmuxRenderFact.SurfacesDeclared(
                    listOf(
                        SharedTmuxSurfaceDeclaration(
                            surfaceId = "live",
                            presentation = SharedTmuxSurfacePresentation.Single,
                        ),
                    ),
                ),
            ),
        )
        assertEquals(
            CoreCallResult.Accepted,
            runtime.feed(
                "%window-add @1\r\n%session-window-changed $0 @1\r\n%window-pane-changed @1 %1\r\n"
                    .encodeToByteArray(),
            ),
        )
        val initialCommands = commands(delivered)
        assertTrue(
            "wire-order hydration must queue the superseded window-only metadata request",
            initialCommands.any { it.startsWith("display-message -p -t @1 ") },
        )
        // The window-only request is superseded once the pane arrives, but its
        // FIFO reply still precedes the current metadata and capture replies.
        assertEquals(
            CoreCallResult.Accepted,
            runtime.feed(
                "%begin 1 1 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 1 1 1\r\n"
                    .encodeToByteArray(),
            ),
        )
        assertTrue(
            "draining superseded metadata must queue the current pane-resolved request",
            commands(delivered).count { it.startsWith("display-message -p -t @1 ") } == 2,
        )
        assertEquals(
            CoreCallResult.Accepted,
            runtime.feed(
                "%begin 1 2 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 1 2 1\r\n"
                    .encodeToByteArray(),
            ),
        )
        assertTrue(
            "current metadata must queue the authoritative deep capture",
            commands(delivered).any { it.startsWith("capture-pane -p -e -N -S -") && it.endsWith(" -t @1") },
        )
        assertEquals(
            CoreCallResult.Accepted,
            runtime.feed(
                "%begin 1 3 1\r\ninitial authoritative payload\r\n%end 1 3 1\r\n"
                    .encodeToByteArray(),
            ),
        )
        submitLatestSurfaceState(runtime, delivered)
        return latestFeed(delivered)
    }

    private fun establishSideChannelHistory(
        runtime: SharedTmuxRuntime,
        delivered: List<SharedTmuxRenderEffect>,
    ): SharedTmuxRenderEffect.HistoryReady {
        assertEquals(
            CoreCallResult.Accepted,
            runtime.submitFact(SharedTmuxRenderFact.TransportAttached(SharedTmuxRenderProfile.SideChannel)),
        )
        assertEquals(
            CoreCallResult.Accepted,
            runtime.submitFact(
                SharedTmuxRenderFact.SurfacesDeclared(
                    listOf(
                        SharedTmuxSurfaceDeclaration(
                            surfaceId = "live",
                            presentation = SharedTmuxSurfacePresentation.Single,
                        ),
                    ),
                ),
            ),
        )
        assertEquals(
            CoreCallResult.Accepted,
            runtime.feed(
                "%window-add @1\r\n%session-window-changed $0 @1\r\n%window-pane-changed @1 %1\r\n"
                    .encodeToByteArray(),
            ),
        )
        assertEquals(
            CoreCallResult.Accepted,
            runtime.submitFact(
                SharedTmuxRenderFact.ScrollbackRequested(
                    surfaceId = "live",
                    pointsY = 1.0,
                    isInertial = false,
                ),
            ),
        )
        assertTrue(
            "a side-channel history request must first resolve the visible pane",
            commands(delivered).any { it.startsWith("display-message -p -t %1 ") },
        )
        assertEquals(
            CoreCallResult.Accepted,
            runtime.feed(
                "%begin 1 1 1\r\n%1\t0\t0\t\twindow\thost\t0\t20\r\n%end 1 1 1\r\n"
                    .encodeToByteArray(),
            ),
        )
        assertTrue(
            "metadata must start the bounded mosh history capture",
            commands(delivered).any { it.startsWith("capture-pane -p -e -N -S -") && it.endsWith(" -t %1") },
        )
        assertEquals(
            CoreCallResult.Accepted,
            runtime.feed(
                "%begin 1 2 1\r\nolder history\r\nlive row\r\n%end 1 2 1\r\n"
                    .encodeToByteArray(),
            ),
        )
        submitLatestSurfaceState(runtime, delivered)
        return delivered.filterIsInstance<SharedTmuxRenderEffect.HistoryReady>().last()
    }

    private fun submitLatestSurfaceState(
        runtime: SharedTmuxRuntime,
        delivered: List<SharedTmuxRenderEffect>,
    ) {
        val resolve = delivered.filterIsInstance<SharedTmuxRenderEffect.ResolveSurfaceState>().last()
        assertEquals(
            CoreCallResult.Accepted,
            runtime.submitFact(
                SharedTmuxRenderFact.SurfaceState(
                    surfaceId = resolve.surfaceId,
                    request = resolve.request,
                    altScreen = false,
                    mouseMode = SharedTmuxRenderMouseMode.Off,
                    columns = 80,
                    rows = 24,
                ),
            ),
        )
    }

    private fun latestFeed(delivered: List<SharedTmuxRenderEffect>): SharedTmuxRenderEffect.Feed =
        delivered.filterIsInstance<SharedTmuxRenderEffect.Feed>().last()

    private fun commands(delivered: List<SharedTmuxRenderEffect>): List<String> =
        delivered.filterIsInstance<SharedTmuxRenderEffect.SendCommand>().map { it.command }

    private fun commandResultWire(sequence: Int, lines: List<String>): ByteArray = buildString {
        append("%begin ")
        append(sequence)
        append(" 1 1\r\n")
        lines.forEach { line ->
            append(line)
            append("\r\n")
        }
        append("%end ")
        append(sequence)
        append(" 1 1\r\n")
    }.encodeToByteArray()

    private fun SharedTmuxRenderEffect.isFrozenSideChannelDiagnostic(): Boolean =
        this is SharedTmuxRenderEffect.Diagnostic && message.contains("side-channel-frozen")

    private fun takeAvailableRenderBytes(runtime: SharedTmuxRuntime, bytesRef: Long): ByteArray {
        val result = runtime.takeRenderBytes(bytesRef)
        assertTrue("promised byte reference $bytesRef was unavailable: $result", result is SharedTmuxRenderBytes.Available)
        return (result as SharedTmuxRenderBytes.Available).bytes
    }

    private fun loadVectors(): JSONObject = InstrumentationRegistry.getInstrumentation().context.assets
        .open("tmux/render-ledger-v1.json")
        .use { JSONObject(it.readBytes().decodeToString()) }

    private fun JSONObject.expectedPaneOutput(): JSONObject {
        val effects = getJSONArray("expectedEffects")
        return (0 until effects.length())
            .map { effects.getJSONObject(it) }
            .single { it.getString("kind") == "feed" && it.getString("source") == "pane-output" }
    }

    private fun parseFact(value: JSONObject): SharedTmuxRenderFact {
        assertEquals(1, value.getInt("version"))
        return when (value.getString("kind")) {
            "transportAttached" -> SharedTmuxRenderFact.TransportAttached(
                SharedTmuxRenderProfile.fromWire(value.getString("profile")),
            )
            "transportLost" -> SharedTmuxRenderFact.TransportLost
            "surfacesDeclared" -> SharedTmuxRenderFact.SurfacesDeclared(
                value.getJSONArray("surfaces").let { surfaces ->
                    buildList {
                        repeat(surfaces.length()) { index ->
                            val surface = surfaces.getJSONObject(index)
                            add(
                                SharedTmuxSurfaceDeclaration(
                                    surfaceId = surface.getString("surfaceID"),
                                    presentation = SharedTmuxSurfacePresentation.fromWire(
                                        surface.getString("presentation"),
                                    ),
                                    windowId = surface.optionalInt("windowID"),
                                    paneId = surface.optionalInt("paneID"),
                                ),
                            )
                        }
                    }
                },
            )
            "clientSize" -> SharedTmuxRenderFact.ClientSize(
                columns = value.getInt("columns"),
                rows = value.getInt("rows"),
            )
            "surfaceState" -> SharedTmuxRenderFact.SurfaceState(
                surfaceId = value.getString("surfaceID"),
                request = value.getLong("request"),
                altScreen = value.getBoolean("altScreen"),
                mouseMode = SharedTmuxRenderMouseMode.fromWire(value.getString("mouseMode")),
                columns = value.getInt("columns"),
                rows = value.getInt("rows"),
            )
            "appForeground" -> SharedTmuxRenderFact.AppForeground
            "appBackground" -> SharedTmuxRenderFact.AppBackground
            "timerFired" -> SharedTmuxRenderFact.TimerFired(value.getLong("token"))
            "scrollbackRequested" -> SharedTmuxRenderFact.ScrollbackRequested(
                surfaceId = value.getString("surfaceID"),
                pointsY = value.getDouble("pointsY"),
                isInertial = value.getBoolean("isInertial"),
            )
            "scrollbackReturnedToTail" -> SharedTmuxRenderFact.ScrollbackReturnedToTail(
                value.getString("surfaceID"),
            )
            "historyPresented" -> SharedTmuxRenderFact.HistoryPresented(
                surfaceId = value.getString("surfaceID"),
                owner = value.getJSONObject("owner").toRenderOwner(),
            )
            "historyPresentationFailed" -> SharedTmuxRenderFact.HistoryPresentationFailed(
                surfaceId = value.getString("surfaceID"),
                owner = value.getJSONObject("owner").toRenderOwner(),
            )
            "findOpened" -> SharedTmuxRenderFact.FindOpened(value.getString("surfaceID"))
            "userInput" -> SharedTmuxRenderFact.UserInput
            "scrollbackLimit" -> SharedTmuxRenderFact.ScrollbackLimit(value.getInt("lines"))
            "refreshRequested" -> SharedTmuxRenderFact.RefreshRequested(
                surfaceId = value.getString("surfaceID"),
                stage = SharedTmuxRenderStage.fromWire(value.getString("stage")),
                reason = value.getString("reason"),
            )
            "correlatedRefreshRequested" -> SharedTmuxRenderFact.CorrelatedRefreshRequested(
                surfaceId = value.getString("surfaceID"),
                stage = SharedTmuxRenderStage.fromWire(value.getString("stage")),
                reason = value.getString("reason"),
                correlation = value.getLong("correlation"),
            )
            "correlatedTransportFullFrameRequested" ->
                SharedTmuxRenderFact.CorrelatedTransportFullFrameRequested(
                    surfaceId = value.getString("surfaceID"),
                    reason = value.getString("reason"),
                    correlation = value.getLong("correlation"),
                )
            else -> error("unknown render fact in checked-in vector")
        }
    }

    private fun normalize(
        effect: SharedTmuxRenderEffect,
        runtime: SharedTmuxRuntime,
    ): JSONObject = when (effect) {
        is SharedTmuxRenderEffect.SendCommand -> JSONObject()
            .put("kind", "sendCommand")
            .put("command", effect.command)
        is SharedTmuxRenderEffect.CommandReply -> JSONObject()
            .put("kind", "commandReply")
            .put("tag", effect.tag)
            .put("success", effect.success)
            .put("lines", JSONArray(effect.lines))
        is SharedTmuxRenderEffect.BindSurface -> JSONObject()
            .put("kind", "bindSurface")
            .put("surfaceID", effect.surfaceId)
            .put("owner", normalizeOwner(effect.owner))
        is SharedTmuxRenderEffect.Feed -> {
            val bytes = runtime.takeRenderBytes(effect.bytesRef)
            assertTrue("feed bytes ref ${effect.bytesRef} was not retained", bytes is SharedTmuxRenderBytes.Available)
            val payload = (bytes as SharedTmuxRenderBytes.Available).bytes
            JSONObject()
                .put("kind", "feed")
                .put("surfaceID", effect.surfaceId)
                .put("owner", normalizeOwner(effect.owner))
                .put("source", effect.source.wireValue)
                .put("bytes", JSONObject()
                    .put("length", payload.size)
                    .put("sha256", payload.sha256()))
        }
        is SharedTmuxRenderEffect.SaveWindowModes -> JSONObject()
            .put("kind", "saveWindowModes")
            .put("surfaceID", effect.surfaceId)
            .put("windowID", effect.windowId)
        is SharedTmuxRenderEffect.RestoreWindowModes -> JSONObject()
            .put("kind", "restoreWindowModes")
            .put("surfaceID", effect.surfaceId)
            .put("windowID", effect.windowId)
            .put("paneInAltScreen", effect.paneInAltScreen)
        is SharedTmuxRenderEffect.ResolveSurfaceState -> JSONObject()
            .put("kind", "resolveSurfaceState")
            .put("surfaceID", effect.surfaceId)
            .put("request", effect.request)
        is SharedTmuxRenderEffect.ArmTimer -> JSONObject()
            .put("kind", "armTimer")
            .put("token", effect.token)
            .put("milliseconds", effect.milliseconds)
        is SharedTmuxRenderEffect.CancelTimer -> JSONObject()
            .put("kind", "cancelTimer")
            .put("token", effect.token)
        SharedTmuxRenderEffect.InitialRenderReady -> JSONObject().put("kind", "initialRenderReady")
        SharedTmuxRenderEffect.RequestTransportFullFrame -> JSONObject().put("kind", "requestTransportFullFrame")
        is SharedTmuxRenderEffect.HistoryReady -> JSONObject()
            .put("kind", "historyReady")
            .put("surfaceID", effect.surfaceId)
            .put("owner", normalizeOwner(effect.owner))
            .put("depth", effect.depth)
            .put("historySize", effect.historySize)
            .put("placement", effect.placement.wireValue)
        is SharedTmuxRenderEffect.InlineHistorySettled -> JSONObject()
            .put("kind", "inlineHistorySettled")
            .put("surfaceID", effect.surfaceId)
            .put("owner", normalizeOwner(effect.owner))
            .put("depth", effect.depth)
            .put("historySize", effect.historySize)
            .put("canDeepen", effect.canDeepen)
        is SharedTmuxRenderEffect.RefreshCompleted -> JSONObject()
            .put("kind", "refreshCompleted")
            .put("surfaceID", effect.surfaceId)
            .put("owner", normalizeOwner(effect.owner))
            .put("stage", effect.stage.wireValue)
            .put("correlation", effect.correlation)
        is SharedTmuxRenderEffect.RefreshFailed -> JSONObject()
            .put("kind", "refreshFailed")
            .put("surfaceID", effect.surfaceId)
            .put("correlation", effect.correlation)
            .put("reason", effect.reason)
        is SharedTmuxRenderEffect.RequestCorrelatedTransportFullFrame -> JSONObject()
            .put("kind", "requestCorrelatedTransportFullFrame")
            .put("surfaceID", effect.surfaceId)
            // Omitted, not null: a reservation taken before the surface's first
            // bind names no owner, and the canonical encoding drops the field.
            .apply { effect.owner?.let { put("owner", normalizeOwner(it)) } }
            .put("correlation", effect.correlation)
            .put("reason", effect.reason)
        is SharedTmuxRenderEffect.TransportFullFrameCompleted -> JSONObject()
            .put("kind", "transportFullFrameCompleted")
            .put("surfaceID", effect.surfaceId)
            .apply { effect.owner?.let { put("owner", normalizeOwner(it)) } }
            .put("correlation", effect.correlation)
        is SharedTmuxRenderEffect.TransportFullFrameFailed -> JSONObject()
            .put("kind", "transportFullFrameFailed")
            .put("surfaceID", effect.surfaceId)
            .put("correlation", effect.correlation)
            .put("reason", effect.reason)
        is SharedTmuxRenderEffect.Diagnostic -> JSONObject()
            .put("kind", "diagnostic")
            .put("message", effect.message)
    }

    private fun normalizeOwner(owner: SharedTmuxRenderOwner): JSONObject = JSONObject().apply {
        owner.windowId?.let { put("windowID", it) }
        owner.paneId?.let { put("paneID", it) }
        put("epoch", owner.epoch)
    }

    private fun ByteArray.sha256(): String = MessageDigest.getInstance("SHA-256")
        .digest(this)
        .joinToString(separator = "") { "%02x".format(it.toInt() and 0xff) }

    private fun canonical(value: Any): String = when (value) {
        is JSONObject -> value.sortedKeys()
            .joinToString(separator = ",", prefix = "{", postfix = "}") { key ->
                "${JSONObject.quote(key)}:${canonical(value.get(key))}"
            }
        is JSONArray -> buildList {
            repeat(value.length()) { add(canonical(value.get(it))) }
        }.joinToString(separator = ",", prefix = "[", postfix = "]")
        is String -> JSONObject.quote(value)
        else -> value.toString()
    }

    private fun JSONObject.sortedKeys(): List<String> = buildList {
        val iterator = keys()
        while (iterator.hasNext()) add(iterator.next())
    }.sorted()

    private fun JSONObject.optionalInt(key: String): Int? =
        takeIf { has(key) && !isNull(key) }?.getInt(key)

    private fun JSONObject.toRenderOwner(): SharedTmuxRenderOwner = SharedTmuxRenderOwner(
        windowId = optionalInt("windowID"),
        paneId = optionalInt("paneID"),
        epoch = getLong("epoch"),
    )
}
