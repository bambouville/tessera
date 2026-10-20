package com.bambouville.tessera

import android.Manifest
import android.content.Intent
import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.HapticFeedbackConstants
import android.view.View
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.key
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.zIndex
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.IntentCompat
import androidx.core.content.FileProvider
import com.bambouville.tessera.core.bridge.CoreBridge
import com.bambouville.tessera.core.bridge.CoreBridgeState
import com.bambouville.tessera.core.bridge.SharedInputEncoding
import com.bambouville.tessera.core.bridge.SharedModifierBehavior
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationCoordinator
import com.bambouville.tessera.agent.platform.LiveAgentSessionRegistry
import com.bambouville.tessera.data.AndroidHostRepository
import com.bambouville.tessera.data.AndroidAppPreferences
import com.bambouville.tessera.data.AppPreferences
import com.bambouville.tessera.data.AccessoryBarKey
import com.bambouville.tessera.data.accessoryBarDefaults
import com.bambouville.tessera.data.persistedAccessoryBarIds
import com.bambouville.tessera.data.AndroidKnownHostsRepository
import com.bambouville.tessera.data.AndroidIdentityRepository
import com.bambouville.tessera.data.AndroidSessionRestoreRepository
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.continuity.AndroidForegroundRestoreStore
import com.bambouville.tessera.data.continuity.AndroidPendingContinuationRecoveryStore
import com.bambouville.tessera.data.continuity.ForegroundRestoreConnectionState
import com.bambouville.tessera.data.continuity.ForegroundRestoreDocument
import com.bambouville.tessera.data.continuity.ForegroundRestoreLiveSession
import com.bambouville.tessera.data.continuity.ForegroundRestorePersistMode
import com.bambouville.tessera.data.continuity.ForegroundRestoreSnapshot
import com.bambouville.tessera.data.continuity.ForegroundRestoreStartup
import com.bambouville.tessera.data.continuity.ForegroundRestoreStartupAction
import com.bambouville.tessera.data.continuity.ForegroundRestoreStartupReason
import com.bambouville.tessera.data.continuity.ForegroundRestoreWindow
import com.bambouville.tessera.data.continuity.ForegroundRestoreWindowClosure
import com.bambouville.tessera.data.continuity.RestorePersistPayload
import com.bambouville.tessera.data.continuity.RestorePersistReport
import com.bambouville.tessera.data.continuity.SessionRestoreCoordinator
import com.bambouville.tessera.data.continuity.SessionRestorePolicy
import com.bambouville.tessera.data.continuity.SessionRestorePresentationPolicy
import com.bambouville.tessera.data.continuity.PendingContinuationRecovery
import com.bambouville.tessera.data.continuity.isFreshAt
import com.bambouville.tessera.data.continuity.normalizedRestoreTransportKind
import com.bambouville.tessera.feature.hosts.HostListScreen
import com.bambouville.tessera.feature.hosts.IdentityListScreen
import com.bambouville.tessera.feature.hosts.KnownHostsScreen
import com.bambouville.tessera.feature.session.ExternalUiExcursions
import com.bambouville.tessera.feature.session.LiveSessionStore
import com.bambouville.tessera.feature.session.SessionSwitcherSession
import com.bambouville.tessera.feature.session.ProgramAttentionCounts
import com.bambouville.tessera.feature.session.ProgramAttentionTone
import com.bambouville.tessera.feature.session.ProgramStatusAgentInput
import com.bambouville.tessera.feature.session.ProgramStatusCenter
import com.bambouville.tessera.feature.session.ProgramStatusFocusRequest
import com.bambouville.tessera.feature.session.ProgramStatusQueries
import com.bambouville.tessera.feature.session.ProgramStatusSessionState
import com.bambouville.tessera.feature.session.programStatusCountLine
import com.bambouville.tessera.feature.session.programStatusCountSummary
import com.bambouville.tessera.feature.session.SessionSwitcherStatus
import com.bambouville.tessera.feature.session.SshSessionScreen
import com.bambouville.tessera.feature.session.SshSessionUiState
import com.bambouville.tessera.feature.pairing.PairingScreen
import com.bambouville.tessera.feature.pairing.CrossDevicePairingCoordinator
import com.bambouville.tessera.files.PendingShareUpload
import com.bambouville.tessera.files.RemoteFilesConstants
import com.bambouville.tessera.files.ShareTextMode
import com.bambouville.tessera.files.ShareUploadDestination
import com.bambouville.tessera.files.ShareUploadPolicy
import com.bambouville.tessera.files.ShareUploadSheet
import com.bambouville.tessera.files.ShareUploadTarget
import com.bambouville.tessera.files.SharedTextStaging
import com.bambouville.tessera.files.SharedUriIngress
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TerminalFontCatalog
import com.bambouville.tessera.design.TesseraTerminalFontPicker
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraConfirmDialog
import com.bambouville.tessera.design.TesseraEmptyState
import com.bambouville.tessera.design.TesseraDialog
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraKicker
import com.bambouville.tessera.design.TesseraLogoMark
import com.bambouville.tessera.design.TesseraNavigationRow
import com.bambouville.tessera.design.TesseraPageHeader
import com.bambouville.tessera.design.TesseraRowGlyph
import com.bambouville.tessera.design.TesseraSlider
import com.bambouville.tessera.design.TesseraSegmented
import com.bambouville.tessera.design.TesseraStatusDot
import com.bambouville.tessera.design.TesseraSubPageHeader
import com.bambouville.tessera.design.TesseraTag
import com.bambouville.tessera.design.TesseraTheme
import com.bambouville.tessera.design.TesseraToggleRow
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import com.bambouville.tessera.lifecycle.DiagnosticLogStore
import com.bambouville.tessera.feature.session.bell.AndroidBellController
import com.bambouville.tessera.feature.session.bell.BellEvent
import com.bambouville.tessera.feature.session.bell.BellSource
import com.bambouville.tessera.feature.session.bell.toBellPreferences
import com.bambouville.tessera.terminal.TerminalBackgroundFillMode
import com.bambouville.tessera.terminal.TerminalBackgroundImage
import com.bambouville.tessera.terminal.TerminalBackgroundImageStore
import com.bambouville.tessera.terminal.TerminalTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import android.provider.Settings
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Locale
import java.util.UUID
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import com.bambouville.tessera.feature.agentcenter.AgentCenterPresenter
import com.bambouville.tessera.feature.agentcenter.AgentCenterScreen
import com.bambouville.tessera.feature.agentcenter.targetsLiveSession
import com.bambouville.tessera.feature.agentcenter.navigateToExistingAgentTerminal
import com.bambouville.tessera.feature.agentcenter.AgentNotificationContract

/**
 * The agent runtime, for as long as the process lives.
 *
 * It used to hang off the Activity's own `ViewModelStore`, which survives a
 * configuration change and nothing else — so a real Activity destroy cleared
 * it. That was consistent while the sessions died with the Activity too. Now
 * that they do not, a surviving controller would have gone on holding a
 * coordinator that had already been closed, and its agents would have vanished
 * from a list that never learned they were still there.
 */
private object AgentRuntimeStore : ViewModelStoreOwner {
    override val viewModelStore = ViewModelStore()
}

class MainActivity : ComponentActivity() {
    private val agentRuntime: AgentSessionViewModel by lazy {
        ViewModelProvider(
            AgentRuntimeStore,
            ViewModelProvider.AndroidViewModelFactory(application),
        )[AgentSessionViewModel::class.java]
    }
    private val pendingShare = MutableStateFlow<SharedUriIngress.Payload?>(null)

    /** Host named by the direct-share shortcut this share arrived through. */
    private val pendingShareTargetId = MutableStateFlow<String?>(null)

    /**
     * The share the ingress sheet has already routed, held here rather than in
     * composition so it outlives an activity restart: the payload is gone from
     * the sending app by then, and losing it would be a silent drop.
     */
    private val routedShare = MutableStateFlow<PendingShareUpload?>(null)

    override fun onStart() {
        // Before ON_START is dispatched: a composition computed in this new
        // start epoch is what ends a real background for the show rule.
        LiveSessionStore.get().activityStarted()
        super.onStart()
        agentRuntime.presenter.setApplicationForeground(true)
    }

