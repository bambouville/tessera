package com.bambouville.tessera.core.bridge

import org.junit.Assert.assertEquals
import org.junit.Test

class SharedAgentComposerLiteralImageTest {
    @Test fun optionalLiteralImageModeRequiresEveryPathUnconverted() {
        val text = "\"/tmp/a.png\"\n\"/tmp/b.png\""
        for ((body, normal, literal) in listOf(
            Triple(text, SharedAgentComposerEvidence.Assessment.UNAVAILABLE, SharedAgentComposerEvidence.Assessment.RETURN),
            Triple("[Image #4]\n\"/tmp/b.png\"", SharedAgentComposerEvidence.Assessment.UNAVAILABLE, SharedAgentComposerEvidence.Assessment.UNAVAILABLE),
            Triple("[Image #4]\n[Image #5]", SharedAgentComposerEvidence.Assessment.RETURN, SharedAgentComposerEvidence.Assessment.UNAVAILABLE),
        )) {
            fun assess(literalOnly: Boolean) = SharedAgentComposerEvidence.assess("claude", "❯ $body\n────\n? for shortcuts",
                body.substringAfterLast('\n'), text, false, cursorRow = 1, safetyOnly = true, cursorVisible = true,
                literalImagePathsOnly = literalOnly)
            assertEquals(normal, assess(false))
            assertEquals(literal, assess(true))
        }
    }
}
