package com.bambouville.tessera.feature.artifacts

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import android.net.Uri
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.core.graphics.createBitmap
import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsCacheMetadata
import com.bambouville.tessera.core.bridge.SharedArtifactsCachePresentation
import com.bambouville.tessera.core.bridge.SharedArtifactsCacheState
import com.bambouville.tessera.core.bridge.SharedArtifactsFilter
import com.bambouville.tessera.core.bridge.SharedArtifactsHostGroup
import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.core.bridge.SharedArtifactsOverview
import com.bambouville.tessera.core.bridge.SharedArtifactsQuickOpenHost
import com.bambouville.tessera.core.bridge.SharedArtifactsQuickOpenIntent
import com.bambouville.tessera.core.bridge.SharedArtifactsState
import com.bambouville.tessera.core.bridge.SharedArtifactsSuggestion
import com.bambouville.tessera.core.bridge.SharedArtifactsSuggestionKind
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.feature.artifacts.viewers.ArtifactRemoteReader
import com.bambouville.tessera.feature.artifacts.viewers.ArtifactSftpInterceptor
import java.io.File
import java.io.FileNotFoundException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

enum class ArtifactsHarnessScene(val slug: String, internal val tabId: String? = null) {
    Overview("overview"), Empty("empty"), Live("live", "plan"), Cached("cached", "cached"),
    Stale("stale", "stale"), Offline("offline", "offline"), Diff("diff", "diff"),
    Served("served", "served"), Forwarded("forwarded", "forwarded"), Unseen("unseen", "unseen"),
    Image("image", "image"), Pdf("pdf", "pdf"), Loading("loading", "loading"),
    Missing("missing", "missing"), TooLarge("too-large", "large"), Failed("failed", "failed"),
    NoForwarding("no-forwarding", "mosh"), QuickOpen("quick-open"),
    FailedPage("failed-page", "failed-page"), MoshFiles("mosh-files", "mosh-files"),
}

/** The production UI, with only in-memory content and private local fixtures. */
@Composable
fun ArtifactsVisualHarness(scene: ArtifactsHarnessScene, modifier: Modifier = Modifier) {
    val context = LocalContext.current.applicationContext
    val store by produceState<ArtifactHarnessStore?>(null, scene) {
        value = withContext(Dispatchers.IO) { ArtifactHarnessStore.create(context, scene) }
    }
    val ready = store
    if (ready == null) Text("loading fixtures…", style = TesseraType.bodySmall)
    else ArtifactsBrowser(ready, modifier.fillMaxSize(), initialQuickOpen = scene == ArtifactsHarnessScene.QuickOpen)
}

