package com.termux.view;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.graphics.Typeface;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.Editable;
import android.text.InputType;
import android.text.TextUtils;
import android.util.AttributeSet;
import android.view.ActionMode;
import android.view.HapticFeedbackConstants;
import android.view.InputDevice;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.Menu;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewTreeObserver;
import android.view.accessibility.AccessibilityManager;
import android.view.autofill.AutofillManager;
import android.view.autofill.AutofillValue;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.widget.OverScroller;

import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;

import java.util.Objects;

import com.bambouville.tessera.core.bridge.SharedScrollRoute;
import com.bambouville.tessera.core.bridge.SharedScrollRouting;
import com.bambouville.tessera.terminal.RemoteTmuxPane;
import com.bambouville.tessera.terminal.TerminalSmoothScrollPolicy;
import com.termux.terminal.KeyHandler;
import com.termux.terminal.TerminalEmulator;
import com.termux.terminal.TerminalSession;
import com.termux.view.textselection.TextSelectionCursorController;

/** View displaying and interacting with a {@link TerminalSession}. */
@SuppressLint("ObsoleteSdkInt")
public final class TerminalView extends View {

    /** Log terminal view key and IME events. */
    private static boolean TERMINAL_VIEW_KEY_LOGGING_ENABLED = false;

    /** The currently displayed terminal session, whose emulator is {@link #mEmulator}. */
    public TerminalSession mTermSession;
    /** Our terminal emulator whose session is {@link #mTermSession}. */
    public TerminalEmulator mEmulator;

    public TerminalRenderer mRenderer;

    public TerminalViewClient mClient;

    /** The live IME connection, whose editable mirrors the current line; recreated by each onCreateInputConnection. */
    private TerminalImeConnection mImeConnection;

    /**
     * Receives one content-free line per IME operation (operation, lengths,
     * offsets, what the mirror diff emitted). Text itself never reaches it;
     * the raw arguments go to logcat only under the key-logging flag.
     */
    private java.util.function.Consumer<String> mImeTraceSink;

    private TextSelectionCursorController mTextSelectionCursorController;

    private Handler mTerminalCursorBlinkerHandler;
    private TerminalCursorBlinkerRunnable mTerminalCursorBlinkerRunnable;
    private int mTerminalCursorBlinkerRate;
    private boolean mCursorInvisibleIgnoreOnce;
    public static final int TERMINAL_CURSOR_BLINK_RATE_MIN = 100;
    public static final int TERMINAL_CURSOR_BLINK_RATE_MAX = 2000;

    /** The top row of text to display. Ranges from -activeTranscriptRows to 0. */
    int mTopRow;
    int[] mDefaultSelectors = new int[]{-1,-1,-1,-1};

    float mScaleFactor = 1.f;
    final GestureAndScaleRecognizer mGestureRecognizer;

    /** Keep track of where mouse touch event started which we report as mouse scroll. */
    private int mMouseScrollStartX = -1, mMouseScrollStartY = -1;
    /** Keep track of the time when a touch event leading to sending mouse scroll events started. */
    private long mMouseStartDownTime = -1;

    final OverScroller mScroller;

    /**
     * Tessera's per-device smooth-scroll preference. Momentum is intentionally
     * restricted to local primary-screen scrollback; see
     * {@link TerminalSmoothScrollPolicy}. It is not a transport switch: every
     * remote transport reaches this same terminal view.
     */
    private boolean mSmoothScrollingEnabled = TerminalSmoothScrollPolicy.DEFAULT_ENABLED;
    private float mSmoothScrollingSpeed = TerminalSmoothScrollPolicy.DEFAULT_SPEED;

    /**
     * Whether mouse reporting stands in for the alternate screen when a
     * scroll is routed (the shared {@code TerminalScrollRouting} rule). The
     * session sets it: true only while it has no local scrollback to offer —
     * plain mosh, or mosh+tmux before its pane grid — so the wheel reaches
     * the remote program; false otherwise, so tmux's own {@code mouse on}
     * never turns a swipe into copy-mode.
     */
    private boolean mMouseReportingImpliesAltScreen;

    /**
     * mosh+tmux only: the active tmux pane's alternate-screen and mouse modes.
     * mosh never relays the alternate screen, and the pane's mouse mode can be
     * missing from the visible tmux client, so the side channel is the
     * authority for both. Null lets this view's emulator decide.
     */
    @Nullable private RemoteTmuxPane mRemoteTmuxPane;

    /** Pixel offset inside mTopRow, in [0, lineHeight). Never rounded to a text row. */
    private float mScrollOffsetPixels;
    private int mLastScrollerY;

    /** What was left in from scrolling movement. */
    float mScrollRemainder;

    /** If non-zero, this is the last unicode code point received if that was a combining character. */
    int mCombiningAccent;

    /**
     * The current AutoFill type returned for {@link View#getAutofillType()} by {@link #getAutofillType()}.
     *
     * The default is {@link #AUTOFILL_TYPE_NONE} so that AutoFill UI, like toolbar above keyboard
     * is not shown automatically, like on Activity starts/View create. This value should be updated
     * to required value, like {@link #AUTOFILL_TYPE_TEXT} before calling
     * {@link AutofillManager#requestAutofill(View)} so that AutoFill UI shows. The updated value
     * set will automatically be restored to {@link #AUTOFILL_TYPE_NONE} in
     * {@link #autofill(AutofillValue)} so that AutoFill UI isn't shown anymore by calling
     * {@link #resetAutoFill()}.
     */
    @RequiresApi(api = Build.VERSION_CODES.O)
    private int mAutoFillType = AUTOFILL_TYPE_NONE;

    /**
     * The current AutoFill type returned for {@link View#getImportantForAutofill()} by
     * {@link #getImportantForAutofill()}.
     *
     * The default is {@link #IMPORTANT_FOR_AUTOFILL_NO} so that view is not considered important
     * for AutoFill. This value should be updated to required value, like
     * {@link #IMPORTANT_FOR_AUTOFILL_YES} before calling {@link AutofillManager#requestAutofill(View)}
     * so that Android and apps consider the view as important for AutoFill to process the request.
     * The updated value set will automatically be restored to {@link #IMPORTANT_FOR_AUTOFILL_NO} in
     * {@link #autofill(AutofillValue)} by calling {@link #resetAutoFill()}.
     */
    @RequiresApi(api = Build.VERSION_CODES.O)
    private int mAutoFillImportance = IMPORTANT_FOR_AUTOFILL_NO;

    /**
     * The current AutoFill hints returned for {@link View#getAutofillHints()} ()} by {@link #getAutofillHints()} ()}.
     *
     * The default is an empty `string[]`. This value should be updated to required value. The
     * updated value set will automatically be restored an empty `string[]` in
     * {@link #autofill(AutofillValue)} by calling {@link #resetAutoFill()}.
     */
    private String[] mAutoFillHints = new String[0];

    private final boolean mAccessibilityEnabled;

    private static final String LOG_TAG = "TerminalView";

    public TerminalView(Context context, AttributeSet attributes) { // NO_UCD (unused code)
        super(context, attributes);
        mGestureRecognizer = new GestureAndScaleRecognizer(context, new GestureAndScaleRecognizer.Listener() {

            boolean scrolledWithFinger;

            @Override
            public boolean onUp(MotionEvent event) {
                mScrollRemainder = 0.0f;
                if (mEmulator != null && isMouseReportingActive() && !event.isFromSource(InputDevice.SOURCE_MOUSE) && !isSelectingText() && !scrolledWithFinger) {
                    // Quick event processing when mouse tracking is active - do not wait for check of double tapping
                    // for zooming.
                    sendMouseEventCode(event, TerminalEmulator.MOUSE_LEFT_BUTTON, true);
                    sendMouseEventCode(event, TerminalEmulator.MOUSE_LEFT_BUTTON, false);
                    return true;
                }
                scrolledWithFinger = false;
                return false;
            }

            @Override
            public boolean onSingleTapUp(MotionEvent event) {
                if (mEmulator == null) return true;

                if (isSelectingText()) {
                    stopTextSelectionMode();
                    return true;
                }
                requestFocus();
                mClient.onSingleTapUp(event);
                return true;
            }

            @Override
            public boolean onScroll(MotionEvent e, float distanceX, float distanceY) {
                if (mEmulator == null) return true;
                if (isMouseReportingActive() && e.isFromSource(InputDevice.SOURCE_MOUSE)) {
                    // If moving with mouse pointer while pressing button, report that instead of scroll.
                    // This means that we never report moving with button press-events for touch input,
                    // since we cannot just start sending these events without a starting press event,
                    // which we do not do for touch input, only mouse in onTouchEvent().
                    sendMouseEventCode(e, TerminalEmulator.MOUSE_LEFT_BUTTON_MOVED, true);
                } else {
                    scrolledWithFinger = true;
                    if (scrollRoute() == SharedScrollRoute.LocalScrollback) {
                        scrollLocalPixels(distanceY);
                        return true;
                    }
                    distanceY += mScrollRemainder;
                    int deltaRows = (int) (distanceY / mRenderer.mFontLineSpacing);
                    mScrollRemainder = distanceY - deltaRows * mRenderer.mFontLineSpacing;
                    doScroll(e, deltaRows);
                }
                return true;
            }

            @Override
            public boolean onScale(float focusX, float focusY, float scale) {
                if (mEmulator == null || isSelectingText()) return true;
                mScaleFactor *= scale;
                mScaleFactor = mClient.onScale(mScaleFactor);
                return true;
            }

            @Override
            public boolean onFling(final MotionEvent e2, float velocityX, float velocityY) {
                if (mEmulator == null) return true;
                if (!canSmoothScroll()) return true;
                cancelSmoothScroll();
                // Match Android's native release velocity at the default preference.
                // Work in dp for the safety cap, then return to Scroller's physical pixels.
                float density = getResources().getDisplayMetrics().density;
                Float velocity = TerminalSmoothScrollPolicy.scaledReleaseVelocity(
                    velocityY / density, mSmoothScrollingSpeed
                );
                if (velocity == null) return true;
                final int pixelsPerSecond = Math.round(-velocity * density);
                if (mHistoryScrollPending) {
                    // A slow capture must not spend the release animation on an
                    // invisible transcript. Keep the drag position and start the
                    // native clock only once its history can actually be drawn.
                    mDeferredHistoryFlingVelocity = pixelsPerSecond;
                } else {
                    startLocalFling(pixelsPerSecond);
                }

                return true;
            }

            @Override
            public boolean onDown(float x, float y) {
                // A new direct gesture owns the scroll position immediately.
                // This mirrors UIScrollView and prevents a prior fling from
                // writing after the user begins a deliberate drag.
                cancelSmoothScroll();
                // Why is true not returned here?
                // https://developer.android.com/training/gestures/detector.html#detect-a-subset-of-supported-gestures
                // Although setting this to true still does not solve the following errors when long pressing in terminal view text area
                // ViewDragHelper: Ignoring pointerId=0 because ACTION_DOWN was not received for this pointer before ACTION_MOVE
                // Commenting out the call to mGestureDetector.onTouchEvent(event) in GestureAndScaleRecognizer#onTouchEvent() removes
                // the error logging, so issue is related to GestureDetector
                return false;
            }

            @Override
            public boolean onDoubleTap(MotionEvent event) {
                // Do not treat is as a single confirmed tap - it may be followed by zoom.
                return false;
            }

            @Override
            public void onLongPress(MotionEvent event) {
                if (mGestureRecognizer.isInProgress()) return;
                if (mClient.onLongPress(event)) return;
                if (!isSelectingText()) {
                    performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
                    startTextSelectionMode(event);
                }
            }
        });
        mScroller = new OverScroller(context);
        AccessibilityManager am = (AccessibilityManager) context.getSystemService(Context.ACCESSIBILITY_SERVICE);
        mAccessibilityEnabled = am.isEnabled();
    }



