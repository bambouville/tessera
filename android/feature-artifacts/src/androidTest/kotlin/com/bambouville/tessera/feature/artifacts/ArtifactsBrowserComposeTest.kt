package com.bambouville.tessera.feature.artifacts

import android.app.Activity
import android.app.Instrumentation
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.view.KeyEvent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.text.TextRange
import androidx.core.content.IntentCompat
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import java.io.File
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.core.bridge.SharedArtifactsCachePresentation
import com.bambouville.tessera.core.bridge.SharedArtifactsCacheState
import com.bambouville.tessera.design.TesseraTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class ArtifactsBrowserComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ArtifactsFixtureActivity>()

    private fun show(
        scene: ArtifactsHarnessScene = ArtifactsHarnessScene.Overview,
        wide: Boolean = false,
        dark: Boolean = true,
    ): ArtifactHarnessStore {
        val store = ArtifactHarnessStore.create(compose.activity, scene)
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture {
                TesseraTheme(darkTheme = dark) {
                    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
                        ArtifactsBrowser(store, Modifier.requiredWidth(if (wide) 840.dp else 390.dp).fillMaxHeight())
                    }
                }
            }
        }
        return store
    }

    @Test fun missingStoreShowsRootTagAndNamesTheSources() {
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture { TesseraTheme { ArtifactsRootScreen() } }
        }
        compose.onNodeWithTag("artifacts-page").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-overview").assertIsDisplayed()
        compose.onNodeWithText("open a file from Files, a path or localhost link from a terminal, a forwarded page, or an agent edit").assertIsDisplayed()
    }

    @Test fun emptyStoreHasNoSearchOrFiltersAndStillOffersQuickOpen() {
        show(ArtifactsHarnessScene.Empty)
        compose.onNodeWithTag("artifacts-overview").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-quick-open").assertIsDisplayed()
        compose.onAllNodesWithTag("artifacts-search").assertCountEquals(0)
        for (kind in listOf("all", "docs", "pages", "changes", "files")) {
            compose.onAllNodesWithTag("artifacts-filter-$kind").assertCountEquals(0)
        }
        compose.onNodeWithText("open a file from Files, a path or localhost link from a terminal, a forwarded page, or an agent edit").assertIsDisplayed()
    }

    @Test fun searchFindsUnseenEditAndSelectionReturnsToTheOverviewOnBack() {
        val store = show()
        compose.onNodeWithTag("artifacts-overview").assertIsDisplayed()
        for (kind in listOf("all", "docs", "pages", "changes", "files")) {
            compose.onNodeWithTag("artifacts-filter-$kind").assertExists()
        }
        compose.onNodeWithTag("artifacts-search").performTextReplacement("agent-updated")
        compose.onNodeWithTag("artifacts-row-unseen").assertIsDisplayed()
        compose.onNodeWithContentDescription("unseen change", useUnmergedTree = true).assertExists()
        compose.onNodeWithTag("artifacts-row-unseen").performClick()
        compose.onNodeWithTag("artifacts-tab-unseen").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-overview-back").assertIsDisplayed()
        compose.onAllNodesWithTag("artifacts-overview").assertCountEquals(0)
        compose.runOnIdle {
            assertEquals("unseen", store.visibleTabId)
            assertFalse(store.state.value.tabs.first { it.id == "unseen" }.unseenChange)
            compose.activity.onBackPressedDispatcher.onBackPressed()
        }
        compose.onNodeWithTag("artifacts-overview").assertIsDisplayed()
        compose.runOnIdle { assertNull(store.visibleTabId) }
    }

    @Test fun filtersShowOnlyTheirKindAndEmptySearchIsExplicit() {
        show()
        compose.onNodeWithTag("artifacts-filter-changes").performScrollTo().performClick()
        compose.onNodeWithTag("artifacts-row-diff").assertIsDisplayed()
        compose.onAllNodesWithTag("artifacts-row-plan").assertCountEquals(0)
        compose.onNodeWithTag("artifacts-search").performTextReplacement("no such artifact")
        compose.onNodeWithText("no matching tabs").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-search").assertIsDisplayed()
        for (kind in listOf("all", "docs", "pages", "changes", "files")) {
            compose.onNodeWithTag("artifacts-filter-$kind").assertExists()
        }
    }

    @Test fun closingTheLastTabsHidesTheSearchAndFilters() {
        val store = show()
        compose.onNodeWithTag("artifacts-search").performTextReplacement("no such artifact")
        compose.runOnIdle {
            store.state.value.tabs.map { it.hostId }.distinct().forEach { store.closeAll(it) }
        }
        compose.onAllNodesWithTag("artifacts-search").assertCountEquals(0)
        for (kind in listOf("all", "docs", "pages", "changes", "files")) {
            compose.onAllNodesWithTag("artifacts-filter-$kind").assertCountEquals(0)
        }
        compose.onNodeWithTag("artifacts-quick-open").assertIsDisplayed()
    }

    @Test fun cachedCopyCanBeReadInLightThemeAndCannotRefresh() {
        show(ArtifactsHarnessScene.Cached, dark = false)
        compose.onNodeWithTag("artifacts-content").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-refresh").assertIsNotEnabled()
        compose.onNodeWithText("archive is offline · showing the saved copy").assertIsDisplayed()
    }

    @Test fun revisionOnlyLivenessChangeDisablesRefreshWithoutChangingTabs() {
        val store = show(ArtifactsHarnessScene.Stale)
        compose.onNodeWithTag("artifacts-refresh").assertIsEnabled()
        val before = store.state.value
        compose.runOnIdle {
            store.replacePresentation("stale", SharedArtifactsCachePresentation(SharedArtifactsCacheState.Offline, null, false))
        }
        compose.onNodeWithTag("artifacts-refresh").assertIsNotEnabled()
        compose.onNodeWithContentDescription("offline").assertIsDisplayed()
        compose.runOnIdle { assertSame(before, store.state.value) }
    }

    @Test fun fileRefreshUsesTheStoreWhileItsConnectionIsLive() {
        val store = show(ArtifactsHarnessScene.Stale)
        compose.onNodeWithTag("artifacts-refresh").performClick()
        compose.runOnIdle { assertEquals(listOf("stale"), store.refreshes) }
    }

    @Test fun offlinePageNamesTheHostAndOffersNoConnectionAction() {
        show(ArtifactsHarnessScene.Offline)
        compose.onNodeWithText("connect a session to archive to load it").assertIsDisplayed()
        compose.onAllNodesWithText("connect", substring = false).assertCountEquals(0)
        compose.onNodeWithTag("artifacts-refresh").assertIsNotEnabled()
    }

    @Test fun moshUnavailableExplainsTheExistingSessionRequirement() {
        show(ArtifactsHarnessScene.NoForwarding)
        compose.onNodeWithText("pages on mosh hosts open while Files or an ssh session is connected").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-refresh").assertIsNotEnabled()
    }

    @Test fun aMoshPageLoadsThroughTheHostsFilesConnection() {
        val store = show(ArtifactsHarnessScene.MoshFiles)
        compose.onNodeWithText("no page connection").assertIsDisplayed()
        compose.onNodeWithText("mosh-host is connected; load opens its Files connection").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-files-reconnect").performClick()
        compose.runOnIdle { assertEquals(listOf("mosh-files"), store.fileConnections) }
        compose.onNodeWithTag("artifacts-refresh").assertIsEnabled().performClick()
        compose.runOnIdle {
            assertEquals(listOf("mosh-files", "mosh-files"), store.fileConnections)
            assertTrue(store.refreshes.isEmpty())
        }
    }

    @Test fun aFailedPageRetriesThroughTheStoreWithoutAViewer() {
        val store = show(ArtifactsHarnessScene.FailedPage)
        compose.onNodeWithText("the forward to port 5174 was refused").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-retry").performClick()
        compose.runOnIdle { assertEquals(listOf("failed-page"), store.refreshes) }
        compose.onNodeWithTag("artifacts-refresh").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(listOf("failed-page", "failed-page"), store.refreshes) }
    }

    @Test fun pinAndCloseAllUseTheHostOfTheDisplayedTab() {
        val store = show(ArtifactsHarnessScene.Live)
        compose.onNodeWithTag("artifacts-tab-menu").performClick()
        compose.onNodeWithTag("artifacts-menu-pin").performClick()
        compose.runOnIdle { assertFalse(store.state.value.tabs.first { it.id == "plan" }.pinned) }
        compose.onNodeWithTag("artifacts-tab-menu").performClick()
        compose.onNodeWithTag("artifacts-menu-close-host").performClick()
        compose.onNodeWithTag("artifacts-overview").assertIsDisplayed()
        compose.runOnIdle {
            assertTrue(store.state.value.tabs.none { it.hostId == "api" })
            assertTrue(store.state.value.tabs.any { it.hostId == "build" })
            assertNull(store.visibleTabId)
        }
    }

    @Test fun copyPathPutsTheDisplayedTabsAddressOnTheClipboard() {
        val store = show(ArtifactsHarnessScene.Live)
        val address = compose.runOnIdle { artifactTabAddress(store.state.value.tabs.first { it.id == "plan" }) }
        val clipboard = compose.activity.getSystemService(ClipboardManager::class.java)
        compose.onNodeWithTag("artifacts-tab-menu").performClick()
        compose.onNodeWithTag("artifacts-menu-copy").performClick()
        compose.waitUntil(5_000) {
            compose.runOnUiThread { clipboard.primaryClip?.takeIf { it.itemCount == 1 }?.getItemAt(0)?.text?.toString() } == address
        }
        compose.runOnUiThread { assertEquals("artifact path", clipboard.primaryClipDescription?.label) }
    }

    @Test fun quickOpenKeepsDirectoryAndFailureInlineThenGoOpensAFileInANewTab() {
        val store = show()
        compose.onNodeWithTag("artifacts-quick-open").performClick()
        compose.onNodeWithText("new tab").assertIsDisplayed()
        // The open field is ready to type into, as a browser's new tab is.
        compose.onNodeWithTag("artifacts-new-tab-field").assertIsFocused()
        compose.onNodeWithTag("artifacts-quick-host-api").performClick()
        compose.onNodeWithTag("artifacts-new-tab-field").performTextReplacement("/srv/tessera/")
        compose.onNodeWithTag("artifacts-new-tab-field").performImeAction()
        compose.onNodeWithText("browse /srv/tessera/ in Files").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-new-tab-field").performTextReplacement("/not-in-fixture.md")
        compose.onNodeWithTag("artifacts-new-tab-field").performImeAction()
        compose.onNodeWithText("this path is not in the visual fixture").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-new-tab-field").performTextReplacement("/srv/tessera/PLAN.md")
        compose.onNodeWithTag("artifacts-new-tab-field").performImeAction()
        // A new tab is new even beside a tab already at that path.
        compose.onNodeWithTag("artifacts-tab-opened-1").assertIsDisplayed()
        compose.onAllNodesWithTag("artifacts-quick-open-sheet").assertCountEquals(0)
        compose.runOnIdle {
            assertEquals("opened-1", store.visibleTabId)
            assertEquals(2, store.state.value.tabs.count { it.target == SharedArtifactsTarget.File("/srv/tessera/PLAN.md") })
            assertEquals(ArtifactOpenPlacement.NewTab, store.placements.last().second)
        }
    }

    @Test fun openTabSuggestionKeepsTheImmutableDiffRatherThanOpeningItsFile() {
        val store = show()
        compose.onNodeWithTag("artifacts-quick-open").performClick()
        compose.onNodeWithTag("artifacts-new-tab-field").performTextReplacement("config.kt edit")
        compose.onNodeWithText("switch to tab", useUnmergedTree = true).assertExists()
        compose.onNodeWithTag("artifacts-suggestion-openTab-0").performClick()
        compose.onNodeWithTag("artifacts-tab-diff").assertIsDisplayed()
        compose.onNodeWithText("val mode = \"artifacts\"").assertIsDisplayed()
        compose.onAllNodesWithText("build-box is offline · showing the saved copy").assertCountEquals(0)
        compose.runOnIdle { assertTrue(store.content("diff") is ArtifactContent.Change) }
    }

    @Test fun keepingAnEphemeralPageChangesTheMenuOnRevisionAlone() {
        val store = show(ArtifactsHarnessScene.Forwarded)
        compose.onNodeWithTag("artifacts-tab-menu").performClick()
        compose.onNodeWithTag("artifacts-menu-keep").performClick()
        compose.onNodeWithTag("artifacts-tab-menu").performClick()
        compose.onAllNodesWithTag("artifacts-menu-keep").assertCountEquals(0)
        compose.runOnIdle { assertFalse(store.canKeepAsRule("forwarded")) }
    }

    @Test fun lockingDismissesQuickOpenAndUnlockingDoesNotRestoreIt() {
        val locked = mutableStateOf(false)
        val store = ArtifactHarnessStore.create(compose.activity, ArtifactsHarnessScene.Overview)
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture { TesseraTheme { ArtifactsBrowser(store, locked = locked.value) } }
        }
        compose.onNodeWithTag("artifacts-quick-open").performClick()
        compose.onNodeWithTag("artifacts-quick-open-sheet").assertIsDisplayed()
        compose.runOnIdle { locked.value = true }
        compose.onAllNodesWithTag("artifacts-quick-open-sheet").assertCountEquals(0)
        compose.runOnIdle { locked.value = false }
        compose.onAllNodesWithTag("artifacts-quick-open-sheet").assertCountEquals(0)
    }

    @Test fun lockingClosesTabMenusAndPausesTheFollowerButKeepsThePage() {
        val locked = mutableStateOf(false)
        val store = ArtifactHarnessStore.create(compose.activity, ArtifactsHarnessScene.Live)
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture { TesseraTheme { ArtifactsBrowser(store, locked = locked.value) } }
        }
        compose.onNodeWithTag("artifacts-tab-menu").performClick()
        compose.onNodeWithTag("artifacts-menu-pin").assertIsDisplayed()
        compose.runOnIdle { locked.value = true }
        compose.onAllNodesWithTag("artifacts-menu-pin").assertCountEquals(0)
        // The lock overlay covers the page; keeping it composed keeps its history.
        compose.onAllNodesWithTag("artifacts-content").assertCountEquals(1)
        compose.runOnIdle {
            assertNull(store.visibleTabId)
            locked.value = false
        }
        compose.onAllNodesWithTag("artifacts-menu-pin").assertCountEquals(0)
        compose.runOnIdle { assertNotNull(store.visibleTabId) }
    }

    @Test fun servedPageBackWalksWebHistoryBeforeReturningToOverview() {
        val store = show(ArtifactsHarnessScene.Served)
        compose.onNodeWithTag("artifacts-tab-served").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-tab-menu").performClick()
        compose.onNodeWithTag("artifacts-menu-browser").assertIsNotEnabled()
        compose.onNodeWithTag("artifacts-menu-pin").performClick()
        compose.waitUntil(10_000) {
            var loaded = false
            compose.runOnIdle { loaded = findWebView(compose.activity.window.decorView)?.progress == 100 }
            loaded
        }
        compose.onNodeWithText("release preview").assertIsDisplayed()
        // Follow a real same-origin page through the fake resource reader.
        // The reader has no fallback to a host or a loopback listener.
        tapFirstLink()
        compose.waitUntil(10_000) {
            compose.onAllNodes(hasTestTag("artifacts-page-back") and isEnabled()).fetchSemanticsNodes().isNotEmpty()
        }
        var beforeReload: WebView? = null
        compose.runOnIdle { beforeReload = findWebView(compose.activity.window.decorView) }
        compose.onNodeWithTag("artifacts-refresh").performClick()
        compose.onNodeWithTag("artifacts-page-back").assertIsEnabled()
        compose.runOnIdle {
            assertSame(beforeReload, findWebView(compose.activity.window.decorView))
            assertTrue("page reload must preserve its viewer and history", store.refreshes.isEmpty())
        }
        compose.runOnIdle { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.waitUntil(10_000) {
            compose.onAllNodes(hasTestTag("artifacts-page-back") and isEnabled()).fetchSemanticsNodes().isEmpty()
        }
        compose.onNodeWithTag("artifacts-tab-served").assertIsDisplayed()
        compose.runOnIdle {
            assertEquals("served", store.visibleTabId)
            compose.activity.onBackPressedDispatcher.onBackPressed()
        }
        compose.onNodeWithTag("artifacts-overview").assertIsDisplayed()
        compose.runOnIdle { assertNull(store.visibleTabId) }
    }

    @Test fun wideLayoutKeepsOverviewBesideTheSelectedTabAndRecreationRetainsIt() {
        val store = show(ArtifactsHarnessScene.Live, wide = true)
        compose.onNodeWithTag("artifacts-overview").assertExists()
        compose.onNodeWithTag("artifacts-tab-plan").assertExists()
        compose.onAllNodesWithTag("artifacts-overview-back").assertCountEquals(0)
        compose.activityRule.scenario.recreate()
        compose.onNodeWithTag("artifacts-overview").assertExists()
        compose.onNodeWithTag("artifacts-tab-plan").assertExists()
        compose.onAllNodesWithTag("artifacts-overview-back").assertCountEquals(0)
        compose.runOnIdle { assertEquals("plan", store.visibleTabId) }
    }

    @Test fun wideSystemBackWalksPageHistoryThenClearsTheDetail() {
        val store = show(ArtifactsHarnessScene.Served, wide = true)
        compose.onAllNodesWithTag("artifacts-overview-back").assertCountEquals(0)
        compose.waitUntil(10_000) {
            var loaded = false
            compose.runOnIdle {
                val webView = findWebView(compose.activity.window.decorView)
                loaded = webView?.progress == 100 && webView.title == "release preview"
            }
            loaded
        }
        tapFirstLink()
        compose.waitUntil(10_000) {
            compose.onAllNodes(hasTestTag("artifacts-page-back") and isEnabled()).fetchSemanticsNodes().isNotEmpty()
        }
        compose.runOnIdle { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.waitUntil(10_000) {
            compose.onAllNodes(hasTestTag("artifacts-page-back") and isEnabled()).fetchSemanticsNodes().isEmpty()
        }
        compose.onNodeWithTag("artifacts-tab-served").assertExists()
        compose.runOnIdle {
            assertEquals("served", store.visibleTabId)
            compose.activity.onBackPressedDispatcher.onBackPressed()
        }
        compose.onAllNodesWithTag("artifacts-tab-served").assertCountEquals(0)
        compose.onNodeWithTag("artifacts-overview").assertExists()
        compose.onNodeWithText("select a tab").assertExists()
        compose.runOnIdle { assertNull(store.visibleTabId) }
    }

    @Test fun leavingTheBrowserClearsVisibleOwnership() {
        val store = show(ArtifactsHarnessScene.Live)
        compose.runOnIdle { assertEquals("plan", store.visibleTabId) }
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture { TesseraTheme { androidx.compose.material3.Text("another page") } }
        }
        compose.onNodeWithText("another page").assertIsDisplayed()
        compose.runOnIdle { assertNull(store.visibleTabId) }
    }

    @Test fun overviewActionsMeetTheMinimumTouchHeight() {
        show()
        val minimum = with(compose.density) { 48.dp.toPx() }
        for (tag in listOf("artifacts-quick-open", "artifacts-filter-all", "artifacts-filter-docs")) {
            val node = compose.onNodeWithTag(tag).fetchSemanticsNode()
            assertTrue("$tag is smaller than 48 dp", node.boundsInRoot.height >= minimum - 0.5f)
        }
    }

    // --- Browser chrome: one +, an editable address, new tabs, shortcuts and share ---

    @Test fun phoneTabHasNoPlusAndReachesNewTabFromItsMenu() {
        show(ArtifactsHarnessScene.Live)
        compose.onAllNodesWithTag("artifacts-quick-open").assertCountEquals(0)
        compose.onAllNodesWithTag("artifacts-overview-back").assertCountEquals(1)
        compose.onAllNodesWithTag("artifacts-toolbar").assertCountEquals(0)
        compose.onNodeWithTag("artifacts-refresh").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-share").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-tab-menu").performClick()
        compose.onNodeWithTag("artifacts-menu-new-tab").performClick()
        compose.onNodeWithTag("artifacts-quick-open-sheet").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-new-tab-field").assertIsFocused()
    }

    @Test fun wideTabPutsHistoryAddressReloadAndShareInOneToolbarBesideTheOnlyPlus() {
        show(ArtifactsHarnessScene.Live, wide = true)
        compose.onAllNodesWithTag("artifacts-quick-open").assertCountEquals(1)
        compose.onAllNodesWithTag("artifacts-overview-back").assertCountEquals(0)
        for (tag in listOf("artifacts-page-back", "artifacts-page-forward", "artifacts-address", "artifacts-refresh", "artifacts-share")) {
            compose.onNode(hasTestTag(tag) and hasAnyAncestor(hasTestTag("artifacts-toolbar"))).assertExists()
            compose.onAllNodesWithTag(tag).assertCountEquals(1)
        }
        compose.onNodeWithTag("artifacts-tab-menu").performClick()
        compose.onNodeWithTag("artifacts-menu-pin").assertIsDisplayed()
        compose.onAllNodesWithTag("artifacts-menu-new-tab").assertCountEquals(0)
    }

    @OptIn(ExperimentalTestApi::class)
    @Test fun addressFieldStartsWithTheWholeAddressSelectedAndReturnNavigatesThatTab() {
        val store = show(ArtifactsHarnessScene.Live)
        val tabs = store.state.value.tabs.size
        compose.onNodeWithTag("artifacts-address").performClick()
        val field = compose.onNodeWithTag("artifacts-address-field")
        field.assertIsFocused()
        val address = "api-01:/srv/tessera/PLAN.md"
        field.assert(hasText(address))
        field.assert(SemanticsMatcher.expectValue(SemanticsProperties.TextSelectionRange, TextRange(0, address.length)))
        field.performTextReplacement("api-01:/srv/build/config.kt")
        field.performKeyInput { pressKey(Key.Enter) }
        compose.onAllNodesWithTag("artifacts-address-field").assertCountEquals(0)
        compose.onNodeWithTag("artifacts-tab-plan").assertIsDisplayed()
        compose.onNodeWithText("api-01:/srv/build/config.kt", useUnmergedTree = true).assertIsDisplayed()
        compose.runOnIdle {
            assertEquals(tabs, store.state.value.tabs.size)
            assertEquals(SharedArtifactsTarget.File("/srv/build/config.kt"), store.state.value.tabs.first { it.id == "plan" }.target)
            assertEquals("api-01:/srv/build/config.kt" to ArtifactOpenPlacement.Navigate("plan"), store.placements.single())
        }
    }

    @OptIn(ExperimentalTestApi::class)
    @Test fun escapeAndTappingAwayRestoreTheAddressWithoutNavigating() {
        val store = show(ArtifactsHarnessScene.Live)
        compose.onNodeWithTag("artifacts-address").performClick()
        compose.onNodeWithTag("artifacts-address-field").performTextReplacement("somewhere else")
        compose.onNodeWithTag("artifacts-address-field").performKeyInput { pressKey(Key.Escape) }
        compose.onAllNodesWithTag("artifacts-address-field").assertCountEquals(0)
        compose.onNodeWithText("api-01:/srv/tessera/PLAN.md", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithTag("artifacts-address").performClick()
        compose.onNodeWithTag("artifacts-address-field").performTextReplacement("somewhere else")
        compose.onNodeWithTag("artifacts-address-suggestions").performClick()
        compose.onAllNodesWithTag("artifacts-address-field").assertCountEquals(0)
        compose.runOnIdle { assertTrue(store.placements.isEmpty()) }
    }

    @Test fun anotherHostOrAChangeFromTheAddressFieldOpensANewTab() {
        val store = show(ArtifactsHarnessScene.Diff)
        compose.onNodeWithTag("artifacts-address").performClick()
        compose.onNodeWithTag("artifacts-address-field").performTextReplacement("api-01:/srv/tessera/PLAN.md")
        compose.onNodeWithTag("artifacts-address-field").performImeAction()
        compose.onNodeWithTag("artifacts-tab-opened-1").assertIsDisplayed()
        compose.runOnIdle {
            // A change is an immutable snapshot; it stays beside the file it opened.
            assertTrue(store.state.value.tabs.first { it.id == "diff" }.target is SharedArtifactsTarget.Change)
            assertEquals("opened-1", store.visibleTabId)
        }
    }

    @Test fun twoAddressesOnOnePortOpenTwoTabsBesideEachOther() {
        val store = show(ArtifactsHarnessScene.Empty, wide = true)
        compose.onNodeWithTag("artifacts-quick-open").performClick()
        compose.onNodeWithTag("artifacts-quick-host-api").performClick()
        compose.onNodeWithTag("artifacts-new-tab-field").performTextReplacement("localhost:8001")
        compose.onNodeWithTag("artifacts-new-tab-field").performImeAction()
        compose.onNodeWithTag("artifacts-tab-opened-1").assertExists()
        compose.onNodeWithTag("artifacts-quick-open").performClick()
        compose.onNodeWithTag("artifacts-new-tab-field").performTextReplacement("localhost:8001/laptop.html")
        compose.onNodeWithTag("artifacts-new-tab-field").performImeAction()
        compose.onNodeWithTag("artifacts-tab-opened-2").assertExists()
        compose.onNodeWithTag("artifacts-row-opened-1").assertExists()
        compose.onNodeWithTag("artifacts-row-opened-2").assertExists()
        compose.runOnIdle {
            assertEquals(
                listOf(SharedArtifactsTarget.Page("http", 8001, "/"), SharedArtifactsTarget.Page("http", 8001, "/laptop.html")),
                store.state.value.tabs.map { it.target },
            )
        }
    }

    @Test fun shareSendsTheCachedFileItselfThroughTheFileProvider() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val captured = mutableListOf<Intent>()
        val monitor = object : Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): Instrumentation.ActivityResult? {
                if (intent.action != Intent.ACTION_CHOOSER) return null
                synchronized(captured) { captured += Intent(intent) }
                return Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null)
            }
        }
        instrumentation.addMonitor(monitor)
        try {
            show(ArtifactsHarnessScene.Live)
            compose.onNodeWithTag("artifacts-share").performClick()
            compose.waitUntil(10_000) { synchronized(captured) { captured.isNotEmpty() } }
            val chooser = synchronized(captured) { captured.single() }
            val send = checkNotNull(IntentCompat.getParcelableExtra(chooser, Intent.EXTRA_INTENT, Intent::class.java))
            assertEquals(Intent.ACTION_SEND, send.action)
            assertTrue("markdown keeps a text type, not octet-stream: ${send.type}", send.type!!.startsWith("text/"))
            val uri = checkNotNull(IntentCompat.getParcelableExtra(send, Intent.EXTRA_STREAM, Uri::class.java))
            val context = compose.activity
            assertEquals("content", uri.scheme)
            assertEquals("${context.packageName}.files", uri.authority)
            assertEquals("PLAN.md", uri.lastPathSegment)
            assertTrue(send.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            assertEquals(uri, send.clipData?.getItemAt(0)?.uri)
            assertTrue(chooser.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            val fixture = File(context.cacheDir, "artifacts-visual-harness/PLAN.md").readBytes()
            assertTrue(fixture.contentEquals(context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }))
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)!!.use {
                assertTrue(it.moveToFirst())
                assertEquals("PLAN.md", it.getString(0))
            }
        } finally {
            instrumentation.removeMonitor(monitor)
        }
    }

    @Test fun anUndownloadableFileSaysWhyAndPagesAndChangesHaveNoShare() {
        show(ArtifactsHarnessScene.TooLarge)
        compose.onNodeWithTag("artifacts-share").performClick()
        compose.onNodeWithText("this file is too large to download, so it cannot be shared").assertIsDisplayed()
        show(ArtifactsHarnessScene.Forwarded)
        compose.onNodeWithTag("artifacts-tab-forwarded").assertIsDisplayed()
        compose.onAllNodesWithTag("artifacts-share").assertCountEquals(0)
        show(ArtifactsHarnessScene.Diff)
        compose.onNodeWithTag("artifacts-tab-diff").assertIsDisplayed()
        compose.onAllNodesWithTag("artifacts-share").assertCountEquals(0)
    }

    @Test fun browserShortcutsFollowChromeKeysWithoutATapFirst() {
        val store = show(ArtifactsHarnessScene.Live, wide = true)
        compose.onNodeWithTag("artifacts-tab-plan").assertExists()
        chord(KeyEvent.KEYCODE_TAB)
        compose.onNodeWithTag("artifacts-tab-cached").assertExists()
        chord(KeyEvent.KEYCODE_TAB, shift = true)
        compose.onNodeWithTag("artifacts-tab-plan").assertExists()
        chord(KeyEvent.KEYCODE_9)
        compose.onNodeWithTag("artifacts-tab-failed-page").assertExists()
        chord(KeyEvent.KEYCODE_1)
        compose.onNodeWithTag("artifacts-tab-plan").assertExists()
        chord(KeyEvent.KEYCODE_W)
        compose.onNodeWithTag("artifacts-tab-cached").assertExists()
        compose.runOnIdle { assertTrue(store.state.value.tabs.none { it.id == "plan" }) }
        chord(KeyEvent.KEYCODE_T, shift = true)
        compose.onNodeWithTag("artifacts-tab-reopened-1").assertExists()
        compose.runOnIdle {
            assertEquals(SharedArtifactsTarget.File("/srv/tessera/PLAN.md"), store.state.value.tabs.first { it.id == "reopened-1" }.target)
        }
        chord(KeyEvent.KEYCODE_L)
        compose.onNodeWithTag("artifacts-address-field").assertIsFocused()
        chord(KeyEvent.KEYCODE_ESCAPE, ctrl = false)
        compose.onAllNodesWithTag("artifacts-address-field").assertCountEquals(0)
        chord(KeyEvent.KEYCODE_T)
        compose.onNodeWithTag("artifacts-quick-open-sheet").assertIsDisplayed()
    }

    @Test fun ctrlLOnThePhoneOverviewIsTheOpenField() {
        show()
        chord(KeyEvent.KEYCODE_L)
        compose.onNodeWithTag("artifacts-quick-open-sheet").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-new-tab-field").assertIsFocused()
    }

    @Test fun aFocusedFieldOutsideTheBrowserKeepsItsCtrlKeys() {
        val store = ArtifactHarnessStore.create(compose.activity, ArtifactsHarnessScene.Overview)
        val typed = mutableStateOf("")
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture {
                TesseraTheme {
                    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                        // Stands in for a focused terminal beside the browser.
                        BasicTextField(typed.value, { typed.value = it }, Modifier.fillMaxWidth().testTag("outside"))
                        ArtifactsBrowser(store, Modifier.requiredWidth(390.dp).weight(1f))
                    }
                }
            }
        }
        compose.onNodeWithTag("outside").performClick()
        compose.onNodeWithTag("outside").assertIsFocused()
        chord(KeyEvent.KEYCODE_T)
        chord(KeyEvent.KEYCODE_W)
        compose.onAllNodesWithTag("artifacts-quick-open-sheet").assertCountEquals(0)
        compose.onNodeWithTag("outside").assertIsFocused()
        compose.onNodeWithTag("artifacts-row-plan").performClick()
        compose.onNodeWithTag("artifacts-tab-plan").assertIsDisplayed()
        chord(KeyEvent.KEYCODE_T)
        compose.onNodeWithTag("artifacts-quick-open-sheet").assertIsDisplayed()
    }

    /** A hardware chord through the window, as a keyboard sends it: no tap first. */
    private fun chord(code: Int, ctrl: Boolean = true, shift: Boolean = false) {
        compose.waitForIdle()
        val meta = (if (ctrl) KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON else 0) or
            (if (shift) KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON else 0)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val down = SystemClock.uptimeMillis()
        instrumentation.sendKeySync(KeyEvent(down, down, KeyEvent.ACTION_DOWN, code, 0, meta))
        instrumentation.sendKeySync(KeyEvent(down, down + 20, KeyEvent.ACTION_UP, code, 0, meta))
        compose.waitForIdle()
    }

    /**
     * Chromium skips history entries a script adds without user activation, so
     * a scripted click() never enables back. Inject a tap as a user would.
     */
    private fun tapFirstLink() {
        val measured = CountDownLatch(1)
        var center: List<Float> = emptyList()
        compose.runOnIdle {
            checkNotNull(findWebView(compose.activity.window.decorView)).evaluateJavascript(
                "(() => { const r = document.querySelector('a').getBoundingClientRect(); const d = window.devicePixelRatio;" +
                    " return [(r.left + r.width / 2) * d, (r.top + r.height / 2) * d]; })()",
            ) { value ->
                center = value.trim('[', ']').split(',').map { it.trim().toFloat() }
                measured.countDown()
            }
        }
        assertTrue("the page did not report its link", measured.await(5, TimeUnit.SECONDS))
        val origin = IntArray(2)
        compose.runOnIdle { checkNotNull(findWebView(compose.activity.window.decorView)).getLocationOnScreen(origin) }
        val x = origin[0] + center[0]
        val y = origin[1] + center[1]
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val down = SystemClock.uptimeMillis()
        for ((action, time) in listOf(MotionEvent.ACTION_DOWN to down, MotionEvent.ACTION_UP to down + 60)) {
            val event = MotionEvent.obtain(down, time, action, x, y, 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            instrumentation.sendPointerSync(event)
            event.recycle()
        }
    }

    private fun findWebView(view: View): WebView? {
        if (view is WebView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) {
            findWebView(view.getChildAt(index))?.let { return it }
        }
        return null
    }
}