    // Start fail-closed until the persisted policy is loaded; this prevents protected host data
    // from flashing for one composition on process launch.
    private val locked = MutableStateFlow(true)
    private val appLockError = MutableStateFlow<String?>(null)
    private lateinit var preferences: AndroidAppPreferences
    private lateinit var diagnostics: DiagnosticLogStore
    @Volatile private var appLockEnabled = false
    /**
     * Tessera's own trips out of the activity, counted: they nest (a picker
     * over a credential prompt), and one boolean was cleared by whichever
     * finished first while another was still up.
     */
    private val externalUi = ExternalUiExcursions()
    private val unlockExcursion = externalUi.slot()
    @Volatile private var pairingCoordinator: CrossDevicePairingCoordinator? = null
    private val unlockLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        unlockExcursion(false)
        if (result.resultCode == Activity.RESULT_OK) locked.value = false
    }

    private fun isRealBackgroundEdge(): Boolean = !isChangingConfigurations && !externalUi.active

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Fail closed until the persisted app-switcher policy loads below.
        setRecentsScreenshotEnabled(false)
        applyDebugAcceptanceKeepAwake(intent)
        diagnostics = DiagnosticLogStore(applicationContext)
        diagnostics.record(
            "app_launch",
            mapOf(
                "version" to BuildConfig.VERSION_NAME,
                "sdk" to Build.VERSION.SDK_INT.toString(),
                "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
            ),
        )
        preferences = AndroidAppPreferences(applicationContext)
        lifecycleScope.launch {
            preferences.values.collectLatest { value ->
                // Saved Recents snapshots follow Settings → security → hide content
                // in app switcher (off by default; app lock forces it on).
                setRecentsScreenshotEnabled(!value.hidesContentInAppSwitcher)
                val becameEnabled = value.appLockEnabled && !appLockEnabled
                appLockEnabled = value.appLockEnabled
                if (becameEnabled || !value.appLockEnabled) locked.value = value.appLockEnabled
            }
        }
        savedInstanceState?.let { saved ->
            val uris = saved.getStringArrayList(STATE_PENDING_UPLOADS)?.map(Uri::parse).orEmpty()
            val text = saved.getString(STATE_PENDING_SHARE_TEXT)
            if (uris.isNotEmpty() || !text.isNullOrEmpty()) {
                pendingShare.value = SharedUriIngress.Payload(uris = uris, text = text)
            }
            pendingShareTargetId.value = saved.getString(STATE_PENDING_SHARE_TARGET)
            routedShare.value = readRoutedShare(saved)
        }
        acceptShareIntent(intent)
        AgentNotificationContract.parse(intent)?.let(agentRuntime::handleNotification)
        enableEdgeToEdge()
        setContent {
            TesseraTheme {
                val notificationTarget by agentRuntime.notificationTarget.collectAsState()
                FoundationScreen(
                    pendingShare = pendingShare.collectAsState().value,
                    pendingShareTargetId = pendingShareTargetId.collectAsState().value,
                    onShareRouted = { routed ->
                        routedShare.value = routed
                        pendingShare.value = null
                        pendingShareTargetId.value = null
                    },
                    onShareDiscarded = {
                        pendingShare.value = null
                        pendingShareTargetId.value = null
                    },
                    routedShare = routedShare.collectAsState().value,
                    onRoutedShareConsumed = { routedShare.value = null },
                    preferences = preferences,
                    locked = locked.collectAsState().value,
                    appLockError = appLockError.collectAsState().value,
                    onUnlock = ::requestUnlock,
                    onAppLockChanged = ::setAppLockEnabled,
                    externalUi = externalUi,
                    isRealBackgroundEdge = ::isRealBackgroundEdge,
                    onPairingCoordinatorChanged = { pairingCoordinator = it },
                    diagnostics = diagnostics,
                    onUploadDiagnosticLog = ::uploadDiagnosticLog,
                    agentSessions = agentRuntime.sessions,
                    agentIntegration = agentRuntime.integration,
                    agentPresenter = agentRuntime.presenter,
                    notificationThreadKey = notificationTarget?.threadKey,
                    notificationPrearmedAnswer = notificationTarget?.prearmedAnswer ?: false,
                    onNotificationThreadConsumed = agentRuntime::consumeNotificationTarget,
                )
            }
        }
    }

    override fun onStop() {
        // §6.9: only a real background edge can hide a session. Reported here,
        // before ON_STOP is dispatched, because the composition's frame clock
        // pauses at the stop and never sees it as a value.
        val realBackground = isRealBackgroundEdge()
        // An excursion's stop is transparent only while it stays short: one
        // the user turns into a real background (Home from the picker) must
        // still hide, or the return is no show and leaves them veiled.
        LiveSessionStore.get().activityStopped(
            realBackground,
            duringExcursion = !isChangingConfigurations && externalUi.active,
        )
        agentRuntime.presenter.setApplicationForeground(false)
        super.onStop()
        if (realBackground) {
            // The local pairing listener is foreground-only even when app lock is disabled.
            pairingCoordinator?.applicationDidLock()
            if (appLockEnabled) locked.value = true
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        applyDebugAcceptanceKeepAwake(intent)
        acceptShareIntent(intent)
        AgentNotificationContract.parse(intent)?.let(agentRuntime::handleNotification)
    }

    private var acceptanceKeepAwake: kotlinx.coroutines.Job? = null

    /** External physical-device QA must not own the app through instrumentation:
     * Android kills the target when that runner ends. This debug-only bounded
     * window flag neither changes lock settings nor suppresses session restore. */
    private fun applyDebugAcceptanceKeepAwake(intent: Intent?) {
        if (!BuildConfig.DEBUG || intent?.hasExtra("tesseraAcceptanceKeepAwakeSeconds") != true) return
        val seconds = intent.getIntExtra("tesseraAcceptanceKeepAwakeSeconds", 0).coerceIn(0, 1800)
        acceptanceKeepAwake?.cancel()
        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (seconds == 0) return
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        acceptanceKeepAwake = lifecycleScope.launch {
            kotlinx.coroutines.delay(seconds * 1000L)
            window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        val share = pendingShare.value
        outState.putStringArrayList(
            STATE_PENDING_UPLOADS,
            ArrayList(share?.uris.orEmpty().map(Uri::toString)),
        )
        outState.putString(STATE_PENDING_SHARE_TEXT, share?.text)
        outState.putString(STATE_PENDING_SHARE_TARGET, pendingShareTargetId.value)
        writeRoutedShare(outState, routedShare.value)
        super.onSaveInstanceState(outState)
    }

    private fun acceptShareIntent(intent: Intent) {
        val payload = SharedUriIngress.from(intent) ?: return
        // A direct-share shortcut names the host before the app is even up;
        // read it before the intent is scrubbed below.
        val shortcutHostId = ShareTargetPublisher.selectedHostId(intent)
        pendingShare.value = SharedUriIngress.append(pendingShare.value, payload)
        if (shortcutHostId != null) {
            pendingShareTargetId.value = shortcutHostId
            ShareTargetPublisher.reportUsed(this, shortcutHostId)
        }
        // Activity recreation reuses its launch Intent. Consume the stream
        // payload in-place after retaining the content URIs so a rotation or
        // process recreation cannot enqueue the same upload batch twice.
        intent.action = Intent.ACTION_MAIN
        intent.removeExtra(Intent.EXTRA_STREAM)
        intent.removeExtra(Intent.EXTRA_TEXT)
        intent.clipData = null
        diagnostics.record(
            "share_received",
            mapOf(
                "count" to payload.uris.size.toString(),
                "text" to (!payload.text.isNullOrEmpty()).toString(),
                "shortcut" to (shortcutHostId != null).toString(),
                "read_grant" to payload.hasReadGrant.toString(),
            ),
        )
    }

    /**
     * Routes the diagnostics report into the share-in sheet, the same door an
     * external app's share comes through: the sheet already knows how to pick a
     * host, a destination and a paste path, and a report is worth nothing until
     * it is off the phone.
     */
    private fun uploadDiagnosticLog() {
        lifecycleScope.launch {
            val uri = withContext(Dispatchers.IO) {
                stageDiagnosticLog(applicationContext, diagnostics)
            } ?: return@launch
            pendingShare.value = SharedUriIngress.append(
                pendingShare.value,
                SharedUriIngress.Payload(uris = listOf(uri), hasReadGrant = true),
            )
            diagnostics.record("diagnostics_upload_staged", emptyMap())
        }
    }

    private fun writeRoutedShare(outState: Bundle, routed: PendingShareUpload?) {
        outState.putString(STATE_ROUTED_HOST, routed?.hostId)
        outState.putStringArrayList(
            STATE_ROUTED_URIS,
            ArrayList(routed?.uris.orEmpty().map(Uri::toString)),
        )
        outState.putString(STATE_ROUTED_TEXT, routed?.text)
        outState.putString(STATE_ROUTED_TEXT_MODE, routed?.textMode?.name)
        outState.putString(
            STATE_ROUTED_CWD,
            (routed?.destination as? ShareUploadDestination.SessionCwd)?.path,
        )
        outState.putBoolean(STATE_ROUTED_PASTE, routed?.pastePath == true)
    }

    private fun readRoutedShare(saved: Bundle): PendingShareUpload? {
        val hostId = saved.getString(STATE_ROUTED_HOST) ?: return null
        val uris = saved.getStringArrayList(STATE_ROUTED_URIS)?.map(Uri::parse).orEmpty()
        val text = saved.getString(STATE_ROUTED_TEXT)
        if (uris.isEmpty() && text.isNullOrEmpty()) return null
        val cwd = saved.getString(STATE_ROUTED_CWD)
        return PendingShareUpload(
            hostId = hostId,
            uris = uris,
            text = text,
            textMode = saved.getString(STATE_ROUTED_TEXT_MODE)?.let { name ->
                ShareTextMode.entries.firstOrNull { it.name == name }
            },
            destination = cwd?.let(ShareUploadDestination::SessionCwd) ?: ShareUploadDestination.Temp,
            pastePath = saved.getBoolean(STATE_ROUTED_PASTE),
        )
    }

    private fun requestUnlock() {
        val keyguard = getSystemService(KeyguardManager::class.java)
        val intent = keyguard.createConfirmDeviceCredentialIntent(
            getString(R.string.app_lock_title),
            getString(R.string.app_lock_body),
        )
        if (intent != null) {
            unlockExcursion(true)
            unlockLauncher.launch(intent)
        }
    }

    private fun setAppLockEnabled(enabled: Boolean) {
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (enabled && !keyguard.isDeviceSecure) {
            appLockError.value = "Set a device PIN, pattern, password, or biometric before enabling app lock."
            return
        }
        appLockError.value = null
        lifecycleScope.launch {
            preferences.updateAppLockEnabled(enabled)
            appLockEnabled = enabled
            locked.value = enabled
            if (enabled) requestUnlock()
        }
    }

    private companion object {
        const val STATE_PENDING_UPLOADS = "pending_uploads"
        const val STATE_PENDING_SHARE_TEXT = "pending_share_text"
        const val STATE_PENDING_SHARE_TARGET = "pending_share_target"
        const val STATE_ROUTED_HOST = "routed_share_host"
        const val STATE_ROUTED_URIS = "routed_share_uris"
        const val STATE_ROUTED_TEXT = "routed_share_text"
        const val STATE_ROUTED_TEXT_MODE = "routed_share_text_mode"
        const val STATE_ROUTED_CWD = "routed_share_cwd"
        const val STATE_ROUTED_PASTE = "routed_share_paste"
    }
}

/**
 * How long the cold-start path waits for a host list that came back empty.
 *
 * Long enough for Room to deliver a write the first emission had not observed,
 * short enough that a device with genuinely no saved hosts is not held up.
 */
private const val HOST_LIST_SETTLE_MILLISECONDS = 1_500L

@Composable
private fun FoundationScreen(
    pendingShare: SharedUriIngress.Payload?,
    pendingShareTargetId: String?,
    onShareRouted: (PendingShareUpload) -> Unit,
    onShareDiscarded: () -> Unit,
    routedShare: PendingShareUpload?,
    onRoutedShareConsumed: () -> Unit,
    preferences: AndroidAppPreferences,
    locked: Boolean,
    appLockError: String?,
    onUnlock: () -> Unit,
    onAppLockChanged: (Boolean) -> Unit,
    /** Each consumer below takes its own slot, so nested excursions count. */
    externalUi: ExternalUiExcursions,
    /**
     * Whether an ON_STOP is the app actually leaving, as opposed to a
     * configuration change or a screen the app itself put up — a file picker,
     * the camera, a permission sheet, the keyguard. `MainActivity.onStop`
     * already refuses to treat those as leaving; restore used to, which closed
     * the window mid-wake and reopened a fresh sixty-second one over sessions
     * that never died.
     */
    isRealBackgroundEdge: () -> Boolean,
    onPairingCoordinatorChanged: (CrossDevicePairingCoordinator?) -> Unit,
    diagnostics: DiagnosticLogStore,
    onUploadDiagnosticLog: () -> Unit,
    agentSessions: LiveAgentSessionRegistry,
    agentIntegration: AgentSessionIntegrationCoordinator,
    agentPresenter: AgentCenterPresenter,
    notificationThreadKey: String?,
    notificationPrearmedAnswer: Boolean,
    onNotificationThreadConsumed: () -> Unit,
) {
    val context = LocalContext.current
    val compositionScope = rememberCoroutineScope()
    // One slot per consumer: Keys' credential prompts, and Settings' pickers,
    // pairing camera and permission sheets (one destination at a time).
    val keysExcursion = remember(externalUi) { externalUi.slot() }
    val settingsExcursion = remember(externalUi) { externalUi.slot() }
    val hostRepository = remember(context) {
        AndroidHostRepository(context.applicationContext)
    }
    val knownHostsRepository = remember(context) {
        AndroidKnownHostsRepository(context.applicationContext)
    }
    val identityRepository = remember(context) {
        AndroidIdentityRepository(context.applicationContext)
    }
    val restoreRepository = remember(context) {
        AndroidSessionRestoreRepository(context.applicationContext)
    }
    val foregroundRestoreStore = remember(context) {
        AndroidForegroundRestoreStore(context.applicationContext)
    }
    val pendingContinuationStore = remember(context) {
        AndroidPendingContinuationRecoveryStore(context.applicationContext)
    }
    val credentialStore = remember { AndroidKeystoreCredentialStore() }
    val bellController = remember(context.applicationContext) {
        AndroidBellController(context.applicationContext)
    }
    DisposableEffect(bellController) { onDispose(bellController::close) }
    val bellUnread by bellController.unread.state.collectAsState()
    val appPreferences by preferences.values.collectAsState(initial = AppPreferences())
    var bellPermissionRefresh by remember { mutableIntStateOf(0) }
    val bellPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { bellPermissionRefresh += 1 }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) bellPermissionRefresh += 1
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    val bellNotificationsAvailable = remember(bellPermissionRefresh) {
        bellController.canPostNotifications()
    }
    /**
     * The live sessions live for the process, not for this Activity.
     *
     * Same move `SessionRestoreCoordinator` made for restore's own state, and
     * for the same reason — except this one is the thing that was being
     * compensated for. An Activity destroy this manifest's `configChanges`
     * cannot absorb — not a rotation, which it can — used to close every
     * transport on screen; restore then noticed and reopened the tabs, which is
     * why the reported bug went away while the sessions were still genuinely
     * dying and reconnecting from scratch.
     */
    val sessionStore = remember { LiveSessionStore.get() }
    val liveSessions = sessionStore.hosts
    val programStatusCenter = remember { ProgramStatusCenter() }
    val collectedProgramStatusSessions by programStatusCenter.sessions.collectAsState()
    val programStatusSessions = if (appPreferences.programStatusEnabled) collectedProgramStatusSessions else emptyMap()
    val programStatusFocusRequests = remember { mutableStateMapOf<String, ProgramStatusFocusRequest>() }
    val agentState by agentPresenter.state.collectAsState()
    val paneAgentProviders by agentPresenter.paneAgentProviders.collectAsState()
    val liveSessionIds = sessionStore.sessionIds
    val liveSessionCreatedAt = sessionStore.createdAt
    /**
     * Still composition-scoped, and correctly so: it is a mirror of what each
     * controller's own `state` flow says, and every screen republishes on mount.
     */
    val liveSessionStates = remember { mutableStateMapOf<String, SshSessionUiState>() }
    /**
     * Transport-level reachability per host, absent where the transport
     * reports none. Only Mosh has one, and it is the only thing that tells a
     * live Mosh session apart from one that merely still calls itself
     * connected — which is what SSP does across a network loss, by design.
     */
    val liveSessionTransportReachable = remember { mutableStateMapOf<String, Boolean>() }
    // Visit order for the top bar's switcher, which lists sessions most
    // recently visited first. Creation order is the wrong key: the session the
    // user keeps returning to is the oldest one.
    val liveSessionLastTouched = sessionStore.lastTouched
    val restoreOnMountHostIds = remember { mutableStateMapOf<String, Boolean>() }
    val hostOpenConnectRequests = remember { mutableStateMapOf<String, Long>() }
    // In the store, not the composition: both are part of what makes a
    // controller that controller, so a recreation that came back without them
    // would retire the transport it was supposed to preserve.
    val pairingTmuxOverrides = sessionStore.tmuxTargets
    val pairingAttemptOverrides = sessionStore.pairingAttempts
    /** cwd each live session last reported; feeds the ingress sheet. */
    val liveSessionCwds = remember { mutableStateMapOf<String, String>() }
    // With the store: an Activity rebuilt around live sessions comes back to
    // the tab the user was looking at rather than to the session list.
    var presentedHostId by sessionStore.presentedHost
    var selectedTab by remember { mutableStateOf(CompactRootTab.Hosts) }
    /**
     * Restore's state lives for the process, not for this Activity.
     *
     * It used to be `remember`ed here, which on iOS is fine — that state sits
     * in a view that is never torn down. Android destroys its UI routinely, and
     * each time it did, the latch arming the next wake went with it and the
     * cold-start path re-ran over sessions that were already there.
     */
    val restoreCoordinator = remember(context) {
        SessionRestoreCoordinator.get(context.applicationContext)
    }
    // Before either latch is read, and in a `remember` rather than an effect so
    // it cannot be ordered after the cold-start pass that depends on it: a
    // composition that follows a real background edge is a relaunch, and a
    // relaunch gets its own pass. A configuration change notes no edge, so it
    // still consumes nothing and still cannot replay.
    val restoreStartupRearmed = remember(restoreCoordinator) {
        restoreCoordinator.consumeStartupRearm()
    }
    val startupRestoreEvaluated by restoreCoordinator.startupEvaluated.collectAsState()
    val startupRestoreResolved by restoreCoordinator.startupResolved.collectAsState()
    val restorePreservedSnapshots by restoreCoordinator.preservedSnapshots.collectAsState()
    var restorePrompt by remember { mutableStateOf<ForegroundRestoreDocument?>(null) }
    val restoreWindow = restoreCoordinator.window
    /** Per-host counter the window bumps to reconnect a tab that survived. */
    val restoreReconnectRequests = remember { mutableStateMapOf<String, Long>() }
    var appActive by remember { mutableStateOf(true) }
    DisposableEffect(programStatusCenter, appActive, locked) {
        programStatusCenter.setApplicationActive(appActive && !locked)
        onDispose { programStatusCenter.setApplicationActive(false) }
    }
    DisposableEffect(programStatusCenter) {
        onDispose {
            programStatusCenter.setApplicationActive(false)
            programStatusCenter.onOpenTerminal = null
        }
    }
    var restoreAlwaysReopen by remember { mutableStateOf(false) }
    var pairingRecoveryHandled by remember { mutableStateOf(false) }
    var pairingRecoveryPrompt by remember { mutableStateOf(false) }
    var pendingPairingContinuationHostId by remember { mutableStateOf<String?>(null) }
    val coreState by produceState<CoreBridgeState?>(initialValue = null) {
        value = withContext(Dispatchers.Default) {
            CoreBridge.inspect()
        }
    }
    val restoreRecords by restoreRepository.observeRecords().collectAsState(initial = emptyList())
    val loadedHosts by produceState<List<SavedHost>?>(initialValue = null, hostRepository) {
        hostRepository.observeHosts().collect { value = it }
    }
    val hosts = loadedHosts.orEmpty()
    val continuityState by produceState<ContinuityLaunchState?>(initialValue = null, foregroundRestoreStore) {
        combine(
            foregroundRestoreStore.restorePolicy,
            foregroundRestoreStore.documents,
            pendingContinuationStore.pending,
        ) { policy, document, pendingContinuation ->
            ContinuityLaunchState(policy, document, pendingContinuation)
        }.collect { value = it }
    }
    val density = LocalDensity.current
    val usesCompactShell = with(density) { LocalWindowInfo.current.containerSize.width.toDp() < 700.dp }
    SideEffect { sessionStore.usesCompactShell.value = usesCompactShell }

    /**
     * [explicitOpen]: the user (or a routed continuation) asked for this
     * terminal by name, which §6.9 counts as a show even when the tab is
     * already on screen. A restore never is.
     */
    fun openHost(
        host: SavedHost,
        sessionId: String = UUID.randomUUID().toString(),
        createdAtEpochMilliseconds: Long = System.currentTimeMillis(),
        reconnectOnMount: Boolean = false,
        connectOnPresent: Boolean = false,
        presents: Boolean = true,
        explicitOpen: Boolean = false,
    ) {
        val existing = liveSessions.indexOfFirst { it.id == host.id }
        if (existing >= 0) {
            liveSessions[existing] = host
        } else {
            liveSessions += host
            liveSessionIds[host.id] = sessionId
            liveSessionCreatedAt[host.id] = createdAtEpochMilliseconds
        }
        if (reconnectOnMount) restoreOnMountHostIds[host.id] = true
        if (connectOnPresent) {
            hostOpenConnectRequests[host.id] = (hostOpenConnectRequests[host.id] ?: 0L) + 1L
        }
        // A wake can restore several sessions in one pass, and each one calling
        // itself the presented host would walk the user through every tab
        // before landing on an arbitrary last one.
        if (presents) presentedHostId = host.id
        if (presents && explicitOpen) sessionStore.requestExplicitOpen(host.id)
    }

    /**
     * Bring a set of stored snapshots back.
     *
     * Two shapes, because a wake has two: a session whose tab is gone needs
     * the tab back, and a session whose tab survived a dead transport needs
     * only a reconnect. `openHost` cannot do the second — `reconnectOnMount`
     * is consumed at first mount and never fires again — so that side goes
     * through the session itself, which also cancels the ladder attempt parked
     * behind presentation before starting its own.
     *
     * Returns how many snapshots were restorable; the rest name hosts this
     * device no longer has.
     */
    fun restoreSnapshots(
        snapshots: List<ForegroundRestoreSnapshot>,
        selectedSessionId: String?,
        presentsRestored: Boolean,
    ): Int {
        val hostsById = hosts.associateBy(SavedHost::id)
        val restorable = snapshots.mapNotNull { snapshot ->
            hostsById[snapshot.hostId]?.let { it to snapshot }
        }
        restorable.forEach { (host, snapshot) ->
            if (liveSessions.any { it.id == host.id }) {
                // Deliberately not re-applying the stored tmux target here.
                // The session controller is remembered on it, so writing a
                // different value tears the live session down and builds a new
                // one — and this tab has been up the whole time, so whatever it
                // is attached to is more current than the snapshot anyway.
                restoreReconnectRequests[host.id] = (restoreReconnectRequests[host.id] ?: 0L) + 1L
            } else {
                if (snapshot.tmuxTarget != null) pairingTmuxOverrides[host.id] = snapshot.tmuxTarget
                openHost(
                    host = host,
                    sessionId = snapshot.sessionId,
                    createdAtEpochMilliseconds = snapshot.createdAtEpochMilliseconds,
                    reconnectOnMount = true,
                    presents = false,
                )
            }
        }
        if (presentsRestored) {
            val selectedHostId = restorable.firstOrNull { (_, snapshot) ->
                snapshot.sessionId == selectedSessionId
            }?.first?.id ?: restorable.firstOrNull()?.first?.id
            presentedHostId = selectedHostId
            if (selectedHostId == null) selectedTab = CompactRootTab.Sessions
        } else {
            // Mid-wake the user may be looking at a session already. Only claim
            // the screen when nothing holds it, and then only for the session
            // they left off on.
            if (presentedHostId == null) {
                restorable.firstOrNull { (_, snapshot) -> snapshot.sessionId == selectedSessionId }
                    ?.let { (host, _) -> presentedHostId = host.id }
            }
        }
        return restorable.size
    }

    fun reopen(document: ForegroundRestoreDocument) {
        restoreSnapshots(
            snapshots = document.snapshots,
            selectedSessionId = document.selectedSessionId,
            presentsRestored = true,
        )
    }
    val pairingCoordinator = remember(context, hostRepository, identityRepository, knownHostsRepository) {
        CrossDevicePairingCoordinator(
            context = context.applicationContext,
            hosts = hostRepository,
            identities = identityRepository,
            knownHosts = knownHostsRepository,
            credentialStore = credentialStore,
            scope = compositionScope,
            onConnectionRequired = { hostId, transport, tmuxTarget, attemptId ->
                compositionScope.launch {
                    // Resolve at the moment of handoff: remember must not capture the
                    // initial (usually empty) host list.
                    hostRepository.host(hostId)?.let { host ->
                        pairingTmuxOverrides[host.id] = tmuxTarget
                        pairingAttemptOverrides[host.id] = attemptId
                        // The authenticated QR acceptance is the explicit
                        // continuation: an explicit open, decided by the
                        // shared show rule instead of a bespoke claim.
                        openHost(host, explicitOpen = true)
                    }
                }
            },
            recordDiagnostic = diagnostics::record,
        )
    }
    DisposableEffect(pairingCoordinator) {
        onPairingCoordinatorChanged(pairingCoordinator)
        onDispose {
            onPairingCoordinatorChanged(null)
            pairingCoordinator.close()
        }
    }
    LaunchedEffect(appPreferences.appLockEnabled) {
        pairingCoordinator.securityPolicyChanged()
    }
    LaunchedEffect(locked) { if (locked) pairingCoordinator.applicationDidLock() }
    LaunchedEffect(hosts) {
        agentPresenter.updateHostDisplayLabels(hosts.associate { it.id to it.displayName })
        liveSessions.indices.forEach { index ->
            hosts.firstOrNull { it.id == liveSessions[index].id }?.let { liveSessions[index] = it }
        }
    }
    LaunchedEffect(liveSessionStates.values.toList(), liveSessions.size) {
        // An empty mirror over a non-empty tab list means "not published yet",
        // not "none connected": a relaunch onto a warm process composes before
        // any session screen has remounted and republished. Reporting zero here
        // would stop the keep-alive service out from under transports that are
        // still up — the very thing keeping them alive is the reason there are
        // tabs to come back to.
        if (liveSessionStates.isEmpty() && liveSessions.isNotEmpty()) return@LaunchedEffect
        val activeCount = liveSessionStates.values.count {
            it == SshSessionUiState.Connecting ||
                it == SshSessionUiState.Connected ||
                it is SshSessionUiState.AwaitingCredential ||
                it is SshSessionUiState.AwaitingHostKey ||
                it is SshSessionUiState.AwaitingOwnerAuthorization
        }
        SystemPickerSessionService.setSessionsActive(context.applicationContext, activeCount)
    }
    // The one honest answer to "is this host connected?". A saved restore
    // record only says a session *could* be resumed, so it never counts here:
    // the host list used to tint on those records and claimed a live link to
    // hosts the app had not talked to since the previous launch.
    val connectedHostIds = liveSessionStates
        .filterValues { it == SshSessionUiState.Connected }
        .keys
        .toSet()
    // Direct-share targets: one shortcut per host, so the Android share sheet
    // can route a payload the way iOS's share extension does with its own host
    // picker. Republished whenever the set or its connected subset changes.
    LaunchedEffect(hosts, liveSessionStates.toMap(), appPreferences.appLockEnabled) {
        ShareTargetPublisher.publish(
            context = context,
            hosts = hosts,
            connectedHostIds = connectedHostIds,
            appLockEnabled = appPreferences.appLockEnabled,
        )
    }
    LaunchedEffect(continuityState, loadedHosts, locked) {
        // The one exit that still said nothing. A relaunch onto a warm process
        // found the pass already claimed and returned above every diagnostic in
        // this effect, so a whole field report came back with zero
        // startup_restore lines in it and no way to tell "restore decided not
        // to" from "restore never ran".
        if (startupRestoreEvaluated) {
            diagnostics.record(
                "startup_restore_skip",
                mapOf(
                    "reason" to "already-evaluated-on-entry",
                    "detail" to "rearmed=$restoreStartupRearmed",
                ),
            )
            return@LaunchedEffect
        }
        // Every way out of here says so.
        //
        // A launch that restores nothing used to be indistinguishable from one
        // that was never asked to: the guards returned in silence and the only
        // evidence was the absence of a line. A field report of "restore did
        // not work" then had no way to name which guard held. iOS has said this
        // since its first restore commit; Android did not.
        if (continuityState == null || locked) {
            diagnostics.record(
                "startup_restore_skip",
                mapOf("reason" to if (locked) "locked" else "no-continuity-state"),
            )
            return@LaunchedEffect
        }
        // Claimed for the process, not for this composition. An Activity
        // recreation used to get a fresh latch and replay the whole cold-start
        // path over sessions that were already there: two plans within four
        // hundred milliseconds, four reconnects, and one host holding two
        // transports while the first instance's controllers were closed
        // mid-connect.
        val launch = checkNotNull(continuityState)
        val effectivePolicy = SessionRestorePresentationPolicy.effective(
            stored = launch.policy,
            usesCompactShell = usesCompactShell,
        )
        val document = launch.document
        // What a cold start should do is the shared core's call — the same
        // rules, in the same order, as iOS. What stays here is the facts it
        // needs and the records it answers about.
        //
        // A tab that is already open is not a session to restore, but it says
        // nothing about the others. Bailing out whenever the tab list was
        // non-empty meant any launch that opened a host first — a share target,
        // a direct-share shortcut, an agent notification — silently took
        // restore with it, with nothing logged to say so.
        fun startupAction(): ForegroundRestoreStartupAction =
            ForegroundRestoreStartup.action(
                document = document,
                hostsLoaded = loadedHosts != null,
                availableHostIds = hosts.map(SavedHost::id).toSet(),
                liveHostIds = liveSessions.map(SavedHost::id).toSet(),
                policy = effectivePolicy,
            )

        var action = startupAction()
        // An empty host list is not proof the hosts are gone, and the core says
        // so rather than deciding: `loadedHosts` stops being null at Room's
        // first emission, and that emission can predate a write the query has
        // not observed yet. Acting on it reads every snapshot as naming a host
        // this device no longer has, spends the one cold-start pass, and clears
        // the document.
        //
        // Waiting is safe and self-limiting: this effect is keyed on
        // `loadedHosts`, so a real emission cancels and restarts it with the
        // new list. Reaching the far side of the delay means the list stayed
        // empty, which is a device that genuinely has no hosts — and the second
        // ask then says `nothing-restorable` on its own.
        if (action is ForegroundRestoreStartupAction.Wait &&
            action.reason == ForegroundRestoreStartupReason.HOST_LIST_EMPTY
        ) {
            diagnostics.record("startup_restore_skip", mapOf("reason" to "hosts-empty-settling"))
            delay(HOST_LIST_SETTLE_MILLISECONDS)
            action = startupAction()
        }

        // Claimed where it acts, not on entry: the waits above can restart this
        // effect, and a pass spent before it could act is a pass nothing gets
        // to use. Claimed for the process, not for this composition — an
        // Activity recreation used to get a fresh latch and replay the whole
        // cold-start path over sessions that were already there: two plans
        // within four hundred milliseconds, four reconnects, and one host
        // holding two transports while the first instance's controllers were
        // closed mid-connect.
        when (val decided = action) {
            is ForegroundRestoreStartupAction.Wait -> {
                // Nothing is claimed and nothing is cleared: the question could
                // not be answered yet, and deleting a document over that is how
                // a launch loses the sessions it was about to reopen.
                diagnostics.record(
                    "startup_restore_skip",
                    mapOf("reason" to "wait-${decided.reason.wireValue}"),
                )
            }
            is ForegroundRestoreStartupAction.Skip -> {
                if (!restoreCoordinator.claimStartupPass()) return@LaunchedEffect
                diagnostics.record(
                    "startup_restore_skip",
                    mapOf(
                        "reason" to decided.reason.wireValue,
                        "detail" to "stored=${document?.snapshots?.size ?: 0} hosts=${hosts.size} " +
                            "live=${liveSessions.size}",
                    ),
                )
                // Restore turned off is the user asking for the stores to be
                // empty, which is not the same thing as this launch having
                // nothing to do — so it deletes unconditionally, and the two
                // are kept apart here rather than collapsed into one clear.
                val policyIsNever = decided.reason == ForegroundRestoreStartupReason.POLICY_NEVER
                val keptSessionIds =
                    if (policyIsNever) emptySet() else liveSessionIds.values.toSet()
                restoreRecords.filterNot { it.sessionId in keptSessionIds }.forEach {
                    restoreRepository.delete(it.sessionId)
                }
                val liveHostIds = liveSessions.map(SavedHost::id).toSet()
                // A snapshot naming a host that is already on screen was
                // excluded, not judged unrestorable — clearing over it would
                // throw away the one entry that is certainly still wanted.
                if (policyIsNever ||
                    document == null ||
                    document.snapshots.none { it.hostId in liveHostIds }
                ) {
                    foregroundRestoreStore.clear()
                }
                restoreCoordinator.markStartupResolved()
            }
            is ForegroundRestoreStartupAction.Restore,
            is ForegroundRestoreStartupAction.Offer,
            -> {
                val storedDocument = document ?: return@LaunchedEffect
                val restorePlan = when (decided) {
                    is ForegroundRestoreStartupAction.Restore -> decided.plan
                    is ForegroundRestoreStartupAction.Offer -> decided.plan
                }
                if (!restoreCoordinator.claimStartupPass()) {
                    diagnostics.record("startup_restore_skip", mapOf("reason" to "already-evaluated"))
                    return@LaunchedEffect
                }
                val cohortSessionIds = storedDocument.snapshots
                    .map(ForegroundRestoreSnapshot::sessionId).toSet()
                restoreRecords.filterNot {
                    it.sessionId in cohortSessionIds || it.sessionId in liveSessionIds.values
                }.forEach {
                    restoreRepository.delete(it.sessionId)
                }
                val plan = ForegroundRestoreDocument(
                    savedAtEpochMilliseconds = storedDocument.savedAtEpochMilliseconds,
                    snapshots = restorePlan.snapshots,
                    selectedSessionId = restorePlan.selectedSessionId,
                )
                diagnostics.record(
                    "startup_restore_plan",
                    mapOf(
                        "count" to plan.snapshots.size.toString(),
                        "policy" to effectivePolicy.name.lowercase(),
                        "skipped" to restorePlan.skippedCount.toString(),
                    ),
                )
                if (decided is ForegroundRestoreStartupAction.Restore) {
                    reopen(plan)
                    restoreCoordinator.markStartupResolved()
                } else {
                    restorePrompt = plan
                }
            }
        }
    }
    fun currentRestoreSnapshots(): List<ForegroundRestoreSnapshot> {
        val recordsBySession = restoreRecords.associateBy { it.sessionId }
        val recordsByHost = restoreRecords.associateBy { it.hostId }
        return liveSessions.take(ForegroundRestoreDocument.MAX_SNAPSHOTS).map { host ->
            val sessionId = liveSessionIds[host.id] ?: UUID.randomUUID().toString().also {
                liveSessionIds[host.id] = it
            }
            val record = recordsBySession[sessionId] ?: recordsByHost[host.id]
            ForegroundRestoreSnapshot(
                sessionId = sessionId,
                hostId = host.id,
                displayName = host.displayName.ifBlank { host.id },
                createdAtEpochMilliseconds = liveSessionCreatedAt[host.id]
                    ?: record?.updatedAtEpochMilliseconds
                    ?: System.currentTimeMillis(),
                transportKind = normalizedRestoreTransportKind(record?.transportKind, host.transportKind),
                // The snapshot rejects a blank optional with a bare `require`,
                // which kills the process. Host rows are normalized on save,
                // but a pairing override arrives from another device, so it is
                // the one value here that has never been through validation.
                tmuxTarget = (pairingTmuxOverrides[host.id] ?: record?.tmuxTarget ?: host.tmuxTarget)
                    ?.takeIf { it.isNotBlank() },
                lastSelection = record?.lastSelection?.takeIf { it.isNotBlank() },
                reconnectRequired = liveSessionStates[host.id] != SshSessionUiState.Connected,
            )
        }
    }

    /**
     * Write the restore document.
     *
     * What this may do to what is already stored is the shared core's call,
     * not this function's, and it is the whole ballgame: a write that mirrors
     * the live tab list deletes everything it cannot see, and the sessions
     * worth restoring are exactly the ones that are no longer there. Android
     * only ever wrote live-only, and cleared the store outright whenever the
     * tab list was empty. On iOS that same shape deleted a dead session's
     * snapshot twice — once when the first of two transports to die closed the
     * window on the other, and once when a death reported behind the app lock
     * rewrote the document the post-unlock wake was going to seed from.
     */
    /**
     * The facts a write needs, captured now.
     *
     * The background-edge write runs on a scope that outlives this Activity, so
     * it must not read composition state once it is running: by then the
     * composition may be gone. Everything it needs is snapshotted here, on the
     * caller's thread, before the write is launched.
     */
    fun restorePersistPayload(isActive: Boolean) = RestorePersistPayload(
        isActive = isActive,
        policy = continuityState?.policy,
        live = currentRestoreSnapshots(),
        presentedSessionId = presentedHostId?.let(liveSessionIds::get),
    )

    fun recordRestorePersist(payload: RestorePersistPayload, report: RestorePersistReport) {
        diagnostics.record(
            "restore_persist",
            mapOf(
                "detail" to "active=${payload.isActive} " +
                    "mode=${report.mode.name.lowercase(Locale.ROOT)} " +
                    "live=${payload.live.size} stored=${report.storedCount} " +
                    "written=${report.writtenCount} cohort=${report.cohortCount}",
            ),
        )
    }

    suspend fun persistRestoreSnapshots(isActive: Boolean) {
        val payload = restorePersistPayload(isActive)
        recordRestorePersist(payload, restoreCoordinator.persist(payload))
    }

    LaunchedEffect(
        startupRestoreResolved,
        appActive,
        liveSessions.toList(),
        liveSessionStates.toMap(),
        liveSessionIds.toMap(),
        liveSessionCreatedAt.toMap(),
        pairingTmuxOverrides.toMap(),
        restoreRecords,
        presentedHostId,
        continuityState?.policy,
    ) {
        if (!startupRestoreResolved) return@LaunchedEffect
        // The background edge writes from the lifecycle callback instead: by
        // the time a recomposition could deliver appActive=false the process
        // may already be frozen, and that write is the one the next wake reads.
        if (!appActive) return@LaunchedEffect
        persistRestoreSnapshots(isActive = true)
    }

    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> appActive = true
                Lifecycle.Event.ON_STOP -> {
                    appActive = false
                    programStatusCenter.setApplicationActive(false)
                    // A configuration change or an app-launched screen is not
                    // the app leaving. Treating it as one closed the window
                    // mid-wake and opened a fresh one on return over sessions
                    // that never died — and the window is process-scoped now,
                    // so there is nothing to rebuild it from afterwards.
                    if (!isRealBackgroundEdge()) return@LifecycleEventObserver
                    // The window belongs to one wake. Carrying it across the
                    // background edge would leave the next foreground running
                    // the previous visit's clock: the alive floor reads as long
                    // spent, every entry retires on the first pass, and the
                    // detection window is zero. The latch survives — the write
                    // below is what re-arms it.
                    restoreWindow.closeForBackgroundEdge()
                    // Captured here, written there. The payload is snapshotted
                    // on this thread because the write outlives the composition
                    // it came from; the write runs on the coordinator's scope
                    // because the Activity's is cancelled at ON_DESTROY, about
                    // thirty milliseconds from now, with the write still inside
                    // two suspending DataStore round trips. Losing it loses the
                    // latch, and with it the whole wake path.
                    if (startupRestoreResolved) {
                        val payload = restorePersistPayload(isActive = false)
                        restoreCoordinator.scope.launch {
                            recordRestorePersist(payload, restoreCoordinator.persist(payload))
                        }
                    }
                    // The payload this edge writes is what the next foreground
                    // restores from, and that foreground needs a cold-start
                    // pass of its own. Only noted here — the re-arm itself
                    // happens as the next composition starts, because ON_STOP
                    // does not yet know whether this Activity is coming back.
                    restoreCoordinator.noteRealBackgroundEdge()
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        appActive = lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    /**
     * The facts a verdict needs, lifted out of the live sessions so the
     * decision itself stays the shared core's.
     */
    fun foregroundRestoreLiveSessions(): List<ForegroundRestoreLiveSession> =
        liveSessions.mapNotNull { host ->
            val sessionId = liveSessionIds[host.id] ?: return@mapNotNull null
            ForegroundRestoreLiveSession(
                sessionId = sessionId,
                hostId = host.id,
                state = when (liveSessionStates[host.id]) {
                    SshSessionUiState.Connected -> ForegroundRestoreConnectionState.CONNECTED
                    // An awaiting-a-decision session is a connect in progress,
                    // not a verdict: it holds its cohort place until the user
                    // answers the credential or host-key prompt.
                    SshSessionUiState.Connecting,
                    is SshSessionUiState.AwaitingCredential,
                    is SshSessionUiState.AwaitingHostKey,
                    is SshSessionUiState.AwaitingOwnerAuthorization,
                    -> ForegroundRestoreConnectionState.CONNECTING
                    is SshSessionUiState.Failed -> ForegroundRestoreConnectionState.FAILED
                    SshSessionUiState.Disconnected,
                    SshSessionUiState.Terminated,
                    -> ForegroundRestoreConnectionState.DISCONNECTED
                    null -> ForegroundRestoreConnectionState.IDLE
                },
                transportConfirmed = liveSessionTransportReachable[host.id],
            )
        }

    /**
     * The wake.
     *
     * Restart it on the app-lock edge as well as the foreground one: the
     * window is deliberately seeded *after* the lock guard, so an unlock is
     * what lets it open at all. Reseeding is safe because the window's own
     * state survives this effect — only the loop driving it restarts.
     */
    LaunchedEffect(
        appActive,
        locked,
        startupRestoreResolved,
        // The latch is armed at the tail of the departing write, which now
        // outlives this composition. Keying on it is what makes a wake that
        // recomposed before the write landed try again instead of silently
        // getting no window at all.
        restorePreservedSnapshots,
        continuityState?.policy,
        usesCompactShell,
    ) {
        if (!appActive || !startupRestoreResolved) return@LaunchedEffect
        if (!restorePreservedSnapshots) return@LaunchedEffect
        val policy = SessionRestorePresentationPolicy.effective(
            stored = continuityState?.policy ?: SessionRestorePolicy.ASK,
            usesCompactShell = usesCompactShell,
        )
        if (policy == SessionRestorePolicy.NEVER) {
            restoreCoordinator.closeWindow()
            restoreCoordinator.withDocument { foregroundRestoreStore.clear() }
            return@LaunchedEffect
        }
        // Behind the lock the scene is still alive and persists still land, but
        // nothing here may run: seeding now would spend the alive floor and the
        // backstop on time the user was busy authenticating. The persist path
        // covers the wait — latched and unopened is what a locked wake looks
        // like, and the core answers that with a merging write.
        if (locked) return@LaunchedEffect
        val document = restoreCoordinator.withDocument { foregroundRestoreStore.load() }
        if (document == null) {
            restoreCoordinator.closeWindow()
            return@LaunchedEffect
        }

        if (restoreWindow.openIfNeeded(System.currentTimeMillis(), document.snapshots)) {
            diagnostics.record(
                "restore_window_open",
                mapOf("detail" to "cohort=${document.snapshots.size} policy=${policy.name.lowercase(Locale.ROOT)}"),
            )
        }

        /**
         * Raise, or widen, the restore sheet.
         *
         * A session that dies after the sheet is up is absent from what it
         * offers, so answering would restore the rest, settle the window and
         * take that snapshot with it. The sheet absorbs a strictly larger set
         * under its existing identity instead, so it updates in place rather
         * than being torn down and re-raised while the user is reading it.
         */
        fun offerRestore(dead: List<ForegroundRestoreSnapshot>, selectedSessionId: String?) {
            val offered = restorePrompt
            val snapshots = if (offered == null) {
                dead
            } else {
                val known = offered.snapshots.map(ForegroundRestoreSnapshot::sessionId).toSet()
                offered.snapshots + dead.filterNot { it.sessionId in known }
            }
            if (offered != null && snapshots.size == offered.snapshots.size) return
            restorePrompt = ForegroundRestoreDocument(
                savedAtEpochMilliseconds = document.savedAtEpochMilliseconds,
                snapshots = snapshots.take(ForegroundRestoreDocument.MAX_SNAPSHOTS),
                selectedSessionId = selectedSessionId?.takeIf { selected ->
                    snapshots.any { it.sessionId == selected }
                },
            )
        }

        while (isActive) {
            // The background edge closes the window from its lifecycle
            // callback, and a tick already suspended in `delay` can resume
            // after that. Leaving it to run would have it report `settled` on
            // an empty window, drop the latch the departing write just armed,
            // and land a foreground write over the background edge's.
            if (!appActive || !restoreWindow.isOpen) return@LaunchedEffect
            // Every snapshot resolves through the host list, so acting before
            // it has loaded would read every entry as naming a host this device
            // no longer has, retire the lot, and drop their snapshots on the
            // write that follows.
            if (loadedHosts == null) {
                delay(ForegroundRestoreWindow.TICK_MILLISECONDS)
                continue
            }
            val prompting = restorePrompt != null || liveSessionStates.values.any {
                it is SshSessionUiState.AwaitingCredential ||
                    it is SshSessionUiState.AwaitingHostKey ||
                    it is SshSessionUiState.AwaitingOwnerAuthorization
            }
            restoreWindow.charge(System.currentTimeMillis(), isPrompting = prompting)

            val failed = runCatching {
                if (liveSessions.isEmpty() && restoreWindow.cohort.size == document.snapshots.size) {
                    // Nothing survived the wake. Restore the document whole so
                    // the stored selection is honoured rather than rebuilt from
                    // whichever entry happened to be reported dead first.
                    when (policy) {
                        SessionRestorePolicy.ALWAYS -> {
                            restoreWindow.retireAll()
                            reopen(document)
                        }
                        // Under ASK the entries keep their cohort places, and
                        // therefore their snapshots, until the user answers.
                        SessionRestorePolicy.ASK ->
                            offerRestore(document.snapshots, document.selectedSessionId)
                        SessionRestorePolicy.NEVER -> Unit
                    }
                } else {
                    val evaluation = restoreWindow.evaluate(
                        live = foregroundRestoreLiveSessions(),
                        retiresDeadImmediately = policy == SessionRestorePolicy.ALWAYS,
                    )
                    if (evaluation.dead.isNotEmpty()) {
                        diagnostics.record(
                            "restore_window_dead",
                            mapOf(
                                "detail" to "dead=${evaluation.dead.size} " +
                                    "remaining=${restoreWindow.cohort.size} " +
                                    "policy=${policy.name.lowercase(Locale.ROOT)}",
                            ),
                        )
                        when (policy) {
                            SessionRestorePolicy.ALWAYS -> restoreSnapshots(
                                snapshots = evaluation.dead,
                                selectedSessionId = document.selectedSessionId,
                                presentsRestored = false,
                            )
                            SessionRestorePolicy.ASK ->
                                offerRestore(evaluation.dead, document.selectedSessionId)
                            SessionRestorePolicy.NEVER -> Unit
                        }
                    }
                }
                false
            }.getOrElse { failure ->
                // Fail open: no restore beats a crash on a code path that runs
                // at every wake. The bridge rejects an identifier it cannot
                // read as a UUID, and a host imported from another device is
                // the one id here that this app never minted.
                diagnostics.record(
                    "restore_window_error",
                    mapOf("detail" to (failure.message ?: failure::class.java.simpleName)),
                )
                true
            }

            val closure = if (failed) {
                ForegroundRestoreWindowClosure.BACKSTOP
            } else {
                restoreWindow.closure(hasUnansweredPrompt = restorePrompt != null)
            }
            when (closure) {
                ForegroundRestoreWindowClosure.OPEN -> delay(ForegroundRestoreWindow.TICK_MILLISECONDS)
                else -> {
                    diagnostics.record(
                        "restore_window_close",
                        mapOf(
                            "detail" to "closure=${closure.name.lowercase(Locale.ROOT)} " +
                                "unresolved=${restoreWindow.cohort.size} " +
                                "elapsedMs=${restoreWindow.elapsedMilliseconds}",
                        ),
                    )
                    restoreCoordinator.closeWindow()
                    persistRestoreSnapshots(isActive = true)
                    return@LaunchedEffect
                }
            }
        }
    }
    LaunchedEffect(
        startupRestoreEvaluated,
        startupRestoreResolved,
        restorePrompt,
        continuityState?.pendingContinuation?.attemptId,
        continuityState?.policy,
        locked,
    ) {
        if (pairingRecoveryHandled || !startupRestoreEvaluated || locked) return@LaunchedEffect
        val launch = continuityState ?: return@LaunchedEffect
        if (launch.pendingContinuation == null) {
            pairingRecoveryHandled = true
            return@LaunchedEffect
        }
        if (!launch.pendingContinuation.isFreshAt(System.currentTimeMillis())) {
            pairingRecoveryHandled = true
            pendingContinuationStore.clearIfAttempt(launch.pendingContinuation.attemptId)
            return@LaunchedEffect
        }
        when (SessionRestorePresentationPolicy.effective(launch.policy, usesCompactShell)) {
            SessionRestorePolicy.ALWAYS -> {
                pairingRecoveryHandled = true
                pairingCoordinator.recoverPendingContinuationOnStartup()
            }
            SessionRestorePolicy.NEVER -> {
                pairingRecoveryHandled = true
                pendingContinuationStore.clear()
            }
            SessionRestorePolicy.ASK -> if (restorePrompt == null && startupRestoreResolved) {
                pairingRecoveryPrompt = true
            }
        }
    }
    LaunchedEffect(appPreferences.agentCenterEnabled) {
        agentPresenter.setEnabled(appPreferences.agentCenterEnabled)
        agentIntegration.setEnabled(appPreferences.agentCenterEnabled)
        if (!appPreferences.agentCenterEnabled && selectedTab == CompactRootTab.Agents) {
            selectedTab = CompactRootTab.Hosts
        }
    }
    LaunchedEffect(notificationThreadKey, notificationPrearmedAnswer) {
        notificationThreadKey ?: return@LaunchedEffect
        if (!appPreferences.agentCenterEnabled) {
            onNotificationThreadConsumed()
            return@LaunchedEffect
        }
        selectedTab = CompactRootTab.Agents
        agentPresenter.activate()
        agentPresenter.select(notificationThreadKey)
        if (notificationPrearmedAnswer) agentPresenter.prearmPromptReview(notificationThreadKey)
        onNotificationThreadConsumed()
    }

    LaunchedEffect(presentedHostId) {
        presentedHostId?.let { liveSessionLastTouched[it] = System.currentTimeMillis() }
    }
    val programStatusAgents = if (appPreferences.agentCenterEnabled) {
        programStatusAgentInput(agentState, liveSessions.mapNotNull { host ->
            liveSessionIds[host.id]?.let { host.id to it }
        }.toMap())
    } else ProgramStatusAgentInput.NONE
    val programAttentionCounts = ProgramStatusQueries.counts(programStatusSessions, programStatusAgents)
    SideEffect {
        programStatusCenter.onOpenTerminal = { hostId, windowId, paneId ->
            if (liveSessions.any { it.id == hostId } && liveSessionIds[hostId] != null) {
                presentedHostId = hostId
                programStatusFocusRequests[hostId] = ProgramStatusFocusRequest(windowId, paneId, System.nanoTime())
            }
        }
    }
    val switcherSessions = liveSessions.map { sessionHost ->
        SessionSwitcherSession(
            hostId = sessionHost.id,
            title = sessionHost.displayName,
            endpoint = "${sessionHost.username}@${sessionHost.hostname}:${sessionHost.port}",
            status = when (liveSessionStates[sessionHost.id]) {
                SshSessionUiState.Connected -> SessionSwitcherStatus.CONNECTED
                SshSessionUiState.Connecting,
                is SshSessionUiState.AwaitingCredential,
                is SshSessionUiState.AwaitingHostKey,
                is SshSessionUiState.AwaitingOwnerAuthorization -> SessionSwitcherStatus.PENDING
                is SshSessionUiState.Failed -> SessionSwitcherStatus.FAILED
                else -> SessionSwitcherStatus.IDLE
            },
            isCurrent = sessionHost.id == presentedHostId,
            unread = appPreferences.bellVisualEnabled && sessionHost.id in bellUnread.sessionIds,
            lastTouchedEpochMilliseconds = liveSessionLastTouched[sessionHost.id],
            programAttention = ProgramStatusQueries.sessionCounts(programStatusSessions, sessionHost.id, programStatusAgents)
                .takeIf { it.total > 0 },
        )
    }
    Box(Modifier.fillMaxSize()) {
        when (val state = coreState) {
            is CoreBridgeState.Ready -> {
                liveSessions.forEach { sessionHost ->
                    key(sessionHost.id) {
                        val presented = presentedHostId == sessionHost.id
                        val visible = presented && !locked
                        SshSessionScreen(
                            host = sessionHost,
                            hosts = hostRepository,
                            identities = identityRepository,
                            knownHosts = knownHostsRepository,
                            restore = restoreRepository,
                            credentialStore = credentialStore,
                            bellController = bellController,
                            bellPreferences = appPreferences.toBellPreferences(),
                            liveSessionId = liveSessionIds[sessionHost.id] ?: sessionHost.id,
                            agentSessions = agentSessions,
                            paneAgentProviders = if (appPreferences.agentCenterEnabled) paneAgentProviders else emptyMap(),
                            programStatusCenter = programStatusCenter,
                            programStatusEnabled = appPreferences.programStatusEnabled,
                            programStatusAgents = programStatusAgents,
                            programStatusFocusRequest = programStatusFocusRequests[sessionHost.id],
                            onOpenAgentCenter = if (appPreferences.agentCenterEnabled) {
                                {
                                    presentedHostId = null
                                    selectedTab = CompactRootTab.Agents
                                }
                            } else null,
                            sessions = sessionStore,
                            agentIntegration = agentIntegration,
                            onAgentTerminalVisible = agentPresenter::terminalVisible,
                            terminalTextSizeSp = appPreferences.terminalTextSizeSp,
                            terminalFontId = appPreferences.terminalFontId,
                            scrollbackLines = appPreferences.scrollbackLines,
                            resizeTerminalWithKeyboard = appPreferences.resizeTerminalWithKeyboard,
                            terminalThemeId = appPreferences.terminalThemeId,
                            terminalCursorStyle = appPreferences.terminalCursorStyle,
                            terminalCursorBlink = appPreferences.terminalCursorBlink,
                            accessoryBarKeys = appPreferences.accessoryBarKeys,
                            modifierBehavior = appPreferences.modifierBehavior,
                            modifierNotation = appPreferences.modifierNotation,
                            terminalBackgroundUsesImage = appPreferences.terminalBackgroundUsesImage,
                            terminalBackgroundImageId = appPreferences.terminalBackgroundImageId,
                            terminalBackgroundDim = appPreferences.terminalBackgroundDim,
                            terminalBackgroundBlur = appPreferences.terminalBackgroundBlur,
                            terminalBackgroundFillMode = appPreferences.terminalBackgroundFillMode,
                            smoothScrollingEnabled = appPreferences.smoothScrollingEnabled,
                            smoothScrollingSpeed = appPreferences.smoothScrollingSpeed,
                            onTerminalTextSizeChanged = { size ->
                                compositionScope.launch { preferences.updateTerminalTextSize(size) }
                            },
                            isPresented = visible,
                            initialTmuxSelection = restoreRecords.firstOrNull { it.hostId == sessionHost.id }?.lastSelection,
                            shareUpload = routedShare?.takeIf { it.hostId == sessionHost.id },
                            onShareUploadConsumed = onRoutedShareConsumed,
                            onTerminalDirectoryChanged = { directory ->
                                if (directory == null) liveSessionCwds.remove(sessionHost.id)
                                else liveSessionCwds[sessionHost.id] = directory
                            },
                            onSystemPickerActiveChanged = { active ->
                                SystemPickerSessionService.setActive(context.applicationContext, active)
                            },
                            externalUi = externalUi,
                            onOpenKeys = {
                                presentedHostId = null
                                selectedTab = CompactRootTab.Keys
                            },
                            onEditHost = {
                                presentedHostId = null
                                selectedTab = CompactRootTab.Hosts
                            },
                            onContinueOnAnotherDevice = {
                                pendingPairingContinuationHostId = sessionHost.id
                                presentedHostId = null
                                selectedTab = CompactRootTab.Settings
                            },
                            switcherSessions = switcherSessions,
                            onSelectSession = { hostId -> presentedHostId = hostId },
                            onStateChanged = { nextState ->
                                val pairingAttempt = pairingAttemptOverrides[sessionHost.id]
                                if (pairingAttempt != null &&
                                    (nextState is SshSessionUiState.Failed || nextState == SshSessionUiState.Terminated)
                                ) {
                                    compositionScope.launch {
                                        pendingContinuationStore.clearIfAttempt(pairingAttempt)
                                    }
                                }
                                if (nextState == SshSessionUiState.Terminated) {
                                    if (presentedHostId == sessionHost.id) presentedHostId = null
                                    // Terminated is a decision, not a death: the
                                    // user closed the session or the remote shell
                                    // exited cleanly. A transport that merely went
                                    // down reports Disconnected, and covering the
                                    // gap between those two is what the restore
                                    // window is for — so retire this entry, or the
                                    // wake reopens what was deliberately ended.
                                    liveSessionIds[sessionHost.id]?.let {
                                        restoreWindow.retire(listOf(it))
                                    }
                                    // Ends the transport and drops the tab in
                                    // one place. A tab removed without closing
                                    // its controller would leave a process-held
                                    // transport nothing on screen can reach.
                                    sessionStore.close(sessionHost.id)
                                    programStatusCenter.remove(sessionHost.id)
                                    programStatusFocusRequests.remove(sessionHost.id)
                                    liveSessionStates.remove(sessionHost.id)
                                    liveSessionTransportReachable.remove(sessionHost.id)
                                    restoreOnMountHostIds.remove(sessionHost.id)
                                    hostOpenConnectRequests.remove(sessionHost.id)
                                    restoreReconnectRequests.remove(sessionHost.id)
                                    compositionScope.launch {
                                        restoreRepository.deleteForHost(sessionHost.id)
                                        foregroundRestoreStore.removeForHost(sessionHost.id)
                                    }
                                } else {
                                    liveSessionStates[sessionHost.id] = nextState
                                }
                            },
                            onTransportReachableChanged = { reachable ->
                                if (reachable == null) liveSessionTransportReachable.remove(sessionHost.id)
                                else liveSessionTransportReachable[sessionHost.id] = reachable
                            },
                            pairingTmuxTarget = pairingTmuxOverrides[sessionHost.id],
                            pairingAttemptId = pairingAttemptOverrides[sessionHost.id],
                            reconnectOnMount = restoreOnMountHostIds[sessionHost.id] == true,
                            connectOnOpenRequest = hostOpenConnectRequests[sessionHost.id] ?: 0L,
                            restoreReconnectRequest = restoreReconnectRequests[sessionHost.id] ?: 0L,
                            onTerminalRenderedReady = pairingCoordinator::connectionRenderedReady,
                            onBack = { presentedHostId = null },
                            modifier = Modifier.fillMaxSize().alpha(if (visible) 1f else 0f)
                                .zIndex(if (presented) 2f else 0f),
                        )
                    }
                }
                if (presentedHostId == null) {
            CompactRootScaffold(
                selectedTab = selectedTab,
                agentCenterEnabled = appPreferences.agentCenterEnabled,
                programAttention = programAttentionCounts,
                onSelect = { selectedTab = it },
                modifier = Modifier.fillMaxSize().zIndex(1f),
            ) { padding ->
                when (selectedTab) {
                    CompactRootTab.Hosts -> HostListScreen(
                        repository = hostRepository,
                        identities = identityRepository,
                        connectedHostIds = connectedHostIds,
                                onOpenHost = { host ->
                                    openHost(host, connectOnPresent = true, explicitOpen = true)
                                },
                        modifier = Modifier.fillMaxSize().padding(padding),
                    )
                    CompactRootTab.Sessions -> SessionLandingScreen(
                        hosts = hosts,
                                restoreRecords = restoreRecords,
                                liveStates = liveSessionStates,
                                programStatusSessions = programStatusSessions,
                                programStatusAgents = programStatusAgents,
                                unreadSessionIds = if (appPreferences.bellVisualEnabled) {
                                    bellUnread.sessionIds
                                } else emptySet(),
                                onOpenHost = { host ->
                                    // The row this opens is labelled with what
                                    // it will do — "reconnect" for a stored
                                    // record whose tab is gone — and a bare
                                    // `openHost` did neither: it mounted a tab
                                    // that sat disconnected, and started it
                                    // under a fresh session id that orphaned
                                    // the very record the row was drawn from.
                                    // The hosts list has passed
                                    // `connectOnPresent` all along; only this
                                    // list did not.
                                    //
                                    // Connecting is still the session screen's
                                    // decision, not this tap's:
                                    // `shouldConnectFromHostOpen` acts only on
                                    // a Disconnected state, so a row that is
                                    // already open is revealed, not redialled.
                                    val stored = restoreRecords.firstOrNull { it.hostId == host.id }
                                    if (stored != null && liveSessionStates[host.id] == null) {
                                        stored.tmuxTarget?.takeIf { it.isNotBlank() }?.let {
                                            pairingTmuxOverrides[host.id] = it
                                        }
                                        openHost(
                                            host = host,
                                            sessionId = stored.sessionId,
                                            createdAtEpochMilliseconds = stored.updatedAtEpochMilliseconds,
                                            connectOnPresent = true,
                                            explicitOpen = true,
                                        )
                                    } else {
                                        openHost(host, connectOnPresent = true, explicitOpen = true)
                                    }
                                },
                                onCloseSession = { hostId ->
                                    // An explicit dismissal retires its entry, or
                                    // an open window reopens the session the user
                                    // just closed.
                                    liveSessionIds[hostId]?.let { restoreWindow.retire(listOf(it)) }
                                    // The session is over: the transport goes
                                    // with the tab, which is the whole
                                    // difference between this and a window the
                                    // system happened to rebuild.
                                    sessionStore.close(hostId)
                                    programStatusCenter.remove(hostId)
                                    programStatusFocusRequests.remove(hostId)
                                    liveSessionStates.remove(hostId)
                                    liveSessionTransportReachable.remove(hostId)
                                    restoreOnMountHostIds.remove(hostId)
                                    hostOpenConnectRequests.remove(hostId)
                                    restoreReconnectRequests.remove(hostId)
                                    compositionScope.launch {
                                        restoreRepository.deleteForHost(hostId)
                                        foregroundRestoreStore.removeForHost(hostId)
                                    }
                                },
                        modifier = Modifier.fillMaxSize().padding(padding),
                    )
                    CompactRootTab.Agents -> AgentCenterScreen(
                        presenter = agentPresenter,
                        captureProtectionEnabled = appPreferences.hidesContentInAppSwitcher,
                        onOpenTerminal = { detail ->
                            compositionScope.launch {
                                val host = liveSessions.firstOrNull { detail.targetsLiveSession(it.id, liveSessionIds[it.id]) }
                                navigateToExistingAgentTerminal(
                                    isCurrentCarrier = { host != null && detail.targetsLiveSession(host.id, liveSessionIds[host.id]) &&
                                        agentPresenter.isTerminalCarrierCurrent(detail) },
                                    focus = { agentPresenter.focusExact(detail) { presentedHostId == host?.id } },
                                    reveal = { openHost(checkNotNull(host), explicitOpen = true) },
                                    isCurrentTarget = { agentPresenter.isTerminalBindingCurrent(detail) },
                                    isStillPresented = { presentedHostId == host?.id },
                                    onOutcome = { agentPresenter.reportTerminalNavigationOutcome(it) },
                                )
                            }
                        },
                        onLaunchRequested = agentPresenter::requestLaunch,
                        onOpenCandidateTerminal = { candidate ->
                            compositionScope.launch {
                                val host = liveSessions.firstOrNull { agentPresenter.candidateTargetsLiveSession(candidate, it.id, liveSessionIds[it.id]) }
                                navigateToExistingAgentTerminal(
                                    isCurrentCarrier = { host != null && agentPresenter.candidateTargetsLiveSession(candidate, host.id, liveSessionIds[host.id]) },
                                    focus = { agentPresenter.focusCandidateExact(candidate) { presentedHostId == host?.id } },
                                    reveal = { openHost(checkNotNull(host), explicitOpen = true) },
                                    isCurrentTarget = { agentPresenter.isCandidateBindingCurrent(candidate) },
                                    isStillPresented = { presentedHostId == host?.id },
                                    onOutcome = { agentPresenter.reportTerminalNavigationOutcome(it, candidate = true) },
                                )
                            }
                        },
                        modifier = Modifier.fillMaxSize().agentCenterContentPadding(padding),
                    )
                    CompactRootTab.Keys -> {
                        // Leaving Keys while its credential prompt is up must
                        // not leave the excursion counted (it would disable
                        // the hide and the app lock for the rest of the run).
                        DisposableEffect(keysExcursion) { onDispose { keysExcursion(false) } }
                        IdentityListScreen(
                            repository = identityRepository,
                            hostRepository = hostRepository,
                            knownHostsRepository = knownHostsRepository,
                            credentialStore = credentialStore,
                            onSystemUiActiveChanged = keysExcursion,
                            modifier = Modifier.fillMaxSize().padding(padding),
                        )
                    }
                    CompactRootTab.Settings -> {
                        // Same for a Settings picker or permission prompt.
                        DisposableEffect(settingsExcursion) { onDispose { settingsExcursion(false) } }
                        SettingsLandingScreen(
                            preferences = appPreferences,
                            sessionRestorePolicy = continuityState?.policy ?: SessionRestorePolicy.ASK,
                            usesCompactShell = usesCompactShell,
                            appLockError = appLockError,
                            knownHostsRepository = knownHostsRepository,
                            hosts = hosts,
                            pairingCoordinator = pairingCoordinator,
                            onReceivedSetupFinished = {
                                presentedHostId = null
                                selectedTab = CompactRootTab.Hosts
                            },
                            diagnostics = diagnostics,
                            onUploadDiagnosticLog = onUploadDiagnosticLog,
                            onAppLockChanged = onAppLockChanged,
                            onExternalUiActiveChanged = settingsExcursion,
                            onTerminalTextSizeChanged = { size ->
                                compositionScope.launch { preferences.updateTerminalTextSize(size) }
                            },
                            onTerminalFontChanged = { id ->
                                compositionScope.launch { preferences.updateTerminalFontId(id) }
                            },
                            onScrollbackLinesChanged = { lines ->
                                compositionScope.launch { preferences.updateScrollbackLines(lines) }
                            },
                            onResizeTerminalWithKeyboardChanged = { enabled ->
                                compositionScope.launch { preferences.updateResizeTerminalWithKeyboard(enabled) }
                            },
                            onTerminalThemeChanged = { theme ->
                                compositionScope.launch { preferences.updateTerminalThemeId(theme) }
                            },
                            onTerminalCursorStyleChanged = { style ->
                                compositionScope.launch { preferences.updateTerminalCursorStyle(style) }
                            },
                            onTerminalCursorBlinkChanged = { enabled ->
                                compositionScope.launch { preferences.updateTerminalCursorBlink(enabled) }
                            },
                            onTerminalBackgroundUsesImageChanged = { enabled ->
                                compositionScope.launch { preferences.updateTerminalBackgroundUsesImage(enabled) }
                            },
                            onTerminalBackgroundImageChanged = { imageId ->
                                compositionScope.launch { preferences.updateTerminalBackgroundImageId(imageId) }
                            },
                            onTerminalBackgroundDimChanged = { dim ->
                                compositionScope.launch { preferences.updateTerminalBackgroundDim(dim) }
                            },
                            onTerminalBackgroundBlurChanged = { blur ->
                                compositionScope.launch { preferences.updateTerminalBackgroundBlur(blur) }
                            },
                            onTerminalBackgroundFillModeChanged = { mode ->
                                compositionScope.launch { preferences.updateTerminalBackgroundFillMode(mode) }
                            },
                            onSmoothScrollingEnabledChanged = { enabled ->
                                compositionScope.launch { preferences.updateSmoothScrollingEnabled(enabled) }
                            },
                            onSmoothScrollingSpeedChanged = { speed ->
                                compositionScope.launch { preferences.updateSmoothScrollingSpeed(speed) }
                            },
                            onProgramStatusEnabledChanged = { enabled ->
                                compositionScope.launch { preferences.updateProgramStatusEnabled(enabled) }
                            },
                            onAccessoryBarKeysChanged = { keys ->
                                compositionScope.launch { preferences.updateAccessoryBarKeys(keys) }
                            },
                            onModifierBehaviorChanged = { value ->
                                compositionScope.launch { preferences.updateModifierBehavior(value) }
                            },
                            onModifierNotationChanged = { value ->
                                compositionScope.launch { preferences.updateModifierNotation(value) }
                            },
                            onSessionRestorePolicyChanged = { policy ->
                                // Turning restore off mid-wake ends the window too,
                                // or it keeps holding snapshots for a document the
                                // user just asked to stop keeping — and would write
                                // them back when it settles.
                                if (policy == SessionRestorePolicy.NEVER) restoreCoordinator.closeWindow()
                                compositionScope.launch {
                                    foregroundRestoreStore.updateRestorePolicy(policy)
                                    if (policy == SessionRestorePolicy.NEVER) {
                                        restoreCoordinator.withDocument { foregroundRestoreStore.clear() }
                                    }
                                }
                            },
                            onBellSoundChanged = { enabled ->
                                compositionScope.launch { preferences.updateBellSoundEnabled(enabled) }
                            },
                            onBellVisualChanged = { enabled ->
                                compositionScope.launch { preferences.updateBellVisualEnabled(enabled) }
                            },
                            onBellNotificationChanged = { enabled ->
                                compositionScope.launch { preferences.updateBellNotificationEnabled(enabled) }
                                if (enabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                                    !bellController.canPostNotifications()
                                ) {
                                    bellPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                                }
                            },
                            bellNotificationsAvailable = bellNotificationsAvailable,
                            onOpenBellNotificationSettings = {
                                context.startActivity(
                                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                        .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName),
                                )
                            },
                            onTestBell = {
                                bellController.ring(
                                    BellEvent(
                                        source = BellSource.Session("settings-test"),
                                        originOnScreen = false,
                                        hostDisplayName = "tessera",
                                        paneTitle = "test",
                                    ),
                                    appPreferences.toBellPreferences(),
                                )
                            },
                            onAgentCenterEnabledChanged = { enabled ->
                                compositionScope.launch { preferences.updateAgentCenterEnabled(enabled) }
                            },
                            onHideContentInAppSwitcherChanged = { enabled ->
                                compositionScope.launch { preferences.updateHideContentInAppSwitcher(enabled) }
                            },
                            onAgentCenterNotificationsChanged = { enabled ->
                                compositionScope.launch { preferences.updateAgentCenterNotificationsEnabled(enabled) }
                                if (enabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                                    !bellController.canPostNotifications()
                                ) {
                                    // This is an explicit Agent Center notification opt-in, not screen entry.
                                    bellPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                                }
                            },
                            autoStartContinuationHost = hosts.firstOrNull {
                                it.id == pendingPairingContinuationHostId
                            },
                            onAutoStartConsumed = { pendingPairingContinuationHostId = null },
                            modifier = Modifier.fillMaxSize().padding(padding),
                        )
                    }
                }
            }
                }
            }
            else -> Surface(
                modifier = Modifier.fillMaxSize().zIndex(1f),
                color = LocalTesseraTokens.current.bg,
            ) {
                val tokens = LocalTesseraTokens.current
                Column(
                    modifier = Modifier.fillMaxSize().padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    TesseraLogoMark(size = 56.dp)
                    Text(
                        text = stringResource(R.string.app_name).lowercase(),
                        modifier = Modifier.padding(top = 18.dp),
                        style = TesseraType.page,
                        color = tokens.fg,
                    )
                    Text(
                        modifier = Modifier.padding(top = 10.dp),
                        text = when (state) {
                            null -> stringResource(R.string.shared_core_checking)
                            is CoreBridgeState.Failed -> stringResource(R.string.shared_core_failed)
                            is CoreBridgeState.Ready -> stringResource(R.string.shared_core_ready)
                        },
                        textAlign = TextAlign.Center,
                        style = TesseraType.body,
                        color = tokens.fgMuted,
                    )
                    when (state) {
                        null -> Unit
                        is CoreBridgeState.Failed -> Text(
                            modifier = Modifier.padding(top = 8.dp),
                            text = state.reason,
                            textAlign = TextAlign.Center,
                            style = TesseraType.bodySmall,
                            color = tokens.red,
                        )
                        is CoreBridgeState.Ready -> Text(
                            modifier = Modifier.padding(top = 8.dp),
                            text = pluralStringResource(
                                R.plurals.shared_core_contract,
                                state.runtime.maxPayloadBytes.toInt(),
                                state.runtime.abiVersion,
                                state.runtime.maxPayloadBytes,
                            ),
                            textAlign = TextAlign.Center,
                            style = TesseraType.code,
                            color = tokens.fgDim,
                        )
                    }
                }
            }
        }
        if (locked) {
            AppLockOverlay(onUnlock = onUnlock, modifier = Modifier.fillMaxSize().zIndex(10f))
        }
        restorePrompt?.takeIf { !locked }?.let { document ->
            RestorePreviousSessionsDialog(
                document = document,
                alwaysReopen = restoreAlwaysReopen,
                onAlwaysReopenChanged = { restoreAlwaysReopen = it },
                onReopen = {
                    if (restoreAlwaysReopen) compositionScope.launch {
                        foregroundRestoreStore.updateRestorePolicy(SessionRestorePolicy.ALWAYS)
                    }
                    restorePrompt = null
                    // Answering is a verdict, and it is applied before the
                    // restore: an entry that has been acted on must never be
                    // reconsidered, or the next tick raises this same sheet
                    // again — the replacement can never match it — and a second
                    // tap stacks a duplicate tab.
                    val hadWindow = restoreWindow.isOpen
                    restoreWindow.retire(document.snapshots.map(ForegroundRestoreSnapshot::sessionId))
                    if (hadWindow) {
                        restoreSnapshots(
                            snapshots = document.snapshots,
                            selectedSessionId = document.selectedSessionId,
                            presentsRestored = false,
                        )
                    } else {
                        reopen(document)
                    }
                    restoreCoordinator.markStartupResolved()
                    if (!pairingRecoveryHandled && continuityState?.pendingContinuation != null) {
                        pairingRecoveryHandled = true
                        pairingCoordinator.recoverPendingContinuationOnStartup()
                    }
                },
                onNotNow = {
                    restorePrompt = null
                    restoreAlwaysReopen = false
                    restoreCoordinator.markStartupResolved()
                    pairingRecoveryHandled = true
                    val hadWindow = restoreWindow.isOpen
                    restoreWindow.retire(document.snapshots.map(ForegroundRestoreSnapshot::sessionId))
                    compositionScope.launch {
                        // Declining at startup means the document is spent. A
                        // window that is still open owns it instead: it closes
                        // on its own and writes what actually survived, and
                        // clearing under that would both race the write and
                        // delete the snapshots of the sessions still alive.
                        if (!hadWindow) {
                            foregroundRestoreStore.clear()
                            restoreRecords.forEach { restoreRepository.delete(it.sessionId) }
                        }
                        pendingContinuationStore.clear()
                    }
                },
            )
        }
        // Share-in ingress. Presented over whatever is on screen: a share has to
        // be routed to a host before anything can happen with it, and making the
        // user go find that host in a tab first is how the payload got lost.
        // Waits behind the lock screen and the restore prompt — both are
        // decisions about which sessions exist, which this one depends on.
        if (pendingShare != null && !locked && restorePrompt == null) {
            val payload = pendingShare
            val sharePreferences = remember(context) {
                context.getSharedPreferences(SHARE_PREFERENCES, Context.MODE_PRIVATE)
            }
            val shareFiles = remember(payload) { readSharedFileMetadata(context, payload.uris) }
            val shareTargets = hosts.map { host ->
                val liveState = liveSessionStates[host.id]
                ShareUploadTarget(
                    id = host.id,
                    label = host.displayName.ifBlank { host.hostname },
                    detail = "${host.username}@${host.hostname}:${host.port}",
                    isConnected = liveState == SshSessionUiState.Connected,
                    isConnecting = liveState == SshSessionUiState.Connecting ||
                        liveState is SshSessionUiState.AwaitingCredential ||
                        liveState is SshSessionUiState.AwaitingHostKey ||
                        liveState is SshSessionUiState.AwaitingOwnerAuthorization,
                    isActiveSession = presentedHostId == host.id &&
                        liveState == SshSessionUiState.Connected,
                    isFailed = liveState is SshSessionUiState.Failed,
                    sessionCwd = liveSessionCwds[host.id],
                )
            }
            ShareUploadSheet(
                fileNames = shareFiles.map(SharedFileMetadata::name),
                totalBytes = shareFiles.mapNotNull(SharedFileMetadata::size)
                    .takeIf { it.size == shareFiles.size && it.isNotEmpty() }
                    ?.sum(),
                sharedText = payload.text,
                targets = shareTargets,
                reaperDays = RemoteFilesConstants.DEFAULT_REAPER_DAYS,
                initialTargetId = pendingShareTargetId,
                rememberedDestination = { hostId ->
                    sharePreferences.getString(ShareUploadPolicy.rememberedDestinationKey(hostId), null)
                },
                onRememberDestination = { hostId, value ->
                    sharePreferences.edit()
                        .putString(ShareUploadPolicy.rememberedDestinationKey(hostId), value)
                        .apply()
                },
                onConfirm = { choice ->
                    hosts.firstOrNull { it.id == choice.targetId }?.let { host ->
                        // "Upload as file" has no content URI yet: the payload
                        // was text, and the transfer path moves bytes from a
                        // provider. Stage it before the sheet goes away.
                        val stagedText = payload.text
                            ?.takeIf { it.isNotEmpty() && choice.textMode == ShareTextMode.UploadAsFile }
                        val uris = stagedText
                            ?.let { listOf(SharedTextStaging.stage(context, it)) }
                            ?: payload.uris
                        val routed = PendingShareUpload(
                            hostId = host.id,
                            uris = uris,
                            text = payload.text,
                            textMode = choice.textMode,
                            destination = choice.destination,
                            pastePath = choice.pastePath,
                        )
                        diagnostics.record(
                            "share_routed",
                            mapOf(
                                "count" to uris.size.toString(),
                                "destination" to ShareUploadPolicy.rememberedValue(choice.destination),
                                "paste" to choice.pastePath.toString(),
                            ),
                        )
                        onShareRouted(routed)
                        // The user tapped "upload" / "connect & upload"; that
                        // gesture is what opens the session, never the share.
                        openHost(host, connectOnPresent = true, explicitOpen = true)
                    }
                },
                onCancel = {
                    diagnostics.record("share_discarded", emptyMap())
                    onShareDiscarded()
                },
            )
        }
        if (pairingRecoveryPrompt && !locked) {
            TesseraConfirmDialog(
                title = "interrupted continuation",
                body = "Reconnect the verified destination session? The old pairing transaction will not be resumed.",
                confirmLabel = "reconnect",
                cancelLabel = "not now",
                onConfirm = {
                    pairingRecoveryPrompt = false
                    pairingRecoveryHandled = true
                    pairingCoordinator.recoverPendingContinuationOnStartup()
                },
                onDismiss = {
                    pairingRecoveryPrompt = false
                    pairingRecoveryHandled = true
                    compositionScope.launch { pendingContinuationStore.clear() }
                },
            )
        }
    }
}

