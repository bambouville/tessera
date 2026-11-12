package com.bambouville.tessera.feature.artifacts.viewers

import org.junit.Assert.assertEquals
import org.junit.Test

class ArtifactWebNavigationTest {
    private val origin = "https://tab.artifact.tessera.invalid/index.html"

    @Test fun everyExternalAppRequiresAGesture() {
        for (target in listOf(
            "tel:12345", "sms:12345", "geo:0,0", "mailto:user@example.org", "https://example.org/", "http://example.org/",
        )) {
            assertEquals(target, ArtifactWebNavigation.Blocked, artifactWebNavigation(origin, target, true, false))
            assertEquals(target, ArtifactWebNavigation.External, artifactWebNavigation(origin, target, true, true))
        }
    }

    @Test fun sameOriginScriptNavigationStaysInThePage() {
        assertEquals(ArtifactWebNavigation.InPage, artifactWebNavigation(origin, "https://tab.artifact.tessera.invalid/next", true, false))
        assertEquals(ArtifactWebNavigation.InPage, artifactWebNavigation("http://127.0.0.1:5173/", "http://127.0.0.1:5173/next", true, false))
        assertEquals(ArtifactWebNavigation.Blocked, artifactWebNavigation("http://127.0.0.1:5173/", "http://127.0.0.1:8080/", true, false))
    }

    @Test fun aGestureCannotSendAnyPageToADeviceLocalAddress() {
        val hosts = listOf(
            "127.0.0.1", "127.42.9.8", "127.1", "2130706433", "0x7f000001", "0177.0.0.1",
            "localhost", "LOCALHOST.", "app.localhost", "0.0.0.0", "0", "[::1]", "[::]",
            "[0:0:0:0:0:0:0:1]", "[::ffff:127.0.0.1]", "[::ffff:7f00:1]", "[::ffff:0:0]",
            "[::127.0.0.1]", "[::7f00:1]", "[0:0:0:0:0:0:7f2a:908]",
            "127%2e0%2e0%2e1", "%6cocalhost",
        )
        for (initial in listOf(origin, "http://127.0.0.1:5173/", "https://example.org/")) {
            for (host in hosts) for (scheme in listOf("http", "https")) for (userinfo in listOf("", "user:password@")) {
                val target = "$scheme://$userinfo$host:8080/private"
                assertEquals("$initial -> $target", ArtifactWebNavigation.Blocked, artifactWebNavigation(initial, target, true, true))
            }
        }
    }

    @Test fun sameOriginLoopbackNavigationStaysInsideItsForward() {
        for (host in listOf("127.0.0.1", "localhost", "[::1]", "[::ffff:7f00:1]", "[::7f00:1]")) {
            for (gesture in listOf(false, true)) {
                val initial = "http://$host:5173/"
                assertEquals(initial, ArtifactWebNavigation.InPage, artifactWebNavigation(initial, "${initial}next", true, gesture))
            }
        }
    }

    @Test fun publicLookalikesAndNonLoopbackMappedAddressesCanStillOpenExternally() {
        for (host in listOf("localhost.example.org", "127.example.org", "128.0.0.1", "[2001:db8::1]", "[::ffff:c000:201]", "[::c000:201]")) {
            val target = "https://$host/"
            assertEquals(target, ArtifactWebNavigation.External, artifactWebNavigation(origin, target, true, true))
        }
    }

    @Test fun aGestureCannotAuthorizeAppPrivateOrIntentUrls() {
        for (target in listOf("file:///private/key", "content://private/key", "intent://open/#Intent;end", "javascript:alert(1)", "data:text/html,hi")) {
            assertEquals(target, ArtifactWebNavigation.Blocked, artifactWebNavigation(origin, target, true, true))
        }
    }

    @Test fun subframesCannotLaunchAppsAndForwardedSubresourcesStillLoad() {
        assertEquals(ArtifactWebNavigation.Blocked, artifactWebNavigation(origin, "tel:12345", false, true))
        assertEquals(ArtifactWebNavigation.Blocked, artifactWebNavigation(origin, "mailto:user@example.org", false, false))
        assertEquals(ArtifactWebNavigation.InPage, artifactWebNavigation("http://127.0.0.1:5173/", "http://127.0.0.1:8080/api", false, false))
    }
}
