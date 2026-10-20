package com.bambouville.tessera.design

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathBuilder
import androidx.compose.ui.graphics.vector.PathData
import androidx.compose.ui.unit.dp

/**
 * Tessera's iconography: hand-drawn monochrome line vectors on a 24x24 viewport.
 *
 * These exist because the alternatives both fail the design language. Unicode
 * symbols (the previous approach) render as whatever glyph the system font happens
 * to ship and read as raw text next to real UI; Material's icon set is a different
 * product's voice — rounder, heavier, and filled where Tessera is hairline.
 * A stroked path at 1.75 units on a 24-unit grid is the drawn equivalent of the
 * 1dp hairline borders the rest of the app is built from, and it tints cleanly
 * because `Icon` recolours by `ColorFilter`, so the declared stroke colour is
 * irrelevant.
 *
 * Keep additions in the same idiom: stroke only (fills reserved for dots), round
 * caps and joins, and geometry that stays inside a 3.5-unit margin so icons
 * optically match at 20-24dp.
 */
object TesseraIcons {
    // Navigation and chrome
    val ChevronLeft by lazy { line("ChevronLeft") { moveTo(15f, 4.5f); lineTo(8.5f, 12f); lineTo(15f, 19.5f) } }
    val ChevronRight by lazy { line("ChevronRight") { moveTo(9f, 4.5f); lineTo(15.5f, 12f); lineTo(9f, 19.5f) } }
    val ChevronDown by lazy { line("ChevronDown") { moveTo(5.5f, 9f); lineTo(12f, 15.5f); lineTo(18.5f, 9f) } }
    val Close by lazy {
        line("Close") {
            moveTo(5.5f, 5.5f); lineTo(18.5f, 18.5f)
            moveTo(18.5f, 5.5f); lineTo(5.5f, 18.5f)
        }
    }
    val Plus by lazy {
        line("Plus") {
            moveTo(12f, 4.5f); lineTo(12f, 19.5f)
            moveTo(4.5f, 12f); lineTo(19.5f, 12f)
        }
    }
    val Paperclip by lazy {
        line("Paperclip") {
            moveTo(8f, 12f); lineTo(14.5f, 5.5f)
            curveTo(16.2f, 3.8f, 19f, 4.1f, 19f, 6.5f)
            curveTo(19f, 7.5f, 18.6f, 8.2f, 18f, 8.8f)
            lineTo(9.4f, 17.4f)
            curveTo(7.8f, 19f, 5f, 18f, 5f, 16f)
            curveTo(5f, 15.2f, 5.3f, 14.6f, 5.8f, 14.1f)
            lineTo(14.2f, 5.7f)
            moveTo(8f, 12f)
            curveTo(6f, 14f, 8f, 16f, 10f, 14f)
            lineTo(16f, 8f)
        }
    }
    val Check by lazy { line("Check") { moveTo(4.5f, 12.5f); lineTo(9.5f, 17.5f); lineTo(19.5f, 6.5f) } }
    val Search by lazy {
        line("Search") {
            circle(11f, 11f, 6.5f)
            moveTo(15.9f, 15.9f); lineTo(20.5f, 20.5f)
        }
    }
    /**
     * Drawn as four sub-90-degree arcs rather than one 315-degree sweep: a
     * large-arc `arcTo` on this path renderer collapsed to a stub, so the whole
     * glyph rendered as a hook. Quarter arcs never take the large-arc branch.
     */
    val Refresh by lazy {
        line("Refresh") {
            moveTo(16.95f, 7.05f)
            arcTo(7f, 7f, 0f, false, true, 19f, 12f)
            arcTo(7f, 7f, 0f, false, true, 12f, 19f)
            arcTo(7f, 7f, 0f, false, true, 5f, 12f)
            arcTo(7f, 7f, 0f, false, true, 12f, 5f)
            moveTo(9.9f, 2.9f); lineTo(12f, 5f); lineTo(9.9f, 7.1f)
        }
    }
    val MoreVertical by lazy {
        dots("MoreVertical", 1.6f, listOf(12f to 5.4f, 12f to 12f, 12f to 18.6f))
    }

