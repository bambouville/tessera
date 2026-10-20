package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject
import java.util.Collections

/**
 * Immutable canonical JSON tree emitted by TesseraAgentCore. It deliberately
 * represents normalized Agent snapshots, never provider JSON, transcript file
 * paths, SSH objects, or JNI buffers.
 */
sealed interface SharedAgentValue {
    data class StringValue(val value: String) : SharedAgentValue
    data class NumberValue(val value: String) : SharedAgentValue
    data class BooleanValue(val value: Boolean) : SharedAgentValue
    data object Null : SharedAgentValue
    data class ArrayValue(val values: List<SharedAgentValue>) : SharedAgentValue
    data class ObjectValue(val fields: Map<String, SharedAgentValue>) : SharedAgentValue
}

enum class SharedAgentSnapshotKind(val wireValue: String) {
    List("listSnapshot"),
    Thread("threadSnapshot"),
    Lifecycle("lifecycleAccepted"),
    Projection("projectionApplied"),
    ActionPlan("actionPlan"),
    LaunchPlan("launchPlan"),
    Search("searchSnapshot"),
    PromptObservation("promptObservation"),
    Unknown("unknown");

    companion object {
        fun fromEventKind(value: String): SharedAgentSnapshotKind = when (value) {
            "listSnapshot" -> List
            "threadSnapshot" -> Thread
            "lifecycleAccepted" -> Lifecycle
            "projectionApplied" -> Projection
            "actionPlan" -> ActionPlan
            "launchPlan" -> LaunchPlan
            "searchSnapshot" -> Search
            "promptObservation" -> PromptObservation
            else -> Unknown
        }
    }
}

data class SharedAgentSnapshot(
    val runtimeGeneration: Long,
    val kind: SharedAgentSnapshotKind,
    val payload: SharedAgentValue.ObjectValue,
)

data class SharedAgentPromptAnswerStep(
    val action: String,
    val bytes: String?,
    val semanticKey: String?,
    val phase: String?,
    val refusal: String?,
    val anchor: SharedAgentValue.ObjectValue?,
) {
    companion object {
        fun decode(wire: SharedAgentValue.ObjectValue): SharedAgentPromptAnswerStep? {
            val step = wire.fields["step"] as? SharedAgentValue.ObjectValue ?: return null
            fun string(key: String) = (step.fields[key] as? SharedAgentValue.StringValue)?.value
            return SharedAgentPromptAnswerStep(string("action") ?: return null, string("bytes"),
                string("semanticKey"), string("phase"), string("refusal"), wire.fields["anchor"] as? SharedAgentValue.ObjectValue)
        }
    }
}

data class SharedAgentRouteRetirement(
    val threadID: SharedAgentValue.ObjectValue,
    val bindingToken: String,
    val successor: SharedAgentValue.ObjectValue?,
    val reason: String,
)

sealed interface SharedAgentRuntimeEvent {
    val runtimeGeneration: Long

    data class Snapshot(val snapshot: SharedAgentSnapshot) : SharedAgentRuntimeEvent {
        override val runtimeGeneration: Long = snapshot.runtimeGeneration
    }

    data class Failure(
        override val runtimeGeneration: Long,
        val code: String,
        val details: SharedAgentValue.ObjectValue,
    ) : SharedAgentRuntimeEvent

    data class RoutesRetired(
        override val runtimeGeneration: Long,
        val retirements: List<SharedAgentRouteRetirement>,
    ) : SharedAgentRuntimeEvent

    data class Notice(
        override val runtimeGeneration: Long,
        val kind: String,
        val details: SharedAgentValue.ObjectValue,
    ) : SharedAgentRuntimeEvent
}

/**
 * A callback the decoder refused. [code] is a fixed identifier that is safe
 * for exported diagnostics; parser messages can quote payload text and are
 * deliberately never surfaced.
 */
class SharedAgentEventDecodeException(val code: String) : IllegalArgumentException(code)

/** Versioned callback decoder shared by the JNI sink and Android tests. */
object SharedAgentEventDecoder {
    private const val ABI_VERSION = 1
    private const val MAX_TREE_DEPTH = 32
    private const val MAX_STRING_BYTES = 262_144

