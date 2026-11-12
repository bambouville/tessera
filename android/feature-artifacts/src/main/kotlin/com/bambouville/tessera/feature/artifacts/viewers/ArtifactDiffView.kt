package com.bambouville.tessera.feature.artifacts.viewers

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.feature.artifacts.R

/** Renders an agent edit snapshot without reading the remote file. */
@Composable
fun ArtifactDiffView(diff: String, modifier: Modifier = Modifier) {
    val tokens = LocalTesseraTokens.current
    val lines = remember(diff) { ArtifactDiffParser.parse(diff) }
    val gutter = remember(lines) {
        val largest = lines.maxOfOrNull { maxOf(it.oldLineNumber ?: 0, it.newLineNumber ?: 0) } ?: 0
        (maxOf(4, largest.toString().length) * 8 + 8).dp
    }
    if (lines.isEmpty()) {
        Text(stringResource(R.string.artifacts_no_changes), modifier.fillMaxSize().background(tokens.bg).imePadding().padding(16.dp), style = TesseraType.code, color = tokens.fgDim)
        return
    }
    SelectionContainer(modifier.fillMaxSize().background(tokens.bg).imePadding()) {
        LazyColumn(Modifier.fillMaxSize()) {
            itemsIndexed(lines, key = { index, _ -> index }) { _, line ->
                val ink = when (line.kind) {
                    ArtifactDiffLineKind.Added -> tokens.green
                    ArtifactDiffLineKind.Removed -> tokens.red
                    ArtifactDiffLineKind.Header, ArtifactDiffLineKind.Hunk, ArtifactDiffLineKind.Note -> tokens.fgMuted
                    ArtifactDiffLineKind.Context -> tokens.fg
                }
                val surface = when (line.kind) {
                    ArtifactDiffLineKind.Added -> tokens.green.copy(alpha = 0.08f)
                    ArtifactDiffLineKind.Removed -> tokens.red.copy(alpha = 0.08f)
                    ArtifactDiffLineKind.Hunk -> tokens.inputBg
                    else -> Color.Transparent
                }
                Row(Modifier.fillMaxWidth().background(surface).padding(vertical = 2.dp, horizontal = 4.dp)) {
                    Text(line.oldLineNumber?.toString().orEmpty(), Modifier.width(gutter).padding(end = 8.dp), style = TesseraType.code, color = tokens.fgDim, textAlign = TextAlign.End)
                    Text(line.newLineNumber?.toString().orEmpty(), Modifier.width(gutter).padding(end = 8.dp), style = TesseraType.code, color = tokens.fgDim, textAlign = TextAlign.End)
                    val marker = when (line.kind) {
                        ArtifactDiffLineKind.Added -> "+"
                        ArtifactDiffLineKind.Removed -> "−"
                        else -> " "
                    }
                    Text(marker, Modifier.width(16.dp), style = TesseraType.code, color = ink)
                    // Wrap a long logical line within the compact viewport; its
                    // numbers stay on the first visual line and remain legible.
                    Text(line.text.ifEmpty { " " }, Modifier.weight(1f), style = TesseraType.code, color = ink)
                }
            }
        }
    }
}

internal enum class ArtifactDiffLineKind { Header, Hunk, Context, Added, Removed, Note }

internal data class ArtifactDiffLine(
    val kind: ArtifactDiffLineKind,
    val text: String,
    val oldLineNumber: Int? = null,
    val newLineNumber: Int? = null,
)

/** AgentBlockCard currently prints edit bodies verbatim; it has no shared parser. */
internal object ArtifactDiffParser {
    private val hunk = Regex("^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@.*$")

    fun parse(diff: String): List<ArtifactDiffLine> {
        if (diff.isEmpty()) return emptyList()
        var oldLine = 0L
        var newLine = 0L
        var oldRemaining = 0
        var newRemaining = 0
        // A start of 0 with lines is no position: an agent's edit known only
        // by its old and new text. Its lines go unnumbered.
        var oldKnown = true
        var newKnown = true
        fun number(value: Long, remaining: Int, known: Boolean): Int? =
            value.takeIf { known && remaining > 0 && it in 0..Int.MAX_VALUE.toLong() }?.toInt()

        return buildList {
            for (raw in diff.removeSuffix("\n").removeSuffix("\r").lineSequence()) {
                val line = raw.removeSuffix("\r")
                val match = hunk.matchEntire(line)
                if (match != null) {
                    val oldStart = match.groupValues[1].toIntOrNull()
                    val oldCount = match.groupValues[2].ifEmpty { "1" }.toIntOrNull()
                    val newStart = match.groupValues[3].toIntOrNull()
                    val newCount = match.groupValues[4].ifEmpty { "1" }.toIntOrNull()
                    if (oldStart != null && oldCount != null && newStart != null && newCount != null) {
                        oldLine = oldStart.toLong()
                        newLine = newStart.toLong()
                        oldRemaining = oldCount
                        newRemaining = newCount
                        oldKnown = oldStart != 0 || oldCount == 0
                        newKnown = newStart != 0 || newCount == 0
                        // An agent's edit, known only by its old and new text,
                        // names no lines: its header shows as a break.
                        add(ArtifactDiffLine(ArtifactDiffLineKind.Hunk, if (oldKnown && newKnown) line else "⋯"))
                        continue
                    }
                }
                val inHunk = oldRemaining > 0 || newRemaining > 0
                when {
                    line.startsWith("\\ No newline at end of file") -> add(ArtifactDiffLine(ArtifactDiffLineKind.Note, line))
                    line.startsWith("diff --git ") || line.startsWith("@@") ||
                        (!inHunk && (line.startsWith("--- ") || line.startsWith("+++ "))) -> {
                        oldRemaining = 0
                        newRemaining = 0
                        add(ArtifactDiffLine(ArtifactDiffLineKind.Header, line))
                    }
                    line.startsWith('+') -> {
                        add(ArtifactDiffLine(ArtifactDiffLineKind.Added, line.drop(1), newLineNumber = number(newLine, newRemaining, newKnown)))
                        if (newRemaining > 0) { newLine++; newRemaining-- }
                    }
                    line.startsWith('-') -> {
                        add(ArtifactDiffLine(ArtifactDiffLineKind.Removed, line.drop(1), oldLineNumber = number(oldLine, oldRemaining, oldKnown)))
                        if (oldRemaining > 0) { oldLine++; oldRemaining-- }
                    }
                    line.startsWith(' ') -> {
                        add(ArtifactDiffLine(ArtifactDiffLineKind.Context, line.drop(1), number(oldLine, oldRemaining, oldKnown), number(newLine, newRemaining, newKnown)))
                        if (oldRemaining > 0) { oldLine++; oldRemaining-- }
                        if (newRemaining > 0) { newLine++; newRemaining-- }
                    }
                    else -> {
                        oldRemaining = 0
                        newRemaining = 0
                        add(ArtifactDiffLine(ArtifactDiffLineKind.Header, line))
                    }
                }
            }
        }
    }
}
