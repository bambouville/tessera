package com.bambouville.tessera.feature.artifacts.viewers

import org.junit.Assert.assertEquals
import org.junit.Test

class ArtifactMimeTypeTest {
    @Test fun builtPagesHaveExecutableAssetMimeTypes() {
        val expected = mapOf(
            "html" to "text/html", "htm" to "text/html", "css" to "text/css", "js" to "text/javascript",
            "mjs" to "text/javascript", "cjs" to "text/javascript", "json" to "application/json", "map" to "application/json",
            "webmanifest" to "application/manifest+json", "xml" to "application/xml", "wasm" to "application/wasm",
            "woff" to "font/woff", "woff2" to "font/woff2", "ttf" to "font/ttf", "otf" to "font/otf",
        )
        expected.forEach { (extension, mime) -> assertEquals(extension, mime, artifactMimeType("/report/asset.$extension")) }
    }

    @Test fun imagesDocumentsAndMediaHaveStableMimeTypes() {
        val expected = mapOf(
            "svg" to "image/svg+xml", "png" to "image/png", "jpg" to "image/jpeg", "jpeg" to "image/jpeg",
            "gif" to "image/gif", "webp" to "image/webp", "avif" to "image/avif", "bmp" to "image/bmp", "ico" to "image/x-icon",
            "pdf" to "application/pdf", "md" to "text/plain", "txt" to "text/plain", "mp3" to "audio/mpeg", "wav" to "audio/wav",
            "ogg" to "audio/ogg", "mp4" to "video/mp4", "webm" to "video/webm",
        )
        expected.forEach { (extension, mime) -> assertEquals(extension, mime, artifactMimeType("asset.$extension")) }
    }

    @Test fun uppercaseAndUnknownExtensionsHaveDeterministicFallbacks() {
        assertEquals("text/html", artifactMimeType("REPORT.HTML"))
        assertEquals("image/png", artifactMimeType("asset.PnG"))
        assertEquals("application/octet-stream", artifactMimeType("asset.unknown"))
        assertEquals("application/octet-stream", artifactMimeType("README"))
    }
}
