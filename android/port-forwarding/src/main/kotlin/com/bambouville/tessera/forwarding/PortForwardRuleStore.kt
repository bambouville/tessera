package com.bambouville.tessera.forwarding

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.portForwardingPreferences by preferencesDataStore(name = "tessera_port_forwarding")

/** Per-host, secret-free rule persistence kept separate from credential and host tables. */
interface PortForwardRuleStore {
    fun observe(hostId: String): Flow<List<PortForwardRule>>
    suspend fun replace(hostId: String, rules: List<PortForwardRule>)
    suspend fun delete(hostId: String)
}

class AndroidPortForwardRuleStore(context: Context) : PortForwardRuleStore {
    private val applicationContext = context.applicationContext

    override fun observe(hostId: String): Flow<List<PortForwardRule>> {
        val key = preferenceKey(hostId)
        return applicationContext.portForwardingPreferences.data.map { preferences ->
            PortForwardRuleCodec.decode(preferences[key].orEmpty())
        }
    }

    override suspend fun replace(hostId: String, rules: List<PortForwardRule>) {
        require(rules.map(PortForwardRule::id).distinct().size == rules.size) { "forwarding rule ids must be unique" }
        rules.forEach { rule ->
            require(PortForwardRuleValidator.validate(rule, rules) == null) { "invalid forwarding rule ${rule.id}" }
        }
        val key = preferenceKey(hostId)
        val encoded = PortForwardRuleCodec.encode(rules)
        applicationContext.portForwardingPreferences.edit { preferences ->
            if (encoded.isEmpty()) preferences.remove(key) else preferences[key] = encoded
        }
    }

    override suspend fun delete(hostId: String) {
        applicationContext.portForwardingPreferences.edit { preferences ->
            preferences.remove(preferenceKey(hostId))
        }
    }

    private fun preferenceKey(hostId: String) = stringPreferencesKey("host.${UUID.fromString(hostId)}")
}

/**
 * Small versioned persistence codec. It avoids generic object serialization so
 * malformed imported data is discarded per rule instead of crashing a host
 * editor or preventing the remaining rules from loading.
 *
 * It parses structure only and asks no policy question: forwarding policy now
 * lives in the shared core behind the native bridge, and every path that can
 * act on a decoded rule already consults it — [AndroidPortForwardRuleStore.replace]
 * before a rule is ever written, `PortForwardingManager` before a listener is
 * opened, and the host importer on anything arriving from outside. Keeping the
 * codec free of that call also keeps it exercisable without the native library.
 */
object PortForwardRuleCodec {
    fun encode(rules: List<PortForwardRule>): String = rules.joinToString("\n") { rule ->
        listOf(
            VERSION,
            rule.id.toString(),
            rule.enabled.toString(),
            rule.autoStart.toString(),
            rule.direction.name,
            encodeText(rule.bind.host),
            rule.bind.port.toString(),
            (rule.target != null).toString(),
            encodeText(rule.target?.host.orEmpty()),
            (rule.target?.port ?: 0).toString(),
            encodeText(rule.label),
        ).joinToString(FIELD_SEPARATOR)
    }

    fun decode(value: String): List<PortForwardRule> = value.lineSequence()
        .filter(String::isNotBlank)
        .mapNotNull(::decodeRule)
        .toList()

    private fun decodeRule(line: String): PortForwardRule? = runCatching {
        val fields = line.split(FIELD_SEPARATOR)
        require(fields.size == FIELD_COUNT && fields[0] == VERSION)
        val target = if (fields[7].toBooleanStrict()) {
            PortForwardEndpoint(decodeText(fields[8]), port(fields[9]))
        } else {
            null
        }
        PortForwardRule(
            id = UUID.fromString(fields[1]),
            enabled = fields[2].toBooleanStrict(),
            autoStart = fields[3].toBooleanStrict(),
            direction = PortForwardDirection.valueOf(fields[4]),
            bind = PortForwardEndpoint(decodeText(fields[5]), port(fields[6])),
            target = target,
            label = decodeText(fields[10]),
        )
    }.getOrNull()

    /** A number outside the representable range is not a port, only noise. */
    private fun port(value: String): Int = value.toInt().also { require(it in PORT_RANGE) }

    private fun encodeText(value: String): String = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(value.encodeToByteArray())

    private fun decodeText(value: String): String = Base64.getUrlDecoder().decode(value).decodeToString()

    private const val VERSION = "v1"
    private const val FIELD_SEPARATOR = "|"
    private const val FIELD_COUNT = 11
}
