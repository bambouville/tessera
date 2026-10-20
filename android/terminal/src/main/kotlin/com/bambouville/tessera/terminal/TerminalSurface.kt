package com.bambouville.tessera.terminal

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Typeface
import android.os.Looper
import android.util.Log
import android.util.TypedValue
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewTreeObserver
import android.view.inputmethod.InputMethodManager
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.bambouville.tessera.core.bridge.SharedArmedModifiers
import com.bambouville.tessera.core.bridge.SharedInputEncoding
import com.bambouville.tessera.core.bridge.SharedModifierArming
import com.bambouville.tessera.core.bridge.SharedModifierArmingEvent
import com.bambouville.tessera.core.bridge.SharedModifierBehavior
import com.bambouville.tessera.core.bridge.SharedSessionPolicy
import com.bambouville.tessera.core.bridge.SharedScrollRoute
import com.termux.terminal.TerminalColors
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.terminal.TextStyle
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import androidx.core.content.res.ResourcesCompat
import androidx.core.graphics.toColorInt
import java.net.URI

data class TerminalTheme(
    val id: String,
    val foreground: String,
    val background: String,
    val cursor: String,
    /** ANSI 0...15. The 256-color cube remains Termux's standard xterm palette. */
    val ansi: List<String>,
) {
    constructor(foreground: String, background: String, cursor: String) : this(
        id = "custom",
        foreground = foreground,
        background = background,
        cursor = cursor,
        ansi = DEFAULT_ANSI,
    )

    val backgroundArgb: Int get() = parseColor(background)

    fun termuxPalette(): IntArray {
        val palette = TerminalColors.copyBootstrapColors()
        ansi.forEachIndexed { index, color -> palette[index] = parseColor(color) }
        palette[TextStyle.COLOR_INDEX_FOREGROUND] = parseColor(foreground)
        palette[TextStyle.COLOR_INDEX_BACKGROUND] = parseColor(background)
        palette[TextStyle.COLOR_INDEX_CURSOR] = parseColor(cursor)
        return palette
    }

    companion object {
        val Void = theme(
            "void", "#D4D4D4", "#000000", "#5B9FFF",
            "#000000", "#CD3131", "#0DBC79", "#E5E510", "#2472C8", "#BC3FBC", "#11A8CD", "#E5E5E5",
            "#666666", "#F14C4C", "#23D18B", "#F5F543", "#3B8EEA", "#D670D6", "#29B8DB", "#E5E5E5",
        )
        val Graphite = theme(
            "graphite", "#EEEEEE", "#1C1C1E", "#30D158",
            "#000000", "#990000", "#00A600", "#999900", "#0000B2", "#B200B2", "#00A6B2", "#BFBFBF",
            "#666666", "#E50000", "#00D900", "#E5E500", "#0000FF", "#E500E5", "#00E5E5", "#E5E5E5",
        )
        val Amber = theme(
            "amber", "#FFB000", "#0A0600", "#FFB000",
            "#1A1000", "#B07300", "#B07300", "#FFB000", "#B07300", "#FFB000", "#B07300", "#FFB000",
            "#503500", "#FFB000", "#FFB000", "#FFCB42", "#FFB000", "#FFCB42", "#FFB000", "#FFCB42",
        )
        val Paper = theme(
            "paper", "#111111", "#FAFAFA", "#0066CC",
            "#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
            "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
        )
        val Dracula = theme(
            "dracula", "#F8F8F2", "#282A36", "#BD93F9",
            "#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
            "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF",
        )
        val Nord = theme(
            "nord", "#D8DEE9", "#2E3440", "#88C0D0",
            "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
            "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4",
        )

        val all = listOf(Void, Graphite, Amber, Paper, Dracula, Nord)
        fun fromId(id: String): TerminalTheme = all.firstOrNull { it.id == id } ?: Void

        private val DEFAULT_ANSI = listOf(
            "#000000", "#CD0000", "#00CD00", "#CDCD00", "#6495ED", "#CD00CD", "#00CDCD", "#E5E5E5",
            "#7F7F7F", "#FF0000", "#00FF00", "#FFFF00", "#5C5CFF", "#FF00FF", "#00FFFF", "#FFFFFF",
        )
        private fun theme(id: String, foreground: String, background: String, cursor: String, vararg ansi: String) =
            TerminalTheme(id, foreground, background, cursor, ansi.toList())
        private fun parseColor(hex: String): Int = hex.toColorInt()
    }
}

enum class TerminalCursorStyle(val persistedValue: String, val termuxStyle: Int) {
    Block("block", TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK),
    Bar("bar", TerminalEmulator.TERMINAL_CURSOR_STYLE_BAR),
    Underline("underline", TerminalEmulator.TERMINAL_CURSOR_STYLE_UNDERLINE),
    ;

    companion object {
        fun fromPersisted(value: String): TerminalCursorStyle =
            entries.firstOrNull { it.persistedValue == value } ?: Block
    }
}

data class TerminalFont(
    val sizeSp: Int,
    /** Null keeps the surface's bundled JetBrains Mono face while changing size. */
    val typeface: Typeface? = null,
)

data class TerminalSelection(val text: String)
data class TerminalTextSnapshot(
    val visibleText: String,
    val currentLine: String?,
    val physicalRows: List<String>? = null,
    val cursorRow: Int? = null,
    val cursorVisible: Boolean? = null,
    val cursorColumn: Int? = null,
    /** Immutable cell evidence; provider interpretation remains in shared Core. */
    val screenEvidence: com.bambouville.tessera.core.bridge.SharedTerminalScreenEvidence? = null,
    val framePending: Boolean = false,
)

