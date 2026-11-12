package com.bambouville.tessera.feature.artifacts.viewers

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.isSpecified
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.core.graphics.createBitmap
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.feature.artifacts.ArtifactFailureException
import com.bambouville.tessera.feature.artifacts.ArtifactMessage
import com.bambouville.tessera.feature.artifacts.R
import com.bambouville.tessera.feature.artifacts.artifactFailureMessage
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.withContext
import kotlin.math.sqrt

/** Renders only the cached file; opening a document never needs a host. */
@Composable
fun ArtifactPdfView(
    file: File,
    displayName: String,
    modifier: Modifier = Modifier,
    reloadToken: Long = 0L,
) {
    val tokens = LocalTesseraTokens.current
    key(file.absolutePath, displayName) {
        val list = rememberLazyListState()
        BoxWithConstraints(modifier.fillMaxSize().background(tokens.bg).imePadding().testTag("artifacts-pdf")) {
            val widthPixels = with(LocalDensity.current) { (maxWidth - 32.dp).roundToPx().coerceAtLeast(1) }
            // Even very short PDF pages must fit in the bounded visible set.
            val minimumPageHeight = (maxHeight / 4f).coerceAtLeast(96.dp)
            // Each generation owns its state, so a cancelled render cannot
            // publish into a reloaded file or a differently sized column.
            val state = remember(reloadToken, widthPixels) { ArtifactPdfState() }
            LaunchedEffect(state) {
                var document: ArtifactPdfDocument? = null
                try {
                    // Assign inside IO: cancellation at dispatcher handoff
                    // must still leave the descriptor reachable by finally.
                    withContext(Dispatchers.IO) { document = ArtifactPdfDocument.open(file) }
                    val ready = checkNotNull(document)
                    state.pageCount = ready.pageCount
                    snapshotFlow {
                        artifactPdfNearbyPages(list.layoutInfo.visibleItemsInfo.map { it.index }, ready.pageCount)
                    }.collectLatest { nearby ->
                        state.pages.keys.filter { it !in nearby }.forEach { index -> state.pages.remove(index)?.retire() }
                        for (index in nearby) {
                            if (index in state.pages) continue
                            var pending: Bitmap? = null
                            try {
                                withContext(Dispatchers.IO) { pending = ready.renderPage(index, widthPixels) }
                                currentCoroutineContext().ensureActive()
                                val bitmap = checkNotNull(pending)
                                state.ratios[index] = bitmap.width.toFloat() / bitmap.height
                                state.pages[index] = ArtifactPdfBitmap(bitmap)
                                pending = null
                            } finally { pending?.recycle() }
                        }
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Exception) {
                    state.failure = artifactFailureMessage(failure, R.string.artifacts_pdf_unreadable)
                } finally {
                    val removed = state.pages.values.toList()
                    state.pages.clear()
                    removed.forEach { it.retire() }
                    withContext(NonCancellable + Dispatchers.IO) { document?.close() }
                }
            }
            when {
                state.failure != null -> ArtifactOpenWith(file, displayName, state.failure)
                state.pageCount == 0 -> Text(
                    stringResource(R.string.artifacts_loading), Modifier.align(Alignment.Center).padding(24.dp),
                    style = TesseraType.bodySmall, color = tokens.fgMuted,
                )
                else -> LazyColumn(
                    Modifier.fillMaxSize().testTag("artifacts-pdf-pages"), state = list,
                    contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    items(count = state.pageCount, key = { it }) { index ->
                        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            val page = state.pages[index]
                            val pageLabel = stringResource(R.string.artifacts_pdf_page, index + 1, state.pageCount)
                            Box(
                                Modifier.fillMaxWidth().heightIn(min = minimumPageHeight)
                                    .aspectRatio(state.ratios[index] ?: (1f / 1.4142f))
                                    .background(androidx.compose.ui.graphics.Color.White),
                                contentAlignment = Alignment.Center,
                            ) {
                                if (page != null) key(state, page) {
                                    ArtifactPdfPage(page, pageLabel, index)
                                } else Text(stringResource(R.string.artifacts_pdf_loading_page, index + 1), style = TesseraType.bodySmall,
                                    color = androidx.compose.ui.graphics.Color.DarkGray)
                            }
                            Text(pageLabel, style = TesseraType.rowMicro, color = tokens.fgDim)
                        }
                    }
                }
            }
        }
    }
}

/**
 * A page's zoom and pan after one pinch step. The page scales about its
 * centre and then moves by [offset], so the point under the fingers stays
 * under them; a step without a centroid zooms about the centre. The page
 * never pulls away from the viewport's edges.
 */
