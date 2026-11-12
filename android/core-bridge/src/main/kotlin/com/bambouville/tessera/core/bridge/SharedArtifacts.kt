package com.bambouville.tessera.core.bridge

import java.nio.ByteBuffer
import org.json.JSONArray
import org.json.JSONObject

enum class SharedArtifactsKind(val wireValue: String) { Docs("docs"), Pages("pages"), Changes("changes"), Files("files") }
enum class SharedArtifactsViewer(val wireValue: String) { Markdown("markdown"), Html("html"), Web("web"), Image("image"), Pdf("pdf"), Text("text"), Diff("diff"), Other("other") }
enum class SharedArtifactsFilter(val wireValue: String) { All("all"), Docs("docs"), Pages("pages"), Changes("changes"), Files("files") }
enum class SharedArtifactsCacheState(val wireValue: String) { Live("live"), Cached("cached"), Stale("stale"), Offline("offline"), None("none") }

sealed interface SharedArtifactsTarget {
    val path: String
    data class File(override val path: String) : SharedArtifactsTarget
    data class Page(val scheme: String, val port: Int, override val path: String) : SharedArtifactsTarget {
        init { require(port in 0..65_535) }
    }
    data class Change(override val path: String, val diff: String, val summary: String) : SharedArtifactsTarget
}