    // Root destinations
    val Hosts by lazy {
        line("Hosts") {
            roundRect(3.5f, 4.5f, 20.5f, 10.5f, 1.8f)
            roundRect(3.5f, 13.5f, 20.5f, 19.5f, 1.8f)
            dot(7f, 7.5f)
            dot(7f, 16.5f)
        }
    }
    val Sessions by lazy {
        line("Sessions") {
            roundRect(3.5f, 4.5f, 20.5f, 19.5f, 2.5f)
            moveTo(7.5f, 10f); lineTo(10.5f, 12.5f); lineTo(7.5f, 15f)
            moveTo(12.8f, 15.2f); lineTo(16.5f, 15.2f)
        }
    }
    /** Three sparkles, matching the Agents destination's SF Symbol on iOS. */
    val Agents by lazy {
        line("AgentsSparkles") {
            moveTo(14f, 5.5f)
            curveTo(15f, 10.5f, 15.5f, 11f, 20.5f, 12f)
            curveTo(15.5f, 13f, 15f, 13.5f, 14f, 18.5f)
            curveTo(13f, 13.5f, 12.5f, 13f, 7.5f, 12f)
            curveTo(12.5f, 11f, 13f, 10.5f, 14f, 5.5f)
            close()
            moveTo(6f, 3.5f); lineTo(6.7f, 5.3f); lineTo(8.5f, 6f)
            lineTo(6.7f, 6.7f); lineTo(6f, 8.5f); lineTo(5.3f, 6.7f)
            lineTo(3.5f, 6f); lineTo(5.3f, 5.3f); close()
            moveTo(6f, 15.5f); lineTo(6.7f, 17.3f); lineTo(8.5f, 18f)
            lineTo(6.7f, 18.7f); lineTo(6f, 20.5f); lineTo(5.3f, 18.7f)
            lineTo(3.5f, 18f); lineTo(5.3f, 17.3f); close()
        }
    }
    val Tunnels by lazy {
        line("Tunnels") {
            moveTo(4f, 8f); lineTo(18f, 8f)
            moveTo(14.5f, 4.5f); lineTo(18f, 8f); lineTo(14.5f, 11.5f)
            moveTo(20f, 16f); lineTo(6f, 16f)
            moveTo(9.5f, 12.5f); lineTo(6f, 16f); lineTo(9.5f, 19.5f)
        }
    }
    /** Chain link: the Files browser tied to (or cut loose from) the terminal's cwd. */
    val Link by lazy {
        line("Link") {
            moveTo(10f, 13f)
            arcToRelative(5f, 5f, 0f, false, false, 7.54f, 0.54f)
            lineToRelative(3f, -3f)
            arcToRelative(5f, 5f, 0f, false, false, -7.07f, -7.07f)
            lineToRelative(-1.72f, 1.71f)
            moveTo(14f, 11f)
            arcToRelative(5f, 5f, 0f, false, false, -7.54f, -0.54f)
            lineToRelative(-3f, 3f)
            arcToRelative(5f, 5f, 0f, false, false, 7.07f, 7.07f)
            lineToRelative(1.71f, -1.71f)
        }
    }
    val Keys by lazy {
        line("Keys") {
            circle(8.5f, 15.5f, 3.6f)
            moveTo(11.2f, 12.9f); lineTo(19.8f, 4.3f)
            moveTo(16.6f, 7.5f); lineTo(18.2f, 9.1f)
        }
    }
    val Settings by lazy {
        line("Settings") {
            moveTo(3.5f, 8f); lineTo(20.5f, 8f)
            circle(9f, 8f, 2.3f)
            moveTo(3.5f, 16f); lineTo(20.5f, 16f)
            circle(15f, 16f, 2.3f)
        }
    }

