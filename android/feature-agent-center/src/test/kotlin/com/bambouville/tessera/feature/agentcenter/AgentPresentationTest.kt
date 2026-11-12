package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest
import com.bambouville.tessera.core.bridge.SharedAgentReadStatus
import com.bambouville.tessera.core.bridge.SharedAgentSnapshot
import com.bambouville.tessera.core.bridge.SharedAgentSnapshotKind
import com.bambouville.tessera.core.bridge.SharedAgentValue
import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentSessionKey
import com.bambouville.tessera.agent.platform.AgentTmuxLaunchReceipt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONArray
import org.json.JSONObject
import java.util.TimeZone

class AgentPresentationTest {
    @Test fun artifactChangesRequireStructuredPathDiffAndHostIdentity() {
        val edit = AgentBlock("src/App.kt", "+ preview", "edit", path = "src/App.kt", diff = "+ complete")
        assertEquals(
            ArtifactOpenRequest.Change("saved-host", "src/App.kt", "+ complete", "src/App.kt", ArtifactOpenOrigin.AgentEdit, "live-session"),
            edit.artifactChange("saved-host", "live-session"),
        )
        assertNull(edit.artifactChange(" "))
        assertNull(edit.copy(path = null).artifactChange("host"))
        assertNull(edit.copy(path = " ").artifactChange("host"))
        assertNull(edit.copy(diff = null).artifactChange("host"))
        assertNull(edit.copy(diff = " ").artifactChange("host"))
        assertNull(edit.copy(kind = "text").artifactChange("host"))
    }

    @Test fun artifactChangesKeepTheDiffBeyondTheCollapsedCardPreview() {
        val diff = "+ a complete line in the edit\n".repeat(1_000)
        val thread = SharedAgentValue.ObjectValue(mapOf(
            "summary" to SharedAgentValue.ObjectValue(mapOf("id" to SharedAgentValue.ObjectValue(mapOf(
                "hostID" to SharedAgentValue.StringValue("host-a"),
                "providerID" to SharedAgentValue.StringValue("claude"),
                "providerSessionID" to SharedAgentValue.StringValue("session-a"),
            )))),
            "messages" to SharedAgentValue.ArrayValue(listOf(SharedAgentValue.ObjectValue(mapOf(
                "recordID" to SharedAgentValue.StringValue("edit-1"),
                "blocks" to SharedAgentValue.ArrayValue(listOf(SharedAgentValue.ObjectValue(mapOf(
                    "edit" to SharedAgentValue.ObjectValue(mapOf(
                        "path" to SharedAgentValue.StringValue("src/App.kt"),
                        "diff" to SharedAgentValue.StringValue(diff),
                    )),
                )))),
            )))),
        ))
        val detail = requireNotNull(AgentPresentation.detail(SharedAgentSnapshot(
            1, SharedAgentSnapshotKind.Thread, SharedAgentValue.ObjectValue(mapOf("thread" to thread)),
        )))
        val block = detail.live.single()
        assertTrue(block.body.length < diff.length)
        assertEquals(diff, requireNotNull(block.artifactChange(detail.row.hostID)).diff)
    }

    @Test fun seventyKiBDiffsWithTheSamePreviewProduceDistinctChangeOpensFromBothSources() {
        val prefix = "+".repeat(70 * 1024 - 1)
        val diffs = listOf(prefix + "a", prefix + "b")
        val edits = diffs.map { diff -> SharedAgentValue.ObjectValue(mapOf(
            "path" to SharedAgentValue.StringValue("src/App.kt"),
            "diff" to SharedAgentValue.StringValue(diff),
        )) }
        for (transcript in listOf(true, false)) {
            val fields = mutableMapOf<String, SharedAgentValue>(
                "summary" to SharedAgentValue.ObjectValue(mapOf("id" to SharedAgentValue.ObjectValue(mapOf(
                    "hostID" to SharedAgentValue.StringValue("host-a"),
                    "providerID" to SharedAgentValue.StringValue("claude"),
                    "providerSessionID" to SharedAgentValue.StringValue("session-a"),
                )))),
            )
            if (transcript) fields["messages"] = SharedAgentValue.ArrayValue(listOf(SharedAgentValue.ObjectValue(mapOf(
                "blocks" to SharedAgentValue.ArrayValue(edits.map { SharedAgentValue.ObjectValue(mapOf("edit" to it)) }),
            ))))
            else fields["changes"] = SharedAgentValue.ObjectValue(mapOf("edits" to SharedAgentValue.ArrayValue(edits)))
            val detail = requireNotNull(AgentPresentation.detail(SharedAgentSnapshot(1, SharedAgentSnapshotKind.Thread,
                SharedAgentValue.ObjectValue(mapOf("thread" to SharedAgentValue.ObjectValue(fields))))))
            val blocks = if (transcript) detail.live else detail.changes
            assertEquals(blocks[0].body, blocks[1].body)
            assertTrue(blocks.all { it.body.length <= if (transcript) 16_384 else 4_096 })
            val opens = blocks.map { requireNotNull(it.artifactChange(detail.row.hostID)) }
            assertEquals(2, opens.distinct().size)
            diffs.indices.forEach { index ->
                assertSame("the snapshot retains the payload string", diffs[index], blocks[index].diff)
                assertSame(diffs[index], opens[index].diff)
                assertEquals(70 * 1024, opens[index].diff.length)
            }
        }
    }

    @Test fun statusDotTonesMatchIOS() {
        assertEquals(AgentStatusDotTone.Green, agentStatusDotTone("working", "none"))
        assertEquals(AgentStatusDotTone.Green, agentStatusDotTone("finished", "unreadCompletion"))
        assertEquals(AgentStatusDotTone.Amber, agentStatusDotTone("waitingForInput", "none"))
        assertEquals(AgentStatusDotTone.Amber, agentStatusDotTone("working", "needsYou"))
        assertEquals(AgentStatusDotTone.Amber, agentStatusDotTone("idle", "needsYou"))
        assertEquals(AgentStatusDotTone.Faint, agentStatusDotTone("idle", "none"))
        assertEquals(AgentStatusDotTone.Faint, agentStatusDotTone("unavailable", "none"))
    }

