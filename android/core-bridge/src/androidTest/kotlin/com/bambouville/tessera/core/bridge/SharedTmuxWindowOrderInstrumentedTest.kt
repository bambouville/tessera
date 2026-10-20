package com.bambouville.tessera.core.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises the window-order contract through the real Kotlin/JNI/Swift seam. */
@RunWith(AndroidJUnit4::class)
class SharedTmuxWindowOrderInstrumentedTest {
    @Test
    fun checkedInPlansCrossJniWithoutKotlinCommandDerivation() {
        val root = InstrumentationRegistry.getInstrumentation().context.assets
            .open("tmux/window-order-v1.json")
            .use { JSONObject(it.readBytes().decodeToString()) }
        val cases = root.getJSONArray("cases")
        org.junit.Assert.assertTrue("window ordering vectors must not be empty", cases.length() > 0)
        repeat(cases.length()) { index ->
            val vector = cases.getJSONObject(index)
            val request = vector.getJSONObject("request")
            val capabilities = request.getJSONObject("capabilities").let {
                SharedTmuxWindowCapabilities(
                    supportsMoveBefore = it.getBoolean("supportsMoveBefore"),
                    supportsSubscriptions = it.getBoolean("supportsSubscriptions"),
                )
            }
            fun ids(key: String): List<Int> = request.getJSONArray(key).let { values ->
                List(values.length()) { valueIndex ->
                    values.getString(valueIndex).removePrefix("@").toInt()
                }
            }
            val actualOrNull = SharedTmuxCommands.windowReorderPlan(
                    order = ids("order"),
                    moving = request.getString("moving").removePrefix("@").toInt(),
                    destination = request.getInt("destination"),
                    capabilities = capabilities,
                    sessionId = request.getString("sessionID").removePrefix("\$").toInt(),
                    activeWindowId = request.getString("activeWindowID").removePrefix("@").toInt(),
                    highestIndex = request.getInt("highestIndex"),
                )
            assertNotNull(actualOrNull)
            val actual = actualOrNull!!
            val expected = vector.getJSONObject("response")
            assertEquals(expected.getJSONArray("commands").strings(), actual.commands)
            assertEquals(
                expected.getJSONArray("expectedOrder").strings().map { it.removePrefix("@").toInt() },
                actual.expectedOrder,
            )
        }
    }

    @Test
    fun runtimeKeepsOptimismUntilItsCorrelatedFullListReply() {
        val events = mutableListOf<SharedTmuxEvent>()
        SharedTmuxRuntime.create { events += it }.use { runtime ->
            assertEquals(CoreCallResult.Accepted, runtime.feed(
                ("%session-changed \$7 work\r\n" + response(
                    sequence = 1,
                    rows = listOf(windowRow(1, 0), windowRow(2, 1)),
                )).encodeToByteArray(),
            ))

            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.ReorderBegan(token = 1, order = listOf(2, 1))),
            )
            assertTrue(events.last().snapshot.isReorderPending)
            assertEquals(listOf(2, 1), events.last().snapshot.windows.map { it.id })

