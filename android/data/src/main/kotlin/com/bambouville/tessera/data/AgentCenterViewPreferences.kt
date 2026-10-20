package com.bambouville.tessera.data

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.agentCenterViewPreferences by preferencesDataStore(name = "agent_center_view")

/** View-only choices. Selection, transcripts, prompts, and routes never enter DataStore. */
data class AgentCenterViewPreferences(
    val grouping: String = "attention",
    val showSystemEvents: Boolean = false,
    val compactTab: String = "live",
)

class AndroidAgentCenterViewPreferences(private val context: Context) {
    val values: Flow<AgentCenterViewPreferences> = context.agentCenterViewPreferences.data.map { value ->
        AgentCenterViewPreferences(
            grouping = value[Grouping]?.takeIf { it in GROUPINGS } ?: "attention",
            showSystemEvents = value[ShowSystemEvents] ?: false,
            compactTab = value[CompactTab]?.takeIf { it in TABS } ?: "live",
        )
    }

    suspend fun setGrouping(value: String) {
        require(value in GROUPINGS)
        context.agentCenterViewPreferences.edit { it[Grouping] = value }
    }

    suspend fun setShowSystemEvents(value: Boolean) {
        context.agentCenterViewPreferences.edit { it[ShowSystemEvents] = value }
    }

    suspend fun setCompactTab(value: String) {
        require(value in TABS)
        context.agentCenterViewPreferences.edit { it[CompactTab] = value }
    }

    private companion object {
        val Grouping = stringPreferencesKey("grouping")
        val ShowSystemEvents = booleanPreferencesKey("show_system_events")
        val CompactTab = stringPreferencesKey("compact_tab")
        // Match the shared AgentListGrouping ABI exactly. Provider is a
        // capability/filter concern, not a presentation grouping. A stored
        // retired "project" grouping reads back as attention.
        val GROUPINGS = setOf("attention", "host")
        val TABS = setOf("live", "activity", "changes")
    }
}
