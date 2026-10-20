package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject

/** Display-only Markdown tree emitted by the shared Swift parser. */
data class SharedAgentMarkdownDocument(
    val blocks: List<SharedAgentMarkdownNode>,
    val truncated: Boolean,
)

data class SharedAgentMarkdownNode(
    val kind: String,
    val text: String? = null,
    val children: List<SharedAgentMarkdownNode> = emptyList(),
    val level: Int? = null,
    val start: Int? = null,
    val checked: Boolean? = null,
    val destination: String? = null,
    val language: String? = null,
    val alignment: String? = null,
)

/**
 * Thin Android adapter for the shared Markdown parser. This intentionally
 * decodes only Core-produced JSON; Markdown grammar never lives in Kotlin.
 */
object SharedAgentMarkdown {
    private const val MAX_INPUT_BYTES = 128 * 1024
    private const val MAX_OUTPUT_BYTES = 2 * 1024 * 1024
    private const val MAX_DEPTH = 26
    private const val MAX_NODES = 8_192

    /**
     * Composition parses synchronously, and a lazy transcript re-composes an
     * item every time it scrolls back into view. Parsed trees are immutable,
     * so one process-wide, byte-bounded LRU serves every surface.
     */
    private val cache = SharedAgentMarkdownCache(CACHE_BYTES)
    private const val CACHE_BYTES = 4 * 1024 * 1024

    /**
     * Sizes the LRU from the app's heap class (`ActivityManager.memoryClass`,
     * in MiB): 1/32 of the heap, between 4 and 16 MiB.
     */
    fun configureCache(heapClassMiB: Int) {
        cache.resize((heapClassMiB / 32).coerceIn(4, 16) * 1024 * 1024)
    }

    /** Memory pressure and disabling Agent Center drop every parsed tree. */
    fun clearCache() = cache.clear()

    fun parse(source: String): SharedAgentMarkdownDocument? {
        cache[source]?.let { return it }
        // A bridge failure is not cached: a later load may succeed.
        return parseUncached(source)?.also { cache.put(source, it) }
    }

    private fun parseUncached(source: String): SharedAgentMarkdownDocument? {
        return try {
            val (input, clipped) = clippedInputForNative(source)
            NativeLibraries.ensureLoaded()
            val json = NativeCoreBindings.agentMarkdownParse(
                if (input.isEmpty()) null else input.toDirectBuffer(),
                input.size,
            )
            if (json == null) null else decodeJSON(json, clipped)
        } catch (_: LinkageError) {
            null
        } catch (_: SecurityException) {
            null
        } catch (_: RuntimeException) {
            null
        }
    }

    /** Kept internal for a JVM-only adapter test; it never parses Markdown. */
    internal fun decodeJSONForTesting(json: String, inputWasClipped: Boolean = false): SharedAgentMarkdownDocument? =
        try {
            decodeJSON(json, inputWasClipped)
        } catch (_: RuntimeException) {
            null
        }

    /** Clips at a UTF-8 scalar boundary before the JNI hop. */
    internal fun clippedInputForNative(source: String): Pair<ByteArray, Boolean> {
        val encoded = source.encodeToByteArray()
        if (encoded.size <= MAX_INPUT_BYTES) return encoded to false
        var end = MAX_INPUT_BYTES
        while (end > 0 && ((encoded[end].toInt() and 0xC0) == 0x80)) end -= 1
        return encoded.copyOf(end) to true
    }

    private fun decodeJSON(json: String, inputWasClipped: Boolean): SharedAgentMarkdownDocument? {
        if (json.encodeToByteArray().size > MAX_OUTPUT_BYTES) return null
        val root = JSONObject(json)
        val blocks = root.optJSONArray("blocks") ?: return null
        if (!root.has("truncated") || root.isNull("truncated")) return null
        val state = DecodeState()
        val nodes = buildList {
            for (index in 0 until blocks.length()) {
                add(state.node(blocks.getJSONObject(index), 1))
            }
        }
        return SharedAgentMarkdownDocument(nodes, root.getBoolean("truncated") || inputWasClipped)
    }

