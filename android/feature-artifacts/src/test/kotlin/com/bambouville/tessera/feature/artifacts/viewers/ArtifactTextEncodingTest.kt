package com.bambouville.tessera.feature.artifacts.viewers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ArtifactTextEncodingTest {
    @Test fun utf8BomIsHonouredAndRemovedFromDocumentText() {
        val bytes = byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte()) + "# café".toByteArray(Charsets.UTF_8)
        assertEquals(ArtifactTextEncoding(Charsets.UTF_8, 3), artifactTextEncoding(bytes))
        assertEquals("# café", decodeArtifactText(bytes))
    }

    @Test fun bothUtf16BomsSelectTheByteOrderForHtmlAndDocuments() {
        for ((charset, bom) in listOf(
            Charsets.UTF_16LE to byteArrayOf(0xff.toByte(), 0xfe.toByte()),
            Charsets.UTF_16BE to byteArrayOf(0xfe.toByte(), 0xff.toByte()),
        )) {
            val bytes = bom + "<p>café 日本 😀</p>".toByteArray(charset)
            assertEquals(ArtifactTextEncoding(charset, 2), artifactTextEncoding(bytes))
            assertEquals("<p>café 日本 😀</p>", decodeArtifactText(bytes))
        }
    }

    @Test fun validUtf8WithoutABomRemainsUtf8() {
        for (source in listOf("", "ascii", "café 日本 😀")) {
            val bytes = source.toByteArray(Charsets.UTF_8)
            assertEquals(ArtifactTextEncoding(Charsets.UTF_8), artifactTextEncoding(bytes))
            assertEquals(source, decodeArtifactText(bytes))
        }
    }

    @Test fun legacyHtmlLeavesEncodingUnsetForMetaCharsetSniffing() {
        val bytes = "<meta charset=windows-1252><p>café</p>".toByteArray(Charsets.ISO_8859_1)
        assertNull(artifactTextEncoding(bytes))
    }

    @Test fun htmlMetaCharsetTakesPrecedenceEvenWhenTheBytesAreValidUtf8() {
        for (meta in listOf(
            "<meta charset=windows-1252>",
            "<META CHARSET = 'Windows-1252' >",
            "<MeTa\nCHARSET\t=\t\"windows-1252\"/>",
            "<meta name='description' charset='windows-1252'>",
        )) {
            val bytes = "$meta<p>café</p>".toByteArray(Charsets.UTF_8)
            assertNull(meta, artifactTextEncoding(bytes, mimeType = "text/html"))
        }
    }

    @Test fun httpEquivContentTypeCanDeclareTheCharsetInEitherAttributeOrder() {
        for (meta in listOf(
            """<meta http-equiv="content-type" content="text/html; charset=windows-1252">""",
            """<META CONTENT='text/html; CHARSET = "Windows-1252"' HTTP-EQUIV = 'Content-Type'>""",
            "<meta content = 'text/html; charset=windows-1252' http-equiv=content-type>",
        )) assertNull(meta, artifactTextEncoding("$meta<p>ascii</p>".toByteArray()))
    }

    @Test fun xmlAndSvgDeclarationsLeaveEncodingForWebView() {
        for (mime in listOf("application/xml", "text/xml", "image/svg+xml", "application/xhtml+xml")) {
            for (declaration in listOf(
                """<?xml version="1.0" encoding="windows-1252"?>""",
                "<?XML\nversion='1.0'\tENCODING = 'Windows-1252' ?>",
            )) assertNull(mime, artifactTextEncoding("$declaration<root>café</root>".toByteArray(), mimeType = mime))
        }
        val spaced = "<?xml " + " ".repeat(4096) + "encoding='windows-1252'?><root/>"
        assertNull(artifactTextEncoding(spaced.toByteArray(), mimeType = "application/xml"))
    }

    @Test fun xmlAndSvgWithoutADeclarationDoNotInferUtf8() {
        for (mime in listOf("application/xml", "text/xml", "image/svg+xml", "application/xhtml+xml", "APPLICATION/ATOM+XML; version=1")) {
            for (source in listOf("", "<root>£</root>", "<?xml version=\"1.0\"?><root>£</root>", "<svg><text>£</text></svg>")) {
                assertNull("$mime: $source", artifactTextEncoding(source.toByteArray(), mimeType = mime))
            }
        }
    }

    @Test fun bomlessUtf16XmlDeclarationsAreLeftForTheXmlParser() {
        for ((charset, label) in listOf(Charsets.UTF_16LE to "UTF-16LE", Charsets.UTF_16BE to "UTF-16BE")) {
            val source = """<?xml version="1.0" encoding="$label"?><root/>"""
            val bytes = source.toByteArray(charset)
            assertEquals(source.length * 2, bytes.size)
            // ASCII plus NUL validates as UTF-8, but must not override XML detection.
            assertEquals(ArtifactTextEncoding(Charsets.UTF_8), artifactTextEncoding(bytes, mimeType = "text/plain"))
            for (mime in listOf("application/xml", "text/xml", "image/svg+xml", "application/xhtml+xml")) {
                assertNull("$mime: $label", artifactTextEncoding(bytes, mimeType = mime))
            }
        }
    }

    @Test fun windows1252HtmlLeavesTheStylesheetEncodingInherited() {
        val page = "<meta charset=windows-1252><link rel=stylesheet href=style.css>".toByteArray()
        assertNull(artifactTextEncoding(page, mimeType = artifactMimeType("index.html")))
        // C2 A3 is £ in UTF-8 and Â£ in the referring page's Windows-1252.
        val stylesheet = "p::after { content: '".toByteArray() + byteArrayOf(0xc2.toByte(), 0xa3.toByte()) + "'; }".toByteArray()
        assertEquals("p::after { content: '£'; }", String(stylesheet, Charsets.UTF_8))
        assertEquals("p::after { content: 'Â£'; }", String(stylesheet, Charsets.ISO_8859_1))
        assertNull(artifactTextEncoding(stylesheet, mimeType = artifactMimeType("style.css")))
    }

    @Test fun classicModuleAndCommonJsScriptsDoNotDeclareAResponseCharset() {
        for (path in listOf("classic.js", "module.mjs", "common.cjs", "CLASSIC.JS")) {
            for (source in listOf("", "window.price = '£';", "export const price = '£';")) {
                assertNull(path, artifactTextEncoding(source.toByteArray(), mimeType = artifactMimeType(path)))
            }
        }
    }

    @Test fun utf8BomsSetUtf8ForEveryTextResourcePath() {
        val bytes = byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte()) +
            "<meta charset=windows-1252><?xml encoding='UTF-16LE'?>@charset \"windows-1252\";£".toByteArray()
        for (path in listOf(
            "index.html", "style.css", "classic.js", "module.mjs", "common.cjs", "data.xml", "icon.svg",
            "data.json", "app.js.map", "site.webmanifest", "plain.txt",
        )) assertEquals(path, ArtifactTextEncoding(Charsets.UTF_8, 3), artifactTextEncoding(bytes, mimeType = artifactMimeType(path)))
    }

    @Test fun cssCharsetAtByteZeroLeavesTheStylesheetEncodingForWebView() {
        for (charset in listOf(Charsets.UTF_8, Charsets.ISO_8859_1)) {
            val bytes = """@charset "windows-1252"; p::after { content: "café"; }""".toByteArray(charset)
            assertNull(charset.name(), artifactTextEncoding(bytes, mimeType = "text/css"))
            assertNull(charset.name(), artifactTextEncoding(bytes, mimeType = "TEXT/CSS; charset=UTF-8"))
        }
    }

    @Test fun cssCharsetSyntaxIsLeftForWebView() {
        for (source in listOf(
            """ @charset "windows-1252";""",
            "\n@charset \"windows-1252\";",
            """/* comment */@charset "windows-1252";""",
            """p {} @charset "windows-1252";""",
            """@CHARSET "windows-1252";""",
            """@Charset "windows-1252";""",
            "@charset 'windows-1252';",
            "@charset windows-1252;",
            "@charset\t\"windows-1252\";",
            """@charset  "windows-1252";""",
            """@charset "windows-1252" ;""",
            """@charset "windows-1252"""",
            """@charset "windows-1252" p {}""",
            """@charset "";""",
            """@charset " ";""",
            """p::after { content: '@charset "windows-1252";'; }""",
        )) assertNull(source, artifactTextEncoding(source.toByteArray(), mimeType = "text/css"))
    }

    @Test fun cssDoesNotInferACharsetBeyondTheBrowserPrescan() {
        val prefix = "@charset \""
        val suffix = "\";"
        assertNull(artifactTextEncoding((prefix + "x".repeat(1024 - prefix.length - suffix.length) + suffix).toByteArray(), mimeType = "text/css"))
        assertNull(artifactTextEncoding((prefix + "x".repeat(1025 - prefix.length - suffix.length) + suffix).toByteArray(), mimeType = "text/css"))
    }

    @Test fun cssDeclarationsAreNotAppliedToOtherTextMimeTypes() {
        val source = """@charset "windows-1252"; p::after { content: "café"; }"""
        for (mime in listOf("text/plain", "text/html", "application/json", "application/manifest+json")) {
            assertEquals(mime, ArtifactTextEncoding(Charsets.UTF_8), artifactTextEncoding(source.toByteArray(), mimeType = mime))
        }
        assertEquals(source, decodeArtifactText(source.toByteArray()))
    }

    @Test fun byteOrderMarksPreserveBrowserAndDocumentDecoding() {
        for (mime in listOf(
            "text/html", "text/css", "text/javascript", "application/json", "application/manifest+json", "text/plain",
            "application/xml", "text/xml", "image/svg+xml", "application/xhtml+xml",
        )) {
            val source = when (mime) {
                "text/html" -> "<meta charset=windows-1252>"
                "text/css" -> """@charset "windows-1252";"""
                else -> """<?xml encoding="windows-1252"?>"""
            }
            for ((charset, bom) in listOf(
                Charsets.UTF_8 to byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte()),
                Charsets.UTF_16LE to byteArrayOf(0xff.toByte(), 0xfe.toByte()),
                Charsets.UTF_16BE to byteArrayOf(0xfe.toByte(), 0xff.toByte()),
            )) {
                val bytes = bom + source.toByteArray(charset)
                val xml = mime == "application/xml" || mime == "text/xml" || mime.endsWith("+xml")
                val expected = if (xml && charset != Charsets.UTF_8) null else ArtifactTextEncoding(charset, bom.size)
                assertEquals("$mime: ${charset.name()}", expected, artifactTextEncoding(bytes, mimeType = mime))
                assertEquals(source, decodeArtifactText(bytes))
            }
        }
    }

    @Test fun onlyTheFirst1024HtmlBytesAreSearchedForADeclaration() {
        val meta = "<meta charset=windows-1252>"
        assertNull(artifactTextEncoding((" ".repeat(1024 - meta.length) + meta).toByteArray()))
        assertEquals(ArtifactTextEncoding(Charsets.UTF_8), artifactTextEncoding((" ".repeat(1024) + meta).toByteArray()))
    }

    @Test fun textWithoutADeclarationAndOtherMimeTypesKeepTheUtf8Default() {
        for ((mime, source) in listOf(
            "text/html" to "<p>café</p>",
            "text/plain" to "<meta charset=windows-1252>café",
            "application/json" to """{"markup":"<?xml encoding='windows-1252'?>"}""",
            "application/manifest+json" to """{"name":"café"}""",
        )) assertEquals(mime, ArtifactTextEncoding(Charsets.UTF_8), artifactTextEncoding(source.toByteArray(), mimeType = mime))
    }

    @Test fun htmlJsonSourceMapsManifestsAndPlainTextKeepTheirResponseCharsets() {
        for ((path, source) in listOf(
            "index.html" to "<p>café £</p>",
            "data.json" to """{"price":"£"}""",
            "app.js.map" to """{"sources":["café.js"]}""",
            "site.webmanifest" to """{"name":"café"}""",
            "plain.txt" to "café £",
        )) {
            val mime = artifactMimeType(path)
            assertEquals(path, ArtifactTextEncoding(Charsets.UTF_8), artifactTextEncoding(source.toByteArray(), mimeType = mime))
            assertNull(path, artifactTextEncoding(source.toByteArray(Charsets.ISO_8859_1), mimeType = mime))
        }
    }

    @Test fun commentsLookalikeAttributesAndNonAsciiMarkupDoNotDeclareACharset() {
        for (source in listOf(
            "<!-- <meta charset=windows-1252> --><p>café</p>",
            "<metadata charset=windows-1252>",
            "<meta data-charset=windows-1252>",
            "<meta content='text/html; charset=windows-1252'>",
            "<meta http-equiv=refresh content='text/html; charset=windows-1252'>",
            "<meta http-equiv=content-type content='text/html'>",
            "<meta\u00a0charset=windows-1252>",
            "<meta char\u017fet=windows-1252>",
        )) assertEquals(source, ArtifactTextEncoding(Charsets.UTF_8), artifactTextEncoding(source.toByteArray()))
    }

    @Test fun plainTextPreviewDoesNotReinterpretUtf8InsideAnEncodingDeclaration() {
        for (source in listOf(
            "<meta charset=windows-1252><p>café 日本</p>",
            """@charset "windows-1252"; p::after { content: 'café 日本'; }""",
            """<?xml version="1.0" encoding="windows-1252"?><root>café 日本</root>""",
            "const price = '£';",
        )) assertEquals(source, decodeArtifactText(source.toByteArray()))
    }

    @Test fun documentsFallBackToLatin1WithoutABomOrValidUtf8() {
        val bytes = "café £".toByteArray(Charsets.ISO_8859_1)
        assertNull(artifactTextEncoding(bytes))
        assertEquals("café £", decodeArtifactText(bytes))
    }

    @Test fun malformedOverlongAndSurrogateUtf8AreNotDeclaredUtf8() {
        for (bytes in listOf(byteArrayOf(0xc0.toByte(), 0xaf.toByte()), byteArrayOf(0xed.toByte(), 0xa0.toByte(), 0x80.toByte()), byteArrayOf(0xf0.toByte(), 0x9f.toByte()))) {
            assertNull(artifactTextEncoding(bytes))
            assertEquals(String(bytes, Charsets.ISO_8859_1), decodeArtifactText(bytes))
        }
    }

    @Test fun aPreviewCapDoesNotReinterpretUtf8WhenItSplitsACharacter() {
        val bytes = "café 😀".toByteArray(Charsets.UTF_8).dropLast(1).toByteArray()
        assertEquals("café ", decodeArtifactText(bytes, truncated = true))
        assertEquals("café £", decodeArtifactText("café £".toByteArray(Charsets.ISO_8859_1), truncated = true))
    }

    @Test fun aPreviewCapAlsoDropsAnIncompleteUtf16CodeUnit() {
        val bytes = byteArrayOf(0xff.toByte(), 0xfe.toByte()) + "hello".toByteArray(Charsets.UTF_16LE).dropLast(1).toByteArray()
        assertEquals("hell", decodeArtifactText(bytes, truncated = true))
    }
}