data class SharedArtifactsCacheMetadata(val fetchedAt: Long, val remoteMTime: Long?, val size: Long, val isStale: Boolean = false)
data class SharedArtifactTab(
    val id: String, val hostId: String, val hostLabel: String, val target: SharedArtifactsTarget,
    val kind: SharedArtifactsKind, val title: String, val origin: String, val sessionHint: String?,
    val openedAt: Long, val viewedAt: Long, val pinned: Boolean, val cache: SharedArtifactsCacheMetadata?,
    val unseenChange: Boolean, val agentEditedAt: Long?,
)
data class SharedArtifactsState(
    val version: Int = 1, val tabs: List<SharedArtifactTab> = emptyList(), val selectedId: String? = null,
    val filter: SharedArtifactsFilter = SharedArtifactsFilter.All, val tabCap: Int = 64,
)
data class SharedArtifactsPersistenceFiles(val stateJSON: String, val blobs: Map<String, String>)
/** [newTab] is a browser's explicit new tab; automatic opens leave it false and focus the tab already at their target. */
data class SharedArtifactsOpenRequest(
    val id: String, val hostId: String, val hostLabel: String, val target: SharedArtifactsTarget,
    val title: String, val origin: String, val sessionHint: String? = null, val newTab: Boolean = false,
)
sealed interface SharedArtifactsAction {
    val nowMillis: Long
    data class Open(val request: SharedArtifactsOpenRequest, override val nowMillis: Long) : SharedArtifactsAction
    /** The address bar's Return: the tab shows [target] on its own host. Changes neither navigate nor are destinations. */
    data class Navigate(val tabId: String, val target: SharedArtifactsTarget, val title: String, override val nowMillis: Long) : SharedArtifactsAction
    data class Select(val tabId: String, override val nowMillis: Long) : SharedArtifactsAction
    data class Close(val tabId: String, override val nowMillis: Long) : SharedArtifactsAction
    data class CloseAll(val hostId: String, override val nowMillis: Long) : SharedArtifactsAction
    data class Pin(val tabId: String, val pinned: Boolean, override val nowMillis: Long) : SharedArtifactsAction
    data class SetFilter(val filter: SharedArtifactsFilter, override val nowMillis: Long) : SharedArtifactsAction
    data class TitleLearned(val tabId: String, val title: String, override val nowMillis: Long) : SharedArtifactsAction
    data class Fetched(val tabId: String, val cache: SharedArtifactsCacheMetadata, override val nowMillis: Long) : SharedArtifactsAction
    data class RemoteStatObserved(val tabId: String, val remoteMTime: Long?, val size: Long?, val visible: Boolean, override val nowMillis: Long) : SharedArtifactsAction
    data class AgentEditObserved(val hostId: String, val path: String, override val nowMillis: Long) : SharedArtifactsAction
    data class HostRemoved(val hostId: String, override val nowMillis: Long) : SharedArtifactsAction
    data class HostRelabelled(val hostId: String, val label: String, override val nowMillis: Long) : SharedArtifactsAction
}
data class SharedArtifactsReduction(val state: SharedArtifactsState, val focusedTabId: String?, val evictedTabIds: List<String>, val navigatedPath: String?)
data class SharedArtifactsHostGroup(val hostId: String, val hostLabel: String, val tabIds: List<String>)
data class SharedArtifactsOverview(val groups: List<SharedArtifactsHostGroup>, val countsByKind: Map<SharedArtifactsKind, Int>, val totalCount: Int)
data class SharedArtifactsCachePresentation(val state: SharedArtifactsCacheState, val fetchedAt: Long?, val canRefresh: Boolean)
data class SharedArtifactsQuickOpenHost(val id: String, val label: String, val home: String? = null)
data class SharedArtifactsListeningPort(val port: Int, val bindAddress: String, val process: String?) {
    init { require(port in 0..65_535) }
}
/** A saved rule whose local listener is running now in a live session of [hostId]. */
data class SharedArtifactsActiveForward(val hostId: String, val rule: SharedForwardRule)
data class SharedArtifactsQuickOpenContext(
    val hosts: List<SharedArtifactsQuickOpenHost>, val currentHostId: String?, val cwd: String?, val listeningPorts: List<SharedArtifactsListeningPort>,
    val activeForwards: List<SharedArtifactsActiveForward> = emptyList(),
)
sealed interface SharedArtifactsQuickOpenIntent {
    data class File(val hostId: String, val path: String) : SharedArtifactsQuickOpenIntent
    data class Directory(val hostId: String, val path: String) : SharedArtifactsQuickOpenIntent
    data class Page(val hostId: String, val scheme: String, val port: Int, val path: String) : SharedArtifactsQuickOpenIntent {
        init { require(port in 0..65_535) }
    }
    data class Search(val text: String) : SharedArtifactsQuickOpenIntent
    data class Invalid(val reason: String) : SharedArtifactsQuickOpenIntent
}
enum class SharedArtifactsSuggestionKind(val wireValue: String) { HostPrefix("hostPrefix"), ActiveForward("activeForward"), OpenTab("openTab"), ListeningPort("listeningPort"), Recent("recent") }
data class SharedArtifactsSuggestion(val kind: SharedArtifactsSuggestionKind, val title: String, val subtitle: String, val intent: SharedArtifactsQuickOpenIntent, val tabId: String?)
data class SharedArtifactsRecent(val title: String, val subtitle: String, val intent: SharedArtifactsQuickOpenIntent, val viewedAt: Long)
sealed interface SharedArtifactsLinkClass {
    data class RemoteLoopback(val scheme: String, val port: Int, val pathAndQuery: String) : SharedArtifactsLinkClass
    data object Refused : SharedArtifactsLinkClass
    data object External : SharedArtifactsLinkClass
    data object Unsupported : SharedArtifactsLinkClass
}
/** Where a link in a document shown in Artifacts goes. A file or page is on the document's own host. */
sealed interface SharedArtifactsDocumentLink {
    data class File(val path: String) : SharedArtifactsDocumentLink
    data class Page(val scheme: String, val port: Int, val pathAndQuery: String) : SharedArtifactsDocumentLink
    data object External : SharedArtifactsDocumentLink
    data object Refused : SharedArtifactsDocumentLink
    data object Ignored : SharedArtifactsDocumentLink
}
sealed interface SharedArtifactsForwardPlan {
    data class Reuse(val ruleId: String, val target: SharedForwardedWebTarget) : SharedArtifactsForwardPlan
    data class Ephemeral(val rule: SharedForwardRule) : SharedArtifactsForwardPlan
}
data class SharedArtifactsCacheEntry(val key: String, val size: Long, val viewedAt: Long, val pinned: Boolean = false)

/** Policy stays in TesseraArtifactsCore; this facade only translates the ABI's JSON. */
object SharedArtifacts {
    const val MAX_PAYLOAD_BYTES: Int = 128 * 1024 * 1024