/** Share-sheet preferences: the per-host last-destination memory. */
private const val SHARE_PREFERENCES = "tessera.files"

private data class SharedFileMetadata(val name: String, val size: Long?)

/**
 * Names and sizes for the ingress sheet's payload row. A provider is free to
 * answer neither, so both stay optional and the row degrades to a count.
 */
private fun readSharedFileMetadata(context: Context, uris: List<Uri>): List<SharedFileMetadata> {
    val resolver = context.contentResolver
    return uris.map { uri ->
        var name: String? = null
        var size: Long? = null
        runCatching {
            resolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
                }
            }
        }
        SharedFileMetadata(
            name = name?.takeIf(String::isNotBlank) ?: uri.lastPathSegment.orEmpty().ifBlank { "shared file" },
            size = size,
        )
    }
}

private data class ContinuityLaunchState(
    val policy: SessionRestorePolicy,
    val document: ForegroundRestoreDocument?,
    val pendingContinuation: PendingContinuationRecovery?,
)

@Composable
private fun RestorePreviousSessionsDialog(
    document: ForegroundRestoreDocument,
    alwaysReopen: Boolean,
    onAlwaysReopenChanged: (Boolean) -> Unit,
    onReopen: () -> Unit,
    onNotNow: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    TesseraDialog(
        title = "previous connections",
        onDismissRequest = {},
        actions = {
            TesseraButton(text = "not now", onClick = onNotNow, compact = true)
            TesseraButton(
                text = "reopen",
                onClick = onReopen,
                style = TesseraButtonStyle.Primary,
                compact = true,
            )
        },
    ) {
        Text(
            "Reopen ${document.snapshots.size} saved session${if (document.snapshots.size == 1) "" else "s"}?",
            style = TesseraType.body,
            color = tokens.fgMuted,
        )
        document.snapshots.take(5).forEach { snapshot ->
            Text("• ${snapshot.displayName}", style = TesseraType.rowMeta, color = tokens.fg)
        }
        if (document.snapshots.size > 5) {
            Text(
                "+${document.snapshots.size - 5} more",
                style = TesseraType.rowMeta,
                color = tokens.fgMuted,
            )
        }
        TesseraToggleRow(
            title = "always reopen",
            subtitle = "Reopen restorable sessions automatically next time.",
            checked = alwaysReopen,
            onCheckedChange = onAlwaysReopenChanged,
            contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 8.dp),
        )
    }
}

