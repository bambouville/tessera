package com.bambouville.tessera.core.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The restore decisions, checked through the bridge rather than in Kotlin.
 *
 * `ProtocolVectors/session/v1/restore-decisions.json` states each rule once.
 * `RestoreDecisionVectorTests` in `Packages/TesseraCore` pins it against the
 * Swift authority; this pins the same rows against what actually comes back
 * over JNI. Nothing here restates a rule — a Kotlin reimplementation would
 * only be a second authority to drift from.
 *
 * What it is really guarding is the marshalling, which is Android's alone and
 * has no other cover: milliseconds converted to seconds at the wrapper edge,
 * enums crossing as wire strings, an absent optional arriving as a missing key
 * rather than a null, and a `-1` that means invalid arguments, an undersized
 * buffer, or an unreachable state depending on the call.
 *
 * Device-only: a JVM test cannot dlopen the core.
 */
@RunWith(AndroidJUnit4::class)
class SharedRestoreDecisionVectorInstrumentedTest {
    private val hostA = "aaaaaaaa-1111-4111-8111-cafebabe1111"
    private val hostB = "bbbbbbbb-2222-4222-8222-cafebabe2222"

    private fun host(symbol: String?): String? = when (symbol) {
        "A" -> hostA
        "B" -> hostB
        else -> null
    }

    private val vectors: JSONObject by lazy {
        val stream = InstrumentationRegistry.getInstrumentation().context.assets
            .open("session/v1/restore-decisions.json")
        JSONObject(stream.bufferedReader().use { it.readText() })
    }

    private fun rows(name: String): List<JSONObject> {
        val array: JSONArray = vectors.getJSONArray(name)
        return (0 until array.length()).map(array::getJSONObject)
    }

    @Test
    fun verdictsMatchTheVectors() {
        val rows = rows("verdict")
        assertTrue("the vector file carries no verdict rows", rows.isNotEmpty())
        rows.forEach { row ->
            val sessionId = "33333333-3333-4333-8333-333333333333"
            val live = if (row.isNull("live")) {
                null
            } else {
                val it = row.getJSONObject("live")
                SharedRestoreLiveSession(
                    liveSessionId = sessionId,
                    persistedHostId = host(it.optionalString("host")),
                    state = SharedRestoreLiveState.entries
                        .first { state -> state.wireValue == it.getString("state") },
                    transportConfirmed =
                        if (it.isNull("transportConfirmed")) null else it.getBoolean("transportConfirmed"),
                )
            }
            assertEquals(
                row.getString("name"),
                row.getString("expected"),
                SharedSessionPolicy.restoreVerdict(
                    candidate = SharedRestoreCandidate(
                        liveSessionId = sessionId,
                        persistedHostId = host(row.optionalString("candidateHost")),
                    ),
                    live = live,
                    elapsedSinceWindowOpenedMilliseconds = row.getDouble("elapsedSeconds").toMilliseconds(),
                    aliveFloorMilliseconds = row.getDouble("aliveFloorSeconds").toMilliseconds(),
                ).wireValue,
            )
        }
    }

    @Test
    fun windowClosuresMatchTheVectors() {
        rows("windowClosure").forEach { row ->
            assertEquals(
                row.getString("name"),
                row.getString("expected"),
                SharedSessionPolicy.restoreWindowClosure(
                    remainingCohortCount = row.getInt("remainingCohortCount"),
                    elapsedSinceWindowOpenedMilliseconds = row.getDouble("elapsedSeconds").toMilliseconds(),
                    maxWindowMilliseconds = row.getDouble("maxWindowSeconds").toMilliseconds(),
                    hasUnansweredPrompt = row.getBoolean("hasUnansweredPrompt"),
                ).wireValue,
            )
        }
    }

    @Test
    fun chargeDeltasMatchTheVectors() {
        rows("chargeDelta").forEach { row ->
            assertEquals(
                row.getString("name"),
                row.getDouble("expected").toMilliseconds(),
                SharedSessionPolicy.restoreChargeDeltaMilliseconds(
                    nowMilliseconds = row.getDouble("nowSeconds").toMilliseconds(),
                    lastChargeAtMilliseconds =
                        if (row.isNull("lastChargeAtSeconds")) null
                        else row.getDouble("lastChargeAtSeconds").toMilliseconds(),
                    isPrompting = row.getBoolean("isPrompting"),
                    maxTickMilliseconds = row.getDouble("maxTickSeconds").toMilliseconds(),
                ),
            )
        }
    }

    @Test
    fun persistModesMatchTheVectors() {
        rows("persistMode").forEach { row ->
            assertEquals(
                row.getString("name"),
                row.getString("expected"),
                SharedSessionPolicy.restorePersistMode(
                    isActive = row.getBoolean("isActive"),
                    hasPreservedSnapshots = row.getBoolean("hasPreservedSnapshots"),
                    isWindowOpen = row.getBoolean("isWindowOpen"),
                    hasCohortEntries = row.getBoolean("hasCohortEntries"),
                ).wireValue,
            )
        }
    }

