package com.bambouville.tessera

import android.app.ActivityManager
import android.app.Application
import android.content.ComponentCallbacks2
import android.content.res.Configuration
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.bambouville.tessera.agent.platform.AndroidAgentSessionCoordinator
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationCoordinator
import com.bambouville.tessera.agent.platform.LiveAgentSessionRegistry
import com.bambouville.tessera.core.bridge.SharedAgentMarkdown
import com.bambouville.tessera.data.AndroidAgentCenterViewPreferences
import com.bambouville.tessera.data.AndroidAgentMetadataRepository
import com.bambouville.tessera.data.AndroidAppPreferences
import com.bambouville.tessera.feature.agentcenter.AgentCenterPresenter
import com.bambouville.tessera.feature.agentcenter.AgentDeviceMemory
import com.bambouville.tessera.feature.agentcenter.AgentNotificationIntent
import com.bambouville.tessera.feature.agentcenter.AgentNotificationContract
import com.bambouville.tessera.feature.agentcenter.AndroidAgentAttentionNotifier
import com.bambouville.tessera.feature.agentcenter.OnDeviceAgentTitleGenerator
import com.bambouville.tessera.lifecycle.DiagnosticLogStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/** App-level owner: it survives configuration changes, but process death loses live routes. */
class AgentSessionViewModel(application: Application) : AndroidViewModel(application) {
    private val metadata = AndroidAgentMetadataRepository(application)
    private val preferences = AndroidAppPreferences(application)
    private val agentNotificationsEnabled = MutableStateFlow(false)
    val sessions = LiveAgentSessionRegistry()
    val coordinator = AndroidAgentSessionCoordinator(sessions)
    val integration = AgentSessionIntegrationCoordinator(
        coordinator.directory,
        viewModelScope,
        coordinator,
    )
    val presenter = AgentCenterPresenter(
        coordinator = coordinator,
        metadata = metadata,
        viewPreferences = AndroidAgentCenterViewPreferences(application),
        scope = viewModelScope,
        sessionIntegration = integration,
        attentionNotifier = AndroidAgentAttentionNotifier(application, metadata) { agentNotificationsEnabled.value },
        diagnostics = DiagnosticLogStore(application)::record,
        // Nothing is downloaded and nothing leaves the device: it is used only
        // where the model is already present, and every other case falls
        // through to shared Core clipped opening prompt.
        titleGenerator = OnDeviceAgentTitleGenerator(application),
        deviceMemory = application.getSystemService(ActivityManager::class.java)?.let { manager ->
            val info = ActivityManager.MemoryInfo().also(manager::getMemoryInfo)
            AgentDeviceMemory(info.totalMem, manager.isLowRamDevice)
        },
    )
    private val mutableNotificationTarget = MutableStateFlow<NotificationTarget?>(null)
    val notificationTarget = mutableNotificationTarget.asStateFlow()
    private val memoryCallbacks = object : ComponentCallbacks2 {
        override fun onTrimMemory(level: Int) = presenter.trimMemory(level)
        override fun onConfigurationChanged(newConfig: Configuration) = Unit
        @Deprecated("Deprecated in Java")
        override fun onLowMemory() = presenter.trimMemory(ComponentCallbacks2.TRIM_MEMORY_COMPLETE)
    }

    init {
        application.getSystemService(ActivityManager::class.java)?.let { SharedAgentMarkdown.configureCache(it.memoryClass) }
        application.registerComponentCallbacks(memoryCallbacks)
        viewModelScope.launch {
            preferences.values.collect { agentNotificationsEnabled.value = it.agentCenterNotificationsEnabled }
        }
        // Attention discovery is app/session scoped. Opening the Agents tab
        // controls presentation demand, not whether live lifecycle events exist.
        presenter.activate()
    }

    /**
     * Resolves only metadata. A pre-armed notification opens review UI; it can
     * never send input after process death or without a fresh Core action plan.
     */
    fun handleNotification(notification: AgentNotificationIntent) {
        viewModelScope.launch {
            AgentNotificationContract.resolveForeground(metadata, coordinator.directory, notification.route, System.currentTimeMillis())
                ?.let { threadKey ->
                    mutableNotificationTarget.value = NotificationTarget(threadKey, notification.prearmedAnswer)
                }
        }
    }

    fun consumeNotificationTarget() { mutableNotificationTarget.value = null }

    override fun onCleared() {
        getApplication<Application>().unregisterComponentCallbacks(memoryCallbacks)
        presenter.close()
        integration.close()
        coordinator.close()
    }

    data class NotificationTarget(val threadKey: String, val prearmedAnswer: Boolean)
}