    /** A host that stopped early is reported even when it returned matches:
     * they are partial. Host IDs compare case-insensitively, as Core's UUIDs
     * do, and result hosts and reported hosts together stay within four. */
    @Test fun aResultHostThatStoppedEarlyIsStillReported() {
        assertEquals(listOf("HOST-A", "host-b"), agentSearchUnavailableHosts(setOf("HOST-A", "host-b"), setOf("host-a")))
        assertEquals(listOf("host-a"), agentSearchUnavailableHosts(setOf("host-a", "HOST-A"), emptySet()))
        // Three result hosts leave one free slot; partial result hosts take none.
        assertEquals(listOf("host-d", "HOST-A", "host-c"), agentSearchUnavailableHosts(
            setOf("host-d", "HOST-A", "host-e", "host-c", "host-f"), setOf("host-a", "host-b", "HOST-C")))
        assertEquals(listOf("h1", "h2", "h3", "h4"), agentSearchUnavailableHosts(setOf("h1", "h2", "h3", "h4", "h5"), emptySet()))
    }

    /** A running search shows the rows it started with first, then what it
     * finds, each record once and within Core's per-host bound. */
    @Test fun aRunningSearchOnlyAddsRows() {
        fun result(host: String, session: String, record: String, excerpt: String = record) = JSONObject()
            .put("threadID", JSONObject().put("hostID", host).put("providerID", JSONObject().put("rawValue", "claude"))
                .put("providerSessionID", session))
            .put("recordID", record).put("excerpt", excerpt)
        val shown = JSONArray().put(result("h1", "s1", "r9", "shown"))
        val found = JSONArray().put(result("h1", "s2", "r1")).put(result("H1", "s1", "r9", "again")).put(result("h1", "s1", "r2"))
        val merged = agentSearchMerged(shown, found)
        assertEquals(listOf("r9", "r1", "r2"), (0 until merged.length()).map { merged.getJSONObject(it).getString("recordID") })
        assertEquals("shown", merged.getJSONObject(0).getString("excerpt"))
        val many = JSONArray().also { array -> repeat(150) { array.put(result("h2", "s", "m$it")) } }
        assertEquals(AGENT_SEARCH_HOST_RESULTS, agentSearchMerged(JSONArray(), many).length())
        // A later copy places a record the first could not; the first keeps
        // its place and excerpt, and a placed row is never re-placed.
        val placed = agentSearchMerged(shown, JSONArray().put(result("h1", "s1", "r9", "again").put("sequence", 37).put("sourceOffset", 4096)
            .put("seekToken", "0123456789abcdef:u-9")))
        assertEquals(1, placed.length())
        assertEquals("shown", placed.getJSONObject(0).getString("excerpt"))
        assertEquals(37, placed.getJSONObject(0).getInt("sequence"))
        assertEquals(4096, placed.getJSONObject(0).getInt("sourceOffset"))
        assertEquals("0123456789abcdef:u-9", placed.getJSONObject(0).getString("seekToken"))
        assertFalse("the shown row is not edited in place", shown.getJSONObject(0).has("sequence"))
        val kept = agentSearchMerged(placed, JSONArray().put(result("h1", "s1", "r9").put("sequence", 99)))
        assertEquals(37, kept.getJSONObject(0).getInt("sequence"))
        // A placed row without a token takes a later copy's whole position
        // when that one carries a token; one with a token keeps its own.
        val untokened = JSONArray().put(result("h1", "s1", "r9", "shown").put("sequence", 36).put("sourceOffset", 4000))
        val proven = agentSearchMerged(untokened, JSONArray().put(result("h1", "s1", "r9", "again").put("sequence", 37)
            .put("seekToken", "0123456789abcdef:u-9"))).getJSONObject(0)
        assertEquals("shown", proven.getString("excerpt"))
        assertEquals(37, proven.getInt("sequence"))
        assertFalse("an offset never joins another copy's order", proven.has("sourceOffset"))
        assertEquals("0123456789abcdef:u-9", proven.getString("seekToken"))
        val own = agentSearchMerged(placed, JSONArray().put(result("h1", "s1", "r9").put("sequence", 99)
            .put("seekToken", "fedcba9876543210:u-9"))).getJSONObject(0)
        assertEquals(37, own.getInt("sequence"))
        assertEquals("0123456789abcdef:u-9", own.getString("seekToken"))
        val untouched = agentSearchMerged(untokened, JSONArray().put(result("h1", "s1", "r9").put("sequence", 99))).getJSONObject(0)
        assertEquals(36, untouched.getInt("sequence"))
        assertEquals(4000, untouched.getInt("sourceOffset"))
    }

    /** Core refuses a search snapshot holding more than four result hosts,
     * which would drop the whole search: later hosts' matches are left out. */
    @Test fun searchResultsKeepTheFirstFourHosts() {
        val results = JSONArray()
        for ((host, record) in listOf("h1" to "a", "H1" to "b", "h2" to "c", "h3" to "d", "h4" to "e", "h5" to "f", "h2" to "g")) {
            results.put(JSONObject().put("threadID", JSONObject().put("hostID", host)).put("recordID", record))
        }
        val admitted = agentSearchResultsWithinHostCap(results)
        assertEquals(listOf("a", "b", "c", "d", "e", "g"), (0 until admitted.length()).map { admitted.getJSONObject(it).getString("recordID") })
    }