/** No networking, JNI, repositories, or session creation is reachable here. */
internal class ArtifactHarnessStore private constructor(
    initialState: SharedArtifactsState,
    private val contents: MutableMap<String, ArtifactContent>,
    private val presentations: MutableMap<String, SharedArtifactsCachePresentation>,
) : ArtifactsUiStore {
    private val mutableState = MutableStateFlow(initialState)
    private val mutableRevision = MutableStateFlow(0L)
    override val state: StateFlow<SharedArtifactsState> = mutableState.asStateFlow()
    override val revision: StateFlow<Long> = mutableRevision.asStateFlow()
    override val route = ArtifactsBrowserRoute()
    private val liveHosts = mutableSetOf("api", "build", "mosh-host")
    var visibleTabId: String? = null
        private set
    val visibleVisits = mutableListOf<String?>()
    val refreshes = mutableListOf<String>()
    val fileConnections = mutableListOf<String>()
    private val keptRules = mutableSetOf<String>()
    private val closedTabs = ArtifactClosedTabs()
    private var openedTabs = 0
    /** Every quick-open call, with where it was told to go. */
    val placements = mutableListOf<Pair<String, ArtifactOpenPlacement>>()
    override val quickOpenHosts = listOf(
        SharedArtifactsQuickOpenHost("api", "api-01", "/srv/tessera"),
        SharedArtifactsQuickOpenHost("build", "build-box", "/srv/build"),
        SharedArtifactsQuickOpenHost("archive", "archive", "/srv/archive"),
    )

    override fun overview(query: String): SharedArtifactsOverview {
        val matching = state.value.tabs.filter { tab ->
            query.isBlank() || listOf(tab.title, tab.hostLabel, tab.target.path).any { it.contains(query.trim(), ignoreCase = true) }
        }.sortedByDescending { it.viewedAt }
        val shown = matching.filter { state.value.filter == SharedArtifactsFilter.All || it.kind.wireValue == state.value.filter.wireValue }
        return SharedArtifactsOverview(
            shown.groupBy { it.hostId }.map { (id, tabs) -> SharedArtifactsHostGroup(id, tabs.first().hostLabel, tabs.map { it.id }) },
            SharedArtifactsKind.entries.associateWith { kind -> matching.count { it.kind == kind } }, matching.size,
        )
    }

    override fun content(tabId: String) = contents[tabId] ?: ArtifactContent.Unavailable(ArtifactUnavailable.Missing)
    override fun presentation(tabId: String) = presentations[tabId]
        ?: SharedArtifactsCachePresentation(SharedArtifactsCacheState.None, null, false)
    /** Only the mosh page's host is connected in a terminal and not over Files. */
    override fun filesReconnect(tabId: String): ArtifactFilesReconnect? =
        ArtifactFilesReconnect.Available.takeIf { tabId == "mosh-files" }
    override fun connectFiles(tabId: String) { if (filesReconnect(tabId) != null) fileConnections += tabId }
    override fun isLive(hostId: String) = hostId in liveHosts
    override fun select(tabId: String) {
        if (state.value.tabs.none { it.id == tabId }) return
        mutableState.value = state.value.copy(selectedId = tabId, tabs = state.value.tabs.map {
            if (it.id == tabId) it.copy(viewedAt = System.currentTimeMillis(), unseenChange = false) else it
        })
    }
    override fun close(tabId: String) {
        state.value.tabs.firstOrNull { it.id == tabId }?.let(closedTabs::push)
        mutableState.value = state.value.copy(tabs = state.value.tabs.filterNot { it.id == tabId },
            selectedId = state.value.selectedId.takeUnless { it == tabId })
    }
    override fun closeAll(hostId: String) {
        state.value.tabs.filter { it.hostId == hostId }.forEach(closedTabs::push)
        val remaining = state.value.tabs.filterNot { it.hostId == hostId }
        mutableState.value = state.value.copy(tabs = remaining, selectedId = state.value.selectedId.takeIf { id -> remaining.any { it.id == id } })
    }
    override fun setPinned(tabId: String, pinned: Boolean) {
        mutableState.value = state.value.copy(tabs = state.value.tabs.map { if (it.id == tabId) it.copy(pinned = pinned) else it })
    }
    override fun setFilter(filter: SharedArtifactsFilter) { mutableState.value = state.value.copy(filter = filter) }
    override fun refresh(tabId: String) {
        if (!presentation(tabId).canRefresh) return
        refreshes += tabId
        (contents[tabId] as? ArtifactContent.Document)?.let { contents[tabId] = it.copy(reloadToken = it.reloadToken + 1) }
        val previous = presentation(tabId)
        presentations[tabId] = previous.copy(state = SharedArtifactsCacheState.Live)
        mutableRevision.value++
    }
    override fun noteVisible(tabId: String?) { visibleTabId = tabId; visibleVisits += tabId }
    override fun titleLearned(tabId: String, title: String) {
        mutableState.value = state.value.copy(tabs = state.value.tabs.map { if (it.id == tabId) it.copy(title = title) else it })
    }
    override fun canKeepAsRule(tabId: String) = (contents[tabId] as? ArtifactContent.ForwardedPage)?.isEphemeral == true && tabId !in keptRules
    override fun keepAsRule(tabId: String) {
        keptRules += tabId
        (contents[tabId] as? ArtifactContent.ForwardedPage)?.let { contents[tabId] = it.copy(isEphemeral = false, ruleLabel = "preview") }
        mutableRevision.value++
    }

    override fun quickOpenSuggestions(input: String, currentHostId: String?): List<SharedArtifactsSuggestion> = buildList {
        if (input.endsWith(':')) quickOpenHosts.firstOrNull { input == "${it.label}:" }?.let {
            add(SharedArtifactsSuggestion(SharedArtifactsSuggestionKind.HostPrefix, "${it.label}:~/", "home directory",
                SharedArtifactsQuickOpenIntent.Directory(it.id, it.home ?: "~/"), null))
        }
        state.value.tabs.filter { input.isBlank() || it.title.contains(input, true) || it.target.path.contains(input, true) }.take(5).forEach {
            val target = it.target
            val intent = if (target is SharedArtifactsTarget.Page) SharedArtifactsQuickOpenIntent.Page(it.hostId, target.scheme, target.port, target.path)
                else SharedArtifactsQuickOpenIntent.File(it.hostId, target.path)
            add(SharedArtifactsSuggestion(SharedArtifactsSuggestionKind.OpenTab, it.title, it.hostLabel, intent, it.id))
        }
        if (input.startsWith(':') && currentHostId != null) add(SharedArtifactsSuggestion(
            SharedArtifactsSuggestionKind.ListeningPort, "localhost:5173", "preview server",
            SharedArtifactsQuickOpenIntent.Page(currentHostId, "http", 5173, "/"), null,
        ))
        if (input.isBlank()) add(SharedArtifactsSuggestion(SharedArtifactsSuggestionKind.Recent, "release notes", "archive",
            SharedArtifactsQuickOpenIntent.File("archive", "/srv/archive/release.md"), null))
    }.take(8)

    /** Pages on any port, and files the fixture already holds, open like the live store: new tabs are always new. */
    override suspend fun quickOpen(input: String, currentHostId: String?, placement: ArtifactOpenPlacement): ArtifactQuickOpenOutcome {
        placements += input to placement
        val text = input.trim()
        val host = quickOpenHosts.firstOrNull { text.startsWith("${it.label}:") }
        val hostId = host?.id ?: currentHostId ?: return ArtifactQuickOpenOutcome.Failed("choose a host first")
        val rest = if (host == null) text else text.removePrefix("${host.label}:")
        val page = Regex("^(?:(https?)://)?(?:localhost)?:(\\d{1,5})(/.*)?$").matchEntire(rest)
        val label = quickOpenHosts.firstOrNull { it.id == hostId }?.label ?: hostId
        val (target, opened) = when {
            page != null -> {
                val target = SharedArtifactsTarget.Page(page.groupValues[1].ifEmpty { "http" }, page.groupValues[2].toInt(), page.groupValues[3].ifEmpty { "/" })
                target to ArtifactContent.ForwardedPage(harnessPageUrl(target.path), "preview", true)
            }
            rest.endsWith('/') -> return ArtifactQuickOpenOutcome.Directory(hostId, rest)
            else -> {
                val source = state.value.tabs.firstOrNull { it.target is SharedArtifactsTarget.File && it.target.path == rest }
                    ?.let { contents[it.id] as? ArtifactContent.Document }
                    ?: return ArtifactQuickOpenOutcome.Failed("this path is not in the visual fixture")
                SharedArtifactsTarget.File(rest) to source
            }
        }
        val kind = when {
            target is SharedArtifactsTarget.Page || target.path.endsWith(".html") -> SharedArtifactsKind.Pages
            target.path.endsWith(".md") -> SharedArtifactsKind.Docs
            else -> SharedArtifactsKind.Files
        }
        val title = if (target is SharedArtifactsTarget.Page) "localhost:${target.port}" else target.path.substringAfterLast('/')
        val now = System.currentTimeMillis()
        val navigated = (placement as? ArtifactOpenPlacement.Navigate)?.tabId?.let { id -> state.value.tabs.firstOrNull { it.id == id } }
            ?.takeIf { artifactNavigatesInPlace(it, hostId, toChange = false) }
        val id = navigated?.id ?: "opened-${++openedTabs}"
        contents[id] = opened
        presentations[id] = SharedArtifactsCachePresentation(SharedArtifactsCacheState.Live, now, true)
        val tab = navigated?.copy(target = target, kind = kind, title = title, viewedAt = now, origin = "quickOpen")
            ?: SharedArtifactTab(id, hostId, label, target, kind, title, "quickOpen", null, now, now, false, null, false, null)
        mutableState.value = state.value.copy(
            tabs = if (navigated == null) state.value.tabs + tab else state.value.tabs.map { if (it.id == id) tab else it },
            selectedId = id,
        )
        mutableRevision.value++
        return ArtifactQuickOpenOutcome.Opened(id)
    }

    override fun reopenClosed() {
        val closed = closedTabs.pop() ?: return
        val id = "reopened-${++openedTabs}"
        val now = System.currentTimeMillis()
        contents[id] = (closed.target as? SharedArtifactsTarget.Page)?.let { ArtifactContent.ForwardedPage(harnessPageUrl(it.path), "preview", true) }
            ?: ArtifactContent.Unavailable(ArtifactUnavailable.Offline)
        mutableState.value = state.value.copy(
            tabs = state.value.tabs + SharedArtifactTab(id, closed.hostId, closed.hostId, closed.target,
                if (closed.target is SharedArtifactsTarget.Page) SharedArtifactsKind.Pages else SharedArtifactsKind.Docs,
                closed.title, closed.origin, closed.sessionHint, now, now, closed.pinned, null, false, null),
            selectedId = id,
        )
        mutableRevision.value++
    }

    override fun share(tabId: String): ArtifactShare? {
        val tab = state.value.tabs.firstOrNull { it.id == tabId } ?: return null
        return artifactShare(tab, content(tabId), null)
    }

    internal fun replacePresentation(tabId: String, presentation: SharedArtifactsCachePresentation) {
        presentations[tabId] = presentation
        mutableRevision.value++
    }

    companion object {
        fun create(context: Context, scene: ArtifactsHarnessScene = ArtifactsHarnessScene.Overview): ArtifactHarnessStore {
            val directory = File(context.cacheDir, "artifacts-visual-harness").apply { mkdirs() }
            val markdown = File(directory, "PLAN.md").apply { writeText("# Release plan\n\nA host-owned artifact survives its session.\n\n- [x] browser\n- [ ] review\n") }
            val text = File(directory, "config.kt").apply { writeText("val artifactTitle = \"following the live session\"\n") }
            val image = File(directory, "topology.png")
            val bitmap = createBitmap(320, 180, Bitmap.Config.ARGB_8888)
            Canvas(bitmap).apply {
                drawColor(Color.LTGRAY)
                val paint = Paint().apply { color = Color.DKGRAY; strokeWidth = 3f; textSize = 20f }
                drawLine(60f, 90f, 260f, 90f, paint)
                drawCircle(60f, 90f, 22f, paint); drawCircle(260f, 90f, 22f, paint)
                drawText("session → artifacts", 60f, 150f, paint)
            }
            image.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
            val pdf = File(directory, "release.pdf")
            val document = PdfDocument()
            try {
                val page = document.startPage(PdfDocument.PageInfo.Builder(320, 440, 1).create())
                page.canvas.drawText("Release notes", 24f, 48f, Paint().apply { textSize = 20f })
                document.finishPage(page)
                pdf.outputStream().use { document.writeTo(it) }
            } finally {
                document.close()
            }
            val now = System.currentTimeMillis()
            val contents = mutableMapOf<String, ArtifactContent>()
            val presentations = mutableMapOf<String, SharedArtifactsCachePresentation>()
            val tabs = mutableListOf<SharedArtifactTab>()
            fun add(
                id: String, host: String, label: String, kind: SharedArtifactsKind, title: String,
                target: SharedArtifactsTarget, content: ArtifactContent,
                cacheState: SharedArtifactsCacheState = SharedArtifactsCacheState.Live,
                unseen: Boolean = false,
            ) {
                val cachedAt = now - 9 * 60_000
                tabs += SharedArtifactTab(
                    id, host, label, target, kind, title, if (kind == SharedArtifactsKind.Changes) "agentEdit" else "files",
                    "dev", now, now - tabs.size * 1000L, id == "plan",
                    if (content is ArtifactContent.Document) SharedArtifactsCacheMetadata(cachedAt, null, content.file.length(), cacheState == SharedArtifactsCacheState.Stale) else null,
                    unseen, if (unseen) now else null,
                )
                contents[id] = content
                presentations[id] = SharedArtifactsCachePresentation(cacheState, cachedAt,
                    host != "archive" && cacheState != SharedArtifactsCacheState.Offline && kind != SharedArtifactsKind.Changes)
            }
            val doc = ArtifactContent.Document(markdown, "PLAN.md", 0, emptyMap())
            add("plan", "api", "api-01", SharedArtifactsKind.Docs, "release plan", SharedArtifactsTarget.File("/srv/tessera/PLAN.md"), doc)
            add("cached", "archive", "archive", SharedArtifactsKind.Docs, "saved release notes", SharedArtifactsTarget.File("/srv/archive/release.md"), doc.copy(displayName = "release.md"), SharedArtifactsCacheState.Cached)
            add("stale", "build", "build-box", SharedArtifactsKind.Files, "config.kt", SharedArtifactsTarget.File("/srv/build/config.kt"), ArtifactContent.Document(text, "config.kt", 0, emptyMap()), SharedArtifactsCacheState.Stale)
            add("offline", "archive", "archive", SharedArtifactsKind.Docs, "uncached draft", SharedArtifactsTarget.File("/srv/archive/draft.md"), ArtifactContent.Unavailable(ArtifactUnavailable.Offline), SharedArtifactsCacheState.Offline)
            val diff = "diff --git a/config.kt b/config.kt\n--- a/config.kt\n+++ b/config.kt\n@@ -1 +1 @@\n-val mode = \"old\"\n+val mode = \"artifacts\"\n"
            add("diff", "build", "build-box", SharedArtifactsKind.Changes, "config.kt edit", SharedArtifactsTarget.Change("/srv/build/config.kt", diff, "rename mode"), ArtifactContent.Change("/srv/build/config.kt", diff), SharedArtifactsCacheState.Cached)
            val reader = ArtifactRemoteReader { _, path, maxBytes ->
                val body = when (path) {
                    "/srv/site/index.html" -> HARNESS_PAGE
                    "/srv/site/detail.html" -> HARNESS_DETAIL
                    else -> throw FileNotFoundException(path)
                }.toByteArray()
                check(body.size <= maxBytes)
                body
            }
            val interceptor = ArtifactSftpInterceptor("served", "/srv/site/index.html", reader)
            add("served", "build", "build-box", SharedArtifactsKind.Pages, "site preview", SharedArtifactsTarget.File("/srv/site/index.html"), ArtifactContent.ServedPage(interceptor.pageUrl, interceptor))
            // A data URL exercises forwarded-page chrome without a listener.
            add("forwarded", "api", "api-01", SharedArtifactsKind.Pages, "dev server", SharedArtifactsTarget.Page("http", 5173, "/"),
                ArtifactContent.ForwardedPage("data:text/html;charset=utf-8,${Uri.encode(HARNESS_PAGE.replace("detail.html", "#preview"))}", "preview", true))
            add("unseen", "build", "build-box", SharedArtifactsKind.Docs, "agent-updated plan", SharedArtifactsTarget.File("/srv/build/PLAN.md"), doc, unseen = true)
            add("image", "build", "build-box", SharedArtifactsKind.Files, "topology.png", SharedArtifactsTarget.File("/srv/build/topology.png"), ArtifactContent.Document(image, image.name, 0, emptyMap()))
            add("pdf", "build", "build-box", SharedArtifactsKind.Files, "release.pdf", SharedArtifactsTarget.File("/srv/build/release.pdf"), ArtifactContent.Document(pdf, pdf.name, 0, emptyMap()))
            add("loading", "api", "api-01", SharedArtifactsKind.Docs, "loading notes", SharedArtifactsTarget.File("/srv/tessera/loading.md"), ArtifactContent.Loading)
            add("missing", "api", "api-01", SharedArtifactsKind.Files, "removed.log", SharedArtifactsTarget.File("/srv/tessera/removed.log"), ArtifactContent.Unavailable(ArtifactUnavailable.Missing))
            add("large", "api", "api-01", SharedArtifactsKind.Files, "archive.tar", SharedArtifactsTarget.File("/srv/tessera/archive.tar"), ArtifactContent.Unavailable(ArtifactUnavailable.TooLarge(90L * 1024 * 1024)))
            add("failed", "api", "api-01", SharedArtifactsKind.Docs, "restricted.md", SharedArtifactsTarget.File("/srv/tessera/restricted.md"), ArtifactContent.Unavailable(ArtifactUnavailable.Failed("permission denied reading this file")))
            add("mosh", "mosh-host", "mosh-host", SharedArtifactsKind.Pages, "mosh preview", SharedArtifactsTarget.Page("http", 8080, "/"), ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding), SharedArtifactsCacheState.Offline)
            add("mosh-files", "mosh-host", "mosh-host", SharedArtifactsKind.Pages, "mosh dashboard", SharedArtifactsTarget.Page("http", 8081, "/"), ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding), SharedArtifactsCacheState.Offline)
            add("failed-page", "api", "api-01", SharedArtifactsKind.Pages, "api docs", SharedArtifactsTarget.Page("http", 5174, "/"), ArtifactContent.Unavailable(ArtifactUnavailable.Failed("the forward to port 5174 was refused")), SharedArtifactsCacheState.Live)
            return ArtifactHarnessStore(SharedArtifactsState(tabs = if (scene == ArtifactsHarnessScene.Empty) emptyList() else tabs, selectedId = scene.tabId), contents, presentations)
        }
    }
}

/** A data URL stands in for a forwarded listener: no network is reachable from the harness. */
private fun harnessPageUrl(path: String): String =
    "data:text/html;charset=utf-8,${Uri.encode("<!doctype html><title>$path</title><h1>${path.substringAfterLast('/').ifBlank { "home" }}</h1><p>$path</p>")}"

private val HARNESS_PAGE = """
    <!doctype html><html><head><title>release preview</title><meta name="viewport" content="width=device-width,initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <style>body{font:16px system-ui;padding:24px;color:#222;background:#fafafa}a{color:inherit}</style></head>
    <body><h1>release preview</h1><p>served entirely by the fake reader</p><a href="detail.html">next page</a></body></html>
""".trimIndent()

private val HARNESS_DETAIL = """
    <!doctype html><html><head><title>preview details</title><meta name="viewport" content="width=device-width,initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'"></head>
    <body><h1>preview details</h1><p>back returns to the preview before the overview</p></body></html>
""".trimIndent()
