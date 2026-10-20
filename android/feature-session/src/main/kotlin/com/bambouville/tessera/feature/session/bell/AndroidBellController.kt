package com.bambouville.tessera.feature.session.bell

import android.Manifest
import android.app.Activity
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import java.io.Closeable
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Android side-effect boundary for terminal BEL policy, sound, and background delivery. */
class AndroidBellController(
    context: Context,
    private val clock: BellClock = BellClock { android.os.SystemClock.elapsedRealtime() },
    private val notifier: BellNotificationPublisher = AndroidBellNotificationPublisher(context.applicationContext),
    private val soundPlayer: BellSoundPlayer = AndroidBellSoundPlayer(),
) : Closeable {
    private val app = context.applicationContext as Application
    private val lifecycle = BellLifecycleObserver()
    private val limiter = BellRateLimiter(clock)
    val unread = BellUnreadStore()
    private val mutableVisualPulse = MutableStateFlow<BellVisualPulse?>(null)
    val visualPulse: StateFlow<BellVisualPulse?> = mutableVisualPulse.asStateFlow()

    init {
        app.registerActivityLifecycleCallbacks(lifecycle)
    }

    /**
     * Call from [com.bambouville.tessera.terminal.TerminalSurface.onBell]. Returns false when the
     * event was coalesced by the source limiter.
     */
    fun ring(event: BellEvent, preferences: BellPreferences): Boolean {
        if (!limiter.admit(event.source)) return false
        val decision = BellPolicy.decide(event, preferences, lifecycle.visibility)
        if (decision.markSessionUnread) unread.markUnread(event.source)
        if (decision.showVisual) {
            mutableVisualPulse.value = BellVisualPulse(event.source, clock.nowMilliseconds())
        }
        if (decision.playSound) soundPlayer.play()
        if (decision.postBackgroundNotification) notifier.post(event)
        return true
    }

    fun markSessionRead(sessionId: String) = unread.markSessionRead(sessionId)
    fun markTmuxWindowRead(sessionId: String, windowId: Int) = unread.markTmuxWindowRead(sessionId, windowId)

    fun canPostNotifications(): Boolean = notifier.canPost()

    override fun close() {
        app.unregisterActivityLifecycleCallbacks(lifecycle)
        unread.clear()
    }

    private class BellLifecycleObserver : Application.ActivityLifecycleCallbacks {
        // Controllers are constructed from an already-rendering terminal surface, so they begin
        // foreground. A boolean (rather than a resume count) avoids a configuration-change
        // overlap leaving the app permanently marked foreground after the old Activity pauses.
        @Volatile private var foreground = true
        val visibility: BellAppVisibility
            get() = if (foreground) BellAppVisibility.FOREGROUND else BellAppVisibility.BACKGROUND

        override fun onActivityCreated(activity: Activity, savedInstanceState: android.os.Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityResumed(activity: Activity) { foreground = true }
        override fun onActivityPaused(activity: Activity) { foreground = false }
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: android.os.Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
    }

}

fun interface BellSoundPlayer {
    fun play()
}

private class AndroidBellSoundPlayer : BellSoundPlayer {
    override fun play() {
        val tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 40)
        tone.startTone(ToneGenerator.TONE_PROP_BEEP2, 110)
        Handler(Looper.getMainLooper()).postDelayed({ tone.release() }, 180)
    }
}

interface BellNotificationPublisher {
    fun canPost(): Boolean
    fun post(event: BellEvent)
}

private class AndroidBellNotificationPublisher(private val context: Context) : BellNotificationPublisher {
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val nextId = AtomicInteger(72_000)

    init {
        notifications.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Terminal bells", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Background terminal bell alerts"
                setSound(null, null)
                enableVibration(false)
            },
        )
    }

    override fun canPost(): Boolean = notifications.areNotificationsEnabled() &&
        (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)

    override fun post(event: BellEvent) {
        if (!canPost()) return
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = launch?.let {
            PendingIntent.getActivity(context, event.source.hashCode(), it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        val title = event.paneTitle?.takeIf(String::isNotBlank)?.let { "${event.hostDisplayName} · $it" }
            ?: event.hostDisplayName
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle(title)
            .setContentText("rang a bell that needs attention")
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .apply { pendingIntent?.let(::setContentIntent) }
            .build()
        notifications.notify(nextId.getAndIncrement(), notification)
    }

    private companion object {
        // v2 upgrades existing installs from the old shade-only LOW channel to
        // a silent banner-capable channel; Android channel importance is immutable.
        const val CHANNEL_ID = "terminal-bells-v2"
    }
}
