package com.bambouville.tessera.feature.hosts

import com.bambouville.tessera.data.HostDraft
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.forwarding.PortForwardDirection
import com.bambouville.tessera.forwarding.PortForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleValidator
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal object HostImportCodec {
    data class Payload(val host: HostDraft, val forwardingRules: List<PortForwardRule>)

    fun encode(host: SavedHost, forwardingRules: List<PortForwardRule> = emptyList()): String = JSONObject()
        .put("format", "tessera-host-v2")
        .put("name", host.displayName)
        .put("hostname", host.hostname)
        .put("port", host.port)
        .put("username", host.username)
        .put("transport", host.transportKind)
        .put("tmuxMode", host.tmuxMode)
        .put("tmuxTarget", host.tmuxTarget)
        .put("portForwards", JSONArray().apply {
            forwardingRules.forEach { rule ->
                put(JSONObject()
                    .put("id", rule.id.toString())
                    .put("enabled", rule.enabled)
                    .put("autoStart", rule.autoStart)
                    .put("direction", rule.direction.name.lowercase())
                    .put("bindHost", rule.bind.host)
                    .put("bindPort", rule.bind.port)
                    .put("targetHost", rule.target?.host)
                    .put("targetPort", rule.target?.port)
                    .put("label", rule.label))
            }
        })
        .toString(2)

    fun decode(value: String): Payload {
        require(value.length <= 64 * 1024) { "host import is too large" }
        val json = JSONObject(value)
        val format = json.optString("format")
        require(format == "tessera-host-v1" || format == "tessera-host-v2") {
            "unsupported host import format"
        }
        val tmuxMode = json.optString("tmuxMode", TmuxModes.OFF)
        val rules = if (format == "tessera-host-v2") decodeForwards(json.optJSONArray("portForwards")) else emptyList()
        return Payload(
            host = HostDraft(
                displayName = json.optString("name"),
                hostname = json.getString("hostname"),
                port = json.optInt("port", 22),
                username = json.getString("username"),
                // Older payloads predate the field; a host without it was SSH.
                transportKind = json.optString("transport", TransportKinds.SSH),
                tmuxMode = tmuxMode,
                tmuxTarget = json.optString("tmuxTarget").takeIf { it.isNotBlank() && it != "null" },
            ),
            forwardingRules = rules,
        )
    }

    private fun decodeForwards(items: JSONArray?): List<PortForwardRule> = buildList {
        val array = items ?: return@buildList
        require(array.length() <= 128) { "too many port forwards" }
        for (index in 0 until array.length()) {
            val item = array.getJSONObject(index)
            val direction = PortForwardDirection.valueOf(item.getString("direction").uppercase())
            val targetHost = item.optString("targetHost").takeIf { it.isNotBlank() && it != "null" }
            val targetPort = item.optInt("targetPort", 0)
            val rule = PortForwardRule(
                id = UUID.fromString(item.getString("id")),
                enabled = item.optBoolean("enabled", true),
                autoStart = item.optBoolean("autoStart", true),
                direction = direction,
                bind = PortForwardEndpoint(item.getString("bindHost"), item.getInt("bindPort")),
                target = targetHost?.let { PortForwardEndpoint(it, targetPort) },
                label = item.optString("label"),
            )
            require(PortForwardRuleValidator.validate(rule, this) == null) { "invalid port forward" }
            add(rule)
        }
    }
}
