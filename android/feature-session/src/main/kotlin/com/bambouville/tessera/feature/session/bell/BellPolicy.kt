package com.bambouville.tessera.feature.session.bell

import com.bambouville.tessera.data.AppPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Identifies the terminal location that emitted BEL without exposing terminal contents. */
sealed interface BellSource {
    val sessionId: String

    data class Session(override val sessionId: String) : BellSource
    data class TmuxWindow(override val sessionId: String, val windowId: Int) : BellSource
}

data class BellEvent(
    val source: BellSource,
    val originOnScreen: Boolean,
    val hostDisplayName: String,
    val paneTitle: String? = null,
)

data class BellPreferences(
    val soundEnabled: Boolean,
    val visualEnabled: Boolean,
    val notificationEnabled: Boolean,
)

fun AppPreferences.toBellPreferences(): BellPreferences = BellPreferences(
    soundEnabled = bellSoundEnabled,
    visualEnabled = bellVisualEnabled,
    notificationEnabled = bellNotificationEnabled,
)

enum class BellAppVisibility { FOREGROUND, BACKGROUND }

data class BellDecision(
    val playSound: Boolean,
    val showVisual: Boolean,
    val postBackgroundNotification: Boolean,
    val markSessionUnread: Boolean,
)

/**
 * Platform-independent bell policy. Android notifications stay silent: audible feedback is
 * controlled here so channel defaults cannot override the user's bell-sound preference.
 */
object BellPolicy {
    fun decide(
        event: BellEvent,
        preferences: BellPreferences,
        appVisibility: BellAppVisibility,
    ): BellDecision {
        val foreground = appVisibility == BellAppVisibility.FOREGROUND
        val offScreen = !event.originOnScreen
        return BellDecision(
            playSound = preferences.soundEnabled && (offScreen || !foreground),
            showVisual = preferences.visualEnabled && foreground && offScreen,
            postBackgroundNotification = preferences.notificationEnabled && !foreground,
            // A session that was visible before backgrounding still needs a dot when the
            // user returns: it could have rung while no terminal was actually observable.
            markSessionUnread = offScreen || !foreground,
        )
    }
}

fun interface BellClock {
    fun nowMilliseconds(): Long
}

/** Per-source two-second limiter, matching the portable iOS bell contract. */
class BellRateLimiter(
    private val clock: BellClock,
    private val minimumIntervalMilliseconds: Long = 2_000,
) {
    private val lastAdmitAt = mutableMapOf<String, Long>()

    @Synchronized
    fun admit(source: BellSource): Boolean {
        val key = source.rateLimitKey()
        val now = clock.nowMilliseconds()
        val previous = lastAdmitAt[key]
        if (previous != null && now - previous < minimumIntervalMilliseconds) return false
        lastAdmitAt[key] = now
        return true
    }
}

private fun BellSource.rateLimitKey(): String = when (this) {
    is BellSource.Session -> "session:$sessionId"
    is BellSource.TmuxWindow -> "tmux:$sessionId:$windowId"
}

data class BellUnreadState(
    val sessionLevelIds: Set<String> = emptySet(),
    val tmuxWindowIdsBySession: Map<String, Set<Int>> = emptyMap(),
    val latestSourceBySession: Map<String, BellSource> = emptyMap(),
) {
    val sessionIds: Set<String>
        get() = sessionLevelIds + tmuxWindowIdsBySession.filterValues { it.isNotEmpty() }.keys

    fun isUnread(sessionId: String): Boolean = sessionId in sessionIds
    fun isWindowUnread(sessionId: String, windowId: Int): Boolean =
        windowId in tmuxWindowIdsBySession[sessionId].orEmpty()
}

data class BellVisualPulse(val source: BellSource, val emittedAtMilliseconds: Long)

/**
 * In-memory unread state for session/sidebar indicators. It deliberately contains no terminal
 * content and is cleared when the owning session becomes visible.
 */
class BellUnreadStore {
    private val mutableState = MutableStateFlow(BellUnreadState())
    val state: StateFlow<BellUnreadState> = mutableState.asStateFlow()

    fun markUnread(source: BellSource) {
        mutableState.value = mutableState.value.let { current ->
            current.copy(
                sessionLevelIds = if (source is BellSource.Session) {
                    current.sessionLevelIds + source.sessionId
                } else current.sessionLevelIds,
                tmuxWindowIdsBySession = if (source is BellSource.TmuxWindow) {
                    current.tmuxWindowIdsBySession + (
                        source.sessionId to (current.tmuxWindowIdsBySession[source.sessionId].orEmpty() + source.windowId)
                    )
                } else current.tmuxWindowIdsBySession,
                latestSourceBySession = current.latestSourceBySession + (source.sessionId to source),
            )
        }
    }

    fun markSessionRead(sessionId: String) {
        mutableState.value = mutableState.value.let { current ->
            current.copy(
                sessionLevelIds = current.sessionLevelIds - sessionId,
                latestSourceBySession = if (current.latestSourceBySession[sessionId] is BellSource.Session) {
                    current.latestSourceBySession - sessionId
                } else current.latestSourceBySession,
            )
        }
    }

    fun markTmuxWindowRead(sessionId: String, windowId: Int) {
        mutableState.value = mutableState.value.let { current ->
            val remaining = current.tmuxWindowIdsBySession[sessionId].orEmpty() - windowId
            val windowMap = if (remaining.isEmpty()) current.tmuxWindowIdsBySession - sessionId
            else current.tmuxWindowIdsBySession + (sessionId to remaining)
            val latest = current.latestSourceBySession[sessionId]
            current.copy(
                tmuxWindowIdsBySession = windowMap,
                latestSourceBySession = if (
                    latest is BellSource.TmuxWindow && latest.windowId == windowId
                ) current.latestSourceBySession - sessionId else current.latestSourceBySession,
            )
        }
    }

    fun clear() {
        mutableState.value = BellUnreadState()
    }
}
