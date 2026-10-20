package com.bambouville.tessera.terminal

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.Drawable
import androidx.annotation.WorkerThread
import androidx.core.graphics.drawable.toDrawable
import androidx.core.graphics.scale
import androidx.core.graphics.withClip
import java.io.File
import java.nio.ByteBuffer
import java.util.UUID
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** How a terminal background picture is placed in its canvas. */
enum class TerminalBackgroundFillMode(val persistedValue: String) {
    /** Aspect-fill crop (the iOS default). */
    Fill("fill"),
    /** Aspect-fit with the terminal theme color left visible as letterboxing. */
    Fit("fit"),
    ;

    companion object {
        fun fromPersisted(value: String?): TerminalBackgroundFillMode =
            entries.firstOrNull { it.persistedValue == value } ?: Fill
    }
}

/**
 * Resolved picture settings for any [TerminalSurface]. A null value at the call site means the
 * classic solid terminal-theme background. The values deliberately mirror the iOS contract so
 * the same persisted setting has the same visual meaning on both platforms.
 */
data class TerminalBackgroundImage(
    val imageId: String,
    /** Theme-color scrim opacity. Zero leaves the image unmodified. */
    val dim: Float = DEFAULT_DIM,
    val fillMode: TerminalBackgroundFillMode = TerminalBackgroundFillMode.Fill,
    /** Gaussian-like blur radius in density-independent pixels. */
    val blurRadiusDp: Float = 0f,
) {
    init {
        require(imageId.matches(IMAGE_ID_PATTERN)) { "terminal background image ID is invalid" }
        require(dim in DIM_RANGE) { "terminal background dim must be within $DIM_RANGE" }
        require(blurRadiusDp in BLUR_RADIUS_DP_RANGE) {
            "terminal background blur must be within $BLUR_RADIUS_DP_RANGE"
        }
    }

    companion object {
        const val DEFAULT_DIM = 0.5f
        val DIM_RANGE = 0f..0.85f
        val BLUR_RADIUS_DP_RANGE = 0f..24f
        private val IMAGE_ID_PATTERN = Regex("[0-9a-fA-F-]{36}\\.jpg")
    }
}

/** Metadata returned after a source image becomes an app-owned terminal background file. */
data class ImportedTerminalBackgroundImage(
    val imageId: String,
    val pixelWidth: Int,
    val pixelHeight: Int,
    val byteCount: Long,
)

/**
 * Owns app-private terminal background images in files/TerminalBackgrounds.
 *
 * Imports are downsampled, orientation-normalized by [ImageDecoder], and JPEG-reencoded. The
 * original picker URI is never retained, so later terminal rendering never needs Photo/SAF access.
 * Blur variants are derived and cached under the base image's UUID; callers should call this from a
 * worker dispatcher when an image is first selected or prewarmed.
 */
class TerminalBackgroundImageStore(context: Context) {
    private val appContext = context.applicationContext
    private val directory = File(appContext.filesDir, DIRECTORY_NAME)