    private class DecodeState {
        private var nodeCount = 0

        fun node(value: JSONObject, depth: Int): SharedAgentMarkdownNode {
            require(depth <= MAX_DEPTH)
            require(++nodeCount <= MAX_NODES)
            val kind = value.requiredString("kind")
            require(kind.isNotEmpty() && kind.length <= 64)
            val children = value.optJSONArray("children")?.let { array ->
                buildList {
                    for (index in 0 until array.length()) add(node(array.getJSONObject(index), depth + 1))
                }
            } ?: emptyList()
            return SharedAgentMarkdownNode(
                kind = kind,
                text = value.optionalString("text"),
                children = children,
                level = value.optionalInt("level"),
                start = value.optionalInt("start"),
                checked = value.optionalBoolean("checked"),
                destination = value.optionalString("destination"),
                language = value.optionalString("language"),
                alignment = value.optionalString("alignment"),
            )
        }
    }
}

/**
 * Least-recently-used documents bounded by an estimate of retained bytes
 * (the key plus every node's strings and fixed overhead). A document larger
 * than a quarter of the budget is simply not retained.
 */
internal class SharedAgentMarkdownCache(private var maxBytes: Int) {
    private class Entry(val document: SharedAgentMarkdownDocument, val bytes: Int)
    private val entries = LinkedHashMap<String, Entry>(64, 0.75f, true)
    private var retainedBytes = 0

    @Synchronized operator fun get(source: String): SharedAgentMarkdownDocument? = entries[source]?.document

    @Synchronized fun put(source: String, document: SharedAgentMarkdownDocument) {
        val bytes = ENTRY_OVERHEAD_BYTES + source.length * 2 + document.blocks.sumOf { estimatedBytes(it) }
        if (bytes > maxBytes / 4) return
        entries.put(source, Entry(document, bytes))?.let { retainedBytes -= it.bytes }
        retainedBytes += bytes
        trim()
    }

    @Synchronized fun resize(maxBytes: Int) {
        this.maxBytes = maxBytes
        entries.values.removeAll { it.bytes > maxBytes / 4 }
        retainedBytes = entries.values.sumOf { it.bytes }
        trim()
    }

    @Synchronized fun clear() {
        entries.clear()
        retainedBytes = 0
    }

    private fun trim() {
        val iterator = entries.values.iterator()
        while (retainedBytes > maxBytes && iterator.hasNext()) {
            retainedBytes -= iterator.next().bytes
            iterator.remove()
        }
    }

    @get:Synchronized val size: Int get() = entries.size
    @get:Synchronized val bytes: Int get() = retainedBytes

    private fun estimatedBytes(node: SharedAgentMarkdownNode): Int = NODE_OVERHEAD_BYTES +
        2 * ((node.text?.length ?: 0) + (node.destination?.length ?: 0) + (node.language?.length ?: 0)) +
        node.children.sumOf { estimatedBytes(it) }

    private companion object {
        const val ENTRY_OVERHEAD_BYTES = 96
        const val NODE_OVERHEAD_BYTES = 96
    }
}

private fun JSONObject.requiredString(key: String): String = optionalString(key)
    ?: throw IllegalArgumentException("missing $key")

private fun JSONObject.optionalString(key: String): String? {
    if (!has(key) || isNull(key)) return null
    return get(key) as? String ?: throw IllegalArgumentException("invalid $key")
}

private fun JSONObject.optionalInt(key: String): Int? {
    if (!has(key) || isNull(key)) return null
    return when (val value = get(key)) {
        is Int -> value
        is Long -> value.toInt().also { require(it.toLong() == value) }
        else -> throw IllegalArgumentException("invalid $key")
    }
}

private fun JSONObject.optionalBoolean(key: String): Boolean? {
    if (!has(key) || isNull(key)) return null
    return get(key) as? Boolean ?: throw IllegalArgumentException("invalid $key")
}