enum class TerminalSelectionPathAction { QuickOpen, RevealInFiles }

/**
 * The one tmux window/pane/continuity generation allowed to populate a render
 * surface. This is the terminal-seam projection of the shared render ledger's
 * owner, extended with the Android transport-lifetime namespace.
 */
data class RenderOwner(
    val windowId: Int,
    val paneId: Int,
    /** Epoch issued by the shared render ledger. */
    val epoch: Long,
    /**
     * Monotonic Android transport generation that names a particular shared
     * tmux-runtime lifetime. The shared runtime can restart its own ledger
     * epoch at zero; including this namespace prevents an identically shaped
     * replacement owner from becoming a terminal-bind no-op.
     *
     * The default preserves standalone surface callers. Controller-owned
     * render feeds always provide the live transport generation.
     */
    val transportGeneration: Long = 0,
)

/** The level of terminal mouse reporting the platform can presently observe. */
enum class TerminalMouseMode { Off, Tracking }

/**
 * The active tmux pane behind a mosh+tmux client, as the side channel reports
 * it: whether its program is on the alternate screen and asked for the mouse.
 * [column] and [row] are the 1-based client cell wheel reports aim at, inside
 * that pane; zero aims at the centre of the screen.
 */
data class RemoteTmuxPane(
    val alternateScreen: Boolean,
    val mouseReporting: Boolean,
    val column: Int = 0,
    val row: Int = 0,
)

data class TerminalGridMetrics(
    val cellWidthPixels: Float,
    val cellHeightPixels: Int,
    val firstBaselineInsetPixels: Int,
) {
    // Keep the product from rounding down to an integer before ceil.
    fun pixelWidth(columns: Int): Int = kotlin.math.ceil(columns.toDouble() * cellWidthPixels.toDouble()).toInt()
    fun pixelHeight(rows: Int): Int = rows * cellHeightPixels + firstBaselineInsetPixels

    fun columnsFor(pixelWidth: Int): Int =
        kotlin.math.floor(pixelWidth / cellWidthPixels).toInt().coerceAtLeast(1)

    fun rowsFor(pixelHeight: Int): Int =
        ((pixelHeight - firstBaselineInsetPixels) / cellHeightPixels).coerceAtLeast(1)
}
data class TerminalSearchResult(val current: Int, val total: Int)

data class TerminalSurfaceState(
    val columns: Int,
    val rows: Int,
    val alternateScreen: Boolean,
    val mouseTracking: Boolean,
    val mouseMode: TerminalMouseMode,
    val focused: Boolean,
    val cursorRow: Int,
    val cursorColumn: Int,
    val cursorVisible: Boolean,
    val topRow: Int,
    val bracketedPaste: Boolean,
)

interface TerminalSurface {
    val view: TerminalView
    val hasRenderedOutput: Boolean
    /**
     * Content-free IME trace (operation names, lengths, offsets, mirror
     * shape). Null disables it. Typed text never passes through here.
     */
    var imeTraceSink: ((String) -> Unit)?
        get() = null
        set(_) {}
    /** The ledger owner permitted to paint this surface, or null while the ledger is idle. */
    val boundOwner: RenderOwner?
    /** Number of feeds refused because they were not authorized for [boundOwner]. */
    val droppedForeignFeeds: Int
    /** Whether the authenticated raw transport painter may use `feed(null, …)`. */
    val painterFeedsAdmitted: Boolean

    /**
     * Bind a new render owner. A different owner must begin with an empty
     * scrollback; rebinding the current owner is deliberately a no-op.
     */
    fun bind(owner: RenderOwner)

    /**
     * Admits or rejects untagged transport-painter bytes. Grid, inline, and
     * detached-overlay surfaces must leave this false; only an actual plain
     * SSH or mosh visible painter may enable it.
     */
    fun setPainterFeedAdmission(admitted: Boolean)

    /**
     * Feed bytes from [owner]. Null denotes the transport painter (plain SSH
     * or mosh) and is accepted only while [painterFeedsAdmitted] is true. A
     * mosh SSP painter can remain admitted alongside side-channel history with
     * an owner. Tagged bytes are accepted only from the currently bound owner.
     */
    fun feed(owner: RenderOwner?, bytes: ByteArray): Boolean

    /** Backward-compatible shorthand for an untagged transport-painter feed. */
    fun feed(bytes: ByteArray): Boolean = feed(owner = null, bytes = bytes)
    fun resize(columns: Int, rows: Int)
    fun requestFullRepaint()
    fun setTheme(theme: TerminalTheme)
    /**
     * Installs a picture behind default terminal cells. Explicit ANSI cell backgrounds remain
     * opaque, matching the iTerm2/iOS composition model. Null restores the solid theme canvas.
     */
    fun setBackgroundImage(background: TerminalBackgroundImage?)
    fun setCursorAppearance(style: TerminalCursorStyle, blink: Boolean)
    fun setFont(font: TerminalFont)
    fun setFocused(focused: Boolean)
    /**
     * Declares whether mouse reporting stands in for the alternate screen when
     * a scroll is routed (the shared `TerminalScrollRouting` rule): true only
     * while the session has no local scrollback to offer — plain mosh, or
     * mosh+tmux before its pane grid — so the wheel reaches the remote program.
     * False keeps a mosh+tmux swipe on the local overlay even with the
     * server's `mouse on` in force.
     */
    fun setMouseReportingImpliesAltScreen(implies: Boolean)
    /**
     * mosh+tmux only: the side channel's report of the active pane's modes
     * (mosh never relays the alternate screen, and the pane's mouse mode can
     * be missing from the visible tmux client).
     * An alternate screen routes swipes and wheels the way the shared scroll
     * rule routes one; mouse reporting forwards clicks. Null for every other
     * session, and while the pane asked for neither.
     */
    fun setRemoteTmuxPane(pane: RemoteTmuxPane?)
    fun snapshotNonSecretState(): TerminalSurfaceState
    fun caretClearance(): TerminalCaretClearance?
    /** Bounded, in-memory screen evidence for an already authorized action. */
    fun snapshotText(): TerminalTextSnapshot?
    fun pasteClipboard()
    fun sendInput(bytes: ByteArray)

