package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.files.FilesConnectionUnavailableException
import com.bambouville.tessera.files.FilesRouteUnavailableException
import java.io.IOException
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class ArtifactsPresentationTest {
    @Test fun fileKindsNeverUseAFolderGlyph() {
        assertSame(TesseraIcons.File, artifactKindIcon(SharedArtifactsKind.Files))
        assertSame(TesseraIcons.File, artifactKindIcon(SharedArtifactsKind.Docs))
        assertSame(TesseraIcons.Tunnels, artifactKindIcon(SharedArtifactsKind.Pages))
        assertSame(TesseraIcons.Pencil, artifactKindIcon(SharedArtifactsKind.Changes))
    }

    @Test fun cacheAgeChangesAtMinuteHourAndDayBoundaries() {
        assertEquals(ArtifactAge(ArtifactAgeUnit.JustNow, 0), artifactAge(0, 59_999))
        assertEquals(ArtifactAge(ArtifactAgeUnit.Minutes, 1), artifactAge(0, 60_000))
        assertEquals(ArtifactAge(ArtifactAgeUnit.Minutes, 59), artifactAge(0, 3_599_999))
        assertEquals(ArtifactAge(ArtifactAgeUnit.Hours, 1), artifactAge(0, 3_600_000))
        assertEquals(ArtifactAge(ArtifactAgeUnit.Hours, 23), artifactAge(0, 86_399_999))
        assertEquals(ArtifactAge(ArtifactAgeUnit.Days, 1), artifactAge(0, 86_400_000))
    }

    @Test fun futureClockAndOverflowNeverProduceNegativeOrFreshAncientAges() {
        assertEquals(ArtifactAge(ArtifactAgeUnit.JustNow, 0), artifactAge(20_000, 10_000))
        assertEquals(ArtifactAge(ArtifactAgeUnit.JustNow, 0), artifactAge(Long.MAX_VALUE, Long.MIN_VALUE))
        assertEquals(ArtifactAge(ArtifactAgeUnit.Days, 106_751_991_167), artifactAge(Long.MIN_VALUE, Long.MAX_VALUE))
    }

    @Test fun unavailableFileSizeUsesBinaryUnitsAndDoesNotDependOnLocale() {
        val before = Locale.getDefault()
        try {
            Locale.setDefault(Locale.FRANCE)
            assertEquals(null, artifactByteCount(-1))
            assertEquals("1023 B", artifactByteCount(1023))
            assertEquals("1.0 KiB", artifactByteCount(1024))
            assertEquals("90.0 MiB", artifactByteCount(90L * 1024 * 1024))
            assertEquals("2.0 GiB", artifactByteCount(2L * 1024 * 1024 * 1024))
        } finally {
            Locale.setDefault(before)
        }
    }

    @Test fun aMissingFilesConnectionShowsTranslatedTextWhileOtherFailuresKeepTheirOwn() {
        val fallback = R.string.artifacts_open_artifact_failed
        assertEquals(ArtifactMessage.Resource(R.string.artifacts_files_connection_unavailable),
            artifactFailureMessage(FilesConnectionUnavailableException(), fallback))
        assertEquals(ArtifactMessage.Resource(R.string.artifacts_terminal_not_connected),
            artifactFailureMessage(FilesRouteUnavailableException(FilesRouteUnavailableException.Reason.NotConnected), fallback))
        assertEquals(ArtifactMessage.Resource(R.string.artifacts_route_unavailable),
            artifactFailureMessage(FilesRouteUnavailableException(FilesRouteUnavailableException.Reason.RouteUnavailable), fallback))
        assertEquals(ArtifactMessage.Verbatim("channel refused"), artifactFailureMessage(IOException("channel refused"), fallback))
        assertEquals(ArtifactMessage.Resource(fallback), artifactFailureMessage(IOException(), fallback))
    }

    /** A suggestion the core marks invalid reads like quick open's own refusal, not its reason code. */
    @Test fun aQuickOpenRefusalIsTranslatedByItsReasonCode() {
        assertEquals(ArtifactMessage.Resource(R.string.artifacts_error_missing_cwd), artifactQuickOpenFailure("missingCwd"))
        assertEquals(ArtifactMessage.Resource(R.string.artifacts_error_unknown_host), artifactQuickOpenFailure("unknownHost"))
        assertEquals(ArtifactMessage.Resource(R.string.artifacts_error_unresolved), artifactQuickOpenFailure("somethingNew"))
    }

    @Test fun provenanceNamesTheOriginAndPreservesUnknownSources() {
        assertEquals(ArtifactMessage.Resource(R.string.artifacts_opened_from_terminal_selection), artifactOpenedFrom("terminalSelection"))
        assertEquals(ArtifactMessage.Resource(R.string.artifacts_opened_from_agent_edit), artifactOpenedFrom("AgentEdit"))
        assertEquals(ArtifactMessage.Resource(R.string.artifacts_opened_from_files), artifactOpenedFrom("files"))
        assertEquals(ArtifactMessage.Resource(R.string.artifacts_opened_from_other, listOf("import extension")), artifactOpenedFrom("import extension"))
        assertEquals(ArtifactMessage.Resource(R.string.artifacts_opened_from_session), artifactOpenedFrom(""))
    }

    @Test fun suggestionInputPreservesPageSchemeRouteQueryAndFragment() {
        assertEquals("https://localhost:8443/a%20b?q=one%2Ftwo#part", artifactQuickOpenInput("/a%20b?q=one%2Ftwo#part", "https", 8443))
        assertEquals("http://localhost:5173/", artifactQuickOpenInput("/", port = 5173))
        assertEquals("/srv/docs/notes: draft.md", artifactQuickOpenInput("/srv/docs/notes: draft.md"))
    }
}