@Composable
private fun AppLockOverlay(onUnlock: () -> Unit, modifier: Modifier = Modifier) {
    val tokens = LocalTesseraTokens.current
    Surface(modifier, color = tokens.bg) {
        Column(
            modifier = Modifier.fillMaxSize().padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            TesseraEmptyState(
                title = stringResource(R.string.app_lock_title).lowercase(),
                body = stringResource(R.string.app_lock_body),
                icon = TesseraIcons.Lock,
                action = {
                    TesseraButton(
                        text = stringResource(R.string.app_lock_unlock),
                        onClick = onUnlock,
                        style = TesseraButtonStyle.Primary,
                    )
                },
            )
        }
    }
}

internal enum class CompactRootTab(val icon: ImageVector, val label: String) {
    Hosts(TesseraIcons.Hosts, "hosts"),
    Sessions(TesseraIcons.Sessions, "sessions"),
    Agents(TesseraIcons.Agents, "agents"),
    Keys(TesseraIcons.Keys, "keys"),
    Settings(TesseraIcons.Settings, "settings"),
}

/** The production compact shell, also exercised by host-free keyboard tests. */
@Composable
internal fun CompactRootScaffold(
    selectedTab: CompactRootTab,
    agentCenterEnabled: Boolean,
    onSelect: (CompactRootTab) -> Unit,
    modifier: Modifier = Modifier,
    programAttention: ProgramAttentionCounts = ProgramAttentionCounts(),
    content: @Composable (androidx.compose.foundation.layout.PaddingValues) -> Unit,
) {
    Scaffold(
        modifier = modifier,
        containerColor = LocalTesseraTokens.current.bg,
        bottomBar = { CompactBottomBar(selectedTab, agentCenterEnabled, onSelect, programAttention) },
        content = content,
    )
}

