package com.bambouville.tessera.feature.artifacts

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider

class ArtifactsFixtureActivity : ComponentActivity() {
    class Content : ViewModel() {
        var render by mutableStateOf<(@Composable () -> Unit)?>(null)
        override fun onCleared() { render = null }
    }
    private val content get() = ViewModelProvider(this)[Content::class.java]

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING)
        val owner = content
        setContent { owner.render?.invoke() }
    }

    fun installFixture(render: @Composable () -> Unit) { content.render = render }
}