    @Test fun searchAcceptsCanonicalAndLegacyProviderIDs() {
        for (provider in listOf(
            SharedAgentValue.StringValue("pi"),
            SharedAgentValue.ObjectValue(mapOf("rawValue" to SharedAgentValue.StringValue("pi"))),
        )) {
            val result = SharedAgentValue.ObjectValue(mapOf(
                "threadID" to SharedAgentValue.ObjectValue(mapOf(
                    "hostID" to SharedAgentValue.StringValue("3EDA7C27-0E99-4B8D-9E2B-C7A2F2E2DF2A"),
                    "providerID" to provider,
                    "providerSessionID" to SharedAgentValue.StringValue("Session-A"),
                )),
                "recordID" to SharedAgentValue.StringValue("record-1"),
                "excerpt" to SharedAgentValue.StringValue("Readable reply"),
            ))
            val snapshot = SharedAgentSnapshot(1, SharedAgentSnapshotKind.Search, SharedAgentValue.ObjectValue(mapOf(
                "search" to SharedAgentValue.ObjectValue(mapOf("results" to SharedAgentValue.ArrayValue(listOf(result)))),
            )))
            val row = AgentPresentation.search(snapshot).first.single()
            assertEquals("3eda7c27-0e99-4b8d-9e2b-c7a2f2e2df2a:pi:Session-A", row.threadKey)
            assertEquals("Readable reply", row.excerpt)
            assertNull("a legacy result names no position", row.sequence)
        }
    }

    /** A result places its record for a seek with unsigned 64-bit decimal
     * strings; anything else places nothing. */
    @Test fun searchResultCarriesItsRecordsPosition() {
        fun row(sequence: SharedAgentValue?, offset: SharedAgentValue?, token: SharedAgentValue? = null): AgentSearchResultRow {
            val fields = mutableMapOf<String, SharedAgentValue>(
                "threadID" to SharedAgentValue.ObjectValue(mapOf(
                    "hostID" to SharedAgentValue.StringValue("3eda7c27-0e99-4b8d-9e2b-c7a2f2e2df2a"),
                    "providerID" to SharedAgentValue.ObjectValue(mapOf("rawValue" to SharedAgentValue.StringValue("claude"))),
                    "providerSessionID" to SharedAgentValue.StringValue("Session-A"),
                )),
                "recordID" to SharedAgentValue.StringValue("record-1"),
                "excerpt" to SharedAgentValue.StringValue("found it"),
            )
            sequence?.let { fields["sequence"] = it }
            offset?.let { fields["sourceOffset"] = it }
            token?.let { fields["seekToken"] = it }
            val snapshot = SharedAgentSnapshot(1, SharedAgentSnapshotKind.Search, SharedAgentValue.ObjectValue(mapOf(
                "search" to SharedAgentValue.ObjectValue(mapOf("results" to SharedAgentValue.ArrayValue(
                    listOf(SharedAgentValue.ObjectValue(fields))))))))
            return AgentPresentation.search(snapshot).first.single()
        }
        row(SharedAgentValue.NumberValue("4503599627370376"), SharedAgentValue.NumberValue("18446744073709551615")).let {
            assertEquals("4503599627370376", it.sequence)
            assertEquals("18446744073709551615", it.sourceOffset)
        }
        row(SharedAgentValue.NumberValue("37"), null).let {
            assertEquals("37", it.sequence)
            assertNull(it.sourceOffset)
            assertNull(it.seekToken)
        }
        row(SharedAgentValue.NumberValue("37"), null, SharedAgentValue.StringValue("0123456789abcdef:u-37")).let {
            assertEquals("0123456789abcdef:u-37", it.seekToken)
        }
        row(SharedAgentValue.NumberValue("-1"), SharedAgentValue.NumberValue("1.5")).let {
            assertNull(it.sequence)
            assertNull(it.sourceOffset)
        }
    }

    @Test fun canonicalThreadKeyNormalizesOnlyUuidHostCase() {
        val upperHost = "3EDA7C27-0E99-4B8D-9E2B-C7A2F2E2DF2A"
        val lowerHost = "3eda7c27-0e99-4b8d-9e2b-c7a2f2e2df2a"

        assertEquals(
            canonicalAgentThreadKey(lowerHost, "claude", "Session-A"),
            canonicalAgentThreadKey(upperHost, "claude", "Session-A"),
        )
        assertFalse(
            canonicalAgentThreadKey(upperHost, "claude", "Session-A") ==
                canonicalAgentThreadKey(upperHost, "claude", "session-a"),
        )
    }

    @Test fun listPreservesUnprovenLiveCandidatesAsTerminalOnlyFallbacks() {
        val candidate = SharedAgentValue.ObjectValue(mapOf(
            "id" to SharedAgentValue.ObjectValue(mapOf(
                "hostID" to SharedAgentValue.StringValue("host-a"),
                "providerID" to SharedAgentValue.ObjectValue(mapOf("rawValue" to SharedAgentValue.StringValue("claude"))),
                "sourceIdentity" to SharedAgentValue.StringValue("pane-%4"),
            )),
            "providerName" to SharedAgentValue.StringValue("Claude"),
            "title" to SharedAgentValue.StringValue("unproven terminal"),
            "hostDisplayLabel" to SharedAgentValue.StringValue("build host"),
            "fallback" to SharedAgentValue.ObjectValue(mapOf(
                "status" to SharedAgentValue.StringValue("waitingForInput"),
                "location" to SharedAgentValue.StringValue("main · pane %4"),
                "liveTail" to SharedAgentValue.StringValue("approval requested"),
                "binding" to SharedAgentValue.ObjectValue(mapOf(
                    "transport" to SharedAgentValue.StringValue("moshTmux"),
                    "agentPID" to SharedAgentValue.NumberValue("42"),
                    "capabilities" to SharedAgentValue.NumberValue("8"),
                )),
                "prompt" to SharedAgentValue.ObjectValue(mapOf(
                    "title" to SharedAgentValue.StringValue("Approve deployment"),
                    "token" to SharedAgentValue.ObjectValue(mapOf("rawValue" to SharedAgentValue.StringValue("candidate-token"))),
                    "options" to SharedAgentValue.ArrayValue(listOf(SharedAgentValue.ObjectValue(mapOf(
                        "id" to SharedAgentValue.StringValue("approve"),
                        "label" to SharedAgentValue.StringValue("Approve"),
                        "isDefault" to SharedAgentValue.BooleanValue(true),
                    )))),
                )),
            )),
        ))
        val snapshot = SharedAgentSnapshot(1, SharedAgentSnapshotKind.List, SharedAgentValue.ObjectValue(mapOf(
            "list" to SharedAgentValue.ObjectValue(mapOf("threads" to SharedAgentValue.ArrayValue(emptyList()), "candidates" to SharedAgentValue.ArrayValue(listOf(candidate)))),
        )))

        val rendered = AgentPresentation.candidates(snapshot).single()

        assertEquals("host-a:claude:pane-%4", rendered.key)
        assertEquals("moshTmux", rendered.binding?.string("transport"))
        assertEquals("approval requested", rendered.liveTail)
        assertEquals("Approve deployment", rendered.prompt?.title)
        assertTrue(rendered.canAnswerPrompt())
    }

