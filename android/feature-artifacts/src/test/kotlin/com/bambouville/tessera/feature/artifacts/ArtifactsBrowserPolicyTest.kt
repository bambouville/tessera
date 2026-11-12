package com.bambouville.tessera.feature.artifacts

import android.view.KeyEvent
import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.core.bridge.SharedArtifactsQuickOpenIntent
import com.bambouville.tessera.core.bridge.SharedArtifactsSuggestion
import com.bambouville.tessera.core.bridge.SharedArtifactsSuggestionKind
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ArtifactsBrowserPolicyTest {
    private fun tab(
        id: String, target: SharedArtifactsTarget, host: String = "h", label: String = "devbox", pinned: Boolean = false,
    ) = SharedArtifactTab(id, host, label, target, SharedArtifactsKind.Docs, id, "quickOpen", "dev", 1, 1, pinned, null, false, null)

    @Test fun exactlyOneNewTabControlAndAtMostOneOverviewControlAtEveryWidth() {
        for (wide in listOf(false, true)) for (tabShown in listOf(false, true)) {
            val chrome = artifactsChrome(wide, tabShown)
            // The overview's + is the only + drawn; a phone tab's menu is not on screen until opened.
            assertEquals("wide=$wide tab=$tabShown", if (chrome.overview) 1 else 0, chrome.visibleNewTabControls)
            assertTrue("wide=$wide tab=$tabShown", chrome.visibleOverviewControls <= 1)
            // A phone tab has no + on screen; its menu carries new tab instead.
            assertEquals(!wide && tabShown, chrome.menuNewTab)
            assertEquals(!chrome.overviewNewTab, chrome.menuNewTab)
        }
        // The overview pane beside a wide tab is the overview; no back control is drawn.
        assertEquals(0, artifactsChrome(wide = true, tabShown = true).visibleOverviewControls)
        assertEquals(1, artifactsChrome(wide = false, tabShown = true).visibleOverviewControls)
        assertEquals(0, artifactsChrome(wide = false, tabShown = false).visibleOverviewControls)
    }

    @Test fun historyAndReloadSitInTheToolbarWhenWideAndTheBottomBarOnAPhone() {
        val wide = artifactsChrome(wide = true, tabShown = true)
        assertTrue(wide.toolbarHistory); assertFalse(wide.bottomHistory)
        val phone = artifactsChrome(wide = false, tabShown = true)
        assertFalse(phone.toolbarHistory); assertTrue(phone.bottomHistory)
        val overview = artifactsChrome(wide = false, tabShown = false)
        assertFalse(overview.toolbarHistory); assertFalse(overview.bottomHistory)
    }

    @Test fun theAddressIsTheFullLocationAndStartsEditingAllSelected() {
        val laptop = tab("p", SharedArtifactsTarget.Page("http", 8001, "/laptop.html"))
        assertEquals("localhost:8001/laptop.html", artifactAddressText(laptop))
        assertEquals("localhost:8001/", artifactAddressText(tab("r", SharedArtifactsTarget.Page("http", 8001, ""))))
        assertEquals("https://localhost:8443/a?b#c", artifactAddressText(tab("s", SharedArtifactsTarget.Page("https", 8443, "/a?b#c"))))
        // A page shows where its viewer went after in-page links, on the tab's own port.
        assertEquals("localhost:8001/docs/intro.html?x=1", artifactAddressText(laptop, "http://127.0.0.1:45555/docs/intro.html?x=1"))
        assertEquals("localhost:8001/laptop.html", artifactAddressText(laptop, "data:text/html,hi"))
        assertEquals("devbox:/srv/PLAN.md", artifactAddressText(tab("f", SharedArtifactsTarget.File("/srv/PLAN.md"))))
        val edit = artifactAddressEditStart("localhost:8001/laptop.html")
        assertEquals(ArtifactAddressEdit("localhost:8001/laptop.html", 0, 26), edit)
        assertEquals(ArtifactAddressEdit("", 0, 0), artifactAddressEditStart(""))
    }

    @Test fun pagePathsRebaseOntoTheSameForwardedOrigin() {
        assertEquals("/laptop.html?x#y", artifactPagePathOf("http://127.0.0.1:45555/laptop.html?x#y"))
        assertEquals("/?q", artifactPagePathOf("https://127.0.0.1:45555?q"))
        assertEquals("/", artifactPagePathOf("http://127.0.0.1:45555"))
        assertNull(artifactPagePathOf("data:text/html,x"))
        assertNull(artifactPagePathOf("file:///etc/hosts"))
        assertEquals("http://127.0.0.1:45555/docs/", artifactRebasedPageUrl("http://127.0.0.1:45555/laptop.html?x", "/docs/"))
        assertEquals("http://127.0.0.1:45555/a", artifactRebasedPageUrl("http://127.0.0.1:45555", "a"))
    }

    @Test fun returnRetargetsPagesAndFilesOnTheirHostAndNeverAChange() {
        val page = tab("p", SharedArtifactsTarget.Page("http", 8001, "/"))
        val file = tab("f", SharedArtifactsTarget.File("/a.md"))
        val change = tab("c", SharedArtifactsTarget.Change("/a.md", "+x", "edit"))
        assertTrue(artifactNavigatesInPlace(page, "h", toChange = false))
        assertTrue(artifactNavigatesInPlace(file, "h", toChange = false))
        assertFalse("another host opens a new tab", artifactNavigatesInPlace(file, "other", toChange = false))
        assertFalse("a change is an immutable snapshot", artifactNavigatesInPlace(change, "h", toChange = false))
        assertFalse("a change is never a destination", artifactNavigatesInPlace(page, "h", toChange = true))
    }

    @Test fun openTabsAreSwitchToRowsAndEverythingElseOpens() {
        val page = SharedArtifactsQuickOpenIntent.Page("h", "http", 8001, "/laptop.html")
        assertEquals(ArtifactSuggestionChoice.SwitchTo("t"),
            artifactSuggestionChoice(SharedArtifactsSuggestion(SharedArtifactsSuggestionKind.OpenTab, "laptop", "devbox", page, "t")))
        assertEquals(ArtifactSuggestionChoice.SwitchTo("d"), artifactSuggestionChoice(SharedArtifactsSuggestion(
            SharedArtifactsSuggestionKind.Recent, "a.md", "devbox", SharedArtifactsQuickOpenIntent.File("h", "/a.md"), "d")))
        assertEquals(ArtifactSuggestionChoice.Open(artifactQuickOpenInput("/laptop.html", "http", 8001), "h"),
            artifactSuggestionChoice(SharedArtifactsSuggestion(SharedArtifactsSuggestionKind.ActiveForward, "l", "s", page, "t")))
        assertEquals(ArtifactSuggestionChoice.Open("/srv/", "h"), artifactSuggestionChoice(SharedArtifactsSuggestion(
            SharedArtifactsSuggestionKind.HostPrefix, "srv", "", SharedArtifactsQuickOpenIntent.Directory("h", "/srv"), null)))
        assertEquals(ArtifactSuggestionChoice.Search("plan"), artifactSuggestionChoice(SharedArtifactsSuggestion(
            SharedArtifactsSuggestionKind.Recent, "plan", "", SharedArtifactsQuickOpenIntent.Search("plan"), null)))
        assertEquals(ArtifactSuggestionChoice.Invalid("bad port"), artifactSuggestionChoice(SharedArtifactsSuggestion(
            SharedArtifactsSuggestionKind.Recent, "x", "", SharedArtifactsQuickOpenIntent.Invalid("bad port"), null)))
        val own = SharedArtifactsSuggestion(SharedArtifactsSuggestionKind.OpenTab, "own", "", page, "own")
        val other = own.copy(tabId = "other")
        assertEquals(listOf(other), artifactEditingSuggestions(listOf(own, other), "own"))
        assertEquals(listOf(own, other), artifactEditingSuggestions(listOf(own, other), null))
    }

    @Test fun closedTabsReopenNewestFirstWithinCapacityAndOnlyForKnownHosts() {
        val stack = ArtifactClosedTabs(capacity = 2)
        stack.push(tab("a", SharedArtifactsTarget.File("/a.md")))
        stack.push(tab("b", SharedArtifactsTarget.File("/b.md"), host = "gone"))
        stack.push(tab("c", SharedArtifactsTarget.Page("http", 8001, "/"), pinned = true))
        assertEquals(2, stack.size)
        val newest = stack.pop()!!
        assertEquals(SharedArtifactsTarget.Page("http", 8001, "/"), newest.target)
        assertTrue(newest.pinned)
        assertEquals("dev", newest.sessionHint)
        stack.push(tab("d", SharedArtifactsTarget.File("/d.md")))
        stack.retainHosts(setOf("h"))
        assertEquals(SharedArtifactsTarget.File("/d.md"), stack.pop()!!.target)
        assertNull("the removed host's tab and the one past capacity are gone", stack.pop())
    }

    @Test fun keyboardTabOrderIsOpeningOrderAndWraps() {
        val ids = listOf("a", "b", "c")
        assertEquals("b", artifactAdjacentTab(ids, "a", 1))
        assertEquals("a", artifactAdjacentTab(ids, "c", 1))
        assertEquals("c", artifactAdjacentTab(ids, "a", -1))
        assertEquals("a", artifactAdjacentTab(ids, null, 1))
        assertEquals("c", artifactAdjacentTab(ids, null, -1))
        assertNull(artifactAdjacentTab(emptyList(), null, 1))
        assertEquals("b", artifactNumberedTab(ids, ArtifactsShortcut.SelectTab(1)))
        assertNull(artifactNumberedTab(ids, ArtifactsShortcut.SelectTab(5)))
        assertEquals("c", artifactNumberedTab(ids, ArtifactsShortcut.LastTab))
    }

    private fun key(code: Int, ctrl: Boolean = false, shift: Boolean = false, alt: Boolean = false, meta: Boolean = false, text: Boolean = false) =
        artifactsShortcut(code, ctrl, shift, alt, meta, text)

    @Test fun chromeForAndroidKeysMapToBrowserCommands() {
        assertEquals(ArtifactsShortcut.NewTab, key(KeyEvent.KEYCODE_T, ctrl = true))
        assertEquals(ArtifactsShortcut.NewTab, key(KeyEvent.KEYCODE_T, meta = true))
        assertEquals(ArtifactsShortcut.ReopenClosedTab, key(KeyEvent.KEYCODE_T, ctrl = true, shift = true))
        assertEquals(ArtifactsShortcut.EditAddress, key(KeyEvent.KEYCODE_L, ctrl = true))
        assertEquals(ArtifactsShortcut.EditAddress, key(KeyEvent.KEYCODE_D, alt = true))
        assertEquals(ArtifactsShortcut.EditAddress, key(KeyEvent.KEYCODE_F6))
        assertEquals(ArtifactsShortcut.Reload, key(KeyEvent.KEYCODE_R, ctrl = true))
        assertEquals(ArtifactsShortcut.Reload, key(KeyEvent.KEYCODE_R, ctrl = true, shift = true))
        assertEquals(ArtifactsShortcut.Reload, key(KeyEvent.KEYCODE_F5))
        assertEquals(ArtifactsShortcut.Reload, key(KeyEvent.KEYCODE_REFRESH))
        assertEquals(ArtifactsShortcut.Back, key(KeyEvent.KEYCODE_DPAD_LEFT, alt = true))
        assertEquals(ArtifactsShortcut.Forward, key(KeyEvent.KEYCODE_DPAD_RIGHT, alt = true))
        assertEquals(ArtifactsShortcut.Forward, key(KeyEvent.KEYCODE_FORWARD))
        assertEquals(ArtifactsShortcut.CloseTab, key(KeyEvent.KEYCODE_W, ctrl = true))
        assertEquals(ArtifactsShortcut.CloseTab, key(KeyEvent.KEYCODE_F4, ctrl = true))
        assertEquals(ArtifactsShortcut.NextTab, key(KeyEvent.KEYCODE_TAB, ctrl = true))
        assertEquals(ArtifactsShortcut.PreviousTab, key(KeyEvent.KEYCODE_TAB, ctrl = true, shift = true))
        assertEquals(ArtifactsShortcut.NextTab, key(KeyEvent.KEYCODE_PAGE_DOWN, ctrl = true))
        assertEquals(ArtifactsShortcut.PreviousTab, key(KeyEvent.KEYCODE_PAGE_UP, ctrl = true))
        assertEquals(ArtifactsShortcut.SelectTab(0), key(KeyEvent.KEYCODE_1, ctrl = true))
        assertEquals(ArtifactsShortcut.SelectTab(7), key(KeyEvent.KEYCODE_8, ctrl = true))
        assertEquals(ArtifactsShortcut.LastTab, key(KeyEvent.KEYCODE_9, ctrl = true))
        assertEquals(ArtifactsShortcut.Overview, key(KeyEvent.KEYCODE_BACKSLASH, ctrl = true, shift = true))
    }

    @Test fun unmodifiedTypingAndOtherChordsStayWithTheFocusedControl() {
        // Plain letters, digits and Tab are typing and focus movement.
        for (code in listOf(KeyEvent.KEYCODE_T, KeyEvent.KEYCODE_L, KeyEvent.KEYCODE_W, KeyEvent.KEYCODE_1, KeyEvent.KEYCODE_TAB, KeyEvent.KEYCODE_ENTER)) {
            assertNull(key(code))
            assertNull(key(code, shift = true))
        }
        // Copy, paste, select all and find stay with the page or field.
        for (code in listOf(KeyEvent.KEYCODE_C, KeyEvent.KEYCODE_V, KeyEvent.KEYCODE_A, KeyEvent.KEYCODE_F, KeyEvent.KEYCODE_Z)) {
            assertNull(key(code, ctrl = true))
        }
        assertNull(key(KeyEvent.KEYCODE_T, ctrl = true, alt = true))
        assertNull(key(KeyEvent.KEYCODE_L, ctrl = true, shift = true))
        assertNull(key(KeyEvent.KEYCODE_W, ctrl = true, shift = true))
        assertNull(key(KeyEvent.KEYCODE_BACKSLASH, ctrl = true))
        assertNull(key(KeyEvent.KEYCODE_1, ctrl = true, shift = true))
        // Alt+arrows move a field's caret by word on a Mac keyboard.
        assertNull(key(KeyEvent.KEYCODE_DPAD_LEFT, alt = true, text = true))
        assertNull(key(KeyEvent.KEYCODE_DPAD_RIGHT, alt = true, text = true))
        assertNull(key(KeyEvent.KEYCODE_DPAD_LEFT, alt = true, shift = true))
        assertNull(key(KeyEvent.KEYCODE_DPAD_LEFT))
        // Text-field focus does not change the Ctrl commands, as in Chrome's omnibox.
        assertEquals(ArtifactsShortcut.NewTab, key(KeyEvent.KEYCODE_T, ctrl = true, text = true))
    }

    @Test fun onlyFilesShareAndOnlyTheirCompleteCachedCopy() {
        val file = tab("f", SharedArtifactsTarget.File("/srv/PLAN.md"))
        val cachedFile = File("/cache/PLAN.md")
        val cached = ArtifactContent.Document(cachedFile, "PLAN.md", 0, emptyMap())
        assertEquals(ArtifactShare.Ready(cachedFile, "PLAN.md"), artifactShare(file, cached, null))
        assertEquals(ArtifactShare.Ready(cachedFile, "PLAN.md"), artifactShare(file, cached.copy(displayName = ""), null))
        assertEquals(ArtifactShare.Unavailable(ARTIFACT_SHARE_DOWNLOADING), artifactShare(file, ArtifactContent.Loading, null))
        assertEquals(ArtifactShare.Unavailable(ARTIFACT_SHARE_TOO_LARGE),
            artifactShare(file, ArtifactContent.Unavailable(ArtifactUnavailable.TooLarge(1L shl 30)), null))
        assertEquals(ArtifactShare.Unavailable(ARTIFACT_SHARE_NOT_DOWNLOADED),
            artifactShare(file, ArtifactContent.Unavailable(ArtifactUnavailable.Offline), null))
        assertEquals("an offline tab shares the copy it already holds", ArtifactShare.Ready(cachedFile, "PLAN.md"),
            artifactShare(file, ArtifactContent.Unavailable(ArtifactUnavailable.Offline), cached))
        val html = tab("s", SharedArtifactsTarget.File("/site/report.html"))
        val served = ArtifactContent.ServedPage("https://artifact/report.html", ArtifactSftpInterceptorStub.value)
        assertEquals(ArtifactShare.Unavailable(ARTIFACT_SHARE_DOWNLOADING), artifactShare(html, served, null))
        val report = ArtifactContent.Document(File("/cache/report.html"), "report.html", 0, emptyMap())
        assertEquals(ArtifactShare.Ready(File("/cache/report.html"), "report.html"), artifactShare(html, served, report))
        // A forwarded page's localhost address means nothing to a friend; a change is a diff.
        val page = tab("p", SharedArtifactsTarget.Page("http", 8001, "/"))
        assertNull(artifactShare(page, ArtifactContent.ForwardedPage("http://127.0.0.1:1/", "x", true), null))
        assertNull(artifactShare(page, ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding), cached))
        val change = tab("c", SharedArtifactsTarget.Change("/a.md", "+x", "edit"))
        assertNull(artifactShare(change, ArtifactContent.Change("/a.md", "+x"), null))
    }
}

private object ArtifactSftpInterceptorStub {
    val value = com.bambouville.tessera.feature.artifacts.viewers.ArtifactSftpInterceptor(
        "s", "/site/report.html", com.bambouville.tessera.feature.artifacts.viewers.ArtifactRemoteReader { _, _, _ -> ByteArray(0) },
    )
}
