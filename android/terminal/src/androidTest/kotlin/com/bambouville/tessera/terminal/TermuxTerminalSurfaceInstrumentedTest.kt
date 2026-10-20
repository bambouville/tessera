package com.bambouville.tessera.terminal

import android.app.Activity
import android.content.ComponentName
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.os.SystemClock
import android.util.Log
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.view.KeyEvent
import android.view.View
import android.view.MotionEvent
import android.view.inputmethod.EditorInfo
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TextStyle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.core.content.res.ResourcesCompat
import com.bambouville.tessera.core.bridge.SharedArmedModifiers
import com.bambouville.tessera.core.bridge.SharedTmuxCellRect
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TermuxTerminalSurfaceInstrumentedTest {
    @Test
    fun agentSnapshotPreservesStyledSuggestionAndPhysicalCursorColumn() = withSizedSurface { surface ->
        surface.feed("\u001b[2J\u001b[1;1H❯ \u001b[7ms\u001b[0;2muggested work\u001b[0m\u001b[1;3H".encodeToByteArray())
        val snapshot = requireNotNull(surface.snapshotText())
        assertEquals(0, snapshot.cursorRow)
        assertEquals(2, snapshot.cursorColumn)
        assertEquals("❯ suggested work", snapshot.currentLine)
        val cells = requireNotNull(snapshot.screenEvidence).cells.first()
        assertEquals(8, cells[2].style)
        assertEquals(32, cells[3].style)
        assertFalse(snapshot.visibleText.contains("\u001b"))
        surface.feed("\u001b[1;3H\u001b[0mreal draft\u001b[K".encodeToByteArray())
        val typed = requireNotNull(surface.snapshotText())
        assertEquals(12, typed.cursorColumn)
        assertEquals("❯ real draft", typed.currentLine)
        assertEquals(0, requireNotNull(typed.screenEvidence).cells.first()[2].style)
        surface.feed("\u001b[?2026hpartial".encodeToByteArray())
        assertEquals(true, surface.snapshotText()?.framePending)
        surface.feed("\u001b[?2026l".encodeToByteArray())
        assertTrue(surface.snapshotText() != null)
        val columns = surface.view.mEmulator.mColumns
        surface.feed(("\u001b[2J\u001b[H" + "x".repeat(columns + 1)).encodeToByteArray())
        val wrapped = requireNotNull(surface.snapshotText()?.screenEvidence).wrappedRows
        assertEquals(listOf(false, true, false), wrapped.take(3))
    }

    @Test
    fun transientLayoutKeepsEmulatorOnCommittedGrid() = withSizedSurface { surface ->
        surface.view.updateSize()
        val emulator = surface.view.mEmulator
        val rows = emulator.mRows
        val columns = emulator.mColumns
        val sizes = mutableListOf<Pair<Int, Int>>()
        surface.onResize = { cols, lines -> sizes += cols to lines }
        surface.feed("\u001b[${rows - 1};1HAsk Codex to do anything".encodeToByteArray())
        surface.view.layout(0, 0, 600, 868)
        assertEquals("A transient modal size must not reach the emulator", rows, emulator.mRows)
        assertEquals(columns, emulator.mColumns)
        surface.feed("\u001b[${rows};20H\u001b[48;2;30;30;30m⠂\u001b[0m".encodeToByteArray())
        surface.view.layout(0, 0, 600, 900)
        assertTrue("A canceled pulse must not reach the host", sizes.isEmpty())
        assertTrue(surface.snapshotText()!!.visibleText.contains("Ask Codex to do anything"))
    }

    @Test
    fun lastingLayoutReattachesAndAuthoritativeResizeAndCloseCancelPendingWork() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent.makeMainActivity(ComponentName(instrumentation.context, TerminalTestActivity::class.java))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as TerminalTestActivity
        lateinit var surface: TermuxTerminalSurface
        val sizes = mutableListOf<Pair<Int, Int>>()
        var initialRows = 0
        try {
            instrumentation.runOnMainSync {
                val container = android.widget.FrameLayout(activity)
                surface = TermuxTerminalSurface(activity)
                container.addView(surface.view, android.widget.FrameLayout.LayoutParams(600, 900))
                activity.setContentView(container)
            }
            instrumentation.waitForIdleSync()
            Thread.sleep(200)
            instrumentation.runOnMainSync {
                initialRows = surface.view.mEmulator.mRows
                surface.onResize = { columns, rows ->
                    assertEquals(columns, surface.view.mEmulator.mColumns)
                    assertEquals(rows, surface.view.mEmulator.mRows)
                    sizes += columns to rows
                }
                surface.view.layoutParams = android.widget.FrameLayout.LayoutParams(600, 840)
                surface.view.layout(0, 0, 600, 840)
                assertEquals(initialRows, surface.view.mEmulator.mRows)
                assertTrue(sizes.isEmpty())
                val container = surface.view.parent as android.widget.FrameLayout
                container.removeView(surface.view)
                container.addView(surface.view, android.widget.FrameLayout.LayoutParams(600, 840))
            }
            Thread.sleep(250)
            instrumentation.runOnMainSync {
                assertEquals(1, sizes.size)
                assertTrue(surface.view.mEmulator.mRows < initialRows)
                surface.view.layoutParams = android.widget.FrameLayout.LayoutParams(600, 780)
                surface.view.layout(0, 0, 600, 780)
                surface.resize(70, 20)
                assertEquals(2, sizes.size)
            }
            Thread.sleep(200)
            instrumentation.runOnMainSync {
                assertEquals(70, surface.view.mEmulator.mColumns)
                assertEquals(20, surface.view.mEmulator.mRows)
                assertEquals(2, sizes.size)
                surface.view.layoutParams = android.widget.FrameLayout.LayoutParams(600, 720)
                surface.view.layout(0, 0, 600, 720)
                surface.close()
            }
            Thread.sleep(200)
            instrumentation.runOnMainSync { assertEquals(2, sizes.size) }
        } finally {
            instrumentation.runOnMainSync { surface.close(); activity.finish() }
        }
    }

    @Test
    fun idleRedrawPreservesHistoryInNativeWindow() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent.makeMainActivity(ComponentName(instrumentation.context, TerminalTestActivity::class.java))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as TerminalTestActivity
        lateinit var surface: TermuxTerminalSurface
        try {
            instrumentation.runOnMainSync {
                surface = TermuxTerminalSurface(activity)
                activity.setContentView(surface.view)
            }
            instrumentation.waitForIdleSync()
            instrumentation.runOnMainSync {
                assertTrue(surface.view.width > 0 && surface.view.height > 0)
                repeat(500) { surface.feed("NATIVE-HISTORY-$it\r\n".encodeToByteArray()) }
                surface.view.topRow = -12
                surface.view.invalidate()
            }
            fun capture(name: String) {
                instrumentation.waitForIdleSync()
                // Use the native Canvas renderer at the window's real
                // measured size. Emulator compositor screenshots can expose
                // a partially copied first frame even after idle sync.
                lateinit var bitmap: Bitmap
                instrumentation.runOnMainSync {
                    bitmap = Bitmap.createBitmap(surface.view.width, surface.view.height, Bitmap.Config.ARGB_8888)
                    surface.view.draw(Canvas(bitmap))
                }
                val values = android.content.ContentValues().apply {
                    put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
                    put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/png")
                    put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/tessera-idle-redraw")
                }
                val resolver = activity.contentResolver
                val uri = checkNotNull(resolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values))
                checkNotNull(resolver.openOutputStream(uri)).use {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
            }
            capture("android-history")
            repeat(30) {
                instrumentation.runOnMainSync {
                    surface.feed("\u001b[?2026h\u001b[s\u001b[1;1Hidle prompt\u001b[u\u001b[?2026l".encodeToByteArray())
                    assertEquals(-12, surface.view.topRow)
                }
                Thread.sleep(30)
            }
            capture("android-redrawn")
        } finally {
            instrumentation.runOnMainSync { surface.close(); activity.finish() }
        }
    }

    @Test
    fun idleRedrawPreservesPrimaryHistory() = withSizedSurface { surface ->
        repeat(100) { surface.feed("history-$it\r\n".encodeToByteArray()) }
        surface.view.topRow = -12
        repeat(8) {
            for (part in listOf("\u001b[?2026h", "\u001b[s\u001b[1;1Hidle prompt\u001b[u", "\u001b[?2026l")) {
                surface.feed(part.encodeToByteArray())
                assertEquals("idle redraw must preserve the reader's position", -12, surface.view.topRow)
            }
        }
    }

    @Test
    fun newOutputKeepsHistoryAnchoredAndLiveTailFollowing() = withSizedSurface { surface ->
        repeat(100) { surface.feed("history-$it\r\n".encodeToByteArray()) }
        surface.view.topRow = -12
        val emulator = surface.view.mEmulator
        val before = emulator.screen.getSelectedText(0, -12, emulator.mColumns, -12)
        surface.feed("new line\r\n".encodeToByteArray())
        assertEquals(-13, surface.view.topRow)
        assertEquals(before, emulator.screen.getSelectedText(0, -13, emulator.mColumns, -13))
        surface.view.topRow = 0
        surface.feed("another line\r\n".encodeToByteArray())
        assertEquals(0, surface.view.topRow)
        surface.view.topRow = -12
        surface.feed("\u001b[?1049h\u001b[2J\u001b[Halternate".encodeToByteArray())
        assertEquals(0, surface.view.topRow)
    }

    @Test
    fun typingReturnsToLiveCursorButQueriesAndMarginRedrawsDoNot() = withSizedSurface { surface ->
        repeat(100) { surface.feed("history-$it\r\n".encodeToByteArray()) }
        surface.view.topRow = -12
        surface.feed("\u001b[6n".encodeToByteArray())
        assertEquals(-12, surface.view.topRow)
        surface.feed("\u001b[?69h\u001b[2;20s\u001b[24;2H\n".encodeToByteArray())
        assertEquals(-12, surface.view.topRow)
        surface.view.inputCodePoint('x'.code, false, false)
        assertEquals(0, surface.view.topRow)
        surface.view.topRow = -12
        surface.view.handleKeyCode(KeyEvent.KEYCODE_ENTER, 0)
        assertEquals(0, surface.view.topRow)
        surface.view.topRow = -12
        surface.view.autofill(android.view.autofill.AutofillValue.forText("hello"))
        assertEquals(0, surface.view.topRow)
    }

    @Test
    fun bindEmptiesTranscriptKeepsScreenAndResetsTopRow() = withSizedSurface { surface ->
        repeat(80) { row -> surface.feed("history-$row\r\n".encodeToByteArray()) }
        val emulator = surface.view.mEmulator
        assertTrue(emulator.screen.activeTranscriptRows > 0)
        surface.view.topRow = -5

        val owner = RenderOwner(windowId = 1, paneId = 11, epoch = 7)
        surface.bind(owner)

        assertEquals(owner, surface.boundOwner)
        assertEquals(0, emulator.screen.activeTranscriptRows)
        assertEquals(0, surface.view.topRow)
        assertEquals(60, surface.snapshotNonSecretState().columns)
        assertEquals(24, surface.snapshotNonSecretState().rows)
        assertTrue(surface.snapshotText()?.visibleText.orEmpty().contains("history-79"))

        // A same-owner bind must leave a newly accumulated history and the
        // user's current scroll position alone.
        repeat(48) { row -> surface.feed(owner, "owner-history-$row\r\n".encodeToByteArray()) }
        val transcriptBeforeSameOwnerBind = emulator.screen.activeTranscriptRows
        surface.view.topRow = -3
        surface.bind(owner)
        assertEquals(transcriptBeforeSameOwnerBind, emulator.screen.activeTranscriptRows)
        assertEquals(-3, surface.view.topRow)

        // A continuity break for the same pane changes only the epoch, but
        // must be just as destructive to cached history as a pane switch.
        val nextEpoch = owner.copy(epoch = owner.epoch + 1)
        surface.bind(nextEpoch)
        assertEquals(nextEpoch, surface.boundOwner)
        assertEquals(0, emulator.screen.activeTranscriptRows)
        assertEquals(0, surface.view.topRow)
        assertEquals(60, surface.snapshotNonSecretState().columns)
        assertEquals(24, surface.snapshotNonSecretState().rows)
    }

    @Test
    fun bindDuringAlternateScreenClearsMainTranscript() = withSizedSurface { surface ->
        repeat(80) { row -> surface.feed("primary-history-$row\r\n".encodeToByteArray()) }
        val emulator = surface.view.mEmulator
        assertTrue(emulator.screen.activeTranscriptRows > 0)

        surface.feed("\u001b[?1049h\u001b[2J\u001b[HALTERNATE-OWNER-SCREEN".encodeToByteArray())
        assertTrue(emulator.isAlternateBufferActive)
        val owner = RenderOwner(windowId = 2, paneId = 22, epoch = 8)
        surface.bind(owner)

        // Binding must not blank the TUI that is currently visible.
        assertTrue(surface.snapshotText()?.visibleText.orEmpty().contains("ALTERNATE-OWNER-SCREEN"))
        surface.feed(owner, "\u001b[?1049l".encodeToByteArray())
        assertFalse(emulator.isAlternateBufferActive)
        assertEquals(0, emulator.screen.activeTranscriptRows)
    }

    @Test
    fun transportGenerationRebindsAnOwnerWhenTheSharedRuntimeRestarts() = withSizedSurface { surface ->
        val firstRuntime = RenderOwner(
            windowId = 2,
            paneId = 22,
            epoch = 0,
            transportGeneration = 31,
        )
        surface.bind(firstRuntime)
        repeat(64) { row -> surface.feed(firstRuntime, "first-runtime-$row\r\n".encodeToByteArray()) }
        assertTrue(surface.view.mEmulator.screen.activeTranscriptRows > 0)
        surface.view.topRow = -4

        // A new SharedTmuxRuntime begins its core ledger epoch again. It must
        // still clear this platform surface even though the core owner shape is
        // otherwise identical.
        val replacementRuntime = firstRuntime.copy(transportGeneration = 32)
        surface.bind(replacementRuntime)

        assertEquals(replacementRuntime, surface.boundOwner)
        assertEquals(0, surface.view.mEmulator.screen.activeTranscriptRows)
        assertEquals(0, surface.view.topRow)
    }

    @Test
    fun foreignOwnerFeedNeverReachesTheEmulator() = withSizedSurface { surface ->
        val owner = RenderOwner(windowId = 3, paneId = 31, epoch = 9)
        surface.bind(owner)
        surface.feed(owner, "AUTHORIZED-OWNER\r\n".encodeToByteArray())
        surface.feed(RenderOwner(windowId = 4, paneId = 41, epoch = 9), "FOREIGN-OWNER".encodeToByteArray())

        val visible = surface.snapshotText()?.visibleText.orEmpty()
        assertTrue(visible.contains("AUTHORIZED-OWNER"))
        assertFalse(visible.contains("FOREIGN-OWNER"))
        assertEquals(1, surface.droppedForeignFeeds)
    }

    @Test
    fun painterFeedRemainsAllowedWhenSideChannelHistoryHasAnOwner() = withSizedSurface { surface ->
        // The controller enables this only for a real mosh/SSH painter.
        surface.setPainterFeedAdmission(true)
        surface.feed("UNBOUND-PAINTER".encodeToByteArray())
        assertTrue(surface.snapshotText()?.visibleText.orEmpty().contains("UNBOUND-PAINTER"))

        // A side-channel capture has a RenderOwner while mosh SSP remains the
        // authoritative painter of the visible terminal. `feed(bytes)` is the
        // explicit painter entry point; the owned overload is reserved for
        // ledger-tagged repaints and continues to enforce the owner check.
        surface.bind(RenderOwner(windowId = 5, paneId = 51, epoch = 10))
        surface.feed("BOUND-PAINTER-OK".encodeToByteArray())

        assertTrue(surface.snapshotText()?.visibleText.orEmpty().contains("BOUND-PAINTER-OK"))
        assertEquals(0, surface.droppedForeignFeeds)
    }

    @Test
    fun painterFeedAdmissionRejectsUntaggedBytesWithoutAffectingOwnedRepaints() = withSizedSurface { surface ->
        surface.setPainterFeedAdmission(false)
        surface.feed("UNTAGGED-MUST-DROP".encodeToByteArray())

        val owner = RenderOwner(windowId = 6, paneId = 61, epoch = 11)
        surface.bind(owner)
        surface.feed(owner, "OWNED-REPAINT-OK".encodeToByteArray())

        val visible = surface.snapshotText()?.visibleText.orEmpty()
        assertFalse(visible.contains("UNTAGGED-MUST-DROP"))
        assertTrue(visible.contains("OWNED-REPAINT-OK"))
        assertEquals(1, surface.droppedForeignFeeds)
        assertFalse(surface.painterFeedsAdmitted)
    }

    @Test
    fun surfaceStateTracksBracketedPasteForOwnerModeRestore() = withSizedSurface { surface ->
        val owner = RenderOwner(windowId = 7, paneId = 71, epoch = 1)
        surface.bind(owner)

        surface.feed(owner, "\u001b[?2004h".encodeToByteArray())
        assertTrue(surface.snapshotNonSecretState().bracketedPaste)

        surface.feed(owner, "\u001b[?2004l".encodeToByteArray())
        assertFalse(surface.snapshotNonSecretState().bracketedPaste)
    }

    @Test
    fun bracketedPasteRestoreChangesTheActualClipboardWireBytes() = withSizedSurface { surface ->
        val owner = RenderOwner(windowId = 7, paneId = 71, epoch = 2)
        val sent = ByteArrayOutputStream()
        val clipboard = surface.view.context.getSystemService(ClipboardManager::class.java)
        surface.bind(owner)
        surface.onInput = { sent.write(it) }
        clipboard.setPrimaryClip(ClipData.newPlainText("terminal test", "paste\nline"))

        // This is the same DECSET sequence the render executor emits for a
        // saved owner. Verify the emulator does more than report the bit: a
        // real clipboard paste must acquire the bracket bytes on the wire.
        surface.feed(owner, "\u001b[?2004h".encodeToByteArray())
        surface.pasteClipboard()
        assertEquals(
            "\u001b[200~paste\rline\u001b[201~",
            sent.toByteArray().decodeToString(),
        )

        sent.reset()
        // The next owner's restore disables the mode; no wrappers may leak
        // into its shell input.
        surface.feed(owner, "\u001b[?2004l".encodeToByteArray())
        surface.pasteClipboard()
        assertEquals("paste\rline", sent.toByteArray().decodeToString())
    }

    @Test
    fun surfaceStateReportsGridAlternateScreenAndMouseMode() = withSizedSurface { surface ->
        val before = surface.snapshotNonSecretState()
        assertEquals(60, before.columns)
        assertEquals(24, before.rows)
        assertFalse(before.alternateScreen)
        assertEquals(TerminalMouseMode.Off, before.mouseMode)

        surface.feed("\u001b[?1000h\u001b[?1049h".encodeToByteArray())
        val alternate = surface.snapshotNonSecretState()
        assertEquals(60, alternate.columns)
        assertEquals(24, alternate.rows)
        assertTrue(alternate.alternateScreen)
        assertTrue(alternate.mouseTracking)
        assertEquals(TerminalMouseMode.Tracking, alternate.mouseMode)

        surface.feed("\u001b[?1000l\u001b[?1049l".encodeToByteArray())
        val restored = surface.snapshotNonSecretState()
        assertFalse(restored.alternateScreen)
        assertFalse(restored.mouseTracking)
        assertEquals(TerminalMouseMode.Off, restored.mouseMode)
    }

    @Test
    fun smoothScrollMomentumContinuesInTheFingerDirection() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent.makeMainActivity(
                ComponentName(instrumentation.context, TerminalTestActivity::class.java),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as TerminalTestActivity
        instrumentation.waitForIdleSync()
        val failure = AtomicReference<Throwable?>()
        lateinit var surface: TermuxTerminalSurface

        instrumentation.runOnMainSync {
            try {
                surface = TermuxTerminalSurface(activity)
                activity.setContentView(surface.view)
            } catch (error: Throwable) {
                failure.set(error)
            }
        }
        instrumentation.waitForIdleSync()
        // Start the gesture on the Activity's settled production geometry,
        // not an artificial 600x900 frame that the next traversal replaces.
        Thread.sleep(200)
        instrumentation.runOnMainSync {
            try {
                repeat(240) { row -> surface.feed("history-$row\r\n".encodeToByteArray()) }
                assertTrue(surface.view.mEmulator.screen.activeTranscriptRows > 100)
                surface.view.setSmoothScrollingEnabled(true)
                surface.view.setSmoothScrollingSpeed(0.5f)
            } catch (error: Throwable) {
                failure.set(error)
            }
        }
        failure.get()?.let { throw it }

        var rowAtRelease = 0
        instrumentation.runOnMainSync {
            val recognizerField = surface.view.javaClass.getDeclaredField("mGestureRecognizer").apply {
                isAccessible = true
            }
            val recognizer = recognizerField.get(surface.view)
            val listenerField = recognizer.javaClass.getDeclaredField("mListener").apply {
                isAccessible = true
            }
            val listener = listenerField.get(recognizer)
            val event = MotionEvent.obtain(
                SystemClock.uptimeMillis(),
                SystemClock.uptimeMillis(),
                MotionEvent.ACTION_MOVE,
                300f,
                500f,
                0,
            )
            val scroll = listener.javaClass.getMethod(
                "onScroll",
                MotionEvent::class.java,
                Float::class.javaPrimitiveType,
                Float::class.javaPrimitiveType,
            ).apply { isAccessible = true }
            val fling = listener.javaClass.getMethod(
                "onFling",
                MotionEvent::class.java,
                Float::class.javaPrimitiveType,
                Float::class.javaPrimitiveType,
            ).apply { isAccessible = true }
            // A downward content drag reports negative distanceY and positive
            // release velocity. Exercise the exact production listener while
            // avoiding timing variance in GestureDetector's velocity sampler.
            scroll.invoke(listener, event, 0f, -600f)
            rowAtRelease = surface.view.topRow
            fling.invoke(listener, event, 0f, 2_400f)
            event.recycle()
        }
        assertTrue("gesture must enter primary-screen history", rowAtRelease < 0)
        Thread.sleep(180)
        instrumentation.waitForIdleSync()
        var rowAfterMomentum = 0
        instrumentation.runOnMainSync { rowAfterMomentum = surface.view.topRow }
        assertTrue(
            "downward content release must continue toward older rows: release=$rowAtRelease after=$rowAfterMomentum",
            rowAfterMomentum < rowAtRelease,
        )

        instrumentation.runOnMainSync {
            surface.close()
            activity.finish()
        }
    }

    @Test
    fun backgroundImageIsVisibleThroughDefaultCellsAndViewportMargins() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent.makeMainActivity(
                ComponentName(instrumentation.context, TerminalTestActivity::class.java),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as TerminalTestActivity
        instrumentation.waitForIdleSync()

        val source = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888).apply {
            eraseColor(Color.rgb(220, 35, 30))
        }
        val encoded = ByteArrayOutputStream().also { output ->
            assertTrue(source.compress(Bitmap.CompressFormat.JPEG, 100, output))
        }.toByteArray()
        source.recycle()
        val store = TerminalBackgroundImageStore(activity)
        val imported = requireNotNull(store.importImage(encoded))

        val failure = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync {
            try {
                val surface = TermuxTerminalSurface(activity, terminalBackgroundStore = store)
                surface.resize(40, 20)
                val viewport = GeometryNeutralTerminalViewport(activity, surface)
                val pane = SharedTmuxCellRect(columns = 80, rows = 30)
                viewport.setWindowGrid(window = pane, focus = pane)
                activity.setContentView(viewport)
                viewport.measure(
                    View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY),
                )
                viewport.layout(0, 0, 480, 800)

                // Match live Settings ordering: the compact tmux viewport is already
                // mounted when the new global background arrives.
                surface.setBackgroundImage(
                    TerminalBackgroundImage(imageId = imported.imageId, dim = 0f),
                )

                assertTrue(surface.view.background is TerminalBackgroundDrawable)
                assertTrue(viewport.background is TerminalBackgroundDrawable)

                val rendered = Bitmap.createBitmap(480, 800, Bitmap.Config.ARGB_8888)
                viewport.draw(Canvas(rendered))
                val center = rendered.getPixel(rendered.width / 2, rendered.height / 2)
                assertTrue("default cells must reveal the image", Color.red(center) > 160)
                assertTrue("red fixture must not collapse to theme black", Color.red(center) > Color.blue(center) * 2)
                rendered.recycle()

                viewport.releaseTerminal()
                surface.close()
            } catch (error: Throwable) {
                failure.set(error)
            } finally {
                store.delete(imported.imageId)
                activity.finish()
            }
        }
        failure.get()?.let { throw it }
    }

    @Test
    fun themesAndCursorAppearanceAreIndependentPerSurface() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent.makeMainActivity(
                ComponentName(instrumentation.context, TerminalTestActivity::class.java),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as TerminalTestActivity
        instrumentation.waitForIdleSync()
        val failure = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync {
            try {
                val first = TermuxTerminalSurface(activity)
                val second = TermuxTerminalSurface(activity)
                val expectedDefaultTextPixels = android.util.TypedValue.applyDimension(
                    android.util.TypedValue.COMPLEX_UNIT_SP,
                    13f,
                    activity.resources.displayMetrics,
                ).toInt()
                assertEquals(expectedDefaultTextPixels, first.view.textSizePixels)
                first.resize(80, 24)
                second.resize(80, 24)

                first.setTheme(TerminalTheme.Paper)
                first.setCursorAppearance(TerminalCursorStyle.Underline, blink = false)
                second.setTheme(TerminalTheme.Dracula)
                second.setCursorAppearance(TerminalCursorStyle.Bar, blink = true)

                assertEquals(
                    TerminalTheme.Paper.termuxPalette()[TextStyle.COLOR_INDEX_BACKGROUND],
                    first.view.mEmulator.mColors.mCurrentColors[TextStyle.COLOR_INDEX_BACKGROUND],
                )
                assertEquals(
                    TerminalTheme.Dracula.termuxPalette()[TextStyle.COLOR_INDEX_BACKGROUND],
                    second.view.mEmulator.mColors.mCurrentColors[TextStyle.COLOR_INDEX_BACKGROUND],
                )
                assertEquals(
                    TerminalTheme.Paper.termuxPalette()[1],
                    first.view.mEmulator.mColors.mCurrentColors[1],
                )
                assertEquals(
                    TerminalTheme.Dracula.termuxPalette()[1],
                    second.view.mEmulator.mColors.mCurrentColors[1],
                )
                assertEquals(TerminalEmulator.TERMINAL_CURSOR_STYLE_UNDERLINE, first.view.mEmulator.cursorStyle)
                assertEquals(TerminalEmulator.TERMINAL_CURSOR_STYLE_BAR, second.view.mEmulator.cursorStyle)

                first.close()
                second.close()
            } catch (error: Throwable) {
                failure.set(error)
            } finally {
                activity.finish()
            }
        }
        failure.get()?.let { throw it }
    }

    @Test
    fun remoteSurfaceRendersModesResizesAndRoutesControlAndImeInput() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent.makeMainActivity(
                ComponentName(instrumentation.context, TerminalTestActivity::class.java),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as TerminalTestActivity
        instrumentation.waitForIdleSync()
        var foreground = false
        for (attempt in 0 until 50) {
            instrumentation.runOnMainSync { foreground = activity.hasWindowFocus() }
            if (foreground) break
            Thread.sleep(20)
        }
        assertTrue("terminal test activity never became foreground", foreground)
        val failure = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync {
            try {
                runProof(activity)
            } catch (error: Throwable) {
                failure.set(error)
            } finally {
                activity.finish()
            }
        }
        failure.get()?.let { throw it }
    }

    @Test
    fun geometryNeutralViewportKeepsAuthoritativePaneGridWhileFittingPhone() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent.makeMainActivity(
                ComponentName(instrumentation.context, TerminalTestActivity::class.java),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as TerminalTestActivity
        instrumentation.waitForIdleSync()
        val failure = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync {
            try {
                val surface = TermuxTerminalSurface(activity)
                val viewport = GeometryNeutralTerminalViewport(activity, surface)
                val pane = SharedTmuxCellRect(columns = 100, rows = 40)
                viewport.setWindowGrid(window = pane, focus = pane)
                activity.setContentView(viewport)
                viewport.measure(
                    View.MeasureSpec.makeMeasureSpec(500, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY),
                )
                viewport.layout(0, 0, 500, 800)

                val state = surface.snapshotNonSecretState()
                assertEquals(100, state.columns)
                assertEquals(40, state.rows)
                assertTrue("authoritative pane should scale down to phone width", surface.view.scaleX < 1f)
                assertEquals(surface.view.scaleX, surface.view.scaleY, 0.0001f)
                assertTrue(surface.view.translationX >= 0f)
                assertTrue(surface.view.translationY >= 0f)

                surface.feed("\u001b[2J\u001b[3;1H".encodeToByteArray())
                val topClearance = surface.caretClearance()
                assertTrue(topClearance != null)
                assertTrue(topClearance!!.belowPixels > topClearance.abovePixels)

                surface.feed("\u001b[?1049h\u001b[2J\u001b[2;1H".encodeToByteArray())
                assertNull("alternate screen must keep the complete IME lift", surface.caretClearance())
                val rows = surface.snapshotNonSecretState().rows
                val columns = surface.snapshotNonSecretState().columns
                surface.feed("\u001b[${rows};1HALT STATUS LINE MUST REMAIN VISIBLE\u001b[2;1H".encodeToByteArray())
                assertTrue(
                    "alternate-screen status belongs to the final terminal row",
                    surface.view.mEmulator.screen
                        .getSelectedText(0, rows - 1, columns, rows - 1)
                        .contains("ALT STATUS LINE"),
                )

                surface.feed("\u001b[?1049l\u001b[2J\u001b[${rows};1HMOUSE STATUS LINE MUST REMAIN VISIBLE\u001b[?1000h\u001b[2;1H".encodeToByteArray())
                assertTrue(
                    "mouse reporting on a primary screen that scrolls locally follows the caret",
                    surface.caretClearance() != null,
                )
                surface.setMouseReportingImpliesAltScreen(true)
                assertNull(
                    "mouse reporting standing in for the alternate screen keeps the complete IME lift",
                    surface.caretClearance(),
                )
                surface.setMouseReportingImpliesAltScreen(false)
                assertTrue(
                    "mouse-reporting status belongs to the final terminal row",
                    surface.view.mEmulator.screen
                        .getSelectedText(0, rows - 1, columns, rows - 1)
                        .contains("MOUSE STATUS LINE"),
                )
                surface.feed("\u001b[?1000l\u001b[40;1H".encodeToByteArray())
                val bottomClearance = surface.caretClearance()
                assertTrue(bottomClearance != null)
                assertTrue(bottomClearance!!.abovePixels > topClearance.abovePixels)
                assertTrue(bottomClearance.belowPixels < topClearance.belowPixels)

                viewport.releaseTerminal()
                surface.close()
            } catch (error: Throwable) {
                failure.set(error)
            } finally {
                activity.finish()
            }
        }
        failure.get()?.let { throw it }
    }

    /**
     * The Samsung/Gboard auto-correct flow over already-committed text:
     * `deleteSurroundingText(n, 0)` followed by `commitText(corrected)`.
     * The deletions must reach the pty BEFORE the replacement — posting them
     * through the IME dispatch queue lets the synchronously-written
     * replacement overtake them, so the backspaces erase the correction's own
     * tail and the line shows the original word plus a truncated correction:
     * the "input gets duplicated" report. Same mechanism 456f32c fixed in
     * streamComposition; this pins the sibling path.
     */
    @Test
    fun imeRevisionOfCommittedTextDeletesBeforeTheReplacement() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent.makeMainActivity(
                ComponentName(instrumentation.context, TerminalTestActivity::class.java),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as TerminalTestActivity
        instrumentation.waitForIdleSync()
        lateinit var surface: TermuxTerminalSurface
        val input = ByteArrayOutputStream()
        instrumentation.runOnMainSync {
            surface = TermuxTerminalSurface(activity)
            activity.setContentView(surface.view)
            surface.view.measure(
                View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.EXACTLY),
            )
            surface.view.layout(0, 0, 600, 900)
            surface.resize(60, 24)
            surface.onInput = { input.write(it) }
            surface.view.requestFocus()
        }
        instrumentation.runOnMainSync {
            val connection = surface.view.onCreateInputConnection(EditorInfo())
            connection.commitText("teh ", 1)
            connection.deleteSurroundingText(4, 0)
            connection.commitText("the ", 1)
        }
        instrumentation.waitForIdleSync()
        val expected =
            "teh ".encodeToByteArray() + ByteArray(4) { 0x7F } + "the ".encodeToByteArray()
        assertEquals(
            "deletions must precede the replacement text at the pty",
            expected.toList(),
            input.toByteArray().toList(),
        )
    }

    /**
     * Gboard 18 revises a committed word through the API-34 replaceText entry
     * point instead of deleteSurroundingText + commitText (captured live from
     * the Pixel's Gboard 18.0.5 build: type "teh", tap the "the" suggestion,
     * observe replaceText(1, 3, "he ", 1)). Before the honest-mirror rework,
     * BaseInputConnection applied that edit silently to the local editable,
     * ZERO bytes reached the pty, and the leftover "he " was flushed together
     * with the NEXT keystroke - the "input gets duplicated" report.
     */
    @Test
    fun imeReplaceTextRevisionReachesThePty() {
        withImeSurface { surface, connection, input ->
            connection.commitText("t", 1)
            connection.commitText("e", 1)
            connection.commitText("h", 1)
            connection.replaceText(1, 3, "he ", 1, null)
            connection.commitText("m", 1)
            val expected = "teh".encodeToByteArray() +
                ByteArray(2) { 0x7F } + "he ".encodeToByteArray() +
                "m".encodeToByteArray()
            assertEquals(
                "suggestion-tap revision must be erase-tail + retype, and must not ghost into the next keystroke",
                expected.toList(),
                input.toByteArray().toList(),
            )
            assertEquals(
                "the mirror keeps the revised line so the IME can see its own text",
                "the m",
                (connection as android.view.inputmethod.BaseInputConnection).editable.toString(),
            )
        }
    }

    /**
     * The editable is an honest mirror of the current line: commits accumulate
     * (so the IME can see and revise its own text), a committed newline ends
     * the line model, and a revision the IME issues against a line that no
     * longer exists is clamped to what the mirror actually holds - no stray
     * DEL bytes reach the pty (in vim a stray DEL is real input, not a no-op).
     */
    @Test
    fun imeMirrorAccumulatesAndResetsOnEnter() {
        withImeSurface { _, connection, input ->
            connection.commitText("ls", 1)
            assertEquals("ls", connection.getTextBeforeCursor(10, 0).toString())
            connection.commitText("\n", 1)
            connection.deleteSurroundingText(2, 0)
            val expected = "ls\r".encodeToByteArray()
            assertEquals(
                "newline ends the mirrored line; a stale delete afterwards must emit nothing",
                expected.toList(),
                input.toByteArray().toList(),
            )
        }
    }

    /**
     * The composing path under the honest mirror: streaming while typing,
     * then an autocorrected commit takes back only the diverging tail. This is
     * Gboard's full (non-degraded) input mode, which the mirror's consistent
     * context is meant to re-enable.
     */
    @Test
    fun imeComposedAutocorrectTakesBackOnlyTheDivergingTail() {
        withImeSurface { _, connection, input ->
            connection.setComposingText("t", 1)
            connection.setComposingText("te", 1)
            connection.setComposingText("teh", 1)
            connection.commitText("the ", 1)
            val expected = "teh".encodeToByteArray() +
                ByteArray(2) { 0x7F } + "he ".encodeToByteArray()
            assertEquals(
                "composition streams forward; the correction erases only eh and types he ",
                expected.toList(),
                input.toByteArray().toList(),
            )
        }
    }

    /**
     * The device report: five letters typed on Mosh, a suggestion tapped, and
     * the word came back with a letter the user never typed. The mirror only
     * ever appends what the keyboard commits - both flows below emit a pure
     * four-character append and no erasure - so the report needs a number that
     * says which side produced the extra letter. `join=` is that number: how
     * much of the committed text retypes the line it lands on. An honest
     * completion of "actua" scores zero; one computed against a stale "actu"
     * scores the drift, and the doubled letter is the keyboard's.
     */
    @Test
    fun imeTraceScoresACompletionThatRetypesWhatIsAlreadyOnTheLine() {
        withImeSurface { surface, connection, input ->
            val traces = mutableListOf<String>()
            surface.imeTraceSink = { traces += it }

            "actua".forEach { connection.commitText(it.toString(), 1) }
            connection.commitText("lly ", 1)
            assertEquals(
                "an honest completion appends exactly the committed text",
                "actually ",
                String(input.toByteArray(), Charsets.ISO_8859_1),
            )
            val honest = traces.last { it.startsWith("reconcile") }

            // Enter ends the mirrored line, so the second word starts clean.
            connection.commitText("\n", 1)
            input.reset()
            traces.clear()

            "actua".forEach { connection.commitText(it.toString(), 1) }
            connection.commitText("ally", 1)
            assertEquals(
                "a stale completion is appended just as faithfully - that is the defect",
                "actuaally",
                String(input.toByteArray(), Charsets.ISO_8859_1),
            )
            val stale = traces.last { it.startsWith("reconcile") }

            assertTrue(
                "both completions are the same append: $honest / $stale",
                honest.contains("before=5 after=9 common=5 erased=0 sent=4") &&
                    stale.contains("before=5 after=9 common=5 erased=0 sent=4"),
            )
            assertTrue("an honest completion repeats nothing: $honest", honest.contains("join=0"))
            assertTrue("a stale completion repeats its drift: $stale", stale.contains("join=1"))
        }
    }

    private fun withImeSurface(
        block: (TermuxTerminalSurface, android.view.inputmethod.InputConnection, ByteArrayOutputStream) -> Unit,
    ) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent.makeMainActivity(
                ComponentName(instrumentation.context, TerminalTestActivity::class.java),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as TerminalTestActivity
        instrumentation.waitForIdleSync()
        lateinit var surface: TermuxTerminalSurface
        val input = ByteArrayOutputStream()
        instrumentation.runOnMainSync {
            surface = TermuxTerminalSurface(activity)
            activity.setContentView(surface.view)
            surface.view.measure(
                View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.EXACTLY),
            )
            surface.view.layout(0, 0, 600, 900)
            surface.resize(60, 24)
            surface.onInput = { input.write(it) }
            surface.view.requestFocus()
        }
        instrumentation.runOnMainSync {
            val connection = surface.view.onCreateInputConnection(EditorInfo())
            block(surface, connection, input)
        }
        instrumentation.waitForIdleSync()
    }

    private fun runProof(activity: Activity) {
        val surface = TermuxTerminalSurface(activity)
        activity.setContentView(surface.view)
        val input = ByteArrayOutputStream()
        val titles = mutableListOf<String?>()
        val sizes = mutableListOf<Pair<Int, Int>>()
        val bells = AtomicInteger()
        surface.onInput = { input.write(it) }
        surface.onTitleChanged = { titles += it }
        surface.onBell = { bells.incrementAndGet() }
        surface.onResize = { columns, rows -> sizes += columns to rows }
        val firstOutputDraws = AtomicInteger()
        surface.onFirstOutputRendered = { firstOutputDraws.incrementAndGet() }

        surface.setTheme(TerminalTheme("#f5f5f5", "#090909", "#ffffff"))
        val bundledTypeface = ResourcesCompat.getFont(activity, R.font.jetbrains_mono)
        assertEquals(bundledTypeface, surface.view.typeface)
        surface.setFont(TerminalFont(sizeSp = 18))
        val expectedPixels = android.util.TypedValue.applyDimension(
            android.util.TypedValue.COMPLEX_UNIT_SP,
            18f,
            activity.resources.displayMetrics,
        ).toInt()
        assertEquals(expectedPixels, surface.view.textSizePixels)
        assertEquals(
            "a size-only update must preserve bundled JetBrains Mono",
            bundledTypeface,
            surface.view.typeface,
        )
        val keyboardRequests = AtomicInteger()
        surface.onSoftwareKeyboardRequested = { keyboardRequests.incrementAndGet() }
        val tap = MotionEvent.obtain(0, 0, MotionEvent.ACTION_UP, 10f, 10f, 0)
        surface.view.mClient.onSingleTapUp(tap)
        tap.recycle()
        assertEquals(1, keyboardRequests.get())
        val width = 1_280
        val height = 720
        surface.view.measure(
            View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY),
        )
        surface.view.layout(0, 0, width, height)
        surface.setFocused(true)
        assertTrue(sizes.isNotEmpty())

        surface.feed("\u001b]0;Tessera Phase A\u0007main UTF-8: café 界 é\r\n".encodeToByteArray())
        surface.view.viewTreeObserver.dispatchOnDraw()
        assertTrue(surface.hasRenderedOutput)
        assertEquals(1, firstOutputDraws.get())
        assertTrue(titles.contains("Tessera Phase A"))
        val emulator = surface.view.mEmulator
        val visibleText = emulator.screen.getSelectedText(0, 0, emulator.mColumns, emulator.mRows)
        assertTrue(visibleText.contains("café 界 é"))

        surface.feed("\u0007".encodeToByteArray())
        assertEquals("BEL must reach the app-level attention policy exactly once", 1, bells.get())

        surface.feed("\u001b[?1049h\u001b[?1000h\u001b[?1006h\u001b[32mALT MOUSE\u001b[0m".encodeToByteArray())
        surface.view.viewTreeObserver.dispatchOnDraw()
        assertEquals(1, firstOutputDraws.get())
        val modeState = surface.snapshotNonSecretState()
        assertTrue(modeState.alternateScreen)
        assertTrue(modeState.mouseTracking)

        surface.view.inputCodePoint('A'.code, false, false)
        assertTrue(surface.view.handleKeyCode(KeyEvent.KEYCODE_DPAD_UP, 0))
        // A password-class field is what makes an IME withhold the dictation key
        // and the suggestion strip, so the terminal must never advertise one.
        val editorInfo = EditorInfo()
        val inputConnection = surface.view.onCreateInputConnection(editorInfo)
        assertEquals(
            "the terminal must advertise an ordinary text field",
            android.text.InputType.TYPE_CLASS_TEXT,
            editorInfo.inputType and android.text.InputType.TYPE_MASK_CLASS,
        )
        assertEquals(
            "a password variation withholds dictation and suggestions",
            0,
            editorInfo.inputType and android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
        )
        assertEquals(
            "NO_SUGGESTIONS withholds the suggestion strip",
            0,
            editorInfo.inputType and android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS,
        )
        assertEquals(
            "NO_PERSONALIZED_LEARNING reads to Gboard as incognito: no voice typing, no composing",
            0,
            editorInfo.imeOptions and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING,
        )
        assertTrue(inputConnection.commitText("界", 1))
        val inputBytes = input.toByteArray()
        assertTrue(inputBytes.containsSlice("A".encodeToByteArray()))
        assertTrue(inputBytes.containsSlice("\u001b[A".encodeToByteArray()))
        assertTrue(inputBytes.containsSlice("界".encodeToByteArray()))

        input.reset()
        // The armed set now reaches the wire through the shared encoder rather
        // than the upstream view's own Ctrl table.
        surface.setSoftwareModifiers(SharedArmedModifiers(control = true))
        assertTrue(inputConnection.commitText("c", 1))
        assertTrue(input.toByteArray().contains(0x03))
        surface.sendInput("\u001b[A".encodeToByteArray())
        assertTrue(input.toByteArray().containsSlice("\u001b[A".encodeToByteArray()))

        val clipboard = activity.getSystemService(ClipboardManager::class.java)
        clipboard.setPrimaryClip(ClipData.newPlainText("terminal test", "pasted\nline"))
        surface.pasteClipboard()
        assertTrue(input.toByteArray().containsSlice("pasted\rline".encodeToByteArray()))

        input.reset()
        // KeyEvent-driven special keys go through the upstream view's
        // KeyHandler with the armed set folded into keyMod — the shared
        // single-byte encoder cannot express a modified arrow, and zeroing
        // readControlKey() once lost this whole key class.
        surface.setSoftwareModifiers(SharedArmedModifiers(control = true))
        assertTrue(
            surface.view.onKeyDown(
                KeyEvent.KEYCODE_DPAD_LEFT,
                KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_LEFT),
            ),
        )
        assertTrue(
            "armed ⌃ + Left must send the modified arrow, not a bare one",
            input.toByteArray().containsSlice("[1;5D".encodeToByteArray()),
        )

        input.reset()
        surface.setSoftwareModifiers(SharedArmedModifiers(shift = true))
        assertTrue(
            surface.view.onKeyDown(
                KeyEvent.KEYCODE_TAB,
                KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB),
            ),
        )
        assertTrue(
            "Shift+Tab must send backtab on the KeyEvent path too",
            input.toByteArray().containsSlice(byteArrayOf(0x1B, 0x5B, 0x5A)),
        )

        input.reset()
        // A one-character paste is a single byte, but must neither be
        // transformed nor spend the armed modifier.
        surface.setSoftwareModifiers(SharedArmedModifiers(control = true))
        clipboard.setPrimaryClip(ClipData.newPlainText("terminal test", "c"))
        surface.pasteClipboard()
        val pastedBytes = input.toByteArray()
        assertTrue(pastedBytes.containsSlice("c".encodeToByteArray()))
        assertTrue("a paste must never be control-transformed", !pastedBytes.contains(0x03))
        assertTrue(inputConnection.commitText("c", 1))
        assertTrue(
            "the armed modifier survives a paste and encodes the next typed key",
            input.toByteArray().contains(0x03),
        )
        surface.setSoftwareModifiers(SharedArmedModifiers())

        // The IME composes words now that the terminal advertises a real text
        // field. A terminal cannot wait for a commit that a TUI would never
        // send, so each composition update must reach the pty immediately, and a
        // revision must take back only what it already sent.
        // A revision's deletions must reach the pty through the same synchronous
        // path as the replacement text, and BEFORE it. Deriving the oracle from
        // handleKeyCode — the call streamComposition makes — keeps this assertion
        // honest about ordering, which sendKeyEvent silently got wrong.
        input.reset()
        surface.view.handleKeyCode(KeyEvent.KEYCODE_DEL, 0)
        val oneBackspace = input.toByteArray().decodeToString()
        assertTrue("the delete key must produce bytes to diff against", oneBackspace.isNotEmpty())

        input.reset()
        assertTrue(inputConnection.setComposingText("h", 1))
        assertEquals("composition must reach the pty as it is typed", "h", input.toByteArray().decodeToString())

        input.reset()
        assertTrue(inputConnection.setComposingText("he", 1))
        assertEquals("only the new suffix may be sent", "e", input.toByteArray().decodeToString())

        input.reset()
        assertTrue(inputConnection.setComposingText("hi", 1))
        assertEquals(
            "a revision must delete before it writes, and write the diverging tail only",
            oneBackspace + "i",
            input.toByteArray().decodeToString(),
        )

        input.reset()
        assertTrue(inputConnection.commitText("hi", 1))
        assertEquals(
            "committing what was already streamed must not send it twice",
            "",
            input.toByteArray().decodeToString(),
        )

        input.reset()
        assertTrue(inputConnection.commitText("ok", 1))
        assertEquals(
            "a commit with no composition in flight is a plain send",
            "ok",
            input.toByteArray().decodeToString(),
        )

        surface.resize(132, 43)
        val resized = surface.snapshotNonSecretState()
        assertTrue(resized.columns == 132 && resized.rows == 43)
        assertTrue(sizes.contains(132 to 43))

        val batch = buildString {
            repeat(128) { row ->
                append("\u001b[38;5;")
                append(16 + row % 216)
                append("mrow-")
                append(row.toString().padStart(3, '0'))
                append(" abcdefghijklmnopqrstuvwxyz 0123456789\u001b[0m\r\n")
            }
        }.encodeToByteArray()
        val started = System.nanoTime()
        repeat(64) { surface.feed(batch) }
        val elapsedSeconds = (System.nanoTime() - started) / 1_000_000_000.0
        val throughputMiB = batch.size * 64 / 1_048_576.0 / elapsedSeconds

        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        surface.view.draw(Canvas(bitmap))
        val sampledColors = mutableMapOf<Int, Int>()
        for (y in 0 until height step 4) {
            for (x in 0 until width step 4) {
                val color = bitmap.getPixel(x, y)
                sampledColors[color] = (sampledColors[color] ?: 0) + 1
            }
        }
        val nonUniformPixels = sampledColors.values.sum() - (sampledColors.values.maxOrNull() ?: 0)
        assertTrue(sampledColors.size >= 4)
        assertTrue(nonUniformPixels > 100)

        surface.feed("\u001b[?1006l\u001b[?1000l\u001b[?1049l".encodeToByteArray())
        val restored = surface.snapshotNonSecretState()
        assertFalse(restored.alternateScreen)
        assertFalse(restored.mouseTracking)

        Log.i(
            "TesseraTerminal",
            "TESSERA_TERMINAL_VIEW_OK columns=${resized.columns} rows=${resized.rows} " +
                "inputBytes=${inputBytes.size} colors=${sampledColors.size} nonUniform=$nonUniformPixels " +
                "throughputMiB=${"%.2f".format(java.util.Locale.US, throughputMiB)}",
        )
        surface.close()
    }

    private fun ByteArray.containsSlice(needle: ByteArray): Boolean {
        if (needle.isEmpty()) return true
        return indices.any { start ->
            start + needle.size <= size && needle.indices.all { offset ->
                this[start + offset] == needle[offset]
            }
        }
    }

    /**
     * Scroll routing is the shared `TerminalScrollRouting` rule, not Termux's
     * mouse-first branch. A primary screen with mouse reporting on moves the
     * local transcript and emits nothing — the mosh+tmux visible client with
     * the server's `mouse on` must never enter copy-mode — unless the session
     * declared that mouse reporting stands in for the alternate screen (no
     * overlay to offer), in which case the wheel is reported; the alternate
     * screen without mouse reporting becomes arrow keys.
     */
    @Test
    fun scrollRoutingFollowsTheSharedScreenRuleNotMouseTrackingAlone() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent.makeMainActivity(
                ComponentName(instrumentation.context, TerminalTestActivity::class.java),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as TerminalTestActivity
        instrumentation.waitForIdleSync()
        val failure = AtomicReference<Throwable?>()
        val sent = ByteArrayOutputStream()
        lateinit var surface: TermuxTerminalSurface

        fun onMain(block: () -> Unit) {
            instrumentation.runOnMainSync {
                try {
                    block()
                } catch (error: Throwable) {
                    failure.set(error)
                }
            }
            failure.get()?.let { throw it }
        }

        fun wheelUp() {
            val now = SystemClock.uptimeMillis()
            val properties = MotionEvent.PointerProperties().apply {
                id = 0
                toolType = MotionEvent.TOOL_TYPE_MOUSE
            }
            val coords = MotionEvent.PointerCoords().apply {
                x = 300f
                y = 450f
                setAxisValue(MotionEvent.AXIS_VSCROLL, 1f)
            }
            val event = MotionEvent.obtain(
                now, now, MotionEvent.ACTION_SCROLL, 1, arrayOf(properties), arrayOf(coords),
                0, 0, 1f, 1f, 0, 0, android.view.InputDevice.SOURCE_MOUSE, 0,
            )
            try {
                assertTrue(surface.view.onGenericMotionEvent(event))
            } finally {
                event.recycle()
            }
        }

        fun sentText(): String = String(sent.toByteArray(), Charsets.ISO_8859_1)

        onMain {
            surface = TermuxTerminalSurface(activity)
            activity.setContentView(surface.view)
            surface.view.measure(
                View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.EXACTLY),
            )
            surface.view.layout(0, 0, 600, 900)
            surface.resize(60, 24)
            surface.onInput = { bytes -> sent.write(bytes) }
            repeat(240) { row -> surface.feed("history-$row\r\n".encodeToByteArray()) }
            surface.feed("\u001b[?1000h".encodeToByteArray())
            assertTrue(surface.view.mEmulator.isMouseTrackingActive)
            assertFalse(surface.view.mEmulator.isAlternateBufferActive)
        }

        // Primary screen + mouse reporting, with a local scrollback to offer: local.
        onMain {
            assertEquals(
                com.bambouville.tessera.core.bridge.SharedScrollRoute.LocalScrollback,
                surface.view.scrollRoute(),
            )
            val before = surface.view.topRow
            wheelUp()
            assertTrue(
                "local transcript must move: before=$before after=${surface.view.topRow}",
                surface.view.topRow < before,
            )
            assertEquals("no bytes may reach the remote: ${sentText()}", 0, sent.size())
        }

        // Same screen; the session says mouse reporting stands in for the alternate screen.
        onMain {
            surface.view.setMouseReportingImpliesAltScreen(true)
            assertEquals(
                com.bambouville.tessera.core.bridge.SharedScrollRoute.MouseWheel,
                surface.view.scrollRoute(),
            )
            val before = surface.view.topRow
            wheelUp()
            assertEquals(before, surface.view.topRow)
            assertTrue(sentText(), sentText().startsWith("\u001b[M"))
            sent.reset()
        }

        // Alternate screen without mouse reporting: arrow keys.
        onMain {
            surface.view.setMouseReportingImpliesAltScreen(false)
            surface.feed("\u001b[?1000l\u001b[?1049h".encodeToByteArray())
            assertTrue(surface.view.mEmulator.isAlternateBufferActive)
            assertEquals(
                com.bambouville.tessera.core.bridge.SharedScrollRoute.ArrowKeys,
                surface.view.scrollRoute(),
            )
            wheelUp()
            val keys = sentText()
            assertTrue(keys, keys.contains("\u001b[A") || keys.contains("\u001bOA"))
        }
    }

    @Test
    fun allMotionMouseModeSurvivesRepaintAndResizeWithoutSendingComposerKeys() = withSizedSurface { surface ->
        val sent = ByteArrayOutputStream()
        surface.onInput = { sent.write(it) }
        val evidence = java.io.File(
            InstrumentationRegistry.getInstrumentation().targetContext.filesDir,
            "mouse-mode-recovery",
        ).apply { mkdirs() }
        val results = StringBuilder("stage,tracking,route,wire\n")
        fun checkWheel(stage: String) {
            sent.reset()
            wheelUp(surface, 40f, 80f)
            val route = surface.view.scrollRoute()
            val wire = sent.toWireText()
            results.append("$stage,${surface.view.mEmulator.isMouseTrackingActive},$route,")
                .append(sent.toByteArray().joinToString("") { "%02x".format(it) }).append('\n')
            java.io.File(evidence, "routing.csv").writeText(results.toString())
            val frame = Bitmap.createBitmap(surface.view.width, surface.view.height, Bitmap.Config.ARGB_8888)
            surface.view.draw(Canvas(frame))
            java.io.File(evidence, "$stage.png").outputStream().use {
                frame.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            frame.recycle()
            assertEquals(stage, com.bambouville.tessera.core.bridge.SharedScrollRoute.MouseWheel, route)
            assertTrue("$stage must send only SGR wheels: $wire", wire.isNotEmpty() &&
                Regex("\\u001b\\[<64;\\d+;\\d+M").replace(wire, "").isEmpty())
        }

        // A reattached Codex pane can report only 1003, even though its initial
        // startup requested 1000, 1002 and 1003. The capture restores that mode
        // without the initial startup bytes being replayed.
        surface.feed(("\u001b[?1049h\u001b[2J\u001b[H" +
            (1..18).joinToString("\r\n") { "TRANSCRIPT_ROW_%03d".format(it) } +
            "\r\nKEEP MY DRAFT\u001b[?1003h\u001b[?1006h").encodeToByteArray())
        checkWheel("fresh-surface")
        surface.resize(56, 30)
        checkWheel("resized-surface")
        surface.feed("\u001b[?1003s\u001b[?1003l\u001b[?1003r".encodeToByteArray())
        checkWheel("saved-mode-restored")
        surface.feed(("\u001b[?1003l\u001b[?1002l\u001b[?1000l\u001b[?1006l" +
            "\u001b[?1003h\u001b[?1006h").encodeToByteArray())
        checkWheel("repaint-mode-restored")

        val emulator = surface.view.mEmulator
        sent.reset()
        emulator.sendMouseEvent(TerminalEmulator.MOUSE_LEFT_BUTTON_MOVED, 7, 9, true)
        assertEquals("\u001b[<32;7;9M", sent.toWireText())
        sent.reset()
        emulator.sendMouseEvent(TerminalEmulator.MOUSE_MOVED, 7, 9, true)
        assertEquals("\u001b[<35;7;9M", sent.toWireText())
        surface.feed("\u001b[?1000h\u001b[?1003l".encodeToByteArray())
        sent.reset()
        emulator.sendMouseEvent(TerminalEmulator.MOUSE_LEFT_BUTTON_MOVED, 7, 9, true)
        assertEquals("Press-only mode must suppress drag reports", "", sent.toWireText())
        emulator.sendMouseEvent(TerminalEmulator.MOUSE_MOVED, 7, 9, true)
        assertEquals("Press-only mode must suppress hover reports", "", sent.toWireText())
        surface.feed("\u001b[?1002h\u001b[?1000l".encodeToByteArray())
        sent.reset()
        emulator.sendMouseEvent(TerminalEmulator.MOUSE_LEFT_BUTTON_MOVED, 7, 9, true)
        assertEquals("\u001b[<32;7;9M", sent.toWireText())
        sent.reset()
        emulator.sendMouseEvent(TerminalEmulator.MOUSE_MOVED, 7, 9, true)
        assertEquals("Button-motion mode must suppress hover reports", "", sent.toWireText())
        surface.feed("\u001b[?1002l\u001b[?1003l".encodeToByteArray())
        assertFalse(emulator.isMouseTrackingActive)
        assertEquals(com.bambouville.tessera.core.bridge.SharedScrollRoute.ArrowKeys, surface.view.scrollRoute())
        for (mode in listOf(1000, 1002, 1003)) {
            surface.feed("\u001b[?${mode}s\u001b[?${mode}h\u001b[?${mode}r".encodeToByteArray())
            assertFalse("Restoring a saved disabled $mode must keep tracking off", emulator.isMouseTrackingActive)
            surface.feed("\u001b[?${mode}h\u001b[?${mode}s\u001b[?${mode}l\u001b[?${mode}r".encodeToByteArray())
            assertTrue("Restoring a saved enabled $mode must restore tracking", emulator.isMouseTrackingActive)
            surface.feed("\u001b[?${mode}l".encodeToByteArray())
        }
    }

    @Test
    fun allMotionHoverReportsOnlyTheLiveUnselectedMouseSurface() = withSizedSurface { surface ->
        val view = surface.view
        val sent = ByteArrayOutputStream()
        surface.onInput = { sent.write(it) }
        surface.feed("\u001b[?1049h\u001b[?1003h\u001b[?1006h".encodeToByteArray())
        fun hover(source: Int = android.view.InputDevice.SOURCE_MOUSE): MotionEvent {
            val now = SystemClock.uptimeMillis()
            val properties = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_MOUSE }
            val coordinates = MotionEvent.PointerCoords().apply {
                x = (view.getPointX(7) + view.getPointX(8)) / 2f
                y = (view.getPointY(8) + view.getPointY(9)) / 2f
            }
            return MotionEvent.obtain(now, now, MotionEvent.ACTION_HOVER_MOVE, 1,
                arrayOf(properties), arrayOf(coordinates), 0, 0, 1f, 1f, 0, 0, source, 0)
        }
        fun dispatch(source: Int = android.view.InputDevice.SOURCE_MOUSE): Boolean {
            sent.reset()
            val event = hover(source)
            return try { view.dispatchGenericMotionEvent(event) } finally { event.recycle() }
        }
        assertTrue(dispatch())
        assertEquals("\u001b[<35;8;9M", sent.toWireText())
        for (mode in listOf(1000, 1002)) {
            surface.feed("\u001b[?${mode}h".encodeToByteArray())
            assertTrue(dispatch())
            assertEquals("Mode $mode must suppress unpressed motion", "", sent.toWireText())
        }
        surface.feed("\u001b[?1003h".encodeToByteArray())
        assertFalse(dispatch(android.view.InputDevice.SOURCE_TOUCHSCREEN))
        assertEquals("", sent.toWireText())
        view.topRow = -1
        assertFalse(dispatch())
        assertEquals("History must not forward hover to the hidden program", "", sent.toWireText())
        view.topRow = 0
        val select = hover()
        try { view.startTextSelectionMode(select) } finally { select.recycle() }
        assertTrue(view.isSelectingText)
        assertFalse(dispatch())
        assertEquals("Selection must not forward hover", "", sent.toWireText())
        // Native selection ignores dismissals during its first 300 ms.
        SystemClock.sleep(310)
        view.stopTextSelectionMode()
        assertFalse(view.isSelectingText)
        assertTrue(dispatch())
        assertEquals("\u001b[<35;8;9M", sent.toWireText())
    }

    @Test
    fun remoteAlternateMousePaneRoutesFingerDragsAndWheelToPaneCell() = withRemotePaneSurface { surface, sent ->
        val view = surface.view
        val pane = RemoteTmuxPane(alternateScreen = true, mouseReporting = true, column = 7, row = 9)
        surface.setRemoteTmuxPane(pane)
        assertEquals(com.bambouville.tessera.core.bridge.SharedScrollRoute.MouseWheel, view.scrollRoute())
        val liveRow = view.topRow

        dragFinger(surface, 520f, 160f)
        assertOnlyRepeatedReport(sent, "\u001b[<65;7;9M")
        assertEquals(liveRow, view.topRow)
        sent.reset()

        dragFinger(surface, 160f, 520f)
        assertOnlyRepeatedReport(sent, "\u001b[<64;7;9M")
        assertEquals(liveRow, view.topRow)
        sent.reset()

        wheelUp(surface, 40f, 80f)
        assertEquals("\u001b[<64;7;9M".repeat(3), sent.toWireText())
        assertEquals(liveRow, view.topRow)
    }

    @Test
    fun remoteAlternateMousePaneDefaultsWheelTargetToScreenCentre() = withRemotePaneSurface { surface, sent ->
        val view = surface.view
        surface.setRemoteTmuxPane(RemoteTmuxPane(alternateScreen = true, mouseReporting = true))
        assertEquals(com.bambouville.tessera.core.bridge.SharedScrollRoute.MouseWheel, view.scrollRoute())
        val emulator = view.mEmulator
        val report = "\u001b[<64;${(emulator.mColumns + 1) / 2};${(emulator.mRows + 1) / 2}M"

        wheelUp(surface, 40f, 80f)
        assertEquals(report.repeat(3), sent.toWireText())
        assertEquals(0, view.topRow)
    }

    @Test
    fun remoteAlternatePaneWithoutMouseRoutesFingerDragsToArrowKeys() = withRemotePaneSurface { surface, sent ->
        val view = surface.view
        surface.setRemoteTmuxPane(RemoteTmuxPane(alternateScreen = true, mouseReporting = false))
        assertEquals(com.bambouville.tessera.core.bridge.SharedScrollRoute.ArrowKeys, view.scrollRoute())

        dragFinger(surface, 520f, 160f)
        assertOnlyRepeatedArrowKey(sent, 'B')
        assertEquals(0, view.topRow)
        sent.reset()

        dragFinger(surface, 160f, 520f)
        assertOnlyRepeatedArrowKey(sent, 'A')
        assertEquals(0, view.topRow)
    }

    @Test
    fun remotePrimaryMousePaneKeepsLocalDragAndReportsLiveFingerAndMouseClicks() = withRemotePaneSurface { surface, sent ->
        val view = surface.view
        surface.setRemoteTmuxPane(RemoteTmuxPane(alternateScreen = false, mouseReporting = true))
        assertEquals(com.bambouville.tessera.core.bridge.SharedScrollRoute.LocalScrollback, view.scrollRoute())

        dragFinger(surface, 160f, 520f)
        assertTrue("finger drag must enter local history", view.topRow < 0)
        assertEquals("", sent.toWireText())

        val x = 180f
        val y = 260f
        // Local history on screen: a click would land on the program's
        // unrelated live rows.
        tapPointer(surface, x, y, MotionEvent.TOOL_TYPE_FINGER, android.view.InputDevice.SOURCE_TOUCHSCREEN)
        tapPointer(surface, x, y, MotionEvent.TOOL_TYPE_MOUSE, android.view.InputDevice.SOURCE_MOUSE)
        assertEquals("", sent.toWireText())

        view.followLiveOutput()
        SystemClock.sleep(400) // past the double-tap window
        val cellEvent = MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, x, y, 0)
        val cell = try { view.getColumnAndRow(cellEvent, false) } finally { cellEvent.recycle() }
        val column = cell[0] + 1
        val row = cell[1] + 1
        assertTrue(column in 1..view.mEmulator.mColumns)
        assertTrue(row in 1..view.mEmulator.mRows)
        val click = "\u001b[<0;$column;${row}M\u001b[<0;$column;${row}m"

        tapPointer(surface, x, y, MotionEvent.TOOL_TYPE_FINGER, android.view.InputDevice.SOURCE_TOUCHSCREEN)
        assertEquals(click, sent.toWireText())
        sent.reset()

        tapPointer(surface, x, y, MotionEvent.TOOL_TYPE_MOUSE, android.view.InputDevice.SOURCE_MOUSE)
        assertEquals(click, sent.toWireText())
    }

    @Test
    fun remoteAlternatePaneReturnsHistoryToLiveAndClearingItRestoresLocalDrag() = withRemotePaneSurface { surface, sent ->
        val view = surface.view
        view.topRow = -12
        surface.setRemoteTmuxPane(RemoteTmuxPane(alternateScreen = true, mouseReporting = true))
        assertEquals(0, view.topRow)
        assertEquals(com.bambouville.tessera.core.bridge.SharedScrollRoute.MouseWheel, view.scrollRoute())

        surface.setRemoteTmuxPane(null)
        assertEquals(com.bambouville.tessera.core.bridge.SharedScrollRoute.LocalScrollback, view.scrollRoute())
        dragFinger(surface, 160f, 520f)
        assertTrue("primary-screen drag must enter local history after clearing pane", view.topRow < 0)
        assertEquals("", sent.toWireText())
    }

    private fun withRemotePaneSurface(block: (TermuxTerminalSurface, ByteArrayOutputStream) -> Unit) =
        withSizedSurface { surface ->
            val sent = ByteArrayOutputStream()
            surface.onInput = { bytes -> sent.write(bytes) }
            repeat(240) { row -> surface.feed("history-$row\r\n".encodeToByteArray()) }
            val emulator = surface.view.mEmulator
            assertFalse(emulator.isAlternateBufferActive)
            assertFalse(emulator.isMouseTrackingActive)
            assertTrue(emulator.screen.activeTranscriptRows > 0)
            assertEquals(0, surface.view.topRow)
            sent.reset()
            block(surface, sent)
        }

    private fun ByteArrayOutputStream.toWireText(): String = String(toByteArray(), Charsets.ISO_8859_1)

    private fun assertOnlyRepeatedReport(sent: ByteArrayOutputStream, report: String) {
        val actual = sent.toWireText()
        assertTrue("expected only repeated $report, got $actual", actual.isNotEmpty() && actual.replace(report, "").isEmpty())
    }

    private fun assertOnlyRepeatedArrowKey(sent: ByteArrayOutputStream, direction: Char) {
        val actual = sent.toWireText()
        val withoutKeys = actual.replace("\u001b[$direction", "").replace("\u001bO$direction", "")
        assertTrue("expected only $direction arrow keys, got $actual", actual.isNotEmpty() && withoutKeys.isEmpty())
    }

    private fun dragFinger(surface: TermuxTerminalSurface, startY: Float, endY: Float) {
        val downTime = SystemClock.uptimeMillis()
        val x = 300f
        dispatchPointer(surface, downTime, downTime, MotionEvent.ACTION_DOWN, x, startY,
            MotionEvent.TOOL_TYPE_FINGER, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0)
        for (step in 1..6) {
            SystemClock.sleep(20)
            val y = startY + (endY - startY) * step / 6
            dispatchPointer(surface, downTime, SystemClock.uptimeMillis(), MotionEvent.ACTION_MOVE, x, y,
                MotionEvent.TOOL_TYPE_FINGER, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0)
        }
        SystemClock.sleep(20)
        dispatchPointer(surface, downTime, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, endY,
            MotionEvent.TOOL_TYPE_FINGER, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0)
    }

    private fun tapPointer(surface: TermuxTerminalSurface, x: Float, y: Float, tool: Int, source: Int) {
        val downTime = SystemClock.uptimeMillis()
        val downButtons = if (tool == MotionEvent.TOOL_TYPE_MOUSE) MotionEvent.BUTTON_PRIMARY else 0
        dispatchPointer(surface, downTime, downTime, MotionEvent.ACTION_DOWN, x, y, tool, source, downButtons)
        SystemClock.sleep(12)
        dispatchPointer(surface, downTime, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, y, tool, source, 0)
    }

    private fun dispatchPointer(
        surface: TermuxTerminalSurface, downTime: Long, eventTime: Long, action: Int,
        x: Float, y: Float, tool: Int, source: Int, buttons: Int,
    ) {
        val properties = MotionEvent.PointerProperties().apply { id = 0; toolType = tool }
        val coords = MotionEvent.PointerCoords().apply { this.x = x; this.y = y }
        val event = MotionEvent.obtain(downTime, eventTime, action, 1, arrayOf(properties), arrayOf(coords),
            0, buttons, 1f, 1f, 0, 0, source, 0)
        try {
            assertTrue(surface.view.onTouchEvent(event))
        } finally {
            event.recycle()
        }
    }

    private fun wheelUp(surface: TermuxTerminalSurface, x: Float, y: Float) {
        val now = SystemClock.uptimeMillis()
        val properties = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_MOUSE }
        val coords = MotionEvent.PointerCoords().apply {
            this.x = x
            this.y = y
            setAxisValue(MotionEvent.AXIS_VSCROLL, 1f)
        }
        val event = MotionEvent.obtain(now, now, MotionEvent.ACTION_SCROLL, 1,
            arrayOf(properties), arrayOf(coords), 0, 0, 1f, 1f, 0, 0,
            android.view.InputDevice.SOURCE_MOUSE, 0)
        try {
            assertTrue(surface.view.onGenericMotionEvent(event))
        } finally {
            event.recycle()
        }
    }

    @Test
    fun mediaControlSymbolsRenderAsOneCellTextGlyphsInThePenColour() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent.makeMainActivity(
                ComponentName(instrumentation.context, TerminalTestActivity::class.java),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as TerminalTestActivity
        instrumentation.waitForIdleSync()
        val failure = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync {
            try {
                // "\u23FA\u23F5" is what Claude Code prints for a tool row and for its
                // "auto mode on" status line. The bundled face has no glyph for either, so
                // the renderer measures the device's fallback chain and draws a text twin
                // ("\u25CF\u25B6") wherever the chain would misdraw the original: a colour
                // emoji tile squeezed into half a cell, or a .notdef box. Whichever way the
                // measurement goes on this device, the row must come out as real glyphs in
                // the pen colour.
                val marker = "\u23FA\u23F5"
                val probe = TermuxTerminalSurface(activity)
                val renderer = probe.view.mRenderer
                val presented = String(CharArray(marker.length) { renderer.presentationOf(marker[it]) })
                probe.close()
                for (c in presented) {
                    assertTrue("U+%04X must be drawn as a real glyph, not .notdef".format(c.code), renderer.hasGlyph(c))
                }

                // White pen on black, cursor hidden, so every pixel of a text glyph is a
                // grey blend and a colour emoji tile is not.
                val prologue = "\u001b[?25l\u001b[38;2;255;255;255m\u001b[48;2;0;0;0m"
                val drawn = renderRows(activity, prologue + marker)
                val twin = renderRows(activity, prologue + presented)
                assertTrue(
                    "the drawn row must equal the row of what the renderer decided to draw",
                    drawn.sameAs(twin),
                )
                val pixels = IntArray(drawn.width * drawn.height)
                drawn.getPixels(pixels, 0, drawn.width, 0, 0, drawn.width, drawn.height)
                assertTrue("the symbols must leave ink", pixels.any { Color.red(it) > 96 })
                // Only ink is judged: the surface's own default background may be a
                // tinted dark colour, and a colour emoji tile is bright.
                val tinted = pixels.count { pixel ->
                    val r = Color.red(pixel)
                    val g = Color.green(pixel)
                    val b = Color.blue(pixel)
                    maxOf(r, g, b) > 64 && maxOf(r, g, b) - minOf(r, g, b) > 24
                }
                assertEquals("text presentation draws in the pen colour only; tinted pixels", 0, tinted)
                drawn.recycle()
                twin.recycle()

                val surface = TermuxTerminalSurface(activity)
                surface.resize(24, 4)
                surface.feed("\u23FA Bash(x)".encodeToByteArray())
                val snapshot = requireNotNull(surface.snapshotText())
                assertTrue(
                    "substitution is a rendering decision; the emulator keeps the host's code point",
                    snapshot.visibleText.contains("\u23FA"),
                )
                surface.close()
            } catch (error: Throwable) {
                failure.set(error)
            } finally {
                activity.finish()
            }
        }
        failure.get()?.let { throw it }
    }

    /** Runs [block] on a real, laid-out external Termux session on the main thread. */
    private fun withSizedSurface(block: (TermuxTerminalSurface) -> Unit) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent.makeMainActivity(
                ComponentName(instrumentation.context, TerminalTestActivity::class.java),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as TerminalTestActivity
        instrumentation.waitForIdleSync()
        val failure = AtomicReference<Throwable?>()

        instrumentation.runOnMainSync {
            var surface: TermuxTerminalSurface? = null
            try {
                val createdSurface = TermuxTerminalSurface(activity)
                surface = createdSurface
                activity.setContentView(createdSurface.view)
                createdSurface.view.measure(
                    View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.EXACTLY),
                )
                createdSurface.view.layout(0, 0, 600, 900)
                createdSurface.resize(60, 24)
                block(createdSurface)
            } catch (error: Throwable) {
                failure.set(error)
            } finally {
                surface?.close()
                activity.finish()
            }
        }
        failure.get()?.let { throw it }
    }

    /** Draws [text] on its own terminal surface and returns the rendered pixels. */
    private fun renderRows(activity: Activity, text: String): Bitmap {
        val surface = TermuxTerminalSurface(activity)
        surface.resize(24, 4)
        surface.view.measure(
            View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(200, View.MeasureSpec.EXACTLY),
        )
        surface.view.layout(0, 0, 480, 200)
        surface.feed(text.encodeToByteArray())
        val rendered = Bitmap.createBitmap(480, 200, Bitmap.Config.ARGB_8888)
        surface.view.draw(Canvas(rendered))
        surface.close()
        return rendered
    }
}

class TerminalTestActivity : Activity() {
    // Fresh-AVD configuration changes recreate this activity; the lanes keep
    // TerminalView:I logcat, so these lines explain a surface that stops drawing.
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        android.util.Log.i("TerminalView", "test activity created ${hashCode()} restored=${savedInstanceState != null}")
    }

    override fun onDestroy() {
        android.util.Log.i("TerminalView", "test activity destroyed ${hashCode()} changing=$isChangingConfigurations")
        super.onDestroy()
    }
}