    /**
     * Publishes the accessory bar's armed modifiers and how long they survive.
     *
     * The bar owns the state; this surface owns applying it to the bytes an
     * ordinary typed key produces, through the shared encoder.
     */
    fun setSoftwareModifiers(
        armed: SharedArmedModifiers,
        behavior: SharedModifierBehavior = SharedModifierBehavior.OneShot,
    )
    fun requestSoftwareKeyboard()
    fun toggleSoftwareKeyboard()

    /**
     * Makes this surface the input target without touching keyboard
     * visibility. Accessory-bar tiles send their bytes through it while the
     * software keyboard is down; a tile tap must never summon the keyboard,
     * and must never dismiss one the user already raised.
     */
    fun focusForInput()
    fun find(query: String, forward: Boolean = true): TerminalSearchResult?
    fun close()

    var onInput: ((ByteArray) -> Unit)?
    var onResize: ((Int, Int) -> Unit)?
    var onSelectionChanged: ((TerminalSelection?) -> Unit)?
    var isRemotePathSelection: ((String) -> Boolean)?
    var onSelectionPathAction: ((TerminalSelectionPathAction, String) -> Unit)?
    var onTitleChanged: ((String?) -> Unit)?
    /** OSC 7 path for the currently displayed remote shell, when available. */
    var onHostDirectoryChanged: ((String?) -> Unit)?
    /** Fired for each BEL parsed by the terminal emulator, after terminal state is updated. */
    var onBell: (() -> Unit)?
    /**
     * Fired after a key event spent the armed modifiers, carrying what is
     * still armed afterwards — empty under one-shot, unchanged under sticky.
     */
    var onSoftwareModifiersConsumed: ((SharedArmedModifiers) -> Unit)?
    var onFontSizeChanged: ((Int) -> Unit)?
    /** Requests that the host show the IME after a direct terminal tap. */
    var onSoftwareKeyboardRequested: (() -> Unit)?
    /** Fired once after remote output is drawn into an attached, laid-out view. */
    var onFirstOutputRendered: (() -> Unit)?
}

/**
 * Tessera's remote-session adapter around the pinned Termux emulator and Android View.
 *
 * The upstream TerminalSession owns a local PTY. Tessera's narrow fork adds an external-session
 * constructor so transport bytes and resizes stay behind this interface and no local subprocess or
 * Termux JNI library is loaded.
 */
