package com.bambouville.tessera.feature.artifacts.viewers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ArtifactPdfPolicyTest {
    @Test fun initialAndLastPageWindowsNeverRequestPagesOutsideTheDocument() {
        assertEquals(emptyList<Int>(), artifactPdfNearbyPages(emptyList(), 0))
        assertEquals(listOf(0), artifactPdfNearbyPages(emptyList(), 1))
        assertEquals(listOf(0, 1), artifactPdfNearbyPages(emptyList(), 100))
        assertEquals(listOf(99, 98), artifactPdfNearbyPages(listOf(99), 100))
    }

    @Test fun jumpingFarAheadDropsTheOldWindowAndPrioritizesVisiblePages() {
        val before = artifactPdfNearbyPages(listOf(0, 1), 100)
        val after = artifactPdfNearbyPages(listOf(50, 51), 100)
        assertEquals(listOf(50, 51, 52, 49), after)
        assertTrue(before.none { it in after })
    }

    @Test fun aViewportOfTinyPagesStillHasABoundedBitmapWorkingSet() {
        val nearby = artifactPdfNearbyPages((0 until 100).toList(), 100)
        assertEquals((0 until 6).toList(), nearby)
        assertEquals(nearby.size, nearby.distinct().size)
    }
}