    fun decode(bytes: ByteArray): SharedAgentRuntimeEvent {
        decodeRequire(bytes.isNotEmpty() && bytes.size <= CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES, "payloadSize")
        val root = JSONObject(bytes.decodeToString())
        val version = when {
            root.has("v") -> root.optInt("v", -1)
            root.has("version") -> root.optInt("version", -1)
            else -> -1
        }
        decodeRequire(version == ABI_VERSION, "version")
        val generation = root.requireGeneration()
        val kind = root.optString("kind").takeIf { it.isNotBlank() }
            ?: throw SharedAgentEventDecodeException("kindMissing")
        // Every counted value occupies at least one byte of the frame, so a
        // budget of the frame's own size can never reject a legal snapshot
        // (Core admits ~768 KB of thread presentation into the 1 MiB frame,
        // which is far more than a fixed 32K values of small tool records)
        // while still bounding hostile input linearly.
        val budget = NodeBudget(bytes.size)
        return when (kind) {
            "routesRetired" -> {
                val payload = root.toSharedAgentObject(depth = 0, budget = budget)
                val entries = (payload.fields["retirements"] as? SharedAgentValue.ArrayValue)?.values
                    ?: throw SharedAgentEventDecodeException("retirementsMissing")
                SharedAgentRuntimeEvent.RoutesRetired(generation, Collections.unmodifiableList(entries.map { value ->
                    val entry = value as? SharedAgentValue.ObjectValue
                        ?: throw SharedAgentEventDecodeException("retirementInvalid")
                    val threadID = entry.fields["threadID"] as? SharedAgentValue.ObjectValue
                        ?: throw SharedAgentEventDecodeException("retirementThreadMissing")
                    requireRetirementThreadID(threadID)
                    val token = (entry.fields["bindingToken"] as? SharedAgentValue.StringValue)?.value
                        ?: throw SharedAgentEventDecodeException("retirementTokenMissing")
                    val reason = (entry.fields["reason"] as? SharedAgentValue.StringValue)?.value
                        ?: throw SharedAgentEventDecodeException("retirementReasonMissing")
                    decodeRequire(token.isNotBlank() && token.length <= 128, "retirementTokenInvalid")
                    decodeRequire(reason in setOf("replaced", "absent", "cleared", "unbound"), "retirementReasonInvalid")
                    val successor = entry.fields["successor"]
                    decodeRequire(successor == null || successor == SharedAgentValue.Null || successor is SharedAgentValue.ObjectValue,
                        "retirementSuccessorInvalid")
                    if (successor is SharedAgentValue.ObjectValue) requireRetirementThreadID(successor)
                    SharedAgentRouteRetirement(threadID, token, successor as? SharedAgentValue.ObjectValue, reason)
                }))
            }
            "listSnapshot", "threadSnapshot", "lifecycleAccepted", "projectionApplied",
            "actionPlan", "launchPlan", "searchSnapshot", "promptObservation" -> {
                SharedAgentRuntimeEvent.Snapshot(
                    SharedAgentSnapshot(
                        runtimeGeneration = generation,
                        kind = SharedAgentSnapshotKind.fromEventKind(kind),
                        // Preserve every ABI field (including optional nulls), so Android
                        // can render the shared snapshot without reimplementing its reducer.
                        payload = root.toSharedAgentObject(depth = 0, budget = budget),
                    ),
                )
            }
            "commandRejected" -> SharedAgentRuntimeEvent.Failure(
                runtimeGeneration = generation,
                code = root.optString("code").takeIf { it.isNotBlank() } ?: "unknown",
                details = root.toSharedAgentObject(depth = 0, budget = budget),
            )
            else -> SharedAgentRuntimeEvent.Notice(
                runtimeGeneration = generation,
                kind = kind,
                details = root.toSharedAgentObject(depth = 0, budget = budget),
            )
        }
    }

    private fun requireRetirementThreadID(value: SharedAgentValue.ObjectValue) {
        val provider = value.fields["providerID"] as? SharedAgentValue.ObjectValue
        decodeRequire(listOf(value.fields["hostID"], value.fields["providerSessionID"], provider?.fields?.get("rawValue"))
            .all { it is SharedAgentValue.StringValue && it.value.isNotBlank() }, "retirementThreadInvalid")
    }

    private fun JSONObject.requireGeneration(): Long {
        decodeRequire(has("generation"), "generationMissing")
        val value = optLong("generation", Long.MIN_VALUE)
        decodeRequire(value >= 1, "generation")
        return value
    }

    private fun JSONObject.toSharedAgentObject(depth: Int, budget: NodeBudget): SharedAgentValue.ObjectValue {
        checkDepth(depth)
        val fields = sortedMapOf<String, SharedAgentValue>()
        keys().forEach { key ->
            decodeRequire(key.length <= 256, "keyTooLong")
            fields[key] = get(key).toSharedAgentValue(depth + 1, budget)
        }
        return SharedAgentValue.ObjectValue(Collections.unmodifiableMap(fields))
    }

    private fun Any?.toSharedAgentValue(depth: Int, budget: NodeBudget): SharedAgentValue {
        checkDepth(depth)
        budget.consume()
        return when (this) {
            null, JSONObject.NULL -> SharedAgentValue.Null
            is String -> {
                decodeRequire(utf8FitsStringLimit(), "stringTooLarge")
                SharedAgentValue.StringValue(this)
            }
            is Boolean -> SharedAgentValue.BooleanValue(this)
            is Number -> SharedAgentValue.NumberValue(toString())
            is JSONObject -> toSharedAgentObject(depth, budget)
            is JSONArray -> SharedAgentValue.ArrayValue(Collections.unmodifiableList(
                List(length()) { index -> get(index).toSharedAgentValue(depth + 1, budget) },
            ))
            else -> throw SharedAgentEventDecodeException("unsupportedValue")
        }
    }

    /**
     * A UTF-16 code unit encodes to 1..3 UTF-8 bytes (a surrogate pair to 4
     * for its two units), so only strings in the ambiguous band pay for an
     * exact re-encode. Snapshots carry thousands of short strings.
     */
    private fun String.utf8FitsStringLimit(): Boolean = when {
        length.toLong() * 3 <= MAX_STRING_BYTES -> true
        length > MAX_STRING_BYTES -> false
        else -> encodeToByteArray().size <= MAX_STRING_BYTES
    }

    private fun checkDepth(depth: Int) {
        decodeRequire(depth <= MAX_TREE_DEPTH, "tooDeep")
    }

    private fun decodeRequire(condition: Boolean, code: String) {
        if (!condition) throw SharedAgentEventDecodeException(code)
    }

    private class NodeBudget(private var remaining: Int) {
        fun consume() {
            decodeRequire(remaining-- > 0, "tooManyValues")
        }
    }
}