    /**
     * @param client The {@link TerminalViewClient} interface implementation to allow
     *                           for communication between {@link TerminalView} and its client.
     */
    public void setTerminalViewClient(TerminalViewClient client) {
        this.mClient = client;
    }

    /**
     * Sets whether terminal view key logging is enabled or not.
     *
     * @param value The boolean value that defines the state.
     */
    public void setIsTerminalViewKeyLoggingEnabled(boolean value) {
        TERMINAL_VIEW_KEY_LOGGING_ENABLED = value;
    }

    /** Installs (or, with null, removes) the content-free IME trace sink. */
    public void setImeTraceSink(java.util.function.Consumer<String> sink) {
        mImeTraceSink = sink;
    }

    private void traceIme(String line) {
        java.util.function.Consumer<String> sink = mImeTraceSink;
        if (sink != null) sink.accept(line);
    }

    /** Enables/disables post-release glide; disabling stops an active glide. */
    public void setSmoothScrollingEnabled(boolean enabled) {
        mSmoothScrollingEnabled = enabled;
        if (!enabled) cancelSmoothScroll();
    }

    public boolean isSmoothScrollingEnabled() {
        return mSmoothScrollingEnabled;
    }

    /**
     * Sets momentum strength for future flings. The normalized range and
     * default mirror iOS: 0.15 (slow) through 1.25 (fast), default 0.5.
     */
    public void setSmoothScrollingSpeed(float speed) {
        mSmoothScrollingSpeed = TerminalSmoothScrollPolicy.normalizedSpeed(speed);
    }

    /** See {@link #mMouseReportingImpliesAltScreen}; a change stops a glide the new route forbids. */
    public void setMouseReportingImpliesAltScreen(boolean implies) {
        if (mMouseReportingImpliesAltScreen == implies) return;
        mMouseReportingImpliesAltScreen = implies;
        if (scrollRoute() != SharedScrollRoute.LocalScrollback) followLiveOutput();
    }

    public boolean mouseReportingImpliesAltScreen() {
        return mMouseReportingImpliesAltScreen;
    }

    /** See {@link #mRemoteTmuxPane}; a change stops a glide the new route forbids. */
    public void setRemoteTmuxPane(@Nullable RemoteTmuxPane pane) {
        if (Objects.equals(mRemoteTmuxPane, pane)) return;
        mRemoteTmuxPane = pane;
        if (scrollRoute() != SharedScrollRoute.LocalScrollback) followLiveOutput();
    }

    @Nullable
    public RemoteTmuxPane remoteTmuxPane() {
        return mRemoteTmuxPane;
    }

    /**
     * One shared decision per scroll step, from {@code TerminalScrollRouting}
     * in the core — the same rule the iOS dispatcher applies. The screen
     * decides, never mouse tracking alone: on mosh+tmux the visible client
     * sits on the primary screen with the server's {@code mouse on} in force,
     * and a wheel report there would put tmux into copy-mode instead of
     * moving the overlay the side channel painted.
     */
    public SharedScrollRoute scrollRoute() {
        if (mEmulator == null) return SharedScrollRoute.LocalScrollback;
        RemoteTmuxPane pane = mRemoteTmuxPane;
        if (pane != null && pane.getAlternateScreen()) {
            // The gesture scrolls the pane's program, not the tmux client.
            return SharedScrollRouting.route(true, pane.getMouseReporting(), false);
        }
        return SharedScrollRouting.route(
            mEmulator.isAlternateBufferActive(),
            mEmulator.isMouseTrackingActive(),
            mMouseReportingImpliesAltScreen
        );
    }

    public float getSmoothScrollingSpeed() {
        return mSmoothScrollingSpeed;
    }

    // Opt-in paging seam for a primary Mosh canvas. Ordinary SSH/local history
    // never installs this callback and keeps its native bounded scroller.
    private Runnable mHistoryScrollRequest;
    private boolean mHistoryScrollPending;
    private float mPendingHistoryPosition;
    private int mDeferredHistoryFlingVelocity;

    private void startLocalFling(int pixelsPerSecond) {
        final int lineHeight = Math.max(1, mRenderer.mFontLineSpacing);
        mLastScrollerY = Math.round(getScrollPositionPixels());
        mScroller.fling(0, mLastScrollerY, 0, pixelsPerSecond,
            0, 0, mHistoryScrollRequest == null
                ? -mEmulator.getScreen().getActiveTranscriptRows() * lineHeight : Integer.MIN_VALUE / 4, 0);
        postInvalidateOnAnimation();
    }

    public void setHistoryScrollRequest(Runnable request) {
        mHistoryScrollRequest = request;
        if (request == null) cancelHistoryScroll();
    }

    public boolean isHistoryScrollPending() { return mHistoryScrollPending; }

    /** Whether a glide is still moving the viewport. */
    public boolean isGliding() { return !mScroller.isFinished(); }

    public void beginHistoryScroll() {
        if (mHistoryScrollPending) return;
        mHistoryScrollPending = true;
        mPendingHistoryPosition = getScrollPositionPixels();
    }

    public void cancelHistoryScroll() {
        mHistoryScrollPending = false;
        mPendingHistoryPosition = 0;
        cancelSmoothScroll();
    }

    /** A capture bind rebuilds rows, but must not discard its pending gesture. */
    public void resetScrollForRenderOwner() {
        if (!mHistoryScrollPending) cancelSmoothScroll();
        mTopRow = 0;
        mScrollOffsetPixels = 0;
        invalidate();
    }

    /** Apply the accumulated drag AND native release motion in the new transcript. */
    public void completeHistoryScroll(int fallbackTopRow) {
        if (!mHistoryScrollPending) {
            setTopRow(fallbackTopRow);
            return;
        }
        float position = mPendingHistoryPosition;
        mHistoryScrollPending = false;
        mPendingHistoryPosition = 0;
        setLocalScrollPosition(position);
        final int deferredVelocity = mDeferredHistoryFlingVelocity;
        mDeferredHistoryFlingVelocity = 0;
        if (deferredVelocity != 0 && canSmoothScroll()) startLocalFling(deferredVelocity);
    }

    /** Stops an active glide without changing the persisted preference. */
    public void cancelSmoothScroll() {
        mDeferredHistoryFlingVelocity = 0;
        if (!mScroller.isFinished()) mScroller.abortAnimation();
        mScrollRemainder = 0.0f;
    }



    /**
     * Attach a {@link TerminalSession} to this view.
     *
     * @param session The {@link TerminalSession} this view will be displaying.
     */
    public boolean attachSession(TerminalSession session) {
        if (session == mTermSession) return false;
        cancelSmoothScroll();
        mTopRow = 0;
        mScrollOffsetPixels = 0;

        mTermSession = session;
        mEmulator = null;
        mCombiningAccent = 0;

        updateSize();

        // Wait with enabling the scrollbar until we have a terminal to get scroll position from.
        setVerticalScrollBarEnabled(true);

        return true;
    }

    @Override
    public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
        // Ensure that inputType is only set if TerminalView is selected view with the keyboard and
        // an alternate view is not selected, like an EditText. This is necessary if an activity is
        // initially started with the alternate view or if activity is returned to from another app
        // and the alternate view was the one selected the last time.
        if (mClient.isTerminalViewSelected()) {
            if (mClient.shouldEnforceCharBasedInput()) {
                // Some keyboards seems do not reset the internal state on TYPE_NULL.
                // Affects mostly Samsung stock keyboards.
                // https://github.com/termux/termux-app/issues/686
                // However, this is not a valid value as per AOSP since `InputType.TYPE_CLASS_*` is
                // not set and it logs a warning:
                // W/InputAttributes: Unexpected input class: inputType=0x00080090 imeOptions=0x02000000
                // https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:packages/inputmethods/LatinIME/java/src/com/android/inputmethod/latin/InputAttributes.java;l=79
                outAttrs.inputType = InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
            } else {
                // A real text class is what makes an IME behave like an ordinary
                // keyboard: the dictation key and the suggestion strip are both
                // withheld from TYPE_NULL and from password variations. The cost
                // is that the IME now composes words, so setComposingText below
                // streams the composition to the pty instead of waiting for a
                // commit that a TUI would never see.
                //
                // AUTO_CORRECT is deliberately left off: suggestions are offered
                // and can be tapped, but the IME never silently rewrites a typed
                // command. Historic TYPE_NULL issues, for whoever revisits this:
                // https://github.com/termux/termux-packages/issues/25
                // https://github.com/termux/termux-app/issues/87.
                // https://github.com/termux/termux-app/issues/126.
                // https://github.com/termux/termux-app/issues/137 (japanese chars and TYPE_NULL).
                outAttrs.inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_NORMAL;
            }
        } else {
            // Corresponds to android:inputType="text"
            outAttrs.inputType =  InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_NORMAL;
        }

        // Note that IME_ACTION_NONE cannot be used as that makes it impossible to input newlines using the on-screen
        // keyboard on Android TV (see https://github.com/termux/termux-app/issues/221).
        //
        // NO_PERSONALIZED_LEARNING is deliberately NOT set. It was added to keep a password
        // answered at a remote prompt out of the IME's learned dictionary, on the assumption
        // that it costs nothing else. It is not a dictionary switch: Gboard reads it as a
        // request for incognito mode and puts the whole keyboard in it — incognito badge in
        // the toolbar, voice typing withheld, no composing region, and auto-correct that can
        // be tapped but never applies. That is the same degraded keyboard the password input
        // class used to impose, arriving by another door, and undoing what the ordinary text
        // class above was chosen for. Whether a password is typed here is the remote prompt's
        // business, and a user who wants that protection has the platform's own incognito
        // controls; the terminal does not force it on every line they type.
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN;

