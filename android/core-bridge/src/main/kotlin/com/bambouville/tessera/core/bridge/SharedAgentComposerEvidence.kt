package com.bambouville.tessera.core.bridge

import org.json.JSONObject

/** Shared, cursor-anchored evidence; no native-side provider grammar. */
object SharedAgentComposerEvidence {
    fun insertion(provider: String, text: String): ByteArray? = try {
        val bytes = JSONObject().put("provider", provider).put("text", text).put("bracketedPasteEnabled", false)
            .toString().encodeToByteArray()
        if (bytes.size > 262_144) null else {
            NativeLibraries.ensureLoaded()
            java.util.Base64.getDecoder().decode(NativeCoreBindings.agentComposerInsertion(bytes.toDirectBuffer(), bytes.size))
        }
    } catch (_: Exception) { null }

    enum class Assessment { UNAVAILABLE, ABSENT, RETURN, TAB, BLOCKED, OCCUPIED }

    fun assess(provider: String, visibleText: String, cursorLine: String?, text: String, queueWhenWorking: Boolean, cursorRow: Int? = null, safetyOnly: Boolean = false, requireEmpty: Boolean = false, cursorVisible: Boolean? = null, cursorColumn: Int? = null, screen: SharedTerminalScreenEvidence? = null, literalImagePathsOnly: Boolean = false): Assessment = try {
        val bytes = JSONObject().put("provider", provider).put("visibleText", visibleText)
            .put("cursorLine", cursorLine ?: JSONObject.NULL).put("text", text)
            .put("queueWhenWorking", queueWhenWorking).putOpt("cursorRow", cursorRow)
            .put("literalImagePathsOnly", literalImagePathsOnly).put("safetyOnly", safetyOnly).put("requireEmpty", requireEmpty).putOpt("cursorVisible", cursorVisible)
            .putOpt("cursorColumn", cursorColumn).putOpt("screen", screen?.toJSON()).toString().encodeToByteArray()
        if (bytes.size > 2 * 1_024 * 1_024) Assessment.UNAVAILABLE else {
            NativeLibraries.ensureLoaded()
            when (NativeCoreBindings.agentComposerAssess(bytes.toDirectBuffer(), bytes.size)) {
                0 -> Assessment.ABSENT
                1 -> Assessment.RETURN
                2 -> Assessment.TAB
                3 -> Assessment.BLOCKED
                4 -> Assessment.OCCUPIED
                else -> Assessment.UNAVAILABLE
            }
        }
    } catch (_: LinkageError) { Assessment.UNAVAILABLE } catch (_: RuntimeException) { Assessment.UNAVAILABLE }

    fun matches(provider: String, visibleText: String, cursorLine: String?, text: String): Boolean = try {
        val bytes = JSONObject().put("provider", provider).put("visibleText", visibleText)
            .put("cursorLine", cursorLine ?: JSONObject.NULL).put("text", text).toString().encodeToByteArray()
        if (bytes.size > 256 * 1_024) false else {
            NativeLibraries.ensureLoaded()
            NativeCoreBindings.agentComposerMatches(bytes.toDirectBuffer(), bytes.size)
        }
    } catch (_: LinkageError) { false } catch (_: RuntimeException) { false }
}