    // Files
    val Folder by lazy {
        line("Folder") {
            moveTo(3.5f, 18.5f); lineTo(3.5f, 6f); lineTo(9.3f, 6f); lineTo(11.4f, 8.8f)
            lineTo(20.5f, 8.8f); lineTo(20.5f, 18.5f); close()
        }
    }
    val FolderPlus by lazy {
        line("FolderPlus") {
            moveTo(3.5f, 18.5f); lineTo(3.5f, 6f); lineTo(9.3f, 6f); lineTo(11.4f, 8.8f)
            lineTo(20.5f, 8.8f); lineTo(20.5f, 18.5f); close()
            moveTo(12f, 11f); lineTo(12f, 16.2f)
            moveTo(9.4f, 13.6f); lineTo(14.6f, 13.6f)
        }
    }
    val File by lazy {
        line("File") {
            moveTo(6f, 3.5f); lineTo(14f, 3.5f); lineTo(18.5f, 8f); lineTo(18.5f, 20.5f)
            lineTo(6f, 20.5f); close()
            moveTo(14f, 3.5f); lineTo(14f, 8f); lineTo(18.5f, 8f)
        }
    }
    val Upload by lazy {
        line("Upload") {
            moveTo(12f, 16f); lineTo(12f, 4f)
            moveTo(7.5f, 8.5f); lineTo(12f, 4f); lineTo(16.5f, 8.5f)
            moveTo(4.5f, 15f); lineTo(4.5f, 20f); lineTo(19.5f, 20f); lineTo(19.5f, 15f)
        }
    }
    val Download by lazy {
        line("Download") {
            moveTo(12f, 4f); lineTo(12f, 16f)
            moveTo(7.5f, 11.5f); lineTo(12f, 16f); lineTo(16.5f, 11.5f)
            moveTo(4.5f, 15f); lineTo(4.5f, 20f); lineTo(19.5f, 20f); lineTo(19.5f, 15f)
        }
    }
    val ArrowUp by lazy {
        line("ArrowUp") {
            moveTo(12f, 19.5f); lineTo(12f, 5f)
            moveTo(6f, 11f); lineTo(12f, 5f); lineTo(18f, 11f)
        }
    }

    val Microphone by lazy {
        line("Microphone") {
            moveTo(9f, 5f); curveTo(9f, 1f, 15f, 1f, 15f, 5f)
            lineTo(15f, 11f); curveTo(15f, 15f, 9f, 15f, 9f, 11f); close()
            moveTo(6f, 10f); lineTo(6f, 11f); curveTo(6f, 19f, 18f, 19f, 18f, 11f); lineTo(18f, 10f)
            moveTo(12f, 17f); lineTo(12f, 22f); moveTo(9f, 22f); lineTo(15f, 22f)
        }
    }