    private fun call(request: JSONObject, entry: (ByteBuffer, Int) -> String): String = call(request.toString(), entry)
    private fun call(request: String, entry: (ByteBuffer, Int) -> String): String {
        val bytes = request.encodeToByteArray()
        require(bytes.size in 1..MAX_PAYLOAD_BYTES) { "artifacts input exceeds 128 MiB" }
        NativeLibraries.ensureLoaded()
        return entry(bytes.toDirectBuffer(), bytes.size)
    }

    fun reduce(state: SharedArtifactsState, action: SharedArtifactsAction): SharedArtifactsReduction = ArtifactsJson.reduction(JSONObject(call(
        JSONObject().put("state", ArtifactsJson.encode(state)).put("action", ArtifactsJson.encode(action)), NativeCoreBindings::artifactsReduce,
    )))

    fun overview(state: SharedArtifactsState, filter: SharedArtifactsFilter, query: String): SharedArtifactsOverview = ArtifactsJson.overview(JSONObject(call(
        JSONObject().put("state", ArtifactsJson.encode(state)).put("filter", filter.wireValue).put("query", query), NativeCoreBindings::artifactsOverview,
    )))

    fun quickOpenParse(input: String, context: SharedArtifactsQuickOpenContext): SharedArtifactsQuickOpenIntent = ArtifactsJson.intent(JSONObject(call(
        JSONObject().put("input", input).put("context", ArtifactsJson.encode(context)), NativeCoreBindings::artifactsQuickOpenParse,
    )))

    fun quickOpenSuggestions(input: String, state: SharedArtifactsState, context: SharedArtifactsQuickOpenContext, recents: List<SharedArtifactsRecent> = emptyList(), limit: Int = 8): List<SharedArtifactsSuggestion> =
        ArtifactsJson.list(JSONArray(call(JSONObject().put("input", input).put("state", ArtifactsJson.encode(state))
            .put("context", ArtifactsJson.encode(context)).put("recents", ArtifactsJson.array(recents.map(ArtifactsJson::encode)))
            .put("limit", limit), NativeCoreBindings::artifactsQuickOpenSuggestions)), ArtifactsJson::suggestion)

    fun classifyLink(url: String): SharedArtifactsLinkClass = ArtifactsJson.link(JSONObject(call(
        JSONObject().put("urlString", url), NativeCoreBindings::artifactsClassifyLink,
    )))

    /** Resolves [link] against [documentPath], as a browser resolves a link in a file; [home] expands "~". */
    fun documentLink(link: String, documentPath: String, home: String? = null): SharedArtifactsDocumentLink = ArtifactsJson.documentLink(JSONObject(call(
        JSONObject().put("link", link).put("documentPath", documentPath).apply { if (home != null) put("home", home) }, NativeCoreBindings::artifactsDocumentLink,
    )))

    fun listeningPortsCommand(): String {
        NativeLibraries.ensureLoaded()
        return JSONObject(NativeCoreBindings.artifactsListeningPortsCommand()).getString("command")
    }

    fun listeningPortsParse(output: String, sshPort: Int? = null): List<SharedArtifactsListeningPort> {
        require(sshPort == null || sshPort in 0..65_535)
        return ArtifactsJson.list(JSONArray(call(JSONObject().put("output", output).put("sshPort", sshPort),
            NativeCoreBindings::artifactsListeningPortsParse)), ArtifactsJson::listeningPort)
    }

    fun forwardPlan(remotePort: Int, hostRules: List<SharedForwardRule>): SharedArtifactsForwardPlan {
        require(remotePort in 0..65_535)
        return ArtifactsJson.forwardPlan(JSONObject(call(JSONObject().put("remotePort", remotePort)
            .put("hostRules", ArtifactsJson.array(hostRules.map(ArtifactsJson::encode))), NativeCoreBindings::artifactsForwardPlan)))
    }

