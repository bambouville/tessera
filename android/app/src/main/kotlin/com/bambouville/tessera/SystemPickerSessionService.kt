package com.bambouville.tessera

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat
import com.bambouville.tessera.data.AndroidSessionRestoreRepository
import com.bambouville.tessera.data.continuity.AndroidForegroundRestoreStore
import com.bambouville.tessera.data.continuity.SessionRestoreTaskRemoval
import com.bambouville.tessera.feature.session.LiveSessionStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking

/** Keeps active terminal transports alive across lock/background and system picker handoffs. */
class SystemPickerSessionService : Service() {
    override fun onCreate() {
        super.onCreate()
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.system_picker_session_channel),
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
        startForegroundNotification(activeSessionCount)
    }

    private fun startForegroundNotification(sessionCount: Int) {
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(if (sessionCount > 0) "Tessera terminal active" else getString(R.string.system_picker_session_title))
            .setContentText(
                if (sessionCount > 0) "$sessionCount session${if (sessionCount == 1) "" else "s"} kept connected"
                else getString(R.string.system_picker_session_body),
            )
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // The companion's state, not the start's: a stop may have followed
        // this start before it arrived, and its count would undo the stop.
        startForegroundNotification(activeSessionCount)
        if (pendingStarts > 0) pendingStarts--
        if (!pickerActive && activeSessionCount == 0) {
            // [update] leaves a stop that overtook a start to the service:
            // having called startForeground(), it may now stop.
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Removing the task is the one gesture that means "end them", and since
        // the controllers stopped dying with the Activity it is the only one
        // left that can say so from here. This used to be a comment explaining
        // that composition disposal had already done it.
        LiveSessionStore.get().closeAll()
        pickerActive = false
        activeSessionCount = 0
        // Removing the task is an explicit request to end this app instance,
        // unlike ordinary backgrounding/lock. Retire both restore stores before
        // the service disappears so a cached process or later cold launch cannot
        // resurrect dead transports as "reconnect" rows.
        runBlocking(Dispatchers.IO) {
            val documents = AndroidForegroundRestoreStore(applicationContext)
            SessionRestoreTaskRemoval.apply(
                policy = documents.restorePolicy.first(),
                records = AndroidSessionRestoreRepository(applicationContext),
                documents = documents,
            )
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val TAG = "TesseraSessionSvc"
        private const val CHANNEL_ID = "system-picker-session"
        private const val NOTIFICATION_ID = 2_001
        @Volatile private var pickerActive = false
        @Volatile private var activeSessionCount = 0
        /**
         * Foreground starts not yet delivered to [onStartCommand]. Main
         * thread only, like [update] and the service's callbacks.
         */
        @Volatile internal var pendingStarts = 0
            private set

        fun setActive(context: Context, active: Boolean) {
            pickerActive = active
            update(context)
        }

        fun setSessionsActive(context: Context, count: Int) {
            activeSessionCount = count.coerceAtLeast(0)
            update(context)
        }

        private fun update(context: Context) {
            val intent = Intent(context, SystemPickerSessionService::class.java)
            if (pickerActive || activeSessionCount > 0) {
                // A session can change state (schedule a reconnect, drop, come
                // back) while Tessera is backgrounded or locked. Android 12+
                // forbids starting a foreground service from the background and
                // throws ForegroundServiceStartNotAllowedException — an
                // IllegalStateException subclass — which would crash the whole
                // app for a keep-alive that is only best-effort anyway. The
                // start is retried the next time this runs in the foreground,
                // because the session-state effect that calls it re-fires then.
                try {
                    ContextCompat.startForegroundService(context, intent)
                    pendingStarts++
                } catch (denied: IllegalStateException) {
                    Log.w(TAG, "keep-alive service not startable from background", denied)
                }
            } else if (pendingStarts == 0) {
                context.stopService(intent)
            } else {
                // A start is still on its way, and stopService() before the
                // service calls startForeground() crashes the app with
                // ForegroundServiceDidNotStartInTimeException: a session that
                // connects and closes while the main thread is busy (restore
                // at launch, then the Activity going away) did exactly that.
                // The service stops itself once started; see onStartCommand.
            }
        }
    }
}
