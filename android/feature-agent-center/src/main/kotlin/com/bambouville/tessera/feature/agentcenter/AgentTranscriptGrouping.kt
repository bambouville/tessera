package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.core.bridge.SharedAgentValue

/** Display-only ABI projection. All membership and summary rules live in Swift Core. */
data class AgentToolRunDescriptor(val key: String, val entryIDs: List<String>, val summaryTitle: String, val latestSummary: String?)

sealed class AgentTranscriptItem {
    abstract val key: String
    data class Block(val block: AgentBlock, override val key: String) : AgentTranscriptItem()
    data class ToolRun(val entries: List<AgentTranscriptEntry>, val descriptor: AgentToolRunDescriptor) : AgentTranscriptItem() {
        override val key: String get() = descriptor.key
        val summaryTitle: String get() = descriptor.summaryTitle
        val latestSummary: String? get() = descriptor.latestSummary
    }
}

data class AgentTranscriptEntry(val block: AgentBlock, val key: String)

internal fun agentToolRunDescriptors(values: List<SharedAgentValue>?): List<AgentToolRunDescriptor> = values.orEmpty().mapNotNull { value ->
    val wire = value as? SharedAgentValue.ObjectValue ?: return@mapNotNull null
    val key = wire.string("id") ?: return@mapNotNull null
    val entries = wire.array("entryIDs").orEmpty().mapNotNull { (it as? SharedAgentValue.StringValue)?.value }
    if (entries.isEmpty() || entries.first() != key) return@mapNotNull null
    AgentToolRunDescriptor(key, entries, wire.string("summaryTitle") ?: return@mapNotNull null, wire.string("latestSummary"))
}

internal fun agentBlockKeys(blocks: List<AgentBlock>): List<String> {
    val occurrences = mutableMapOf<String, Int>()
    return blocks.map { block ->
        val base = block.recordID ?: "${block.kind}:${block.title}:${block.body.hashCode()}"
        val ordinal = occurrences.getOrDefault(base, 0)
        occurrences[base] = ordinal + 1
        "$base#$ordinal"
    }
}

internal fun agentTranscriptItems(blocks: List<AgentBlock>, runs: List<AgentToolRunDescriptor>): List<AgentTranscriptItem> {
    val keys = agentBlockKeys(blocks)
    val byStart = runs.associateBy { it.key }
    val items = mutableListOf<AgentTranscriptItem>()
    var index = 0
    while (index < blocks.size) {
        val descriptor = byStart[keys[index]]
        val end = index + (descriptor?.entryIDs?.size ?: 0)
        // A stale/malformed display descriptor must never hide unrelated content.
        if (descriptor != null && descriptor.entryIDs.isNotEmpty() && end <= blocks.size && keys.subList(index, end) == descriptor.entryIDs) {
            items += AgentTranscriptItem.ToolRun((index until end).map { AgentTranscriptEntry(blocks[it], keys[it]) }, descriptor)
            index = end
        } else {
            items += AgentTranscriptItem.Block(blocks[index], keys[index])
            index += 1
        }
    }
    return items
}

/**
 * LazyColumn row keys that survive a run growing at its start. Core keys a run
 * by its first entry, so an older page whose tool activity merges into the top
 * run would rename that row: the list would lose the reader's anchor while
 * paging older. As on iOS (`toolRunAnchors`), a run keeps the key its list row
 * last used for any of its entries; failing that, the key of a standalone card
 * it absorbed (thinking that older tool activity now joins). A remembered key
 * never takes a key another row owns, so the list's keys stay unique even if
 * Core regroups a transcript unexpectedly.
 */
internal class AgentTranscriptRowKeys {
    private var runAnchors: Map<String, String> = emptyMap()
    private var blockKeys: Set<String> = emptySet()
    // An unchanged run keeps its instance: Compose compares a run (it holds a
    // List) by identity, so its visible card can skip recomposition.
    private var previousRuns: Map<String, AgentTranscriptItem.ToolRun> = emptyMap()

    fun apply(items: List<AgentTranscriptItem>): List<AgentTranscriptItem> {
        val owned = items.mapTo(HashSet()) { it.key }
        val inherited = HashSet<String>()
        val nextAnchors = HashMap<String, String>()
        val nextRuns = HashMap<String, AgentTranscriptItem.ToolRun>()
        return items.map { item ->
            if (item !is AgentTranscriptItem.ToolRun) return@map item
            val remembered = item.entries.firstNotNullOfOrNull { runAnchors[it.key] }
                ?: item.entries.firstOrNull { it.key in blockKeys }?.key
            val key = remembered?.takeIf { it == item.key || (it !in owned && inherited.add(it)) } ?: item.key
            item.entries.forEach { nextAnchors[it.key] = key }
            val anchored = if (key == item.key) item else item.copy(descriptor = item.descriptor.copy(key = key))
            (previousRuns[key]?.takeIf { it == anchored } ?: anchored).also { nextRuns[key] = it }
        }.also { anchored ->
            runAnchors = nextAnchors
            blockKeys = anchored.mapNotNullTo(HashSet()) { (it as? AgentTranscriptItem.Block)?.key }
            previousRuns = nextRuns
        }
    }
}

/** An expanded run keeps its header and gives each entry its own lazy row. */
internal fun agentTranscriptDisplayItems(items: List<AgentTranscriptItem>, expandedEntries: Collection<String>): List<AgentTranscriptItem> =
    items.flatMap { item ->
        if (item is AgentTranscriptItem.ToolRun && item.entries.any { it.key in expandedEntries }) {
            listOf(item) + item.entries.map { AgentTranscriptItem.Block(it.block, "agent-tool-detail:${it.key}") }
        } else listOf(item)
    }
