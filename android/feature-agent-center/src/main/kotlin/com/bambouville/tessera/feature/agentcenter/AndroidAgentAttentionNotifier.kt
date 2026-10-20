package com.bambouville.tessera.feature.agentcenter

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import com.bambouville.tessera.data.AndroidAgentMetadataRepository
import java.util.UUID

/**
 * Android delivery adapter for shared attention snapshots. It deliberately uses
 * content-free copy by default: the OS never receives a transcript preview,
 * action label, provider/session identity, locator, or response macro.
 */
class AndroidAgentAttentionNotifier(
    private val context: Context,
    private val metadata: AndroidAgentMetadataRepository,
    private val notificationsEnabled: () -> Boolean = { false },
) {
    private val deliveredThreadKeys = linkedSetOf<String>()
    suspend fun publish(detail: AgentThreadDetail) {
        if (!deliveryAllowed(notificationsEnabled(), detail.row.attention)) return
        // `deliveryGeneration` changes for each shared thread update and is
        // not an endpoint identity. The opaque route must instead carry the
        // exact currently-live SSH carrier generation checked at activation.
        val generation = detail.liveCarrierGenerationOrNull() ?: return
        val token = UUID.randomUUID().toString().replace("-", "")
        val route = AgentNotificationRoute(token, generation)
        metadata.issueRoute(token, detail.row.key, generation, System.currentTimeMillis() + ROUTE_LIFETIME_MILLIS)
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.agent_notification_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = context.getString(R.string.agent_notification_channel_description)
            },
        )
        val review = PendingIntent.getActivity(
            context,
            token.hashCode(),
            AgentNotificationContract.intent(context, route),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val prearmedReview = PendingIntent.getActivity(
            context,
            token.hashCode() xor 0x5a5a,
            AgentNotificationContract.intent(context, route, prearmedAnswer = true),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = context.getString(
            if (detail.row.attention == "needsYou") {
                R.string.agent_notification_needs_input
            } else {
                R.string.agent_notification_finished
            },
        )
        // Localized, and still content-free: the resource is fixed copy.
        val body = context.getString(R.string.agent_notification_body)
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(review)
            // This opens the app with a review hint only. It never sends a response.
            .addAction(
                Notification.Action.Builder(null, context.getString(R.string.agent_notification_review), prearmedReview)
                    .build(),
            )
            .setAutoCancel(true)
            // A refresh of a notification still showing (a new route token,
            // or needs-input turning into finished) updates it silently.
            .setOnlyAlertOnce(true)
            .build()
        manager.notify("agent:${detail.row.key}".hashCode(), notification)
        synchronized(deliveredThreadKeys) { deliveredThreadKeys += detail.row.key }
    }

    fun withdraw(threadKey: String) {
        context.getSystemService(NotificationManager::class.java)
            .cancel("agent:$threadKey".hashCode())
        synchronized(deliveredThreadKeys) { deliveredThreadKeys -= threadKey }
    }

    fun withdrawAll() {
        val keys = synchronized(deliveredThreadKeys) { deliveredThreadKeys.toList().also { deliveredThreadKeys.clear() } }
        val manager = context.getSystemService(NotificationManager::class.java)
        keys.forEach { manager.cancel("agent:$it".hashCode()) }
    }

    companion object {
        const val CHANNEL_ID = "agent_attention"
        /** English source of `R.string.agent_notification_body`. */
        const val CONTENT_FREE_BODY = "Open Tessera to review."

        internal fun deliveryAllowed(optedIn: Boolean, attention: String): Boolean =
            optedIn && attention in ATTENTION_KINDS
        private const val ROUTE_LIFETIME_MILLIS = 24L * 60L * 60L * 1_000L
        private val ATTENTION_KINDS = setOf("needsYou", "unreadCompletion")
    }
}