    @Test fun candidateActionTokenMustNameTheFreshPromptSignature() {
        assertTrue(candidateActionTokenMatches("candidate-c2lnbmF0dXJl", "signature"))
        assertFalse(candidateActionTokenMatches("candidate-stale", "signature"))
    }

    @Test fun listUsesSharedOrderAndDoesNotInventActionAvailability() {
        val summary = SharedAgentValue.ObjectValue(mapOf(
            "id" to SharedAgentValue.ObjectValue(mapOf(
                "providerID" to SharedAgentValue.StringValue("claude"),
                "providerSessionID" to SharedAgentValue.StringValue("session-a"),
            )),
            "title" to SharedAgentValue.StringValue("review"),
            "providerName" to SharedAgentValue.StringValue("Claude"),
            "status" to SharedAgentValue.StringValue("waitingForInput"),
            "attention" to SharedAgentValue.StringValue("needsYou"),
            "hostDisplayLabel" to SharedAgentValue.StringValue("build host"),
            "permissionMode" to SharedAgentValue.StringValue("plan"),
            // 2024-01-01T00:00:00Z in JSONEncoder's Apple-reference seconds.
            "lastActivity" to SharedAgentValue.NumberValue("725760000"),
            "context" to SharedAgentValue.ObjectValue(mapOf("percentUsed" to SharedAgentValue.NumberValue("62.0"), "usedTokens" to SharedAgentValue.NumberValue("84320"))),
            "cost" to SharedAgentValue.ObjectValue(mapOf(
                "totalCost" to SharedAgentValue.NumberValue("1.20"),
                "linesAdded" to SharedAgentValue.NumberValue("14"),
                "linesRemoved" to SharedAgentValue.NumberValue("3"),
            )),
            "availability" to SharedAgentValue.ObjectValue(mapOf("actions" to SharedAgentValue.BooleanValue(false))),
        ))
        val snapshot = SharedAgentSnapshot(1, SharedAgentSnapshotKind.List, SharedAgentValue.ObjectValue(mapOf(
            "list" to SharedAgentValue.ObjectValue(mapOf("threads" to SharedAgentValue.ArrayValue(listOf(summary)))),
        )))

        val rows = AgentPresentation.list(snapshot)

        assertEquals(listOf("claude:session-a"), rows.map { it.key })
        assertFalse(rows.single().actionAvailable)
        assertEquals("build host", rows.single().host)
        assertEquals("plan", rows.single().permissionMode)
        assertEquals("62.0", rows.single().contextPercent)
        assertEquals("84320", rows.single().contextUsedTokens)
        assertEquals("1.20", rows.single().totalCost)
        assertEquals("14", rows.single().linesAdded)
        assertEquals("3", rows.single().linesRemoved)
        assertEquals(1_704_067_200_000L, rows.single().lastActivityMillis)
    }

    @Test fun derivedContextPercentDisplaysWholePercent() {
        assertEquals("16", "16.702736842105263".wholePercent())
        assertEquals("62", "62.0".wholePercent())
        assertEquals("100", "100".wholePercent())
    }

    @Test fun permissionModeUsesKnownDisplayLabelsAndHidesUnavailableValues() {
        assertEquals("default", agentPermissionModeDisplay("defaultMode"))
        assertEquals("auto", agentPermissionModeDisplay("auto"))
        assertEquals("plan", agentPermissionModeDisplay("plan"))
        assertEquals("read only", agentPermissionModeDisplay("readOnly"))
        assertEquals(null, agentPermissionModeDisplay("unavailable"))
        assertEquals(null, agentPermissionModeDisplay("provider-specific-mode"))
        assertEquals(null, agentPermissionModeDisplay(null))
    }

    /// The waterfall decides in shared Core and Android only mirrors it, but
    /// the mirror is where it can break: `AgentTitleProvenance` is an Int-backed
    /// Swift enum, so it crosses the ABI as a bare number. Reading it as a
    /// string would name every tier "placeholder" and ask the device model to
    /// summarise threads the agent had already titled. A title that failed to
    /// parse leaves the field absent or at the prompt tier, and both must still
    /// be offered for generation.
    @Test fun titleProvenanceCrossesTheAbiAsANumberAndNamesTheTierItActuallyIs() {
        val unwritten = SharedAgentValue.ObjectValue(mapOf(
            "id" to SharedAgentValue.ObjectValue(mapOf(
                "providerID" to SharedAgentValue.StringValue("claude"),
                "providerSessionID" to SharedAgentValue.StringValue("unwritten"),
            )),
            "title" to SharedAgentValue.StringValue("Claude"),
            "providerName" to SharedAgentValue.StringValue("Claude"),
        ))
        val prompted = SharedAgentValue.ObjectValue(mapOf(
            "id" to SharedAgentValue.ObjectValue(mapOf(
                "providerID" to SharedAgentValue.StringValue("claude"),
                "providerSessionID" to SharedAgentValue.StringValue("prompted"),
            )),
            "title" to SharedAgentValue.StringValue("why does the router drop mosh gestures"),
            "providerName" to SharedAgentValue.StringValue("Claude"),
            "titleProvenance" to SharedAgentValue.NumberValue("1"),
            "titleSeed" to SharedAgentValue.StringValue("why does the router drop mosh gestures"),
        ))
        val named = SharedAgentValue.ObjectValue(mapOf(
            "id" to SharedAgentValue.ObjectValue(mapOf(
                "providerID" to SharedAgentValue.StringValue("claude"),
                "providerSessionID" to SharedAgentValue.StringValue("named"),
            )),
            "title" to SharedAgentValue.StringValue("Mosh scroll routing"),
            "providerName" to SharedAgentValue.StringValue("Claude"),
            "titleProvenance" to SharedAgentValue.NumberValue("3"),
            "titleSeed" to SharedAgentValue.StringValue("why does the router drop mosh gestures"),
        ))
        val snapshot = SharedAgentSnapshot(1, SharedAgentSnapshotKind.List, SharedAgentValue.ObjectValue(mapOf(
            "list" to SharedAgentValue.ObjectValue(mapOf("threads" to SharedAgentValue.ArrayValue(listOf(unwritten, prompted, named)))),
        )))

        val rows = AgentPresentation.list(snapshot)

        assertEquals(listOf("placeholder", "prompt", "native"), rows.map { it.titleProvenance })
        assertEquals(listOf(null, "why does the router drop mosh gestures", "why does the router drop mosh gestures"), rows.map { it.titleSeed })
        val worthGenerating = rows.filter { it.titleProvenance in setOf("placeholder", "prompt") && it.titleSeed?.isNotBlank() == true }
        assertEquals(listOf("claude:prompted"), worthGenerating.map { it.key })
    }