    @WorkerThread
    fun importImage(data: ByteArray): ImportedTerminalBackgroundImage? {
        if (data.isEmpty()) return null
        val decoded = decodeImportedBitmap(data) ?: return null
        val id = "${UUID.randomUUID()}.jpg"
        val destination = imageFile(id)
        val temporary = File(directory, ".$id.tmp")
        var keepDecoded = false
        return try {
            if (!directory.exists() && !directory.mkdirs()) return null
            temporary.outputStream().use { output ->
                if (!decoded.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, output)) return null
            }
            if (!temporary.renameTo(destination)) return null
            cachePut(id, decoded)
            keepDecoded = true
            ImportedTerminalBackgroundImage(
                imageId = id,
                pixelWidth = decoded.width,
                pixelHeight = decoded.height,
                byteCount = destination.length(),
            )
        } catch (_: Exception) {
            temporary.delete()
            null
        } finally {
            if (!keepDecoded && !decoded.isRecycled) decoded.recycle()
        }
    }

    /** A decoded base image, or null if the persisted file was removed or corrupt. */
    @WorkerThread
    fun image(imageId: String, blurRadiusDp: Float = 0f): Bitmap? {
        if (!isValidImageId(imageId) || blurRadiusDp !in TerminalBackgroundImage.BLUR_RADIUS_DP_RANGE) {
            return null
        }
        val blurKey = blurKey(imageId, blurRadiusDp)
        cacheGet(blurKey)?.let { return it }
        val file = File(directory, blurKey)
        if (file.isFile) {
            return BitmapFactory.decodeFile(file.path)?.also { cachePut(blurKey, it) }
        }

        // A missing/corrupt base image is terminal. Without this guard the
        // blur resolver would recursively ask for the same zero-radius base.
        if (blurRadiusDp.roundToInt() == 0) return null

        val base = image(imageId, 0f) ?: return null
        val sourceScale = min(1f, BLUR_MAX_PIXEL_SIZE.toFloat() / max(base.width, base.height))
        val blurSource = if (sourceScale < 1f) {
            base.scale(
                max(1, (base.width * sourceScale).roundToInt()),
                max(1, (base.height * sourceScale).roundToInt()),
            )
        } else base
        val radiusPixels = (blurRadiusDp * appContext.resources.displayMetrics.density * sourceScale).roundToInt()
        if (radiusPixels <= 0) {
            if (blurSource !== base && !blurSource.isRecycled) blurSource.recycle()
            return base
        }
        val blurred = try {
            GaussianBitmapBlur.blur(blurSource, radiusPixels)
        } finally {
            if (blurSource !== base && !blurSource.isRecycled) blurSource.recycle()
        } ?: return base
        persistVariant(blurKey, blurred)
        cachePut(blurKey, blurred)
        return blurred
    }

    fun imageExists(imageId: String): Boolean = isValidImageId(imageId) && imageFile(imageId).isFile

    fun byteCount(imageId: String): Long? =
        imageFile(imageId).takeIf { isValidImageId(imageId) && it.isFile }?.length()

    /** Removes the base image and every cached/rendered blur sibling derived from it. */
    fun delete(imageId: String) {
        if (!isValidImageId(imageId)) return
        val stem = imageId.removeSuffix(".jpg")
        synchronized(memoryCache) {
            memoryCache.keys.filter { it == imageId || it.startsWith("$stem-b") }.forEach(memoryCache::remove)
        }
        directory.listFiles()?.forEach { file ->
            if (file.name == imageId || (file.name.startsWith("$stem-b") && file.name.endsWith(".jpg"))) {
                file.delete()
            }
        }
    }

    /** Keeps only the currently selected blur variant; safe to call after a slider commit. */
    fun pruneVariants(imageId: String, keepingBlurRadiusDp: Float) {
        if (!isValidImageId(imageId)) return
        val keep = blurKey(imageId, keepingBlurRadiusDp)
        val stem = imageId.removeSuffix(".jpg")
        directory.listFiles()?.forEach { file ->
            if (file.name.startsWith("$stem-b") && file.name.endsWith(".jpg") && file.name != keep) {
                synchronized(memoryCache) { memoryCache.remove(file.name) }
                file.delete()
            }
        }
    }

    /** Decodes the active image/variant before a terminal is mounted; invoke off the main thread. */
    @WorkerThread
    fun prewarm(backgrounds: Iterable<TerminalBackgroundImage>) {
        backgrounds.forEach { background -> image(background.imageId, background.blurRadiusDp) }
    }

    /** Creates an independent drawable for a terminal surface or its enclosing tmux viewport. */
    fun drawable(themeBackgroundArgb: Int, background: TerminalBackgroundImage?): Drawable {
        if (background == null) return themeBackgroundArgb.toDrawable()
        val bitmap = image(background.imageId, background.blurRadiusDp)
            ?: return themeBackgroundArgb.toDrawable()
        return TerminalBackgroundDrawable(
            bitmap = bitmap,
            baseColor = themeBackgroundArgb,
            dim = background.dim,
            fillMode = background.fillMode,
        )
    }

    private fun decodeImportedBitmap(data: ByteArray): Bitmap? = try {
        val source = ImageDecoder.createSource(ByteBuffer.wrap(data))
        ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            val size = info.size
            val scale = min(1f, MAX_PIXEL_SIZE.toFloat() / max(size.width, size.height).toFloat())
            decoder.setTargetSize(
                max(1, (size.width * scale).roundToInt()),
                max(1, (size.height * scale).roundToInt()),
            )
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
    } catch (_: Exception) {
        null
    }

    private fun persistVariant(name: String, bitmap: Bitmap) {
        if (!directory.exists() && !directory.mkdirs()) return
        val temporary = File(directory, ".$name.tmp")
        try {
            temporary.outputStream().use { output ->
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, output)) return
            }
            if (!temporary.renameTo(File(directory, name))) temporary.delete()
        } catch (_: Exception) {
            temporary.delete()
        }
    }

    private fun imageFile(imageId: String): File = File(directory, imageId)

    private fun blurKey(imageId: String, blurRadiusDp: Float): String {
        val rounded = blurRadiusDp.roundToInt()
        return if (rounded == 0) imageId else "${imageId.removeSuffix(".jpg")}-b$rounded.jpg"
    }

    private fun isValidImageId(imageId: String): Boolean = IMAGE_ID_PATTERN.matches(imageId)

    private fun cacheGet(key: String): Bitmap? = synchronized(memoryCache) { memoryCache[key] }

    private fun cachePut(key: String, bitmap: Bitmap) {
        synchronized(memoryCache) { memoryCache[key] = bitmap }
    }

    private companion object {
        const val DIRECTORY_NAME = "TerminalBackgrounds"
        const val MAX_PIXEL_SIZE = 2732
        const val BLUR_MAX_PIXEL_SIZE = 1366
        const val JPEG_QUALITY = 85
        val IMAGE_ID_PATTERN = Regex("[0-9a-fA-F-]{36}\\.jpg")
        val memoryCache = object : LinkedHashMap<String, Bitmap>(8, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Bitmap>?): Boolean = size > 8
        }
    }
}