/** Detail's IME padding must account for the tab/navigation space already applied by Scaffold. */
internal fun Modifier.agentCenterContentPadding(padding: androidx.compose.foundation.layout.PaddingValues): Modifier =
    padding(padding).consumeWindowInsets(padding)

/**
 * Root tab bar.
 *
 * Icons are drawn vectors at 24dp with a sans caption, not the glyph-plus-micro-mono
 * pairing this used to be: at 10sp the captions were below the platform's smallest
 * legible size, and the unselected tint sat at the muted token, which is a colour
 * meant for supporting copy rather than for the app's primary navigation.
 */
@Composable
private fun CompactBottomBar(
    selectedTab: CompactRootTab,
    agentCenterEnabled: Boolean,
    onSelect: (CompactRootTab) -> Unit,
    programAttention: ProgramAttentionCounts,
) {
    val tokens = LocalTesseraTokens.current
    Column(Modifier.background(tokens.panelBg)) {
        TesseraHairline()
        Row(
            Modifier.fillMaxWidth().navigationBarsPadding().heightIn(min = 60.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CompactRootTab.entries.filter { it != CompactRootTab.Agents || agentCenterEnabled }.forEach { tab ->
                val selected = tab == selectedTab
                val tint = if (selected) tokens.accent else tokens.fgMuted
                val attention = programAttention.takeIf { tab == CompactRootTab.Sessions && it.total > 0 }
                val attentionSummary = attention?.let { programStatusCountSummary(it) }
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .heightIn(min = 56.dp)
                        .testTag("root-${tab.label}")
                        .clickable(role = Role.Tab) { onSelect(tab) }
                        .semantics {
                            if (attention != null) stateDescription = "${attention.total} · $attentionSummary"
                        }
                        .padding(vertical = 8.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Box {
                        Icon(tab.icon, contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
                        if (attention != null) {
                            val badgeTone = when (attention.tone) {
                                ProgramAttentionTone.NEEDS_INPUT -> tokens.amber
                                ProgramAttentionTone.FAILED -> tokens.red
                                ProgramAttentionTone.FINISHED -> tokens.green
                                null -> tokens.fgDim
                            }
                            Text(
                                attention.total.toString(),
                                modifier = Modifier.align(Alignment.TopEnd)
                                    .background(tokens.panelBg, RoundedCornerShape(6.dp))
                                    .padding(horizontal = 3.dp),
                                color = badgeTone,
                                style = TesseraType.rowMicro,
                            )
                        }
                    }
                    Text(
                        tab.label,
                        modifier = Modifier.padding(top = 4.dp),
                        color = tint,
                        style = TesseraType.navLabel,
                    )
                }
            }
        }
    }
}

@Composable
private fun SessionLandingScreen(
    hosts: List<SavedHost>,
    restoreRecords: List<com.bambouville.tessera.data.SessionRestoreRecord>,
    liveStates: Map<String, SshSessionUiState>,
    programStatusSessions: Map<String, ProgramStatusSessionState>,
    programStatusAgents: ProgramStatusAgentInput,
    unreadSessionIds: Set<String>,
    onOpenHost: (SavedHost) -> Unit,
    onCloseSession: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalTesseraTokens.current
    val recordsByHost = restoreRecords.associateBy { it.hostId }
    val restorable = hosts.filter { it.id in liveStates || it.id in recordsByHost }
    Column(modifier.background(tokens.bg)) {
        TesseraPageHeader("sessions")
        TesseraHairline()
        if (restorable.isEmpty()) {
            TesseraEmptyState(
                title = "no active sessions",
                body = "Open a host to start a terminal session. Sessions you leave stay connected here.",
                icon = TesseraIcons.Sessions,
                modifier = Modifier.fillMaxWidth().weight(1f),
            )
        } else {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                restorable.forEach { host ->
                    val liveState = liveStates[host.id]
                    val counts = ProgramStatusQueries.sessionCounts(programStatusSessions, host.id, programStatusAgents)
                    val tone = when {
                        liveState == SshSessionUiState.Connected -> tokens.green
                        liveState == SshSessionUiState.Connecting ||
                            liveState is SshSessionUiState.AwaitingCredential ||
                            liveState is SshSessionUiState.AwaitingHostKey ||
                            liveState is SshSessionUiState.AwaitingOwnerAuthorization -> tokens.amber
                        liveState is SshSessionUiState.Failed -> tokens.red
                        // Amber is reserved for a connection in flight. A saved
                        // record that still needs reconnecting is simply not live,
                        // and its row reads dim like every other dormant session.
                        else -> tokens.fgDim
                    }
                    val label = when (liveState) {
                        SshSessionUiState.Connected -> "open"
                        SshSessionUiState.Connecting,
                        is SshSessionUiState.AwaitingCredential,
                        is SshSessionUiState.AwaitingHostKey,
                        is SshSessionUiState.AwaitingOwnerAuthorization -> "connecting"
                        is SshSessionUiState.Failed -> "failed"
                        SshSessionUiState.Disconnected -> "connect"
                        SshSessionUiState.Terminated -> "ended"
                        null -> "reconnect"
                    }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 68.dp)
                            .clickable { onOpenHost(host) }
                            .padding(start = 18.dp, end = 4.dp, top = 10.dp, bottom = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        TesseraRowGlyph(icon = TesseraIcons.Sessions, badge = tone)
                        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                            Text(host.displayName, style = TesseraType.rowTitle, color = tokens.fg, maxLines = 1)
                            Text(
                                "${host.username}@${host.hostname}:${host.port}",
                                color = tokens.fgMuted,
                                style = TesseraType.rowMeta,
                                maxLines = 1,
                            )
                            if (counts.total > 0) {
                                Text(
                                    programStatusCountLine(counts),
                                    style = TesseraType.rowMeta,
                                    maxLines = 1,
                                )
                            }
                        }
                        if (host.id in unreadSessionIds) {
                            TesseraStatusDot(tokens.accent, size = 7.dp)
                            Spacer(Modifier.width(8.dp))
                        }
                        TesseraTag(label, tone = tone)
                        TesseraIconButton(
                            icon = TesseraIcons.Close,
                            contentDescription = "Close ${host.displayName}",
                            onClick = { onCloseSession(host.id) },
                        )
                    }
                    TesseraHairline(Modifier.padding(start = 66.dp))
                }
            }
        }
    }
}