    @Test fun promptIsSnapshotDerivedAndObserveOnlyBindingKeepsAnswerUnavailable() {
        val summary = SharedAgentValue.ObjectValue(mapOf(
            "id" to SharedAgentValue.ObjectValue(mapOf(
                "hostID" to SharedAgentValue.StringValue("host-a"),
                "providerID" to SharedAgentValue.StringValue("claude"),
                "providerSessionID" to SharedAgentValue.StringValue("session-a"),
            )),
            "availability" to SharedAgentValue.ObjectValue(mapOf("actions" to SharedAgentValue.BooleanValue(true))),
        ))
        val promptWire = SharedAgentValue.ObjectValue(mapOf(
            "token" to SharedAgentValue.ObjectValue(mapOf("rawValue" to SharedAgentValue.StringValue("opaque-token"))),
            "title" to SharedAgentValue.StringValue("Choose a deployment"),
            "options" to SharedAgentValue.ArrayValue(listOf(
                SharedAgentValue.ObjectValue(mapOf(
                    "id" to SharedAgentValue.StringValue("safe"),
                    "label" to SharedAgentValue.StringValue("Safe"),
                    "isDefault" to SharedAgentValue.BooleanValue(true),
                )),
            )),
        ))
        val prompt = SharedAgentValue.ObjectValue(mapOf(
            "actionPrompt" to SharedAgentValue.ObjectValue(mapOf("_0" to promptWire)),
        ))
        val thread = SharedAgentValue.ObjectValue(mapOf(
            "summary" to summary,
            "binding" to SharedAgentValue.ObjectValue(mapOf(
                "capabilities" to SharedAgentValue.NumberValue("1"),
            )),
            "messages" to SharedAgentValue.ArrayValue(listOf(SharedAgentValue.ObjectValue(mapOf(
                "blocks" to SharedAgentValue.ArrayValue(listOf(prompt)),
            )))),
        ))
        val snapshot = SharedAgentSnapshot(1, SharedAgentSnapshotKind.Thread, SharedAgentValue.ObjectValue(mapOf("thread" to thread)))

        val detail = requireNotNull(AgentPresentation.detail(snapshot))

        assertNotNull(detail.prompt)
        assertEquals("opaque-token", detail.prompt?.actionToken)
        assertEquals(listOf("safe"), detail.prompt?.options?.map { it.id })
        assertFalse(detail.canAnswerPrompt())
    }

    @Test fun promptRequiresAFreshCaptureWhoseSignatureTokenIsTheCards() {
        val row = AgentThreadRow(
            key = "host:claude:session", title = "t", provider = "Claude", model = null, preview = null,
            status = "waitingForInput", attention = "needsYou", location = "", queuedCount = null,
            isFork = false, actionAvailable = true, spawnAvailable = false, forkAvailable = false,
        )
        val detail = AgentThreadDetail(
            row, emptyList(), emptyList(), emptyList(),
            SharedAgentValue.ObjectValue(mapOf("capabilities" to SharedAgentValue.NumberValue("8"))),
            hasMore = false,
            prompt = AgentPrompt(
                "Continue?", null, livePromptActionToken("fresh-signature"), listOf(AgentPromptOption("yes", "Yes", true)),
                fresh = AgentFreshPrompt("fresh-signature", listOf(AgentFreshPromptOption("yes", "Yes", "1\r", true))),
            ),
        )

        assertTrue(detail.canAnswerPrompt())
        // The terminal's selection moves isDefault and a deferred card has no
        // options: only the signature token identifies the prompt.
        val prompt = requireNotNull(detail.prompt)
        assertTrue(detail.copy(prompt = prompt.copy(options = emptyList())).canAnswerPrompt())
        assertFalse(detail.copy(prompt = prompt.copy(fresh = AgentFreshPrompt("other-signature", emptyList()))).canAnswerPrompt())
        assertFalse(detail.copy(prompt = prompt.copy(fresh = null)).canAnswerPrompt())
        assertFalse(detail.copy(row = row.copy(actionAvailable = false)).canAnswerPrompt())
    }

    @Test fun aCardTokenNotDerivedFromTheFreshSignatureNeverEnablesAnswers() {
        val row = AgentThreadRow("key", "t", "Claude", null, null, "waitingForInput", "needsYou", "", null, false, true, false, false)
        val detail = AgentThreadDetail(
            row, emptyList(), emptyList(), emptyList(), null, false,
            prompt = AgentPrompt(
                "Continue?", null, "opaque", listOf(AgentPromptOption("yes", "Yes", true)),
                fresh = AgentFreshPrompt("fresh", listOf(AgentFreshPromptOption("yes", "Yes, proceed", "1\r", true))),
            ),
        )

        assertFalse(detail.canAnswerPrompt())
    }

