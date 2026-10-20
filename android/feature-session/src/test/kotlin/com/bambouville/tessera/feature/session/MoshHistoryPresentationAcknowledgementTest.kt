package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import com.bambouville.tessera.terminal.RenderOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MoshHistoryPresentationAcknowledgementTest {
    private val logicalOwner = SharedTmuxRenderOwner(windowId = 7, paneId = 42, epoch = 3)
    private val physicalOwner = RenderOwner(
        windowId = 7,
        paneId = 42,
        epoch = 3,
        transportGeneration = 11,
    )

    @Test
    fun acceptsOnlyExactCurrentTokenPhysicalSurfaceOwnerAndGenerationOnce() {
        val acknowledgements = MoshHistoryPresentationAcknowledgements<String>()
        acknowledgements.publish(
            MoshHistoryPresentationAcknowledgements.Delivery(
                deliveryToken = 41,
                surfaceId = "overlay:42",
                owner = logicalOwner,
                physicalOwner = physicalOwner,
                surface = "mounted-overlay-a",
            ),
        )

        val accepted = acknowledgements.acknowledge(
            surfaceId = "overlay:42",
            deliveryToken = 41,
            currentGeneration = 11,
            currentSurface = "mounted-overlay-a",
            currentOwner = physicalOwner,
        )
        assertTrue(accepted is MoshHistoryPresentationAcknowledgements.Acknowledgement.Accepted)
        assertEquals(
            MoshHistoryPresentationAcknowledgements.Acknowledgement.Duplicate,
            acknowledgements.acknowledge(
                surfaceId = "overlay:42",
                deliveryToken = 41,
                currentGeneration = 11,
                currentSurface = "mounted-overlay-a",
                currentOwner = physicalOwner,
            ),
        )
    }

    @Test
    fun staleTokenOrReplacedSurfaceCannotAcknowledgeCapturedBytes() {
        val acknowledgements = MoshHistoryPresentationAcknowledgements<String>()
        acknowledgements.publish(
            MoshHistoryPresentationAcknowledgements.Delivery(
                deliveryToken = 42,
                surfaceId = "overlay:42",
                owner = logicalOwner,
                physicalOwner = physicalOwner,
                surface = "mounted-overlay-a",
            ),
        )

        assertEquals(
            MoshHistoryPresentationAcknowledgements.Acknowledgement.Unknown,
            acknowledgements.acknowledge(
                surfaceId = "overlay:42",
                deliveryToken = 41,
                currentGeneration = 11,
                currentSurface = "mounted-overlay-a",
                currentOwner = physicalOwner,
            ),
        )
        val stale = acknowledgements.acknowledge(
            surfaceId = "overlay:42",
            deliveryToken = 42,
            currentGeneration = 11,
            currentSurface = "mounted-overlay-b",
            currentOwner = physicalOwner,
        )
        assertTrue(stale is MoshHistoryPresentationAcknowledgements.Acknowledgement.Stale)
        assertEquals(
            MoshHistoryPresentationAcknowledgements.Acknowledgement.Unknown,
            acknowledgements.acknowledge(
                surfaceId = "overlay:42",
                deliveryToken = 42,
                currentGeneration = 11,
                currentSurface = "mounted-overlay-a",
                currentOwner = physicalOwner,
            ),
        )
    }

    @Test
    fun undeclaredSurfaceDropsItsPendingCallbackBeforeItCanAck() {
        val acknowledgements = MoshHistoryPresentationAcknowledgements<String>()
        acknowledgements.publish(
            MoshHistoryPresentationAcknowledgements.Delivery(
                deliveryToken = 43,
                surfaceId = "overlay:42",
                owner = logicalOwner,
                physicalOwner = physicalOwner,
                surface = "mounted-overlay-a",
            ),
        )

        assertEquals(
            listOf("overlay:42"),
            acknowledgements.discardUndeclared(setOf("live")).map { it.surfaceId },
        )
        assertEquals(
            MoshHistoryPresentationAcknowledgements.Acknowledgement.Unknown,
            acknowledgements.acknowledge(
                surfaceId = "overlay:42",
                deliveryToken = 43,
                currentGeneration = 11,
                currentSurface = "mounted-overlay-a",
                currentOwner = physicalOwner,
            ),
        )
    }
}
