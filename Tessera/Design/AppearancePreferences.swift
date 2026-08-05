// Tessera/Design/AppearancePreferences.swift
import SwiftUI

enum AppearanceModeOption: String {
    case system, dark, light
}

/// Terminal cursor shape preference. Mapped to SwiftTerm.CursorStyle at the
/// surface that wires it to the live terminal — kept as a Tessera-local enum
/// here so AppearancePreferences doesn't need to import SwiftTerm.
enum CursorStyleOption: String, CaseIterable {
    case block, bar, underline
}

enum AppLockSettingsPolicy {
    static func isBackgroundLockEnabled(
        requiresOwnerAuthentication: Bool,
        locksWhenBackgrounded: Bool
    ) -> Bool {
        requiresOwnerAuthentication && locksWhenBackgrounded
    }

    static func applyingBackgroundLockSelection(
        _ isEnabled: Bool,
        requiresOwnerAuthentication: Bool
    ) -> (requiresOwnerAuthentication: Bool, locksWhenBackgrounded: Bool) {
        (
            requiresOwnerAuthentication: isEnabled || requiresOwnerAuthentication,
            locksWhenBackgrounded: isEnabled
        )
    }
}

@Observable
final class AppearancePreferences {
    /// Baseline used by SessionTopBar to derive a scale factor from the
    /// user's chosen `topBarHeight`. When the user picks 32 the strip
    /// renders exactly the v2 design literals; smaller/larger values
    /// scale icons, pills, and fonts proportionally.
    static let defaultTopBarHeight: Double = 32
    static let topBarHeightRange: ClosedRange<Double> = 26...44


