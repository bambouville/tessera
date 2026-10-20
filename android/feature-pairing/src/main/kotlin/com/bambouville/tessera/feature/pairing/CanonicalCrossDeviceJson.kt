package com.bambouville.tessera.feature.pairing

import android.util.Base64
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.UUID

/**
 * The C ABI accepts one JSON spelling only: Swift's sorted-key JSONEncoder
 * output.  This deliberately tiny writer is an ABI adapter, not a protocol
 * encoder. Complex payloads emitted by the core are retained as validated raw
 * JSON rather than being decoded and reimplemented on Android.
 */
internal object CanonicalCrossDeviceJson {
    fun command(kind: String, generation: Long, fields: Map<String, JsonValue> = emptyMap()): ByteArray {
        require(generation >= 0) { "generation must be unsigned" }
        val values = linkedMapOf<String, JsonValue>(
            "v" to JsonValue.Number(1),
            "kind" to JsonValue.String(kind),
            "generation" to JsonValue.Number(generation),
        )
        values.putAll(fields)
        return objectValue(values).encodeToByteArray()
    }

    fun objectValue(values: Map<String, JsonValue>): String = values.entries
        .sortedBy { it.key }
        .joinToString(prefix = "{", postfix = "}", separator = ",") { (key, value) ->
            stringValue(key) + ":" + value.encoded()
        }

    fun stringValue(value: String): String = buildString(value.length + 2) {
        append('"')
        value.forEach { character ->
            when (character) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\b' -> append("\\b")
                '\u000c' -> append("\\f")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (character.code < 0x20) append("\\u%04x".format(Locale.ROOT, character.code))
                else append(character)
            }
        }
        append('"')
    }

    fun uuid(value: UUID): String = value.toString().uppercase(Locale.ROOT)

    fun base64(value: ByteArray): String = Base64.encodeToString(value, Base64.NO_WRAP)

    sealed interface JsonValue {
        fun encoded(): kotlin.String

        data class String(val value: kotlin.String) : JsonValue {
            override fun encoded() = stringValue(value)
        }
        data class Number(val value: Long) : JsonValue {
            override fun encoded() = value.toString()
        }
        data class Boolean(val value: kotlin.Boolean) : JsonValue {
            override fun encoded() = value.toString()
        }
        data class Raw(val value: kotlin.String) : JsonValue {
            override fun encoded(): kotlin.String {
                require(value.isNotBlank()) { "raw JSON cannot be empty" }
                return value
            }
        }
        data class Array(val values: List<JsonValue>) : JsonValue {
            override fun encoded() = values.joinToString(prefix = "[", postfix = "]", separator = ",") { it.encoded() }
        }
    }

    fun raw(bytes: ByteArray): JsonValue.Raw = JsonValue.Raw(bytes.toString(StandardCharsets.UTF_8))
}