    // Actions
    val Share by lazy {
        mixed(
            "Share",
            stroke = {
                moveTo(8.5f, 10.9f); lineTo(15.5f, 6.9f)
                moveTo(8.5f, 13.1f); lineTo(15.5f, 17.1f)
            },
            fill = {
                circle(17.6f, 5.7f, 2.4f)
                circle(6.4f, 12f, 2.4f)
                circle(17.6f, 18.3f, 2.4f)
            },
        )
    }
    val Copy by lazy {
        line("Copy") {
            rect(8.5f, 8.5f, 20f, 20.5f)
            moveTo(15.5f, 4f); lineTo(4f, 4f); lineTo(4f, 16f)
        }
    }
    val Paste by lazy {
        line("Paste") {
            moveTo(9f, 4.8f); lineTo(6.5f, 4.8f); lineTo(6.5f, 20.5f); lineTo(17.5f, 20.5f)
            lineTo(17.5f, 4.8f); lineTo(15f, 4.8f)
            rect(9f, 3f, 15f, 6.6f)
        }
    }
    val Trash by lazy {
        line("Trash") {
            moveTo(4.5f, 6.6f); lineTo(19.5f, 6.6f)
            moveTo(9.5f, 6.6f); lineTo(9.5f, 4f); lineTo(14.5f, 4f); lineTo(14.5f, 6.6f)
            moveTo(6.6f, 6.6f); lineTo(7.6f, 20.5f); lineTo(16.4f, 20.5f); lineTo(17.4f, 6.6f)
            moveTo(10.4f, 10f); lineTo(10.4f, 17f)
            moveTo(13.6f, 10f); lineTo(13.6f, 17f)
        }
    }
    val Pencil by lazy {
        line("Pencil") {
            moveTo(4f, 20f); lineTo(4f, 15.6f); lineTo(15.8f, 3.8f); lineTo(20.2f, 8.2f)
            lineTo(8.4f, 20f); close()
            moveTo(13.2f, 6.4f); lineTo(17.6f, 10.8f)
        }
    }
    val Install by lazy {
        line("Install") {
            moveTo(10f, 4.5f); lineTo(19.5f, 4.5f); lineTo(19.5f, 19.5f); lineTo(10f, 19.5f)
            moveTo(3.5f, 12f); lineTo(14f, 12f)
            moveTo(10.5f, 8.5f); lineTo(14f, 12f); lineTo(10.5f, 15.5f)
        }
    }
    val Power by lazy {
        line("Power") {
            moveTo(12f, 3.5f); lineTo(12f, 11.5f)
            moveTo(7.19f, 7.19f)
            arcTo(6.8f, 6.8f, 0f, false, false, 5.2f, 12f)
            arcTo(6.8f, 6.8f, 0f, false, false, 12f, 18.8f)
            arcTo(6.8f, 6.8f, 0f, false, false, 18.8f, 12f)
            arcTo(6.8f, 6.8f, 0f, false, false, 16.81f, 7.19f)
        }
    }

    // Status and security
    val Shield by lazy {
        line("Shield") {
            moveTo(12f, 3.5f); lineTo(20f, 6.5f); lineTo(20f, 12.4f); lineTo(12f, 20.5f)
            lineTo(4f, 12.4f); lineTo(4f, 6.5f); close()
        }
    }
    val Lock by lazy {
        line("Lock") {
            rect(5.5f, 10.5f, 18.5f, 20.5f)
            moveTo(8.5f, 10.5f); lineTo(8.5f, 7.5f)
            arcTo(3.5f, 3.5f, 0f, false, true, 12f, 4f)
            arcTo(3.5f, 3.5f, 0f, false, true, 15.5f, 7.5f)
            lineTo(15.5f, 10.5f)
        }
    }
    val Pulse by lazy {
        line("Pulse") {
            moveTo(3.5f, 12f); lineTo(7.8f, 12f); lineTo(10.3f, 5.5f); lineTo(13.8f, 18.5f)
            lineTo(16.3f, 12f); lineTo(20.5f, 12f)
        }
    }
    val Alert by lazy {
        line("Alert") {
            moveTo(12f, 3.8f); lineTo(21f, 19.6f); lineTo(3f, 19.6f); close()
            moveTo(12f, 9.8f); lineTo(12f, 14.4f)
            dot(12f, 17.2f)
        }
    }

