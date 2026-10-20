package com.bambouville.tessera.markdown

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.core.bridge.SharedAgentMarkdown
import com.bambouville.tessera.core.bridge.SharedAgentMarkdownNode
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraType
import java.net.URI

/**
 * Presentation-only renderer for the bounded, non-executing Markdown tree
 * produced in shared Core. Keep parsing out of this module: platform renderers
 * must agree on what content means before they choose how it looks.
 */
@Composable
fun TesseraMarkdownText(
    source: String,
    modifier: Modifier = Modifier,
    imageContent: (@Composable (destination: String, alt: String) -> Unit)? = null,
) {
    val tokens = LocalTesseraTokens.current
    // A bridge load failure must never make content disappear. The literal
    // fallback deliberately does not run a local Markdown parser.
    val document = remember(source) { runCatching { SharedAgentMarkdown.parse(source) }.getOrNull() }
    if (document == null) {
        Text(source, modifier = modifier, style = TesseraType.body, color = tokens.fg)
        return
    }

    CompositionLocalProvider(LocalMarkdownImageContent provides imageContent) {
        Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            document.blocks.forEach { block -> AgentMarkdownBlock(block) }
            if (document.truncated) Text("…", style = TesseraType.rowMicro, color = tokens.fgDim)
        }
    }
}

@Composable
private fun AgentMarkdownBlock(node: SharedAgentMarkdownNode, listDepth: Int = 0) {
    val tokens = LocalTesseraTokens.current
    when (node.kind) {
        "paragraph" -> AgentMarkdownProse(node.children)
        "heading" -> AgentMarkdownInline(
            node.children,
            style = when (node.level ?: 1) {
                1 -> TesseraType.sheet
                2 -> TesseraType.section
                else -> TesseraType.rowTitle
            },
            color = tokens.fg,
        )
        // The rule takes the quote's own height, so the Row must measure its
        // minimum intrinsic height first: a weighted bar in a wrap-content Row
        // is laid out zero-tall and the quote reads as plain indented text.
        "quote" -> Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
            Box(Modifier.width(2.dp).fillMaxHeight().background(tokens.border))
            Column(
                Modifier.weight(1f).padding(start = 10.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) { node.children.forEach { AgentMarkdownBlock(it, listDepth) } }
        }
        "unorderedList" -> AgentMarkdownList(node, ordered = false, listDepth = listDepth)
        "orderedList" -> AgentMarkdownList(node, ordered = true, listDepth = listDepth)
        "listItem" -> AgentMarkdownListItem(node, listDepth)
        "codeBlock" -> AgentMarkdownCodeBlock(node)
        "thematicBreak" -> Box(Modifier.fillMaxWidth().padding(vertical = 4.dp).background(tokens.border).padding(vertical = 0.5.dp))
        "table" -> AgentMarkdownTable(node)
        // The parser normally puts these below table/list containers. Retaining
        // a graceful block rendering makes a forward-compatible bridge safer.
        "tableRow", "tableCell" -> AgentMarkdownProse(node.children)
        else -> AgentMarkdownProse(listOf(node))
    }
}

@Composable
private fun AgentMarkdownProse(nodes: List<SharedAgentMarkdownNode>) {
    val tokens = LocalTesseraTokens.current
    AgentMarkdownInline(nodes, style = TesseraType.body, color = tokens.fg)
}

@Composable
private fun AgentMarkdownList(node: SharedAgentMarkdownNode, ordered: Boolean, listDepth: Int) {
    Column(
        Modifier.padding(start = (listDepth * 12).dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        node.children.forEachIndexed { index, item ->
            AgentMarkdownListItem(item, listDepth, if (ordered) "${(node.start ?: 1) + index}." else "•")
        }
    }
}

@Composable
private fun AgentMarkdownListItem(node: SharedAgentMarkdownNode, listDepth: Int, marker: String? = null) {
    val tokens = LocalTesseraTokens.current
    val taskMarker = when (node.checked) {
        true -> "☑"
        false -> "☐"
        null -> marker ?: "•"
    }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Text(
            taskMarker,
            modifier = Modifier.padding(end = 7.dp),
            style = TesseraType.body,
            color = if (node.checked != null) tokens.accent else tokens.fgMuted,
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            node.children.forEach { child -> AgentMarkdownBlock(child, listDepth + 1) }
        }
    }
}

@Composable
private fun AgentMarkdownCodeBlock(node: SharedAgentMarkdownNode) {
    val tokens = LocalTesseraTokens.current
    Column(
        Modifier.fillMaxWidth().background(tokens.inputBg, RoundedCornerShape(8.dp))
            .border(1.dp, tokens.border, RoundedCornerShape(8.dp)).padding(10.dp),
    ) {
        node.language?.takeIf(String::isNotBlank)?.let { language ->
            Text(language, style = TesseraType.rowMicro, color = tokens.fgDim, modifier = Modifier.padding(bottom = 5.dp))
        }
        Row(Modifier.horizontalScroll(rememberScrollState())) {
            Text(node.text.orEmpty(), style = TesseraType.code, color = tokens.fg, softWrap = false)
        }
    }
}

