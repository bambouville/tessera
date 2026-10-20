package com.bambouville.tessera.feature.agentcenter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentPhotoAttachmentTest {
    @Test fun supportedTypesKeepBytesAndUseCanonicalExtensions() {
        for ((mime, extension) in mapOf(
            "image/png" to "png", "image/jpeg" to "jpg",
            "image/gif" to "gif", "image/webp" to "webp",
        )) {
            val plan = agentPhotoAttachmentPlan("holiday.HEIC", mime)
            assertEquals("holiday.$extension", plan.fileName)
            assertFalse(plan.transcodeToJpeg)
        }
    }

    @Test fun heifTiffAndOtherImagesAreTranscodedEvenWithMisleadingNames() {
        for (mime in listOf("image/heic", "image/heif", "image/heic-sequence", "image/tiff", "image/bmp", "image/avif")) {
            assertEquals(AgentPhotoAttachmentPlan("portrait.jpg", true), agentPhotoAttachmentPlan("portrait.png", mime))
        }
    }

    @Test fun providerMimeIsNormalized() {
        assertEquals(AgentPhotoAttachmentPlan("portrait.jpg", false),
            agentPhotoAttachmentPlan("portrait.JPEG", " IMAGE/JPEG; charset=binary "))
        assertEquals(AgentPhotoAttachmentPlan("portrait.png", false),
            agentPhotoAttachmentPlan("portrait.heic", "image/x-png"))
    }

    @Test fun absentAndGenericMimeFallBackToContentSignatures() {
        val signatures = mapOf(
            "png" to byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a),
            "jpg" to byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte()),
            "gif" to "GIF89a".toByteArray(),
            "webp" to ("RIFF".toByteArray() + byteArrayOf(4, 0, 0, 0) + "WEBP".toByteArray()),
        )
        for (mime in listOf(null, "", "application/octet-stream", "image/*", "image/unknown")) {
            for ((extension, header) in signatures) {
                assertEquals(AgentPhotoAttachmentPlan("photo.$extension", false),
                    agentPhotoAttachmentPlan("photo.heic", mime, header))
            }
        }
        assertFalse(agentPhotoAttachmentPlan("old", null, "GIF87a".toByteArray()).transcodeToJpeg)
    }

    @Test fun unknownTypeNeverTrustsTheFileExtension() {
        for (header in listOf(byteArrayOf(), "II*\u0000".toByteArray(), "ftypheic".toByteArray(), "not an image".toByteArray())) {
            assertEquals(AgentPhotoAttachmentPlan("photo.jpg", true), agentPhotoAttachmentPlan("photo.png", null, header))
        }
    }

    @Test fun truncatedAndUnrelatedSignaturesDoNotPassThrough() {
        for (header in listOf(byteArrayOf(0xff.toByte(), 0xd8.toByte()), "GIF89".toByteArray(),
            "RIFF1234WAVE".toByteArray(), "RIFF".toByteArray())) {
            assertTrue(agentPhotoAttachmentPlan("photo", null, header).transcodeToJpeg)
        }
    }

    @Test fun namingUsesLastPathComponentAndRemovesOnlyTheFinalExtension() {
        assertEquals("my holiday.edit.jpg", agentPhotoAttachmentPlan("/photos/my holiday.edit.HEIF", "image/heif").fileName)
        assertEquals("portrait.jpg", agentPhotoAttachmentPlan("C:\\photos\\portrait.TIFF", "image/tiff").fileName)
        assertEquals("portrait.jpg", agentPhotoAttachmentPlan("portrait", "image/heic").fileName)
    }

    @Test fun unusableNamesFallBackToPhoto() {
        for (name in listOf(null, "", "  ", ".", "..", ".heic", "/photos/", "\u0000\n.heic")) {
            assertEquals("Photo.jpg", agentPhotoAttachmentPlan(name, "image/heic").fileName)
        }
        assertEquals("Photo.png", agentPhotoAttachmentPlan(null, "image/png").fileName)
    }

    @Test fun controlCharactersCannotEscapeTheStagingName() {
        assertEquals("portrait.jpg", agentPhotoAttachmentPlan("por\ntrait\u0000.heic", "image/heic").fileName)
    }

    @Test fun smallImagesAreNeverUpscaled() {
        for ((width, height) in listOf(1 to 1, 480 to 640, 4096 to 2048, 2048 to 4096)) {
            assertEquals(width to height, agentPhotoDecodeSize(width, height))
        }
    }

    @Test fun largeImagesAreBoundedInBothOrientations() {
        assertEquals(4096 to 3072, agentPhotoDecodeSize(8000, 6000))
        assertEquals(3072 to 4096, agentPhotoDecodeSize(6000, 8000))
        assertEquals(4096 to 4096, agentPhotoDecodeSize(5000, 5000))
    }

    @Test fun extremeDimensionsCannotOverflowOrRoundToZero() {
        assertEquals(4096 to 1, agentPhotoDecodeSize(Int.MAX_VALUE, 1))
        assertEquals(1 to 4096, agentPhotoDecodeSize(1, Int.MAX_VALUE))
        assertEquals(4096 to 4096, agentPhotoDecodeSize(Int.MAX_VALUE, Int.MAX_VALUE))
    }

    @Test(expected = IllegalArgumentException::class)
    fun invalidDecodeDimensionsAreRejected() {
        agentPhotoDecodeSize(0, 200)
    }

    @Test fun normalizedPhotoNamesActivateImageAttachmentWaits() {
        for (mime in listOf("image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/tiff", null)) {
            val plan = agentPhotoAttachmentPlan("photo.HEIC", mime)
            assertTrue(agentDraftAttachesImages("\"/home/dev/.cache/tessera/${plan.fileName}\""))
        }
        assertFalse(agentDraftAttachesImages("\"/home/dev/.cache/tessera/photo.heic\""))
    }
}