    @Test fun detailMapsSharedMessageBlocksActivityDetailAndChangeEdits() {
        val summary = SharedAgentValue.ObjectValue(mapOf(
            "id" to SharedAgentValue.ObjectValue(mapOf(
                "hostID" to SharedAgentValue.StringValue("host-a"),
                "providerID" to SharedAgentValue.StringValue("claude"),
                "providerSessionID" to SharedAgentValue.StringValue("session-a"),
            )),
        ))
        val thread = SharedAgentValue.ObjectValue(mapOf(
            "summary" to summary,
            "messages" to SharedAgentValue.ArrayValue(listOf(SharedAgentValue.ObjectValue(mapOf(
                "recordID" to SharedAgentValue.StringValue("message-1"),
                "blocks" to SharedAgentValue.ArrayValue(listOf(SharedAgentValue.ObjectValue(mapOf(
                    "thinking" to SharedAgentValue.ObjectValue(mapOf("_0" to SharedAgentValue.StringValue("checking route proof"))),
                )))),
            )))),
            "activity" to SharedAgentValue.ArrayValue(listOf(SharedAgentValue.ObjectValue(mapOf(
                "id" to SharedAgentValue.StringValue("activity-1"),
                "kind" to SharedAgentValue.StringValue("system"),
                "title" to SharedAgentValue.StringValue("Process verified"),
                "detail" to SharedAgentValue.StringValue("PID belongs to pane %2"),
                // 2024-01-01T12:34:00Z in JSONEncoder's Apple-reference seconds.
                "displayTime" to SharedAgentValue.NumberValue("725805240"),
            )))),
            "changes" to SharedAgentValue.ObjectValue(mapOf("edits" to SharedAgentValue.ArrayValue(listOf(
                SharedAgentValue.ObjectValue(mapOf(
                    "id" to SharedAgentValue.StringValue("edit-1"),
                    "path" to SharedAgentValue.StringValue("Sources/App.kt"),
                    "additions" to SharedAgentValue.NumberValue("3"),
                    "deletions" to SharedAgentValue.NumberValue("1"),
                    "diff" to SharedAgentValue.StringValue("+ verified"),
                )),
            )))),
        ))

        val detail = requireNotNull(AgentPresentation.detail(SharedAgentSnapshot(
            1, SharedAgentSnapshotKind.Thread,
            SharedAgentValue.ObjectValue(mapOf("thread" to thread)),
        )))

        assertEquals(AgentBlock("thinking", "checking route proof", "thinking", "message-1"), detail.live.single())
        assertEquals("PID belongs to pane %2", detail.activity.single().body)
        assertEquals("system", detail.activity.single().kind)
        assertEquals(1_704_112_440_000L, detail.activity.single().displayTimeMillis)
        assertEquals("Sources/App.kt\n+3 −1\n+ verified", detail.changes.single().body)
        assertEquals("edit-1", detail.changes.single().recordID)
        assertEquals("Sources/App.kt", detail.changes.single().path)
        assertEquals("+ verified", detail.changes.single().diff)
        assertEquals(
            ArtifactOpenRequest.Change("host-a", "Sources/App.kt", "+ verified", "Sources/App.kt", ArtifactOpenOrigin.AgentEdit),
            detail.changes.single().artifactChange(detail.row.hostID),
        )
    }