@Composable
private fun SettingsLandingScreen(
    preferences: AppPreferences,
    sessionRestorePolicy: SessionRestorePolicy,
    usesCompactShell: Boolean,
    appLockError: String?,
    knownHostsRepository: com.bambouville.tessera.data.KnownHostsRepository,
    hosts: List<SavedHost>,
    pairingCoordinator: CrossDevicePairingCoordinator,
    onReceivedSetupFinished: () -> Unit,
    diagnostics: DiagnosticLogStore,
    onUploadDiagnosticLog: () -> Unit,
    onAppLockChanged: (Boolean) -> Unit,
    onExternalUiActiveChanged: (Boolean) -> Unit,
    onTerminalTextSizeChanged: (Int) -> Unit,
    onTerminalFontChanged: (String) -> Unit,
    onScrollbackLinesChanged: (Int) -> Unit,
    onResizeTerminalWithKeyboardChanged: (Boolean) -> Unit,
    onTerminalThemeChanged: (String) -> Unit,
    onTerminalCursorStyleChanged: (String) -> Unit,
    onTerminalCursorBlinkChanged: (Boolean) -> Unit,
    onTerminalBackgroundUsesImageChanged: (Boolean) -> Unit,
    onTerminalBackgroundImageChanged: (String?) -> Unit,
    onTerminalBackgroundDimChanged: (Float) -> Unit,
    onTerminalBackgroundBlurChanged: (Int) -> Unit,
    onTerminalBackgroundFillModeChanged: (String) -> Unit,
    onSmoothScrollingEnabledChanged: (Boolean) -> Unit,
    onSmoothScrollingSpeedChanged: (Float) -> Unit,
    onProgramStatusEnabledChanged: (Boolean) -> Unit,
    onAccessoryBarKeysChanged: (List<String>) -> Unit,
    onModifierBehaviorChanged: (String) -> Unit,
    onModifierNotationChanged: (String) -> Unit,
    onSessionRestorePolicyChanged: (SessionRestorePolicy) -> Unit,
    onBellSoundChanged: (Boolean) -> Unit,
    onBellVisualChanged: (Boolean) -> Unit,
    onBellNotificationChanged: (Boolean) -> Unit,
    bellNotificationsAvailable: Boolean,
    onOpenBellNotificationSettings: () -> Unit,
    onTestBell: () -> Unit,
    onAgentCenterEnabledChanged: (Boolean) -> Unit,
    onAgentCenterNotificationsChanged: (Boolean) -> Unit,
    onHideContentInAppSwitcherChanged: (Boolean) -> Unit,
    autoStartContinuationHost: SavedHost?,
    onAutoStartConsumed: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var destination by remember {
        mutableStateOf(
            if (autoStartContinuationHost == null) null else SettingsDestination.Pairing,
        )
    }
    LaunchedEffect(autoStartContinuationHost?.id) {
        if (autoStartContinuationHost != null) destination = SettingsDestination.Pairing
    }
    val tokens = LocalTesseraTokens.current
    when (destination) {
        SettingsDestination.KnownHosts -> {
            KnownHostsScreen(knownHostsRepository, onBack = { destination = null }, modifier = modifier)
            return
        }
        SettingsDestination.Diagnostics -> {
            DiagnosticsScreen(
                store = diagnostics,
                onUploadLog = onUploadDiagnosticLog,
                onBack = { destination = null },
                modifier = modifier,
            )
            return
        }
        SettingsDestination.Pairing -> {
            PairingScreen(
                hosts = hosts,
                coordinator = pairingCoordinator,
                onExternalUiActiveChanged = onExternalUiActiveChanged,
                onBack = { destination = null },
                autoStartContinuationHost = autoStartContinuationHost,
                onAutoStartConsumed = onAutoStartConsumed,
                onReceivedSetupFinished = {
                    destination = null
                    onReceivedSetupFinished()
                },
                modifier = modifier,
            )
            return
        }
        null -> Unit
    }
    // One long scroll mixed typography, colour, cursor, scrollback, background,
    // scrolling and the accessory bar into a single "terminal" heading, and
    // filed diagnostics under security. Sections are their own pages now, named
    // as iOS names them where the same settings exist, so the landing screen is
    // a map rather than a wall.
    var section by rememberSaveable { mutableStateOf<SettingsSection?>(null) }
    Column(modifier.background(tokens.bg).verticalScroll(rememberScrollState())) {
        val current = section
        if (current == null) {
            TesseraPageHeader("settings")
            TesseraHairline()
            SettingsSection.entries.forEach { entry ->
                TesseraNavigationRow(
                    title = entry.title,
                    subtitle = entry.summary,
                    onClick = {
                        val opens = entry.opens
                        if (opens != null) destination = opens else section = entry
                    },
                )
                TesseraHairline(Modifier.padding(start = 18.dp))
            }
            Spacer(Modifier.height(24.dp))
            return@Column
        }

        TesseraSubPageHeader(
            title = current.title,
            onBack = { section = null },
            backContentDescription = "back to settings",
        )
        TesseraHairline()

        if (current == SettingsSection.Appearance) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 12.dp)) {
                Text("color theme", style = TesseraType.rowTitle, color = tokens.fg)
                Text(
                    "Applied independently to every terminal surface.",
                    style = TesseraType.rowMeta,
                    color = tokens.fgMuted,
                    modifier = Modifier.padding(top = 3.dp, bottom = 8.dp),
                )
                val themes = listOf("void", "graphite", "amber", "paper", "dracula", "nord")
                TesseraSegmented(
                    options = themes.take(3),
                    selectedIndex = themes.take(3).indexOf(preferences.terminalThemeId),
                    onSelect = { onTerminalThemeChanged(themes[it]) },
                )
                TesseraSegmented(
                    options = themes.drop(3),
                    selectedIndex = themes.drop(3).indexOf(preferences.terminalThemeId),
                    onSelect = { onTerminalThemeChanged(themes[it + 3]) },
                    modifier = Modifier.padding(top = 4.dp),
                )
        }
        TesseraHairline(Modifier.padding(start = 18.dp))
        Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 12.dp)) {
            Text("terminal font", style = TesseraType.rowTitle, color = tokens.fg)
            Text(
                "Applies to the terminal grid only — app chrome keeps its own face.",
                style = TesseraType.rowMeta,
                color = tokens.fgMuted,
                modifier = Modifier.padding(top = 3.dp, bottom = 8.dp),
            )
            TesseraTerminalFontPicker(
                selectedId = TerminalFontCatalog.resolve(preferences.terminalFontId),
                onSelect = onTerminalFontChanged,
            )
        }
        TesseraHairline(Modifier.padding(start = 18.dp))
        TerminalBackgroundSettings(
            preferences = preferences,
            onExternalUiActiveChanged = onExternalUiActiveChanged,
            onUsesImageChanged = onTerminalBackgroundUsesImageChanged,
            onImageChanged = onTerminalBackgroundImageChanged,
            onDimChanged = onTerminalBackgroundDimChanged,
            onBlurChanged = onTerminalBackgroundBlurChanged,
            onFillModeChanged = onTerminalBackgroundFillModeChanged,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 12.dp),
        )
        TesseraHairline(Modifier.padding(start = 18.dp))
        }
        if (current == SettingsSection.Terminal) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("text size", modifier = Modifier.weight(1f), style = TesseraType.rowTitle, color = tokens.fg)
                    Text("${preferences.terminalTextSizeSp}sp", style = TesseraType.rowMeta, color = tokens.fgMuted)
                }
                TesseraSlider(
                    value = preferences.terminalTextSizeSp.toFloat(),
                    onValueChange = { onTerminalTextSizeChanged(it.toInt().coerceIn(8, 40)) },
                    valueRange = 8f..40f,
                    stepSize = 1f,
                    contentDescription = "Terminal text size",
                )
                Text(
                    "user@host:~$ ls -la",
                    style = TesseraType.code.copy(fontSize = preferences.terminalTextSizeSp.sp),
                    color = tokens.fgMuted,
                    maxLines = 1,
                    modifier = Modifier.padding(bottom = 10.dp),
                )
        }
        TesseraHairline(Modifier.padding(start = 18.dp))
        Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 12.dp)) {
            Text("cursor", style = TesseraType.rowTitle, color = tokens.fg)
            val styles = listOf("block", "bar", "underline")
            TesseraSegmented(
                options = styles,
                selectedIndex = styles.indexOf(preferences.terminalCursorStyle).coerceAtLeast(0),
                onSelect = { onTerminalCursorStyleChanged(styles[it]) },
            )
        }
        TesseraHairline(Modifier.padding(start = 18.dp))
        TesseraToggleRow(
            title = "blink cursor",
            subtitle = "Blink the active terminal cursor.",
            checked = preferences.terminalCursorBlink,
            onCheckedChange = onTerminalCursorBlinkChanged,
        )
        TesseraHairline(Modifier.padding(start = 18.dp))
        Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("scrollback", modifier = Modifier.weight(1f), style = TesseraType.rowTitle, color = tokens.fg)
                Text("${preferences.scrollbackLines} lines · new sessions", style = TesseraType.rowMeta, color = tokens.fgMuted)
            }
            TesseraSlider(
                value = preferences.scrollbackLines.toFloat(),
                onValueChange = {
                    onScrollbackLinesChanged(
                        ((it.toInt() / 1_000) * 1_000).coerceIn(1_000, 50_000),
                    )
                },
                valueRange = 1_000f..50_000f,
                stepSize = 1_000f,
                contentDescription = "Terminal scrollback lines",
            )
        }
        TesseraHairline(Modifier.padding(start = 18.dp))
        SmoothScrollingSettings(
            enabled = preferences.smoothScrollingEnabled,
            speed = preferences.smoothScrollingSpeed,
            onEnabledChanged = onSmoothScrollingEnabledChanged,
            onSpeedChanged = onSmoothScrollingSpeedChanged,
        )
        TesseraHairline(Modifier.padding(start = 18.dp))
        TesseraToggleRow(
            title = "program status",
            subtitle = "Show needs input, finished, and failed on tmux windows and session lists when programs report it (OSC 7501). Works without Agent Center.",
            checked = preferences.programStatusEnabled,
            onCheckedChange = onProgramStatusEnabledChanged,
        )
        TesseraHairline(Modifier.padding(start = 18.dp))
        }
        if (current == SettingsSection.Keyboard) {
            TesseraToggleRow(
                title = "resize terminal with keyboard",
                subtitle = "Reflow terminal rows when the software keyboard appears or hides.",
                checked = preferences.resizeTerminalWithKeyboard,
                onCheckedChange = onResizeTerminalWithKeyboardChanged,
            )
            TesseraHairline(Modifier.padding(start = 18.dp))
            AccessoryBarEditor(
                persistedKeys = preferences.accessoryBarKeys,
                notation = preferences.modifierNotation,
                onKeysChanged = onAccessoryBarKeysChanged,
                modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
            )
            TesseraHairline(Modifier.padding(start = 18.dp))
            ModifierBehaviorSettings(
                behavior = preferences.modifierBehavior,
                notation = preferences.modifierNotation,
                onBehaviorChanged = onModifierBehaviorChanged,
                onNotationChanged = onModifierNotationChanged,
                modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
            )
            TesseraHairline(Modifier.padding(start = 18.dp))
        }
        if (current == SettingsSection.Continuity) {
            TesseraNavigationRow(
                title = "pair another device",
                subtitle = "Pair with iPhone, iPad, or another Android device over local Wi-Fi.",
                onClick = { destination = SettingsDestination.Pairing },
            )
            TesseraHairline(Modifier.padding(start = 18.dp))
            if (usesCompactShell) {
                TesseraToggleRow(
                    title = "restore on launch",
                    subtitle = "Reopen restorable saved-host sessions automatically.",
                    checked = sessionRestorePolicy != SessionRestorePolicy.NEVER,
                    onCheckedChange = { enabled ->
                        onSessionRestorePolicyChanged(
                            if (enabled) SessionRestorePolicy.ALWAYS else SessionRestorePolicy.NEVER,
                        )
                    },
                )
            } else {
                Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 12.dp)) {
                    Text("previous connections", style = TesseraType.rowTitle, color = tokens.fg)
                    Text(
                        "Choose whether Tessera asks, reopens, or discards sessions after process death.",
                        style = TesseraType.rowMeta,
                        color = tokens.fgMuted,
                        modifier = Modifier.padding(top = 3.dp, bottom = 8.dp),
                    )
                    val policies = SessionRestorePolicy.entries
                    TesseraSegmented(
                        options = listOf("ask", "always", "never"),
                        selectedIndex = policies.indexOf(sessionRestorePolicy).coerceAtLeast(0),
                        onSelect = { index -> onSessionRestorePolicyChanged(policies[index]) },
                    )
                }
        }
        TesseraHairline(Modifier.padding(start = 18.dp))

        }
        if (current == SettingsSection.Bell) {
            TesseraToggleRow(
                title = "sound",
                subtitle = "Play a soft tone when an off-screen terminal emits BEL.",
                checked = preferences.bellSoundEnabled,
                onCheckedChange = onBellSoundChanged,
            )
            TesseraHairline(Modifier.padding(start = 18.dp))
            TesseraToggleRow(
                title = "visual flash",
                subtitle = "Show an accent glow and dot on the tmux window that rang.",
                checked = preferences.bellVisualEnabled,
                onCheckedChange = onBellVisualChanged,
            )
            TesseraHairline(Modifier.padding(start = 18.dp))
            TesseraToggleRow(
                title = "notify when backgrounded",
                subtitle = if (preferences.bellNotificationEnabled && !bellNotificationsAvailable) {
                    "Enabled in Tessera, but blocked by Android notification settings."
                } else {
                    "Show a silent banner when any terminal emits BEL while Tessera is away."
                },
                checked = preferences.bellNotificationEnabled,
                onCheckedChange = onBellNotificationChanged,
            )
            if (preferences.bellNotificationEnabled && !bellNotificationsAvailable) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 4.dp)) {
                    TesseraButton(
                        text = "open Android settings",
                        onClick = onOpenBellNotificationSettings,
                        compact = true,
                    )
                }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 10.dp)) {
            TesseraButton(
                text = "test bell",
                onClick = onTestBell,
                style = TesseraButtonStyle.Primary,
                compact = true,
            )
        }
        TesseraHairline(Modifier.padding(start = 18.dp))

        }
        if (current == SettingsSection.Security) {
            TesseraToggleRow(
                title = "app lock",
                subtitle = "Require your device credential when Tessera returns to the foreground.",
                checked = preferences.appLockEnabled,
                onCheckedChange = onAppLockChanged,
            )
            appLockError?.let {
                com.bambouville.tessera.design.TesseraBanner(
                    text = it,
                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 4.dp),
                )
        }
        TesseraHairline(Modifier.padding(start = 18.dp))
        // Shows the effective policy: app lock forces it on, as on iOS.
        TesseraToggleRow(
            title = "hide content in app switcher",
            subtitle = if (preferences.appLockEnabled) {
                "Always on while app lock is on. Recents shows a blank preview, and screenshots and screen sharing are blocked while Agent Center is open."
            } else {
                "Show a blank preview in Recents instead of Tessera's content. While Agent Center is open, this also blocks screenshots and screen sharing."
            },
            checked = preferences.hidesContentInAppSwitcher,
            onCheckedChange = onHideContentInAppSwitcherChanged,
            enabled = !preferences.appLockEnabled,
        )
        TesseraHairline(Modifier.padding(start = 18.dp))
        TesseraNavigationRow(
            title = "known hosts",
            subtitle = "Review trusted fingerprints and remove stale trust records.",
            onClick = { destination = SettingsDestination.KnownHosts },
        )
        TesseraHairline(Modifier.padding(start = 18.dp))
        }
        if (current == SettingsSection.Experimental) {
            TesseraToggleRow(
                title = "agent center",
                subtitle = "Show detected coding-agent threads. Transcript content remains memory-only.",
                checked = preferences.agentCenterEnabled,
                onCheckedChange = onAgentCenterEnabledChanged,
            )
            TesseraHairline(Modifier.padding(start = 18.dp))
            TesseraToggleRow(
                title = "agent attention notifications",
                subtitle = "Optional. Tessera sends only “Agent needs input” or “Agent finished” and “Open Tessera to review.” No terminal, task, host, provider, or transcript content leaves the app.",
                checked = preferences.agentCenterNotificationsEnabled,
                onCheckedChange = onAgentCenterNotificationsChanged,
            )
            TesseraHairline(Modifier.padding(start = 18.dp))

        }
        if (current == SettingsSection.About) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TesseraLogoMark(size = 22.dp)
                Text(
                    "Tessera for Android",
                    modifier = Modifier.weight(1f).padding(start = 12.dp),
                    style = TesseraType.rowTitle,
                    color = tokens.fg,
                )
                Text(BuildConfig.VERSION_NAME, color = tokens.fgMuted, style = TesseraType.rowMeta)
        }
        }
        Spacer(Modifier.height(24.dp))
    }
}

