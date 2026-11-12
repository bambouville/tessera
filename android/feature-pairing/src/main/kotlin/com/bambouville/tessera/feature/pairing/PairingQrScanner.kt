package com.bambouville.tessera.feature.pairing

import android.Manifest
import android.content.pm.PackageManager
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.bambouville.tessera.design.DisplayText
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** On-device camera scanner (see [PairingQrDecoder]). The manual QR-text field remains available on denial/failure. */
@Composable
internal fun PairingQrScanner(
    onScanned: (String) -> Unit,
    onFailure: (DisplayText) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        granted = it
        if (!it) onFailure(DisplayText.Resource(R.string.pairing_camera_denied))
    }
    LaunchedEffect(Unit) { if (!granted) permission.launch(Manifest.permission.CAMERA) }
    if (!granted) return
    // Show the whole analyzed frame; filling a wide preview can hide the QR's
    // finder patterns even though they remain inside the camera sensor image.
    val view = remember { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FIT_CENTER } }
    val consumed = remember { AtomicBoolean(false) }
    DisposableEffect(owner, granted) {
        // Cleared on dispose. Results reach the caller on the main thread, as
        // dispose does, so a frame still decoding when the scanner is closed
        // can never report afterwards.
        val live = AtomicBoolean(true)
        // Each binding owns its analyzer thread: a re-run must not inherit one
        // that dispose already shut down.
        val executor = Executors.newSingleThreadExecutor()
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            if (!live.get()) return@addListener
            runCatching {
                val provider = providerFuture.get()
                val preview = androidx.camera.core.Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                // Pairing offers are denser than ordinary URL codes. CameraX's
                // 640x480 default loses small modules after YUV downsampling.
                val analysis = ImageAnalysis.Builder()
                    .setResolutionSelector(ResolutionSelector.Builder().setResolutionStrategy(
                        ResolutionStrategy(Size(1280, 960), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)
                    ).build())
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build().also { useCase ->
                    // Made on the analyzer thread, its only user, so a native
                    // load failure reports below instead of crashing.
                    val decoder = lazy(LazyThreadSafetyMode.NONE) { PairingQrDecoder() }
                    val main = ContextCompat.getMainExecutor(context)
                    useCase.setAnalyzer(executor) { image ->
                        if (!live.get() || consumed.get()) { image.close(); return@setAnalyzer }
                        val decoded = runCatching { decoder.value.decode(image) }
                        image.close()
                        decoded.onSuccess { offer ->
                            if (offer != null && live.get() && consumed.compareAndSet(false, true)) {
                                main.execute { if (live.get()) onScanned(offer) }
                            }
                        }.onFailure {
                            if (live.get() && consumed.compareAndSet(false, true)) {
                                main.execute { if (live.get()) onFailure(DisplayText.Resource(R.string.pairing_camera_failed)) }
                            }
                        }
                    }
                }
                provider.unbindAll()
                provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            }.onFailure { if (live.get()) onFailure(DisplayText.Resource(R.string.pairing_camera_unavailable)) }
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            live.set(false)
            providerFuture.addListener(
                { runCatching { providerFuture.get().unbindAll() } },
                ContextCompat.getMainExecutor(context),
            )
            // Not shutdownNow: a frame CameraX already queued would be dropped
            // unclosed, and the camera's reader waits for every frame back.
            // Queued frames still run, see `live` cleared, and close at once.
            executor.shutdown()
        }
    }
    AndroidView(factory = { view }, modifier = modifier)
}
