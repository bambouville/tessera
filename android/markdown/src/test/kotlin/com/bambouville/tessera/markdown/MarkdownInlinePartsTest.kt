package com.bambouville.tessera.markdown

import com.bambouville.tessera.core.bridge.SharedAgentMarkdownNode as Node
import org.junit.Assert.assertEquals
import org.junit.Test

class MarkdownInlinePartsTest {
    @Test fun nestedImagesSplitWithoutDroppingSurroundingStylesOrText() {
        val image = Node("image", destination = "../plot.png", children = listOf(Node("text", text = "plot")))
        val nodes = listOf(Node("strong", children = listOf(Node("text", text = "before"), image, Node("text", text = "after"))))
        val parts = markdownInlineParts(nodes)
        assertEquals(3, parts.size)
        assertEquals(nodes[0].copy(children = listOf(Node("text", text = "before"))), parts[0].nodes.single())
        assertEquals(image, parts[1].image)
        assertEquals(nodes[0].copy(children = listOf(Node("text", text = "after"))), parts[2].nodes.single())
    }

    @Test fun codeAndImagesWithoutDestinationsRemainLiteral() {
        val nodes = listOf(Node("inlineCode", text = "![literal](path.png)"), Node("image", children = listOf(Node("text", text = "alt"))))
        assertEquals(listOf(MarkdownInlinePart(nodes)), markdownInlineParts(nodes))
    }
}