private enum class SettingsDestination { KnownHosts, Diagnostics, Pairing }

/**
 * Settings grouped the way the iOS build groups them, so a setting lives under
 * the same heading on both platforms. `summary` is what the landing row says the
 * section is for; the section's own controls carry their full explanations.
 */
private enum class SettingsSection(
    val title: String,
    val summary: String,
    /** Set when the row opens an existing screen instead of a section page. */
    val opens: SettingsDestination? = null,
) {
    Appearance("appearance", "Colour theme, terminal font, and background."),
    Terminal("terminal", "Text size, cursor, scrollback, scrolling, and program status."),
    Keyboard("keyboard & input", "Accessory bar and software-keyboard behaviour."),
    Continuity("sync & continuity", "Pairing and what reopens on launch."),
    Bell("bell & notifications", "What happens when a terminal rings."),
    Security("security", "App lock, app-switcher privacy, and trusted host keys."),
    Diagnostics("diagnostics", "Export or upload the local log.", SettingsDestination.Diagnostics),
    Experimental("experimental", "Agent Center and other in-progress work."),
    About("about", "Version and build."),
}



@Composable
internal fun TerminalBackgroundSettings(
    preferences: AppPreferences,
    onExternalUiActiveChanged: (Boolean) -> Unit,
    onUsesImageChanged: (Boolean) -> Unit,
    onImageChanged: (String?) -> Unit,
    onDimChanged: (Float) -> Unit,
    onBlurChanged: (Int) -> Unit,
    onFillModeChanged: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalTesseraTokens.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val store = remember(context.applicationContext) {
        TerminalBackgroundImageStore(context.applicationContext)
    }
    var previewBlur by remember(preferences.terminalBackgroundImageId) {
        mutableIntStateOf(preferences.terminalBackgroundBlur)
    }
    var importError by remember { mutableStateOf<String?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        onExternalUiActiveChanged(false)
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            val previousId = preferences.terminalBackgroundImageId
            val imported = withContext(Dispatchers.IO) {
                runCatching {
                    context.contentResolver.openInputStream(uri)?.use { input ->
                        store.importImage(input.readBytesBounded(MAX_TERMINAL_BACKGROUND_IMPORT_BYTES))
                    }
                }.getOrNull()
            }
            if (imported == null) {
                importError = "That image could not be imported. Choose a JPEG, PNG, or HEIF image under 32 MB."
            } else {
                importError = null
                onImageChanged(imported.imageId)
                onUsesImageChanged(true)
                if (previousId != null && previousId != imported.imageId) {
                    withContext(Dispatchers.IO) { store.delete(previousId) }
                }
            }
        }
    }

    Column(modifier) {
        Text("terminal background", style = TesseraType.rowTitle, color = tokens.fg)
        Text(
            "Use the terminal theme color or an app-owned picture. Background settings are global; per-host overrides are not part of Android v1.",
            style = TesseraType.rowMeta,
            color = tokens.fgMuted,
            modifier = Modifier.padding(top = 3.dp, bottom = 9.dp),
        )
        TesseraSegmented(
            options = listOf("theme color", "custom image"),
            selectedIndex = if (preferences.terminalBackgroundUsesImage) 1 else 0,
            onSelect = { index ->
                if (index == 0) onUsesImageChanged(false)
                else if (preferences.terminalBackgroundImageId != null) onUsesImageChanged(true)
                else {
                    onExternalUiActiveChanged(true)
                    picker.launch(arrayOf("image/*"))
                }
            },
        )
        Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TesseraButton(
                text = if (preferences.terminalBackgroundImageId == null) "choose image" else "replace image",
                onClick = {
                    onExternalUiActiveChanged(true)
                    picker.launch(arrayOf("image/*"))
                },
                compact = true,
            )
            if (preferences.terminalBackgroundImageId != null) {
                TesseraButton(
                    text = "remove",
                    onClick = {
                        val imageId = preferences.terminalBackgroundImageId
                        onUsesImageChanged(false)
                        onImageChanged(null)
                        if (imageId != null) scope.launch(Dispatchers.IO) { store.delete(imageId) }
                    },
                    style = TesseraButtonStyle.Danger,
                    compact = true,
                )
            }
        }
        importError?.let { error ->
            com.bambouville.tessera.design.TesseraBanner(error, Modifier.padding(top = 8.dp))
        }
        preferences.terminalBackgroundImageId?.let { imageId ->
            TerminalBackgroundPreview(
                imageId = imageId,
                themeId = preferences.terminalThemeId,
                dim = preferences.terminalBackgroundDim,
                previewBlur = previewBlur,
                committedBlur = preferences.terminalBackgroundBlur,
                fillMode = preferences.terminalBackgroundFillMode,
                enabled = preferences.terminalBackgroundUsesImage,
                store = store,
                modifier = Modifier.fillMaxWidth().height(150.dp).padding(top = 10.dp),
            )
        }
        if (preferences.terminalBackgroundUsesImage && preferences.terminalBackgroundImageId != null) {
            Row(Modifier.fillMaxWidth().padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("dim", modifier = Modifier.weight(1f), style = TesseraType.rowMeta, color = tokens.fgMuted)
                Text("${(preferences.terminalBackgroundDim * 100).toInt()}%", style = TesseraType.rowMeta, color = tokens.fgMuted)
            }
            TesseraSlider(
                value = preferences.terminalBackgroundDim,
                onValueChange = onDimChanged,
                valueRange = 0f..0.85f,
                stepSize = 0.05f,
                contentDescription = "Terminal background dim",
            )
            Row(Modifier.fillMaxWidth().padding(top = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("blur", modifier = Modifier.weight(1f), style = TesseraType.rowMeta, color = tokens.fgMuted)
                Text("$previewBlur pt", style = TesseraType.rowMeta, color = tokens.fgMuted)
            }
            TesseraSlider(
                value = previewBlur.toFloat(),
                onValueChange = { previewBlur = it.toInt().coerceIn(0, 24) },
                valueRange = 0f..24f,
                stepSize = 1f,
                contentDescription = "Terminal background blur",
                onValueChangeFinished = { finalValue ->
                    val committed = finalValue.toInt().coerceIn(0, 24)
                    previewBlur = committed
                    onBlurChanged(committed)
                    preferences.terminalBackgroundImageId?.let { imageId ->
                        scope.launch(Dispatchers.IO) {
                            store.pruneVariants(imageId, committed.toFloat())
                        }
                    }
                },
            )
            Text("fill", style = TesseraType.rowMeta, color = tokens.fgMuted, modifier = Modifier.padding(top = 5.dp, bottom = 4.dp))
            TesseraSegmented(
                options = listOf("fill", "fit"),
                selectedIndex = if (preferences.terminalBackgroundFillMode == "fit") 1 else 0,
                onSelect = { onFillModeChanged(if (it == 0) "fill" else "fit") },
            )
        }
    }
}

@Composable
private fun TerminalBackgroundPreview(
    imageId: String,
    themeId: String,
    dim: Float,
    previewBlur: Int,
    committedBlur: Int,
    fillMode: String,
    enabled: Boolean,
    store: TerminalBackgroundImageStore,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalTesseraTokens.current
    val theme = remember(themeId) { TerminalTheme.fromId(themeId) }
    val usePlatformPreviewBlur = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
    val storedBlur = if (usePlatformPreviewBlur) 0 else committedBlur
    val image = remember(imageId, dim, storedBlur, fillMode, enabled) {
        if (!enabled) null else TerminalBackgroundImage(
            imageId = imageId,
            dim = dim.coerceIn(0f, 0.85f),
            fillMode = TerminalBackgroundFillMode.fromPersisted(fillMode),
            blurRadiusDp = storedBlur.coerceIn(0, 24).toFloat(),
        )
    }
    val drawable by produceState<android.graphics.drawable.Drawable?>(
        initialValue = null,
        image,
        theme.backgroundArgb,
        store,
    ) {
        value = withContext(Dispatchers.IO) {
            image?.let { store.prewarm(listOf(it)) }
            store.drawable(theme.backgroundArgb, image)
        }
    }
    val shape = androidx.compose.foundation.shape.RoundedCornerShape(10.dp)
    Box(modifier.clip(shape).border(1.dp, tokens.border, shape)) {
        AndroidView(
            factory = { previewContext -> View(previewContext) },
            update = { view ->
                view.background = drawable
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val radius = previewBlur.coerceIn(0, 24) * view.resources.displayMetrics.density
                    view.setRenderEffect(
                        if (enabled && radius > 0f) {
                            android.graphics.RenderEffect.createBlurEffect(
                                radius,
                                radius,
                                android.graphics.Shader.TileMode.CLAMP,
                            )
                        } else null,
                    )
                }
            },
            modifier = Modifier.fillMaxSize(),
        )
        Column(Modifier.padding(14.dp)) {
            Text("user@host:~$ ls -la", style = TesseraType.code, color = Color(0xFFD4D4D4))
            Text("drwxr-xr-x  projects", style = TesseraType.code, color = Color(0xFF7DD3FC))
            Text("-rw-r--r--  README.md", style = TesseraType.code, color = Color(0xFFD4D4D4))
        }
    }
}

private fun InputStream.readBytesBounded(limit: Int): ByteArray {
    val output = ByteArrayOutputStream(minOf(limit, 64 * 1024))
    val buffer = ByteArray(16 * 1024)
    var total = 0
    while (true) {
        val count = read(buffer)
        if (count < 0) break
        total += count
        require(total <= limit) { "terminal background exceeds the import limit" }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}

private const val MAX_TERMINAL_BACKGROUND_IMPORT_BYTES = 32 * 1024 * 1024

/**
 * Mirrors the iPhone editor's practical phone behavior: the same persisted
 * order drives the live strip, a swipe scrolls the preview, a tap removes,
 * and a deliberate hold/reorder never steals the short horizontal pan.
 */
@Composable
internal fun SmoothScrollingSettings(
    enabled: Boolean,
    speed: Float,
    onEnabledChanged: (Boolean) -> Unit,
    onSpeedChanged: (Float) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalTesseraTokens.current
    Column(modifier) {
        TesseraToggleRow(
            title = "smooth scrolling",
            subtitle = "Glide after a touch scroll in local terminal scrollback.",
            checked = enabled,
            onCheckedChange = onEnabledChanged,
        )
        if (enabled) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("scroll speed", modifier = Modifier.weight(1f), style = TesseraType.rowTitle, color = tokens.fg)
                    Text(
                        if (speed < 0.5f) "slow" else if (speed > 0.9f) "fast" else "balanced",
                        style = TesseraType.rowMeta,
                        color = tokens.fgMuted,
                    )
                }
                TesseraSlider(
                    value = speed,
                    onValueChange = onSpeedChanged,
                    valueRange = 0.15f..1.25f,
                    stepSize = 0.05f,
                    contentDescription = "Smooth scrolling speed",
                )
            }
        }
    }
}

@Composable
internal fun AccessoryBarEditor(
    persistedKeys: List<String>?,
    onKeysChanged: (List<String>) -> Unit,
    modifier: Modifier = Modifier,
    notation: String = SharedInputEncoding.ChordNotation.Glyph.wireValue,
) {
    val tokens = LocalTesseraTokens.current
    val chordNotation = rememberChordNotation(notation)
    // One pass over the catalog per notation rather than a render per chip.
    val labels = remember(chordNotation) { AccessoryBarKey.labels(chordNotation) }
    // Same idiom rule the live row uses, so the editor previews the bar the
    // session will actually show.
    val barDefaults = LocalConfiguration.current.accessoryBarDefaults()
    val keys = remember(persistedKeys, barDefaults) { AccessoryBarKey.resolve(persistedKeys, barDefaults) }
    val dragScope = rememberCoroutineScope()
    val hapticView = LocalView.current
    val reorder = remember { AccessoryReorderState(dragScope) }

    // Every edit is applied to the row first and written second. The write
    // round-trips through DataStore, so reading it back is always at least a
    // frame behind the finger — long enough for the second move of a fast drag
    // to be computed from a list that still describes the first.
    fun commit(updated: List<AccessoryBarKey>) {
        reorder.setPending(updated)
        onKeysChanged(updated.persistedAccessoryBarIds())
    }
    val rowKeys = reorder.renderedOrder(keys)
    LaunchedEffect(keys, reorder.draggingId) { reorder.reconcile(keys) }
    val commitOrder by rememberUpdatedState<(List<AccessoryBarKey>) -> Unit> { commit(it) }
    LaunchedEffect(reorder) { reorder.onCommit = { order -> commitOrder(order) } }

    Column(modifier.fillMaxWidth()) {
        Text("accessory bar layout", style = TesseraType.rowTitle, color = tokens.fg)
        Text(
            "The software keyboard row only. Tap a preview key to remove it; hold, then drag to reorder. The keyboard button remains fixed at the end of the live row.",
            style = TesseraType.rowMeta,
            color = tokens.fgMuted,
            modifier = Modifier.padding(top = 3.dp, bottom = 10.dp),
        )
        Surface(
            color = tokens.panelBg,
            shape = androidx.compose.foundation.shape.RoundedCornerShape(10.dp),
            border = androidx.compose.foundation.BorderStroke(1.dp, tokens.border),
        ) {
            Column(Modifier.padding(vertical = 8.dp)) {
                Text(
                    "PREVIEW",
                    style = TesseraType.kicker,
                    color = tokens.fgDim,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 2.dp),
                )
                Box {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag("accessory-editor-preview")
                            .horizontalScroll(rememberScrollState())
                            .accessoryReorderGesture(
                                state = reorder,
                                order = { rowKeys },
                                onTap = { index ->
                                    rowKeys.getOrNull(index)?.let { tapped ->
                                        commit(rowKeys.filterNot { it == tapped })
                                    }
                                },
                                onLift = {
                                    hapticView.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                                },
                                onCross = {
                                    hapticView.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                                },
                            )
                            .onGloballyPositioned { reorder.reportRowOrigin(it.positionInRoot().x) }
                            .padding(horizontal = 8.dp, vertical = 5.dp),
                        horizontalArrangement = Arrangement.spacedBy(ACCESSORY_CHIP_SPACING),
                    ) {
                        rowKeys.forEachIndexed { index, barKey ->
                            key(barKey.persistedId) {
                                AccessoryEditorChip(
                                    key = barKey,
                                    label = labels[barKey] ?: barKey.persistedId,
                                    selected = false,
                                    lifted = reorder.draggingId == barKey.persistedId,
                                    slotIndex = index,
                                    reorder = reorder,
                                    testTag = "accessory-editor-preview-key-${barKey.persistedId}",
                                    clickable = false,
                                    onClick = {},
                                )
                            }
                        }
                    }
                    Box(
                        Modifier
                            .align(Alignment.CenterEnd)
                            .width(26.dp)
                            .fillMaxHeight()
                            .background(
                                Brush.horizontalGradient(
                                    listOf(Color.Transparent, tokens.panelBg),
                                ),
                            ),
                    )
                }
            }
        }
        Text(
            "ADD KEYS",
            style = TesseraType.kicker,
            color = tokens.fgDim,
            modifier = Modifier.padding(top = 13.dp, bottom = 5.dp),
        )
        AccessoryEditorPaletteRow("navigation", AccessoryBarKey.navigation, rowKeys, labels, ::commit)
        AccessoryEditorPaletteRow("modifiers", AccessoryBarKey.modifiers, rowKeys, labels, ::commit)
        AccessoryEditorPaletteRow("control shortcuts", AccessoryBarKey.controlShortcuts, rowKeys, labels, ::commit)
        AccessoryEditorPaletteRow("function keys", AccessoryBarKey.functionKeys, rowKeys, labels, ::commit)
        AccessoryEditorPaletteRow("symbols", AccessoryBarKey.symbols, rowKeys, labels, ::commit)
        Row(Modifier.padding(top = 12.dp)) {
            TesseraButton(
                text = "restore defaults",
                onClick = { commit(AccessoryBarKey.defaultOrder(barDefaults)) },
                compact = true,
            )
        }
    }
}

/**
 * Sticky modifiers and chord notation, sitting under the bar editor because
 * both change how that exact row behaves and reads.
 *
 * Swift authority: `TesseraInputCore.ModifierArming` for the behavior rule and
 * `TesseraInputCore.KeyChordNotation` for the spelling. The two segmented
 * controls match the idiom already used for cursor style and restore policy;
 * the sample underneath is rendered by the shared renderer so it cannot
 * disagree with the bar it describes.
 */
@Composable
private fun ModifierBehaviorSettings(
    behavior: String,
    notation: String,
    onBehaviorChanged: (String) -> Unit,
    onNotationChanged: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalTesseraTokens.current
    val chordNotation = rememberChordNotation(notation)
    Column(modifier.fillMaxWidth()) {
        Text("modifier keys", style = TesseraType.rowTitle, color = tokens.fg)
        Text(
            "One-shot applies an armed control, option, or shift chip to the " +
                "next key only. Sticky keeps it armed until you tap it off.",
            style = TesseraType.rowMeta,
            color = tokens.fgMuted,
            modifier = Modifier.padding(top = 3.dp, bottom = 8.dp),
        )
        val behaviors = SharedModifierBehavior.entries
        TesseraSegmented(
            options = listOf("one-shot", "sticky"),
            selectedIndex = behaviors.indexOfFirst { it.wireValue == behavior }.coerceAtLeast(0),
            onSelect = { index -> onBehaviorChanged(behaviors[index].wireValue) },
        )

        Text(
            "chord labels",
            style = TesseraType.rowTitle,
            color = tokens.fg,
            modifier = Modifier.padding(top = 16.dp),
        )
        Text(
            "How a modifier chord is written on the bar and in shortcut lists. " +
                "Labels only — it never changes what a key sends.",
            style = TesseraType.rowMeta,
            color = tokens.fgMuted,
            modifier = Modifier.padding(top = 3.dp, bottom = 8.dp),
        )
        val notations = SharedInputEncoding.ChordNotation.entries
        TesseraSegmented(
            options = listOf("glyphs", "words"),
            selectedIndex = notations.indexOfFirst { it.wireValue == notation }.coerceAtLeast(0),
            onSelect = { index -> onNotationChanged(notations[index].wireValue) },
        )
        Text(
            remember(chordNotation) {
                listOf(AccessoryBarKey.Control, AccessoryBarKey.ControlC, AccessoryBarKey.Tab)
                    .joinToString("   ") { it.label(chordNotation) }
            },
            style = TesseraType.rowMeta,
            color = tokens.fgMuted,
            modifier = Modifier.padding(top = 8.dp),
        )
    }
}

