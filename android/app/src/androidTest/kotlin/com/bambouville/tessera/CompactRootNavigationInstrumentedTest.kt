package com.bambouville.tessera

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.bambouville.tessera.design.TesseraTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** The production bar without hosts, native core startup, or onboarding state. */
class CompactRootNavigationInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun enabledAgentsKeepTheApprovedFiveDestinationOrder() {
        showShell(agentCenterEnabled = true)
        assertOrder(listOf("hosts", "sessions", "agents", "artifacts", "settings"))
        compose.onNodeWithTag("root-keys").assertDoesNotExist()
        compose.onNodeWithTag("root-artifacts").performClick().assertIsSelected()
        compose.onNodeWithText("destination: artifacts").assertIsDisplayed()
        compose.onNodeWithTag("root-settings").performClick().assertIsSelected()
        compose.onNodeWithText("destination: settings").assertIsDisplayed()
    }

    @Test
    fun disabledAgentsLeaveArtifactsBetweenSessionsAndSettings() {
        showShell(agentCenterEnabled = false)
        assertOrder(listOf("hosts", "sessions", "artifacts", "settings"))
        compose.onNodeWithTag("root-agents").assertDoesNotExist()
        compose.onNodeWithTag("root-keys").assertDoesNotExist()
        compose.onNodeWithTag("root-artifacts").performClick().assertIsSelected()
        compose.onNodeWithText("destination: artifacts").assertIsDisplayed()
    }

    private fun showShell(agentCenterEnabled: Boolean) {
        compose.setContent {
            TesseraTheme {
                var selected by remember { mutableStateOf(CompactRootTab.Hosts) }
                CompactRootScaffold(
                    selectedTab = selected,
                    agentCenterEnabled = agentCenterEnabled,
                    onSelect = { selected = it },
                    modifier = Modifier.fillMaxSize(),
                ) { padding ->
                    Text("destination: ${selected.label}", modifier = Modifier.padding(padding))
                }
            }
        }
    }

    private fun assertOrder(labels: List<String>) {
        assertEquals(listOf("hosts", "sessions", "agents", "artifacts", "settings"), CompactRootTab.entries.map { it.label })
        val bounds = labels.map { label ->
            compose.onNodeWithTag("root-$label").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        }
        bounds.zipWithNext().forEach { (left, right) ->
            assertTrue("Root tabs retain their order", left.right <= right.left + 1f)
        }
        val minimum = compose.activity.resources.displayMetrics.density * 48f
        bounds.forEach { bounds ->
            assertTrue("Root tabs meet Android's touch minimum", bounds.width >= minimum && bounds.height >= minimum)
        }
    }
}