    fun keepAsRule(ephemeral: SharedForwardRule, label: String, ruleId: String): SharedForwardRule = ArtifactsJson.rule(JSONObject(call(
        JSONObject().put("ephemeral", ArtifactsJson.encode(ephemeral)).put("label", label).put("ruleID", ruleId), NativeCoreBindings::artifactsKeepAsRule,
    )))

    fun cacheKey(tab: SharedArtifactTab): String = JSONObject(call(JSONObject().put("tab", ArtifactsJson.encode(tab)), NativeCoreBindings::artifactsCacheKey)).getString("key")

    fun cacheEvictions(entries: List<SharedArtifactsCacheEntry>, budgetBytes: Long, protectedKeys: Set<String>): List<String> = ArtifactsJson.strings(JSONObject(call(
        JSONObject().put("entries", ArtifactsJson.array(entries.map(ArtifactsJson::encode))).put("budgetBytes", budgetBytes)
            .put("protectedKeys", ArtifactsJson.array(protectedKeys.sorted())), NativeCoreBindings::artifactsCacheEvictions,
    )).getJSONArray("keys"))

    fun cachePresentation(tab: SharedArtifactTab, liveConnection: Boolean, nowMillis: Long): SharedArtifactsCachePresentation = ArtifactsJson.presentation(JSONObject(call(
        JSONObject().put("tab", ArtifactsJson.encode(tab)).put("liveConnection", liveConnection).put("nowMillis", nowMillis), NativeCoreBindings::artifactsCachePresentation,
    )))

    /** Lenient decode is the shared persistence codec, including its malformed-tab recovery. */
    fun decodeState(json: String): SharedArtifactsState = ArtifactsJson.state(JSONObject(call(json, NativeCoreBindings::artifactsDecodeState)))

    /** Apply the shared persistence bounds before writing canonical JSON. */
    fun encodeState(state: SharedArtifactsState): String = call(ArtifactsJson.encode(state), NativeArtifactsPersistenceBindings::encodeState)

    fun splitState(state: SharedArtifactsState): SharedArtifactsPersistenceFiles = ArtifactsJson.persistenceFiles(JSONObject(call(
        ArtifactsJson.encode(state), NativeArtifactsPersistenceBindings::splitState,
    )))

    fun stateBlobDigests(json: String): List<String> = ArtifactsJson.strings(JSONObject(call(
        json, NativeArtifactsPersistenceBindings::blobDigests,
    )).getJSONArray("digests"))

    fun joinState(json: String, blobs: Map<String, String>): SharedArtifactsState = ArtifactsJson.state(JSONObject(call(
        ArtifactsJson.encode(SharedArtifactsPersistenceFiles(json, blobs)), NativeArtifactsPersistenceBindings::joinState,
    )))

    fun kind(path: String, mimeHint: String? = null): Pair<SharedArtifactsKind, SharedArtifactsViewer> = ArtifactsJson.kind(JSONObject(call(
        JSONObject().put("path", path).put("mimeHint", mimeHint), NativeCoreBindings::artifactsKind,
    )))
}

internal object NativeArtifactsPersistenceBindings {
    external fun encodeState(request: ByteBuffer, requestCount: Int): String
    external fun splitState(request: ByteBuffer, requestCount: Int): String
    external fun blobDigests(request: ByteBuffer, requestCount: Int): String
    external fun joinState(request: ByteBuffer, requestCount: Int): String
}

/** Structural codec only. Lenient recovery and all model decisions belong to Swift. */
internal object ArtifactsJson {
    fun array(values: Iterable<Any>): JSONArray = JSONArray().also { a -> values.forEach(a::put) }
    fun <T> list(array: JSONArray, decode: (JSONObject) -> T): List<T> = List(array.length()) { decode(array.getJSONObject(it)) }
    fun strings(array: JSONArray): List<String> = List(array.length(), array::getString)
    fun encode(v: SharedArtifactsPersistenceFiles): JSONObject = JSONObject().put("stateJSON", v.stateJSON)
        .put("blobs", JSONObject().also { blobs -> v.blobs.forEach { (digest, diff) -> blobs.put(digest, diff) } })
    fun persistenceFiles(v: JSONObject): SharedArtifactsPersistenceFiles = v.getJSONObject("blobs").let { blobs ->
        SharedArtifactsPersistenceFiles(v.getString("stateJSON"), blobs.keys().asSequence().associateWith { blobs.getString(it) })
    }
    private fun JSONObject.stringOrNull(key: String): String? = if (isNull(key)) null else getString(key)
    private fun JSONObject.longOrNull(key: String): Long? = if (isNull(key)) null else getLong(key)
    private inline fun <reified T : Enum<T>> wire(value: String, spelling: (T) -> String): T = enumValues<T>().first { spelling(it) == value }