internal fun pinchedPdfPage(
    zoom: Float, offset: Offset, size: IntSize, centroid: Offset, zoomChange: Float, panChange: Offset,
): Pair<Float, Offset> {
    val next = (zoom * zoomChange).coerceIn(1f, 4f)
    val focus = if (centroid.isSpecified) centroid - Offset(size.width / 2f, size.height / 2f) else Offset.Zero
    val moved = focus - (focus - offset) * (next / zoom) + panChange
    val maxX = size.width * (next - 1f) / 2f
    val maxY = size.height * (next - 1f) / 2f
    return next to Offset(moved.x.coerceIn(-maxX, maxX), moved.y.coerceIn(-maxY, maxY))
}

@Composable
private fun ArtifactPdfPage(page: ArtifactPdfBitmap, description: String, index: Int) {
    // LazyColumn can retain a composed row after it leaves the nearby cache.
    // Recycle only once that row has released its image as well.
    DisposableEffect(page) {
        page.acquire()
        onDispose { page.release() }
    }
    val image = remember(page) { page.bitmap.asImageBitmap() }
    var zoom by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    var size by remember { mutableStateOf(IntSize.Zero) }
    val transform = rememberTransformableState { centroid, zoomChange, panChange, _ ->
        val (nextZoom, nextOffset) = pinchedPdfPage(zoom, offset, size, centroid, zoomChange, panChange)
        zoom = nextZoom
        offset = nextOffset
    }
    Box(Modifier.fillMaxSize().clipToBounds().onSizeChanged { size = it }
        .transformable(state = transform, canPan = { zoom > 1f })) {
        Image(
            image, contentDescription = description, contentScale = ContentScale.Fit,
            modifier = Modifier.fillMaxSize().testTag("artifacts-pdf-page-${index + 1}").graphicsLayer {
                scaleX = zoom; scaleY = zoom
                translationX = offset.x; translationY = offset.y
            },
        )
    }
}

private class ArtifactPdfState {
    var pageCount by mutableIntStateOf(0)
    var failure by mutableStateOf<ArtifactMessage?>(null)
    val pages = mutableStateMapOf<Int, ArtifactPdfBitmap>()
    val ratios = mutableStateMapOf<Int, Float>()
}

internal fun artifactPdfNearbyPages(visible: List<Int>, pageCount: Int): List<Int> {
    if (pageCount <= 0) return emptyList()
    val shown = visible.filter { it in 0 until pageCount }.ifEmpty { listOf(0) }
    return (shown + (shown.last() + 1) + (shown.first() - 1))
        .filter { it in 0 until pageCount }.distinct().take(MAX_CACHED_PDF_PAGES)
}

/** Accessed on the composition thread; the bitmap is immutable after rendering. */
internal class ArtifactPdfBitmap(val bitmap: Bitmap) {
    private var users = 0
    private var retired = false
    fun acquire() { check(!retired); users++ }
    fun release() { check(users > 0); users--; recycleIfUnused() }
    fun retire() { retired = true; recycleIfUnused() }
    private fun recycleIfUnused() { if (retired && users == 0 && !bitmap.isRecycled) bitmap.recycle() }
}

/** One IO coroutine owns the renderer, including every opened page and close. */
internal class ArtifactPdfDocument private constructor(
    private val descriptor: ParcelFileDescriptor,
    private val renderer: PdfRenderer,
) : AutoCloseable {
    val pageCount = renderer.pageCount

    fun renderPage(index: Int, columnWidthPixels: Int): Bitmap = renderer.openPage(index).use { page ->
        if (page.width <= 0 || page.height <= 0) throw ArtifactFailureException(ArtifactMessage.Resource(R.string.artifacts_pdf_bad_page_size))
        val scale = minOf(
            columnWidthPixels.coerceAtLeast(1).toDouble() / page.width,
            8192.0 / maxOf(page.width, page.height),
            sqrt(MAX_PDF_PAGE_PIXELS.toDouble() / page.width / page.height),
        )
        val bitmap = createBitmap(
            (page.width * scale).toInt().coerceAtLeast(1),
            (page.height * scale).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888,
        )
        try {
            bitmap.eraseColor(Color.WHITE)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            bitmap
        } catch (failure: Throwable) { bitmap.recycle(); throw failure }
    }

    override fun close() {
        try { renderer.close() } finally { descriptor.close() }
    }

    companion object {
        fun open(file: File): ArtifactPdfDocument {
            val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            var renderer: PdfRenderer? = null
            try {
                renderer = PdfRenderer(descriptor)
                if (renderer.pageCount <= 0) throw ArtifactFailureException(ArtifactMessage.Resource(R.string.artifacts_pdf_no_pages))
                return ArtifactPdfDocument(descriptor, renderer)
            } catch (failure: Throwable) {
                try { renderer?.close() } finally { descriptor.close() }
                throw failure
            }
        }
    }
}

private const val MAX_CACHED_PDF_PAGES = 6
private const val MAX_PDF_PAGE_PIXELS = 2 * 1024 * 1024
