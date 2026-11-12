package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import com.bambouville.tessera.core.bridge.SharedAgentRuntimeEvent
import com.bambouville.tessera.core.bridge.SharedAgentSnapshotKind
import com.bambouville.tessera.data.AndroidAgentCenterViewPreferences
import com.bambouville.tessera.data.AndroidAgentMetadataRepository
import java.lang.reflect.Proxy
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import sun.misc.Unsafe

/** Production presenter, coordinator and host JNI Core; no Android storage or host connections. */
class AgentCenterLifecycleTest {
    @Test fun paneRemovalBurstSchedulesOneSweepAndRetiresTheNeedsInputThread() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX)) {
            val rig = Rig(transport)
            try {
                rig.endpoint.live("%75", 7, "claude")
                rig.frame("A", 7, event = "PermissionRequest")
                rig.await { it.threads.singleOrNull()?.let { row ->
                    row.status == "waitingForInput" && row.attention == "needsYou"
                } == true }
                rig.observeEndpoint()
                assertEquals(0, rig.endpoint.occupancyReads)
                rig.endpoint.occupancy = AgentEndpointResult.Success(AgentOccupancySnapshot(emptyList(), allPaneIDs = emptyList()))
                rig.removalBurst()
                rig.onPresenter { assertEquals(1, rig.sweepJobs().size) }
                rig.await { it.threads.isEmpty() && it.selectedThreadKey == null }
                rig.drain()
                assertEquals(1, rig.endpoint.occupancyReads)
                assertNull(rig.owner("A"))
                assertFalse(rig.sources().containsKey(rig.endpoint.threadKey("A")))
                assertTrue(rig.presenter.state.value.projectedDetails.values.none { it.row.attention == "needsYou" })
            } finally { rig.close() }
        }
    }

    /** A search's rows show while it runs with a spinner below them; the
     * same query again keeps them, and a new one clears them at once. */
    @Test fun aNewQueryClearsTheLastRowsAndTheSpinnerStaysUntilTheSearchEnds() = runBlocking {
        val rig = Rig()
        try {
            val row = JSONObject().put("threadID", JSONObject().put("hostID", UUID.randomUUID().toString())
                .put("providerID", JSONObject().put("rawValue", "claude")).put("providerSessionID", "s1"))
                .put("recordID", "r1").put("excerpt", "alpha row")
            val publish = AgentCenterPresenter::class.java
                .getDeclaredMethod("publishSearch", JSONArray::class.java, JSONArray::class.java).also { it.isAccessible = true }
            rig.onPresenter { it.search("alpha") }
            assertTrue(rig.presenter.state.value.searching)
            // No source holds a thread: the search ends having found nothing.
            rig.await { !it.searching }
            rig.onPresenter { publish.invoke(it, JSONArray().put(row), JSONArray()) }
            rig.await { it.searchResults.map { result -> result.recordID } == listOf("r1") }
            rig.onPresenter { it.search("alpha ") }
            rig.presenter.state.value.let { state ->
                assertTrue(state.searching)
                assertEquals("the same query keeps its rows while it runs", listOf("r1"), state.searchResults.map { it.recordID })
            }
            rig.onPresenter { it.search("beta") }
            rig.await { it.searching && it.searchResults.isEmpty() }
            rig.await { !it.searching && it.searchResults.isEmpty() }
            rig.onPresenter { it.search("") }
            assertFalse(rig.presenter.state.value.searching)
        } finally { rig.close() }
    }

    /** A search result opens at its match: a record not loaded is read
     * around from the live cursor, apart from the head; a refused seek, or
     * one already on screen, reads nothing more and keeps the newest page. */
    @Test fun aSearchResultOpensAtItsMatch() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            val key = rig.endpoint.threadKey("A")
            rig.onPresenter { it.select(key) }
            rig.await { it.projectedDetails[key]?.live?.any { block -> block.recordID == "record_handle_A" } == true }

            // Already loaded: the detail lands without a read.
            rig.onPresenter { it.openSearchResult(AgentSearchResultRow(key, "record_handle_A", "Ready", sequence = "1")) }
            assertEquals("record_handle_A", rig.presenter.state.value.searchLanding?.recordID)
            rig.drain()
            assertTrue(rig.endpoint.seekRequests.isEmpty())
            assertEquals("the landing waits for the detail to reach its row", "record_handle_A", rig.presenter.state.value.searchLanding?.recordID)

            // Refused (the record moved): no read status, the newest page stays.
            rig.endpoint.seekRefusal = "seekRecordMoved"
            rig.onPresenter { it.openSearchResult(AgentSearchResultRow(key, "match_handle_A", "Match", sequence = "0")) }
            rig.await { it.searchLanding == null }
            assertEquals(1, rig.endpoint.seekRequests.size)
            rig.presenter.state.value.let { state ->
                assertNull(state.ingestionReadStatuses[key])
                assertEquals("bootstrap", state.projectedDetails[key]?.window?.transition)
                assertTrue(state.projectedDetails[key]?.live?.any { block -> block.recordID == "record_handle_A" } == true)
            }

            // Read around the match from the live cursor; the landing waits
            // for the detail to reach its row.
            rig.endpoint.seekRefusal = null
            rig.onPresenter { it.openSearchResult(AgentSearchResultRow(key, "match_handle_A", "Match", sequence = "0", sourceOffset = "4096",
                seekToken = "0123456789abcdef:u-0")) }
            val landed = rig.await { it.projectedDetails[key]?.live?.any { block -> block.recordID == "match_handle_A" } == true }
            val seek = rig.endpoint.seekRequests.last()
            assertEquals(2, rig.endpoint.seekRequests.size)
            assertEquals("live_handle_A", seek.getString("cursor"))
            assertEquals(0L, seek.getLong("order"))
            assertEquals("match_handle_A", seek.getString("recordID"))
            assertEquals(4096L, seek.getLong("sourceOffset"))
            assertEquals("0123456789abcdef:u-0", seek.getString("seekToken"))
            assertEquals("seek", landed.projectedDetails[key]?.window?.transition)
            assertEquals(false, landed.projectedDetails[key]?.window?.atLiveHead)
            val landing = checkNotNull(landed.searchLanding)
            assertEquals(AgentSearchLanding(key, "match_handle_A", landing.id), landing)
            rig.onPresenter { it.finishSearchLanding(landing) }
            assertNull(rig.presenter.state.value.searchLanding)

            // An index the host rebuilt since the search names the match
            // anew: the landing follows the record at the match's order.
            rig.onPresenter { it.openSearchResult(AgentSearchResultRow(key, "rebuilt:0", "Match", sequence = "0", sourceOffset = "4096")) }
            val retargeted = rig.await { it.searchLanding?.recordID == "match_handle_A" && rig.endpoint.seekRequests.size == 3 }
            assertEquals("rebuilt:0", rig.endpoint.seekRequests.last().getString("recordID"))
            rig.onPresenter { it.finishSearchLanding(checkNotNull(retargeted.searchLanding)) }

            // Another match tapped here while a page applies lands there: the
            // page that arrives does not send the reader to the newest page.
            // The detail is open, so its window stays between reads.
            rig.onPresenter { it.setOpenDetail(key) }
            rig.endpoint.ackGate = CompletableDeferred()
            val seeks = rig.endpoint.seekRequests.size + 1
            rig.onPresenter { it.openSearchResult(AgentSearchResultRow(key, "stale:0", "Match", sequence = "0", sourceOffset = "4096")) }
            withTimeout(8_000) { while (!rig.endpoint.seekAcked(seeks)) delay(10) }
            val reads = rig.endpoint.pageReads.size
            rig.onPresenter { it.openSearchResult(AgentSearchResultRow(key, "match_handle_A", "Match", sequence = "0")) }
            checkNotNull(rig.endpoint.ackGate).complete(Unit)
            rig.endpoint.ackGate = null
            rig.await { key !in it.loadingTranscriptThreads }
            rig.drain()
            rig.presenter.state.value.let { state ->
                assertEquals("match_handle_A", state.searchLanding?.recordID)
                assertEquals("seek", state.projectedDetails[key]?.window?.transition)
            }
            assertEquals(reads, rig.endpoint.pageReads.size)
            rig.onPresenter { it.finishSearchLanding(checkNotNull(rig.presenter.state.value.searchLanding)) }

            // Refused from another match's page: the thread opens at its
            // newest page.
            rig.endpoint.seekRefusal = "seekRecordMoved"
            rig.onPresenter { it.openSearchResult(AgentSearchResultRow(key, "moved:5", "x", sequence = "5")) }
            rig.await { it.searchLanding == null && it.projectedDetails[key]?.window?.transition == "bootstrap" }
            assertEquals(reads + 1, rig.endpoint.pageReads.size)
            rig.endpoint.seekRefusal = null

            // A match left for another thread while its page applies: that
            // thread reads its newest page when chosen again.
            rig.endpoint.ackGate = CompletableDeferred()
            val left = rig.endpoint.seekRequests.size + 1
            rig.onPresenter { it.openSearchResult(AgentSearchResultRow(key, "match_handle_A", "Match", sequence = "0")) }
            withTimeout(8_000) { while (!rig.endpoint.seekAcked(left)) delay(10) }
            rig.onPresenter { it.select(null) }
            checkNotNull(rig.endpoint.ackGate).complete(Unit)
            rig.endpoint.ackGate = null
            rig.await { key !in it.loadingTranscriptThreads }
            rig.drain()
            assertEquals("seek", rig.presenter.state.value.projectedDetails[key]?.window?.transition)
            assertEquals(reads + 1, rig.endpoint.pageReads.size)
            rig.onPresenter { it.select(key) }
            rig.await { it.projectedDetails[key]?.window?.transition == "bootstrap" }
            assertEquals(reads + 2, rig.endpoint.pageReads.size)
            rig.onPresenter { it.setOpenDetail(null) }

            // Another thread's selection drops a landing still waiting.
            rig.onPresenter { it.openSearchResult(AgentSearchResultRow(key, "elsewhere", "x", sequence = "5")) }
            rig.onPresenter { it.select(null) }
            assertNull(rig.presenter.state.value.searchLanding)
        } finally { rig.close() }
    }

    /** A host from before seeks reads no page around a match: the result
     * opens at the newest page without reopening the thread for a seek. */
    @Test fun aSearchResultOnAHostThatCannotSeekOpensAtTheNewestPage() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.windowSeek = false
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            val key = rig.endpoint.threadKey("A")
            rig.onPresenter { it.select(key) }
            // The detail is open, so its window stays between reads.
            rig.onPresenter { it.setOpenDetail(key) }
            rig.await { it.projectedDetails[key]?.live?.any { block -> block.recordID == "record_handle_A" } == true }
            rig.drain()
            val reads = rig.endpoint.pageReads.size
            val unsubscribes = rig.endpoint.unsubscribes.size
            rig.onPresenter { it.openSearchResult(AgentSearchResultRow(key, "match_handle_A", "Match", sequence = "0", sourceOffset = "4096",
                seekToken = "0123456789abcdef:u-0")) }
            rig.await { it.searchLanding == null && key !in it.loadingTranscriptThreads }
            rig.drain()
            assertTrue(rig.endpoint.seekRequests.isEmpty())
            assertEquals("no read for the match: ${rig.endpoint.pageOperations}", reads, rig.endpoint.pageReads.size)
            assertEquals("the open thread is not reopened", unsubscribes, rig.endpoint.unsubscribes.size)
            rig.presenter.state.value.let { state ->
                assertNull(state.ingestionReadStatuses[key])
                assertEquals(true, state.projectedDetails[key]?.window?.atLiveHead)
                assertTrue(state.projectedDetails[key]?.live?.any { block -> block.recordID == "record_handle_A" } == true)
            }
            rig.onPresenter { it.setOpenDetail(null) }
        } finally { rig.close() }
    }

    /** A reader in history keeps their place when the app comes back: the new
     * connection reads around their row, unmarked, and the newest page it
     * starts from never shows. A seek cut off by leaving again keeps the
     * place, and the rows before, for the next connection. A refused seek
     * leaves the newest page, and a reader following it reads only that. */
    @Test fun aReaderInHistoryKeepsTheirPlaceAcrossANewConnection() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            val key = rig.endpoint.threadKey("A")
            rig.onPresenter { it.select(key); it.setOpenDetail(key) }
            rig.await { it.projectedDetails[key]?.live?.any { block -> block.recordID == "record_handle_A" } == true &&
                key !in it.loadingTranscriptThreads }
            rig.onPresenter { it.openSearchResult(AgentSearchResultRow(key, "match_handle_A", "Match", sequence = "0")) }
            val opened = rig.await { it.projectedDetails[key]?.window?.transition == "seek" && key !in it.loadingTranscriptThreads }
            rig.onPresenter { it.finishSearchLanding(checkNotNull(opened.searchLanding)) }
            // The detail reports the row its viewport starts at.
            rig.onPresenter { it.viewportAnchor(key, "match_handle_A") }
            rig.drain()
            suspend fun leave() = rig.onPresenter { it.setApplicationForeground(false) }
            suspend fun reconnect() = rig.onPresenter { it.setApplicationForeground(false); it.setApplicationForeground(true) }
            fun showsTheMatch(state: AgentCenterUiState) = state.projectedDetails[key]?.window?.transition == "seek" &&
                state.projectedDetails[key]?.live?.any { block -> block.recordID == "match_handle_A" } == true

            var gate = CompletableDeferred<Unit>().also { rig.endpoint.seekGate = it }
            val reads = rig.endpoint.pageReads.size
            reconnect()
            withTimeout(8_000) { while (rig.endpoint.seekRequests.size < 2) delay(10) }
            assertEquals("the new connection bootstraps first", reads + 1, rig.endpoint.pageReads.size)
            rig.presenter.state.value.let { state ->
                assertTrue("the rows before stay while the seek runs", showsTheMatch(state))
                val landing = checkNotNull(state.searchLanding)
                assertEquals(AgentSearchLanding(key, "match_handle_A", landing.id, marked = false), landing)
                assertTrue(key in state.loadingTranscriptThreads)
            }
            rig.endpoint.seekRequests.last().let { seek ->
                assertEquals("live_handle_A", seek.getString("cursor"))
                assertEquals(0L, seek.getLong("order"))
                assertEquals("match_handle_A", seek.getString("recordID"))
            }
            assertEquals("match_handle_A", rig.readerPlaces()[key]?.recordID)

            // Left again before the seek lands: the place, and the rows before,
            // wait for the next connection, with no landing left behind.
            leave()
            rig.drain()
            rig.presenter.state.value.let { state ->
                assertTrue(showsTheMatch(state))
                assertNull(state.searchLanding)
            }
            assertEquals("match_handle_A", rig.readerPlaces()[key]?.recordID)
            gate.complete(Unit)
            gate = CompletableDeferred<Unit>().also { rig.endpoint.seekGate = it }
            rig.onPresenter { it.setApplicationForeground(true) }
            withTimeout(8_000) { while (rig.endpoint.seekRequests.size < 3) delay(10) }
            assertTrue("Core's window holds the newest page by now; the kept place opens", showsTheMatch(rig.presenter.state.value))
            gate.complete(Unit)
            rig.endpoint.seekGate = null
            val placed = rig.await { key !in it.loadingTranscriptThreads }
            assertTrue(showsTheMatch(placed))
            assertEquals(false, placed.projectedDetails[key]?.window?.atLiveHead)
            assertTrue("the place landed", rig.readerPlaces().isEmpty())
            rig.onPresenter { it.finishSearchLanding(checkNotNull(placed.searchLanding)) }
            rig.drain()

            // Refused: the newest page shows and the landing ends.
            rig.endpoint.seekRefusal = "seekRecordMoved"
            reconnect()
            val refused = rig.await { rig.endpoint.seekRequests.size == 4 && key !in it.loadingTranscriptThreads && it.searchLanding == null }
            assertEquals("bootstrap", refused.projectedDetails[key]?.window?.transition)
            assertTrue(refused.projectedDetails[key]?.live?.none { block -> block.recordID == "match_handle_A" } == true)
            assertTrue(rig.readerPlaces().isEmpty())
            rig.endpoint.seekRefusal = null
            rig.drain()

            // Following the newest page: only it is read.
            rig.onPresenter { it.viewportAnchor(key, null) }
            val before = rig.endpoint.pageReads.size
            reconnect()
            withTimeout(8_000) { while (rig.endpoint.pageReads.size == before) delay(10) }
            rig.await { key !in it.loadingTranscriptThreads }
            rig.drain()
            assertEquals("only the newest page: ${rig.endpoint.pageOperations}", before + 1, rig.endpoint.pageReads.size)
            assertEquals(4, rig.endpoint.seekRequests.size)
            assertNull(rig.presenter.state.value.searchLanding)
            assertEquals("bootstrap", rig.presenter.state.value.projectedDetails[key]?.window?.transition)
            rig.onPresenter { it.setOpenDetail(null) }
        } finally { rig.close() }
    }

    /** A notification opens its conversation at the newest reply rather than
     * wait on a read of the reader's place. A place still shown on a live
     * connection stays; one being read gives way to the newest page that
     * read started from; one no read has reached yet is never read, even
     * when the detail reports its old row again. The next opening read ends
     * that: a place the reader takes later is read as before. */
    @Test fun aNotificationOpensTheNewestReplyRatherThanReadTheReadersPlace() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            val key = rig.endpoint.threadKey("A")
            rig.onPresenter { it.select(key); it.setOpenDetail(key) }
            rig.await { it.projectedDetails[key]?.live?.any { block -> block.recordID == "record_handle_A" } == true &&
                key !in it.loadingTranscriptThreads }
            suspend fun intoHistory() {
                rig.onPresenter { it.openSearchResult(AgentSearchResultRow(key, "match_handle_A", "Match", sequence = "0")) }
                val opened = rig.await { it.projectedDetails[key]?.window?.transition == "seek" && key !in it.loadingTranscriptThreads }
                rig.onPresenter { it.finishSearchLanding(checkNotNull(opened.searchLanding)); it.viewportAnchor(key, "match_handle_A") }
                rig.drain()
            }
            fun showsTheMatch(state: AgentCenterUiState) = state.projectedDetails[key]?.window?.transition == "seek" &&
                state.projectedDetails[key]?.live?.any { block -> block.recordID == "match_handle_A" } == true
            fun showsTheNewestPage(state: AgentCenterUiState) = state.projectedDetails[key]?.window?.transition == "bootstrap" &&
                state.projectedDetails[key]?.live?.none { block -> block.recordID == "match_handle_A" } == true
            intoHistory()

            // Still shown on a live connection: the place stays, unread.
            var reads = rig.endpoint.pageReads.size
            rig.onPresenter { it.openNotificationThread(key) }
            rig.drain()
            assertTrue(showsTheMatch(rig.presenter.state.value))
            assertNull(rig.presenter.state.value.latestOpening)
            assertEquals(reads, rig.endpoint.pageReads.size)
            assertEquals(1, rig.endpoint.seekRequests.size)

            // Opened while the new connection reads the place: the newest page
            // it read first shows at once, and the seek's reply is dropped.
            val gate = CompletableDeferred<Unit>().also { rig.endpoint.seekGate = it }
            rig.onPresenter { it.setApplicationForeground(false); it.setApplicationForeground(true) }
            withTimeout(8_000) { while (rig.endpoint.seekRequests.size < 2) delay(10) }
            rig.onPresenter { it.openNotificationThread(key) }
            rig.presenter.state.value.let { state ->
                assertTrue("the newest page, not the place: ${state.projectedDetails[key]?.window}", showsTheNewestPage(state))
                assertEquals("the detail follows the newest page", key, state.latestOpening)
                assertTrue("the dropped seek is not waited on", key !in state.loadingTranscriptThreads)
                assertNull(state.searchLanding)
            }
            assertTrue(rig.readerPlaces().isEmpty())
            gate.complete(Unit)
            rig.endpoint.seekGate = null
            val settled = rig.await { key !in it.loadingTranscriptThreads }
            rig.drain()
            assertTrue(showsTheNewestPage(rig.presenter.state.value))
            assertNull(settled.searchLanding)
            assertTrue(rig.readerPlaces().isEmpty())

            // Opened before the new connection reads anything: only the newest
            // page is read.
            intoHistory()
            val seeks = rig.endpoint.seekRequests.size
            rig.onPresenter { it.setApplicationForeground(false) }
            rig.onPresenter { it.openNotificationThread(key) }
            assertEquals(key, rig.presenter.state.value.latestOpening)
            // A detail mounting with its kept state reports the old row again.
            rig.onPresenter { it.viewportAnchor(key, "match_handle_A") }
            reads = rig.endpoint.pageReads.size
            rig.onPresenter { it.setApplicationForeground(true) }
            withTimeout(8_000) { while (rig.endpoint.pageReads.size == reads) delay(10) }
            rig.await { key !in it.loadingTranscriptThreads }
            rig.drain()
            assertEquals("only the newest page: ${rig.endpoint.pageOperations}", reads + 1, rig.endpoint.pageReads.size)
            assertEquals(seeks, rig.endpoint.seekRequests.size)
            assertTrue(showsTheNewestPage(rig.presenter.state.value))
            assertNull(rig.presenter.state.value.searchLanding)

            // A place the reader takes later is read as before.
            intoHistory()
            val later = rig.endpoint.seekRequests.size
            rig.onPresenter { it.setApplicationForeground(false); it.setApplicationForeground(true) }
            withTimeout(8_000) { while (rig.endpoint.seekRequests.size == later) delay(10) }
            rig.await { key !in it.loadingTranscriptThreads }
            rig.onPresenter { it.setOpenDetail(null) }
        } finally { rig.close() }
    }

    /** A match opened while a read is in flight waits for that read, which
     * may move the window, and is checked again when it ends. A reader who
     * leaves the match (the newest page, another thread) or a reset ends it. */
    @Test fun aSearchResultWaitsForTheReadInFlightAndYieldsToTheReader() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            val key = rig.endpoint.threadKey("A")
            rig.onPresenter { it.select(key) }
            rig.await { it.projectedDetails[key]?.live?.any { block -> block.recordID == "record_handle_A" } == true }
            rig.drain()
            val match = { record: String, sequence: String? -> AgentSearchResultRow(key, record, "x", sequence = sequence) }

            // A loaded match still waits for the read in flight, then needs none.
            rig.onPresenter {
                it.loadNewer(key, latest = true)
                it.openSearchResult(match("record_handle_A", "1"))
            }
            rig.drain()
            assertTrue(rig.endpoint.seekRequests.isEmpty())
            assertEquals("record_handle_A", rig.presenter.state.value.searchLanding?.recordID)

            // The newest page, chosen over a match still waiting, ends it,
            // and is read again once the read in flight ends.
            val reads = rig.endpoint.pageReads.size
            rig.onPresenter {
                it.loadNewer(key, latest = true)
                it.openSearchResult(match("match_handle_A", "0"))
                it.returnToLatest(key)
            }
            assertNull(rig.presenter.state.value.searchLanding)
            rig.await { rig.endpoint.pageReads.size == reads + 2 && key !in it.loadingTranscriptThreads &&
                it.projectedDetails[key]?.window?.transition == "bootstrap" }
            assertTrue(rig.endpoint.seekRequests.isEmpty())
            assertNull(rig.presenter.state.value.searchLanding)

            // Another thread's selection drops a match queued behind a read.
            rig.onPresenter {
                it.loadNewer(key, latest = true)
                it.openSearchResult(match("match_handle_A", "0"))
                it.select(null)
                it.select(key)
            }
            rig.drain()
            assertTrue(rig.endpoint.seekRequests.isEmpty())
            assertNull(rig.presenter.state.value.searchLanding)

            // Behind a read, a match it does not load is read around, at an
            // order no Long holds.
            rig.onPresenter {
                it.loadNewer(key, latest = true)
                it.openSearchResult(match("match_handle_A", "18446744073709551615"))
            }
            val landed = rig.await { it.projectedDetails[key]?.live?.any { block -> block.recordID == "match_handle_A" } == true }
            assertEquals(1, rig.endpoint.seekRequests.size)
            assertEquals("18446744073709551615", rig.endpoint.seekRequests.last().get("order").toString())
            assertEquals("seek", landed.projectedDetails[key]?.window?.transition)
            rig.drain()
            assertEquals("match_handle_A", rig.presenter.state.value.searchLanding?.recordID)

            // A reset ends a landing still waiting.
            rig.onPresenter { it.setApplicationForeground(false) }
            assertNull(rig.presenter.state.value.searchLanding)
        } finally { rig.close() }
    }

    /** In an open detail: rows whose window the host no longer holds show a
     * loaded match only after the read that replaces them; navigation asked
     * for after a loaded match still runs; and a reader who leaves a match
     * while its page is read (the newest page, another thread) keeps the
     * window they chose, the page given back unapplied. */
    @Test fun aSearchResultWaitsOnStaleRowsAndYieldsMidRead() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            val key = rig.endpoint.threadKey("A")
            rig.onPresenter { it.select(key); it.setOpenDetail(key) }
            rig.await { it.projectedDetails[key]?.live?.any { block -> block.recordID == "record_handle_A" } == true &&
                key !in it.loadingTranscriptThreads }
            rig.drain()
            val loaded = AgentSearchResultRow(key, "record_handle_A", "x", sequence = "1")
            val match = AgentSearchResultRow(key, "match_handle_A", "x", sequence = "0")
            suspend fun seekSent(count: Int) = withTimeout(8_000) { while (rig.endpoint.seekRequests.size < count) delay(10) }

            // The refresh that reads a closed window again shows no spinner;
            // a loaded match there waits for it, then needs no read.
            assertTrue(rig.nativeThreads(key).isNotEmpty())
            rig.nativeThreads(key).forEach { it.window = null }
            rig.onPresenter {
                it.refreshVisibleTranscript(key)
                assertFalse(key in it.state.value.loadingTranscriptThreads)
                it.openSearchResult(loaded)
                assertTrue("the detail waits for the read in flight", key in it.state.value.loadingTranscriptThreads)
            }
            rig.await { key !in it.loadingTranscriptThreads && rig.nativeThreads(key).all { thread -> thread.window != null } }
            rig.drain()
            assertTrue(rig.endpoint.seekRequests.isEmpty())
            assertEquals("record_handle_A", rig.presenter.state.value.searchLanding?.recordID)

            // The newest page asked for after a loaded match is still read.
            val before = rig.endpoint.pageReads.size
            rig.onPresenter {
                it.loadNewer(key, latest = true)
                it.openSearchResult(loaded)
                it.loadNewer(key, latest = true)
            }
            rig.await { rig.endpoint.pageReads.size == before + 2 && key !in it.loadingTranscriptThreads }
            assertEquals("record_handle_A", rig.presenter.state.value.searchLanding?.recordID)
            rig.drain()

            // The newest page, chosen while the match is read.
            var gate = CompletableDeferred<Unit>().also { rig.endpoint.seekGate = it }
            rig.onPresenter { it.openSearchResult(match) }
            seekSent(1)
            rig.onPresenter {
                assertTrue(key in it.state.value.loadingTranscriptThreads)
                it.returnToLatest(key)
            }
            assertNull(rig.presenter.state.value.searchLanding)
            // Every earlier read of the thread ended before the seek began.
            val reads = rig.endpoint.pageReads.size
            gate.complete(Unit)
            rig.await { rig.endpoint.pageReads.size == reads + 1 && key !in it.loadingTranscriptThreads }
            rig.drain()
            assertTrue("the match's page is given back unapplied",
                rig.endpoint.seekRequests.last().getString("id") in rig.endpoint.windowCancels)
            rig.presenter.state.value.projectedDetails[key].let { detail ->
                assertEquals("bootstrap", detail?.window?.transition)
                assertTrue(detail?.live?.none { block -> block.recordID == "match_handle_A" } == true)
            }

            // Another thread, chosen while the match is read.
            gate = CompletableDeferred<Unit>().also { rig.endpoint.seekGate = it }
            rig.onPresenter { it.openSearchResult(match) }
            seekSent(2)
            rig.onPresenter { it.select(null) }
            assertNull(rig.presenter.state.value.searchLanding)
            gate.complete(Unit)
            val second = rig.endpoint.seekRequests.last().getString("id")
            withTimeout(8_000) { while (second !in rig.endpoint.windowCancels) delay(10) }
            rig.drain()
            rig.onPresenter { it.select(key) }
            rig.drain()
            rig.presenter.state.value.projectedDetails[key].let { detail ->
                assertEquals("bootstrap", detail?.window?.transition)
                assertTrue(detail?.live?.none { block -> block.recordID == "match_handle_A" } == true)
            }
            assertNull(rig.presenter.state.value.searchLanding)
        } finally { rig.close() }
    }

    @Test fun paneProvidersRequireMatchingSnapshotCurrentRegistrationAndEnabledCenter() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX)) {
            val rig = Rig(transport)
            try {
                rig.endpoint.live("%75", 7, "claude")
                rig.frame("A", 7)
                val key = rig.endpoint.key
                val expected = mapOf(key to mapOf(75 to "claude"))
                withTimeout(8_000) { rig.presenter.paneAgentProviders.first { it == expected } }
                val owners = rig.owners().toMap()
                val details = rig.presenter.state.value.projectedDetails
                assertEquals(expected, rig.providers(details, owners))
                assertTrue(rig.providers(details, owners, enabled = false).isEmpty())
                assertTrue(rig.providers(emptyMap(), owners).isEmpty())
                assertTrue(rig.providers(details, emptyMap()).isEmpty())
                val threadKey = rig.endpoint.threadKey("A")
                val owner = owners.getValue(threadKey)
                val stale = JSONObject(owner.coreBindingJSON).put("agentPID", 999).toString()
                assertTrue(rig.providers(details, mapOf(threadKey to owner.copy(coreBindingJSON = stale))).isEmpty())
                val wrongGeneration = owner.copy(endpointKey = key.copy(carrierGeneration = 2))
                assertTrue(rig.providers(details, mapOf(threadKey to wrongGeneration)).isEmpty())
                // The same key and route on a replacement endpoint is a different registration.
                val replacement = object : AgentSessionEndpoint by rig.endpoint {}
                assertTrue(rig.providers(details, mapOf(threadKey to owner.copy(endpoint = replacement))).isEmpty())
                rig.onPresenter { it.setEnabled(false) }
                assertTrue(rig.presenter.paneAgentProviders.value.isEmpty())
            } finally { rig.close() }
        }
    }

    @Test fun paneProvidersSuppressDifferentProvidersButKeepSameProviderThreadsAndExactSessionKeys() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            withTimeout(8_000) { rig.presenter.paneAgentProviders.first { it.isNotEmpty() } }
            val key = rig.endpoint.threadKey("A")
            val detail = rig.presenter.state.value.projectedDetails.getValue(key)
            val owner = rig.owner("A")!!
            val sameOwners = linkedMapOf(key to owner, "same" to owner)
            val sameDetails = linkedMapOf(key to detail, "same" to detail)
            assertEquals(mapOf(rig.endpoint.key to mapOf(75 to "claude")), rig.providers(sameDetails, sameOwners))
            val codexID = JSONObject(owner.threadID).put("providerID", JSONObject().put("rawValue", "codex"))
            val ambiguousOwners = sameOwners + ("codex" to owner.copy(threadID = codexID.toString())) + ("last" to owner)
            val ambiguousDetails = sameDetails + ("codex" to detail.copy(row = detail.row.copy(providerID = "codex"))) + ("last" to detail)
            assertTrue(rig.providers(ambiguousDetails, ambiguousOwners).isEmpty())
            // A pane on another live session/carrier cannot consume this entry.
            val providers = rig.providers(sameDetails, sameOwners)
            assertNull(providers[rig.endpoint.key.copy(liveSessionID = "another-session")])
            assertNull(providers[rig.endpoint.key.copy(carrierGeneration = 2)])
            rig.endpoint.occupancy = AgentEndpointResult.Success(AgentOccupancySnapshot(emptyList(), allPaneIDs = emptyList()))
            rig.sweep()
            withTimeout(8_000) { rig.presenter.paneAgentProviders.first { it.isEmpty() } }
            assertTrue(rig.presenter.paneAgentProviders.value.isEmpty())
        } finally { rig.close() }
    }

    @Test fun refusedEndAndBlankExitRetireOnlyTheAbsentFieldOwner() = runBlocking {
        val rig = Rig()
        try {
            val endpoint = rig.endpoint
            endpoint.live("%75", 95076, "claude")
            rig.frame("A", 95076)
            rig.await { it.threads.map { row -> row.providerSessionID } == listOf("A") }
            endpoint.live("%75", 2, "claude")
            endpoint.occupancy = AgentEndpointResult.Failed("pending-field-observation")
            rig.forgetProofMemo()
            rig.frame("A", 95076, event = "SessionEnd")
            rig.frame("", null, event = "WrapperExit")
            rig.frame("B", 2)
            rig.await { it.threads.map { row -> row.providerSessionID }.toSet() == setOf("A", "B") }
            endpoint.occupancy = null
            rig.sweep()
            rig.await { it.threads.map { row -> row.providerSessionID } == listOf("B") }
            assertNull(rig.owner("A"))
            assertFalse(rig.sources().containsKey(endpoint.threadKey("A")))
            assertNotNull(rig.owner("B"))
            val refusals = rig.logs.filter { it.first == "agent_lifecycle_refused" }.map { it.second["detail"].orEmpty() }
            assertTrue("$refusals", refusals.any { "proof_exit_1" in it })
            assertTrue("$refusals", refusals.any { "blank-session-id" in it })
            // The list can publish B before the ordered retirement callback
            // emits its diagnostic; await that callback's own evidence.
            withTimeout(8_000) {
                while (rig.logs.none { it.first == "agent_route_retired" && it.second["pid"] == "95076" }) delay(10)
            }
            assertEquals(1, rig.logs.count { it.first == "agent_route_retired" && it.second["pid"] == "95076" })
            assertTrue(rig.logs.filter { it.first == "agent_route_retired" }.all { entry -> entry.second.values.none { '@' in it } })
        } finally { rig.close() }
    }

    @Test fun incompleteOrUnavailableOccupancyKeepsOwnersUntilACompletePaneList() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            val owner = rig.owner("A")!!
            for (observation in listOf<AgentEndpointResult<AgentOccupancySnapshot>>(
                AgentEndpointResult.Success(AgentOccupancySnapshot(listOf(AgentOccupancyPane("%75", true, false, emptyList())))),
                AgentEndpointResult.Success(AgentOccupancySnapshot(emptyList())),
                AgentEndpointResult.Failed("timeout"))) {
                rig.endpoint.occupancy = observation
                rig.sweep(); rig.drain()
                assertEquals(owner.bindingToken, rig.owner("A")?.bindingToken)
                assertEquals(listOf("A"), rig.presenter.state.value.threads.map { it.providerSessionID })
            }
            rig.endpoint.occupancy = AgentEndpointResult.Success(AgentOccupancySnapshot(emptyList(), allPaneIDs = emptyList()))
            rig.sweep()
            rig.await { it.threads.isEmpty() && it.selectedThreadKey == null }
            assertNull(rig.owner("A"))
        } finally { rig.close() }
    }

    @Test fun rawOccupancyRetiresTheMissingProviderWithoutATmuxPane() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH, AgentEndpointTransport.MOSH)) {
            val rig = Rig(transport)
            try {
                rig.endpoint.live(null, 7, "claude")
                rig.frame("A", 7, pane = null)
                rig.await { it.threads.size == 1 }
                rig.endpoint.live(null, 7, "codex")
                rig.sweep()
                rig.await { it.threads.isEmpty() }
                assertNull(rig.owner("A"))
            } finally { rig.close() }
        }
    }

    @Test fun occupancyReadBeforeANewOwnerIsInstalledCannotRetireThatOwner(): Unit = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            rig.endpoint.occupancyGate = entered to release
            val reading = async { rig.sweep() }
            withTimeout(8_000) { entered.await() }
            rig.endpoint.live("%75", 8, "claude")
            rig.frame("B", 8)
            rig.await { it.threads.map { row -> row.providerSessionID }.toSet() == setOf("A", "B") }
            release.complete(Unit)
            assertNull(reading.await())
            assertNotNull(rig.owner("B"))
            rig.sweep()
            rig.await { it.threads.map { row -> row.providerSessionID } == listOf("B") }
        } finally { rig.close() }
    }

    @Test fun provedBlankCodexRootRetiresItsRootAndChildAndSelection() = runBlocking {
        val rig = Rig(provider = "codex")
        try {
            rig.endpoint.live("%75", 7, "codex")
            rig.frame("root", 7)
            rig.await { it.threads.size == 1 }
            rig.frame("child", 7, event = "PermissionRequest", child = "worker")
            rig.await { it.threads.size == 2 }
            rig.onPresenter { it.select(rig.endpoint.threadKey("root")) }
            rig.frame("", 7)
            rig.await { it.threads.isEmpty() && it.selectedThreadKey == null && it.detail == null }
            assertNull(rig.owner("root")); assertNull(rig.owner("child"))
            assertTrue(rig.sources().isEmpty())
        } finally { rig.close() }
    }

    @Test fun blankClaudeAndUnprovedCodexDoNotClearLiveOwners() = runBlocking {
        for (provider in listOf("claude", "codex")) {
            val rig = Rig(provider = provider)
            try {
                rig.endpoint.live("%75", 7, provider)
                rig.frame("root", 7)
                rig.await { it.threads.size == 1 }
                val owner = rig.owner("root")!!
                rig.frame("", if (provider == "claude") 7 else null)
                rig.drain()
                assertEquals(owner.bindingToken, rig.owner("root")?.bindingToken)
                assertEquals(listOf("root"), rig.presenter.state.value.threads.map { it.providerSessionID })
            } finally { rig.close() }
        }
    }

    @Test fun unlocatableSuccessorRetiresThePredecessorWithoutCreatingARow() = runBlocking {
        for (provider in listOf("claude", "codex")) {
            val rig = Rig(provider = provider)
            try {
                rig.endpoint.live("%75", 7, provider)
                rig.frame("A", 7)
                rig.await { it.threads.size == 1 }
                rig.onPresenter { it.select(rig.endpoint.threadKey("A")) }
                rig.frame("B", 7, locatable = false)
                rig.await { it.threads.isEmpty() && it.selectedThreadKey == null }
                assertNull(rig.owner("A")); assertNull(rig.owner("B"))
                assertTrue(rig.logs.any { it.first == "agent_conversation_cleared" && it.second["detail"].orEmpty().contains("successor=unlocatable") })
                assertTrue(rig.logs.any { it.first == "agent_lifecycle_refused" && it.second["detail"].orEmpty().contains("v9-no-transcript") })
            } finally { rig.close() }
        }
    }

    @Test fun lateOrSameConversationWithoutALocatorKeepsTheHeldRoot() = runBlocking {
        for (provider in listOf("claude", "codex")) {
            val rig = Rig(provider = provider)
            try {
                rig.endpoint.live("%75", 7, provider)
                val started = System.nanoTime()
                rig.frame("A", 7, timestampNs = started)
                rig.await { it.threads.size == 1 }
                val owner = rig.owner("A")!!
                // The same conversation briefly without a locator is not a successor.
                rig.frame("A", 7, event = "UserPromptSubmit", locatable = false)
                // A replayed frame older than A's tenure cannot end it: the clear
                // carries its source timestamp and Core spares newer tenures.
                rig.frame("B", 7, locatable = false, timestampNs = started - 1_000_000)
                rig.drain()
                assertEquals(owner.bindingToken, rig.owner("A")?.bindingToken)
                assertEquals(listOf("A"), rig.presenter.state.value.threads.map { it.providerSessionID })
                // Another process in the pane is not this root's successor.
                rig.frame("C", 8, locatable = false)
                rig.drain()
                assertEquals(listOf("A"), rig.presenter.state.value.threads.map { it.providerSessionID })
                assertEquals(owner.bindingToken, rig.owner("A")?.bindingToken)
            } finally { rig.close() }
        }
    }

    @Test fun delayedRetirementOfAnOlderProofKeepsTheNewOwnerAndSource() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            val old = rig.owner("A")!!
            rig.holdRetirements = true
            rig.endpoint.capabilities.value = AgentEndpointCapabilities(lifecycleFeed = true, remoteData = true)
            rig.forgetProofMemo()
            rig.frame("A", 7)
            rig.await { it.threads.singleOrNull()?.providerSessionID == "A" && rig.owner("A")?.bindingToken != old.bindingToken }
            val newer = rig.owner("A")!!
            assertTrue(rig.heldRetirements.any { it.retirements.any { retired -> retired.bindingToken == old.bindingToken } })
            rig.releaseRetirements()
            assertEquals(newer.bindingToken, rig.owner("A")?.bindingToken)
            assertEquals(newer.endpointKey, rig.owner("A")?.endpointKey)
            assertTrue(rig.sources().containsKey(rig.endpoint.threadKey("A")))
        } finally { rig.close() }
    }

    @Test fun blankKimiWithoutConformanceStillTriggersAnOccupancySweep() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            rig.endpoint.live("%75", null, "claude")
            rig.frame("", 7, providerOverride = "kimi")
            rig.await { it.threads.isEmpty() }
            assertNull(rig.owner("A"))
            assertTrue(rig.logs.any { it.first == "agent_lifecycle_refused" && it.second["detail"].orEmpty().contains("blank-session-id") })
        } finally { rig.close() }
    }

    @Test fun capabilityChangeRetiresThePreviousConversationAndFollowsItsSuccessor() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            rig.onPresenter { it.select(rig.endpoint.threadKey("A")) }
            rig.endpoint.capabilities.value = AgentEndpointCapabilities(lifecycleFeed = true, remoteData = true)
            rig.frame("B", 7)
            rig.await { it.threads.map { row -> row.providerSessionID } == listOf("B") && it.selectedThreadKey == rig.endpoint.threadKey("B") }
            assertNull(rig.owner("A"))
            assertFalse(rig.sources().containsKey(rig.endpoint.threadKey("A")))
            assertFalse(rig.presenter.state.value.projectedDetails.containsKey(rig.endpoint.threadKey("A")))
        } finally { rig.close() }
    }

    @Test fun resumeKeepsALivePaneOwnerAndTransfersAfterItsProcessDisappears() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.endpoint.live("%76", 8, "claude")
            rig.frame("B", 7)
            rig.await { it.threads.size == 1 }
            val old = rig.owner("B")!!
            rig.frame("B", 8, pane = "%76")
            rig.drain()
            assertEquals(old.bindingToken, rig.owner("B")?.bindingToken)
            assertEquals("%75", rig.owner("B")?.endpointBinding?.paneID)
            assertNull(rig.presenter.state.value.notice)
            assertTrue(rig.logs.any { it.first == "agent_lifecycle_refused" && it.second["detail"].orEmpty().contains("bind_liveElsewhere") })
            rig.endpoint.live("%75", null, "claude")
            rig.frame("B", 8, pane = "%76")
            rig.await { it.threads.singleOrNull()?.providerSessionID == "B" && rig.owner("B")?.endpointBinding?.paneID == "%76" }
            assertNotEquals(old.bindingToken, rig.owner("B")?.bindingToken)
        } finally { rig.close() }
    }

    // O2: lifecycle recovery is independent of selection and of the old retry budget.
    @Test(timeout = 40_000) fun sameSourceLifecycleRenewsPendingAndExhaustedFirstReadBudgets() = runBlocking {
        for (exhausted in listOf(false, true)) {
            val rig = Rig(nativeReads = true)
            try {
                val key = rig.endpoint.threadKey("A")
                rig.endpoint.live("%75", 7, "claude")
                rig.endpoint.missingSources.add("A")
                // Neutral child hooks do not advance Core's summary sequence.
                // Acceptance must still correlate to their exact source.
                rig.frame("A", 7, event = if (exhausted) "SubagentStart" else "SessionStart")
                // The failed read can land before the snapshot publishes its detail.
                val failed = rig.await { it.ingestionReadStatuses[key]?.code == "sourceMissing" && it.projectedDetails[key] != null }
                val detail = requireNotNull(failed.projectedDetails[key])
                assertNull(agentVisibleReadStatus(failed.ingestionReadStatuses[key], transcriptShown = false,
                    hasLiveBinding = (detail.binding?.number("agentPID")?.toIntOrNull() ?: -1) > 1,
                    hasTranscriptMessages = detail.hasTranscriptMessages))
                if (exhausted) withTimeout(22_000) {
                    while (rig.endpoint.resolves.count { it == "A" } < 6 || rig.retryJobs().containsKey(key)) delay(20)
                }
                val owner = requireNotNull(rig.owner("A"))
                val reads = rig.endpoint.resolves.count { it == "A" }
                rig.frame("A", 7, event = if (exhausted) "SubagentStop" else "UserPromptSubmit")
                // Leave the source missing for the renewed immediate read, so
                // success subsequently requires a freshly armed bounded ladder.
                withTimeout(4_000) { while (rig.endpoint.resolves.count { it == "A" } <= reads ||
                    !rig.retryJobs().containsKey(key)) delay(10) }
                assertEquals(owner.bindingToken, rig.owner("A")?.bindingToken)
                rig.endpoint.missingSources.remove("A")
                rig.await { it.projectedDetails[key]?.live?.isNotEmpty() == true && it.ingestionReadStatuses[key] == null }
                assertEquals(reads + 2, rig.endpoint.resolves.count { it == "A" })
            } finally { rig.close() }
        }
    }

    @Test fun sameSourceLifecyclePreservesOtherManualFirstReadFailures() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            val key = rig.endpoint.threadKey("A")
            rig.endpoint.live("%75", 7, "claude")
            rig.endpoint.resolveFailureCodes["A"] = "sourceNotAuthorized"
            rig.frame("A", 7)
            val failed = rig.await { it.ingestionReadStatuses[key]?.code == "sourceNotAuthorized" }
            val status = failed.ingestionReadStatuses[key]
            rig.endpoint.resolveFailureCodes.remove("A")
            rig.frame("A", 7, event = "UserPromptSubmit")
            rig.drain()
            assertEquals(status, rig.presenter.state.value.ingestionReadStatuses[key])
            assertEquals(1, rig.endpoint.resolves.count { it == "A" })
            assertFalse(rig.retryJobs().containsKey(key))
        } finally { rig.close() }
    }

    @Test fun sourceMissingFirstReadRecoversWhileAnotherThreadIsSelected() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.endpoint.live("%76", 8, "claude")
            rig.endpoint.missingSources.add("A")
            rig.frame("A", 7)
            rig.await { it.ingestionReadStatuses[rig.endpoint.threadKey("A")]?.code == "sourceMissing" }
            rig.frame("C", 8, pane = "%76")
            rig.onPresenter { it.select(rig.endpoint.threadKey("C")) }
            rig.await { it.detail?.row?.providerSessionID == "C" && it.detail.live.isNotEmpty() }
            rig.endpoint.missingSources.remove("A")
            // The page lands before the bootstrap read returns and clears its status.
            rig.await { it.projectedDetails[rig.endpoint.threadKey("A")]?.live?.isNotEmpty() == true &&
                it.ingestionReadStatuses[rig.endpoint.threadKey("A")] == null }
            assertTrue(rig.endpoint.resolves.count { it == "A" } >= 2)
            assertEquals(rig.endpoint.threadKey("C"), rig.presenter.state.value.selectedThreadKey)
            assertNull(rig.presenter.state.value.ingestionReadStatuses[rig.endpoint.threadKey("A")])
        } finally { rig.close() }
    }

    @Test fun movingTheSamePaneToAnotherWindowRefreshesItsOwner() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            val before = rig.owner("A")!!
            rig.endpoint.binding.value = rig.endpoint.binding.value.copy(windowID = "@2")
            rig.frame("A", 7)
            rig.await { it.threads.singleOrNull()?.providerSessionID == "A" && rig.owner("A")?.endpointBinding?.windowID == "@2" }
            assertNotEquals(before.bindingToken, rig.owner("A")?.bindingToken)
            assertFalse(rig.logs.any { it.first == "agent_lifecycle_refused" && it.second["detail"].orEmpty().contains("bind_liveElsewhere") })
        } finally { rig.close() }
    }

    @Test fun aNewOwnerWithoutATranscriptTakesTheSourceItsPaneNamed() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            val key = rig.endpoint.threadKey("A")
            val before = rig.owner("A")!!
            assertEquals(before.bindingToken, rig.sourceToken(key))
            // An older integration names no transcript; the pane moved, so
            // the frame installs an owner with a new token.
            rig.endpoint.binding.value = rig.endpoint.binding.value.copy(windowID = "@2")
            rig.frame("A", 7, event = "UserPromptSubmit", locatable = false, version = 8)
            rig.await { rig.owner("A")?.bindingToken.let { it != null && it != before.bindingToken } }
            val after = rig.owner("A")!!
            assertEquals(after.bindingToken, rig.sourceToken(key))
            assertEquals(after.endpointKey, rig.sourceEndpoint(key))
        } finally { rig.close() }
    }

    @Test fun ownerRetirementCancelsFirstReadRecovery() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.endpoint.missingSources.add("A")
            rig.frame("A", 7)
            rig.await { it.ingestionReadStatuses[rig.endpoint.threadKey("A")]?.code == "sourceMissing" }
            rig.frame("B", 7)
            rig.await { it.threads.map { row -> row.providerSessionID } == listOf("B") && rig.owner("A") == null }
            val reads = rig.endpoint.resolves.count { it == "A" }
            delay(800)
            assertEquals(reads, rig.endpoint.resolves.count { it == "A" })
            assertFalse(rig.retryJobs().containsKey(rig.endpoint.threadKey("A")))
        } finally { rig.close() }
    }

    @Test fun sourceMissingOnTheFirstPageRecoversAfterResolveSucceeded() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.endpoint.missingPages.add("A")
            rig.frame("A", 7)
            rig.await { it.ingestionReadStatuses[rig.endpoint.threadKey("A")]?.code == "sourceMissing" }
            rig.endpoint.missingPages.remove("A")
            rig.await { it.projectedDetails[rig.endpoint.threadKey("A")]?.live?.isNotEmpty() == true &&
                it.ingestionReadStatuses[rig.endpoint.threadKey("A")] == null }
            assertEquals(listOf("A"), rig.endpoint.resolves.toList())
            assertTrue(rig.endpoint.pageReads.count { it == "A" } >= 2)
            assertNull(rig.presenter.state.value.ingestionReadStatuses[rig.endpoint.threadKey("A")])
        } finally { rig.close() }
    }

    @Test fun acceptedEndSchedulesOccupancyAfterTheProcessExits() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            rig.frame("A", 7, event = "SessionEnd")
            withTimeout(8_000) { while (rig.events.none { event ->
                event is SharedAgentRuntimeEvent.Snapshot && event.snapshot.payload.obj("thread")?.bool("conversationEnded") == true
            }) delay(10) }
            rig.endpoint.live("%75", null, "claude")
            rig.await { it.threads.isEmpty() }
            assertNull(rig.owner("A"))
        } finally { rig.close() }
    }

    @Test(timeout = 30_000) fun missingFirstReadExhaustsItsBudgetAndKeepsManualRetryStatus() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.endpoint.missingSources.add("A")
            rig.frame("A", 7)
            rig.await { it.ingestionReadStatuses[rig.endpoint.threadKey("A")]?.code == "sourceMissing" }
            withTimeout(22_000) { while (rig.endpoint.resolves.count { it == "A" } < 6 || rig.retryJobs().isNotEmpty()) delay(20) }
            assertEquals(6, rig.endpoint.resolves.count { it == "A" })
            assertEquals("manual", rig.presenter.state.value.ingestionReadStatuses[rig.endpoint.threadKey("A")]?.recovery)
            delay(600)
            assertEquals(6, rig.endpoint.resolves.count { it == "A" })
        } finally { rig.close() }
    }

    // A conversation a live pane holds was refused an observation binding, and
    // that ended the whole inventory pass: no later row was listed, and the
    // pass repeated every 10 s for as long as the pane lived.
    @Test fun inventoryListsTheRestPastAThreadALivePaneHolds() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            // Core still holds A's live route, but this endpoint no longer
            // presents it (its pane address went stale, say).
            rig.endpoint.routeCurrent = false
            rig.endpoint.inventory.addAll(listOf("A", "B", "C"))
            rig.startInventory()
            withTimeout(8_000) { while (listOf("B", "C").any { rig.endpoint.threadKey(it) !in rig.sources() }) delay(20) }
            rig.drain()
            assertEquals(1, rig.endpoint.inventoryPasses())
            assertTrue(rig.logs.none { it.second["reason"] == "inventory-failed" })
            assertTrue(rig.logs.any { it.second["reason"] == "live-threads-skipped" && it.second["count"] == "1" })
        } finally { rig.close() }
    }

    // Each pass walks every transcript on the host, and one ran every 10 s
    // even when nothing had changed. Rows admit in one list per page.
    @Test(timeout = 30_000) fun inventoryListsOncePerPageAndRunsAgainOnlyForAgentActivity() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            rig.presenter.successorBindGraceMillis = 300
            rig.endpoint.inventoryPageSize = 100
            repeat(250) { rig.endpoint.inventory.add("S%03d".format(it)) }
            val before = rig.lists()
            rig.startInventory()
            withTimeout(8_000) { while (rig.sources().size < 250) delay(20) }
            rig.drain()
            val lists = rig.lists() - before
            assertTrue("$lists list snapshots for 3 pages", lists <= 3 + 2)
            delay(1_000)
            assertEquals(1, rig.endpoint.inventoryPasses())
            rig.endpoint.inventory.add("T")
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("T", 7)
            withTimeout(5_000) { while (rig.endpoint.inventoryPasses() < 2) delay(20) }
            delay(1_000)
            assertEquals(2, rig.endpoint.inventoryPasses())
            // Every hook of a working agent asked again, so the whole host
            // catalog was walked and resent every interval. A conversation
            // held here asks for nothing, live or stored.
            rig.frame("T", 7, event = "PreToolUse")
            rig.endpoint.live("%76", 8, "claude")
            rig.frame("S007", 8, event = "UserPromptSubmit", pane = "%76")
            rig.await { state -> state.threads.map { it.providerSessionID }.toSet() == setOf("T", "S007") }
            delay(1_000)
            assertEquals(2, rig.endpoint.inventoryPasses())
            // A conversation its pane no longer hosts is history: list it.
            rig.frame("S010", 7)
            withTimeout(8_000) { while (rig.observed("T") != true) delay(20) }
            assertEquals(3, rig.endpoint.inventoryPasses())
            delay(1_000)
            assertEquals(3, rig.endpoint.inventoryPasses())
        } finally { rig.close() }
    }

    // A hook the presenter refuses (here a provider whose host integration
    // is unproven) repeats with every tool call, and each one asked again.
    @Test(timeout = 30_000) fun aRefusedConversationAsksForOnePass() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            rig.startInventory()
            withTimeout(8_000) { while (rig.endpoint.inventoryPasses() < 1) delay(20) }
            rig.drain()
            repeat(3) {
                rig.frame("K", 7, event = "PreToolUse", providerOverride = "kimi")
                delay(500)
            }
            assertEquals(3, rig.logs.count { it.second["detail"]?.endsWith("reason=kimi-not-conformant") == true })
            assertEquals(2, rig.endpoint.inventoryPasses())
            // Its first Stop asks once more: by then its transcript exists.
            repeat(2) {
                rig.frame("K", 7, event = "Stop", providerOverride = "kimi")
                delay(500)
            }
            assertEquals(3, rig.endpoint.inventoryPasses())
            // A first turn that ends in failure ends it too.
            for (event in listOf("PreToolUse", "StopFailure", "StopFailure")) {
                rig.frame("L", 7, event = event, providerOverride = "kimi")
                delay(500)
            }
            assertEquals(5, rig.endpoint.inventoryPasses())
        } finally { rig.close() }
    }

    // Core refuses an observation for an identity no thread can carry. Each
    // pass got the same answer and retried every interval for good.
    @Test(timeout = 30_000) fun aRowCoreCannotHoldEndsThePassLikeAnyOther() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            rig.endpoint.inventory.addAll(listOf("A", "B\u0007", "C"))
            rig.startInventory()
            withTimeout(8_000) { while (listOf("A", "C").any { rig.observed(it) != true }) delay(20) }
            rig.drain()
            delay(1_000)
            assertEquals(1, rig.endpoint.inventoryPasses())
            assertNull(rig.sources()[rig.endpoint.threadKey("B\u0007")])
            assertTrue(rig.logs.any { it.second["reason"] == "threads-unbound" && it.second["count"] == "1" })
        } finally { rig.close() }
    }

    // The host skips a transcript still being written and says so; the
    // client asked nothing more, so it stayed missing until an agent hooked.
    // One the host can never read while its agent keeps writing ends every
    // pass incomplete: one retry, not one every interval.
    @Test(timeout = 30_000) fun anIncompletePassListsOnceMore() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            rig.endpoint.inventory.add("S")
            rig.endpoint.incompletePasses = Int.MAX_VALUE
            rig.startInventory()
            withTimeout(8_000) { while (rig.endpoint.inventoryPasses() < 2) delay(20) }
            delay(1_000)
            assertEquals(2, rig.endpoint.inventoryPasses())
            assertEquals(1, rig.logs.count { it.first == "agent_native_inventory" && it.second["reason"] == "incomplete" })
        } finally { rig.close() }
    }

    // A pass may already have listed past what a request during it asks
    // about, so one more pass follows it.
    @Test(timeout = 30_000) fun aRequestDuringAPassRunsOneMore() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            val gate = CompletableDeferred<Unit>()
            rig.endpoint.inventoryGate = gate
            rig.startInventory()
            withTimeout(8_000) { while (rig.endpoint.inventoryPasses() < 1) delay(20) }
            rig.endpoint.inventory.add("T")
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("T", 7)
            rig.endpoint.inventoryGate = null
            gate.complete(Unit)
            withTimeout(8_000) { while (rig.endpoint.inventoryPasses() < 2) delay(20) }
            delay(1_000)
            assertEquals(2, rig.endpoint.inventoryPasses())
        } finally { rig.close() }
    }

    // A completed pass waits for agent activity, so a conversation started
    // elsewhere was missing from the list until an agent here did something.
    @Test(timeout = 30_000) fun openingTheAgentsScreenListsTheHostAgain() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            rig.endpoint.inventory.add("S")
            rig.startInventory()
            withTimeout(8_000) { while (rig.endpoint.threadKey("S") !in rig.sources()) delay(20) }
            rig.drain()
            delay(500)
            rig.endpoint.inventory.add("N")
            rig.onPresenter { it.activate() }
            withTimeout(8_000) { while (rig.endpoint.threadKey("N") !in rig.sources()) delay(20) }
            assertEquals(2, rig.endpoint.inventoryPasses())
        } finally { rig.close() }
    }

    // Two rows for one conversation (one rollout in two directories) failed
    // every pass, which retried every interval for good.
    @Test(timeout = 30_000) fun aConversationListedTwiceEndsThePassLikeAnyOther() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            rig.endpoint.inventory.addAll(listOf("A", "A#copy", "B"))
            rig.startInventory()
            withTimeout(8_000) { while (listOf("A", "B").any { rig.observed(it) != true }) delay(20) }
            rig.drain()
            delay(1_000)
            assertEquals(1, rig.endpoint.inventoryPasses())
            assertTrue(rig.logs.none { it.second["reason"] == "inventory-failed" })
        } finally { rig.close() }
    }

    // The tab asked to list a host was whichever came first, so one whose
    // carrier dropped (its every pass failing) kept a working tab unasked.
    @Test(timeout = 30_000) fun openingTheAgentsScreenAsksATabWhoseLastPassWorked() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            val host = UUID.randomUUID().toString()
            lateinit var failing: Endpoint
            lateinit var working: Endpoint
            do {
                failing = Endpoint(AgentEndpointTransport.SSH_TMUX, "claude", nativeReads = true, host = host)
                working = Endpoint(AgentEndpointTransport.SSH_TMUX, "claude", nativeReads = true, host = host)
                val order = java.util.concurrent.ConcurrentHashMap<AgentSessionKey, Unit>().apply {
                    put(failing.key, Unit); put(working.key, Unit) }.keys.toList()
            } while (order.indexOf(failing.key) > order.indexOf(working.key))
            listOf(failing, working).forEach(rig::register)
            failing.inventoryFails = true
            rig.startInventory(failing)
            rig.startInventory(working)
            withTimeout(8_000) { while (working.inventoryPasses() < 1 || failing.inventoryPasses() < 2) delay(20) }
            rig.drain()
            delay(500)
            val before = working.inventoryPasses()
            rig.onPresenter { it.activate() }
            delay(1_000)
            assertEquals(before + 1, working.inventoryPasses())
        } finally { rig.close() }
    }

    // Any one tab's pass lists its whole host; opening the screen ran one per tab.
    @Test(timeout = 30_000) fun openingTheAgentsScreenListsEachHostOnce() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            val other = Endpoint(AgentEndpointTransport.SSH_TMUX, "claude", nativeReads = true, host = rig.endpoint.binding.value.hostID)
            rig.register(other)
            listOf(rig.endpoint, other).forEach { tab -> tab.inventory.add("S"); rig.startInventory(tab) }
            withTimeout(8_000) { while (rig.endpoint.inventoryPasses() < 1 || other.inventoryPasses() < 1) delay(20) }
            rig.drain()
            delay(500)
            rig.onPresenter { it.activate() }
            delay(1_000)
            assertEquals(3, rig.endpoint.inventoryPasses() + other.inventoryPasses())
        } finally { rig.close() }
    }

    // Core replaces a thread's token before its successor binds. One that
    // never bound (a refused or superseded bind) left the conversation
    // unlisted until something else asked for a pass.
    @Test(timeout = 30_000) fun aConversationWhoseSuccessorNeverBindsIsListedAgain() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            rig.presenter.successorBindGraceMillis = 1_500
            rig.endpoint.inventory.add("S")
            rig.startInventory()
            withTimeout(8_000) { while (rig.observed("S") != true) delay(20) }
            rig.drain()
            rig.retireToSuccessor("S")
            assertNull(rig.owner("S"))
            // The successor usually binds at once: it gets the grace first.
            delay(500)
            assertEquals(1, rig.endpoint.inventoryPasses())
            withTimeout(8_000) { while (rig.observed("S") != true) delay(20) }
            assertEquals(2, rig.endpoint.inventoryPasses())
        } finally { rig.close() }
    }

    @Test(timeout = 30_000) fun aConversationWhoseSuccessorBindsAsksForNothing() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            rig.presenter.successorBindGraceMillis = 500
            rig.endpoint.inventory.add("S")
            rig.startInventory()
            withTimeout(8_000) { while (rig.observed("S") != true) delay(20) }
            rig.drain()
            val held = rig.retireToSuccessor("S")
            rig.onPresenter { rig.bindOwner("S", held) }
            delay(1_500)
            assertEquals(1, rig.endpoint.inventoryPasses())
        } finally { rig.close() }
    }

    // A pass lists no conversation another owner holds, and then waits. When
    // that owner left, nothing asked again: a closed tab's history left
    // search, and a killed pane's conversation never became history.
    @Test(timeout = 30_000) fun closingATabListsItsConversationsOnTheOtherTab() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            val others = List(2) { Endpoint(AgentEndpointTransport.SSH_TMUX, "claude", nativeReads = true,
                host = rig.endpoint.binding.value.hostID) }
            others.forEach(rig::register)
            repeat(50) { "S%03d".format(it).let { session -> (others + rig.endpoint).forEach { tab -> tab.inventory.add(session) } } }
            rig.startInventory()
            withTimeout(8_000) { while (rig.owners().size < 50) delay(20) }
            for (other in others) {
                rig.startInventory(other)
                withTimeout(8_000) { while (other.inventoryPasses() < 1) delay(20) }
            }
            rig.drain()
            assertTrue(rig.owners().values.all { it.endpointKey == rig.endpoint.key })
            val retired = rig.retirements()
            rig.vanish(rig.endpoint)
            withTimeout(8_000) { while (rig.owners().size < 50 || rig.owners().values.any { it.endpointKey == rig.endpoint.key }) delay(20) }
            rig.drain()
            // One small retirement per replaced token, all absorbed; no list each.
            assertEquals(50, rig.retirements() - retired)
            assertTrue(rig.retiredObservationTokens().isEmpty())
            delay(1_000)
            // Any tab's pass lists the whole host: one other tab lists it.
            assertEquals(3, others.sumOf { it.inventoryPasses() })
            assertEquals(1, rig.owners().values.map { it.endpointKey }.toSet().size)
        } finally { rig.close() }
    }

    // Tabs closing in one update: the first's owners asked the second, which
    // was closing too, and the ask was lost with it.
    @Test(timeout = 30_000) fun closingTwoTabsTogetherListsTheirConversationsOnTheThird() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            // The ask went to whichever same-host tab the map lists first:
            // make that the closing one, which hash order otherwise decides.
            lateinit var closing: Endpoint
            lateinit var staying: Endpoint
            do {
                closing = Endpoint(AgentEndpointTransport.SSH_TMUX, "claude", nativeReads = true, host = rig.endpoint.binding.value.hostID)
                staying = Endpoint(AgentEndpointTransport.SSH_TMUX, "claude", nativeReads = true, host = rig.endpoint.binding.value.hostID)
                val order = java.util.concurrent.ConcurrentHashMap<AgentSessionKey, Unit>().apply {
                    put(rig.endpoint.key, Unit); put(closing.key, Unit); put(staying.key, Unit) }.keys.toList()
            } while (order.indexOf(closing.key) > order.indexOf(staying.key))
            listOf(closing, staying).forEach(rig::register)
            repeat(20) { "S%03d".format(it).let { session -> listOf(rig.endpoint, closing, staying).forEach { tab -> tab.inventory.add(session) } } }
            rig.startInventory()
            withTimeout(8_000) { while (rig.owners().size < 20) delay(20) }
            for (tab in listOf(closing, staying)) {
                rig.startInventory(tab)
                withTimeout(8_000) { while (tab.inventoryPasses() < 1) delay(20) }
            }
            rig.drain()
            assertTrue(rig.owners().values.all { it.endpointKey == rig.endpoint.key })
            rig.vanish(rig.endpoint, closing)
            withTimeout(8_000) { while (rig.owners().size < 20 || rig.owners().values.any { it.endpointKey != staying.key }) delay(20) }
            assertEquals(2, staying.inventoryPasses())
        } finally { rig.close() }
    }

    @Test(timeout = 30_000) fun aKilledPanesConversationIsListedAsHistory() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            rig.endpoint.inventory.addAll(listOf("A", "B"))
            rig.startInventory()
            withTimeout(8_000) { while (rig.endpoint.threadKey("B") !in rig.sources()) delay(20) }
            rig.drain()
            assertEquals(1, rig.endpoint.inventoryPasses())
            rig.endpoint.occupancy = AgentEndpointResult.Success(AgentOccupancySnapshot(emptyList(), allPaneIDs = emptyList()))
            rig.sweep()
            rig.await { it.threads.isEmpty() }
            withTimeout(8_000) { while (rig.observed("A") != true) delay(20) }
            assertEquals(2, rig.endpoint.inventoryPasses())
        } finally { rig.close() }
    }

    // An owner that leaves while a pass runs asks for another only if that
    // pass already skipped its thread. A reconnect retires live panes while
    // the new carrier's pass lists, and each one ran a second pass.
    @Test(timeout = 30_000) fun aPaneKilledAfterThePassSkippedItsRowListsItOnceMore() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            rig.endpoint.inventory.addAll(listOf("A", "B"))
            rig.endpoint.inventoryPageSize = 1
            val gate = CompletableDeferred<Unit>()
            rig.endpoint.inventoryGates["after_1"] = gate
            rig.startInventory()
            withTimeout(8_000) { while ("after_1" !in rig.endpoint.inventoryCursors) delay(20) }
            rig.endpoint.occupancy = AgentEndpointResult.Success(AgentOccupancySnapshot(emptyList(), allPaneIDs = emptyList()))
            rig.sweep()
            rig.await { it.threads.isEmpty() }
            gate.complete(Unit)
            withTimeout(8_000) { while (rig.observed("A") != true) delay(20) }
            rig.drain()
            assertEquals(2, rig.endpoint.inventoryPasses())
        } finally { rig.close() }
    }

    // A pass waits out its interval before listing; requests made meanwhile
    // are answered by it rather than queueing one more.
    @Test(timeout = 30_000) fun requestsBeforeAPassListsAreAnsweredByIt() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 2_000
            rig.endpoint.inventory.add("S")
            rig.startInventory()
            withTimeout(8_000) { while (rig.endpoint.threadKey("S") !in rig.sources()) delay(20) }
            rig.drain()
            rig.onPresenter { it.activate() }
            delay(200)
            rig.onPresenter { it.activate() }
            withTimeout(8_000) { while (rig.endpoint.inventoryPasses() < 2) delay(20) }
            delay(3_000)
            assertEquals(2, rig.endpoint.inventoryPasses())
        } finally { rig.close() }
    }

    @Test(timeout = 30_000) fun aPaneKilledBeforeThePassReachesItsRowAsksForNoOtherPass() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            rig.endpoint.inventory.addAll(listOf("B", "A"))
            rig.endpoint.inventoryPageSize = 1
            val gate = CompletableDeferred<Unit>()
            rig.endpoint.inventoryGates["after_1"] = gate
            rig.startInventory()
            withTimeout(8_000) { while ("after_1" !in rig.endpoint.inventoryCursors) delay(20) }
            rig.endpoint.occupancy = AgentEndpointResult.Success(AgentOccupancySnapshot(emptyList(), allPaneIDs = emptyList()))
            rig.sweep()
            rig.await { it.threads.isEmpty() }
            gate.complete(Unit)
            withTimeout(8_000) { while (rig.observed("A") != true) delay(20) }
            rig.drain()
            delay(1_000)
            assertEquals(1, rig.endpoint.inventoryPasses())
        } finally { rig.close() }
    }

    // A reconnect tears the old carrier's owners down. One unbind per catalog
    // observation made Core publish a thread and a list snapshot for each
    // stored conversation, and the live pane's proof queued behind them all.
    @Test(timeout = 30_000) fun teardownRetiresCatalogObservationsWithoutAListEach() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.presenter.nativeInventoryIntervalMillis = 300
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            repeat(300) { rig.endpoint.inventory.add("S%03d".format(it)) }
            rig.startInventory()
            withTimeout(8_000) { while (rig.sources().size < 301) delay(20) }
            rig.drain()
            val lists = rig.lists()
            val threads = rig.threadSnapshots()
            rig.teardown()
            rig.await { it.threads.isEmpty() }
            rig.drain()
            assertTrue("${rig.lists() - lists} lists", rig.lists() - lists <= 4)
            assertTrue("${rig.threadSnapshots() - threads} thread snapshots", rig.threadSnapshots() - threads <= 2)
            assertNull(rig.owner("A"))
            // The same endpoint lists them again, and Core hands back the
            // tokens it still holds: their later retirement is a real one.
            withTimeout(8_000) { while (rig.sources().size < 300) delay(20) }
            rig.drain()
            assertEquals(2, rig.endpoint.inventoryPasses())
            assertTrue(rig.retiredObservationTokens().isEmpty())
            assertTrue(rig.presenter.state.value.projectedDetails.size <= 1)
            assertTrue(rig.logs.none { it.second["reason"] == "inventory-failed" })
        } finally { rig.close() }
    }

    private class Rig(transport: AgentEndpointTransport = AgentEndpointTransport.SSH_TMUX,
        provider: String = "claude", nativeReads: Boolean = false) {
        private val dispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        private val scope = CoroutineScope(SupervisorJob() + dispatcher)
        private val registry = LiveAgentSessionRegistry()
        private val coordinator = AndroidAgentSessionCoordinator(registry)
        private val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
        val endpoint = Endpoint(transport, provider, nativeReads)
        private val registrations = mutableMapOf<AgentSessionKey, AgentSessionRegistration>(endpoint.key to registry.register(endpoint))
        private val others = mutableListOf<Endpoint>()
        fun register(other: Endpoint) { registrations[other.key] = registry.register(other); others.add(other) }
        val logs = CopyOnWriteArrayList<Pair<String, Map<String, String>>>()
        val events = CopyOnWriteArrayList<SharedAgentRuntimeEvent>()
        val presenter = AgentCenterPresenter(coordinator, metadata(), unusedPreferences(), scope, integration,
            diagnostics = { event, fields -> logs.add(event to fields) })
        private val runtime = coordinator.runtime()
        @Volatile var holdRetirements = false
        val heldRetirements = CopyOnWriteArrayList<SharedAgentRuntimeEvent.RoutesRetired>()
        init {
            field("runtime").set(presenter, runtime)
            field("enabled").setBoolean(presenter, true)
            scope.launch { runtime.events.collect { event ->
                events.add(event)
                if (holdRetirements && event is SharedAgentRuntimeEvent.RoutesRetired) heldRetirements.add(event)
                else presenter.consume(event)
            } }
        }
        suspend fun frame(session: String, pid: Int?, event: String = "SessionStart", pane: String? = this.endpoint.binding.value.paneID,
            child: String? = null, endpoint: Endpoint = this.endpoint, providerOverride: String? = null,
            locatable: Boolean = true, timestampNs: Long = System.nanoTime(), version: Int = 9) = withContext(dispatcher) {
            val source = "/fixture/$session"
            val transcriptRef = Base64.getUrlEncoder().withoutPadding().encodeToString(source.encodeToByteArray())
            endpoint.sources[transcriptRef] = session
            presenter.consumeLifecycle(endpoint, AgentLifecycleFrame(endpoint.binding.value.copy(paneID = pane), JSONObject()
                .put("version", version).put("provider", providerOverride ?: endpoint.provider).put("event", event)
                .put("state", when (event) {
                    "PermissionRequest" -> "waitingForInput"
                    "SessionEnd", "WrapperExit", "StopFailure" -> "unavailable"
                    "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop" -> "working"
                    else -> "idle"
                })
                .put("timestampNs", "$timestampNs").put("sessionId", session).putOpt("agentPid", pid).putOpt("agentId", child)
                .put("transcriptRef", if (locatable) transcriptRef else "")
                .toString().encodeToByteArray()))
            Unit
        }
        suspend fun onPresenter(action: (AgentCenterPresenter) -> Unit) = withContext(dispatcher) { action(presenter) }
        suspend fun startInventory(endpoint: Endpoint = this.endpoint) = withContext(dispatcher) {
            AgentCenterPresenter::class.java.getDeclaredMethod("startNativeInventory", AgentSessionEndpoint::class.java)
                .also { it.isAccessible = true }.invoke(presenter, endpoint)
            Unit
        }
        /** The session observer's teardown of endpoints whose keys left the directory in one update. */
        suspend fun vanish(vararg endpoints: Endpoint) = withContext(dispatcher) {
            endpoints.forEach { registrations.remove(it.key)?.close() }
            AgentCenterPresenter::class.java.getDeclaredMethod("retireEndpoints", List::class.java)
                .also { it.isAccessible = true }.invoke(presenter, endpoints.map { it.key })
            Unit
        }
        /** Core replaced the session's token for the same thread; returns the retired owner. */
        suspend fun retireToSuccessor(session: String): AgentCenterPresenter.ThreadOwner = withContext(dispatcher) {
            val held = owner(session)!!
            AgentCenterPresenter::class.java.getDeclaredMethod("retireThreadOwner", String::class.java,
                AgentCenterPresenter.ThreadOwner::class.java, String::class.java)
                .also { it.isAccessible = true }.invoke(presenter, endpoint.threadKey(session), held, endpoint.threadKey(session))
            held
        }
        @Suppress("UNCHECKED_CAST") fun bindOwner(session: String, owner: AgentCenterPresenter.ThreadOwner) {
            (field("threadOwners").get(presenter) as MutableMap<String, AgentCenterPresenter.ThreadOwner>)[endpoint.threadKey(session)] = owner
        }
        fun retirements() = events.count { it is SharedAgentRuntimeEvent.RoutesRetired }
        @Suppress("UNCHECKED_CAST") fun retiredObservationTokens() = field("retiredObservationTokens").get(presenter) as Set<String>
        fun observed(session: String) = sources()[endpoint.threadKey(session)]?.let { source ->
            source.javaClass.getDeclaredField("hostObservation").also { it.isAccessible = true }.getBoolean(source) }
        fun lists() = events.count { it is SharedAgentRuntimeEvent.Snapshot && it.snapshot.kind == SharedAgentSnapshotKind.List }
        fun threadSnapshots() = events.count { it is SharedAgentRuntimeEvent.Snapshot && it.snapshot.kind == SharedAgentSnapshotKind.Thread }
        suspend fun teardown() = withContext(dispatcher) {
            AgentCenterPresenter::class.java.getDeclaredMethod("teardownEndpointOwners", AgentSessionKey::class.java)
                .also { it.isAccessible = true }.invoke(presenter, endpoint.key)
            Unit
        }
        suspend fun sweep() = withContext(dispatcher) { presenter.reconcileEndpointOccupancy(endpoint) }
        suspend fun observeEndpoint() = withContext(dispatcher) {
            scope.launch { presenter.observeEndpointEvents(endpoint) }
            endpoint.tmuxPaneRemovals.subscriptionCount.first { it > 0 }
        }
        suspend fun removalBurst() = withContext(dispatcher) {
            repeat(20) { endpoint.tmuxPaneRemovals.emit(Unit); yield() }
        }
        @Suppress("UNCHECKED_CAST") fun sweepJobs() = field("occupancySweepJobs").get(presenter) as Map<AgentSessionKey, Job>
        /** The thread's state on each open Agent Host connection. */
        fun nativeThreads(threadKey: String) = (field("ingestionHosts").get(presenter) as Map<*, *>).values
            .mapNotNull { (it as AgentCenterPresenter.NativeHost).threads[threadKey] }
        suspend fun drain() {
            withContext(dispatcher) { runtime.sendCanonical(JSONObject().put("v", 1).put("kind", "filter")
                .put("grouping", "host").toString().encodeToByteArray()) }
            delay(100)
        }
        suspend fun await(predicate: (AgentCenterUiState) -> Boolean): AgentCenterUiState =
            withTimeoutOrNull(8_000) { presenter.state.first(predicate) }
                ?: throw AssertionError("timed out; state=${presenter.state.value.threads.map { it.providerSessionID }} " +
                    "statuses=${presenter.state.value.ingestionReadStatuses} resolves=${endpoint.resolves} logs=${logs.takeLast(30)}")
        fun providers(
            details: Map<String, AgentThreadDetail>,
            owners: Map<String, AgentCenterPresenter.ThreadOwner>,
            enabled: Boolean = true,
        ) = derivePaneAgentProviders(enabled, details, owners, coordinator.directory)
        fun owner(session: String): AgentCenterPresenter.ThreadOwner? = owners()[endpoint.threadKey(session)]
        @Suppress("UNCHECKED_CAST") fun owners() = field("threadOwners").get(presenter) as Map<String, AgentCenterPresenter.ThreadOwner>
        @Suppress("UNCHECKED_CAST") fun sources() = field("projectionSources").get(presenter) as Map<String, *>
        @Suppress("UNCHECKED_CAST") fun readerPlaces() = field("readerPlaces").get(presenter) as Map<String, AgentSearchResultRow>
        private fun sourceField(key: String, name: String): Any? = sources()[key]?.let { source ->
            source.javaClass.getDeclaredField(name).also { it.isAccessible = true }.get(source)
        }
        fun sourceToken(key: String) = sourceField(key, "bindingToken") as String?
        fun sourceEndpoint(key: String) = sourceField(key, "endpointKey") as AgentSessionKey?
        @Suppress("UNCHECKED_CAST") fun retryJobs() = field("firstProjectionRetryJobs").get(presenter) as Map<String, Job>
        fun forgetProofMemo() {
            val memo = coordinator.javaClass.getDeclaredField("issuedRoutes").also { it.isAccessible = true }.get(coordinator)
            memo.javaClass.getDeclaredMethod("clear").also { it.isAccessible = true }.invoke(memo)
        }
        suspend fun releaseRetirements() = withContext(dispatcher) {
            holdRetirements = false
            heldRetirements.toList().forEach { presenter.consume(it) }; heldRetirements.clear()
        }
        suspend fun close() {
            withContext(NonCancellable + dispatcher) { presenter.close(); integration.close(); coordinator.close() }
            registrations.values.forEach { it.close() }; endpoint.close(); others.forEach { it.close() }; scope.cancel(); dispatcher.close()
        }
        private fun field(name: String) = AgentCenterPresenter::class.java.getDeclaredField(name).also { it.isAccessible = true }
    }

    private class Endpoint(transport: AgentEndpointTransport, val provider: String, private val nativeReads: Boolean = false,
        host: String = UUID.randomUUID().toString()) : AgentSessionEndpoint {
        override val key = AgentSessionKey(UUID.randomUUID().toString(), 1)
        private val tmux = transport.name.endsWith("TMUX")
        override val binding = MutableStateFlow(AgentEndpointBinding(key, host, transport,
            tmuxSession = if (tmux) "fixture" else null, windowID = if (tmux) "@1" else null, paneID = if (tmux) "%75" else null))
        override val ingestionBinding get() = binding.value.copy(windowID = null, paneID = null)
        override fun isCurrentIngestion(candidate: AgentEndpointBinding) = candidate.sameRouteAs(ingestionBinding)
        @Volatile var routeCurrent = true
        override fun isCurrentRoute(candidate: AgentEndpointBinding) = routeCurrent && candidate.copy(windowID = null, paneID = null).sameRouteAs(ingestionBinding)
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities(lifecycleFeed = true, remoteData = true,
            freshTerminalObservation = true, verifiedInput = true, semanticKeys = true))
        override val lifecycleFrames = MutableSharedFlow<AgentLifecycleFrame>()
        override val tmuxPaneRemovals = MutableSharedFlow<Unit>()
        @Volatile var occupancyReads = 0
        private val processes = java.util.concurrent.ConcurrentHashMap<String, List<AgentOccupancyProcess>>()
        @Volatile var occupancy: AgentEndpointResult<AgentOccupancySnapshot>? = null
        @Volatile var occupancyGate: Pair<CompletableDeferred<Unit>, CompletableDeferred<Unit>>? = null
        val sources = java.util.concurrent.ConcurrentHashMap<String, String>()
        val missingSources = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        val resolveFailureCodes = java.util.concurrent.ConcurrentHashMap<String, String>()
        val missingPages = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        val resolves = CopyOnWriteArrayList<String>()
        val pageReads = CopyOnWriteArrayList<String>()
        /** The operation of each read [pageReads] counts. */
        val pageOperations = CopyOnWriteArrayList<String>()
        /** Each `window.read` seek, as sent. */
        val seekRequests = CopyOnWriteArrayList<JSONObject>()
        /** Whether a host started from now on reads around a match (`window.seek.v1`). */
        @Volatile var windowSeek = true
        /** The thread handle of each `unsubscribe`. */
        val unsubscribes = CopyOnWriteArrayList<String>()
        /** A seek the host refuses with this status-less code. */
        @Volatile var seekRefusal: String? = null
        /** Holds each seek's reply until completed. */
        @Volatile var seekGate: CompletableDeferred<Unit>? = null
        /** Each `window.ack`, as sent; a gate holds each seek's ack reply until completed. */
        val windowAcks = CopyOnWriteArrayList<JSONObject>()
        @Volatile var ackGate: CompletableDeferred<Unit>? = null
        fun seekAcked(count: Int) = seekRequests.size >= count &&
            windowAcks.any { it.optString("transaction") == seekRequests[count - 1].getString("id") }
        /** Each `window.cancel`'s transaction. */
        val windowCancels = CopyOnWriteArrayList<String>()
        val inventory = CopyOnWriteArrayList<String>()
        @Volatile var inventoryPageSize = 500
        /** Holds each inventory reply until completed. */
        @Volatile var inventoryGate: CompletableDeferred<Unit>? = null
        /** Holds the reply to the page at that cursor until completed. */
        val inventoryGates = ConcurrentHashMap<String, CompletableDeferred<Unit>>()
        /** Passes whose last page reports a source skipped mid-write. */
        @Volatile var incompletePasses = 0
        /** Every inventory request fails, as on a dropped carrier. */
        @Volatile var inventoryFails = false
        /** Each inventory request's cursor; a pass starts without one. */
        val inventoryCursors = CopyOnWriteArrayList<String>()
        fun inventoryPasses() = inventoryCursors.count { it.isEmpty() }
        private val streams = CopyOnWriteArrayList<HostStream>()
        fun live(pane: String?, pid: Int?, provider: String) { processes[pane ?: "raw"] = pid?.let {
            listOf(AgentOccupancyProcess(it, AgentProofProvider.fromWire(provider)!!)) } ?: emptyList() }
        fun threadKey(session: String) = canonicalAgentThreadKey(binding.value.hostID, provider, session)
        override suspend fun observeOccupancy(bindings: List<AgentEndpointBinding>): AgentEndpointResult<AgentOccupancySnapshot> {
            occupancyReads++
            val observed = occupancy ?: AgentEndpointResult.Success(AgentOccupancySnapshot(bindings.map { route ->
                AgentOccupancyPane(route.paneID, true, true, processes[route.paneID ?: "raw"].orEmpty())
            }, processes.keys.toList().takeIf { tmux }))
            occupancyGate?.let { (entered, release) ->
                occupancyGate = null; entered.complete(Unit); release.await()
            }
            return observed
        }
        override suspend fun proveProcess(binding: AgentEndpointBinding, claimedPID: Int, provider: AgentProofProvider, requireForeground: Boolean): AgentEndpointResult<AgentProcessProof> =
            if (processes[binding.paneID ?: "raw"].orEmpty().any { it.pid == claimedPID && it.provider == provider })
                AgentEndpointResult.Success(AgentProcessProof(setOf(claimedPID), provider, "fixture-$claimedPID"))
            else AgentEndpointResult.Failed("proof_exit_1")
        override suspend fun execute(binding: AgentEndpointBinding, request: AgentExecRequest): AgentEndpointResult<AgentRemoteExecStream> =
            if (nativeReads) AgentEndpointResult.Success(HostStream().also(streams::add)) else unavailable()
        private inner class HostStream : AgentRemoteExecStream {
            private val frames = Channel<ByteArray>(Channel.UNLIMITED)
            private fun emit(value: JSONObject) { frames.trySend(AgentIngestionConnection.frame(value)) }
            private fun envelope(kind: String, id: String, handle: String = "") = JSONObject().put("kind", kind).put("id", id)
                .put("serviceEpoch", "lifecycle_epoch").put("thread", handle)
            init { emit(envelope("hello", "hello").put("v", 3).put("contextScope", "0000000000000001")
                .put("capabilities", JSONArray(listOf("bounded.windows", "window.partitions", "read.progress.v1") +
                    listOfNotNull("window.seek.v1".takeIf { windowSeek })))) }
            override val stdout = frames.receiveAsFlow()
            override val stderr: Flow<ByteArray> = flow { awaitCancellation() }
            override suspend fun awaitExit(): AgentExecExitStatus { awaitCancellation() }
            override suspend fun send(bytes: ByteArray) {
                val request = JSONObject(bytes.copyOfRange(4, bytes.size).decodeToString())
                val id = request.getString("id")
                val handle = request.optString("thread")
                when (request.getString("kind")) {
                    "resolve" -> {
                        val session = sources[request.getString("transcriptRef")]!!
                        resolves.add(session)
                        val failureCode = resolveFailureCodes[session] ?: "sourceMissing".takeIf { session in missingSources }
                        if (failureCode != null) emit(envelope("error", id).put("code", failureCode).put("status", JSONObject()
                            .put("v", 1).put("state", "failed").put("domain", "source").put("recovery", "manual").put("code", failureCode)))
                        else emit(envelope("resolved", id, "handle_$session").put("provider", provider).put("sessionID", session))
                    }
                    "inventory" -> {
                        val cursor = request.optString("cursor")
                        inventoryCursors.add(cursor)
                        inventoryGate?.await()
                        inventoryGates[cursor]?.await()
                        if (inventoryFails) { emit(envelope("error", id).put("code", "unavailable")); return }
                        val start = cursor.removePrefix("after_").toIntOrNull() ?: 0
                        val page = inventory.drop(start).take(inventoryPageSize)
                        emit(envelope("inventory.begin", id))
                        for (entry in page) {
                            // "A#copy" lists A again under another handle.
                            val session = entry.substringBefore('#')
                            val path = "/fixture/$session"
                            sources[Base64.getUrlEncoder().withoutPadding().encodeToString(path.encodeToByteArray())] = session
                            emit(envelope("inventory.thread", id, "handle_" + entry.replace('#', '_')).put("provider", provider)
                                .put("sessionID", session).put("transcriptRef", path).put("modified", System.currentTimeMillis() / 1_000))
                        }
                        val next = start + page.size
                        val incomplete = next >= inventory.size && incompletePasses > 0
                        if (incomplete) incompletePasses--
                        emit(envelope("inventory.end", id).put("hasMore", next < inventory.size)
                            .putOpt("cursor", "after_$next".takeIf { next < inventory.size })
                            .putOpt("incomplete", true.takeIf { incomplete }))
                    }
                    "window.read" -> {
                        val session = handle.removePrefix("handle_")
                        if (request.optString("operation") == "seek") {
                            seekRequests.add(request)
                            seekGate?.await()
                            seekRefusal?.let { emit(envelope("error", id, handle).put("code", it)); return }
                            // A history page around the match, apart from the head.
                            emit(envelope("page.begin", id, handle).put("sourceIdentity", "jsonl:$handle").put("operation", "history")
                                .put("from", request.getString("cursor")))
                            emit(envelope("page.record", id, handle).put("recordID", "match_$handle").put("revision", 1).put("order", 0)
                                .put("record", JSONObject().put("type", "message").put("role", "assistant").put("blocks", JSONArray()
                                    .put(JSONObject().put("type", "text").put("text", "Match $handle")))))
                            emit(envelope("page.end", id, handle).put("records", 1).put("hasOlder", false)
                                .put("backend", "jsonl").put("window", JSONObject().put("lane", "seek")
                                    .put("version", request.optLong("windowVersion") + 1).put("segmentID", "seek_$id")
                                    .put("before", "seek_before_$handle").put("after", "seek_after_$handle")
                                    .put("hasOlder", false).put("hasNewer", true)))
                            return
                        }
                        pageReads.add(session); pageOperations.add(request.optString("operation"))
                        if (session in missingPages) {
                            emit(envelope("error", id, handle).put("code", "sourceMissing").put("status", JSONObject()
                                .put("v", 1).put("state", "failed").put("domain", "source").put("recovery", "manual").put("code", "sourceMissing")))
                            return
                        }
                        emit(envelope("page.begin", id, handle).put("sourceIdentity", "jsonl:$handle").put("operation", "bootstrap"))
                        emit(envelope("page.record", id, handle).put("recordID", "record_$handle").put("revision", 1).put("order", 1)
                            .put("record", JSONObject().put("type", "message").put("role", "assistant").put("blocks", JSONArray()
                                .put(JSONObject().put("type", "text").put("text", "Ready $handle")))))
                        emit(envelope("page.end", id, handle).put("records", 1).put("hasOlder", false).put("hasNewer", false)
                            .put("liveCursor", "live_$handle").put("sourceEnd", 100).put("backend", "jsonl").put("window", JSONObject()
                                .put("lane", "bootstrap").put("version", request.optLong("windowVersion") + 1).put("segmentID", "segment_$id")
                                .put("before", "before_$handle").put("after", "after_$handle").put("hasOlder", false).put("hasNewer", false)))
                    }
                    "window.ack" -> {
                        windowAcks.add(request)
                        if (seekRequests.any { it.getString("id") == request.optString("transaction") }) ackGate?.await()
                        emit(envelope("window.acked", id, handle))
                    }
                    "window.cancel" -> windowCancels.add(request.getString("transaction"))
                    "summary" -> emit(envelope("summary", id, handle).put("revision", "1").put("modified", 1).put("records", JSONArray()))
                    "subscribe" -> emit(envelope("subscribed", id, handle))
                    "unsubscribe" -> { unsubscribes.add(handle); emit(envelope("ack", id, handle)) }
                    else -> emit(envelope("ack", id, handle))
                }
            }
            override fun cancel() { frames.close() }
            override fun close() = cancel()
        }
        override fun close() { streams.forEach { it.close() } }
        private fun unavailable() = AgentEndpointResult.Unavailable("synthetic lifecycle fixture")
        override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> = unavailable()
        override suspend fun processDiscoveryScope(binding: AgentEndpointBinding): AgentEndpointResult<AgentProcessDiscoveryScope> = unavailable()
        override suspend fun probeIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationStatus> = unavailable()
        override suspend fun readIntegrationConfigs(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationConfigSnapshots> = unavailable()
        override suspend fun installIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<SharedAgentIntegrationInstallOutcome> = unavailable()
        override suspend fun inspectCurrentShell(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentCurrentShellStatus> = unavailable()
        override suspend fun discoverProcesses(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentProcessDiscoverySnapshot> = unavailable()
        override suspend fun activateCurrentShell(binding: AgentEndpointBinding, expectedProcessIDs: Set<Int>, command: AgentShellActivationCommand): AgentEndpointResult<Unit> = unavailable()
        override suspend fun validatedDirectories(binding: AgentEndpointBinding): AgentEndpointResult<List<String>> = unavailable()
        override suspend fun sendInput(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit> = unavailable()
        override suspend fun sendSemanticKey(binding: AgentEndpointBinding, key: AgentSemanticKey): AgentEndpointResult<Unit> = unavailable()
        override suspend fun focus(binding: AgentEndpointBinding): AgentEndpointResult<Unit> = unavailable()
        override suspend fun placeTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement): AgentEndpointResult<AgentTmuxPlacementReceipt> = unavailable()
        override suspend fun launchTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement, requestID: String, request: ByteArray): AgentEndpointResult<AgentTmuxLaunchReceipt> = unavailable()
    }

    private companion object {
        fun metadata(): AndroidAgentMetadataRepository {
            val dao = Class.forName("com.bambouville.tessera.data.AgentMetadataDao")
            val empty = Proxy.newProxyInstance(dao.classLoader, arrayOf(dao)) { _, method, _ ->
                when (method.name) { "threads", "repairThreadKeys" -> emptyList<Any>(); "thread" -> null; else -> Unit }
            }
            return AndroidAgentMetadataRepository::class.java.getDeclaredConstructor(dao).also { it.isAccessible = true }
                .newInstance(empty)
        }
        // These tests attach only the runtime; no view-preference method is used.
        fun unusedPreferences(): AndroidAgentCenterViewPreferences {
            val unsafe = Unsafe::class.java.getDeclaredField("theUnsafe").also { it.isAccessible = true }.get(null) as Unsafe
            return unsafe.allocateInstance(AndroidAgentCenterViewPreferences::class.java) as AndroidAgentCenterViewPreferences
        }
    }
}