@Composable
private fun AgentMarkdownTable(table: SharedAgentMarkdownNode) {
    val tokens = LocalTesseraTokens.current
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            .border(1.dp, tokens.border, RoundedCornerShape(8.dp)),
    ) {
        Column {
            table.children.filter { it.kind == "tableRow" }.forEachIndexed { rowIndex, row ->
                Row(Modifier.background(if (rowIndex == 0) tokens.inputBg else Color.Transparent)) {
                    row.children.filter { it.kind == "tableCell" }.forEach { cell ->
                        AgentMarkdownInline(
                            cell.children,
                            modifier = Modifier.width(144.dp).padding(horizontal = 8.dp, vertical = 7.dp),
                            style = TesseraType.bodySmall.copy(
                                fontWeight = if (cell.level == 1) FontWeight.SemiBold else FontWeight.Normal,
                            ),
                            color = tokens.fg,
                            textAlign = when (cell.alignment) {
                                "center" -> TextAlign.Center
                                "right" -> TextAlign.End
                                else -> TextAlign.Start
                            },
                        )
                    }
                }
            }
        }
    }
}

private val LocalMarkdownImageContent = staticCompositionLocalOf<(@Composable (String, String) -> Unit)?> { null }

internal data class MarkdownInlinePart(
    val nodes: List<SharedAgentMarkdownNode> = emptyList(),
    val image: SharedAgentMarkdownNode? = null,
    val link: String? = null,
)

/** Split images out of prose while retaining enclosing emphasis/link styles. */
internal fun markdownInlineParts(nodes: List<SharedAgentMarkdownNode>): List<MarkdownInlinePart> {
    val result = mutableListOf<MarkdownInlinePart>()
    fun add(part: MarkdownInlinePart) {
        if (part.image == null && result.lastOrNull()?.image == null && result.isNotEmpty()) {
            result[result.lastIndex] = MarkdownInlinePart(result.last().nodes + part.nodes)
        } else result += part
    }
    nodes.forEach { node ->
        if (node.kind == "image" && node.destination != null) {
            add(MarkdownInlinePart(image = node))
        } else if (node.children.isNotEmpty() && node.kind != "image") {
            markdownInlineParts(node.children).forEach { part ->
                add(if (part.image != null) {
                    if (node.kind == "link") part.copy(link = node.destination?.takeIf(::isSafeAgentLink)) else part
                } else MarkdownInlinePart(listOf(node.copy(children = part.nodes))))
            }
        } else add(MarkdownInlinePart(listOf(node)))
    }
    return result
}

@Composable
private fun AgentMarkdownInline(
    nodes: List<SharedAgentMarkdownNode>,
    modifier: Modifier = Modifier,
    style: TextStyle,
    color: Color,
    textAlign: TextAlign = TextAlign.Start,
) {
    val tokens = LocalTesseraTokens.current
    val imageContent = LocalMarkdownImageContent.current
    val uriHandler = LocalUriHandler.current
    val parts = remember(nodes) { markdownInlineParts(nodes) }
    val linkColor = tokens.accent
    if (imageContent == null || parts.none { it.image != null }) {
        val text = remember(nodes, linkColor) { agentMarkdownAnnotatedString(nodes, linkColor) }
        Text(text, modifier, color = color, style = style, textAlign = textAlign)
    } else {
        Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            parts.forEach { part ->
                val image = part.image
                if (image != null) {
                    val alt = remember(image, linkColor) { agentMarkdownAnnotatedString(image.children, linkColor).text }
                    Box(if (part.link != null) Modifier.clickable { uriHandler.openUri(part.link) } else Modifier) {
                        imageContent(image.destination.orEmpty(), alt)
                    }
                } else {
                    val text = remember(part.nodes, linkColor) { agentMarkdownAnnotatedString(part.nodes, linkColor) }
                    Text(text, color = color, style = style, textAlign = textAlign)
                }
            }
        }
    }
}

/** Builds a display-only inline annotation tree; links are never fetched here. */
internal fun agentMarkdownAnnotatedString(nodes: List<SharedAgentMarkdownNode>, linkColor: Color): AnnotatedString = buildAnnotatedString {
    nodes.forEach { appendAgentMarkdownInline(it, linkColor) }
}

private fun AnnotatedString.Builder.appendAgentMarkdownInline(node: SharedAgentMarkdownNode, linkColor: Color) {
    fun appendChildren() = node.children.forEach { appendAgentMarkdownInline(it, linkColor) }
    when (node.kind) {
        "text" -> append(node.text.orEmpty())
        "strong" -> withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { appendChildren() }
        "emphasis" -> withStyle(SpanStyle(fontStyle = androidx.compose.ui.text.font.FontStyle.Italic)) { appendChildren() }
        "strikethrough" -> withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) { appendChildren() }
        "inlineCode" -> withStyle(SpanStyle(fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Medium)) { append(node.text.orEmpty()) }
        "link" -> {
            val destination = node.destination?.takeIf(::isSafeAgentLink)
            if (destination == null) appendChildren() else withLink(LinkAnnotation.Url(destination)) {
                withStyle(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)) { appendChildren() }
            }
        }
        "softBreak", "lineBreak" -> append('\n')
        // Agent transcripts remain alt-only. Files explicitly supplies an
        // image slot backed by privately staged copies from the document host.
        "image" -> {
            append("[image")
            if (node.children.isNotEmpty()) {
                append(": ")
                appendChildren()
            }
            append("]")
        }
        else -> if (node.children.isNotEmpty()) appendChildren() else append(node.text.orEmpty())
    }
}

private fun isSafeAgentLink(value: String): Boolean = runCatching {
    val uri = URI(value)
    when (uri.scheme?.lowercase()) {
        "http", "https" -> !uri.host.isNullOrBlank()
        "mailto" -> !uri.schemeSpecificPart.isNullOrBlank()
        else -> false
    }
}.getOrDefault(false)
