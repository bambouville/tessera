package com.bambouville.tessera.markdown

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.LinkAnnotation
import com.bambouville.tessera.core.bridge.SharedAgentMarkdownNode as Node
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MarkdownDocumentLinksTest {
    private val labels = MarkdownImageLabels("image", "image: %1\$s")
    private fun link(destination: String) = Node("link", destination = destination, children = listOf(Node("text", text = destination)))
    private val nodes = listOf(link("../README.md"), link("http://localhost:3000/x"), link("javascript:alert(1)"))

    @Test fun aDocumentsOpenerTakesEveryLinkSoAccessibilityNeverGetsARawURLSpan() {
        val opened = mutableListOf<String>()
        val links = agentMarkdownAnnotatedString(nodes, Color.Blue, labels) { opened += it }
            .let { it.getLinkAnnotations(0, it.length) }.map { it.item as LinkAnnotation.Url }
        assertEquals(listOf("../README.md", "http://localhost:3000/x", "javascript:alert(1)"), links.map { it.url })
        links.forEach { it.linkInteractionListener!!.onClick(it) }
        assertEquals(links.map { it.url }, opened)
    }

    @Test fun agentOutputKeepsOnlyWebLinksForTheDevice() {
        val links = agentMarkdownAnnotatedString(nodes, Color.Blue, labels)
            .let { it.getLinkAnnotations(0, it.length) }.map { it.item as LinkAnnotation.Url }
        assertEquals(listOf("http://localhost:3000/x"), links.map { it.url })
        assertNull(links.single().linkInteractionListener)
    }
}