class TermuxTerminalSurface(
    context: Context,
    transcriptRows: Int = DEFAULT_TRANSCRIPT_ROWS,
    initialFontSizeSp: Int = DEFAULT_TEXT_SIZE_SP,
    initialTheme: TerminalTheme = TerminalTheme.Void,
    initialCursorStyle: TerminalCursorStyle = TerminalCursorStyle.Block,
    initialCursorBlink: Boolean = true,
    /**
     * Face to render the grid with. Null keeps the bundled JetBrains Mono,
     * which is both the app default and the only sensible fallback for
     * harnesses and tests. Passing the user's choice here rather than through a
     * follow-up [setFont] matters: [setFont] calls `requestLayout`, so arriving
     * late costs a second measure pass and, once a transport is attached, a
     * second resize on the wire.
     */
    initialTypeface: Typeface? = null,
    private val terminalBackgroundStore: TerminalBackgroundImageStore = TerminalBackgroundImageStore(context),
) : TerminalSurface {
    override val view = TerminalView(context, null)
    override val hasRenderedOutput: Boolean get() = outputRendered
    override var imeTraceSink: ((String) -> Unit)? = null
        set(value) {
            field = value
            view.setImeTraceSink(value?.let { sink -> java.util.function.Consumer<String> { sink(it) } })
        }
    override var boundOwner: RenderOwner? = null
        private set
    override var droppedForeignFeeds: Int = 0
        private set
    override var painterFeedsAdmitted: Boolean = true
        private set
    internal val backgroundArgb: Int get() = theme.backgroundArgb

    override fun setMouseReportingImpliesAltScreen(implies: Boolean) {
        requireMainThread()
        view.setMouseReportingImpliesAltScreen(implies)
    }

    override fun setRemoteTmuxPane(pane: RemoteTmuxPane?) {
        requireMainThread()
        view.setRemoteTmuxPane(pane)
    }

    override fun snapshotText(): TerminalTextSnapshot? {
        requireMainThread()
        val emulator = view.mEmulator ?: return null
        if (emulator.isSynchronizedOutputPending) return TerminalTextSnapshot("", null, framePending = true)
        val columns = emulator.mColumns
        val rows = emulator.mRows
        if (rows <= 0 || columns <= 0 || columns > 65_536 / rows) return null
        val physical = (0 until rows).map { row -> emulator.screen.getSelectedText(0, row, columns - 1, row) }
        val cells = snapshotTerminalCells(physical, columns) { row, col -> emulator.screen.getStyleAt(row, col) } ?: return null
        val screen = com.bambouville.tessera.core.bridge.SharedTerminalScreenEvidence(columns, cells,
            (0 until rows).map { row ->
                // Termux marks the previous row's outgoing wrap; Core and
                // SwiftTerm mark this row as continuing its predecessor.
                (row > 0 || emulator.screen.activeTranscriptRows > 0) && emulator.screen.getLineWrap(row - 1)
            }, emulator.cursorRow,
            emulator.cursorCol, emulator.isCursorEnabled, emulator.isAlternateBufferActive)
        val captured = screen.physicalRows
        val current = captured.getOrNull(screen.cursorRow)?.trimEnd() ?: return null
        return TerminalTextSnapshot(captured.joinToString("\n"), current, captured, screen.cursorRow,
            screen.cursorVisible, screen.cursorColumn, screenEvidence = screen)
    }

    override var onInput: ((ByteArray) -> Unit)? = null
    override var onResize: ((Int, Int) -> Unit)? = null
    override var onSelectionChanged: ((TerminalSelection?) -> Unit)? = null
    override var isRemotePathSelection: ((String) -> Boolean)? = null
    override var onSelectionPathAction: ((TerminalSelectionPathAction, String) -> Unit)? = null
    override var onTitleChanged: ((String?) -> Unit)? = null
    override var onHostDirectoryChanged: ((String?) -> Unit)? = null
    override var onBell: (() -> Unit)? = null
    override var onSoftwareModifiersConsumed: ((SharedArmedModifiers) -> Unit)? = null
    override var onFontSizeChanged: ((Int) -> Unit)? = null
    override var onSoftwareKeyboardRequested: (() -> Unit)? = null
    override var onFirstOutputRendered: (() -> Unit)? = null

    private val pendingOutput = ArrayDeque<ByteArray>()
    private var pendingOutputBytes = 0
    private var lastColumns = 0
    private var lastRows = 0
    private var closed = false
    private var arming = SharedModifierArming()

    /**
     * True while a synchronous KeyEvent dispatch may write bytes that the
     * upstream view has ALREADY modified — `readControlKey()`/`readAltKey()`/
     * `readShiftKey()` feed `KeyHandler.getCode` (modified arrows, backtab,
     * Ctrl+Backspace, shift+PageUp scrollback) and `getUnicodeChar`'s
     * layout-aware shifting, which the shared single-byte encoder cannot do.
     * Bytes written under this latch must not be modified a second time; the
     * armed one-shot is spent instead.
     */
    private var keyEventOwnsModifiers = false

    /**
     * True while a paste is being written. Paste bytes are never modified and
     * never spend an armed modifier, whatever their length — a one-character
     * clipboard is a single byte and would otherwise be indistinguishable
     * from a typed key.
     */
    private var pasteInFlight = false
    private val backgroundChangedListeners = mutableSetOf<() -> Unit>()
    private var fontSizeSp = initialFontSizeSp.coerceIn(8, 40)
    private var theme = initialTheme
    private var backgroundImage: TerminalBackgroundImage? = null
    private var cursorStyle = initialCursorStyle
    private var cursorBlink = initialCursorBlink
    private var outputAwaitingDraw = false
    private var outputRendered = false
    private var searchQuery = ""
    private var searchRows = emptyList<Int>()
    private var searchIndex = -1
    private val firstOutputDrawListener = ViewTreeObserver.OnDrawListener {
        if (!closed && outputAwaitingDraw && view.isAttachedToWindow && view.width > 0 && view.height > 0) {
            outputAwaitingDraw = false
            outputRendered = true
            onFirstOutputRendered?.invoke()
        }
    }

    private val sessionClient = object : TerminalSessionClient {
        override fun onTextChanged(changedSession: TerminalSession) = view.onScreenUpdated()
        override fun onTitleChanged(changedSession: TerminalSession) {
            this@TermuxTerminalSurface.onTitleChanged?.invoke(changedSession.title)
        }
        override fun onHostDirectoryChanged(changedSession: TerminalSession, uri: String) {
            val path = runCatching { URI(uri) }.getOrNull()
                ?.takeIf { it.scheme.equals("file", ignoreCase = true) }
                ?.path
                ?.takeIf { it.startsWith('/') && it.none(Char::isISOControl) }
            this@TermuxTerminalSurface.onHostDirectoryChanged?.invoke(path)
        }
        override fun onSessionFinished(finishedSession: TerminalSession) = Unit
        override fun onCopyTextToClipboard(session: TerminalSession, text: String) {
            clipboard.setPrimaryClip(ClipData.newPlainText("terminal selection", text))
        }
        override fun onPasteTextFromClipboard(session: TerminalSession) {
            val text = clipboard.primaryClip?.getItemAt(0)?.coerceToText(view.context)?.toString()
            if (text != null) pasteVerbatim(text)
        }
        override fun onBell(session: TerminalSession) {
            if (!closed) this@TermuxTerminalSurface.onBell?.invoke()
        }
        override fun onColorsChanged(session: TerminalSession) = view.invalidate()
        override fun onTerminalCursorStateChange(state: Boolean) = applyCursorAppearance()
        override fun getTerminalCursorStyle(): Int = cursorStyle.termuxStyle
        override fun logError(tag: String, message: String) { Log.e(tag, message) }
        override fun logWarn(tag: String, message: String) { Log.w(tag, message) }
        override fun logInfo(tag: String, message: String) { Log.i(tag, message) }
        override fun logDebug(tag: String, message: String) { Log.d(tag, message) }
        override fun logVerbose(tag: String, message: String) { Log.v(tag, message) }
        override fun logStackTraceWithMessage(tag: String, message: String, error: Exception) {
            Log.e(tag, message, error)
        }
        override fun logStackTrace(tag: String, error: Exception) {
            Log.e(tag, error.message, error)
        }
    }

    private val session = TerminalSession(
        transcriptRows.coerceIn(MIN_TRANSCRIPT_ROWS, MAX_TRANSCRIPT_ROWS),
        sessionClient,
        object : TerminalSession.ExternalSessionClient {
            override fun onInput(data: ByteArray) {
                if (closed) return
                if (pasteInFlight) {
                    this@TermuxTerminalSurface.onInput?.invoke(data.copyOf())
                    return
                }
                if (keyEventOwnsModifiers) {
                    // The view already applied the armed modifiers on the
                    // KeyEvent path; spend the one-shot, deliver verbatim.
                    keyEventOwnsModifiers = false
                    consumeSoftwareModifiers()
                    this@TermuxTerminalSurface.onInput?.invoke(data.copyOf())
                    return
                }
                this@TermuxTerminalSurface.onInput?.invoke(applySoftwareModifiers(data))
            }

            override fun onResize(
                columns: Int,
                rows: Int,
                cellWidthPixels: Int,
                cellHeightPixels: Int,
            ) {
                lastColumns = columns
                lastRows = rows
                if (!closed) this@TermuxTerminalSurface.onResize?.invoke(columns, rows)
            }
        },
    )

    private val viewClient = object : TerminalViewClient {
        override fun onScale(scale: Float): Float {
            val delta = when {
                scale > 1.1f -> 1
                scale < 0.9f -> -1
                else -> return scale
            }
            val next = (fontSizeSp + delta).coerceIn(8, 40)
            if (next != fontSizeSp) {
                fontSizeSp = next
                view.setTextSize(textSizePixels(next))
                view.requestLayout()
                onFontSizeChanged?.invoke(next)
            }
            return 1f
        }
        override fun onSingleTapUp(event: MotionEvent) {
            onSoftwareKeyboardRequested?.invoke()
        }
        override fun shouldBackButtonBeMappedToEscape(): Boolean = false
        // False selects the ordinary text-field input type in TerminalView, which
        // is what surfaces the dictation key and the suggestion strip. Per-keystroke
        // delivery is preserved there by streaming composition to the pty.
        override fun shouldEnforceCharBasedInput(): Boolean = false
        override fun shouldUseCtrlSpaceWorkaround(): Boolean = false
        override fun isTerminalViewSelected(): Boolean = view.hasFocus()
        override fun copyModeChanged(copyMode: Boolean) {
            this@TermuxTerminalSurface.onSelectionChanged?.invoke(
                if (copyMode) view.selectedText?.let(::TerminalSelection) else null,
            )
        }
        override fun isRemotePathSelection(text: String): Boolean =
            this@TermuxTerminalSurface.isRemotePathSelection?.invoke(text) == true
        override fun onRemotePathSelectionAction(action: Int, text: String) {
            val mapped = when (action) {
                TerminalViewClient.SELECTION_PATH_QUICK_OPEN -> TerminalSelectionPathAction.QuickOpen
                TerminalViewClient.SELECTION_PATH_REVEAL -> TerminalSelectionPathAction.RevealInFiles
                else -> return
            }
            this@TermuxTerminalSurface.onSelectionPathAction?.invoke(mapped, text)
        }
        override fun onKeyDown(keyCode: Int, event: KeyEvent, session: TerminalSession): Boolean {
            // This runs at the top of TerminalView.onKeyDown, before the view
            // reads the armed set and (synchronously) writes any bytes. Latch
            // so those bytes are not modified a second time in onInput; the
            // view.post clears the latch after the dispatch in case the key
            // produced no write at all (so a later IME commit still encodes).
            keyEventOwnsModifiers = arming.armed.armsTerminalBytes
            if (keyEventOwnsModifiers) view.post { keyEventOwnsModifiers = false }
            return false
        }
        override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
            keyEventOwnsModifiers = false
            return false
        }
        override fun onLongPress(event: MotionEvent): Boolean = false
        // Ownership of software-modifier application is split by delivery
        // path. KeyEvent-driven keys (hardware/Bluetooth keyboards, IMEs that
        // send real key events) MUST go through the upstream view's own
        // handling: `KeyHandler.getCode` is the only place a special key —
        // arrows, Tab→backtab, Ctrl+Backspace, F-keys, shift+PageUp
        // scrollback — can be encoded with a modifier, and `getUnicodeChar`
        // is the only layout-aware Shift. Committed IME text has no KeyEvent
        // and goes through the shared encoder in onInput instead. The
        // `keyEventOwnsModifiers` latch is what prevents the double
        // application (e.g. a double ESC prefix under Alt) that zeroing
        // these overrides once tried to solve by losing the whole key class.
        override fun readControlKey(): Boolean = arming.armed.control
        override fun readAltKey(): Boolean = arming.armed.alternate
        override fun readShiftKey(): Boolean = arming.armed.shift
        override fun readFnKey(): Boolean = false
        override fun onCodePoint(codePoint: Int, ctrlDown: Boolean, session: TerminalSession): Boolean = false
        override fun onEmulatorSet() {
            applyTheme()
            applyCursorAppearance()
            while (pendingOutput.isNotEmpty()) {
                val batch = pendingOutput.removeFirst()
                pendingOutputBytes -= batch.size
                session.appendExternalOutput(batch, 0, batch.size)
            }
        }
        override fun logError(tag: String, message: String) { Log.e(tag, message) }
        override fun logWarn(tag: String, message: String) { Log.w(tag, message) }
        override fun logInfo(tag: String, message: String) { Log.i(tag, message) }
        override fun logDebug(tag: String, message: String) { Log.d(tag, message) }
        override fun logVerbose(tag: String, message: String) { Log.v(tag, message) }
        override fun logStackTraceWithMessage(tag: String, message: String, error: Exception) {
            Log.e(tag, message, error)
        }
        override fun logStackTrace(tag: String, error: Exception) {
            Log.e(tag, error.message, error)
        }
    }

    private val clipboard = context.getSystemService(ClipboardManager::class.java)

    init {
        requireMainThread()
        view.layoutResizeDelayMillis = SharedSessionPolicy.resizeSettleMilliseconds()
        view.setTerminalViewClient(viewClient)
        view.setTextSize(textSizePixels(fontSizeSp))
        view.setTypeface(
            initialTypeface
                ?: ResourcesCompat.getFont(context, R.font.jetbrains_mono)
                ?: Typeface.MONOSPACE,
        )
        view.isFocusable = true
        view.isFocusableInTouchMode = true
        view.attachSession(session)
        applyTheme()
        view.viewTreeObserver.addOnDrawListener(firstOutputDrawListener)
    }

    override fun bind(owner: RenderOwner) {
        requireMainThread()
        check(!closed) { "terminal surface is closed" }
        if (boundOwner == owner) return

        // The Termux fork clears the main buffer even if an alternate-screen
        // TUI is active. Pre-layout batches have no emulator behind them yet,
        // so they are stale by definition and must not survive the new owner.
        if (boundOwner?.let {
                it.windowId != owner.windowId || it.paneId != owner.paneId ||
                    it.transportGeneration != owner.transportGeneration
            } == true
        ) view.cancelHistoryScroll()
        pendingOutput.clear()
        pendingOutputBytes = 0
        session.clearScrollback()
        view.resetScrollForRenderOwner()
        boundOwner = owner
        view.invalidate()
    }

    override fun setPainterFeedAdmission(admitted: Boolean) {
        requireMainThread()
        painterFeedsAdmitted = admitted
    }

    override fun feed(owner: RenderOwner?, bytes: ByteArray): Boolean {
        requireMainThread()
        check(!closed) { "terminal surface is closed" }
        if (bytes.isEmpty()) return true
        if ((owner == null && !painterFeedsAdmitted) ||
            (owner != null && owner != boundOwner)
        ) {
            droppedForeignFeeds += 1
            return false
        }
        if (!outputRendered) outputAwaitingDraw = true
        if (view.mEmulator == null) {
            check(pendingOutputBytes + bytes.size <= MAX_PENDING_OUTPUT_BYTES) {
                "terminal output exceeded the pre-layout buffer"
            }
            pendingOutput += bytes.copyOf()
            pendingOutputBytes += bytes.size
        } else {
            session.appendExternalOutput(bytes, 0, bytes.size)
        }
        return true
    }

    override fun resize(columns: Int, rows: Int) {
        requireMainThread()
        require(columns >= 4 && rows >= 4)
        view.cancelPendingLayoutResize()
        val renderer = view.mRenderer
        session.updateSize(columns, rows, renderer.fontWidth.toInt(), renderer.fontLineSpacing)
        view.mEmulator = session.emulator
        lastColumns = columns
        lastRows = rows
        view.invalidate()
    }

    override fun requestFullRepaint() {
        requireMainThread()
        view.invalidate()
    }

    override fun setTheme(theme: TerminalTheme) {
        requireMainThread()
        this.theme = theme
        applyTheme()
    }

    override fun setBackgroundImage(background: TerminalBackgroundImage?) {
        requireMainThread()
        backgroundImage = background
        applyTheme()
    }

    /** A new drawable for a surrounding scaled tmux viewport, if it needs the same backdrop. */
    fun backgroundDrawable() = terminalBackgroundStore.drawable(theme.backgroundArgb, backgroundImage)

    fun isCursorKeysApplicationMode(): Boolean = view.mEmulator?.isCursorKeysApplicationMode ?: false

    override fun setCursorAppearance(style: TerminalCursorStyle, blink: Boolean) {
        requireMainThread()
        cursorStyle = style
        cursorBlink = blink
        applyCursorAppearance()
    }

    override fun setFont(font: TerminalFont) {
        requireMainThread()
        require(font.sizeSp > 0)
        fontSizeSp = font.sizeSp.coerceIn(8, 40)
        view.setTextSize(textSizePixels(fontSizeSp))
        font.typeface?.let(view::setTypeface)
        // A geometry-neutral tmux viewport measures this view in exact cells.
        // Font metrics therefore affect layout even when the outer viewport's
        // physical bounds did not change.
        view.requestLayout()
    }

    fun gridMetrics(): TerminalGridMetrics {
        val renderer = view.mRenderer
        return TerminalGridMetrics(
            cellWidthPixels = renderer.fontWidth,
            cellHeightPixels = renderer.fontLineSpacing,
            firstBaselineInsetPixels = renderer.fontLineSpacingAndAscent,
        )
    }

    override fun setFocused(focused: Boolean) {
        requireMainThread()
        if (focused) view.requestFocus() else view.clearFocus()
        if (focused) applyCursorAppearance() else view.setTerminalCursorBlinkerState(false, true)
    }

    override fun snapshotNonSecretState(): TerminalSurfaceState {
        requireMainThread()
        val emulator = view.mEmulator
        val mouseTracking = emulator?.isMouseTrackingActive ?: false
        return TerminalSurfaceState(
            columns = emulator?.mColumns ?: lastColumns,
            rows = emulator?.mRows ?: lastRows,
            alternateScreen = emulator?.isAlternateBufferActive ?: false,
            mouseTracking = mouseTracking,
            mouseMode = if (mouseTracking) TerminalMouseMode.Tracking else TerminalMouseMode.Off,
            focused = view.hasFocus(),
            cursorRow = emulator?.cursorRow ?: 0,
            cursorColumn = emulator?.cursorCol ?: 0,
            cursorVisible = emulator?.shouldCursorBeVisible() ?: false,
            topRow = view.topRow,
            bracketedPaste = emulator?.isBracketedPasteMode ?: false,
        )
    }

    override fun caretClearance(): TerminalCaretClearance? {
        requireMainThread()
        val emulator = view.mEmulator ?: return null
        // Which surfaces keep the whole IME lift is the scroll route's call —
        // the same shared rule that decides whether a swipe stays local. A
        // surface whose swipes leave the device is a full-screen app that
        // keeps its status line at the bottom: the alternate screen, or mouse
        // reporting standing in for it where there is no local scrollback
        // (plain mosh, mosh+tmux before its pane grid). Mouse reporting on a
        // primary screen that still scrolls locally — the mosh+tmux visible
        // client under tmux's `mouse on` — is a shell prompt like any other
        // and follows the caret; asking "is mouse tracking active?" alone
        // pushed that prompt off the top of the screen.
        if (view.height <= 0 || emulator.mRows <= 0 ||
            view.scrollRoute() != SharedScrollRoute.LocalScrollback ||
            !emulator.isCursorEnabled
        ) return null

        val scale = view.scaleY.takeIf { it.isFinite() && it > 0f } ?: 1f
        val viewportHeight = (view.parent as? View)?.height?.takeIf { it > 0 } ?: view.height
        val cellHeight = view.mRenderer.fontLineSpacing * scale
        val caretTop = view.translationY +
            (emulator.cursorRow - view.topRow) * cellHeight
        return TerminalCaretClearance(
            abovePixels = caretTop,
            belowPixels = viewportHeight - (caretTop + cellHeight),
        )
    }

    override fun pasteClipboard() {
        requireMainThread()
        val text = clipboard.primaryClip?.getItemAt(0)?.coerceToText(view.context)?.toString() ?: return
        pasteVerbatim(text)
    }

    /** Pastes never spend or receive an armed modifier, even single-byte ones. */
    private fun pasteVerbatim(text: String) {
        if (text.isNotEmpty()) view.followLiveOutput()
        pasteInFlight = true
        try {
            view.mEmulator?.paste(text)
        } finally {
            pasteInFlight = false
        }
        // Pasted bytes bypass the InputConnection, so the line the IME
        // believes in no longer matches the pty; drop the stale model.
        view.resetImeLineContext()
    }

    override fun sendInput(bytes: ByteArray) {
        requireMainThread()
        if (bytes.isNotEmpty()) view.followLiveOutput()
        if (!closed && bytes.isNotEmpty()) onInput?.invoke(bytes.copyOf())
        consumeSoftwareModifiers()
        // Accessory-bar keys and programmatic sends bypass the
        // InputConnection; the IME's line model is stale now.
        view.resetImeLineContext()
    }

    override fun setSoftwareModifiers(armed: SharedArmedModifiers, behavior: SharedModifierBehavior) {
        requireMainThread()
        arming = SharedModifierArming(behavior = behavior, armed = armed)
    }

    internal fun addBackgroundChangedListener(listener: () -> Unit) {
        requireMainThread()
        backgroundChangedListeners += listener
    }

    internal fun removeBackgroundChangedListener(listener: () -> Unit) {
        requireMainThread()
        backgroundChangedListeners -= listener
    }

    override fun requestSoftwareKeyboard() {
        requireMainThread()
        if (closed) return
        view.requestFocus()
        view.post {
            if (closed || !view.isAttachedToWindow) return@post
            view.requestFocus()
            ViewCompat.getWindowInsetsController(view)?.show(WindowInsetsCompat.Type.ime())
            view.context.getSystemService(InputMethodManager::class.java)
                ?.showSoftInput(view, InputMethodManager.SHOW_IMPLICIT)
        }
    }

    override fun focusForInput() {
        requireMainThread()
        if (closed) return
        view.requestFocus()
    }

    override fun toggleSoftwareKeyboard() {
        requireMainThread()
        if (closed) return
        val ime = WindowInsetsCompat.Type.ime()
        val controller = ViewCompat.getWindowInsetsController(view)
        val input = view.context.getSystemService(InputMethodManager::class.java)
        if (ViewCompat.getRootWindowInsets(view)?.isVisible(ime) == true) {
            controller?.hide(ime)
            input?.hideSoftInputFromWindow(view.windowToken, 0)
        } else {
            requestSoftwareKeyboard()
        }
    }

    override fun find(query: String, forward: Boolean): TerminalSearchResult? {
        requireMainThread()
        val emulator = view.mEmulator ?: return null
        val normalized = query.trim()
        if (normalized.isEmpty()) {
            searchQuery = ""
            searchRows = emptyList()
            searchIndex = -1
            return null
        }
        if (normalized != searchQuery) {
            searchQuery = normalized
            val screen = emulator.screen
            searchRows = (-screen.activeTranscriptRows until emulator.mRows).filter { row ->
                screen.getSelectedText(0, row, emulator.mColumns, row, false)
                    .contains(normalized, ignoreCase = true)
            }
            searchIndex = if (forward) -1 else 0
        }
        if (searchRows.isEmpty()) return TerminalSearchResult(0, 0)
        searchIndex = if (forward) {
            (searchIndex + 1) % searchRows.size
        } else {
            (searchIndex - 1 + searchRows.size) % searchRows.size
        }
        val row = searchRows[searchIndex]
        view.topRow = row.coerceIn(-emulator.screen.activeTranscriptRows, 0)
        view.invalidate()
        return TerminalSearchResult(searchIndex + 1, searchRows.size)
    }

    override fun close() {
        requireMainThread()
        if (closed) return
        closed = true
        view.cancelHistoryScroll()
        view.cancelPendingLayoutResize()
        pendingOutput.clear()
        pendingOutputBytes = 0
        arming = SharedModifierArming(behavior = arming.behavior)
        backgroundChangedListeners.clear()
        searchRows = emptyList()
        isRemotePathSelection = null
        onSelectionPathAction = null
        onHostDirectoryChanged = null
        onFontSizeChanged = null
        onSoftwareKeyboardRequested = null
        onFirstOutputRendered = null
        if (view.viewTreeObserver.isAlive) view.viewTreeObserver.removeOnDrawListener(firstOutputDrawListener)
        session.finishIfRunning()
        view.setTerminalCursorBlinkerState(false, true)
        view.attachSession(null)
    }

    /**
     * Applies the armed accessory modifiers to one key event's bytes.
     *
     * Swift authority: `TesseraInputCore.TerminalSoftwareModifierEncoder`, via
     * `SharedInputEncoding.applySoftwareModifiers`. Ctrl+Space becomes NUL,
     * Ctrl+`?` becomes DEL, Alt adds an ESC prefix, Shift applies the
     * US-layout shifted byte — none of which this platform used to do.
     *
     * Only a single byte is eligible, which is the core's own "next key" rule.
     * A paste, a composed IME commit, and an escape sequence the view already
     * built (an arrow, a function key, a mouse report) are all multi-byte, and
     * prefixing one of those with ESC would corrupt it; they pass through and
     * deliberately leave a one-shot modifier still armed rather than spending
     * it on text the user did not type key by key.
     */
    private fun applySoftwareModifiers(data: ByteArray): ByteArray {
        val armed = arming.armed
        if (!armed.armsTerminalBytes || data.size != 1) return data.copyOf()
        val outcome = SharedInputEncoding.modifierArmingTransition(
            arming,
            SharedModifierArmingEvent.Consume,
        )
        arming = outcome.state
        val encoded = SharedInputEncoding.applySoftwareModifiers(data, outcome.consumed ?: armed)
        onSoftwareModifiersConsumed?.invoke(arming.armed)
        return encoded
    }

    /**
     * Spends the armed modifiers on an already-encoded payload — an accessory
     * chip, whose bytes came from the shared catalog with these very modifiers
     * folded in, or a paste the chrome injected.
     */
    private fun consumeSoftwareModifiers() {
        if (!arming.armed.armsTerminalBytes) return
        val outcome = SharedInputEncoding.modifierArmingTransition(
            arming,
            SharedModifierArmingEvent.Consume,
        )
        arming = outcome.state
        onSoftwareModifiersConsumed?.invoke(arming.armed)
    }

    private fun applyTheme() {
        view.setTerminalBackgroundDrawable(backgroundDrawable())
        view.mEmulator?.mColors?.setDefaultColors(theme.termuxPalette())
        backgroundChangedListeners.toList().forEach { it() }
        view.invalidate()
    }

    private fun applyCursorAppearance() {
        view.mEmulator?.setCursorStyle()
        view.setTerminalCursorBlinkerRate(if (cursorBlink) CURSOR_BLINK_RATE_MILLIS else 0)
        view.setTerminalCursorBlinkerState(cursorBlink && view.hasFocus(), true)
        view.invalidate()
    }

    private fun requireMainThread() {
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "terminal surface operations must be marshalled to the Android main thread"
        }
    }

    private fun textSizePixels(sizeSp: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_SP,
        sizeSp.toFloat(),
        view.resources.displayMetrics,
    ).toInt().coerceAtLeast(1)

    private companion object {
        const val DEFAULT_TEXT_SIZE_SP = 13
        const val CURSOR_BLINK_RATE_MILLIS = 500
        const val DEFAULT_TRANSCRIPT_ROWS = 10_000
        const val MIN_TRANSCRIPT_ROWS = 1_000
        const val MAX_TRANSCRIPT_ROWS = 50_000
        // A full-depth inline tmux history capture is the largest batch that
        // can arrive before this surface has an emulator: 470–680 KB measured
        // for a dense 10 000-line pane, and a deep repaint may land while the
        // view is still pre-layout. The old 1 MiB ceiling sat inside that
        // range, so the `check` below could fail a capture the ledger
        // correctly produced. Matches the raised shared render-bytes ceiling.
        const val MAX_PENDING_OUTPUT_BYTES = 8 shl 20
    }
}

/**
 * Whether anything is armed that can change the bytes a key produces. Command
 * is excluded on purpose: it arms an app-shortcut dispatcher that this
 * platform's accessory row does not offer, and it never reaches the wire.
 */
private val SharedArmedModifiers.armsTerminalBytes: Boolean
    get() = control || alternate || shift