        outAttrs.initialSelStart = 0;
        outAttrs.initialSelEnd = 0;
        mImeConnection = new TerminalImeConnection();
        traceIme("connection inputType=0x" + Integer.toHexString(outAttrs.inputType)
            + " imeOptions=0x" + Integer.toHexString(outAttrs.imeOptions));
        return mImeConnection;
    }

    /**
     * An InputConnection whose editable is an honest mirror of the current
     * line, so IME revisions translate into terminal bytes.
     *
     * A terminal cannot wait for a word to be finished - `q` in less and `j`
     * in vi have to arrive as they are typed - so every mutation is forwarded
     * immediately. The editable is NOT cleared after a commit: it keeps
     * accumulating the line, because an IME addresses later revisions
     * (auto-correct, suggestion taps, Gboard's replaceText) at character
     * offsets inside the text it believes the editor holds. An editable that
     * kept forgetting its text made Gboard 18 revise against a phantom model:
     * replaceText edited the local editable silently, zero bytes reached the
     * pty, and the leftover text was flushed with the NEXT keystroke - the
     * "input gets duplicated" report - while its consistency checks kept
     * auto-correction disabled for the whole app.
     *
     * Translation is uniform for every operation: snapshot the editable, let
     * the superclass apply the edit, then diff the two texts. The pty cursor
     * always sits at the end of the mirrored line, so any edit is "backspace
     * over the diverging tail, retype the remainder". The depth guard keeps
     * nested calls (AOSP default methods are free to implement one operation
     * in terms of others) from translating twice, and everything is emitted
     * synchronously - handleKeyCode / sendTextToTerminal, never sendKeyEvent,
     * which posts through the IME dispatch queue and reorders against
     * synchronous writes (the 456f32c defect).
     *
     * The mirror may UNDER-claim (bytes sent outside the IME path - hardware
     * letters, accessory keys - are simply absent from it; the diff then only
     * ever appends). It must never OVER-claim, so every event that consumes
     * or invalidates line text outside this class resets or trims it: Enter,
     * control bytes, cursor keys, pastes, and the accessory bar all end the
     * line the mirror describes (see resetImeLineContext / noteExternalKey).
     */
    private final class TerminalImeConnection extends BaseInputConnection {

        /** Characters kept in the mirror before the line model is abandoned. */
        private static final int MIRROR_CAP = 4096;

        /** Depth of re-entrant InputConnection operations; only depth 1 translates. */
        private int mOpDepth = 0;
        private int mBatchDepth = 0;
        private boolean mSelectionNotificationPending = false;
        private boolean mRestartPosted = false;
        /**
         * One read-back trace per mutation. A keyboard polls the line on every
         * keystroke; what the report needs to show is whether it read the line
         * again before it revised one, not the polling.
         */
        private boolean mReadTraceArmed = true;

        TerminalImeConnection() {
            super(TerminalView.this, true);
        }

        private void logIme(String message) {
            if (TERMINAL_VIEW_KEY_LOGGING_ENABLED) mClient.logInfo(LOG_TAG, "IME: " + message);
        }

        /** The mirror's shape without its text: length, selection, composing span. */
        private String describeMirror() {
            Editable editable = getEditable();
            return "len=" + editable.length()
                + " sel=" + android.text.Selection.getSelectionStart(editable)
                + ".." + android.text.Selection.getSelectionEnd(editable)
                + " comp=" + getComposingSpanStart(editable) + ".." + getComposingSpanEnd(editable);
        }

        private void traceOp(String detail) {
            if (mImeTraceSink == null) return;
            traceIme(detail + " depth=" + mOpDepth + " batch=" + mBatchDepth + " " + describeMirror());
        }

        /** As traceOp, but only for the first read since the line last changed. */
        private void traceRead(String detail) {
            if (mImeTraceSink == null || !mReadTraceArmed) return;
            mReadTraceArmed = false;
            traceOp(detail);
        }

        @Override
        public boolean setComposingText(CharSequence text, int newCursorPosition) {
            logIme("setComposingText(\"" + text + "\", " + newCursorPosition + ")");
            traceOp("setComposingText textLen=" + text.length() + " cursor=" + newCursorPosition);
            mOpDepth++;
            String before = mOpDepth == 1 ? getEditable().toString() : null;
            try {
                return super.setComposingText(text, newCursorPosition);
            } finally {
                if (before != null) reconcileMirror(before);
                mOpDepth--;
            }
        }

        @Override
        public boolean setComposingRegion(int start, int end) {
            logIme("setComposingRegion(" + start + ", " + end + ")");
            traceOp("setComposingRegion start=" + start + " end=" + end);
            mOpDepth++;
            String before = mOpDepth == 1 ? getEditable().toString() : null;
            try {
                return super.setComposingRegion(start, end);
            } finally {
                if (before != null) reconcileMirror(before);
                mOpDepth--;
            }
        }

        @Override
        public boolean finishComposingText() {
            logIme("finishComposingText()");
            traceOp("finishComposingText");
            mOpDepth++;
            String before = mOpDepth == 1 ? getEditable().toString() : null;
            try {
                return super.finishComposingText();
            } finally {
                if (before != null) reconcileMirror(before);
                mOpDepth--;
            }
        }

        @Override
        public boolean commitText(CharSequence text, int newCursorPosition) {
            logIme("commitText(\"" + text + "\", " + newCursorPosition + ")");
            traceOp("commitText textLen=" + text.length() + " cursor=" + newCursorPosition);
            mOpDepth++;
            String before = mOpDepth == 1 ? getEditable().toString() : null;
            try {
                return super.commitText(text, newCursorPosition);
            } finally {
                if (before != null) reconcileMirror(before);
                mOpDepth--;
            }
        }

        @Override
        public boolean deleteSurroundingText(int leftLength, int rightLength) {
            logIme("deleteSurroundingText(" + leftLength + ", " + rightLength + ")");
            traceOp("deleteSurroundingText left=" + leftLength + " right=" + rightLength);
            mOpDepth++;
            String before = mOpDepth == 1 ? getEditable().toString() : null;
            try {
                return super.deleteSurroundingText(leftLength, rightLength);
            } finally {
                if (before != null) reconcileMirror(before);
                mOpDepth--;
            }
        }

        @Override
        public boolean deleteSurroundingTextInCodePoints(int beforeLength, int afterLength) {
            logIme("deleteSurroundingTextInCodePoints(" + beforeLength + ", " + afterLength + ")");
            traceOp("deleteSurroundingTextInCodePoints before=" + beforeLength + " after=" + afterLength);
            mOpDepth++;
            String before = mOpDepth == 1 ? getEditable().toString() : null;
            try {
                return super.deleteSurroundingTextInCodePoints(beforeLength, afterLength);
            } finally {
                if (before != null) reconcileMirror(before);
                mOpDepth--;
            }
        }

        /**
         * Gboard 18 revises committed words through this API-34 entry point
         * instead of deleteSurroundingText + commitText. Unreachable below
         * API 34 (the framework never routes it there).
         */
        @Override
        public boolean replaceText(int start, int end, CharSequence text, int newCursorPosition,
                                   android.view.inputmethod.TextAttribute textAttribute) {
            logIme("replaceText(" + start + ", " + end + ", \"" + text + "\", " + newCursorPosition + ")");
            traceOp("replaceText start=" + start + " end=" + end + " textLen=" + text.length()
                + " cursor=" + newCursorPosition);
            mOpDepth++;
            String before = mOpDepth == 1 ? getEditable().toString() : null;
            try {
                return super.replaceText(start, end, text, newCursorPosition, textAttribute);
            } finally {
                if (before != null) reconcileMirror(before);
                mOpDepth--;
            }
        }

        /**
         * The reads below change nothing; they are traced because a keyboard
         * that never asks is a keyboard revising against its own memory of the
         * line, and that memory is what goes stale.
         */
        @Override
        public CharSequence getTextBeforeCursor(int length, int flags) {
            CharSequence text = super.getTextBeforeCursor(length, flags);
            traceRead("getTextBeforeCursor n=" + length + " gave=" + (text == null ? -1 : text.length()));
            return text;
        }

        @Override
        public CharSequence getTextAfterCursor(int length, int flags) {
            CharSequence text = super.getTextAfterCursor(length, flags);
            traceRead("getTextAfterCursor n=" + length + " gave=" + (text == null ? -1 : text.length()));
            return text;
        }

        /** API 31; the framework never routes it below that, as with replaceText. */
        @androidx.annotation.RequiresApi(31)
        @Override
        public android.view.inputmethod.SurroundingText getSurroundingText(
                int beforeLength, int afterLength, int flags) {
            android.view.inputmethod.SurroundingText text =
                super.getSurroundingText(beforeLength, afterLength, flags);
            traceRead("getSurroundingText before=" + beforeLength + " after=" + afterLength
                + " gave=" + (text == null ? -1 : text.getText().length()));
            return text;
        }

        @Override
        public android.view.inputmethod.ExtractedText getExtractedText(
                android.view.inputmethod.ExtractedTextRequest request, int flags) {
            android.view.inputmethod.ExtractedText text = super.getExtractedText(request, flags);
            traceRead("getExtractedText gave="
                + (text == null || text.text == null ? -1 : text.text.length()));
            return text;
        }

        @Override
        public boolean requestCursorUpdates(int cursorUpdateMode) {
            traceOp("requestCursorUpdates mode=" + cursorUpdateMode);
            return super.requestCursorUpdates(cursorUpdateMode);
        }

        @Override
        public boolean setSelection(int start, int end) {
            logIme("setSelection(" + start + ", " + end + ")");
            traceOp("setSelection start=" + start + " end=" + end);
            boolean handled = super.setSelection(start, end);
            if (mOpDepth == 0) notifySelectionChanged();
            return handled;
        }

        @Override
        public boolean beginBatchEdit() {
            mBatchDepth++;
            return super.beginBatchEdit();
        }

        @Override
        public boolean endBatchEdit() {
            boolean handled = super.endBatchEdit();
            if (mBatchDepth > 0 && --mBatchDepth == 0 && mSelectionNotificationPending) {
                mSelectionNotificationPending = false;
                doNotifySelection();
            }
            return handled;
        }

        /**
         * Emits the difference between the mirror before and after an edit:
         * backspaces from the end of the line to the first diverging glyph,
         * then the retyped remainder. Plain typing degenerates to "send the
         * new character"; a revision takes back exactly the diverging tail.
         */
        private void reconcileMirror(String before) {
            Editable editable = getEditable();
            String after = editable.toString();
            int common = -1;
            int erased = 0;
            int sent = 0;
            int join = 0;
            if (mEmulator != null && !after.equals(before)) {
                common = 0;
                int max = Math.min(before.length(), after.length());
                while (common < max && before.charAt(common) == after.charAt(common)) common++;
                // Never split a surrogate pair: rewind to the start of the glyph.
                if (common > 0
                    && (common < before.length() && Character.isLowSurrogate(before.charAt(common))
                        || common < after.length() && Character.isLowSurrogate(after.charAt(common)))) {
                    common--;
                }
                if (common < before.length()) {
                    // One backspace per glyph, not per char, or astral-plane
                    // characters would only be half-deleted.
                    int glyphs = before.codePointCount(common, before.length());
                    for (int i = 0; i < glyphs; i++) handleKeyCode(KeyEvent.KEYCODE_DEL, 0);
                    erased = glyphs;
                }
                if (common < after.length()) {
                    sendTextToTerminal(after.substring(common));
                    sent = after.length() - common;
                    // How much of the insertion retypes the text it follows. A
                    // keyboard that completes a word against a stale prefix -
                    // "actu" when the mirror already holds "actua" - commits an
                    // insertion that begins by repeating what is already on the
                    // line, and the line gains a letter the user never typed.
                    // Honest completions score zero, so this is the number that
                    // separates "the IME handed us the wrong text" from "we
                    // translated it wrong", and it carries no text of its own.
                    int limit = Math.min(common, after.length() - common);
                    for (int k = limit; k > 0; k--) {
                        if (after.regionMatches(common - k, after, common, k)) {
                            join = k;
                            break;
                        }
                    }
                }
            }
            // A control character ends the line the mirror describes (Enter
            // arrives as "\n" text from AOSP-descended keyboards); so does an
            // absurdly long line - both hand the IME a fresh, truthful model.
            boolean endsLine = containsControlCharacter(after) || after.length() > MIRROR_CAP;
            if (mImeTraceSink != null) {
                traceIme("reconcile before=" + before.length() + " after=" + after.length()
                    + " common=" + common + " erased=" + erased + " sent=" + sent
                    + " join=" + join + " endsSpace=" + after.endsWith(" ")
                    + " emulator=" + (mEmulator != null) + " endsLine=" + endsLine
                    + " " + describeMirror());
            }
            mReadTraceArmed = true;
            if (endsLine) {
                hardResetLine();
                return;
            }
            notifySelectionChanged();
        }

        private boolean containsControlCharacter(String text) {
            for (int i = 0; i < text.length(); i++) {
                char c = text.charAt(i);
                if (c < 0x20 || c == 0x7F) return true;
            }
            return false;
        }

        /**
         * Forgets the current line model and tells the IME to do the same.
         * No terminal bytes are emitted; this only re-founds the shared
         * fiction on an empty line.
         */
        void hardResetLine() {
            Editable editable = getEditable();
            if (editable.length() == 0 && getComposingSpanStart(editable) < 0) return;
            if (mImeTraceSink != null) traceIme("hardReset " + describeMirror() + " depth=" + mOpDepth);
            editable.clear();
            mSelectionNotificationPending = false;
            if (!mRestartPosted) {
                mRestartPosted = true;
                post(() -> {
                    mRestartPosted = false;
                    android.view.inputmethod.InputMethodManager imm =
                        (android.view.inputmethod.InputMethodManager)
                            getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
                    if (imm != null) imm.restartInput(TerminalView.this);
                });
            }
        }

        /**
         * A key event consumed outside this connection. DEL erases the last
         * mirrored glyph so the mirror tracks the pty; any other key that
         * produces terminal bytes (Enter, arrows, tab, ...) ends the line the
         * mirror describes. Printable letters are left alone - the mirror
         * merely under-claims them, which the diff translation tolerates.
         */
        void noteExternalKey(int keyCode) {
            if (mOpDepth > 0) return;
            if (keyCode == KeyEvent.KEYCODE_DEL) {
                Editable editable = getEditable();
                int len = editable.length();
                if (mImeTraceSink != null) traceIme("externalKey del " + describeMirror());
                if (len > 0) {
                    int cut = len - (len > 1 && Character.isLowSurrogate(editable.charAt(len - 1)) ? 2 : 1);
                    editable.delete(cut, len);
                    notifySelectionChanged();
                }
                return;
            }
            if (KeyEvent.isModifierKey(keyCode)) return;
            TerminalEmulator term = mTermSession == null ? null : mTermSession.getEmulator();
            String code = KeyHandler.getCode(keyCode, 0,
                term != null && term.isCursorKeysApplicationMode(),
                term != null && term.isKeypadApplicationMode());
            if (mImeTraceSink != null) {
                traceIme("externalKey code=" + keyCode + " endsLine=" + (code != null) + " " + describeMirror());
            }
            if (code != null) hardResetLine();
        }

        /** A control byte is leaving for the pty outside any IME operation. */
        void noteExternalControlByte() {
            if (mImeTraceSink != null) traceIme("externalControl depth=" + mOpDepth + " " + describeMirror());
            if (mOpDepth == 0) hardResetLine();
        }

        private void notifySelectionChanged() {
            if (mBatchDepth > 0) {
                mSelectionNotificationPending = true;
                return;
            }
            doNotifySelection();
        }

        private void doNotifySelection() {
            Editable editable = getEditable();
            android.view.inputmethod.InputMethodManager imm =
                (android.view.inputmethod.InputMethodManager)
                    getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm == null) return;
            imm.updateSelection(TerminalView.this,
                android.text.Selection.getSelectionStart(editable),
                android.text.Selection.getSelectionEnd(editable),
                getComposingSpanStart(editable),
                getComposingSpanEnd(editable));
        }

        void sendTextToTerminal(CharSequence text) {
            stopTextSelectionMode();
            final int textLengthInChars = text.length();
            for (int i = 0; i < textLengthInChars; i++) {
                char firstChar = text.charAt(i);
                int codePoint;
                if (Character.isHighSurrogate(firstChar)) {
                    if (++i < textLengthInChars) {
                        codePoint = Character.toCodePoint(firstChar, text.charAt(i));
                    } else {
                        // At end of string, with no low surrogate following the high:
                        codePoint = TerminalEmulator.UNICODE_REPLACEMENT_CHAR;
                    }
                } else {
                    codePoint = firstChar;
                }

                // Check onKeyDown() for details.
                if (mClient.readShiftKey())
                    codePoint = Character.toUpperCase(codePoint);

                boolean ctrlHeld = false;
                if (codePoint <= 31 && codePoint != 27) {
                    if (codePoint == '\n') {
                        // The AOSP keyboard and descendants seems to send \n as text when the enter key is pressed,
                        // instead of a key event like most other keyboard apps. A terminal expects \r for the enter
                        // key (although when icrnl is enabled this doesn't make a difference - run 'stty -icrnl' to
                        // check the behaviour).
                        codePoint = '\r';
                    }

                    // E.g. penti keyboard for ctrl input.
                    ctrlHeld = true;
                    switch (codePoint) {
                        case 31:
                            codePoint = '_';
                            break;
                        case 30:
                            codePoint = '^';
                            break;
                        case 29:
                            codePoint = ']';
                            break;
                        case 28:
                            codePoint = '\\';
                            break;
                        default:
                            codePoint += 96;
                            break;
                    }
                }

                inputCodePoint(codePoint, ctrlHeld, false);
            }
        }
    }

    /**
     * Forget the IME's model of the current line. Call whenever terminal
     * bytes are produced outside the IME path (accessory bar keys, pastes,
     * programmatic sends): the line the IME believes in no longer exists, and
     * keeping the stale model would make its next revision erase real input.
     */
    public void resetImeLineContext() {
        if (mImeConnection == null) return;
        if (mImeTraceSink != null) traceIme("resetLineContext");
        mImeConnection.hardResetLine();
    }


    @Override
    protected int computeVerticalScrollRange() {
        return mEmulator == null ? 1 : mEmulator.getScreen().getActiveRows();
    }

    @Override
    protected int computeVerticalScrollExtent() {
        return mEmulator == null ? 1 : mEmulator.mRows;
    }

    @Override
    protected int computeVerticalScrollOffset() {
        return mEmulator == null ? 1 : mEmulator.getScreen().getActiveRows() + mTopRow - mEmulator.mRows;
    }

    /** Return to the live cursor for actual typing/paste, never terminal auto-replies. */
    public void followLiveOutput() {
        cancelHistoryScroll();
        if (mTopRow == 0 && mScrollOffsetPixels == 0) return;
        mTopRow = 0;
        mScrollOffsetPixels = 0;
        invalidate();
    }

    public void onScreenUpdated() {
        if (mEmulator == null) return;

        int rowsInHistory = mEmulator.getScreen().getActiveTranscriptRows();
        if (scrollRoute() != SharedScrollRoute.LocalScrollback) {
            cancelSmoothScroll();
            mTopRow = 0;
            mScrollOffsetPixels = 0;
        }
        if (mTopRow < -rowsInHistory) {
            mTopRow = -rowsInHistory;
            mScrollOffsetPixels = 0;
        }

        boolean skipScrolling = false;
        if (isSelectingText()) {
            // Do not scroll when selecting text.
            int rowShift = mEmulator.getScrollCounter();
            if (-mTopRow + rowShift > rowsInHistory) {
                // .. unless we're hitting the end of history transcript, in which
                // case we abort text selection and scroll to end.
                stopTextSelectionMode();
            } else {
                skipScrolling = true;
                mTopRow -= rowShift;
                decrementYTextSelectionCursors(rowShift);
            }
        }

        if (!skipScrolling && mTopRow != 0) {
            // Output is not user input. Keep the same history rows visible
            // through idle redraws and newly appended lines, clamping only
            // when those rows have fallen out of the bounded transcript.
            mTopRow = Math.max(-rowsInHistory, mTopRow - mEmulator.getHistoryScrollCounter());
        }

        mEmulator.clearScrollCounter();

        invalidate();
        if (mAccessibilityEnabled) setContentDescription(getText());
    }

    /** This must be called by the hosting activity in {@link Activity#onContextMenuClosed(Menu)}
     * when context menu for the {@link TerminalView} is started by
     * {@link TextSelectionCursorController#ACTION_MORE} is closed. */
    public void onContextMenuClosed(Menu menu) {
        // Unset the stored text since it shouldn't be used anymore and should be cleared from memory
        unsetStoredSelectedText();
    }

    /**
     * Sets the text size, which in turn sets the number of rows and columns.
     *
     * @param textSize the new font size, in density-independent pixels.
     */
    public void setTextSize(int textSize) {
        mRenderer = new TerminalRenderer(textSize, mRenderer == null ? Typeface.MONOSPACE : mRenderer.mTypeface);
        updateSize();
    }

    public void setTypeface(Typeface newTypeface) {
        mRenderer = new TerminalRenderer(mRenderer.mTextSize, newTypeface);
        updateSize();
        invalidate();
    }

    /** Current renderer face; used by the adapter and its font regression test. */
    public Typeface getTypeface() {
        return mRenderer.mTypeface;
    }

    /** Physical pixel size used by the renderer; exposed for density-aware adapter tests. */
    public int getTextSizePixels() {
        return mRenderer.mTextSize;
    }

    @Override
    public boolean onCheckIsTextEditor() {
        return true;
    }

    @Override
    public boolean isOpaque() {
        return true;
    }

    /**
     * Get the zero indexed column and row of the terminal view for the
     * position of the event.
     *
     * @param event The event with the position to get the column and row for.
     * @param relativeToScroll If true the column number will take the scroll
     * position into account. E.g. if scrolled 3 lines up and the event
     * position is in the top left, column will be -3 if relativeToScroll is
     * true and 0 if relativeToScroll is false.
     * @return Array with the column and row.
     */
    public int[] getColumnAndRow(MotionEvent event, boolean relativeToScroll) {
        int column = (int) (event.getX() / mRenderer.mFontWidth);
        int row = (int) ((event.getY() + mScrollOffsetPixels - mRenderer.mFontLineSpacingAndAscent) / mRenderer.mFontLineSpacing);
        if (relativeToScroll) {
            row += mTopRow;
        }
        return new int[] { column, row };
    }

    /**
     * Whether clicks and drags are reported to the remote program: the
     * emulator's own mouse mode, or a mosh+tmux pane that asked for the mouse
     * while the live screen is showing. A tap on local history the reader
     * scrolled back to would land on the program's unrelated rows.
     */
    boolean isMouseReportingActive() {
        if (mEmulator == null) return false;
        if (mEmulator.isMouseTrackingActive()) return true;
        RemoteTmuxPane pane = mRemoteTmuxPane;
        return pane != null && pane.getMouseReporting() && mTopRow == 0 && mScrollOffsetPixels == 0;
    }

    /** Send a single mouse event code to the terminal. */
    void sendMouseEventCode(MotionEvent e, int button, boolean pressed) {
        int[] columnAndRow = getColumnAndRow(e, false);
        int x = columnAndRow[0] + 1;
        int y = columnAndRow[1] + 1;
        if (!mEmulator.isMouseTrackingActive()) {
            if (isMouseReportingActive()) sendRemotePaneMouse(button, x, y, pressed);
            return;
        }
        if (pressed && (button == TerminalEmulator.MOUSE_WHEELDOWN_BUTTON || button == TerminalEmulator.MOUSE_WHEELUP_BUTTON)) {
            if (mMouseStartDownTime == e.getDownTime()) {
                x = mMouseScrollStartX;
                y = mMouseScrollStartY;
            } else {
                mMouseStartDownTime = e.getDownTime();
                mMouseScrollStartX = x;
                mMouseScrollStartY = y;
            }
        }
        mEmulator.sendMouseEvent(button, x, y, pressed);
    }

    /**
     * A wheel report aimed at the active pane through the tmux client. The
     * client's own mouse mode is off, so the emulator would not encode it;
     * tmux parses SGR from a client whatever it enabled, forwards the event
     * to the pane under that cell while its {@code mouse} option is off, and
     * re-encodes it in the mode the pane's program chose.
     */
    private void sendRemotePaneWheel(RemoteTmuxPane pane, int button) {
        if (mEmulator == null) return;
        int column = pane.getColumn() > 0 ? pane.getColumn() : (mEmulator.mColumns + 1) / 2;
        int row = pane.getRow() > 0 ? pane.getRow() : (mEmulator.mRows + 1) / 2;
        sendRemotePaneMouse(button, column, row, true);
    }

    /** SGR, whatever the client enabled: see {@link #sendRemotePaneWheel}. */
    private void sendRemotePaneMouse(int button, int column, int row, boolean pressed) {
        if (mTermSession == null || mEmulator == null) return;
        column = Math.max(1, Math.min(mEmulator.mColumns, column));
        row = Math.max(1, Math.min(mEmulator.mRows, row));
        mTermSession.write("\033[<" + button + ";" + column + ";" + row + (pressed ? "M" : "m"));
    }

    /** Perform a scroll, either from dragging the screen or by scrolling a mouse wheel. */
    boolean doScroll(MotionEvent event, int rowsDown) {
        boolean up = rowsDown < 0;
        int amount = Math.abs(rowsDown);
        boolean changed = false;
        final SharedScrollRoute route = scrollRoute();
        if (route == SharedScrollRoute.LocalScrollback) {
            float before = getScrollPositionPixels();
            scrollLocalPixels(rowsDown * mRenderer.mFontLineSpacing);
            return before != getScrollPositionPixels();
        }
        for (int i = 0; i < amount; i++) {
            switch (route) {
                case MouseWheel: {
                    int button = up ? TerminalEmulator.MOUSE_WHEELUP_BUTTON : TerminalEmulator.MOUSE_WHEELDOWN_BUTTON;
                    // A client that tracks the mouse itself (tmux `mouse on`
                    // over SSH) keeps the pointer-targeted emulator report.
                    RemoteTmuxPane pane = mRemoteTmuxPane;
                    if (pane != null && pane.getAlternateScreen() && !mEmulator.isMouseTrackingActive()) {
                        sendRemotePaneWheel(pane, button);
                    } else {
                        sendMouseEventCode(event, button, true);
                    }
                    changed = true;
                    break;
                }
                case ArrowKeys:
                    // Send up and down key events for scrolling, which is what some terminals do to make scroll work in
                    // e.g. less, which shifts to the alt screen without mouse handling.
                    handleKeyCode(up ? KeyEvent.KEYCODE_DPAD_UP : KeyEvent.KEYCODE_DPAD_DOWN, 0);
                    changed = true;
                    break;
                default:
                    break;
            }
        }
        return changed;
    }

    /** Continuous viewport coordinate, with zero at the live screen. */
    public float getScrollPositionPixels() {
        return mRenderer == null ? 0 : mTopRow * mRenderer.mFontLineSpacing + mScrollOffsetPixels;
    }

    private boolean scrollLocalPixels(float delta) {
        if (mRenderer == null || mEmulator == null) return false;
        if (delta < 0 && !mHistoryScrollPending && mHistoryScrollRequest != null) {
            mHistoryScrollRequest.run();
        }
        if (mHistoryScrollPending) {
            mPendingHistoryPosition = Math.min(0, mPendingHistoryPosition + delta);
            return true;
        }
        float proposed = getScrollPositionPixels() + delta;
        boolean withinBounds = setLocalScrollPosition(proposed);
        if (!withinBounds && delta < 0 && mHistoryScrollRequest != null) {
            // This frame crossed the oldest row. Request before computeScroll
            // can cancel the glide, and carry the unclamped remainder forward.
            mHistoryScrollRequest.run();
            if (mHistoryScrollPending) {
                mPendingHistoryPosition += proposed - getScrollPositionPixels();
                return true;
            }
        }
        return withinBounds;
    }

    private boolean setLocalScrollPosition(float proposed) {
        final int lineHeight = Math.max(1, mRenderer.mFontLineSpacing);
        float position = Math.max(-mEmulator.getScreen().getActiveTranscriptRows() * lineHeight,
            Math.min(0, proposed));
        mTopRow = (int) Math.floor(position / lineHeight);
        mScrollOffsetPixels = position - mTopRow * lineHeight;
        awakenScrollBars();
        invalidate();
        return position == proposed;
    }

    @Override
    public void computeScroll() {
        if (mScroller.isFinished()) return;
        if (!canSmoothScroll()) {
            cancelSmoothScroll();
            return;
        }
        if (mScroller.computeScrollOffset()) {
            int y = mScroller.getCurrY();
            boolean withinBounds = scrollLocalPixels(y - mLastScrollerY);
            mLastScrollerY = y;
            if (!withinBounds) cancelSmoothScroll();
            else if (!mScroller.isFinished()) postInvalidateOnAnimation();
        }
    }

    private boolean canSmoothScroll() {
        return mEmulator != null && !isSelectingText() && TerminalSmoothScrollPolicy.canGlide(mSmoothScrollingEnabled, scrollRoute());
    }

    /** Overriding {@link View#onGenericMotionEvent(MotionEvent)}. */
    @Override
    public boolean onGenericMotionEvent(MotionEvent event) {
        if (mEmulator != null && event.isFromSource(InputDevice.SOURCE_MOUSE)
            && event.getAction() == MotionEvent.ACTION_HOVER_MOVE
            && mEmulator.isMouseTrackingActive() && !isSelectingText()
            && mTopRow == 0 && mScrollOffsetPixels == 0) {
            // The emulator suppresses unpressed motion for modes 1000/1002.
            sendMouseEventCode(event, TerminalEmulator.MOUSE_MOVED, true);
            return true;
        }
        if (mEmulator != null && event.isFromSource(InputDevice.SOURCE_MOUSE) && event.getAction() == MotionEvent.ACTION_SCROLL) {
            cancelSmoothScroll();
            // Handle mouse wheel scrolling.
            boolean up = event.getAxisValue(MotionEvent.AXIS_VSCROLL) > 0.0f;
            doScroll(event, up ? -3 : 3);
            return true;
        }
        return false;
    }

    @SuppressLint("ClickableViewAccessibility")
    @Override
    public boolean onTouchEvent(MotionEvent event) {
        if (mEmulator == null) return true;
        final int action = event.getAction();
        if (action == MotionEvent.ACTION_CANCEL) cancelSmoothScroll();

        if (isSelectingText()) {
            updateFloatingToolbarVisibility(event);
            mGestureRecognizer.onTouchEvent(event);
            return true;
        } else if (event.isFromSource(InputDevice.SOURCE_MOUSE)) {
            if (event.isButtonPressed(MotionEvent.BUTTON_SECONDARY)) {
                if (action == MotionEvent.ACTION_DOWN) showContextMenu();
                return true;
            } else if (event.isButtonPressed(MotionEvent.BUTTON_TERTIARY)) {
                ClipboardManager clipboardManager = (ClipboardManager) getContext().getSystemService(Context.CLIPBOARD_SERVICE);
                ClipData clipData = clipboardManager.getPrimaryClip();
                if (clipData != null) {
                    ClipData.Item clipItem = clipData.getItemAt(0);
                    if (clipItem != null) {
                        CharSequence text = clipItem.coerceToText(getContext());
                        if (!TextUtils.isEmpty(text)) {
                            followLiveOutput();
                            mEmulator.paste(text.toString());
                        }
                    }
                }
            } else if (isMouseReportingActive()) { // BUTTON_PRIMARY.
                switch (event.getAction()) {
                    case MotionEvent.ACTION_DOWN:
                    case MotionEvent.ACTION_UP:
                        sendMouseEventCode(event, TerminalEmulator.MOUSE_LEFT_BUTTON, event.getAction() == MotionEvent.ACTION_DOWN);
                        break;
                    case MotionEvent.ACTION_MOVE:
                        sendMouseEventCode(event, TerminalEmulator.MOUSE_LEFT_BUTTON_MOVED, true);
                        break;
                }
            }
        }

        mGestureRecognizer.onTouchEvent(event);
        return true;
    }

    @Override
    public boolean onKeyPreIme(int keyCode, KeyEvent event) {
        if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
            mClient.logInfo(LOG_TAG, "onKeyPreIme(keyCode=" + keyCode + ", event=" + event + ")");
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            cancelRequestAutoFill();
            if (isSelectingText()) {
                stopTextSelectionMode();
                return true;
            } else if (mClient.shouldBackButtonBeMappedToEscape()) {
                // Intercept back button to treat it as escape:
                switch (event.getAction()) {
                    case KeyEvent.ACTION_DOWN:
                        return onKeyDown(keyCode, event);
                    case KeyEvent.ACTION_UP:
                        return onKeyUp(keyCode, event);
                }
            }
        } else if (mClient.shouldUseCtrlSpaceWorkaround() &&
                   keyCode == KeyEvent.KEYCODE_SPACE && event.isCtrlPressed()) {
            /* ctrl+space does not work on some ROMs without this workaround.
               However, this breaks it on devices where it works out of the box. */
            return onKeyDown(keyCode, event);
        }
        return super.onKeyPreIme(keyCode, event);
    }

    /**
     * Key presses in software keyboards will generally NOT trigger this listener, although some
     * may elect to do so in some situations. Do not rely on this to catch software key presses.
     * Gboard calls this when shouldEnforceCharBasedInput() is disabled (InputType.TYPE_NULL) instead
     * of calling commitText(), with deviceId=-1. However, Hacker's Keyboard, OpenBoard, LG Keyboard
     * call commitText().
     *
     * This function may also be called directly without android calling it, like by
     * `TerminalExtraKeys` which generates a KeyEvent manually which uses {@link KeyCharacterMap#VIRTUAL_KEYBOARD}
     * as the device (deviceId=-1), as does Gboard. That would normally use mappings defined in
     * `/system/usr/keychars/Virtual.kcm`. You can run `dumpsys input` to find the `KeyCharacterMapFile`
     * used by virtual keyboard or hardware keyboard. Note that virtual keyboard device is not the
     * same as software keyboard, like Gboard, etc. Its a fake device used for generating events and
     * for testing.
     *
     * We handle shift key in `commitText()` to convert codepoint to uppercase case there with a
     * call to {@link Character#toUpperCase(int)}, but here we instead rely on getUnicodeChar() for
     * conversion of keyCode, for both hardware keyboard shift key (via effectiveMetaState) and
     * `mClient.readShiftKey()`, based on value in kcm files.
     * This may result in different behaviour depending on keyboard and android kcm files set for the
     * InputDevice for the event passed to this function. This will likely be an issue for non-english
     * languages since `Virtual.kcm` in english only by default or at least in AOSP. For both hardware
     * shift key (via effectiveMetaState) and `mClient.readShiftKey()`, `getUnicodeChar()` is used
     * for shift specific behaviour which usually is to uppercase.
     *
     * For fn key on hardware keyboard, android checks kcm files for hardware keyboards, which is
     * `Generic.kcm` by default, unless a vendor specific one is defined. The event passed will have
     * {@link KeyEvent#META_FUNCTION_ON} set. If the kcm file only defines a single character or unicode
     * code point `\\uxxxx`, then only one event is passed with that value. However, if kcm defines
     * a `fallback` key for fn or others, like `key DPAD_UP { ... fn: fallback PAGE_UP }`, then
     * android will first pass an event with original key `DPAD_UP` and {@link KeyEvent#META_FUNCTION_ON}
     * set. But this function will not consume it and android will pass another event with `PAGE_UP`
     * and {@link KeyEvent#META_FUNCTION_ON} not set, which will be consumed.
     *
     * Now there are some other issues as well, firstly ctrl and alt flags are not passed to
     * `getUnicodeChar()`, so modified key values in kcm are not used. Secondly, if the kcm file
     * for other modifiers like shift or fn define a non-alphabet, like { fn: '\u0015' } to act as
     * DPAD_LEFT, the `getUnicodeChar()` will correctly return `21` as the code point but action will
     * not happen because the `handleKeyCode()` function that transforms DPAD_LEFT to `\033[D`
     * escape sequence for the terminal to perform the left action would not be called since its
     * called before `getUnicodeChar()` and terminal will instead get `21 0x15 Negative Acknowledgement`.
     * The solution to such issues is calling `getUnicodeChar()` before the call to `handleKeyCode()`
     * if user has defined a custom kcm file, like done in POC mentioned in #2237. Note that
     * Hacker's Keyboard calls `commitText()` so don't test fn/shift with it for this function.
     * https://github.com/termux/termux-app/pull/2237
     * https://github.com/agnostic-apollo/termux-app/blob/terminal-code-point-custom-mapping/terminal-view/src/main/java/com/termux/view/TerminalView.java
     *
     * Key Character Map (kcm) and Key Layout (kl) files info:
     * https://source.android.com/devices/input/key-character-map-files
     * https://source.android.com/devices/input/key-layout-files
     * https://source.android.com/devices/input/keyboard-devices
     * AOSP kcm and kl files:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/data/keyboards
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/packages/InputDevices/res/raw
     *
     * KeyCodes:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/core/java/android/view/KeyEvent.java
     * https://cs.android.com/android/platform/superproject/+/master:frameworks/native/include/android/keycodes.h
     *
     * `dumpsys input`:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/services/inputflinger/reader/EventHub.cpp;l=1917
     *
     * Loading of keymap:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/services/inputflinger/reader/EventHub.cpp;l=1644
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/libs/input/Keyboard.cpp;l=41
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/libs/input/InputDevice.cpp
     * OVERLAY keymaps for hardware keyboards may be combined as well:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/libs/input/KeyCharacterMap.cpp;l=165
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/libs/input/KeyCharacterMap.cpp;l=831
     *
     * Parse kcm file:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/libs/input/KeyCharacterMap.cpp;l=727
     * Parse key value:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/libs/input/KeyCharacterMap.cpp;l=981
     *
     * `KeyEvent.getUnicodeChar()`
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/core/java/android/view/KeyEvent.java;l=2716
     * https://cs.android.com/android/platform/superproject/+/master:frameworks/base/core/java/android/view/KeyCharacterMap.java;l=368
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/core/jni/android_view_KeyCharacterMap.cpp;l=117
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/libs/input/KeyCharacterMap.cpp;l=231
     *
     * Keyboard layouts advertised by applications, like for hardware keyboards via #ACTION_QUERY_KEYBOARD_LAYOUTS
     * Config is stored in `/data/system/input-manager-state.xml`
     * https://github.com/ris58h/custom-keyboard-layout
     * Loading from apps:
     * https://cs.android.com/android/platform/superproject/+/master:frameworks/base/services/core/java/com/android/server/input/InputManagerService.java;l=1221
     * Set:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/core/java/android/hardware/input/InputManager.java;l=89
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/core/java/android/hardware/input/InputManager.java;l=543
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:packages/apps/Settings/src/com/android/settings/inputmethod/KeyboardLayoutDialogFragment.java;l=167
     * https://cs.android.com/android/platform/superproject/+/master:frameworks/base/services/core/java/com/android/server/input/InputManagerService.java;l=1385
     * https://cs.android.com/android/platform/superproject/+/master:frameworks/base/services/core/java/com/android/server/input/PersistentDataStore.java
     * Get overlay keyboard layout
     * https://cs.android.com/android/platform/superproject/+/master:frameworks/base/services/core/java/com/android/server/input/InputManagerService.java;l=2158
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/services/core/jni/com_android_server_input_InputManagerService.cpp;l=616
     */
    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
            mClient.logInfo(LOG_TAG, "onKeyDown(keyCode=" + keyCode + ", isSystem()=" + event.isSystem() + ", event=" + event + ")");
        if (mEmulator == null) return true;
        if (isSelectingText()) {
            stopTextSelectionMode();
        }
        // Keep the IME line mirror truthful about bytes this key will produce
        // outside the InputConnection (hardware keys, and DEL/Enter that IMEs
        // dispatch as key events).
        if (mImeConnection != null) mImeConnection.noteExternalKey(keyCode);

        if (mClient.onKeyDown(keyCode, event, mTermSession)) {
            invalidate();
            return true;
        } else if (event.isSystem() && (!mClient.shouldBackButtonBeMappedToEscape() || keyCode != KeyEvent.KEYCODE_BACK)) {
            return super.onKeyDown(keyCode, event);
        } else if (event.getAction() == KeyEvent.ACTION_MULTIPLE && keyCode == KeyEvent.KEYCODE_UNKNOWN) {
            followLiveOutput();
            mTermSession.write(event.getCharacters());
            return true;
        }

        final int metaState = event.getMetaState();
        final boolean controlDown = event.isCtrlPressed() || mClient.readControlKey();
        final boolean leftAltDown = (metaState & KeyEvent.META_ALT_LEFT_ON) != 0 || mClient.readAltKey();
        final boolean shiftDown = event.isShiftPressed() || mClient.readShiftKey();
        final boolean rightAltDownFromEvent = (metaState & KeyEvent.META_ALT_RIGHT_ON) != 0;

        int keyMod = 0;
        if (controlDown) keyMod |= KeyHandler.KEYMOD_CTRL;
        if (event.isAltPressed() || leftAltDown) keyMod |= KeyHandler.KEYMOD_ALT;
        if (shiftDown) keyMod |= KeyHandler.KEYMOD_SHIFT;
        if (event.isNumLockOn()) keyMod |= KeyHandler.KEYMOD_NUM_LOCK;
        // https://github.com/termux/termux-app/issues/731
        if (!event.isFunctionPressed() && handleKeyCode(keyCode, keyMod)) {
            if (TERMINAL_VIEW_KEY_LOGGING_ENABLED) mClient.logInfo(LOG_TAG, "handleKeyCode() took key event");
            return true;
        }

        // Clear Ctrl since we handle that ourselves:
        int bitsToClear = KeyEvent.META_CTRL_MASK;
        if (rightAltDownFromEvent) {
            // Let right Alt/Alt Gr be used to compose characters.
        } else {
            // Use left alt to send to terminal (e.g. Left Alt+B to jump back a word), so remove:
            bitsToClear |= KeyEvent.META_ALT_ON | KeyEvent.META_ALT_LEFT_ON;
        }
        int effectiveMetaState = event.getMetaState() & ~bitsToClear;

        if (shiftDown) effectiveMetaState |= KeyEvent.META_SHIFT_ON | KeyEvent.META_SHIFT_LEFT_ON;
        if (mClient.readFnKey()) effectiveMetaState |= KeyEvent.META_FUNCTION_ON;

        int result = event.getUnicodeChar(effectiveMetaState);
        if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
            mClient.logInfo(LOG_TAG, "KeyEvent#getUnicodeChar(" + effectiveMetaState + ") returned: " + result);
        if (result == 0) {
            return false;
        }

        int oldCombiningAccent = mCombiningAccent;
        if ((result & KeyCharacterMap.COMBINING_ACCENT) != 0) {
            // If entered combining accent previously, write it out:
            if (mCombiningAccent != 0)
                inputCodePoint(mCombiningAccent, controlDown, leftAltDown);
            mCombiningAccent = result & KeyCharacterMap.COMBINING_ACCENT_MASK;
        } else {
            if (mCombiningAccent != 0) {
                int combinedChar = KeyCharacterMap.getDeadChar(mCombiningAccent, result);
                if (combinedChar > 0) result = combinedChar;
                mCombiningAccent = 0;
            }
            inputCodePoint(result, controlDown, leftAltDown);
        }

        if (mCombiningAccent != oldCombiningAccent) invalidate();

        return true;
    }

    public void inputCodePoint(int codePoint, boolean controlDownFromEvent, boolean leftAltDownFromEvent) {
        followLiveOutput();
        if (TERMINAL_VIEW_KEY_LOGGING_ENABLED) {
            mClient.logInfo(LOG_TAG, "inputCodePoint(codePoint=" + codePoint + ", controlDownFromEvent=" + controlDownFromEvent + ", leftAltDownFromEvent="
                + leftAltDownFromEvent + ")");
        }

        if (mTermSession == null) return;

        // A control byte from a physical key ends the line the IME mirror
        // describes (no-op while an InputConnection operation is translating).
        if (mImeConnection != null && (controlDownFromEvent || leftAltDownFromEvent || codePoint < 32 || codePoint == 127))
            mImeConnection.noteExternalControlByte();

        // Ensure cursor is shown when a key is pressed down like long hold on (arrow) keys
        if (mEmulator != null)
            mEmulator.setCursorBlinkState(true);

        final boolean controlDown = controlDownFromEvent || mClient.readControlKey();
        final boolean altDown = leftAltDownFromEvent || mClient.readAltKey();

        if (mClient.onCodePoint(codePoint, controlDown, mTermSession)) return;

        if (controlDown) {
            if (codePoint >= 'a' && codePoint <= 'z') {
                codePoint = codePoint - 'a' + 1;
            } else if (codePoint >= 'A' && codePoint <= 'Z') {
                codePoint = codePoint - 'A' + 1;
            } else if (codePoint == ' ' || codePoint == '2') {
                codePoint = 0;
            } else if (codePoint == '[' || codePoint == '3') {
                codePoint = 27; // ^[ (Esc)
            } else if (codePoint == '\\' || codePoint == '4') {
                codePoint = 28;
            } else if (codePoint == ']' || codePoint == '5') {
                codePoint = 29;
            } else if (codePoint == '^' || codePoint == '6') {
                codePoint = 30; // control-^
            } else if (codePoint == '_' || codePoint == '7' || codePoint == '/') {
                // "Ctrl-/ sends 0x1f which is equivalent of Ctrl-_ since the days of VT102"
                // - http://apple.stackexchange.com/questions/24261/how-do-i-send-c-that-is-control-slash-to-the-terminal
                codePoint = 31;
            } else if (codePoint == '8') {
                codePoint = 127; // DEL
            }
        }

        if (codePoint > -1) {
            // Work around bluetooth keyboards sending funny unicode characters instead
            // of the more normal ones from ASCII that terminal programs expect - the
            // desire to input the original characters should be low.
            switch (codePoint) {
                case 0x02DC: // SMALL TILDE.
                    codePoint = 0x007E; // TILDE (~).
                    break;
                case 0x02CB: // MODIFIER LETTER GRAVE ACCENT.
                    codePoint = 0x0060; // GRAVE ACCENT (`).
                    break;
                case 0x02C6: // MODIFIER LETTER CIRCUMFLEX ACCENT.
                    codePoint = 0x005E; // CIRCUMFLEX ACCENT (^).
                    break;
            }

            // If left alt, send escape before the code point to make e.g. Alt+B and Alt+F work in readline:
            mTermSession.writeCodePoint(altDown, codePoint);
        }
    }

    /** Input the specified keyCode if applicable and return if the input was consumed. */
    public boolean handleKeyCode(int keyCode, int keyMod) {
        // Ensure cursor is shown when a key is pressed down like long hold on (arrow) keys
        if (mEmulator != null)
            mEmulator.setCursorBlinkState(true);

        if (handleKeyCodeAction(keyCode, keyMod))
            return true;

        TerminalEmulator term = mTermSession.getEmulator();
        String code = KeyHandler.getCode(keyCode, keyMod, term.isCursorKeysApplicationMode(), term.isKeypadApplicationMode());
        if (code == null) return false;
        followLiveOutput();
        mTermSession.write(code);
        return true;
    }

    public boolean handleKeyCodeAction(int keyCode, int keyMod) {
        boolean shiftDown = (keyMod & KeyHandler.KEYMOD_SHIFT) != 0;

        switch (keyCode) {
            case KeyEvent.KEYCODE_PAGE_UP:
            case KeyEvent.KEYCODE_PAGE_DOWN:
                // shift+page_up and shift+page_down should scroll scrollback history instead of
                // scrolling command history or changing pages
                if (shiftDown) {
                    long time = SystemClock.uptimeMillis();
                    MotionEvent motionEvent = MotionEvent.obtain(time, time, MotionEvent.ACTION_DOWN, 0, 0, 0);
                    doScroll(motionEvent, keyCode == KeyEvent.KEYCODE_PAGE_UP ? -mEmulator.mRows : mEmulator.mRows);
                    motionEvent.recycle();
                    return true;
                }
        }

       return false;
    }

    /**
     * Called when a key is released in the view.
     *
     * @param keyCode The keycode of the key which was released.
     * @param event   A {@link KeyEvent} describing the event.
     * @return Whether the event was handled.
     */
    @Override
    public boolean onKeyUp(int keyCode, KeyEvent event) {
        if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
            mClient.logInfo(LOG_TAG, "onKeyUp(keyCode=" + keyCode + ", event=" + event + ")");

        // Do not return for KEYCODE_BACK and send it to the client since user may be trying
        // to exit the activity.
        if (mEmulator == null && keyCode != KeyEvent.KEYCODE_BACK) return true;

        if (mClient.onKeyUp(keyCode, event)) {
            invalidate();
            return true;
        } else if (event.isSystem()) {
            // Let system key events through.
            return super.onKeyUp(keyCode, event);
        }

        return true;
    }

    /** Coalesce physical layout before mutating the emulator's live grid. */
    public long layoutResizeDelayMillis = 0;
    private final android.os.Handler mLayoutResizeHandler = new android.os.Handler(android.os.Looper.getMainLooper());
    private Runnable mPendingLayoutResize;
    private boolean mResumeLayoutResizeOnAttach;

    public void cancelPendingLayoutResize() {
        if (mPendingLayoutResize != null) mLayoutResizeHandler.removeCallbacks(mPendingLayoutResize);
        mPendingLayoutResize = null;
        mResumeLayoutResizeOnAttach = false;
    }

    /** Called during layout when physical bounds change, including initial attachment. */
    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        cancelPendingLayoutResize();
        if (mEmulator == null || layoutResizeDelayMillis <= 0) {
            updateSize();
            return;
        }
        if (w <= 0 || h <= 0) return;
        int columns = Math.max(4, (int) (w / mRenderer.mFontWidth));
        int rows = Math.max(4, (h - mRenderer.mFontLineSpacingAndAscent) / mRenderer.mFontLineSpacing);
        if (columns == mEmulator.mColumns && rows == mEmulator.mRows) return;
        mPendingLayoutResize = () -> {
            mPendingLayoutResize = null;
            updateSize();
        };
        mLayoutResizeHandler.postDelayed(mPendingLayoutResize, layoutResizeDelayMillis);
    }

    /** Check if the terminal size in rows and columns should be updated. */
    public void updateSize() {
        cancelPendingLayoutResize();
        int viewWidth = getWidth();
        int viewHeight = getHeight();
        if (viewWidth == 0 || viewHeight == 0 || mTermSession == null) return;

        // Set to 80 and 24 if you want to enable vttest.
        int newColumns = Math.max(4, (int) (viewWidth / mRenderer.mFontWidth));
        int newRows = Math.max(4, (viewHeight - mRenderer.mFontLineSpacingAndAscent) / mRenderer.mFontLineSpacing);

        if (mEmulator == null || (newColumns != mEmulator.mColumns || newRows != mEmulator.mRows)) {
            mTermSession.updateSize(newColumns, newRows, (int) mRenderer.getFontWidth(), mRenderer.getFontLineSpacing());
            mEmulator = mTermSession.getEmulator();
            mClient.onEmulatorSet();

            // Update mTerminalCursorBlinkerRunnable inner class mEmulator on session change
            if (mTerminalCursorBlinkerRunnable != null)
                mTerminalCursorBlinkerRunnable.setEmulator(mEmulator);

            cancelSmoothScroll();
            mTopRow = 0;
            mScrollOffsetPixels = 0;
            scrollTo(0, 0);
            invalidate();
        }
    }

    @Override
    protected void onDraw(Canvas canvas) {
        if (mEmulator != null) {
            // render the terminal view and highlight any selected text
            int[] sel = mDefaultSelectors;
            if (mTextSelectionCursorController != null) {
                mTextSelectionCursorController.getSelectors(sel);
            }

            mRenderer.render(mEmulator, canvas, mTopRow, mScrollOffsetPixels, sel[0], sel[1], sel[2], sel[3]);

            // render the text selection handles
            renderTextSelection();
        }
    }

    /**
     * The terminal's background is drawn by View before onDraw(). Keeping the renderer itself
     * transparent for default cells lets an app-owned wallpaper show through while explicit ANSI
     * backgrounds continue to be painted by TerminalRenderer.
     */
    public void setTerminalBackgroundDrawable(Drawable background) {
        setBackground(background);
    }

    public TerminalSession getCurrentSession() {
        return mTermSession;
    }

    private CharSequence getText() {
        return mEmulator.getScreen().getSelectedText(0, mTopRow, mEmulator.mColumns, mTopRow + mEmulator.mRows);
    }

    public int getCursorX(float x) {
        return (int) (x / mRenderer.mFontWidth);
    }

    public int getCursorY(float y) {
        return (int) (((y + mScrollOffsetPixels - 40) / mRenderer.mFontLineSpacing) + mTopRow);
    }

    public int getPointX(int cx) {
        if (cx > mEmulator.mColumns) {
            cx = mEmulator.mColumns;
        }
        return Math.round(cx * mRenderer.mFontWidth);
    }

    public int getPointY(int cy) {
        return Math.round((cy - mTopRow) * mRenderer.mFontLineSpacing - mScrollOffsetPixels);
    }

    public int getTopRow() {
        return mTopRow;
    }

    /** Selection auto-scroll moves rows without snapping the partially visible row. */
    public void scrollHistoryRows(int rows) {
        cancelSmoothScroll();
        if (scrollRoute() == SharedScrollRoute.LocalScrollback) {
            scrollLocalPixels(rows * mRenderer.mFontLineSpacing);
        }
    }

    public void setTopRow(int mTopRow) {
        cancelSmoothScroll();
        this.mTopRow = mTopRow;
        mScrollOffsetPixels = 0;
        invalidate();
    }



    /**
     * Define functions required for AutoFill API
     */
    @RequiresApi(api = Build.VERSION_CODES.O)
    @Override
    public void autofill(AutofillValue value) {
        if (value.isText()) {
            if (value.getTextValue().length() > 0) followLiveOutput();
            mTermSession.write(value.getTextValue().toString());
            resetImeLineContext();
        }

        resetAutoFill();
    }

    @RequiresApi(api = Build.VERSION_CODES.O)
    @Override
    public int getAutofillType() {
        return mAutoFillType;
    }

    @RequiresApi(api = Build.VERSION_CODES.O)
    @Override
    public String[] getAutofillHints() {
        return mAutoFillHints;
    }

    @RequiresApi(api = Build.VERSION_CODES.O)
    @Override
    public AutofillValue getAutofillValue() {
        return AutofillValue.forText("");
    }

    @RequiresApi(api = Build.VERSION_CODES.O)
    @Override
    public int getImportantForAutofill() {
        return mAutoFillImportance;
    }

    @RequiresApi(api = Build.VERSION_CODES.O)
    private synchronized void resetAutoFill() {
        // Restore none type so that AutoFill UI isn't shown anymore.
        mAutoFillType = AUTOFILL_TYPE_NONE;
        mAutoFillImportance = IMPORTANT_FOR_AUTOFILL_NO;
        mAutoFillHints = new String[0];
    }

    public AutofillManager getAutoFillManagerService() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null;

        try {
            Context context = getContext();
            if (context == null) return null;
            return context.getSystemService(AutofillManager.class);
        } catch (Exception e) {
            mClient.logStackTraceWithMessage(LOG_TAG, "Failed to get AutofillManager service", e);
            return null;
        }
    }

    public boolean isAutoFillEnabled() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false;

        try {
            AutofillManager autofillManager = getAutoFillManagerService();
            return autofillManager != null && autofillManager.isEnabled();
        } catch (Exception e) {
            mClient.logStackTraceWithMessage(LOG_TAG, "Failed to check if Autofill is enabled", e);
            return false;
        }
    }

    public synchronized void requestAutoFillUsername() {
        requestAutoFill(
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O ? new String[]{View.AUTOFILL_HINT_USERNAME} :
                null);
    }

    public synchronized void requestAutoFillPassword() {
        requestAutoFill(
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O ? new String[]{View.AUTOFILL_HINT_PASSWORD} :
            null);
    }

    public synchronized void requestAutoFill(String[] autoFillHints) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        if (autoFillHints == null || autoFillHints.length < 1) return;

        try {
            AutofillManager autofillManager = getAutoFillManagerService();
            if (autofillManager != null && autofillManager.isEnabled()) {
                // Update type that will be returned by `getAutofillType()` so that AutoFill UI is shown.
                mAutoFillType = AUTOFILL_TYPE_TEXT;
                // Update importance that will be returned by `getImportantForAutofill()` so that
                // AutoFill considers the view as important.
                mAutoFillImportance = IMPORTANT_FOR_AUTOFILL_YES;
                // Update hints that will be returned by `getAutofillHints()` for which to show AutoFill UI.
                mAutoFillHints = autoFillHints;
                autofillManager.requestAutofill(this);
            }
        } catch (Exception e) {
            mClient.logStackTraceWithMessage(LOG_TAG, "Failed to request Autofill", e);
        }
    }

    public synchronized void cancelRequestAutoFill() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        if (mAutoFillType == AUTOFILL_TYPE_NONE) return;

        try {
            AutofillManager autofillManager = getAutoFillManagerService();
            if (autofillManager != null && autofillManager.isEnabled()) {
                resetAutoFill();
                autofillManager.cancel();
            }
        } catch (Exception e) {
            mClient.logStackTraceWithMessage(LOG_TAG, "Failed to cancel Autofill request", e);
        }
    }





    /**
     * Set terminal cursor blinker rate. It must be between {@link #TERMINAL_CURSOR_BLINK_RATE_MIN}
     * and {@link #TERMINAL_CURSOR_BLINK_RATE_MAX}, otherwise it will be disabled.
     *
     * The {@link #setTerminalCursorBlinkerState(boolean, boolean)} must be called after this
     * for changes to take effect if not disabling.
     *
     * @param blinkRate The value to set.
     * @return Returns {@code true} if setting blinker rate was successfully set, otherwise [@code false}.
     */
    public synchronized boolean setTerminalCursorBlinkerRate(int blinkRate) {
        boolean result;

        // If cursor blinking rate is not valid
        if (blinkRate != 0 && (blinkRate < TERMINAL_CURSOR_BLINK_RATE_MIN || blinkRate > TERMINAL_CURSOR_BLINK_RATE_MAX)) {
            mClient.logError(LOG_TAG, "The cursor blink rate must be in between " + TERMINAL_CURSOR_BLINK_RATE_MIN + "-" + TERMINAL_CURSOR_BLINK_RATE_MAX + ": " + blinkRate);
            mTerminalCursorBlinkerRate = 0;
            result = false;
        } else {
            mClient.logVerbose(LOG_TAG, "Setting cursor blinker rate to " + blinkRate);
            mTerminalCursorBlinkerRate = blinkRate;
            result = true;
        }

        if (mTerminalCursorBlinkerRate == 0) {
            mClient.logVerbose(LOG_TAG, "Cursor blinker disabled");
            stopTerminalCursorBlinker();
        }

        return result;
    }

    /**
     * Sets whether cursor blinker should be started or stopped. Cursor blinker will only be
     * started if {@link #mTerminalCursorBlinkerRate} does not equal 0 and is between
     * {@link #TERMINAL_CURSOR_BLINK_RATE_MIN} and {@link #TERMINAL_CURSOR_BLINK_RATE_MAX}.
     *
     * This should be called when the view holding this activity is resumed or stopped so that
     * cursor blinker does not run when activity is not visible. If you call this on onResume()
     * to start cursor blinking, then ensure that {@link #mEmulator} is set, otherwise wait for the
     * {@link TerminalViewClient#onEmulatorSet()} event after calling {@link #attachSession(TerminalSession)}
     * for the first session added in the activity since blinking will not start if {@link #mEmulator}
     * is not set, like if activity is started again after exiting it with double back press. Do not
     * call this directly after {@link #attachSession(TerminalSession)} since {@link #updateSize()}
     * may return without setting {@link #mEmulator} since width/height may be 0. Its called again in
     * {@link #onSizeChanged(int, int, int, int)}. Calling on onResume() if emulator is already set
     * is necessary, since onEmulatorSet() may not be called after activity is started after device
     * display timeout with double tap and not power button.
     *
     * It should also be called on the
     * {@link com.termux.terminal.TerminalSessionClient#onTerminalCursorStateChange(boolean)}
     * callback when cursor is enabled or disabled so that blinker is disabled if cursor is not
     * to be shown. It should also be checked if activity is visible if blinker is to be started
     * before calling this.
     *
     * It should also be called after terminal is reset with {@link TerminalSession#reset()} in case
     * cursor blinker was disabled before reset due to call to
     * {@link com.termux.terminal.TerminalSessionClient#onTerminalCursorStateChange(boolean)}.
     *
     * How cursor blinker starting works is by registering a {@link Runnable} with the looper of
     * the main thread of the app which when run, toggles the cursor blinking state and re-registers
     * itself to be called with the delay set by {@link #mTerminalCursorBlinkerRate}. When cursor
     * blinking needs to be disabled, we just cancel any callbacks registered. We don't run our own
     * "thread" and let the thread for the main looper do the work for us, whose usage is also
     * required to update the UI, since it also handles other calls to update the UI as well based
     * on a queue.
     *
     * Note that when moving cursor in text editors like nano, the cursor state is quickly
     * toggled `-> off -> on`, which would call this very quickly sequentially. So that if cursor
     * is moved 2 or more times quickly, like long hold on arrow keys, it would trigger
     * `-> off -> on -> off -> on -> ...`, and the "on" callback at index 2 is automatically
     * cancelled by next "off" callback at index 3 before getting a chance to be run. For this case
     * we log only if {@link #TERMINAL_VIEW_KEY_LOGGING_ENABLED} is enabled, otherwise would clutter
     * the log. We don't start the blinking with a delay to immediately show cursor in case it was
     * previously not visible.
     *
     * @param start If cursor blinker should be started or stopped.
     * @param startOnlyIfCursorEnabled If set to {@code true}, then it will also be checked if the
     *                                 cursor is even enabled by {@link TerminalEmulator} before
     *                                 starting the cursor blinker.
     */
    public synchronized void setTerminalCursorBlinkerState(boolean start, boolean startOnlyIfCursorEnabled) {
        // Stop any existing cursor blinker callbacks
        stopTerminalCursorBlinker();

        if (mEmulator == null) return;

        mEmulator.setCursorBlinkingEnabled(false);

        if (start) {
            // If cursor blinker is not enabled or is not valid
            if (mTerminalCursorBlinkerRate < TERMINAL_CURSOR_BLINK_RATE_MIN || mTerminalCursorBlinkerRate > TERMINAL_CURSOR_BLINK_RATE_MAX)
                return;
            // If cursor blinder is to be started only if cursor is enabled
            else if (startOnlyIfCursorEnabled && ! mEmulator.isCursorEnabled()) {
                if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
                    mClient.logVerbose(LOG_TAG, "Ignoring call to start cursor blinker since cursor is not enabled");
                return;
            }

            // Start cursor blinker runnable
            if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
                mClient.logVerbose(LOG_TAG, "Starting cursor blinker with the blink rate " + mTerminalCursorBlinkerRate);
            if (mTerminalCursorBlinkerHandler == null)
                mTerminalCursorBlinkerHandler = new Handler(Looper.getMainLooper());
            mTerminalCursorBlinkerRunnable = new TerminalCursorBlinkerRunnable(mEmulator, mTerminalCursorBlinkerRate);
            mEmulator.setCursorBlinkingEnabled(true);
            mTerminalCursorBlinkerRunnable.run();
        }
    }

    /**
     * Cancel the terminal cursor blinker callbacks
     */
    private void stopTerminalCursorBlinker() {
        if (mTerminalCursorBlinkerHandler != null && mTerminalCursorBlinkerRunnable != null) {
            if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
                mClient.logVerbose(LOG_TAG, "Stopping cursor blinker");
            mTerminalCursorBlinkerHandler.removeCallbacks(mTerminalCursorBlinkerRunnable);
        }
    }

    private class TerminalCursorBlinkerRunnable implements Runnable {

        private TerminalEmulator mEmulator;
        private final int mBlinkRate;

        // Initialize with false so that initial blink state is visible after toggling
        boolean mCursorVisible = false;

        public TerminalCursorBlinkerRunnable(TerminalEmulator emulator, int blinkRate) {
            mEmulator = emulator;
            mBlinkRate = blinkRate;
        }

        public void setEmulator(TerminalEmulator emulator) {
            mEmulator = emulator;
        }

        public void run() {
            try {
                if (mEmulator != null) {
                    // Toggle the blink state and then invalidate() the view so
                    // that onDraw() is called, which then calls TerminalRenderer.render()
                    // which checks with TerminalEmulator.shouldCursorBeVisible() to decide whether
                    // to draw the cursor or not
                    mCursorVisible = !mCursorVisible;
                    //mClient.logVerbose(LOG_TAG, "Toggling cursor blink state to " + mCursorVisible);
                    mEmulator.setCursorBlinkState(mCursorVisible);
                    invalidate();
                }
            } finally {
                // Recall the Runnable after mBlinkRate milliseconds to toggle the blink state
                mTerminalCursorBlinkerHandler.postDelayed(this, mBlinkRate);
            }
        }
    }



    /**
     * Define functions required for text selection and its handles.
     */
    TextSelectionCursorController getTextSelectionCursorController() {
        if (mTextSelectionCursorController == null) {
            mTextSelectionCursorController = new TextSelectionCursorController(this);

            final ViewTreeObserver observer = getViewTreeObserver();
            if (observer != null) {
                observer.addOnTouchModeChangeListener(mTextSelectionCursorController);
            }
        }

        return mTextSelectionCursorController;
    }

    private void showTextSelectionCursors(MotionEvent event) {
        getTextSelectionCursorController().show(event);
    }

    private boolean hideTextSelectionCursors() {
        return getTextSelectionCursorController().hide();
    }

    private void renderTextSelection() {
        if (mTextSelectionCursorController != null)
            mTextSelectionCursorController.render();
    }

    public boolean isSelectingText() {
        if (mTextSelectionCursorController != null) {
            return mTextSelectionCursorController.isActive();
        } else {
            return false;
        }
    }

    /** Get the currently selected text if selecting. */
    public String getSelectedText() {
        if (isSelectingText() && mTextSelectionCursorController != null)
            return mTextSelectionCursorController.getSelectedText();
        else
            return null;
    }

    /** Get the selected text stored before "MORE" button was pressed on the context menu. */
    @Nullable
    public String getStoredSelectedText() {
        return mTextSelectionCursorController != null ? mTextSelectionCursorController.getStoredSelectedText() : null;
    }

    /** Unset the selected text stored before "MORE" button was pressed on the context menu. */
    public void unsetStoredSelectedText() {
        if (mTextSelectionCursorController != null) mTextSelectionCursorController.unsetStoredSelectedText();
    }

    private ActionMode getTextSelectionActionMode() {
        if (mTextSelectionCursorController != null) {
            return mTextSelectionCursorController.getActionMode();
        } else {
            return null;
        }
    }

    public void startTextSelectionMode(MotionEvent event) {
        cancelSmoothScroll();
        if (!requestFocus()) {
            return;
        }

        showTextSelectionCursors(event);
        mClient.copyModeChanged(isSelectingText());

        invalidate();
    }

    public void stopTextSelectionMode() {
        if (hideTextSelectionCursors()) {
            mClient.copyModeChanged(isSelectingText());
            invalidate();
        }
    }

    private void decrementYTextSelectionCursors(int decrement) {
        if (mTextSelectionCursorController != null) {
            mTextSelectionCursorController.decrementYTextSelectionCursors(decrement);
        }
    }

    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        if (mResumeLayoutResizeOnAttach) onSizeChanged(getWidth(), getHeight(), getWidth(), getHeight());

        if (mTextSelectionCursorController != null) {
            getViewTreeObserver().addOnTouchModeChangeListener(mTextSelectionCursorController);
        }
    }

    @Override
    protected void onDetachedFromWindow() {
        cancelHistoryScroll();
        boolean hadPendingLayoutResize = mPendingLayoutResize != null;
        cancelPendingLayoutResize();
        mResumeLayoutResizeOnAttach = hadPendingLayoutResize;
        super.onDetachedFromWindow();

        if (mTextSelectionCursorController != null) {
            // Might solve the following exception
            // android.view.WindowLeaked: Activity com.termux.app.TermuxActivity has leaked window android.widget.PopupWindow
            stopTextSelectionMode();

            getViewTreeObserver().removeOnTouchModeChangeListener(mTextSelectionCursorController);
            mTextSelectionCursorController.onDetached();
        }
    }



    /**
     * Define functions required for long hold toolbar.
     */
    private final Runnable mShowFloatingToolbar = new Runnable() {
        @Override
        public void run() {
            if (getTextSelectionActionMode() != null) {
                getTextSelectionActionMode().hide(0);  // hide off.
            }
        }
    };

    private void showFloatingToolbar() {
        if (getTextSelectionActionMode() != null) {
            int delay = ViewConfiguration.getDoubleTapTimeout();
            postDelayed(mShowFloatingToolbar, delay);
        }
    }

    void hideFloatingToolbar() {
        if (getTextSelectionActionMode() != null) {
            removeCallbacks(mShowFloatingToolbar);
            getTextSelectionActionMode().hide(-1);
        }
    }

    public void updateFloatingToolbarVisibility(MotionEvent event) {
        if (getTextSelectionActionMode() != null) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_MOVE:
                    hideFloatingToolbar();
                    break;
                case MotionEvent.ACTION_UP:  // fall through
                case MotionEvent.ACTION_CANCEL:
                    showFloatingToolbar();
            }
        }
    }

}
