package com.bambouville.tessera.files

/**
 * The whitespace-tolerant second pass behind terminal-selection Quick Look.
 *
 * Coding agents print paths inside wrapped, indented TUI output, so a selected
 * path often arrives with the whitespace that broke it — and once that is
 * collapsed away, the spelling no longer matches a name that has spaces of its
 * own. This walk matches each path segment against the directory listing by
 * collapsed spelling, so `review v3.pdf` finds `reviewv3.pdf` and the reverse.
 *
 * It only ever runs after every exact reading has missed, so it can never
 * shadow a file that is really there. It is generic over the listing row and
 * takes its listing as a lambda, which keeps it unit-testable without SSH;
 * iOS peer: `RemotePathResolver.resolveIgnoringWhitespace`.
 */
object RemoteTolerantPathWalk {

    /**
     * The real remote path for [absolute], or null when nothing matches.
     *
     * [list] returns null for a directory that could not be listed (missing,
     * or not a directory) — that is a miss, not a failure. An ambiguous
     * directory, where several names collapse alike and none matches exactly,
     * fails instead: opening an arbitrary one of them would be a silent wrong
     * answer.
     */
    suspend fun <T> resolve(
        absolute: String,
        nameOf: (T) -> String,
        list: suspend (String) -> List<T>?,
    ): String? {
        val segments = absolute.split('/').filter(String::isNotEmpty)
        if (segments.isEmpty()) return null

        // The leaf on its own first: a path that only lost the spaces inside
        // its filename needs exactly one listing — the one the exact pass has
        // already warmed.
        val parent = if (segments.size == 1) "/" else "/" + segments.dropLast(1).joinToString("/")
        list(parent)?.let { siblings ->
            unique(segments.last(), siblings, nameOf, absolute)?.let {
                return join(parent, nameOf(it))
            }
        }

        // Otherwise walk from the root, which is where a *directory* whose own
        // name lost its spaces gets matched. Names come from the listing, never
        // from the selection's spelling: the result has to be addressable.
        var directory = "/"
        for (segment in segments) {
            val entries = list(directory) ?: return null
            val entry = unique(segment, entries, nameOf, absolute) ?: return null
            directory = join(directory, nameOf(entry))
        }
        return directory
    }

    private fun <T> unique(name: String, entries: List<T>, nameOf: (T) -> String, absolute: String): T? {
        val matches = RemoteSelectionPathResolver.entriesNamed(name, entries, nameOf)
        check(matches.size <= 1) { "Several files match $absolute — open it from the Files panel." }
        return matches.firstOrNull()
    }

    private fun join(directory: String, name: String): String =
        if (directory == "/") "/$name" else "$directory/$name"
}