    @Test
    fun startupActionsMatchTheVectors() {
        val rows = rows("startupAction")
        assertTrue("the vector file carries no startup rows", rows.isNotEmpty())
        rows.forEach { row ->
            val expected = row.getJSONObject("expected")
            val sessions = sessionIdentifiers(
                strings(row.getJSONArray("candidates").let { array ->
                    JSONArray().also { out ->
                        (0 until array.length()).forEach { out.put(array.getJSONObject(it).getString("session")) }
                    }
                }) + listOfNotNull(row.optionalString("selectedSession")) +
                    strings(expected.optJSONArray("sessions")),
            )
            val candidates = row.getJSONArray("candidates").let { array ->
                (0 until array.length()).map { index ->
                    array.getJSONObject(index).let { candidate ->
                        SharedRestoreStartupCandidate(
                            sessionId = sessions.getValue(candidate.getString("session")),
                            hostId = host(candidate.getString("host"))!!,
                        )
                    }
                }
            }
            val action = SharedSessionPolicy.restoreStartupAction(
                candidates = candidates,
                hasDocument = row.getBoolean("hasDocument"),
                hostsLoaded = row.getBoolean("hostsLoaded"),
                availableHostIds = strings(row.getJSONArray("availableHosts")).mapNotNull(::host),
                liveHostIds = strings(row.getJSONArray("liveHosts")).mapNotNull(::host),
                selectedSessionId = row.optionalString("selectedSession")?.let(sessions::get),
                policy = SharedRestorePolicy.fromWire(row.getString("policy")),
            )
            val name = row.getString("name")
            when (action) {
                is SharedRestoreStartupAction.Wait -> {
                    assertEquals(name, "wait", expected.getString("action"))
                    assertEquals(name, expected.getString("reason"), action.reason.wireValue)
                }
                is SharedRestoreStartupAction.Skip -> {
                    assertEquals(name, "skip", expected.getString("action"))
                    assertEquals(name, expected.getString("reason"), action.reason.wireValue)
                }
                is SharedRestoreStartupAction.Restore -> {
                    assertEquals(name, "restore", expected.getString("action"))
                    assertPlan(name, action.plan, expected, sessions)
                }
                is SharedRestoreStartupAction.Offer -> {
                    assertEquals(name, "offer", expected.getString("action"))
                    assertPlan(name, action.plan, expected, sessions)
                }
            }
        }
    }

    @Test
    fun effectivePoliciesMatchTheVectors() {
        rows("effectivePolicy").forEach { row ->
            assertEquals(
                row.getString("name"),
                row.getString("expected"),
                SharedSessionPolicy.restoreEffectivePolicy(
                    stored = SharedRestorePolicy.fromWire(row.getString("stored")),
                    usesCompactShell = row.getBoolean("usesCompactShell"),
                ).wireValue,
            )
        }
    }

    @Test
    fun persistPlansMatchTheVectors() {
        val rows = rows("persistPlan")
        assertTrue("the vector file carries no persist-plan rows", rows.isNotEmpty())
        rows.forEach { row ->
            val expected = row.getJSONObject("expected")
            val expectedEntries = expected.getJSONArray("entries").let { array ->
                (0 until array.length()).map(array::getJSONObject)
            }
            val sessions = sessionIdentifiers(
                strings(row.getJSONArray("current")) + strings(row.getJSONArray("cohort")) +
                    strings(row.getJSONArray("stored")) +
                    listOfNotNull(
                        row.optionalString("preferredSelection"),
                        row.optionalString("storedSelection"),
                    ) +
                    expectedEntries.map { it.getString("session") },
            )
            val plan = SharedSessionPolicy.restorePersistPlan(
                mode = SharedRestorePersistMode.fromWire(row.getString("mode")),
                currentSessionIds = strings(row.getJSONArray("current")).map(sessions::getValue),
                cohortSessionIds = strings(row.getJSONArray("cohort")).map(sessions::getValue),
                storedSessionIds = strings(row.getJSONArray("stored")).map(sessions::getValue),
                preferredSelection = row.optionalString("preferredSelection")?.let(sessions::get),
                storedSelection = row.optionalString("storedSelection")?.let(sessions::get),
                maxSnapshots = row.getInt("maxSnapshots"),
            )
            val name = row.getString("name")
            assertEquals(
                name,
                expectedEntries.map { "${sessions.getValue(it.getString("session"))} ${it.getString("source")}" },
                plan.entries.map { "${it.sessionId} ${it.source.wireValue}" },
            )
            assertEquals(
                name,
                expected.optionalString("selectedSession")?.let(sessions::get),
                plan.selectedSessionId,
            )
        }
    }

    private fun assertPlan(
        name: String,
        plan: SharedRestoreStartupPlan,
        expected: JSONObject,
        sessions: Map<String, String>,
    ) {
        assertEquals(name, strings(expected.optJSONArray("sessions")).map(sessions::getValue), plan.sessionIds)
        assertEquals(name, expected.optionalString("selectedSession")?.let(sessions::get), plan.selectedSessionId)
        assertEquals(name, expected.optInt("skippedCount", 0), plan.skippedCount)
    }

    private fun strings(array: JSONArray?): List<String> =
        if (array == null) emptyList() else (0 until array.length()).map(array::getString)

    /**
      * Symbolic session names get fixed identifiers, so a vector that states an
      * order is testing the order and not a map's.
      *
      * Lower case, with hex letters, because that is what this platform writes
      * (`UUID.randomUUID().toString()`) and because Swift's `UUID` re-renders
      * in UPPER case on the way back. An id that comes home re-spelled matches
      * nothing in the store, and an all-digit fixture cannot show it.
      */
     private fun sessionIdentifiers(names: List<String>): Map<String, String> {
        val identifiers = LinkedHashMap<String, String>()
        names.forEach { name ->
            identifiers.getOrPut(name) { "abcdef0${identifiers.size}-dead-4bee-8fad-0123456789ab" }
        }
        return identifiers
    }

    /** A JSON null arrives as [JSONObject.NULL], and `optString(key, null)` is
     * a platform type Kotlin reads as non-null. */
    private fun JSONObject.optionalString(key: String): String? =
        if (isNull(key)) null else getString(key)

    private fun Double.toMilliseconds(): Long = Math.round(this * 1_000.0)
}
