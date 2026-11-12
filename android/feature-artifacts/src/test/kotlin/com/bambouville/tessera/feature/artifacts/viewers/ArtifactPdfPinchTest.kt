package com.bambouville.tessera.feature.artifacts.viewers

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.IntSize
import org.junit.Assert.assertEquals
import org.junit.Test

class ArtifactPdfPinchTest {
    private val size = IntSize(1000, 2000)

    @Test fun thePointUnderTheFingersStaysUnderThem() {
        // Fingers at (750, 1500) sit 250, 500 from the centre.
        val (zoom, offset) = pinchedPdfPage(1f, Offset.Zero, size, Offset(750f, 1500f), 2f, Offset.Zero)
        assertEquals(2f, zoom)
        assertEquals(Offset(-250f, -500f), offset)
        // Again from there: the same page point stays put.
        val (deeper, moved) = pinchedPdfPage(zoom, offset, size, Offset(750f, 1500f), 1.5f, Offset.Zero)
        assertEquals(3f, deeper)
        val page = (Offset(250f, 500f) - offset) / zoom
        assertEquals(Offset(250f, 500f), page * deeper + moved)
    }

    @Test fun aStepWithoutACentroidZoomsAboutTheCentre() {
        val (zoom, offset) = pinchedPdfPage(2f, Offset(100f, 0f), size, Offset.Unspecified, 1.5f, Offset.Zero)
        assertEquals(3f, zoom)
        assertEquals(Offset(150f, 0f), offset)
    }

    @Test fun zoomingOutNeverLeavesTheViewportsEdges() {
        val (zoom, offset) = pinchedPdfPage(4f, Offset(-1500f, -3000f), size, Offset(500f, 1000f), 0.5f, Offset.Zero)
        assertEquals(2f, zoom)
        assertEquals(Offset(-500f, -1000f), offset)
        val (rest, still) = pinchedPdfPage(1f, Offset.Zero, size, Offset(900f, 100f), 0.5f, Offset(40f, 40f))
        assertEquals(1f, rest)
        assertEquals(Offset.Zero, still)
    }

    @Test fun aPanMovesAZoomedPageAndStopsAtItsEdge() {
        assertEquals(2f to Offset(30f, -40f), pinchedPdfPage(2f, Offset.Zero, size, Offset(500f, 1000f), 1f, Offset(30f, -40f)))
        assertEquals(2f to Offset(500f, -1000f), pinchedPdfPage(2f, Offset.Zero, size, Offset(500f, 1000f), 1f, Offset(900f, -1900f)))
    }
}
