package com.bambouville.tessera.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ShareUploadTest {
    @Test
    fun `paste path restores explicit false and true independently of destination`() {
        for (isTemp in listOf(false, true)) {
            assertTrue(ShareUploadPolicy.defaultPastePath(true, isTemp, true))
            assertFalse(ShareUploadPolicy.defaultPastePath(false, isTemp, true))
            assertFalse(ShareUploadPolicy.defaultPastePath(true, isTemp, false))
        }
        assertTrue(ShareUploadPolicy.defaultPastePath(null, true, true))
        assertFalse(ShareUploadPolicy.defaultPastePath(null, false, true))
        assertFalse(ShareUploadPolicy.defaultPastePath(null, true, false))
        assertEquals("tessera.files.lastPastePath.first", ShareUploadPolicy.rememberedPastePathKey("first"))
        assertEquals("tessera.files.lastPastePath.second", ShareUploadPolicy.rememberedPastePathKey("second"))
    }

    private fun target(
        id: String,
        label: String = id,
        connected: Boolean = false,
        connecting: Boolean = false,
        active: Boolean = false,
        failed: Boolean = false,
        cwd: String? = null,
    ) = ShareUploadTarget(
        id = id,
        label = label,
        detail = "dev@$label",
        isConnected = connected,
        isConnecting = connecting,
        isActiveSession = active,
        isFailed = failed,
        sessionCwd = cwd,
    )

    @Test
    fun `ordering puts the active session first then connected then connecting`() {
        val ordered = ShareUploadPolicy.ordered(
            listOf(
                target("z", "zeta"),
                target("c", "connecting", connecting = true),
                target("a", "alpha"),
                target("k", "kilo", connected = true),
                target("m", "mike", connected = true, active = true),
            ),
        )

        assertEquals(listOf("m", "k", "c", "a", "z"), ordered.map(ShareUploadTarget::id))
    }

    @Test
    fun `a row that changes state mid-sheet keeps its position`() {
        val order = listOf("a", "b", "c")
        // "c" finished connecting and would now sort to the top.
        val live = listOf(
            target("a", "alpha"),
            target("b", "bravo"),
            target("c", "charlie", connected = true, active = true),
        )

        assertEquals(order, ShareUploadPolicy.frozen(order, live).map(ShareUploadTarget::id))
    }

    @Test
    fun `hosts added after the sheet opened append instead of reshuffling`() {
        val frozen = ShareUploadPolicy.frozen(
            order = listOf("b"),
            live = listOf(target("b", "bravo"), target("a", "alpha", connected = true)),
        )

        assertEquals(listOf("b", "a"), frozen.map(ShareUploadTarget::id))
    }

    @Test
    fun `a host that disappeared while the sheet was up drops out of the rows`() {
        val frozen = ShareUploadPolicy.frozen(
            order = listOf("a", "gone", "b"),
            live = listOf(target("a"), target("b")),
        )

        assertEquals(listOf("a", "b"), frozen.map(ShareUploadTarget::id))
    }

    @Test
    fun `every selectable host can take a pasted path`() {
        assertTrue(ShareUploadPolicy.canPastePath(target("a", connected = true)))
        assertTrue(ShareUploadPolicy.canPastePath(target("a", connecting = true)))
        // A cold host is the case the share sheet exists for: the upload
        // gesture opens its session and the path is typed once it lands.
        assertTrue(ShareUploadPolicy.canPastePath(target("a")))
        assertTrue(ShareUploadPolicy.canPastePath(target("a", failed = true)))
        // No hosts at all is the only state with nothing to paste into.
        assertFalse(ShareUploadPolicy.canPastePath(null))
    }

    @Test
    fun `liveness only decides the wording, never the offer`() {
        assertTrue(ShareUploadPolicy.hasLiveSession(target("a", connected = true)))
        assertTrue(ShareUploadPolicy.hasLiveSession(target("a", connecting = true)))
        assertFalse(ShareUploadPolicy.hasLiveSession(target("a")))
        assertFalse(ShareUploadPolicy.hasLiveSession(target("a", failed = true)))
        assertFalse(ShareUploadPolicy.hasLiveSession(null))
    }

    @Test
    fun `status text distinguishes every row state`() {
        assertEquals(
            "connected · active session",
            ShareUploadPolicy.status(target("a", connected = true, active = true)),
        )
        assertEquals("connected", ShareUploadPolicy.status(target("a", connected = true)))
        assertEquals("connecting…", ShareUploadPolicy.status(target("a", connecting = true)))
        assertEquals("reconnect failed", ShareUploadPolicy.status(target("a", failed = true)))
        assertEquals("connect on upload…", ShareUploadPolicy.status(target("a")))
        assertEquals(
            "connect on paste…",
            ShareUploadPolicy.status(target("a"), ShareTextMode.PasteIntoSession),
        )
        // A live row reads the same either way — the state is the story there.
        assertEquals(
            "connected",
            ShareUploadPolicy.status(target("a", connected = true), ShareTextMode.PasteIntoSession),
        )
    }

    @Test
    fun `the button admits when it has to open a session first`() {
        assertEquals("Upload", ShareUploadPolicy.ctaTitle(target("a", connected = true)))
        assertEquals("Upload", ShareUploadPolicy.ctaTitle(target("a", connecting = true)))
        assertEquals("Connect & upload", ShareUploadPolicy.ctaTitle(target("a")))
        assertEquals("Connect & upload", ShareUploadPolicy.ctaTitle(target("a", failed = true)))
        assertEquals(
            "Paste",
            ShareUploadPolicy.ctaTitle(target("a", connected = true), ShareTextMode.PasteIntoSession),
        )
        assertEquals(
            "Paste",
            ShareUploadPolicy.ctaTitle(target("a", connecting = true), ShareTextMode.PasteIntoSession),
        )
        assertEquals(
            "Connect & paste",
            ShareUploadPolicy.ctaTitle(target("a"), ShareTextMode.PasteIntoSession),
        )
        assertEquals(
            "Connect & paste",
            ShareUploadPolicy.ctaTitle(target("a", failed = true), ShareTextMode.PasteIntoSession),
        )
        assertEquals("Paste", ShareUploadPolicy.ctaTitle(null, ShareTextMode.PasteIntoSession))
        assertEquals("Upload", ShareUploadPolicy.ctaTitle(null))
    }

    @Test
    fun `a remembered cwd is honoured only once a cwd is actually known`() {
        val withCwd = target("a", connected = true, cwd = "/srv/app")
        assertEquals(
            ShareUploadDestination.SessionCwd("/srv/app"),
            ShareUploadPolicy.defaultDestination(withCwd, ShareUploadPolicy.REMEMBERED_CWD),
        )
        assertEquals(
            ShareUploadDestination.Temp,
            ShareUploadPolicy.defaultDestination(target("a", connected = true), ShareUploadPolicy.REMEMBERED_CWD),
        )
        assertEquals(
            ShareUploadDestination.Temp,
            ShareUploadPolicy.defaultDestination(withCwd, ShareUploadPolicy.REMEMBERED_TEMP),
        )
        assertEquals(ShareUploadDestination.Temp, ShareUploadPolicy.defaultDestination(null, null))
    }

    @Test
    fun `a cwd arriving mid-sheet upgrades a preference that was forced to temp`() {
        assertTrue(ShareUploadPolicy.upgradeToCwd(forcedTempForMissingCwd = true, cwd = "/srv/app"))
        assertFalse(ShareUploadPolicy.upgradeToCwd(forcedTempForMissingCwd = true, cwd = null))
        assertFalse(ShareUploadPolicy.upgradeToCwd(forcedTempForMissingCwd = true, cwd = ""))
        assertFalse(ShareUploadPolicy.upgradeToCwd(forcedTempForMissingCwd = false, cwd = "/srv/app"))
    }

    @Test
    fun `the remembered value round-trips both destinations`() {
        assertEquals(
            ShareUploadPolicy.REMEMBERED_CWD,
            ShareUploadPolicy.rememberedValue(ShareUploadDestination.SessionCwd("/srv")),
        )
        assertEquals(
            ShareUploadPolicy.REMEMBERED_TEMP,
            ShareUploadPolicy.rememberedValue(ShareUploadDestination.Temp),
        )
        assertEquals("tessera.files.lastDest.abc", ShareUploadPolicy.rememberedDestinationKey("abc"))
    }

    @Test
    fun `a path that cannot reach the terminal always reaches the clipboard`() {
        val copied = mutableListOf<String>()

        assertEquals(
            ShareUploadDeliveryOutcome.CLIPBOARD_FALLBACK,
            ShareUploadDelivery.deliver(
                path = "/srv/app/paste-1.png",
                pastePath = true,
                injectIntoTerminal = { false },
                copyToClipboard = copied::add,
            ),
        )
        assertEquals(listOf("/srv/app/paste-1.png"), copied)
    }

    @Test
    fun `a live terminal takes the path and the clipboard is left alone`() {
        val copied = mutableListOf<String>()
        val typed = mutableListOf<String>()

        assertEquals(
            ShareUploadDeliveryOutcome.TERMINAL,
            ShareUploadDelivery.deliver(
                path = "/srv/app/paste-1.png",
                pastePath = true,
                injectIntoTerminal = { typed.add(it); true },
                copyToClipboard = copied::add,
            ),
        )
        assertEquals(listOf("/srv/app/paste-1.png"), typed)
        assertTrue(copied.isEmpty())
    }

    @Test
    fun `an upload with paste path off delivers nothing anywhere`() {
        val copied = mutableListOf<String>()

        assertEquals(
            ShareUploadDeliveryOutcome.NONE,
            ShareUploadDelivery.deliver(
                path = "/srv/app/report.pdf",
                pastePath = false,
                injectIntoTerminal = { error("must not be asked") },
                copyToClipboard = copied::add,
            ),
        )
        assertTrue(copied.isEmpty())
    }

    @Test
    fun `temp names carry the reaper prefix and drop the original basename`() {
        val name = ShareUploadPaths.tempFileName("holiday in Rome.JPEG", "20260905-101530", "a1b2")

        assertEquals("paste-20260905-101530-a1b2.JPEG", name)
        assertTrue(ShareUploadPaths.isReapable(name))
        assertFalse(name.contains("holiday"))
    }

    @Test
    fun `an extension-less share still gets a usable temp name`() {
        assertEquals(
            "paste-20260905-101530-a1b2",
            ShareUploadPaths.tempFileName("Makefile", "20260905-101530", "a1b2"),
        )
    }

    @Test
    fun `only the reaper prefix marks a file as collectable`() {
        assertFalse(ShareUploadPaths.isReapable("important.tar.zst"))
        assertFalse(ShareUploadPaths.isReapable("not-paste-1.png"))
        assertTrue(ShareUploadPaths.isReapable("paste-20260905-101530-a1b2.png"))
    }

    @Test
    fun `the temp directory hangs off home without doubling a slash`() {
        assertEquals("/home/dev/.cache/tessera", ShareUploadPaths.tempDirectory("/home/dev"))
        assertEquals("/home/dev/.cache/tessera", ShareUploadPaths.tempDirectory("/home/dev/"))
        assertEquals("/.cache/tessera", ShareUploadPaths.tempDirectory("/"))
    }

    @Test
    fun `home abbreviation only fires on a real home prefix`() {
        assertEquals("~/projects", ShareUploadPaths.abbreviateHome("/home/dev/projects", "/home/dev"))
        assertEquals("~", ShareUploadPaths.abbreviateHome("/home/dev", "/home/dev"))
        assertEquals("/home/developer", ShareUploadPaths.abbreviateHome("/home/developer", "/home/dev"))
        assertEquals("/srv/app", ShareUploadPaths.abbreviateHome("/srv/app", "/"))
        assertEquals("/srv/app", ShareUploadPaths.abbreviateHome("/srv/app", null))
    }
}