    // Terminal and tmux
    val PanelRight by lazy {
        line("PanelRight") {
            roundRect(3.5f, 5f, 20.5f, 19f, 2f)
            moveTo(14.2f, 5f); lineTo(14.2f, 19f)
        }
    }
    val SplitHorizontal by lazy {
        line("SplitHorizontal") {
            roundRect(3.5f, 5f, 20.5f, 19f, 2f)
            moveTo(12f, 5f); lineTo(12f, 19f)
        }
    }
    val SplitVertical by lazy {
        line("SplitVertical") {
            roundRect(3.5f, 5f, 20.5f, 19f, 2f)
            moveTo(3.5f, 12f); lineTo(20.5f, 12f)
        }
    }
    val Maximize by lazy {
        line("Maximize") {
            moveTo(9f, 4.5f); lineTo(4.5f, 4.5f); lineTo(4.5f, 9f)
            moveTo(15f, 4.5f); lineTo(19.5f, 4.5f); lineTo(19.5f, 9f)
            moveTo(19.5f, 15f); lineTo(19.5f, 19.5f); lineTo(15f, 19.5f)
            moveTo(4.5f, 15f); lineTo(4.5f, 19.5f); lineTo(9f, 19.5f)
        }
    }
    val Minimize by lazy {
        line("Minimize") {
            moveTo(4.5f, 9.5f); lineTo(9.5f, 9.5f); lineTo(9.5f, 4.5f)
            moveTo(19.5f, 9.5f); lineTo(14.5f, 9.5f); lineTo(14.5f, 4.5f)
            moveTo(14.5f, 19.5f); lineTo(14.5f, 14.5f); lineTo(19.5f, 14.5f)
            moveTo(9.5f, 19.5f); lineTo(9.5f, 14.5f); lineTo(4.5f, 14.5f)
        }
    }
}

private const val STROKE = 1.75f

private fun line(name: String, block: PathBuilder.() -> Unit): ImageVector =
    ImageVector.Builder(
        name = name,
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f,
    ).apply {
        addPath(
            pathData = PathData(block),
            stroke = SolidColor(Color.Black),
            strokeLineWidth = STROKE,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
        )
    }.build()

private fun mixed(
    name: String,
    stroke: PathBuilder.() -> Unit,
    fill: PathBuilder.() -> Unit,
): ImageVector = ImageVector.Builder(
    name = name,
    defaultWidth = 24.dp,
    defaultHeight = 24.dp,
    viewportWidth = 24f,
    viewportHeight = 24f,
).apply {
    addPath(
        pathData = PathData(stroke),
        stroke = SolidColor(Color.Black),
        strokeLineWidth = STROKE,
        strokeLineCap = StrokeCap.Round,
        strokeLineJoin = StrokeJoin.Round,
    )
    addPath(pathData = PathData(fill), fill = SolidColor(Color.Black))
}.build()

private fun dots(name: String, radius: Float, centers: List<Pair<Float, Float>>): ImageVector =
    ImageVector.Builder(
        name = name,
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f,
    ).apply {
        addPath(
            pathData = PathData { centers.forEach { (x, y) -> circle(x, y, radius) } },
            fill = SolidColor(Color.Black),
        )
    }.build()

/** A dot rendered as a zero-length round-capped segment, sized by the stroke width. */
private fun PathBuilder.dot(x: Float, y: Float) {
    moveTo(x, y)
    lineTo(x + 0.01f, y)
}

private fun PathBuilder.circle(centerX: Float, centerY: Float, radius: Float) {
    moveTo(centerX - radius, centerY)
    arcTo(radius, radius, 0f, true, true, centerX + radius, centerY)
    arcTo(radius, radius, 0f, true, true, centerX - radius, centerY)
    close()
}

private fun PathBuilder.rect(left: Float, top: Float, right: Float, bottom: Float) {
    moveTo(left, top)
    lineTo(right, top)
    lineTo(right, bottom)
    lineTo(left, bottom)
    close()
}

private fun PathBuilder.roundRect(
    left: Float,
    top: Float,
    right: Float,
    bottom: Float,
    radius: Float,
) {
    moveTo(left + radius, top)
    lineTo(right - radius, top)
    arcTo(radius, radius, 0f, false, true, right, top + radius)
    lineTo(right, bottom - radius)
    arcTo(radius, radius, 0f, false, true, right - radius, bottom)
    lineTo(left + radius, bottom)
    arcTo(radius, radius, 0f, false, true, left, bottom - radius)
    lineTo(left, top + radius)
    arcTo(radius, radius, 0f, false, true, left + radius, top)
    close()
}
