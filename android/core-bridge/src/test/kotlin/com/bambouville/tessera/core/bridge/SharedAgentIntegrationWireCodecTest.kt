package com.bambouville.tessera.core.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedAgentIntegrationWireCodecTest {
    @Test
    fun newerHostInstallationDecodesWithItsVersion() {
        val fact = SharedAgentIntegrationWireCodec.decodeInstallation("""{"kind":"requiresAppUpdate","version":12}""")

        assertEquals(SharedAgentIntegrationInstallation.RequiresAppUpdate, fact.installation)
        assertEquals(12, fact.version)
    }

    @Test
    fun newerHostInstallationKindIsAuthoritativeWithoutAVersion() {
        listOf(
            """{"kind":"requiresAppUpdate","version":null}""",
            """{"kind":"requiresAppUpdate"}""",
        ).forEach { encoded ->
            val fact = SharedAgentIntegrationWireCodec.decodeInstallation(encoded)
            assertEquals(SharedAgentIntegrationInstallation.RequiresAppUpdate, fact.installation)
            assertNull(fact.version)
        }
    }

    @Test
    fun existingInstallationFactsKeepTheirWireValues() {
        assertEquals(
            SharedAgentIntegrationInstallation.Missing,
            SharedAgentIntegrationWireCodec.decodeInstallation("""{"kind":"missing","version":null}""").installation,
        )
        SharedAgentIntegrationWireCodec.decodeInstallation("""{"kind":"outdated","version":8}""").let {
            assertEquals(SharedAgentIntegrationInstallation.Outdated, it.installation)
            assertEquals(8, it.version)
        }
        SharedAgentIntegrationWireCodec.decodeInstallation("""{"kind":"current","version":null}""").let {
            assertEquals(SharedAgentIntegrationInstallation.Current, it.installation)
            assertNull(it.version)
        }
        assertThrows(IllegalArgumentException::class.java) {
            SharedAgentIntegrationWireCodec.decodeInstallation("""{"kind":"newer","version":12}""")
        }
    }

    @Test
    fun installationEnumRoundTripsEveryWireValue() {
        SharedAgentIntegrationInstallation.entries.forEach {
            assertEquals(it, SharedAgentIntegrationInstallation.fromWire(it.wireValue))
        }
        assertEquals("requiresAppUpdate", SharedAgentIntegrationInstallation.RequiresAppUpdate.wireValue)
    }

    @Test
    fun newerInstalledIsATerminalInstallFailure() {
        assertEquals(
            SharedAgentIntegrationInstallOutcome.Failed(SharedAgentIntegrationInstallFailure.NewerInstalled),
            SharedAgentIntegrationWireCodec.decodeInstallOutcome("""{"kind":"failed","reason":"newerInstalled"}"""),
        )
        assertEquals(
            SharedAgentIntegrationInstallOutcome.Failed(SharedAgentIntegrationInstallFailure.NotCurrent),
            SharedAgentIntegrationWireCodec.decodeInstallOutcome("""{"kind":"failed","reason":"notCurrent"}"""),
        )
        assertThrows(IllegalArgumentException::class.java) {
            SharedAgentIntegrationWireCodec.decodeInstallOutcome("""{"kind":"failed","reason":"newer"}""")
        }
        assertThrows(IllegalArgumentException::class.java) {
            SharedAgentIntegrationWireCodec.decodeInstallOutcome("""{"kind":"failed"}""")
        }
    }

    @Test
    fun decisionObservationCarriesTheNewerInstallationWireValue() {
        val encoded = SharedAgentIntegrationWireCodec.encodeDecisionRequest(
            SharedAgentIntegrationObservation(
                installation = SharedAgentIntegrationInstallation.RequiresAppUpdate,
                foreground = SharedAgentIntegrationForeground.Shell,
                shellIntegrationActive = null,
                agentIntegrationActive = false,
            ),
            requestedAction = null,
        )
        val request = org.json.JSONObject(encoded)
        val observation = request.getJSONObject("observation")

        assertEquals("requiresAppUpdate", observation.getString("installation"))
        assertEquals("shell", observation.getString("foreground"))
        assertTrue(observation.isNull("shellIntegrationActive"))
        assertTrue(request.isNull("requestedAction"))
    }

    @Test
    fun appUpdateRequiredDecisionOffersNoActionAndWarns() {
        val decision = SharedAgentIntegrationWireCodec.decodeDecision(
            """{"decision":{"kind":"appUpdateRequired"},"effectiveAction":null,"showsWarning":true}""",
        )

        assertEquals(SharedAgentIntegrationDecisionKind.AppUpdateRequired, decision.kind)
        assertNull(decision.primaryAction)
        assertNull(decision.secondaryAction)
        assertNull(decision.effectiveAction)
        assertTrue(decision.showsWarning)
        assertEquals("appUpdateRequired", SharedAgentIntegrationDecisionKind.AppUpdateRequired.wireValue)
    }

    @Test
    fun warningPresentationDelayIsReadFromThePolicy() {
        val policy = org.json.JSONObject(
            """{"currentInstallationFreshnessMilliseconds":30000,"otherInstallationFreshnessMilliseconds":5000,""" +
                """"nextCheckDelayMilliseconds":5000,"activityThrottleMilliseconds":1000,""" +
                """"warningPresentationDelayMilliseconds":5000}""",
        )

        assertEquals(5_000L, SharedAgentIntegrationWireCodec.warningPresentationDelayMillis(policy))
        assertThrows(org.json.JSONException::class.java) {
            SharedAgentIntegrationWireCodec.warningPresentationDelayMillis(org.json.JSONObject("{}"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            SharedAgentIntegrationWireCodec.warningPresentationDelayMillis(
                org.json.JSONObject("""{"warningPresentationDelayMilliseconds":-1}"""),
            )
        }
    }
}