    fun canonical(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().sorted().joinToString(",", "{", "}") { quoted(it) + ":" + canonical(value.get(it)) }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
        is String -> quoted(value)
        is Number, is Boolean -> value.toString()
        else -> error("unexpected JSON value")
    }

    private fun quoted(value: String): String = buildString {
        append('"')
        for (character in value) when (character) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\b' -> append("\\b")
            '\u000C' -> append("\\f")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> if (character.code < 0x20) append("\\u" + character.code.toString(16).padStart(4, '0')) else append(character)
        }
        append('"')
    }

    fun encode(value: SharedArtifactsTarget): JSONObject = JSONObject().put("path", value.path).apply {
        when (value) {
            is SharedArtifactsTarget.File -> put("type", "file")
            is SharedArtifactsTarget.Page -> { put("type", "page"); put("scheme", value.scheme); put("port", value.port) }
            is SharedArtifactsTarget.Change -> { put("type", "change"); put("diff", value.diff); put("summary", value.summary) }
        }
    }
    fun target(v: JSONObject): SharedArtifactsTarget = when (v.getString("type")) {
        "file" -> SharedArtifactsTarget.File(v.getString("path"))
        "page" -> SharedArtifactsTarget.Page(v.getString("scheme"), v.getInt("port"), v.getString("path"))
        "change" -> SharedArtifactsTarget.Change(v.getString("path"), v.getString("diff"), v.getString("summary"))
        else -> error("unknown artifacts target")
    }
    fun encode(v: SharedArtifactsCacheMetadata): JSONObject = JSONObject().put("fetchedAt", v.fetchedAt)
        .put("remoteMTime", v.remoteMTime).put("size", v.size).put("isStale", v.isStale)
    fun cache(v: JSONObject) = SharedArtifactsCacheMetadata(v.getLong("fetchedAt"), v.longOrNull("remoteMTime"), v.getLong("size"), v.optBoolean("isStale", false))
    fun encode(v: SharedArtifactTab): JSONObject = JSONObject().put("id", v.id).put("hostID", v.hostId).put("hostLabel", v.hostLabel)
        .put("target", encode(v.target)).put("kind", v.kind.wireValue).put("title", v.title).put("origin", v.origin)
        .put("sessionHint", v.sessionHint).put("openedAt", v.openedAt).put("viewedAt", v.viewedAt).put("pinned", v.pinned)
        .put("cache", v.cache?.let(::encode)).put("unseenChange", v.unseenChange).put("agentEditedAt", v.agentEditedAt)
    fun tab(v: JSONObject) = SharedArtifactTab(v.getString("id"), v.getString("hostID"), v.getString("hostLabel"), target(v.getJSONObject("target")),
        wire<SharedArtifactsKind>(v.getString("kind")) { it.wireValue }, v.getString("title"), v.getString("origin"), v.stringOrNull("sessionHint"),
        v.getLong("openedAt"), v.getLong("viewedAt"), v.getBoolean("pinned"), v.optJSONObject("cache")?.let(::cache), v.getBoolean("unseenChange"), v.longOrNull("agentEditedAt"))
    fun encode(v: SharedArtifactsState): JSONObject = JSONObject().put("version", v.version).put("tabs", array(v.tabs.map(::encode)))
        .put("selectedID", v.selectedId).put("filter", v.filter.wireValue).put("tabCap", v.tabCap)
    fun state(v: JSONObject) = SharedArtifactsState(v.optInt("version", 1), list(v.getJSONArray("tabs"), ::tab), v.stringOrNull("selectedID"),
        wire<SharedArtifactsFilter>(v.optString("filter", "all")) { it.wireValue }, v.optInt("tabCap", 64))
    fun encode(v: SharedArtifactsOpenRequest): JSONObject = JSONObject().put("id", v.id).put("hostID", v.hostId).put("hostLabel", v.hostLabel)
        .put("target", encode(v.target)).put("title", v.title).put("origin", v.origin).put("sessionHint", v.sessionHint)
        .apply { if (v.newTab) put("newTab", true) }
    fun open(v: JSONObject) = SharedArtifactsOpenRequest(v.getString("id"), v.getString("hostID"), v.getString("hostLabel"), target(v.getJSONObject("target")),
        v.getString("title"), v.getString("origin"), v.stringOrNull("sessionHint"), v.optBoolean("newTab", false))

    fun encode(v: SharedArtifactsAction): JSONObject = JSONObject().put("nowMillis", v.nowMillis).apply {
        when (v) {
            is SharedArtifactsAction.Open -> { put("type", "open"); put("open", encode(v.request)) }
            is SharedArtifactsAction.Navigate -> { put("type", "navigate"); put("tabID", v.tabId); put("target", encode(v.target)); put("title", v.title) }
            is SharedArtifactsAction.Select -> { put("type", "select"); put("tabID", v.tabId) }
            is SharedArtifactsAction.Close -> { put("type", "close"); put("tabID", v.tabId) }
            is SharedArtifactsAction.CloseAll -> { put("type", "closeAll"); put("hostID", v.hostId) }
            is SharedArtifactsAction.Pin -> { put("type", "pin"); put("tabID", v.tabId); put("pinned", v.pinned) }
            is SharedArtifactsAction.SetFilter -> { put("type", "setFilter"); put("filter", v.filter.wireValue) }
            is SharedArtifactsAction.TitleLearned -> { put("type", "titleLearned"); put("tabID", v.tabId); put("title", v.title) }
            is SharedArtifactsAction.Fetched -> { put("type", "fetched"); put("tabID", v.tabId); put("cache", encode(v.cache)) }
            is SharedArtifactsAction.RemoteStatObserved -> { put("type", "remoteStatObserved"); put("tabID", v.tabId); put("remoteMTime", v.remoteMTime); put("size", v.size); put("visible", v.visible) }
            is SharedArtifactsAction.AgentEditObserved -> { put("type", "agentEditObserved"); put("hostID", v.hostId); put("path", v.path) }
            is SharedArtifactsAction.HostRemoved -> { put("type", "hostRemoved"); put("hostID", v.hostId) }
            is SharedArtifactsAction.HostRelabelled -> { put("type", "hostRelabelled"); put("hostID", v.hostId); put("label", v.label) }
        }
    }
    fun action(v: JSONObject): SharedArtifactsAction {
        val now = v.getLong("nowMillis")
        return when (v.getString("type")) {
            "open" -> SharedArtifactsAction.Open(open(v.getJSONObject("open")), now)
            "navigate" -> SharedArtifactsAction.Navigate(v.getString("tabID"), target(v.getJSONObject("target")), v.getString("title"), now)
            "select" -> SharedArtifactsAction.Select(v.getString("tabID"), now)
            "close" -> SharedArtifactsAction.Close(v.getString("tabID"), now)
            "closeAll" -> SharedArtifactsAction.CloseAll(v.getString("hostID"), now)
            "pin" -> SharedArtifactsAction.Pin(v.getString("tabID"), v.getBoolean("pinned"), now)
            "setFilter" -> SharedArtifactsAction.SetFilter(wire<SharedArtifactsFilter>(v.getString("filter")) { it.wireValue }, now)
            "titleLearned" -> SharedArtifactsAction.TitleLearned(v.getString("tabID"), v.getString("title"), now)
            "fetched" -> SharedArtifactsAction.Fetched(v.getString("tabID"), cache(v.getJSONObject("cache")), now)
            "remoteStatObserved" -> SharedArtifactsAction.RemoteStatObserved(v.getString("tabID"), v.longOrNull("remoteMTime"), v.longOrNull("size"), v.getBoolean("visible"), now)
            "agentEditObserved" -> SharedArtifactsAction.AgentEditObserved(v.getString("hostID"), v.getString("path"), now)
            "hostRemoved" -> SharedArtifactsAction.HostRemoved(v.getString("hostID"), now)
            "hostRelabelled" -> SharedArtifactsAction.HostRelabelled(v.getString("hostID"), v.getString("label"), now)
            else -> error("unknown artifacts action")
        }
    }
    fun reduction(v: JSONObject) = SharedArtifactsReduction(state(v.getJSONObject("state")), v.stringOrNull("focusedTabID"), strings(v.getJSONArray("evictedTabIDs")), v.stringOrNull("navigatedPath"))
    fun overview(v: JSONObject): SharedArtifactsOverview {
        val counts = v.getJSONObject("countsByKind")
        return SharedArtifactsOverview(list(v.getJSONArray("groups")) { SharedArtifactsHostGroup(it.getString("hostID"), it.getString("hostLabel"), strings(it.getJSONArray("tabIDs"))) },
            SharedArtifactsKind.entries.associateWith { counts.getInt(it.wireValue) }, v.getInt("totalCount"))
    }
    fun presentation(v: JSONObject) = SharedArtifactsCachePresentation(wire<SharedArtifactsCacheState>(v.getString("state")) { it.wireValue }, v.longOrNull("fetchedAt"), v.getBoolean("canRefresh"))
    fun kind(v: JSONObject) = wire<SharedArtifactsKind>(v.getString("kind")) { it.wireValue } to wire<SharedArtifactsViewer>(v.getString("viewer")) { it.wireValue }
    fun encode(v: SharedArtifactsQuickOpenContext): JSONObject = JSONObject().put("hosts", array(v.hosts.map { JSONObject().put("id", it.id).put("label", it.label).put("home", it.home) }))
        .put("currentHostID", v.currentHostId).put("cwd", v.cwd).put("listeningPorts", array(v.listeningPorts.map { JSONObject().put("port", it.port).put("bindAddress", it.bindAddress).put("process", it.process) }))
        .put("activeForwards", array(v.activeForwards.map { JSONObject().put("hostID", it.hostId).put("rule", encode(it.rule)) }))
    fun context(v: JSONObject) = SharedArtifactsQuickOpenContext(list(v.getJSONArray("hosts")) { SharedArtifactsQuickOpenHost(it.getString("id"), it.getString("label"), it.stringOrNull("home")) },
        v.stringOrNull("currentHostID"), v.stringOrNull("cwd"), list(v.getJSONArray("listeningPorts"), ::listeningPort),
        v.optJSONArray("activeForwards")?.let { list(it) { forward -> SharedArtifactsActiveForward(forward.getString("hostID"), rule(forward.getJSONObject("rule"))) } }.orEmpty())
    fun listeningPort(v: JSONObject) = SharedArtifactsListeningPort(v.getInt("port"), v.getString("bindAddress"), v.stringOrNull("process"))
    fun encode(v: SharedArtifactsQuickOpenIntent): JSONObject = JSONObject().apply {
        when (v) {
            is SharedArtifactsQuickOpenIntent.File -> { put("type", "file"); put("hostID", v.hostId); put("path", v.path) }
            is SharedArtifactsQuickOpenIntent.Directory -> { put("type", "directory"); put("hostID", v.hostId); put("path", v.path) }
            is SharedArtifactsQuickOpenIntent.Page -> { put("type", "page"); put("hostID", v.hostId); put("scheme", v.scheme); put("port", v.port); put("path", v.path) }
            is SharedArtifactsQuickOpenIntent.Search -> { put("type", "search"); put("text", v.text) }
            is SharedArtifactsQuickOpenIntent.Invalid -> { put("type", "invalid"); put("reason", v.reason) }
        }
    }
    fun intent(v: JSONObject): SharedArtifactsQuickOpenIntent = when (v.getString("type")) {
        "file" -> SharedArtifactsQuickOpenIntent.File(v.getString("hostID"), v.getString("path"))
        "directory" -> SharedArtifactsQuickOpenIntent.Directory(v.getString("hostID"), v.getString("path"))
        "page" -> SharedArtifactsQuickOpenIntent.Page(v.getString("hostID"), v.getString("scheme"), v.getInt("port"), v.getString("path"))
        "search" -> SharedArtifactsQuickOpenIntent.Search(v.getString("text"))
        "invalid" -> SharedArtifactsQuickOpenIntent.Invalid(v.getString("reason"))
        else -> error("unknown quick open intent")
    }
    fun encode(v: SharedArtifactsRecent): JSONObject = JSONObject().put("title", v.title).put("subtitle", v.subtitle).put("intent", encode(v.intent)).put("viewedAt", v.viewedAt)
    fun recent(v: JSONObject) = SharedArtifactsRecent(v.getString("title"), v.getString("subtitle"), intent(v.getJSONObject("intent")), v.getLong("viewedAt"))
    fun suggestion(v: JSONObject) = SharedArtifactsSuggestion(wire<SharedArtifactsSuggestionKind>(v.getString("kind")) { it.wireValue }, v.getString("title"), v.getString("subtitle"), intent(v.getJSONObject("intent")), v.stringOrNull("tabID"))
    fun link(v: JSONObject): SharedArtifactsLinkClass = when (v.getString("type")) {
        "remoteLoopback" -> SharedArtifactsLinkClass.RemoteLoopback(v.getString("scheme"), v.getInt("port"), v.getString("pathAndQuery"))
        "refused" -> SharedArtifactsLinkClass.Refused
        "external" -> SharedArtifactsLinkClass.External
        "unsupported" -> SharedArtifactsLinkClass.Unsupported
        else -> error("unknown artifacts link class")
    }
    fun documentLink(v: JSONObject): SharedArtifactsDocumentLink = when (v.getString("type")) {
        "file" -> SharedArtifactsDocumentLink.File(v.getString("path"))
        "page" -> SharedArtifactsDocumentLink.Page(v.getString("scheme"), v.getInt("port"), v.getString("pathAndQuery"))
        "external" -> SharedArtifactsDocumentLink.External
        "refused" -> SharedArtifactsDocumentLink.Refused
        "ignored" -> SharedArtifactsDocumentLink.Ignored
        else -> error("unknown artifacts document link")
    }
    private fun encode(v: SharedForwardEndpoint) = JSONObject().put("host", v.host).put("port", v.port)
    fun encode(v: SharedForwardRule): JSONObject = JSONObject().put("id", v.id).put("enabled", v.enabled).put("autoStart", v.autoStart).put("direction", v.direction.wireValue)
        .put("bind", encode(v.bind)).put("target", v.target?.let(::encode)).put("label", v.label)
    fun rule(v: JSONObject) = SharedForwardRule(v.getString("id"), v.getBoolean("enabled"), v.getBoolean("autoStart"), SharedForwardDirection.fromWire(v.getString("direction")),
        v.getJSONObject("bind").let { SharedForwardEndpoint(it.getString("host"), it.getInt("port")) },
        v.optJSONObject("target")?.let { SharedForwardEndpoint(it.getString("host"), it.getInt("port")) }, v.getString("label"))
    fun forwardPlan(v: JSONObject): SharedArtifactsForwardPlan = when (v.getString("type")) {
        "reuse" -> SharedArtifactsForwardPlan.Reuse(v.getString("ruleID"), v.getJSONObject("target").let { SharedForwardedWebTarget(it.getString("scheme"), it.getString("host"), it.getInt("port"), it.getString("url")) })
        "ephemeral" -> SharedArtifactsForwardPlan.Ephemeral(rule(v.getJSONObject("rule")))
        else -> error("unknown artifacts forward plan")
    }
    fun encode(v: SharedArtifactsCacheEntry): JSONObject = JSONObject().put("key", v.key).put("size", v.size).put("viewedAt", v.viewedAt).put("pinned", v.pinned)
    fun entry(v: JSONObject) = SharedArtifactsCacheEntry(v.getString("key"), v.getLong("size"), v.getLong("viewedAt"), v.optBoolean("pinned", false))
}
