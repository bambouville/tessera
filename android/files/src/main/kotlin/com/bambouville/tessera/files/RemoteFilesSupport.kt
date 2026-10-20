package com.bambouville.tessera.files

import android.content.Intent
import android.net.Uri
import androidx.core.content.IntentCompat
import java.util.Locale

enum class RemoteFileRowTap { NAVIGATE, QUICK_VIEW, NONE }

/** Pure browser rules, kept independent of the SFTP implementation. */
object RemoteFilesBrowser {
    fun isPreparingPresentation(item: TransferItem): Boolean =
        item.direction == TransferDirection.DOWNLOAD && item.localUri == null &&
            item.phase in setOf(TransferPhase.QUEUED, TransferPhase.RUNNING, TransferPhase.CANCELLING)

    fun rowTap(kind: RemoteFileKind): RemoteFileRowTap = when (kind) {
        RemoteFileKind.DIRECTORY, RemoteFileKind.SYMLINK -> RemoteFileRowTap.NAVIGATE
        RemoteFileKind.FILE -> RemoteFileRowTap.QUICK_VIEW
        RemoteFileKind.OTHER -> RemoteFileRowTap.NONE
    }

    fun requestedPath(value: String, homePath: String? = null): String? {
        val requested = value.trim().takeIf { it.isNotEmpty() && it.none(Char::isISOControl) } ?: return null
        return when {
            requested == "~" -> homePath
            requested.startsWith("~/") -> homePath?.let { home ->
                val suffix = requested.removePrefix("~/")
                if (home == "/") "/$suffix" else "${home.trimEnd('/')}/$suffix"
            }
            requested.startsWith("~") -> null
            else -> requested
        }
    }

    fun filter(entries: List<RemoteFileEntry>, query: String): List<RemoteFileEntry> {
        val needle = query.trim().lowercase(Locale.ROOT)
        return if (needle.isEmpty()) entries else entries.filter { entry ->
            entry.name.lowercase(Locale.ROOT).contains(needle) ||
                entry.path.lowercase(Locale.ROOT).contains(needle)
        }
    }
}

/**
 * One share-in parser for ACTION_SEND and ACTION_SEND_MULTIPLE. MainActivity
 * hands the returned payload to the share ingress sheet, which routes it to a
 * host and destination.
 *
 * File URIs are rejected: providers must grant a content URI which can be read
 * without broad storage permissions. Plain text is kept as text rather than
 * being coerced into a file — a URL shared out of a browser is nearly always
 * meant for the shell prompt, and [ShareTextMode] lets the sheet offer both.
 */
object SharedUriIngress {
    data class Payload(
        val uris: List<Uri>,
        val text: String? = null,
        val hasReadGrant: Boolean = false,
    ) {
        val isEmpty: Boolean get() = uris.isEmpty() && text.isNullOrEmpty()
    }

    fun from(intent: Intent): Payload? {
        val streamUris = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(
                IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java),
            )
            Intent.ACTION_SEND_MULTIPLE -> IntentCompat.getParcelableArrayListExtra(
                intent,
                Intent.EXTRA_STREAM,
                Uri::class.java,
            ).orEmpty()
            else -> return null
        }
        val clip = intent.clipData
        val clipUris = clip?.let { data ->
            buildList {
                repeat(data.itemCount) { index ->
                    data.getItemAt(index).uri?.let(::add)
                }
            }
        }.orEmpty()
        val uris = sanitize(streamUris + clipUris)
        // Only look for text once nothing file-shaped arrived: senders routinely
        // attach a caption alongside an image, and that caption is not the share.
        val text = if (uris.isEmpty()) sanitizeText(extractText(intent, clip)) else null
        return Payload(
            uris = uris,
            text = text,
            hasReadGrant = intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0,
        ).takeUnless(Payload::isEmpty)
    }

    /** Keeps a second share from discarding files that have not been routed to a host yet. */
    fun append(existing: Payload?, incoming: Payload): Payload = Payload(
        uris = sanitize(existing?.uris.orEmpty() + incoming.uris),
        // A later text share replaces an earlier one: text has no batch meaning,
        // and silently concatenating two shares would paste a surprise.
        text = incoming.text ?: existing?.text,
        hasReadGrant = incoming.hasReadGrant || existing?.hasReadGrant == true,
    )

    private fun extractText(intent: Intent, clip: android.content.ClipData?): String? {
        intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.let { return it }
        if (clip == null) return null
        repeat(clip.itemCount) { index ->
            clip.getItemAt(index).text?.toString()?.let { return it }
        }
        return null
    }

    /**
     * Control characters in shared text would be executed, not typed, once the
     * payload reaches a PTY. Newlines are the dangerous case — a shared block
     * ending in one submits a command the user never read — so the text arrives
     * as a single line.
     *
     * They become spaces rather than vanishing: deleting the newline out of
     * "cd /srv\napt update" yields "cd /srvapt update", which is worse than
     * either the original or the refusal. Whitespace runs then collapse so the
     * result reads as one line. "Upload as file" is the mode that keeps the
     * exact bytes.
     */
    private fun sanitizeText(value: String?): String? = value
        ?.map { character -> if (character.isISOControl()) ' ' else character }
        ?.joinToString("")
        ?.replace(WHITESPACE_RUN, " ")
        ?.trim()
        ?.take(MAX_SHARED_TEXT)
        ?.takeIf(String::isNotEmpty)

    private fun sanitize(uris: List<Uri>): List<Uri> = uris.asSequence()
        .filter { it.scheme.equals("content", ignoreCase = true) }
        .distinct()
        .toList()

    private const val MAX_SHARED_TEXT = 8 * 1024
    private val WHITESPACE_RUN = Regex("\\s+")
}
