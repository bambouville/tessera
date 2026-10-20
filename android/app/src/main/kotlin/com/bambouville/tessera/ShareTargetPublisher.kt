package com.bambouville.tessera

import android.content.Context
import android.content.Intent
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.bambouville.tessera.data.SavedHost

/**
 * Publishes one direct-share target per host, so the Android share sheet can
 * offer "Tessera · web-01" and route the payload without the user hunting for
 * the host inside the app afterwards.
 *
 * This is the Android counterpart of the iOS share extension's host list: iOS
 * shows its own picker inside the sheet, Android puts the same choices in the
 * sheet's own direct-share row. The ingress sheet still opens afterwards — a
 * shortcut preselects a host, it does not skip the destination decision.
 */
object ShareTargetPublisher {
    /** Must match `res/xml/shortcuts.xml`. */
    const val SHARE_CATEGORY = "com.bambouville.tessera.category.SHARE_TARGET"
    private const val ID_PREFIX = "share-host-"

    /** The host a share-sheet shortcut named, if this intent came from one. */
    fun selectedHostId(intent: Intent): String? = intent
        .getStringExtra(ShortcutManagerCompat.EXTRA_SHORTCUT_ID)
        ?.takeIf { it.startsWith(ID_PREFIX) }
        ?.removePrefix(ID_PREFIX)
        ?.takeIf(String::isNotEmpty)

    fun reportUsed(context: Context, hostId: String) {
        runCatching { ShortcutManagerCompat.reportShortcutUsed(context, ID_PREFIX + hostId) }
    }

    /**
     * Replaces the published set.
     *
     * [appLockEnabled] withdraws every target: a user who put their host list
     * behind biometrics did not agree to publish those names to the system
     * share sheet, where they render without any unlock. The ingress sheet
     * still routes shares for them — it just runs behind the lock screen.
     */
    fun publish(
        context: Context,
        hosts: List<SavedHost>,
        connectedHostIds: Set<String>,
        appLockEnabled: Boolean,
    ) {
        val appContext = context.applicationContext
        if (appLockEnabled || hosts.isEmpty()) {
            runCatching { ShortcutManagerCompat.removeAllDynamicShortcuts(appContext) }
            return
        }
        val limit = runCatching { ShortcutManagerCompat.getMaxShortcutCountPerActivity(appContext) }
            .getOrDefault(DEFAULT_LIMIT)
            .coerceAtLeast(1)
        val ordered = hosts
            .sortedWith(
                compareByDescending<SavedHost> { it.id in connectedHostIds }
                    .thenBy(String.CASE_INSENSITIVE_ORDER) { it.displayName.ifBlank { it.hostname } },
            )
            .take(limit)

        val icon = IconCompat.createWithResource(appContext, R.mipmap.ic_launcher)
        val shortcuts = ordered.mapIndexed { index, host ->
            val label = host.displayName.ifBlank { host.hostname }
            ShortcutInfoCompat.Builder(appContext, ID_PREFIX + host.id)
                .setShortLabel(label)
                .setLongLabel("${host.username}@${host.hostname}")
                .setIcon(icon)
                .setRank(index)
                // Long-lived so the sheet may keep ranking a target the user
                // shares to often even after the set is republished.
                .setLongLived(true)
                .setCategories(setOf(SHARE_CATEGORY))
                .setIntent(
                    Intent(appContext, MainActivity::class.java).setAction(Intent.ACTION_MAIN),
                )
                .build()
        }
        runCatching { ShortcutManagerCompat.setDynamicShortcuts(appContext, shortcuts) }
    }

    private const val DEFAULT_LIMIT = 5
}