/** Opaque terminal backdrop: base theme color, picture, then a theme-color dim scrim. */
class TerminalBackgroundDrawable(
    private val bitmap: Bitmap,
    private val baseColor: Int,
    private val dim: Float,
    private val fillMode: TerminalBackgroundFillMode,
) : Drawable() {
    private val imagePaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val basePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = baseColor }
    private val scrimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = baseColor
        alpha = (dim.coerceIn(0f, 1f) * 255).roundToInt()
    }

    override fun draw(canvas: Canvas) {
        val target = bounds
        if (target.isEmpty || bitmap.isRecycled) return
        canvas.drawRect(target, basePaint)
        val scale = when (fillMode) {
            TerminalBackgroundFillMode.Fill -> max(
                target.width().toFloat() / bitmap.width,
                target.height().toFloat() / bitmap.height,
            )
            TerminalBackgroundFillMode.Fit -> min(
                target.width().toFloat() / bitmap.width,
                target.height().toFloat() / bitmap.height,
            )
        }
        val width = bitmap.width * scale
        val height = bitmap.height * scale
        val left = target.left + (target.width() - width) / 2f
        val top = target.top + (target.height() - height) / 2f
        canvas.withClip(target) {
            drawBitmap(bitmap, null, RectF(left, top, left + width, top + height), imagePaint)
            drawRect(target, scrimPaint)
        }
    }

    override fun setAlpha(alpha: Int) = Unit
    override fun setColorFilter(colorFilter: ColorFilter?) = Unit
    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.OPAQUE
}

/** CPU-side three-pass box blur used only while creating a cached background variant. */
private object GaussianBitmapBlur {
    fun blur(source: Bitmap, radius: Int): Bitmap? {
        if (radius <= 0 || source.isRecycled) return source
        return try {
            val width = source.width
            val height = source.height
            val input = IntArray(width * height)
            source.getPixels(input, 0, width, 0, 0, width, height)
            val scratch = IntArray(input.size)
            repeat(3) {
                boxBlur(input, scratch, width, height, radius, horizontal = true)
                boxBlur(scratch, input, width, height, radius, horizontal = false)
            }
            Bitmap.createBitmap(input, width, height, Bitmap.Config.ARGB_8888)
        } catch (_: OutOfMemoryError) {
            null
        }
    }

    private fun boxBlur(
        source: IntArray,
        destination: IntArray,
        width: Int,
        height: Int,
        radius: Int,
        horizontal: Boolean,
    ) {
        val window = radius * 2 + 1
        if (horizontal) {
            for (y in 0 until height) {
                val row = y * width
                var a = 0; var r = 0; var g = 0; var b = 0
                for (offset in -radius..radius) {
                    val color = source[row + offset.coerceIn(0, width - 1)]
                    a += color ushr 24; r += color shr 16 and 0xff; g += color shr 8 and 0xff; b += color and 0xff
                }
                for (x in 0 until width) {
                    destination[row + x] = (a / window shl 24) or (r / window shl 16) or
                        (g / window shl 8) or (b / window)
                    val add = source[row + (x + radius + 1).coerceAtMost(width - 1)]
                    val remove = source[row + (x - radius).coerceAtLeast(0)]
                    a += (add ushr 24) - (remove ushr 24)
                    r += (add shr 16 and 0xff) - (remove shr 16 and 0xff)
                    g += (add shr 8 and 0xff) - (remove shr 8 and 0xff)
                    b += (add and 0xff) - (remove and 0xff)
                }
            }
        } else {
            for (x in 0 until width) {
                var a = 0; var r = 0; var g = 0; var b = 0
                for (offset in -radius..radius) {
                    val color = source[offset.coerceIn(0, height - 1) * width + x]
                    a += color ushr 24; r += color shr 16 and 0xff; g += color shr 8 and 0xff; b += color and 0xff
                }
                for (y in 0 until height) {
                    destination[y * width + x] = (a / window shl 24) or (r / window shl 16) or
                        (g / window shl 8) or (b / window)
                    val add = source[(y + radius + 1).coerceAtMost(height - 1) * width + x]
                    val remove = source[(y - radius).coerceAtLeast(0) * width + x]
                    a += (add ushr 24) - (remove ushr 24)
                    r += (add shr 16 and 0xff) - (remove shr 16 and 0xff)
                    g += (add shr 8 and 0xff) - (remove shr 8 and 0xff)
                    b += (add and 0xff) - (remove and 0xff)
                }
            }
        }
    }
}
