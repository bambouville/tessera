package com.bambouville.tessera.agent.platform

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * An endpoint's unavailable reason reaches the integration panel and Agent
 * Center notices. Each one has a translation in every shipped language, and
 * the English shown is the reason itself unless the reason is a code.
 */
class AgentEndpointUnavailableReasonTest {
    private val resources = File("src/main/res")
    private val locales = listOf("de", "es", "fr", "ja", "b+zh+Hans", "b+zh+Hant")
    private val names = R.string::class.java.fields.associate { it.getInt(null) to it.name }

    @Test
    fun everyReasonIsTranslatedInEveryShippedLanguage() {
        val english = strings("values")
        for (reason in AgentEndpointUnavailableReason.entries) {
            val name = names.getValue(reason.text)
            assertTrue("${reason.name}: $name has no English", english[name]?.isNotBlank() == true)
            for (locale in locales) {
                val translated = strings("values-$locale")[name]
                assertTrue("${reason.name}: $name missing in $locale", translated?.isNotBlank() == true)
                assertFalse("${reason.name}: $name in $locale is still English", translated == english[name])
            }
        }
    }

    @Test
    fun englishShowsTheReasonAsReported_exceptForACode() {
        val english = strings("values")
        for (reason in AgentEndpointUnavailableReason.entries) {
            val shown = english.getValue(names.getValue(reason.text))
            if (reason.reason.contains('_')) {
                assertFalse("${reason.name} shows its code", shown.contains('_'))
            } else {
                assertEquals(reason.name, reason.reason, shown)
            }
        }
    }

    @Test
    fun reasonsAreDistinctAndLookedUpExactly() {
        val reasons = AgentEndpointUnavailableReason.entries.map { it.reason }
        assertEquals(reasons.size, reasons.toSet().size)
        assertEquals(
            R.string.agent_platform_endpoint_tmux_control_unavailable,
            AgentEndpointUnavailableReason.textFor("tmux control is unavailable"),
        )
        assertNull(AgentEndpointUnavailableReason.textFor("tmux_placement_failed"))
        assertNull(AgentEndpointUnavailableReason.textFor("tmux control is unavailable."))
    }

    private fun strings(directory: String): Map<String, String> {
        val file = File(resources, "$directory/strings.xml")
        assertTrue("missing ${file.path}", file.isFile)
        val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
            .getElementsByTagName("string")
        return (0 until nodes.length).associate { index ->
            val node = nodes.item(index)
            node.attributes.getNamedItem("name").nodeValue to node.textContent.replace("\\'", "'")
        }
    }
}
