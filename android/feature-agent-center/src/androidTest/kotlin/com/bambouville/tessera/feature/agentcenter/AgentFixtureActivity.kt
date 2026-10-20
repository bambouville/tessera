package com.bambouville.tessera.feature.agentcenter

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider

/** Test-only owner: reinstall the same fixture content after configuration
 * recreation, just as an app activity installs its UI from onCreate. No static
 * callbacks, network authority, or provider data survive activity finalization.
 */
class AgentFixtureActivity : ComponentActivity() {
    class Content : ViewModel() {
        var render by mutableStateOf<(@Composable () -> Unit)?>(null)
        override fun onCleared() { render = null }
    }
    private val content get() = ViewModelProvider(this)[Content::class.java]
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Match MainActivity on every creation, including configuration
        // changes. Compose owns both safe-area and keyboard insets.
        enableEdgeToEdge()
        window.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING)
        val owner = content
        setContent { owner.render?.invoke() }
    }
    fun installFixture(render: @Composable () -> Unit) { content.render = render }
}
