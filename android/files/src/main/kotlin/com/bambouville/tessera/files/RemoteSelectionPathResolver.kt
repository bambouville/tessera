package com.bambouville.tessera.files

/**
 * Conservative cleanup and expansion for a path selected in terminal output.
 *
 * A successful local parse only makes the Files action eligible. The caller
 * must still canonicalize and stat the result through its authenticated remote
 * file connection before it exposes or downloads anything.
 */
object RemoteSelectionPathResolver {
    private const val MAX_SELECTION_LENGTH = 1_024

    /**
     * Reduces a terminal selection to one path-shaped token. One pair of shell
     * quotes is accepted for filenames with spaces; unquoted whitespace is
     * treated as prose. Compiler/grep location suffixes and sentence
     * punctuation are stripped only at the end of the token.
     */
    fun pathCandidate(selection: String): String? {
        var value = selection.trim()
        if (value.isEmpty() || value.length > MAX_SELECTION_LENGTH || value.any(Char::isISOControl)) {
            return null
        }

        var quoted = false
        if (value.length >= 2 && value.first() == value.last() && value.first() in QUOTES) {
            value = value.substring(1, value.lastIndex)
            quoted = true
        }

        value = value.trimEnd { it in TRAILING_PUNCTUATION }
        value = COMPILER_LOCATION_SUFFIX.replace(value, "")
        value = value.trimEnd { it in TRAILING_PUNCTUATION }.trim()
        if (value.isEmpty() || value.any(Char::isISOControl)) return null
        if (!quoted && value.any(Char::isWhitespace)) return null
        if (quoted && value.any { it == '\n' || it == '\r' }) return null
        return value
    }

    /**
     * The second reading of a selection: the same token with *all*
     * whitespace removed.
     *
     * Coding agents print paths inside wrapped, indented TUI output, so a
     * path the user selects often arrives broken by a newline plus the next
     * row's indentation — `docs/review\n    v3.pdf`. The strict reading
     * rejects that (interior whitespace means prose), which is right for the
     * *first* attempt and wrong as the last word. Collapsing rejoins the
     * fragments so resolution gets a second, tolerant try.
     *
     * Null when there is nothing to collapse (no interior whitespace — the
     * strict reading already covers it), when the selection carries a
     * non-whitespace control character (terminal debris), or when it has too
     * many fragments to be one wrapped path.
     */
    fun collapsedPathCandidate(selection: String): String? {
        if (selection.any { it.isISOControl() && !isCollapsibleWhitespace(it) }) return null
        var value = selection.trim(::isCollapsibleWhitespace)
        if (value.isEmpty() || value.length > MAX_SELECTION_LENGTH) return null
        if (value.length >= 2 && value.first() == value.last() && value.first() in QUOTES) {
            value = value.substring(1, value.lastIndex).trim(::isCollapsibleWhitespace)
        }
        val fragments = value.split(*COLLAPSIBLE_WHITESPACE).filter(String::isNotEmpty)
        if (fragments.size <= 1 || fragments.size > MAX_COLLAPSED_FRAGMENTS) return null
        // Same tail cleanup as the strict reading: prose punctuation, then the
        // compiler/grep `:line[:col]` suffix, then punctuation again.
        var collapsed = fragments.joinToString(separator = "").trimEnd { it in TRAILING_PUNCTUATION }
        collapsed = COMPILER_LOCATION_SUFFIX.replace(collapsed, "")
        collapsed = collapsed.trimEnd { it in TRAILING_PUNCTUATION }
        return collapsed.ifEmpty { null }
    }

    /**
     * Every reading of one selection, best first: the strict token, then the
     * whitespace-collapsed rejoin. Resolution walks this in order, so an exact
     * hit always wins over a tolerant one.
     */
    fun pathCandidates(selection: String): List<String> = buildList {
        pathCandidate(selection)?.let(::add)
        collapsedPathCandidate(selection)?.takeIf { it !in this }?.let(::add)
    }

    /**
     * Cheap, local menu gate. Remote existence and type are checked later.
     * Both readings count, so a path that wrapped across rows still offers
     * the menu.
     */
    fun isPlausiblePath(selection: String): Boolean =
        pathCandidates(selection).any(::looksLikePath)