            assertEquals(
                CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.ReorderConfirmed(token = 1)),
            )
            assertTrue(events.last().snapshot.isReorderPending)
            assertTrue(
                events.last().renderEffects.filterIsInstance<SharedTmuxRenderEffect.SendCommand>()
                    .single().command.contains("__tessera_windows__"),
            )

            assertEquals(CoreCallResult.Accepted, runtime.feed(
                (response(
                    sequence = 2,
                    rows = listOf(windowRow(2, 0), windowRow(1, 1)),
                ) + "%window-add @3\r\n").encodeToByteArray(),
            ))
            assertFalse(events.last().snapshot.isReorderPending)
            assertEquals(listOf(2, 1, 3), events.last().snapshot.windows.map { it.id })
        }
    }

    @Test
    fun anchorWindowSubscriptionReordersOnlyItsOwnSession() {
        val events = mutableListOf<SharedTmuxEvent>()
        SharedTmuxRuntime.create { events += it }.use { runtime ->
            assertEquals(CoreCallResult.Accepted, runtime.feed(
                ("%session-changed \$7 work\r\n" +
                    "%session-window-changed \$7 @1\r\n" +
                    response(1, listOf(windowRow(1, 0), windowRow(2, 1)))).encodeToByteArray(),
            ))
            assertEquals(CoreCallResult.Accepted, runtime.feed(
                "%subscription-changed tessera-window-order \$7 @1 0 - : 0=@2* 1=@1 \r\n"
                    .encodeToByteArray(),
            ))
            assertEquals(listOf(2, 1), events.last().snapshot.windows.map { it.id })
            assertEquals(1, events.last().snapshot.activeWindowId)

            assertEquals(CoreCallResult.Accepted, runtime.feed(
                "%subscription-changed tessera-window-order \$8 @1 0 - : 0=@1* 1=@2 \r\n"
                    .encodeToByteArray(),
            ))
            assertEquals(listOf(2, 1), events.last().snapshot.windows.map { it.id })
            assertEquals(1, events.last().snapshot.activeWindowId)
        }
    }

    @Test
    fun capabilitiesSubscriptionAndGroupSafetyCrossJni() {
        assertEquals(
            SharedTmuxWindowCapabilities(true, true),
            SharedTmuxCommands.windowCapabilities("3.2a"),
        )
        val events = mutableListOf<SharedTmuxEvent>()
        SharedTmuxRuntime.create { events += it }.use { runtime ->
            assertEquals(CoreCallResult.Accepted, runtime.setSubscriptions(SharedTmuxSubscriptions(windowOrder = true)))
            assertEquals(CoreCallResult.Accepted, runtime.feed(
                ("%session-changed \$7 work\r\n" + response(1, listOf(windowRow(1, 0)))).encodeToByteArray(),
            ))
            assertTrue(events.flatMap { it.subscriptionCommands }.isEmpty())
            assertEquals(CoreCallResult.Accepted, runtime.feed(
                response(2, listOf("__tessera_active_window__\t@1\t3.2a")).encodeToByteArray(),
            ))
            val commands = events.flatMap { it.subscriptionCommands }
            assertEquals(1, commands.size)
            assertTrue(commands.single().startsWith("refresh-client -B 'tessera-window-order:@1:"))
            assertEquals(CoreCallResult.Accepted, runtime.setSubscriptions(SharedTmuxSubscriptions()))
            assertEquals(listOf("refresh-client -B 'tessera-window-order'"), events.last().subscriptionCommands)
        }
        assertEquals(
            listOf(SharedTmuxSessionGroupMember(1, 10), SharedTmuxSessionGroupMember(2, 20)),
            SharedTmuxCommands.sessionGroupMembers(
                listOf("\$1\tteam\t@10", "\$2\tteam\t@20", "\$3\tother\t@30"),
                containingSessionId = 2,
            ),
        )
        assertNull(
            SharedTmuxCommands.sessionGroupMembers(
                listOf("\$1\tteam\t@10\nkill-server"),
                containingSessionId = 1,
            ),
        )
        val plan = SharedTmuxCommands.renumberPlan(
            listOf(SharedTmuxSessionGroupMember(1, 10), SharedTmuxSessionGroupMember(2, 20)), 2)
        assertNotNull(plan)
        assertEquals(listOf("move-window -r -t '\$1'", "move-window -r -t '\$2'"), plan!!.mutationCommands)
        assertEquals(listOf("select-window -t \$1:@10", "select-window -t \$2:@20"), plan.selectionRestoreCommands)
        assertEquals("split-window -h -b -t %3 -e COLORTERM=truecolor", SharedTmuxCommands.splitPane("%3", true, true))
        assertNull(
            SharedTmuxCommands.renumberCommands(
                listOf(SharedTmuxSessionGroupMember(1, 10), SharedTmuxSessionGroupMember(1, 20)),
                attachedSessionId = 1,
            ),
        )
    }

    /** W2: tab switches and visible-client targets name the issuing session. */
    @Test
    fun sessionQualifiedWindowTargetsCrossJni() {
        assertEquals("'\$4:@7'", SharedTmuxCommands.sessionWindowTarget(4, 7))
        assertEquals("'\$4:@7.%12'", SharedTmuxCommands.sessionWindowTarget(4, 7, paneId = 12))
        assertEquals(
            "select-window -t '\$4:@7'",
            SharedTmuxCommands.selectWindowInOwnSession(windowId = 7, ownSessionId = 4),
        )
        assertEquals("select-window -t @7", SharedTmuxCommands.selectWindow(7))
    }

    private fun windowRow(id: Int, index: Int): String =
        "__tessera_windows__\t@$id\t$index\t%$id\t\t\t0\twindow-$id"

    private fun response(sequence: Int, rows: List<String>): String = buildString {
        append("%begin $sequence 1 1\r\n")
        rows.forEach { append(it).append("\r\n") }
        append("%end $sequence 1 1\r\n")
    }

    private fun org.json.JSONArray.strings(): List<String> =
        List(length()) { index -> getString(index) }
}