    @Test fun detailDecodesEverySwiftCodableAgentBlockWithoutLeakingWireFieldNames() {
        fun wrapped(kind: String, payload: SharedAgentValue) = SharedAgentValue.ObjectValue(mapOf(kind to payload))
        fun unlabeled(kind: String, value: SharedAgentValue) = wrapped(kind, SharedAgentValue.ObjectValue(mapOf("_0" to value)))
        fun named(vararg fields: Pair<String, SharedAgentValue>) = SharedAgentValue.ObjectValue(mapOf(*fields))
        val summary = SharedAgentValue.ObjectValue(mapOf(
            "id" to SharedAgentValue.ObjectValue(mapOf(
                "hostID" to SharedAgentValue.StringValue("host-a"),
                "providerID" to SharedAgentValue.StringValue("codex"),
                "providerSessionID" to SharedAgentValue.StringValue("session-a"),
            )),
        ))
        val prompt = named(
            "title" to SharedAgentValue.StringValue("Continue deployment?"),
            "detail" to SharedAgentValue.StringValue("The target is production."),
            "options" to SharedAgentValue.ArrayValue(listOf(named("id" to SharedAgentValue.StringValue("yes"), "label" to SharedAgentValue.StringValue("Continue")))),
            "token" to named("rawValue" to SharedAgentValue.StringValue("opaque")),
        )
        val blocks = listOf(
            unlabeled("text", SharedAgentValue.StringValue("Hello from the user.")),
            unlabeled("thinking", SharedAgentValue.StringValue("Checking the route.")),
            wrapped("toolCall", named("name" to SharedAgentValue.StringValue("Read"), "preview" to SharedAgentValue.StringValue("AgentDomain.swift"))),
            wrapped("toolResult", named("preview" to SharedAgentValue.StringValue("file contents"), "truncated" to SharedAgentValue.BooleanValue(true))),
            wrapped("edit", named("path" to SharedAgentValue.StringValue("App.kt"), "diff" to SharedAgentValue.StringValue("+ fixed"))),
            unlabeled("permission", SharedAgentValue.StringValue("Allow write access")),
            unlabeled("question", SharedAgentValue.StringValue("Which host?")),
            unlabeled("queuedMessage", SharedAgentValue.StringValue("queued follow-up")),
            unlabeled("workflow", SharedAgentValue.StringValue("release")),
            wrapped("subagent", named("agentID" to SharedAgentValue.StringValue("child-1"), "agentType" to SharedAgentValue.StringValue("reviewer"))),
            unlabeled("systemEvent", SharedAgentValue.StringValue("route rebound")),
            unlabeled("completion", SharedAgentValue.Null),
            wrapped("attachment", named("name" to SharedAgentValue.StringValue("report.pdf"), "mediaType" to SharedAgentValue.StringValue("application/pdf"))),
            unlabeled("actionPrompt", prompt),
            unlabeled("workflowTasks", SharedAgentValue.ArrayValue(listOf(named(
                "id" to SharedAgentValue.StringValue("task-1"), "title" to SharedAgentValue.StringValue("Build"),
                "owner" to SharedAgentValue.StringValue("codex"), "state" to SharedAgentValue.StringValue("working"),
            )))),
            unlabeled("subagentGroup", SharedAgentValue.ArrayValue(listOf(named(
                "id" to SharedAgentValue.StringValue("child-1"), "type" to SharedAgentValue.StringValue("reviewer"),
                "summary" to SharedAgentValue.StringValue("checking Android"), "status" to SharedAgentValue.StringValue("working"),
            )))),
            wrapped("unknown", named("type" to SharedAgentValue.StringValue("bridge-session"))),
            unlabeled("compactSummary", SharedAgentValue.StringValue("Summary of the compacted conversation.")),
        )
        val thread = SharedAgentValue.ObjectValue(mapOf(
            "summary" to summary,
            "messages" to SharedAgentValue.ArrayValue(listOf(SharedAgentValue.ObjectValue(mapOf(
                "recordID" to SharedAgentValue.StringValue("message-7"),
                "role" to SharedAgentValue.StringValue("user"),
                // 2024-01-01T00:00:00Z in JSONEncoder's Apple-reference seconds.
                "displayTime" to SharedAgentValue.NumberValue("725760000"),
                "blocks" to SharedAgentValue.ArrayValue(blocks),
            )))),
        ))

        val rendered = requireNotNull(AgentPresentation.detail(SharedAgentSnapshot(
            1, SharedAgentSnapshotKind.Thread, SharedAgentValue.ObjectValue(mapOf("thread" to thread)),
        ))).live

        assertEquals("Hello from the user.", rendered[0].body)
        assertEquals("user", rendered[0].role)
        assertEquals(1_704_067_200_000L, rendered[0].displayTimeMillis)
        assertEquals("Read", rendered[2].title)
        assertEquals("AgentDomain.swift", rendered[2].body)
        assertEquals("result · truncated", rendered[3].title)
        assertEquals("App.kt", rendered[4].title)
        assertEquals("App.kt", rendered[4].path)
        assertEquals("+ fixed", rendered[4].diff)
        assertEquals("Allow write access", rendered[5].body)
        assertEquals("queued message", rendered[7].title)
        assertEquals("reviewer", rendered[9].title)
        assertEquals("finished", rendered[11].body)
        assertEquals("application/pdf", rendered[12].title)
        assertEquals("Continue deployment?", rendered[13].title)
        assertEquals("Build · codex · working", rendered[14].body)
        assertEquals("reviewer · working\n\nchecking Android", rendered[15].body)
        assertEquals("unsupported event", rendered[16].title)
        assertEquals("context compacted", rendered[17].title)
        assertEquals("Summary of the compacted conversation.", rendered[17].body)
        assertTrue(rendered.none { it.body.contains("_0:") || it.body.contains("type:") })
    }

    @Test fun timestampDisplayProjectionMatchesTheSharedDateABIAndIosTimeSemantics() {
        val value = SharedAgentValue.ObjectValue(mapOf(
            "lastActivity" to SharedAgentValue.NumberValue("725760000"),
            "invalid" to SharedAgentValue.NumberValue("NaN"),
        ))

        assertEquals(1_704_067_200_000L, value.agentABIDateMillis("lastActivity"))
        assertEquals(null, value.agentABIDateMillis("invalid"))
        assertEquals("2m ago", agentRelativeTime(1_704_067_200_000L, nowMillis = 1_704_067_320_000L, words = EnglishAgentRowWords))
        assertEquals("in 1h", agentRelativeTime(1_704_070_800_000L, nowMillis = 1_704_067_200_000L, words = EnglishAgentRowWords))
        assertEquals("12:34", agentDisplayTime(1_704_112_440_000L, TimeZone.getTimeZone("UTC")))
    }

    @Test fun missingFirstTranscriptIsHiddenOnlyForAnEmptyLiveConversation() {
        val missing = SharedAgentReadStatus("failed", "source", "manual", "sourceMissing",
            "The conversation could not be read.", isProgress = false, survivesReaderClosure = true)
        assertNull(agentVisibleReadStatus(missing, transcriptShown = false, hasLiveBinding = true))
        assertEquals(missing, agentVisibleReadStatus(missing, transcriptShown = false, hasLiveBinding = false))
        assertEquals(missing, agentVisibleReadStatus(missing, transcriptShown = true, hasLiveBinding = true))
        // An optimistic bubble/preview is not an ingested transcript message.
        assertNull(agentVisibleReadStatus(missing, transcriptShown = true, hasLiveBinding = true, hasTranscriptMessages = false))
        val other = missing.copy(code = "sourceNotAuthorized")
        assertEquals(other, agentVisibleReadStatus(other, transcriptShown = false, hasLiveBinding = true))
    }

    @Test fun messageWithoutRenderableBlocksStillCountsAsTranscriptContent() {
        val thread = SharedAgentValue.ObjectValue(mapOf(
            "summary" to SharedAgentValue.ObjectValue(mapOf("id" to SharedAgentValue.ObjectValue(mapOf(
                "hostID" to SharedAgentValue.StringValue("host"),
                "providerID" to SharedAgentValue.StringValue("claude"),
                "providerSessionID" to SharedAgentValue.StringValue("session"),
            )))),
            "messages" to SharedAgentValue.ArrayValue(listOf(SharedAgentValue.ObjectValue(mapOf(
                "blocks" to SharedAgentValue.ArrayValue(emptyList()),
            )))),
            "conversationEnded" to SharedAgentValue.BooleanValue(true),
        ))
        val detail = requireNotNull(AgentPresentation.detail(SharedAgentSnapshot(1, SharedAgentSnapshotKind.Thread,
            SharedAgentValue.ObjectValue(mapOf("thread" to thread)))))
        assertTrue(detail.live.isEmpty())
        assertTrue(detail.hasTranscriptMessages)
        assertTrue(detail.conversationEnded)
    }