    // MARK: - Existing chrome / appearance
    var mode: AppearanceModeOption = .system {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "tessera.pref.mode") }
    }
    var accent: AccentName = .blue {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: "tessera.pref.accent") }
    }
    /// 24-bit RGB used when `accent == .custom`. Exposed to a SwiftUI ColorPicker
    /// in AppearanceSettingsView. Default mirrors the prior `.pink` accent.
    var customAccentRGB: Int = AccentName.defaultCustomRGB {
        didSet { UserDefaults.standard.set(customAccentRGB, forKey: "tessera.pref.customAccentRGB") }
    }
    var monoFontName: String = "JetBrainsMono-Regular" {
        didSet { UserDefaults.standard.set(monoFontName, forKey: "tessera.pref.monoFontName") }
    }
    var fontSize: Double = 13 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "tessera.pref.fontSize") }
    }
    /// Height of the in-session top chrome bar in points. Drives both the
    /// absolute strip height and a proportional scale factor applied to icon
    /// sizes, pill heights, fonts, and the `+` button inside SessionTopBar.
    /// Default 32 matches the v2 redesign baseline; range 26-44 lets users
    /// pick "narrow" (closer to v1's 28pt) or "comfortable" (legible at
    /// arm's length).
    var topBarHeight: Double = AppearancePreferences.defaultTopBarHeight {
        didSet { UserDefaults.standard.set(topBarHeight, forKey: "tessera.pref.topBarHeight") }
    }
    /// Material of the floating chrome (sidebar, top bar, accessory bar).
    /// Defaults to the highest fidelity the running OS supports (Liquid Glass on
    /// iPadOS 26+, else Frosted) and only persists once the user picks explicitly,
    /// so an un-set preference tracks the OS across upgrades. See `ChromeMaterial`.
    var chromeMaterial: ChromeMaterial = ChromeMaterial.highestSupported {
        didSet { UserDefaults.standard.set(chromeMaterial.rawValue, forKey: "tessera.pref.chromeMaterial") }
    }

    // MARK: - Terminal (M4 §settings.terminal)
    /// Cursor shape. Wired to SwiftTerm.options.cursorStyle in W2 — UI persists in W1.
    var cursorStyle: CursorStyleOption = .block {
        didSet { UserDefaults.standard.set(cursorStyle.rawValue, forKey: "tessera.pref.cursorStyle") }
    }
    /// Blink the terminal cursor. Wired to SwiftTerm in W2.
    var cursorBlink: Bool = true {
        didSet { UserDefaults.standard.set(cursorBlink, forKey: "tessera.pref.cursorBlink") }
    }
    /// Number of off-screen lines kept in the scrollback buffer. Default 10000
    /// matches §R4.5 and the existing `view.changeScrollback(10_000)` call.
    /// Range 1000–50000.
    var scrollbackLines: Int = 10_000 {
        didSet { UserDefaults.standard.set(scrollbackLines, forKey: "tessera.pref.scrollbackLines") }
    }
    /// Web-style momentum glide after trackpad scroll gestures in local
    /// scrollback (primary screen only — alt-screen TUIs keep discrete
    /// wheel/arrow semantics; discrete mouse-wheel notches never glide).
    /// Default on.
    var smoothScrollingEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(
                smoothScrollingEnabled,
                forKey: "tessera.pref.smoothScrollingEnabled"
            )
        }
    }
    /// Glide strength: multiplies the release velocity before the decay
    /// starts, which scales glide speed and travel distance linearly
    /// (distance ≈ v/2 under the UIKit-normal curve). 1.0 = raw tracked
    /// velocity, which testing found too aggressive on iPad — default is
    /// half that. Surfaced as an unlabeled slow↔fast slider.
    static let smoothScrollingSpeedRange: ClosedRange<Double> = 0.15...1.25
    var smoothScrollingSpeed: Double = 0.5 {
        didSet {
            UserDefaults.standard.set(
                smoothScrollingSpeed,
                forKey: "tessera.pref.smoothScrollingSpeed"
            )
        }
    }
    var sessionRestorePolicy: SessionRestorePolicy = .ask {
        didSet {
            UserDefaults.standard.set(sessionRestorePolicy.rawValue, forKey: "tessera.pref.sessionRestorePolicy")
            if sessionRestorePolicy == .never {
                SessionRestoreStore.clearDefaultStore()
            }
        }
    }

    // MARK: - Continuity
    /// Publishes only the focused connected session as a secret-free Handoff
    /// activity. This is device-local: disabling broadcast here does not alter
    /// the peer's preference and never changes session restore behavior.
    var handoffSessionsEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(
                handoffSessionsEnabled,
                forKey: "tessera.pref.handoffSessionsEnabled"
            )
        }
    }

    // MARK: - Themes (M4 §settings.themes)
    /// One of the named TerminalTheme IDs (void, graphite, amber, paper, dracula, nord).
    /// Wired to SwiftTerm.installColors at session boot in W2.
    var terminalThemeID: String = "void" {
        didSet { UserDefaults.standard.set(terminalThemeID, forKey: "tessera.pref.terminalThemeID") }
    }

    // MARK: - Terminal background picture (settings.themes → background)
    /// Whether the global background is the picture (true) or the theme's
    /// solid color (false). Kept separate from `terminalBackgroundImageID`
    /// so toggling back to "theme color" doesn't destroy the imported file —
    /// the user can flip back without re-picking.
    var terminalBackgroundUsesImage: Bool = false {
        didSet {
            UserDefaults.standard.set(
                terminalBackgroundUsesImage,
                forKey: "tessera.pref.terminalBackgroundUsesImage"
            )
        }
    }
    /// Filename inside TerminalBackgroundImageStore.directory; nil = never
    /// imported (or removed). See Terminal/TerminalBackground.swift.
    var terminalBackgroundImageID: String? = nil {
        didSet {
            if let id = terminalBackgroundImageID {
                UserDefaults.standard.set(id, forKey: "tessera.pref.terminalBackgroundImageID")
            } else {
                UserDefaults.standard.removeObject(forKey: "tessera.pref.terminalBackgroundImageID")
            }
        }
    }
    /// Opacity of the theme-bg-colored scrim over the picture (0…0.85).
    var terminalBackgroundDim: Double = 0.5 {
        didSet {
            UserDefaults.standard.set(
                terminalBackgroundDim,
                forKey: "tessera.pref.terminalBackgroundDim"
            )
        }
    }
    /// TerminalBackgroundFillMode raw value ("fill" | "fit").
    var terminalBackgroundFillMode: String = "fill" {
        didSet {
            UserDefaults.standard.set(
                terminalBackgroundFillMode,
                forKey: "tessera.pref.terminalBackgroundFillMode"
            )
        }
    }
    /// Gaussian blur radius in points applied to the picture (0 = off).
    /// Pre-rendered into a variant file by TerminalBackgroundImageStore —
    /// never blurred live in the terminal render path.
    static let terminalBackgroundBlurRange: ClosedRange<Double> = 0...24
    var terminalBackgroundBlur: Double = 0 {
        didSet {
            UserDefaults.standard.set(
                terminalBackgroundBlur,
                forKey: "tessera.pref.terminalBackgroundBlur"
            )
        }
    }

    // MARK: - Keyboard & Input (M4 §settings.keyboard + §14.8 customization)
    /// Translate macOS-style text-editing chords (Option/Command arrows and
    /// delete variants) into the readline/meta bytes expected by shells and
    /// terminal apps. Default-on preserves the existing Option-arrow behavior.
    var naturalTextEditingEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(
                naturalTextEditingEnabled,
                forKey: "tessera.pref.naturalTextEditingEnabled"
            )
        }
    }

    /// Force-show or force-hide the on-screen accessory bar. When true, the bar
    /// still auto-hides via the GCKeyboard.coalesced rule. When false, the bar
    /// is hidden in all input modes.
    var showAccessoryBar: Bool = true {
        didSet { UserDefaults.standard.set(showAccessoryBar, forKey: "tessera.pref.showAccessoryBar") }
    }

    /// Ordered chip IDs (raw `AccessoryChip` rawValues) that compose the user's
    /// custom accessory bar. Persisted as `[String]` rather than `[AccessoryChip]`
    /// so unknown legacy IDs round-trip silently after schema rolls instead of
    /// failing to decode the whole array. Initial value matches
    /// `AccessoryChip.defaultBarOrder`; the source of truth for that list is in
    /// the Keyboard module.
    var accessoryBarKeys: [String] = AccessoryChip.defaultBarOrder.map(\.rawValue) {
        didSet { UserDefaults.standard.set(accessoryBarKeys, forKey: "tessera.pref.accessoryBarKeys") }
    }

    /// Sticky vs one-shot behavior for armed modifier chips on the accessory
    /// bar. Stored as a string so future variants (e.g. "doubleTapToSticky")
    /// don't break decoding. Valid values: "oneShot", "sticky".
    var modifierBehavior: String = "oneShot" {
        didSet { UserDefaults.standard.set(modifierBehavior, forKey: "tessera.pref.modifierBehavior") }
    }

    // MARK: - Files
    var filesReaperDays: Int = RemoteFilesConstants.defaultReaperDays {
        didSet { UserDefaults.standard.set(filesReaperDays, forKey: RemoteFilesConstants.reaperDaysKey) }
    }
    var filesDefaultDestination: String = "temp" {
        didSet { UserDefaults.standard.set(filesDefaultDestination, forKey: RemoteFilesConstants.defaultDestinationKey) }
    }

    // MARK: - Security (M4 §settings.security)
    var requireFaceIDToUnlock: Bool = false {
        didSet { UserDefaults.standard.set(requireFaceIDToUnlock, forKey: "tessera.pref.requireFaceIDToUnlock") }
    }
    /// 0 = never; otherwise minutes (1, 5, 15, 60).
    var autoLockMinutes: Int = 5 {
        didSet { UserDefaults.standard.set(autoLockMinutes, forKey: "tessera.pref.autoLockMinutes") }
    }
    var lockWhenBackgrounded: Bool = true {
        didSet { UserDefaults.standard.set(lockWhenBackgrounded, forKey: "tessera.pref.lockWhenBackgrounded") }
    }

    var effectiveLockWhenBackgrounded: Bool {
        AppLockSettingsPolicy.isBackgroundLockEnabled(
            requiresOwnerAuthentication: requireFaceIDToUnlock,
            locksWhenBackgrounded: lockWhenBackgrounded
        )
    }

    func setBackgroundLockEnabled(_ isEnabled: Bool) {
        let selection = AppLockSettingsPolicy.applyingBackgroundLockSelection(
            isEnabled,
            requiresOwnerAuthentication: requireFaceIDToUnlock
        )

        // Persist the child policy first so RootView's observation of a newly
        // enabled app-lock requirement always sees the complete configuration.
        lockWhenBackgrounded = selection.locksWhenBackgrounded
        requireFaceIDToUnlock = selection.requiresOwnerAuthentication
    }
    /// App-level authorization for a short connection burst. Software-key ACLs
    /// can additionally enforce this in Keychain; device-unlocked Secure
    /// Enclave keys use this mutable Tessera gate while remaining hardware-bound.
    var requireBiometricForKeyUse: Bool = false {
        didSet { UserDefaults.standard.set(requireBiometricForKeyUse, forKey: "tessera.pref.requireBiometricForKeyUse") }
    }
    var bellSoundEnabled: Bool = false {
        didSet { UserDefaults.standard.set(bellSoundEnabled, forKey: "tessera.pref.bellSoundEnabled") }
    }
    var bellVisualEnabled: Bool = true {
        didSet { UserDefaults.standard.set(bellVisualEnabled, forKey: "tessera.pref.bellVisualEnabled") }
    }
    var bellNotificationEnabled: Bool = true {
        didSet { UserDefaults.standard.set(bellNotificationEnabled, forKey: "tessera.pref.bellNotificationEnabled") }
    }

    // MARK: - Experimental
    /// Precise provider lifecycle notifications. Kept independent from the
    /// terminal BEL channel because an arbitrary shell bell is not evidence
    /// that an agent finished or needs input.
    var agentCenterNotificationsEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(
                agentCenterNotificationsEnabled,
                forKey: "tessera.pref.agentCenterNotificationsEnabled"
            )
            DiagnosticLogStore.appendAgentCenter(
                "notification-settings preciseAgent=\(agentCenterNotificationsEnabled) agentCenter=\(agentCenterEnabled) bell=\(bellNotificationEnabled)"
            )
            if agentCenterNotificationsEnabled {
                coordinateAgentCenterAndBellNotificationsIfNeeded()
            }
        }
    }

    /// Master gate for Agent Center discovery, lifecycle processing, UI, and
    /// shortcuts. Off by default while the feature is still baking.
    var agentCenterEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(
                agentCenterEnabled,
                forKey: "tessera.pref.agentCenterEnabled"
            )
            if agentCenterEnabled {
                coordinateAgentCenterAndBellNotificationsIfNeeded()
            }
        }
    }

    // MARK: - Swipe pad (experimental)
    /// Master gate for the swipe-pad floating puck (radial macros + dictation).
    /// Off by default — opt-in until the feature graduates from experimental.
    var swipePadEnabled: Bool = false {
        didSet { UserDefaults.standard.set(swipePadEnabled, forKey: "tessera.pref.swipePadEnabled") }
    }
    /// Corner the puck snaps to on cold launch. Values: topLeft|topRight|bottomLeft|bottomRight.
    /// The puck persists its dragged location separately; this is only the
    /// fallback for the first launch.
    var swipePadCorner: String = "bottomRight" {
        didSet { UserDefaults.standard.set(swipePadCorner, forKey: "tessera.pref.swipePadCorner") }
    }
    /// Puck diameter token. Values: compact (44pt) | standard (52pt) | large (64pt).
    var swipePadSize: String = "standard" {
        didSet { UserDefaults.standard.set(swipePadSize, forKey: "tessera.pref.swipePadSize") }
    }
    /// Last freeform position (puck center in canvas coordinates). `< 0` means
    /// "no saved position — use `swipePadCorner` instead." Updated every time
    /// the user long-press-drags the puck. Reset to -1 by the overlay when the
    /// user picks a new "default corner" in settings.
    var swipePadLastX: Double = -1 {
        didSet { UserDefaults.standard.set(swipePadLastX, forKey: "tessera.pref.swipePadLastX") }
    }
    var swipePadLastY: Double = -1 {
        didSet { UserDefaults.standard.set(swipePadLastY, forKey: "tessera.pref.swipePadLastY") }
    }
    /// Master gate for double-tap dictation on the puck. On by default (the
    /// double-tap is the feature's only entry point); the Experimental
    /// settings toggle persists it here, and SwipePadView consults it before
    /// starting the speech controller — so the visible off switch really
    /// keeps the microphone untouched.
    var voiceDictationEnabled: Bool = true {
        didSet { UserDefaults.standard.set(voiceDictationEnabled, forKey: "tessera.pref.voiceDictationEnabled") }
    }
    /// Auto-commit dictation after a silence window (default 1.2s).
    var voiceCommitOnSilence: Bool = true {
        didSet { UserDefaults.standard.set(voiceCommitOnSilence, forKey: "tessera.pref.voiceCommitOnSilence") }
    }
    /// Send a trailing 0x0D after dictation text hits the terminal.
    var voiceAppendReturn: Bool = false {
        didSet { UserDefaults.standard.set(voiceAppendReturn, forKey: "tessera.pref.voiceAppendReturn") }
    }
    /// Show a live waveform on the puck (morphs the puck into a wider pill).
    /// When false, the puck stays a circle while listening — quieter visually.
    var voiceWaveformOnPuck: Bool = true {
        didSet { UserDefaults.standard.set(voiceWaveformOnPuck, forKey: "tessera.pref.voiceWaveformOnPuck") }
    }

    // MARK: - Onboarding
    /// Set once the user has seen (taken or skipped) the first-launch
    /// walkthrough. Gates the auto-run; the tour stays re-runnable from
    /// Settings → About regardless. Lives here in UserDefaults rather than
    /// SwiftData to dodge the iOS-26 `[String]`-array migration landmine.
    var hasSeenWelcome: Bool = false {
        didSet { UserDefaults.standard.set(hasSeenWelcome, forKey: "tessera.pref.hasSeenWelcome") }
    }

    init() {
        let ud = UserDefaults.standard
        if let raw = ud.string(forKey: "tessera.pref.mode"),
           let v = AppearanceModeOption(rawValue: raw) { mode = v }
        if let raw = ud.string(forKey: "tessera.pref.accent"),
           let v = AccentName(rawValue: raw) { accent = v }
        let storedCustomRGB = ud.integer(forKey: "tessera.pref.customAccentRGB")
        if ud.object(forKey: "tessera.pref.customAccentRGB") != nil {
            customAccentRGB = storedCustomRGB
        }
        if let raw = ud.string(forKey: "tessera.pref.monoFontName") { monoFontName = raw }
        if ud.double(forKey: "tessera.pref.fontSize") > 0 { fontSize = ud.double(forKey: "tessera.pref.fontSize") }
        let storedTopBar = ud.double(forKey: "tessera.pref.topBarHeight")
        if AppearancePreferences.topBarHeightRange.contains(storedTopBar) {
            topBarHeight = storedTopBar
        }
        // Only an explicit user choice persists; an unset pref keeps the
        // highest-supported default so it follows the OS across upgrades.
        // A stored value the current OS can't render falls back to highest.
        if let raw = ud.string(forKey: "tessera.pref.chromeMaterial"),
           let v = ChromeMaterial(rawValue: raw) {
            chromeMaterial = v.isAvailable ? v : .highestSupported
        }

        if let raw = ud.string(forKey: "tessera.pref.cursorStyle"),
           let v = CursorStyleOption(rawValue: raw) { cursorStyle = v }
        if ud.object(forKey: "tessera.pref.cursorBlink") != nil {
            cursorBlink = ud.bool(forKey: "tessera.pref.cursorBlink")
        }
        let storedScrollback = ud.integer(forKey: "tessera.pref.scrollbackLines")
        if storedScrollback >= 1000 { scrollbackLines = storedScrollback }
        if ud.object(forKey: "tessera.pref.smoothScrollingEnabled") != nil {
            smoothScrollingEnabled = ud.bool(forKey: "tessera.pref.smoothScrollingEnabled")
        }
        let storedGlideSpeed = ud.double(forKey: "tessera.pref.smoothScrollingSpeed")
        if AppearancePreferences.smoothScrollingSpeedRange.contains(storedGlideSpeed) {
            smoothScrollingSpeed = storedGlideSpeed
        }
        if let raw = ud.string(forKey: "tessera.pref.sessionRestorePolicy"),
           let v = SessionRestorePolicy(rawValue: raw) {
            sessionRestorePolicy = v
        }
        if ud.object(forKey: "tessera.pref.handoffSessionsEnabled") != nil {
            handoffSessionsEnabled = ud.bool(
                forKey: "tessera.pref.handoffSessionsEnabled"
            )
        }

        if let raw = ud.string(forKey: "tessera.pref.terminalThemeID"), !raw.isEmpty {
            terminalThemeID = raw
        }

        if ud.object(forKey: "tessera.pref.terminalBackgroundUsesImage") != nil {
            terminalBackgroundUsesImage = ud.bool(forKey: "tessera.pref.terminalBackgroundUsesImage")
        }
        if let raw = ud.string(forKey: "tessera.pref.terminalBackgroundImageID"), !raw.isEmpty {
            terminalBackgroundImageID = raw
        }
        if ud.object(forKey: "tessera.pref.terminalBackgroundDim") != nil {
            let dim = ud.double(forKey: "tessera.pref.terminalBackgroundDim")
            if (0...0.85).contains(dim) { terminalBackgroundDim = dim }
        }
        if let raw = ud.string(forKey: "tessera.pref.terminalBackgroundFillMode"),
           TerminalBackgroundFillMode(rawValue: raw) != nil {
            terminalBackgroundFillMode = raw
        }
        if ud.object(forKey: "tessera.pref.terminalBackgroundBlur") != nil {
            let blur = ud.double(forKey: "tessera.pref.terminalBackgroundBlur")
            if AppearancePreferences.terminalBackgroundBlurRange.contains(blur) {
                terminalBackgroundBlur = blur
            }
        }

        if ud.object(forKey: "tessera.pref.naturalTextEditingEnabled") != nil {
            naturalTextEditingEnabled = ud.bool(forKey: "tessera.pref.naturalTextEditingEnabled")
        }
        if ud.object(forKey: "tessera.pref.showAccessoryBar") != nil {
            showAccessoryBar = ud.bool(forKey: "tessera.pref.showAccessoryBar")
        }
        if let keys = ud.array(forKey: "tessera.pref.accessoryBarKeys") as? [String] {
            accessoryBarKeys = keys
        }
        if let raw = ud.string(forKey: "tessera.pref.modifierBehavior"),
           raw == "oneShot" || raw == "sticky" {
            modifierBehavior = raw
        }

        if ud.object(forKey: RemoteFilesConstants.reaperDaysKey) != nil {
            filesReaperDays = max(0, ud.integer(forKey: RemoteFilesConstants.reaperDaysKey))
        }
        if let raw = ud.string(forKey: RemoteFilesConstants.defaultDestinationKey),
           raw == "cwd" || raw == "temp" {
            filesDefaultDestination = raw
        }

        if ud.object(forKey: "tessera.pref.requireFaceIDToUnlock") != nil {
            requireFaceIDToUnlock = ud.bool(forKey: "tessera.pref.requireFaceIDToUnlock")
        }
        let storedAutoLock = ud.integer(forKey: "tessera.pref.autoLockMinutes")
        if ud.object(forKey: "tessera.pref.autoLockMinutes") != nil {
            autoLockMinutes = storedAutoLock
        }
        if ud.object(forKey: "tessera.pref.lockWhenBackgrounded") != nil {
            lockWhenBackgrounded = ud.bool(forKey: "tessera.pref.lockWhenBackgrounded")
        }
        if ud.object(forKey: "tessera.pref.requireBiometricForKeyUse") != nil {
            requireBiometricForKeyUse = ud.bool(forKey: "tessera.pref.requireBiometricForKeyUse")
        }
        if ud.object(forKey: "tessera.pref.bellSoundEnabled") != nil {
            bellSoundEnabled = ud.bool(forKey: "tessera.pref.bellSoundEnabled")
        }
        if ud.object(forKey: "tessera.pref.bellVisualEnabled") != nil {
            bellVisualEnabled = ud.bool(forKey: "tessera.pref.bellVisualEnabled")
        }
        if ud.object(forKey: "tessera.pref.bellNotificationEnabled") != nil {
            bellNotificationEnabled = ud.bool(forKey: "tessera.pref.bellNotificationEnabled")
        }

        if ud.object(forKey: "tessera.pref.agentCenterNotificationsEnabled") != nil {
            agentCenterNotificationsEnabled = ud.bool(
                forKey: "tessera.pref.agentCenterNotificationsEnabled"
            )
        }
        if ud.object(forKey: "tessera.pref.agentCenterEnabled") != nil {
            agentCenterEnabled = ud.bool(forKey: "tessera.pref.agentCenterEnabled")
        }
        if ud.object(forKey: "tessera.pref.swipePadEnabled") != nil {
            swipePadEnabled = ud.bool(forKey: "tessera.pref.swipePadEnabled")
        }
        if let raw = ud.string(forKey: "tessera.pref.swipePadCorner"),
           ["topLeft", "topRight", "bottomLeft", "bottomRight"].contains(raw) {
            swipePadCorner = raw
        }
        if let raw = ud.string(forKey: "tessera.pref.swipePadSize"),
           ["compact", "standard", "large"].contains(raw) {
            swipePadSize = raw
        }
        if ud.object(forKey: "tessera.pref.voiceDictationEnabled") != nil {
            voiceDictationEnabled = ud.bool(forKey: "tessera.pref.voiceDictationEnabled")
        }
        if ud.object(forKey: "tessera.pref.voiceCommitOnSilence") != nil {
            voiceCommitOnSilence = ud.bool(forKey: "tessera.pref.voiceCommitOnSilence")
        }
        if ud.object(forKey: "tessera.pref.voiceAppendReturn") != nil {
            voiceAppendReturn = ud.bool(forKey: "tessera.pref.voiceAppendReturn")
        }
        if ud.object(forKey: "tessera.pref.voiceWaveformOnPuck") != nil {
            voiceWaveformOnPuck = ud.bool(forKey: "tessera.pref.voiceWaveformOnPuck")
        }
        if ud.object(forKey: "tessera.pref.swipePadLastX") != nil {
            swipePadLastX = ud.double(forKey: "tessera.pref.swipePadLastX")
        }
        if ud.object(forKey: "tessera.pref.swipePadLastY") != nil {
            swipePadLastY = ud.double(forKey: "tessera.pref.swipePadLastY")
        }

        if ud.object(forKey: "tessera.pref.hasSeenWelcome") != nil {
            hasSeenWelcome = ud.bool(forKey: "tessera.pref.hasSeenWelcome")
        }

        if agentCenterEnabled && agentCenterNotificationsEnabled {
            coordinateAgentCenterAndBellNotificationsIfNeeded()
        }
    }

    /// One-time coordination prevents duplicate, imprecise background alerts.
    /// The marker is never cleared: if the user later re-enables terminal-bell
    /// notifications, that explicit override remains untouched.
    private func coordinateAgentCenterAndBellNotificationsIfNeeded() {
        guard agentCenterEnabled, agentCenterNotificationsEnabled else { return }
        let defaults = UserDefaults.standard
        let key = "tessera.pref.agentCenterBellCoordinationPerformed"
        guard !defaults.bool(forKey: key) else { return }
        let disabledBell = bellNotificationEnabled
        if bellNotificationEnabled {
            bellNotificationEnabled = false
        }
        defaults.set(true, forKey: key)
        DiagnosticLogStore.appendAgentCenter(
            "notification-settings preciseAgent=true bellAutoDisabled=\(disabledBell) coordination=complete"
        )
    }

    func resolvedMode(systemColorScheme: ColorScheme) -> AppearanceMode {
        switch mode {
        case .dark:   return .dark
        case .light:  return .light
        case .system: return systemColorScheme == .light ? .light : .dark
        }
    }

    func tokens(systemColorScheme: ColorScheme) -> DesignTokens {
        DesignTokens.make(
            mode: resolvedMode(systemColorScheme: systemColorScheme),
            accent: accent,
            customColor: accent == .custom ? Color(rgbInt: customAccentRGB) : nil
        )
    }
}
