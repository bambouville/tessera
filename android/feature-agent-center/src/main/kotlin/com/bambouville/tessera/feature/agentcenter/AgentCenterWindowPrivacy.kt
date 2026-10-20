package com.bambouville.tessera.feature.agentcenter

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.Window
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalContext
import java.util.WeakHashMap

/** Protects both saved Recents snapshots and the compositor's live task image.
 * When enabled, foreground screenshots/screen sharing are unavailable on this surface.
 * Dialogs inherit the secure window policy.
 */
@Composable
fun AgentCenterWindowPrivacy(enabled: Boolean = true) {
    val window = LocalContext.current.agentActivity()?.window
    DisposableEffect(window, enabled) {
        if (enabled) window?.let(AgentSecureWindows::acquire)
        onDispose { if (enabled) window?.let(AgentSecureWindows::release) }
    }
}

private tailrec fun Context.agentActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.takeUnless { it === this }?.agentActivity()
    else -> null
}

private object AgentSecureWindows {
    private data class Lease(var owners: Int, val originallySecure: Boolean)
    private val leases = WeakHashMap<Window, Lease>()
    fun acquire(window: Window) {
        val lease = leases.getOrPut(window) {
            Lease(0, window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
        }
        lease.owners++
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
    fun release(window: Window) {
        val lease = leases[window] ?: return
        if (--lease.owners != 0) return
        if (!lease.originallySecure) window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        leases.remove(window)
    }
}
