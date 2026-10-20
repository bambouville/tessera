package com.bambouville.tessera.feature.pairing

import android.Manifest
import android.content.pm.PackageManager
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
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
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Offline bundled ML Kit scanner. The manual QR-text field remains available on denial/failure. */
@Composable
internal fun PairingQrScanner(
    onScanned: (String) -> Unit,
    onFailure: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        granted = it
        if (!it) onFailure("Camera access was denied. Paste the pairing code instead.")
    }
    LaunchedEffect(Unit) { if (!granted) permission.launch(Manifest.permission.CAMERA) }
    if (!granted) return
    // Show the whole analyzed frame; filling a wide preview can hide the QR's
    // finder patterns even though they remain inside the camera sensor image.
    val view = remember { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FIT_CENTER } }
    val executor = remember { Executors.newSingleThreadExecutor() }
    val consumed = remember { AtomicBoolean(false) }
    val scanner = remember {
        BarcodeScanning.getClient(BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build())
    }
    DisposableEffect(owner, granted) {
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
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
                    useCase.setAnalyzer(executor) { image ->
                        val media = image.mediaImage()
                        if (media == null || consumed.get()) { image.close(); return@setAnalyzer }
                        runCatching {
                            scanner.process(InputImage.fromMediaImage(media, image.imageInfo.rotationDegrees))
                                .addOnSuccessListener { values ->
                                    values.firstOrNull { it.rawValue?.startsWith("tessera://pair/v1?offer=") == true }?.rawValue?.let {
                                        if (consumed.compareAndSet(false, true)) onScanned(it)
                                    }
                                }
                                .addOnFailureListener {
                                    if (consumed.compareAndSet(false, true)) {
                                        onFailure("The camera scanner failed. Paste the pairing code instead.")
                                    }
                                }
                                .addOnCompleteListener { image.close() }
                        }.onFailure {
                            image.close()
                            if (consumed.compareAndSet(false, true)) {
                                onFailure("The camera scanner failed. Paste the pairing code instead.")
                            }
                        }
                    }
                }
                provider.unbindAll()
                provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            }.onFailure { onFailure("The camera scanner is unavailable. Paste the pairing code instead.") }
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            providerFuture.addListener(
                { runCatching { providerFuture.get().unbindAll() } },
                ContextCompat.getMainExecutor(context),
            )
            scanner.close()
            executor.shutdownNow()
        }
    }
    AndroidView(factory = { view }, modifier = modifier)
}

@androidx.annotation.OptIn(markerClass = [ExperimentalGetImage::class])
private fun ImageProxy.mediaImage() = image
