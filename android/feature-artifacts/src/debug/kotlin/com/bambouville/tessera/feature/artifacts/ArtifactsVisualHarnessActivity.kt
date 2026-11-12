package com.bambouville.tessera.feature.artifacts

import android.graphics.Color
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.ui.Modifier
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraTheme

class ArtifactsVisualHarnessActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val darkTheme = intent.getStringExtra("theme") != "light"
        val barStyle = if (darkTheme) SystemBarStyle.dark(Color.TRANSPARENT)
            else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
        enableEdgeToEdge(statusBarStyle = barStyle, navigationBarStyle = barStyle)
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING)
        val scene = ArtifactsHarnessScene.entries.firstOrNull { it.slug == intent.getStringExtra("scene") }
            ?: ArtifactsHarnessScene.Overview
        setContent {
            TesseraTheme(darkTheme = darkTheme) {
                Box(Modifier.fillMaxSize().background(LocalTesseraTokens.current.bg)) {
                    ArtifactsVisualHarness(scene, Modifier.fillMaxSize().safeDrawingPadding())
                }
            }
        }
    }
}