    // A working agent's refreshes pass through "preparing" constantly. Over a
    // transcript on screen that row only moved the conversation up and down.
    @Test fun readProgressShowsOnlyWhileTheTranscriptIsEmpty() {
        for (state in listOf("preparing", "verifying")) {
            val progress = SharedAgentReadStatus(state, "source", "continue", "readPending", "Preparing conversation…", isProgress = true, survivesReaderClosure = false)
            assertEquals(null, agentVisibleReadStatus(progress, transcriptShown = true))
            assertEquals(progress, agentVisibleReadStatus(progress, transcriptShown = false))
        }
        val failure = SharedAgentReadStatus("failed", "source", "manual", "sourceNotAuthorized",
            "The conversation could not be read.", isProgress = false, survivesReaderClosure = true)
        assertEquals(failure, agentVisibleReadStatus(failure, transcriptShown = true))
        assertEquals(failure, agentVisibleReadStatus(failure, transcriptShown = false))
        assertEquals(null, agentVisibleReadStatus(null, transcriptShown = false))
    }

    @Test fun semanticBindingComparisonIgnoresJsonOrderButRejectsAnyChangedAddressField() {
        val leased = JSONObject()
            .put("liveSessionID", "live").put("carrierGeneration", 4)
            .put("incarnation", JSONObject().put("rawValue", "live:4:42"))
            .put("transport", "sshTmux").put("tmuxSession", "main")
            .put("windowID", "@1").put("paneID", "%2").put("agentPID", 42)
            .put("capabilities", 31)
        val reordered = JSONObject()
            .put("capabilities", 31).put("agentPID", 42)
            .put("paneID", "%2").put("windowID", "@1").put("tmuxSession", "main")
            .put("transport", "sshTmux").put("incarnation", JSONObject().put("rawValue", "live:4:42"))
            .put("carrierGeneration", 4).put("liveSessionID", "live")

        assertTrue(leased.sameCoreBinding(reordered))
        reordered.put("paneID", "%3")
        assertFalse(leased.sameCoreBinding(reordered))
    }

    @Test fun splitReceiptCorrelatesToLeasedPaneWhileDurableReceiptKeepsCreatedPane() {
        val leased = AgentEndpointBinding(
            AgentSessionKey("live", 4), "host", AgentEndpointTransport.SSH_TMUX,
            tmuxSession = "main", windowID = "@1", paneID = "%2",
        )
        val created = AgentTmuxLaunchReceipt("request", "@1", "%9", worktreeCreated = false)

        assertEquals("@1" to "%2", created.abiReceiptCoordinates(AgentLaunchPlacement.SplitRight, leased))
        assertEquals("@1" to "%9", created.abiReceiptCoordinates(AgentLaunchPlacement.NewWindow, leased))
    }

    @Test fun composerDraftClearsOnlyForItsAcceptedPlanAndPreservesNewTyping() {
        assertEquals("keep this", draftAfterActionPlan("keep this", "previous message"))
        assertEquals("", draftAfterActionPlan("sent", "sent"))
        assertEquals("  sent  ", draftAfterActionPlan("  sent  ", "sent"))
    }

    @Test fun notificationFenceUsesLiveCarrierRatherThanThreadDeliveryCounter() {
        val detail = AgentThreadDetail(
            row = AgentThreadRow("key", "t", "Claude", null, null, "working", "needsYou", "", null, false, false, false, false),
            live = emptyList(), activity = emptyList(), changes = emptyList(),
            binding = SharedAgentValue.ObjectValue(mapOf("carrierGeneration" to SharedAgentValue.NumberValue("17"))),
            hasMore = false,
            deliveryGeneration = 3,
        )

        assertEquals(17L, detail.liveCarrierGenerationOrNull())
    }

    @Test fun oneAttentionEntryIsOneDeliveryHoweverOftenTheGenerationMoves() {
        fun finished(generation: Long, epoch: Long) = SharedAgentSnapshot(1, SharedAgentSnapshotKind.Thread, SharedAgentValue.ObjectValue(mapOf(
            "thread" to SharedAgentValue.ObjectValue(mapOf(
                "summary" to SharedAgentValue.ObjectValue(mapOf(
                    "id" to SharedAgentValue.ObjectValue(mapOf(
                        "hostID" to SharedAgentValue.StringValue("host-a"),
                        "providerID" to SharedAgentValue.StringValue("claude"),
                        "providerSessionID" to SharedAgentValue.StringValue("session-a"),
                    )),
                    "status" to SharedAgentValue.StringValue("finished"),
                    "attention" to SharedAgentValue.StringValue("unreadCompletion"),
                )),
                "deliveryGeneration" to SharedAgentValue.NumberValue(generation.toString()),
                "attentionEpoch" to SharedAgentValue.NumberValue(epoch.toString()),
                "unreadCompletionKey" to SharedAgentValue.StringValue("c1:18d2c0189ee74548:2a"),
            )),
        )))

        // Stop, Claude's idle_prompt, then a rebind: three frames, one finish.
        val frames = listOf(finished(4, 1), finished(5, 1), finished(9, 1)).map { requireNotNull(AgentPresentation.detail(it)) }
        assertEquals(1L, frames.first().attentionEpoch)
        assertEquals("c1:18d2c0189ee74548:2a", frames.first().unreadCompletionKey)
        assertEquals(null, frames.first().acknowledgedCompletionKey)
        assertEquals(1, frames.mapNotNull { it.attentionDeliveryKey() }.toSet().size)
        // A later finish is a new alert.
        val next = requireNotNull(AgentPresentation.detail(finished(12, 2)))
        assertTrue(next.attentionDeliveryKey() !in frames.map { it.attentionDeliveryKey() })
    }
}