    private fun looksLikePath(candidate: String): Boolean =
        candidate.startsWith('/') ||
            candidate.startsWith('~') ||
            '/' in candidate ||
            (candidate.startsWith('.') && candidate.length > 1) ||
            BARE_EXTENSION.matches(candidate)

    /**
     * The whitespace a wrapped path can be broken by, spelled out rather than
     * deferred to `Char.isWhitespace`, so Kotlin and Swift agree character for
     * character (Java's `isWhitespace` excludes U+00A0; Foundation's
     * `whitespacesAndNewlines` includes it).
     */
    fun isCollapsibleWhitespace(character: Char): Boolean = character in COLLAPSIBLE_WHITESPACE

    /**
     * The name with every collapsible whitespace character removed —
     * `"review v3.pdf"` and `"reviewv3.pdf"` share one collapsed form, which
     * is exactly what makes them match in the fallback.
     */
    fun collapseWhitespace(value: String): String = value.filterNot(::isCollapsibleWhitespace)

    /**
     * Directory entries that answer to [name], exact spelling first.
     *
     * An exact hit short-circuits to a single result, so a directory holding
     * both `review v3.pdf` and `reviewv3.pdf` still resolves the one that was
     * actually named. Otherwise every entry whose name collapses to the same
     * spelling comes back, and the caller decides what to do with an ambiguous
     * set (Tessera refuses rather than guess which document to open).
     */
    fun <T> entriesNamed(name: String, entries: List<T>, nameOf: (T) -> String): List<T> {
        entries.firstOrNull { nameOf(it) == name }?.let { return listOf(it) }
        val target = collapseWhitespace(name)
        if (target.isEmpty()) return emptyList()
        return entries.filter { collapseWhitespace(nameOf(it)) == target }
    }

    /**
     * Anchors a cleaned selection to an absolute remote path without touching
     * the network. Relative paths require the terminal's authoritative cwd;
     * another user's home is intentionally not guessed.
     */
    fun expand(candidate: String, homePath: String?, currentDirectory: String?): String? {
        var path = candidate.trim()
        if (path.isEmpty() || path.any(Char::isISOControl)) return null
        path = when {
            path == "~" -> homePath ?: return null
            path.startsWith("~/") -> {
                val home = homePath ?: return null
                if (home == "/") "/${path.removePrefix("~/")}" else "${home.trimEnd('/')}/${path.removePrefix("~/")}"
            }
            path.startsWith('~') -> return null
            path.startsWith('/') -> path
            else -> {
                val cwd = currentDirectory?.takeIf { it.startsWith('/') } ?: return null
                "${cwd.trimEnd('/')}/$path"
            }
        }
        return lexicallyNormalize(path)
    }

    /** Normalizes dot segments without resolving symlinks; the connection does that remotely. */
    fun lexicallyNormalize(absolutePath: String): String {
        val parts = ArrayDeque<String>()
        absolutePath.split('/').forEach { part ->
            when (part) {
                "", "." -> Unit
                ".." -> if (parts.isNotEmpty()) parts.removeLast()
                else -> parts.addLast(part)
            }
        }
        return if (parts.isEmpty()) "/" else "/${parts.joinToString("/")}"
    }

    /**
     * Most whitespace-separated fragments a selection may have and still read
     * as one wrapped path. A path broken across a few terminal rows (or an
     * agent's indented continuation lines) produces a handful; a paragraph the
     * user swiped over produces many, and must not grow the selection menu.
     */
    const val MAX_COLLAPSED_FRAGMENTS = 8

    private val COLLAPSIBLE_WHITESPACE =
        charArrayOf(' ', '\t', '\n', '\r', '\u000B', '\u000C', '\u00A0')
    private val QUOTES = setOf('\'', '"', '`')
    private val TRAILING_PUNCTUATION = setOf(':', ',', ';', '.')
    private val COMPILER_LOCATION_SUFFIX = Regex(":\\d+(?::\\d+)?$")
    private val BARE_EXTENSION = Regex(".*\\.[A-Za-z0-9]{1,10}$")
}
