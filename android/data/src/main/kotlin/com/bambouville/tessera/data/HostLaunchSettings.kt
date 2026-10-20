package com.bambouville.tessera.data

/** Same per-host shell prologue across SSH, mosh and their tmux launchers.
 * Values are intentional user shell text, not escaped literals. Newlines
 * preserve comments and compound commands; only environment names are parsed.
 */
object HostLaunchSettings {
    fun prologue(envVars: String?, startupSnippet: String?): String = buildList {
        envVars.orEmpty().lineSequence().forEach { raw ->
            val line = raw.trim().removePrefix("export ").removePrefix("export\t").trimStart()
            if (line.startsWith("#") || '=' !in line) return@forEach
            val key = line.substringBefore('=').trim()
            if (Regex("[A-Za-z_][A-Za-z0-9_]*").matches(key)) add("export $key=${line.substringAfter('=')}")
        }
        startupSnippet?.trim()?.takeIf { it.isNotEmpty() }?.let(::add)
    }.joinToString("\n").let { if (it.isEmpty()) "" else "$it\n" }

    fun stdin(host: SavedHost, includeStartupSnippet: Boolean = true): String = prologue(host.envVars, host.startupSnippet.takeIf { includeStartupSnippet }) +
        host.launchCommand?.trim()?.takeIf { host.tmuxMode == TmuxModes.OFF && it.isNotEmpty() }?.let { "$it\n" }.orEmpty()

    fun beforeCommand(host: SavedHost, command: String): String {
        val prefix = prologue(host.envVars, host.startupSnippet)
        return if (prefix.isEmpty()) command else shell(prefix + command)
    }

    fun moshCommand(host: SavedHost, tmuxCommand: String?): String? {
        val prefix = prologue(host.envVars, host.startupSnippet)
        val command = tmuxCommand ?: host.launchCommand?.trim()?.takeIf { it.isNotEmpty() }
        if (prefix.isEmpty() && command == null) return null
        if (prefix.isEmpty() && tmuxCommand != null) return tmuxCommand
        return shell(prefix + (command ?: "exec \"\${SHELL:-/bin/sh}\" -l"))
    }

    private fun shell(command: String) = "/bin/sh -lc '" + command.replace("'", "'\\''") + "'"
}
