package com.bambouville.tessera

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.design.TesseraIcons
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AgentNavigationIconInstrumentedTest {
    @Test fun agentsMatchesIosSparklesAndDoesNotReuseSessionsTerminal() {
        assertEquals("AgentsSparkles", CompactRootTab.Agents.icon.name)
        assertEquals(TesseraIcons.Agents, CompactRootTab.Agents.icon)
        assertNotSame(CompactRootTab.Sessions.icon, CompactRootTab.Agents.icon)
    }
}
