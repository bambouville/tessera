package com.bambouville.tessera.feature.agentcenter

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The attention notification's copy is localized, and every language keeps it
 * content-free: fixed text, with no placeholder a host, provider, project or
 * transcript could be formatted into.
 */
class AgentNotificationCopyTest {
    private val resources = File("src/main/res")
    private val locales = listOf("de", "es", "fr", "ja", "b+zh+Hans", "b+zh+Hant")

    @Test
    fun englishBodyIsTheContractsContentFreeCopy() {
        val english = strings("values")
        assertEquals(AndroidAgentAttentionNotifier.CONTENT_FREE_BODY, english["agent_notification_body"])
        assertEquals("Agent needs input", english["agent_notification_needs_input"])
        assertEquals("Agent finished", english["agent_notification_finished"])
    }

    @Test
    fun everyShippedLanguageTranslatesEveryStringWithoutPlaceholders() {
        val english = strings("values")
        assertEquals(6, english.size)
        for (locale in locales) {
            val localized = strings("values-$locale")
            assertEquals(locale, english.keys, localized.keys)
            for ((key, value) in localized) {
                assertTrue("$locale/$key is blank", value.isNotBlank())
                assertFalse("$locale/$key carries a format placeholder", value.contains('%'))
            }
        }
        // Translations, not copies of the English source.
        assertTrue(locales.all { strings("values-$it")["agent_notification_body"] != english["agent_notification_body"] })
    }

    private fun strings(directory: String): Map<String, String> {
        val file = File(resources, "$directory/agent_notifications.xml")
        assertTrue("missing ${file.path}", file.isFile)
        val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
            .getElementsByTagName("string")
        return (0 until nodes.length).associate { index ->
            val node = nodes.item(index)
            node.attributes.getNamedItem("name").nodeValue to node.textContent
        }
    }
}
