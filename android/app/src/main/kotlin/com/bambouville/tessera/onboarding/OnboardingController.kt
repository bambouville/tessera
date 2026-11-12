package com.bambouville.tessera.onboarding

import android.util.Log
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import com.bambouville.tessera.data.AndroidAppPreferences
import com.bambouville.tessera.data.AppPreferences
import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal enum class OnboardingPhase { Inactive, Welcome, WhatsNew, Touring }

/** Holds onboarding state; create it with [rememberOnboardingController] so receipts use the local DataStore. */
class OnboardingController internal constructor(
    private val scope: CoroutineScope,
    private val persistSeen: suspend () -> Unit,
) {
    internal var phase by mutableStateOf(OnboardingPhase.Inactive)
        private set
    internal var stepIndex by mutableIntStateOf(0)
        private set
    internal var preferences by mutableStateOf<AppPreferences?>(null)
        private set
    private var automaticPresentationDecided = false
    private var movesOnly by mutableStateOf(false)

    internal val steps: List<OnboardingStep>
        get() = if (movesOnly) whatsNewSteps(preferences?.agentCenterEnabled == true)
        else onboardingSteps(preferences?.agentCenterEnabled == true)

    internal fun updatePreferences(value: AppPreferences) {
        preferences = value
    }

    internal fun beginIfNeeded(hostCount: Int, blocked: Boolean) {
        val snapshot = preferences ?: return
        if (blocked || hostCount < 0 || automaticPresentationDecided || phase != OnboardingPhase.Inactive) return
        automaticPresentationDecided = true
        phase = when (onboardingPresentation(hostCount, snapshot.hasSeenWelcome, snapshot.lastSeenWhatsNewVersion)) {
            OnboardingPresentation.None -> OnboardingPhase.Inactive
            OnboardingPresentation.Welcome -> OnboardingPhase.Welcome
            OnboardingPresentation.WhatsNew -> OnboardingPhase.WhatsNew
        }
    }

    fun replayWalkthrough() {
        automaticPresentationDecided = true
        movesOnly = false
        stepIndex = 0
        phase = OnboardingPhase.Touring
    }

    fun showWhatsNew() {
        automaticPresentationDecided = true
        phase = OnboardingPhase.WhatsNew
    }

    internal fun showMoves() {
        recordSeen()
        movesOnly = true
        stepIndex = 0
        phase = OnboardingPhase.Touring
    }

    internal fun next() {
        if (phase != OnboardingPhase.Touring) return
        if (stepIndex == steps.lastIndex) finish() else stepIndex += 1
    }

    internal fun back() {
        if (phase == OnboardingPhase.Touring && stepIndex > 0) stepIndex -= 1
    }

    internal fun finish() {
        recordSeen()
        phase = OnboardingPhase.Inactive
    }

    private fun recordSeen() {
        automaticPresentationDecided = true
        // Complete even if navigating away disposes the composition during DataStore's write.
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            withContext(NonCancellable) {
                try {
                    persistSeen()
                } catch (failure: IOException) {
                    // Keep the choice for this session; a failed disk receipt can be offered again next launch.
                    Log.w("TesseraOnboarding", "Could not save onboarding receipt", failure)
                }
            }
        }
    }
}

@Composable
fun rememberOnboardingController(preferences: AndroidAppPreferences): OnboardingController {
    val scope = rememberCoroutineScope()
    val controller = remember(preferences, scope) {
        OnboardingController(scope) { preferences.updateOnboardingSeen(WHATS_NEW_VERSION) }
    }
    // No default snapshot: a slow DataStore read must never flash the new-install welcome to an updater.
    LaunchedEffect(preferences, controller) {
        preferences.values.collect { controller.updatePreferences(it) }
    }
    return controller
}