@Composable
private fun rememberChordNotation(wireValue: String): SharedInputEncoding.ChordNotation =
    remember(wireValue) {
        SharedInputEncoding.ChordNotation.entries.firstOrNull { it.wireValue == wireValue }
            ?: SharedInputEncoding.ChordNotation.Glyph
    }

/**
 * Where the accessory preview row's reorder drag currently is.
 *
 * The iPhone bar's `DraggableChipBar` is the reference behaviour: a hold lifts
 * the chip under the finger, the lifted chip tracks the finger, every chip it
 * crosses slides out of the way, and the release settles with a spring.
 * Android had the reordering but none of the motion — it committed a new order
 * every 56 *pixels* of travel (a dp figure spent as a pixel count, so the
 * threshold drifted with screen density) and the row then teleported into the
 * new order, which is why a drag read as a glitch rather than as a move.
 *
 * Chips are tracked by persisted id, not by index, and the lifted chip is
 * anchored to the finger rather than to accumulated movement. Both were
 * learned the hard way from a `LazyRow` version of this: a lazy list re-anchors
 * its scroll on whichever key was first visible, so dragging the *first* chip
 * away scrolled the row, which moved every index and offset the drag had
 * measured against, which triggered another swap — one two-chip drag ran
 * through half the row. A plain scrolling Row keeps a pixel scroll offset that
 * a reorder cannot disturb, and ids and finger positions cannot drift.
 */
private class AccessoryReorderState(private val scope: CoroutineScope) {
    /** Set by the editor; the drag pushes each new order through it. */
    var onCommit: (List<AccessoryBarKey>) -> Unit = {}

    var draggingId by mutableStateOf<String?>(null)
        private set

    /** The chip whose release spring is still running, if any. */
    var settlingId by mutableStateOf<String?>(null)
        private set

    /**
     * The order the row is drawing, which is not yet the order the preference
     * store has.
     *
     * Committing goes out through DataStore and comes back as a new
     * composition, so reading it back mid-drag reads a list at least one move
     * behind the finger, and every later move would be computed from a base
     * that no longer describes the row. [reconcile] drops it again the moment
     * persistence catches up.
     */
    var pendingOrder by mutableStateOf<List<AccessoryBarKey>?>(null)
        private set

    /**
     * Chip lefts are measured in root coordinates and the row reports its own
     * origin in the same space, so the two are subtracted into the pointer's
     * space rather than assumed to share it. Padding and scroll both sit
     * between the gesture modifier and the chips, and either would otherwise
     * put the hit test a constant distance out.
     */
    private val lefts = mutableStateMapOf<String, Float>()
    private var rowOrigin by mutableFloatStateOf(0f)
    private var chipWidth by mutableFloatStateOf(0f)
    private var pointerX by mutableFloatStateOf(0f)
    /** How far into the chip the finger grabbed, so the lift does not jump. */
    private var grabInset by mutableFloatStateOf(0f)
    private val settleOffset = Animatable(0f)

    val isDragging: Boolean get() = draggingId != null

    fun reportRowOrigin(x: Float) {
        rowOrigin = x
    }

    fun reportBounds(id: String, rootLeft: Float, width: Int) {
        lefts[id] = rootLeft
        chipWidth = width.toFloat()
    }

    /**
     * Drops a chip that has left the row. A removed chip stops reporting but
     * its last bounds would otherwise stay in the map and answer a hit test
     * for a key that is no longer on the bar.
     */
    fun forgetBounds(id: String) {
        lefts.remove(id)
    }

    private fun idAt(x: Float): String? {
        val rootX = x + rowOrigin
        return lefts.entries
            .firstOrNull { (_, left) -> rootX >= left && rootX <= left + chipWidth }
            ?.key
    }

    /** Where the lifted chip's left edge belongs right now. */
    private val liftedLeftEdge: Float get() = pointerX - grabInset

    /** Pixels to translate the chip with [id] by, right now. */
    fun offsetFor(id: String): Float = when (id) {
        draggingId -> liftedLeftEdge + rowOrigin - (lefts[id] ?: return 0f)
        settlingId -> settleOffset.value
        else -> 0f
    }

    fun indexAt(x: Float, order: List<AccessoryBarKey>): Int? {
        val id = idAt(x) ?: return null
        val index = order.indexOfFirst { it.persistedId == id }
        return index.takeIf { it >= 0 }
    }

    /** @return false when the press did not land on a chip. */
    fun onDragStart(position: Offset, persisted: List<AccessoryBarKey>): Boolean {
        val id = idAt(position.x) ?: return false
        val left = lefts[id] ?: return false
        draggingId = id
        pointerX = position.x
        grabInset = (position.x + rowOrigin) - left
        pendingOrder = pendingOrder ?: persisted
        return true
    }

    /** @return true when this movement crossed a chip and committed a new order. */
    fun onDrag(position: Offset): Boolean {
        val id = draggingId ?: return false
        pointerX = position.x
        // The lifted chip's centre, the way `DraggableChipBar` decides it: a
        // chip moves aside when the chip in flight covers its middle.
        val targetId = idAt(liftedLeftEdge + chipWidth / 2f) ?: return false
        if (targetId == id) return false
        val order = (pendingOrder ?: return false).toMutableList()
        val from = order.indexOfFirst { it.persistedId == id }
        val to = order.indexOfFirst { it.persistedId == targetId }
        if (from < 0 || to < 0) return false
        order.add(to, order.removeAt(from))
        pendingOrder = order
        onCommit(order)
        return true
    }

    fun onDragEnd() {
        val id = draggingId ?: return
        val residual = offsetFor(id)
        draggingId = null
        grabInset = 0f
        settlingId = id
        scope.launch {
            settleOffset.snapTo(residual)
            settleOffset.animateTo(
                targetValue = 0f,
                animationSpec = spring(
                    dampingRatio = Spring.DampingRatioLowBouncy,
                    stiffness = Spring.StiffnessMediumLow,
                ),
            )
            settlingId = null
        }
    }

    /** The order to draw: the live drag's, or the stored one when idle. */
    fun renderedOrder(persisted: List<AccessoryBarKey>): List<AccessoryBarKey> =
        pendingOrder ?: persisted

    /** Records an edit the store has not acknowledged yet. */
    fun setPending(order: List<AccessoryBarKey>) {
        pendingOrder = order
    }

    /** Drops the optimistic order once the store agrees with it. */
    fun reconcile(persisted: List<AccessoryBarKey>) {
        if (draggingId == null && pendingOrder == persisted) pendingOrder = null
    }
}

/**
 * Leaves the initial contact unconsumed so the enclosing horizontal scroll
 * wins ordinary swipes. A stationary long press claims subsequent movement
 * for reorder instead.
 *
 * Both halves live on the row rather than on each chip: chip bounds are
 * reported in the row's own coordinate space, and a tap has to be resolved
 * against the same space the drag is.
 */
private fun Modifier.accessoryReorderGesture(
    state: AccessoryReorderState,
    order: () -> List<AccessoryBarKey>,
    onTap: (Int) -> Unit,
    onLift: () -> Unit,
    onCross: () -> Unit,
): Modifier = pointerInput(state) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        val cancelledBeforeLongPress = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
            while (true) {
                val change = awaitPointerEvent(PointerEventPass.Final).changes
                    .firstOrNull { it.id == down.id }
                    ?: return@withTimeoutOrNull true
                if (!change.pressed) {
                    if (!change.isConsumed) {
                        state.indexAt(change.position.x, order())?.let(onTap)
                    }
                    return@withTimeoutOrNull true
                }
                if (change.isConsumed) return@withTimeoutOrNull true
            }
        }
        if (cancelledBeforeLongPress != null) return@awaitEachGesture
        if (!state.onDragStart(down.position, order())) return@awaitEachGesture
        onLift()

        // Initial, not Main: this modifier sits outside the row's own scroll,
        // and Main runs child-first, so on Main the scroll would see (and
        // claim) each movement before the reorder could consume it — the row
        // would slide out from under the finger mid-drag. Initial runs
        // parent-first, so the scroll never sees the gesture at all.
        while (true) {
            val change = awaitPointerEvent(PointerEventPass.Initial).changes
                .firstOrNull { it.id == down.id }
                ?: break
            if (!change.pressed) break
            val moved = change.positionChange().x != 0f
            change.consume()
            if (moved && state.onDrag(change.position)) onCross()
        }
        state.onDragEnd()
    }
}

@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun AccessoryEditorPaletteRow(
    title: String,
    options: List<AccessoryBarKey>,
    current: List<AccessoryBarKey>,
    labels: Map<AccessoryBarKey, String>,
    onKeysChanged: (List<AccessoryBarKey>) -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    Column(Modifier.padding(top = 6.dp)) {
        Text(title, style = TesseraType.rowMeta, color = tokens.fgMuted)
        FlowRow(
            Modifier.fillMaxWidth().padding(top = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            options.forEach { key ->
                AccessoryEditorChip(
                    key = key,
                    label = labels[key] ?: key.persistedId,
                    selected = key in current,
                    enabled = key !in current,
                    testTag = "accessory-editor-palette-key-${key.persistedId}",
                    onClick = { if (key !in current) onKeysChanged(current + key) },
                )
            }
        }
    }
}

/**
 * One editor chip. Fixed width, so a slot's pitch is a constant both the row
 * and the reorder animation can compute — `esc` and `←` present the same
 * target, and a chip that changes index always travels a whole number of these.
 */
private val ACCESSORY_CHIP_WIDTH = 52.dp
private val ACCESSORY_CHIP_SPACING = 6.dp

@Composable
private fun AccessoryEditorChip(
    key: AccessoryBarKey,
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    clickable: Boolean = true,
    lifted: Boolean = false,
    /** Position in the preview row; null in the palette, which never reorders. */
    slotIndex: Int? = null,
    reorder: AccessoryReorderState? = null,
    testTag: String = "accessory-editor-${key.persistedId}",
) {
    val tokens = LocalTesseraTokens.current
    val shape = androidx.compose.foundation.shape.RoundedCornerShape(7.dp)
    val slotPitch = with(LocalDensity.current) { (ACCESSORY_CHIP_WIDTH + ACCESSORY_CHIP_SPACING).toPx() }
    // A displaced chip is drawn at the slot it just left and animated into the
    // one it now occupies. That is the whole "slide aside" effect: the row's
    // own layout has already teleported it, and this puts the motion back.
    val slide = remember(key.persistedId) { Animatable(0f) }
    var lastSlot by remember(key.persistedId) { mutableIntStateOf(slotIndex ?: 0) }
    if (reorder != null) {
        DisposableEffect(key.persistedId) {
            onDispose { reorder.forgetBounds(key.persistedId) }
        }
    }
    LaunchedEffect(slotIndex) {
        val moved = slotIndex ?: return@LaunchedEffect
        val travelled = (lastSlot - moved) * slotPitch
        lastSlot = moved
        if (travelled == 0f) return@LaunchedEffect
        if (lifted) {
            // The chip in flight changes slot constantly and is placed by the
            // finger. Letting it also carry a slide would leave a residue for
            // the release spring to fight over.
            slide.snapTo(0f)
            return@LaunchedEffect
        }
        slide.snapTo(travelled)
        slide.animateTo(
            targetValue = 0f,
            animationSpec = spring(
                dampingRatio = Spring.DampingRatioLowBouncy,
                stiffness = Spring.StiffnessMediumLow,
            ),
        )
    }
    // The same lift the iPhone bar draws (`ChipLabel`, style `.lifted`):
    // accent label on a 20% accent fill, accent border, 1.06 scale and a soft
    // shadow. Animated rather than switched, so the chip is seen to leave the
    // row instead of appearing to be replaced by a different chip.
    val scale by animateFloatAsState(
        targetValue = if (lifted) 1.06f else 1f,
        label = "accessory-chip-lift-scale",
    )
    val elevation by animateDpAsState(
        targetValue = if (lifted) 8.dp else 0.dp,
        label = "accessory-chip-lift-elevation",
    )
    val fill by animateColorAsState(
        targetValue = if (lifted) tokens.accent.copy(alpha = 0.20f) else tokens.inputBg,
        label = "accessory-chip-lift-fill",
    )
    val stroke by animateColorAsState(
        targetValue = if (lifted) tokens.accent else tokens.border,
        label = "accessory-chip-lift-stroke",
    )
    val ink by animateColorAsState(
        targetValue = when {
            lifted -> tokens.accent
            selected -> tokens.fgDim
            else -> tokens.fg
        },
        label = "accessory-chip-lift-ink",
    )
    Box(
        modifier = modifier
            .testTag(testTag)
            .then(
                if (reorder == null) {
                    Modifier
                } else {
                    Modifier
                        .zIndex(if (lifted || reorder.settlingId == key.persistedId) 1f else 0f)
                        .onGloballyPositioned { coordinates ->
                            reorder.reportBounds(
                                key.persistedId,
                                coordinates.positionInRoot().x,
                                coordinates.size.width,
                            )
                        }
                }
            )
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                // The chip in flight is placed by the finger and must not also
                // be slide-animated — the two would fight and it would trail.
                translationX = if (lifted) {
                    reorder?.offsetFor(key.persistedId) ?: 0f
                } else {
                    slide.value + (reorder?.offsetFor(key.persistedId) ?: 0f)
                }
            }
            .width(ACCESSORY_CHIP_WIDTH)
            .heightIn(min = 38.dp)
            .shadow(elevation, shape)
            .clip(shape)
            .background(fill)
            .border(1.dp, stroke, shape)
            .then(if (clickable) Modifier.clickable(enabled = enabled, onClick = onClick) else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = TesseraType.button,
            color = ink,
            maxLines = 1,
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DiagnosticsScreen(
    store: DiagnosticLogStore,
    onUploadLog: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val tokens = LocalTesseraTokens.current
    val scope = rememberCoroutineScope()
    // The report leaves the phone; it is never drawn on it. A rotated log is a
    // megabyte of text, and laying that out as one composable held the main
    // thread for seconds every time this page opened - to show a wall nobody
    // reads on a phone. iOS shows the same page as a size, a timestamp and the
    // actions that move the file.
    var info by remember(store) { mutableStateOf(DiagnosticLogStore.Info.EMPTY) }
    var staging by remember(store) { mutableStateOf(false) }

    suspend fun refresh() {
        info = withContext(Dispatchers.IO) { store.info() }
    }

    LaunchedEffect(store) { refresh() }

    /** Stages the report and hands it to [send]; null means nothing was recorded. */
    fun withStagedLog(send: (Uri) -> Unit) {
        if (staging) return
        staging = true
        scope.launch {
            val uri = withContext(Dispatchers.IO) { stageDiagnosticLog(context, store) }
            staging = false
            if (uri != null) send(uri)
            refresh()
        }
    }

    Column(modifier.background(tokens.bg)) {
        TesseraSubPageHeader(
            title = "diagnostics",
            onBack = onBack,
            backContentDescription = "back to settings",
        )
        TesseraHairline()
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp, vertical = 12.dp),
        ) {
            Text("debug log", style = TesseraType.rowTitle, color = tokens.fg)
            Text(
                if (info.isEmpty) {
                    "nothing recorded yet"
                } else {
                    "${android.text.format.Formatter.formatShortFileSize(context, info.byteCount)}" +
                        " · updated ${info.modifiedAt?.let(diagnosticsTimestampFormat::format) ?: "unknown"}"
                },
                style = TesseraType.rowMeta,
                color = tokens.fgMuted,
                modifier = Modifier.padding(top = 3.dp, bottom = 14.dp),
            )
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                TesseraButton(
                    text = "export log",
                    compact = true,
                    enabled = !info.isEmpty && !staging,
                    onClick = {
                        withStagedLog { uri ->
                            context.startActivity(
                                Intent.createChooser(
                                    shareDiagnosticLogIntent(uri, recipient = null),
                                    "Export Tessera diagnostics",
                                ),
                            )
                        }
                    },
                )
                TesseraButton(
                    text = "upload log",
                    compact = true,
                    enabled = !info.isEmpty && !staging,
                    onClick = onUploadLog,
                )
                TesseraButton(
                    text = "send to developer",
                    compact = true,
                    enabled = !info.isEmpty && !staging,
                    onClick = {
                        withStagedLog { uri ->
                            context.startActivity(
                                Intent.createChooser(
                                    shareDiagnosticLogIntent(uri, recipient = DEVELOPER_EMAIL_ADDRESS),
                                    "Send Tessera diagnostics",
                                ),
                            )
                        }
                    },
                )
                TesseraButton(
                    text = "refresh",
                    compact = true,
                    enabled = !staging,
                    onClick = { scope.launch { refresh() } },
                )
                TesseraButton(
                    text = "clear",
                    compact = true,
                    style = TesseraButtonStyle.Danger,
                    enabled = !info.isEmpty && !staging,
                    onClick = {
                        scope.launch {
                            withContext(Dispatchers.IO) { store.clear() }
                            refresh()
                        }
                    },
                )
            }
            Text(
                "Connection, trust, transfer, render and input events are recorded here with " +
                    "secrets redacted. Export or upload the file to read it off the phone.",
                style = TesseraType.rowMeta,
                color = tokens.fgMuted,
                modifier = Modifier.padding(top = 16.dp),
            )
        }
    }
}

/** Where diagnostics reports go, the same address the iOS composer uses. */
private const val DEVELOPER_EMAIL_ADDRESS = "dev@bambouville.com"

private val diagnosticsTimestampFormat: java.time.format.DateTimeFormatter =
    java.time.format.DateTimeFormatter
        .ofLocalizedDateTime(java.time.format.FormatStyle.SHORT)
        .withZone(java.time.ZoneId.systemDefault())

/**
 * Copies the retained report into the shared cache and returns the content URI
 * for it, or null when nothing has been recorded. Callers run this off the main
 * thread: the report can be twice [DiagnosticLogStore.MAX_BYTES].
 */
private fun stageDiagnosticLog(context: Context, store: DiagnosticLogStore): Uri? {
    val directory = File(context.cacheDir, "exports").apply { mkdirs() }
    val file = File(directory, DiagnosticLogStore.FILE_NAME)
    if (!store.copyTo(file)) {
        file.delete()
        return null
    }
    return FileProvider.getUriForFile(context, "${context.packageName}.files", file)
}

/**
 * The share payload. With a recipient it is pre-addressed to the developer with
 * the build and device already filled in - the same envelope the iOS mail
 * composer sends - because a report without them is a report we cannot place.
 */
private fun shareDiagnosticLogIntent(uri: Uri, recipient: String?): Intent =
    Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_STREAM, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        if (recipient == null) return@apply
        putExtra(Intent.EXTRA_EMAIL, arrayOf(recipient))
        putExtra(Intent.EXTRA_SUBJECT, "Tessera diagnostics v${BuildConfig.VERSION_NAME}")
        putExtra(
            Intent.EXTRA_TEXT,
            """
            Describe what happened above this line.

            --
            Tessera v${BuildConfig.VERSION_NAME}
            ${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE} (sdk ${Build.VERSION.SDK_INT})
            ${DiagnosticLogStore.FILE_NAME} attached
            """.trimIndent(),
        )
    }
