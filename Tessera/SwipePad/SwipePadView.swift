// Tessera/SwipePad/SwipePadView.swift
// Visible swipe-pad puck, radial macro launcher, and dictation surface.
import SwiftUI
import TmuxControl

private enum PuckState {
    case idle, pressing, relocating, radialOpen
}

/// Status colors shared by petal tints and the puck's attention rings.
enum SwipePadPalette {
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.04)
}

/// The pad's continuous (repeatForever) ring/pulse animations block ordinary
/// XCUITest quiescence — public API taps stall waiting for app idle. Reduce
/// Motion is the user-facing off switch; automation opts in per launch with
/// `launchEnvironment["TESSERA_STATIC_RINGS"] = "1"` instead of mutating
/// simulator accessibility settings. `SwipePadQuiescenceHarnessTests` is the
/// checked-in driver proving standard taps complete under this gate. Either
/// switch keeps every ring visible, just static.
enum SwipePadMotion {
    static let staticRings =
        ProcessInfo.processInfo.environment["TESSERA_STATIC_RINGS"] == "1"
}

/// A completion acknowledgement hides only the visual attention treatment.
/// The semantic `.justFinished` state — including its mode-switch petal —
/// remains intact until Agent Center advances it normally.
enum SwipePadFinishedAcknowledgement {
    static func tintIsVisible(
        status: AgentStatus,
        stateKey: String,
        acknowledgedKey: String?
    ) -> Bool {
        status == .justFinished && stateKey != acknowledgedKey
    }
}

/// Full-pad status light. Waiting breathes continuously; completion breathes
/// three times and then remains visibly green for the rest of the finished
/// window. The fill stays inside the puck, so clipping can never erase it.
private struct SwipePadStatusGlow: View {
    enum Mode: Equatable {
        case waiting
        case finished

        var color: Color {
            switch self {
            case .waiting: SwipePadPalette.amber
            case .finished: SwipePadPalette.green
            }
        }
    }

    let diameter: CGFloat
    let mode: Mode
    let trigger: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var illuminated = false

    var body: some View {
        Circle()
            .fill(mode.color.opacity(illuminated ? 0.42 : 0.18))
            .overlay {
                Circle()
                    .strokeBorder(
                        mode.color.opacity(illuminated ? 0.88 : 0.42),
                        lineWidth: illuminated ? 1.2 : 0.7
                    )
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(illuminated ? 1.0 : 0.94)
            .shadow(
                color: mode.color.opacity(illuminated ? 0.72 : 0.28),
                radius: illuminated ? 18 : 8
            )
            .allowsHitTesting(false)
            .onAppear {
                guard mode == .waiting else { return }
                guard !reduceMotion, !SwipePadMotion.staticRings else {
                    illuminated = true
                    return
                }
                withAnimation(
                    .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                ) { illuminated = true }
            }
            .task(id: trigger) {
                guard mode == .finished else { return }
                guard !reduceMotion, !SwipePadMotion.staticRings else {
                    illuminated = true
                    return
                }
                for _ in 0..<3 {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        illuminated = true
                    }
                    try? await Task.sleep(for: .milliseconds(450))
                    withAnimation(.easeInOut(duration: 0.3)) {
                        illuminated = false
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
                withAnimation(.easeInOut(duration: 0.4)) {
                    illuminated = true
                }
            }
    }
}

struct SwipePadView: View {
    let diameter: CGFloat
    let position: CGPoint
    let canvasSize: CGSize
    let resolver: SwipePadActiveProfileResolver
    let tmux: TmuxController
    let processNameProvider: SwipePadProcessNameProvider?
    let paneProcessNameProvider: SwipePadPaneProcessNameProvider?
    @Bindable var profileStore: SwipePadProfileStore
    @Bindable var dictationController: SpeechDictationController
    /// Hook-proof snapshot of the focused pane's agent; nil = legacy
    /// resolver mode. Passed by value so the view re-renders with each
    /// equality-gated publish and stays trivially previewable.
    var hookSnapshot: SwipePadAgentSnapshot? = nil
    /// Live reference behind `hookSnapshot`. Escaping work (the VoiceOver
    /// fallback's async resolution) must re-check hook state when it lands,
    /// and a captured struct copy only knows the state at render time.
    /// nil (previews, tests) falls back to the snapshot value.
    var agentContext: SwipePadAgentContext? = nil
    var onShowMore: (() -> Void)? = nil
    /// Hidden (opacity-0) session views keep their overlay mounted; the
    /// attention rings only animate on the visible one.
    var sessionIsActive: Bool = true
    let onFireMacro: (String) -> Void
    let onRelocate: (CGPoint) -> Void

    @Environment(AppearancePreferences.self) private var appearance
    @Environment(\.designTokens) private var T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Opaque fill used when `chromeMaterial == .solid` (and under Reduce
    /// Transparency). The puck family is dark-styled with white glyphs, so it
    /// stays dark regardless of theme — matching the accessory bar's fill.
    private static let puckSolidFill = Color(red: 28/255, green: 28/255, blue: 30/255)

    @State private var puckState: PuckState = .idle
    @State private var totalTranslation: CGSize = .zero
    @State private var pressStartedAt: Date? = nil
    @State private var activeDirection: SwipeDirection? = nil
    @State private var doubleTapped = false
    @State private var petalVisible = false
    @State private var relocateCheckTask: Task<Void, Never>? = nil
    @State private var activeProfile: SwipePadProfile? = nil
    @State private var pulse = false
    @State private var diagnosticPressID = 0
    @State private var acknowledgedFinishedKey: String? = nil
    /// Hook state the fire guard baselines against: captured at press-begin
    /// and re-baselined at radial-open onto a live hook state (see
    /// SwipePadFireGuard.keyAtRadialOpen). Petals render live, so if the
    /// remote state changes after the petals became visible, release aims
    /// at petals the user never saw — the guard compares this key against
    /// the release-time state and refuses on mismatch.
    @State private var pressHookStateKey: String? = nil

    private var isDictating: Bool {
        dictationController.activeState != .idle
    }

    private var usesDictationPill: Bool {
        isDictating && appearance.voiceWaveformOnPuck
    }

    private var controlSize: CGSize {
        usesDictationPill
            ? CGSize(width: 280, height: 56)
            : CGSize(width: diameter, height: diameter)
    }

    /// Petals for the current mode. Hook mode is computed live from the
    /// snapshot so a prompt answered remotely mid-gesture retracts its
    /// petals immediately; fallback uses the profile captured at
    /// press-begin, exactly as before.
    private var currentPetals: [SwipePadPetalModel] {
        if let snapshot = hookSnapshot {
            return hookPetals(for: snapshot)
        }
        guard let profile = activeProfile else { return [] }
        return SwipePadPetalLayout.petals(for: profile)
    }

    /// An overflowing live prompt normally uses the down petal for More.
    /// When down is itself a trained live binding, layout keeps all four
    /// gestures truthful and publishes More as a separate puck action.
    private var currentSeparateMoreCount: Int? {
        guard let snapshot = hookSnapshot else { return nil }
        return hookPromptLayout(for: snapshot)?.separateMoreCount
    }

    private func hookPromptLayout(
        for snapshot: SwipePadAgentSnapshot
    ) -> SwipePadPromptLayout? {
        guard snapshot.status == .waitingForInput,
              let prompt = snapshot.prompt else { return nil }
        let profile = profileStore.profiles
            .first(where: { $0.id == snapshot.profileID })
        return SwipePadPetalLayout.promptLayout(for: prompt, profile: profile)
    }

    private func hookPetals(for snapshot: SwipePadAgentSnapshot) -> [SwipePadPetalModel] {
        if snapshot.status == .waitingForInput {
            if let layout = hookPromptLayout(for: snapshot) {
                return layout.petals
            }
            // Confirmed waiting, but the menu's options couldn't be
            // parsed (capture raced the repaint, or the redraw didn't
            // match the grammar). The parser safety invariant holds
            // here too: an unparseable prompt is never actionable, so
            // no static keymap — only the zero-byte "open the prompt
            // UI" petal (plus nothing on the trained directions, so a
            // blind swipe sends no guessed answer).
            return SwipePadPetalLayout.unparsedPromptPetals()
        }
        if snapshot.status == .working {
            return SwipePadPetalLayout.workingPetals()
        }
        if snapshot.status == .idle {
            return SwipePadPetalLayout.idlePetals()
        }
        if snapshot.status == .justFinished {
            return SwipePadPetalLayout.justFinishedPetals()
        }
        // Menu-answer macros are meaningless outside actionable hook states.
        // Custom bindings on the built-ins remain reachable the moment
        // hook proof drops (agent exits) via the resolver fallback.
        return []
    }

    /// Invoke-time hook state for escaping/async safety checks: reads the
    /// live context when available so a check that runs after this struct
    /// copy was captured still sees the current world.
    private var liveHookSnapshot: SwipePadAgentSnapshot? {
        if let agentContext { return agentContext.snapshot }
        return hookSnapshot
    }

    /// Live fire-guard key; see `SwipePadAgentSnapshot.fireGuardKey` and
    /// `SwipePadFireGuard`.
    private var hookStateKey: String? {
        hookSnapshot?.fireGuardKey
    }

    var body: some View {
        ZStack {
            // Built once per body evaluation, not once per subview read —
            // drag frames re-evaluate body continuously while the radial
            // is open.
            radialLayer(petals: puckState == .radialOpen ? currentPetals : [])
            transcriptBubble
            control
        }
        .frame(width: controlSize.width, height: controlSize.height)
        .offset(
            x: puckState == .relocating ? totalTranslation.width : 0,
            y: puckState == .relocating ? totalTranslation.height : 0
        )
        .scaleEffect(puckState == .idle ? 1 : 1.04)
        .opacity(puckState == .idle || puckState == .pressing ? 0.78 : 1)
        .simultaneousGesture(dragGesture)
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: controlSize)
        .animation(.easeInOut(duration: 0.12), value: puckState)
        .onChange(of: sessionIsActive) { _, nowActive in
            // A drag cancelled by the session hiding never delivers
            // onEnded — don't leave the radial visually stuck open.
            if !nowActive, puckState != .idle {
                resetGestureState()
            }
        }
        .onDisappear {
            relocateCheckTask?.cancel()
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment[
                "TESSERA_SWIPEPAD_FORCE_RADIAL_OPEN"
            ] == "1" {
                puckState = .radialOpen
                petalVisible = true
                // Optional aim freeze so screenshots can capture the active
                // petal swell and the fan readout without a live drag.
                if let raw = ProcessInfo.processInfo.environment[
                    "TESSERA_SWIPEPAD_FORCE_ACTIVE_DIRECTION"
                ], let direction = SwipeDirection(rawValue: raw) {
                    activeDirection = direction
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private func radialLayer(petals: [SwipePadPetalModel]) -> some View {
        if puckState == .radialOpen {
            if let activeDirection,
               let model = petals.first(where: { $0.direction == activeDirection }) {
                Circle()
                    .fill(tintColor(model.tint).opacity(0.2))
                    .frame(width: 80, height: 80)
                    .blur(radius: 20)
                    .offset(totalTranslation)
                    .allowsHitTesting(false)
            }

            if petalVisible {
                // Placement modes in strict preference order (decided by
                // SwipePadPetalLayout.presentation): the full cross wherever
                // every petal fits at its ideal cardinal offset; the 90°
                // corner fan where the cross cannot fit (petals stay centered
                // in their own angular sectors, so the drag that fires them
                // is still the drag that points at them); chip rows only for
                // degenerate geometry neither radial can serve. Firing
                // quantization follows the same decision — see
                // resolvedDirection(for:).
                switch SwipePadPetalLayout.presentation(
                    directions: petals.map(\.direction),
                    puckCenter: position,
                    canvasSize: canvasSize,
                    diameter: diameter
                ) {
                case .cross:
                    ForEach(petals) { model in
                        petal(model: model)
                            .offset(
                                SwipePadPetalLayout.petalOffset(
                                    for: model.direction,
                                    diameter: diameter
                                )
                            )
                            .transition(.scale(scale: 0.82).combined(with: .opacity))
                    }
                case .fan(let quadrant):
                    fanLayer(petals: petals, quadrant: quadrant)
                        .transition(.scale(scale: 0.82).combined(with: .opacity))
                case .chips:
                    chipStack(petals: petals)
                        .offset(
                            SwipePadPetalLayout.chipStackCenterOffset(
                                petalCount: petals.count,
                                puckCenter: position,
                                canvasSize: canvasSize,
                                diameter: diameter
                            )
                        )
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptBubble: some View {
        if isDictating && (dictationController.activeState != .idle || !dictationController.transcript.isEmpty) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    pulsingDot(size: 6)
                    Text("LISTENING")
                        .font(Typography.tesseraMono(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.white.opacity(0.7))
                }

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(dictationController.transcript)
                        .font(Typography.tesseraMono(size: 13))
                        .foregroundStyle(Color.white)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)

                    TimelineView(.animation(minimumInterval: 0.85)) { context in
                        Text("|")
                            .font(Typography.tesseraMono(size: 13))
                            .foregroundStyle(T.accent)
                            .opacity(caretIsVisible(at: context.date) ? 1 : 0)
                    }
                    .frame(width: 5)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(width: transcriptWidth, alignment: .leading)
            .floatingGlass(
                appearance.chromeMaterial,
                tint: .clear,
                solidFill: Self.puckSolidFill,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
            .offset(y: usesDictationPill ? -104 : -84)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var control: some View {
        if usesDictationPill {
            dictationPill
                .transition(.scale(scale: 0.94).combined(with: .opacity))
        } else {
            circularPuck
                .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
    }

    /// Flat frosted disc — same visual language as `SessionTopBar` /
    /// `FindBar` / the accessory bar chips. State drives the inner glyph,
    /// always monochrome white. Indicator-only differentiation: which
    /// SF Symbol is shown, not its color.
    ///
    /// State → glyph mapping:
    ///   - `.relocating`  → 4-way move arrow (only visible while picking up)
    ///   - dictation mode → mic.fill
    ///   - overflow with trained down binding → ellipsis (tap for More)
    ///   - hook-proven agent OR matched profile → sparkles
    ///   - otherwise      → no glyph
    private var circularPuck: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.12))

            if isDictating && !appearance.voiceWaveformOnPuck {
                Circle()
                    .stroke(Color.red, lineWidth: 2)
                    .frame(width: diameter + 10, height: diameter + 10)
                    .scaleEffect(pulse ? 1.12 : 1.0)
                    .opacity(pulse ? 0.4 : 1.0)
                    .allowsHitTesting(false)
            } else if sessionIsActive, let snapshot = hookSnapshot {
                // Status light fills the puck; the mic ring keeps priority.
                // Each light exists only in its state (and only on the visible
                // session, never in hidden opacity-0 mounts), so animation is torn
                // down on removal and the resting puck costs nothing. No
                // scene-phase gate on purpose: backgrounded rendering is
                // suspended by the system, unlike the polling this file
                // gates explicitly.
                if snapshot.status == .waitingForInput {
                    SwipePadStatusGlow(
                        diameter: diameter,
                        mode: .waiting,
                        trigger: snapshot.statusChangedAt
                    )
                } else if finishedTintIsVisible {
                    SwipePadStatusGlow(
                        diameter: diameter,
                        mode: .finished,
                        trigger: snapshot.statusChangedAt
                    )
                }
            }

            if let glyph = currentGlyph {
                Image(systemName: glyph.symbol)
                    .font(.system(size: glyph.size, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .frame(width: diameter, height: diameter)
        .floatingGlass(
            appearance.chromeMaterial,
            tint: .clear,
            solidFill: Self.puckSolidFill,
            in: Circle()
        )
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(
                    statusBorderColor,
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 12)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .contentShape(Circle())
        .simultaneousGesture(puckTapGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("swipepad-puck")
        .onAppear(perform: startPulse)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityActions {
            // The radial drag has no VoiceOver equivalent — every petal
            // (prompt options, interrupt, overflow "more") is offered as a
            // custom action instead. Activation still races the world (the
            // action list the user heard can lag a state change), so every
            // invocation re-validates before firing: hook actions against
            // the live snapshot key, fallback actions against a fresh
            // foreground resolution. See performAccessibilityAction.
            let renderKey = hookStateKey
            ForEach(accessibilityPetals) { model in
                Button(accessibilityActionName(model)) {
                    performAccessibilityAction(model, renderKey: renderKey)
                }
            }
            if let hiddenCount = currentSeparateMoreCount {
                Button("Show all options, \(hiddenCount) more") {
                    showMore(source: "a11y-puck")
                }
            }
            if finishedTintIsVisible {
                Button("Acknowledge completion") {
                    acknowledgeFinished(source: "a11y-puck")
                }
            }
        }
    }

    private var finishedTintIsVisible: Bool {
        guard let snapshot = hookSnapshot else { return false }
        return SwipePadFinishedAcknowledgement.tintIsVisible(
            status: snapshot.status,
            stateKey: snapshot.fireGuardKey,
            acknowledgedKey: acknowledgedFinishedKey
        )
    }

    private var statusBorderColor: Color {
        guard !isDictating, sessionIsActive, let snapshot = hookSnapshot else {
            return Color.white.opacity(0.18)
        }
        switch snapshot.status {
        case .waitingForInput: return SwipePadPalette.amber.opacity(0.72)
        case .justFinished:
            return finishedTintIsVisible
                ? SwipePadPalette.green.opacity(0.72)
                : Color.white.opacity(0.18)
        default: return Color.white.opacity(0.18)
        }
    }

    /// Petals reachable without a drag. Hook mode reads the live snapshot
    /// (press-independent); fallback reads the resolver's current profile —
    /// the same source a press would cache into `activeProfile`.
    private var accessibilityPetals: [SwipePadPetalModel] {
        guard !isDictating else { return [] }
        if hookSnapshot != nil { return currentPetals }
        guard let profile = resolver.currentProfile else { return [] }
        return SwipePadPetalLayout.petals(for: profile)
    }

    private func accessibilityActionName(_ model: SwipePadPetalModel) -> String {
        if model.action == .showMore { return "Show all options" }
        return "\(model.label) (\(displayMacro(model.caption)))"
    }

    /// VoiceOver equivalent of the drag path's two safety mechanisms. Hook
    /// mode mirrors the press/release fire guard: the action fires only if
    /// the live snapshot key still equals the key of the render that offered
    /// the action AND the exact petal is still among the current ones — a
    /// prompt replaced by a same-shaped prompt (identical labels, different
    /// question) refuses on the key. Fallback mode mirrors press-begin's
    /// on-demand resolution AND pins an origin token across the async gap
    /// (see SwipePadAccessibilityFallbackGate): the fresh resolution must
    /// still describe the same live surface — not suspended, not
    /// invalidated, same tmux focus — and still offer this exact binding.
    /// Zero-byte showMore bypasses neither — opening Agent Center is always
    /// safe, so it fires directly.
    private func performAccessibilityAction(
        _ model: SwipePadPetalModel,
        renderKey: String?
    ) {
        if model.action == .showMore {
            performPetalAction(model, source: "a11y")
            return
        }
        if renderKey != nil {
            // Hook-offered action: fire only while the live state is still
            // the exact state whose render offered it. A prompt replaced by
            // a same-shaped one (identical labels, different question)
            // refuses on the key even though the petal would compare equal.
            guard let live = liveHookSnapshot,
                  live.fireGuardKey == renderKey,
                  hookPetals(for: live).contains(model) else {
                refuseAccessibilityAction(reason: "hook-state-changed")
                return
            }
            performPetalAction(model, source: "a11y")
            return
        }
        // Fallback-offered action: bind it to a live origin token before
        // the asynchronous resolution starts. If the originating surface
        // is suspended mid-flight (session hidden, app backgrounded, hook
        // proof arriving), the resolver is invalidated, or tmux focus
        // moves to another pane, the completion must refuse even when the
        // resolved profile still offers an equal binding — those bytes
        // would land in a surface the user never aimed at.
        guard let origin = SwipePadAccessibilityFallbackGate.captureOrigin(
            resolver: resolver,
            tmux: tmux
        ) else {
            refuseAccessibilityAction(reason: "surface-inactive")
            return
        }
        resolver.resolveActiveProfile(
            tmux: tmux,
            store: profileStore,
            processNameProvider: processNameProvider,
            paneProcessNameProvider: paneProcessNameProvider
        ) { resolved in
            // resolver/tmux are live class references and liveHookSnapshot
            // reads the live agent context — nothing here trusts values
            // frozen into this closure at render time.
            if let reason = SwipePadAccessibilityFallbackGate.refusalReason(
                origin: origin,
                current: SwipePadAccessibilityFallbackGate.captureOrigin(
                    resolver: resolver,
                    tmux: tmux
                ),
                liveHookSnapshot: liveHookSnapshot,
                resolvedProfile: resolved,
                model: model
            ) {
                refuseAccessibilityAction(reason: reason)
                return
            }
            performPetalAction(model, source: "a11y")
        }
    }

    private func refuseAccessibilityAction(reason: String) {
        SwipePadDiagnostics.log("petal-action source=a11y no-fire reason=\(reason)")
        UIAccessibility.post(
            notification: .announcement,
            argument: "Terminal state changed, action not sent"
        )
    }

    private func performPetalAction(_ model: SwipePadPetalModel, source: String) {
        switch model.action {
        case .showMore:
            showMore(source: source)
        case .macro(let spec):
            SwipePadDiagnostics.log(
                "petal-action source=\(source) direction=\(model.direction.rawValue) mode=\(hookSnapshot != nil ? "hook" : "profile") macroBytes=\(spec.utf8.count)"
            )
            onFireMacro(spec)
        }
    }

    private func showMore(source: String) {
        SwipePadDiagnostics.log("petal-action source=\(source) action=show-more")
        onShowMore?()
    }

    // MARK: - State → glyph selection

    private struct PuckGlyph {
        let symbol: String
        let size: CGFloat
    }

    private var currentGlyph: PuckGlyph? {
        // Order matters — first match wins. Most-specific states first.
        if puckState == .relocating {
            return PuckGlyph(symbol: "arrow.up.and.down.and.arrow.left.and.right", size: 14)
        }
        if isDictating && !appearance.voiceWaveformOnPuck {
            return PuckGlyph(symbol: "mic.fill", size: 15)
        }
        if currentSeparateMoreCount != nil {
            return PuckGlyph(symbol: "ellipsis", size: 15)
        }
        if hookSnapshot != nil || matchedIndicatorVisible {
            return PuckGlyph(symbol: "sparkles", size: 14)
        }
        return nil
    }

    /// True when a non-fallback profile is currently selected by the
    /// resolver — i.e., the user's foreground process matched one of the
    /// configured rules. Drives the at-rest "matched" indicator.
    private var matchedIndicatorVisible: Bool {
        guard let profile = resolver.currentProfile else { return false }
        return !profile.matchProcess.isEmpty
    }

    private var accessibilityLabel: String {
        if isDictating { return "Dictation active" }
        if puckState == .relocating { return "Moving swipe pad" }
        if let snapshot = hookSnapshot {
            switch snapshot.status {
            case .waitingForInput:
                // Only a parsed prompt has a truthful option count; the
                // unparsed fallback offers the static keymap instead.
                if let count = snapshot.prompt?.options.count {
                    return "Swipe pad · \(snapshot.profileName) waiting for input, \(count) options"
                }
                return "Swipe pad · \(snapshot.profileName) waiting for input"
            case .working:
                return "Swipe pad · \(snapshot.profileName) working, swipe left to interrupt or up to switch mode"
            case .justFinished:
                if finishedTintIsVisible {
                    return "Swipe pad · \(snapshot.profileName) finished, tap to acknowledge or swipe up to switch mode"
                }
                return "Swipe pad · \(snapshot.profileName) finished, swipe up to switch mode"
            case .idle:
                return "Swipe pad · \(snapshot.profileName) idle, swipe up to switch mode"
            case .unavailable:
                return "Swipe pad · \(snapshot.profileName)"
            }
        }
        if let profile = resolver.currentProfile, !profile.matchProcess.isEmpty {
            return "Swipe pad · matched \(profile.name)"
        }
        return "Swipe pad"
    }

    private var dictationPill: some View {
        HStack(spacing: 11) {
            pulsingDot(size: 8)

            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(T.accent)

            waveformBars

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsedText(at: context.date))
                    .font(Typography.tesseraMono(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.78))
            }
            .frame(width: 38, alignment: .leading)

            Button {
                dictationController.stop(commit: false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
                    // 30 pt visual circle inside a 44 pt hit frame. Sub-44 pt
                    // targets trip iPadOS 26's hit-target expansion into
                    // mis-assigning taps to the neighbor (see SidebarIconButton)
                    // — here the neighbor is the pill's commit surface.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel dictation")
            // Re-balance the widened frame: it overhangs 7 pt per side instead
            // of pushing neighbors, so every glyph center stays put.
            .padding(.horizontal, -7)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(width: 280, height: 56)
        .floatingGlass(
            appearance.chromeMaterial,
            tint: .clear,
            solidFill: Self.puckSolidFill,
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        // Decoration only. A filled/stroked Shape in an overlay is hit-testable
        // and covers the whole pill — including the cancel button beneath it —
        // so without this the X never receives a touch and every tap falls
        // through to the commit gesture below.
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.13))
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 12)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        // Whole pill, cancel button included. `contentShape` on a container
        // replaces the hit region of the *entire subtree*, so subtracting the
        // cancel button's frame here (as an earlier revision did, to stop a
        // mis-assigned tap from committing) punched a hole that swallowed the
        // cancel taps too — the X became completely dead. What keeps the two
        // apart is child-before-ancestor hit testing: with nothing covering it
        // (see the overlays above), the Button claims every tap inside its
        // 44 pt frame and this gesture only sees the rest of the pill.
        // Verified by tap probe — TESSERA_SWIPEPAD_DICTATION_HARNESS.
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onTapGesture {
            dictationController.stop(commit: true)
        }
        .onAppear(perform: startPulse)
        .accessibilityLabel("Dictation")
        .accessibilityHint(
            appearance.voiceCommitOnSilence
                ? "Tap to commit. Silence can auto-commit."
                : "Tap to commit."
        )
    }

    private var waveformBars: some View {
        let heights: [CGFloat] = [6, 14, 20, 24, 20, 14, 6]
        let multiplier = 0.4 + 0.6 * max(0, min(1, dictationController.amplitude))

        return HStack(alignment: .center, spacing: 3) {
            ForEach(heights.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(T.accent)
                    .frame(width: 3, height: heights[index] * multiplier)
            }
        }
        .frame(width: 39, height: 30)
        .animation(.easeInOut(duration: 0.1), value: dictationController.amplitude)
    }

    /// Shared glass disc for cross and fan petals; the caller frames it.
    private func petalDisc(
        model: SwipePadPetalModel,
        isActive: Bool,
        size: CGFloat
    ) -> some View {
        let tint = tintColor(model.tint)
        let glyphSize: CGFloat = isActive ? size * 0.42 : size * 0.36
        return ZStack {
            Circle()
                .fill(Color.white.opacity(0.12))

            if isActive {
                Circle()
                    .fill(tint.opacity(0.35))
            }

            Image(systemName: symbol(for: model))
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(isActive ? tint : Color.white.opacity(0.92))
        }
        .frame(width: size, height: size)
        .floatingGlass(
            appearance.chromeMaterial,
            tint: .clear,
            solidFill: Self.puckSolidFill,
            in: Circle()
        )
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(isActive ? tint.opacity(0.55) : Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: isActive ? tint.opacity(0.35) : .black.opacity(0.45), radius: isActive ? 18 : 14, y: 10)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private func petal(model: SwipePadPetalModel) -> some View {
        let isActive = activeDirection == model.direction
        let tint = tintColor(model.tint)
        // Petal sizes track the puck so the action targets feel like the
        // same visual family. Active petal swells by ~25% as the aim cue.
        let size: CGFloat = isActive ? diameter * 1.25 : diameter

        // Layout note: the petal's geometric center MUST be the ring center,
        // because `.offset(petalOffset)` positions the view's center at the
        // target cardinal point. A VStack with ring + caption would shift
        // the ring above the offset point by half the caption height —
        // visually misaligning the left/right petals above the puck's
        // horizontal axis. We pin the outer ZStack frame to the ring size
        // and place the caption via `.offset` so it draws below the ring
        // without contributing to the frame.
        let captionGap: CGFloat = isActive ? 12 : 10
        return ZStack {
            petalDisc(model: model, isActive: isActive, size: size)

            petalLabelSurface {
                VStack(spacing: 2) {
                    Text(model.label)
                        .font(Typography.tesseraMono(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isActive ? tint : Color.white.opacity(0.92))

                    Text(displayMacro(model.caption))
                        .font(Typography.tesseraMono(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(Color.white.opacity(0.58))
                }
                .padding(.vertical, 4)
                // Fixed width keeps sentence-length prompt labels honest:
                // SwiftUI otherwise compresses these offset ribbons to a
                // few glyphs because they do not contribute to ZStack size.
                .frame(width: SwipePadPetalLayout.petalCaptionWidth)
            }
            .offset(y: size / 2 + captionGap + 14)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.12), value: isActive)
        .accessibilityIdentifier(
            "swipepad-radial-petal-\(model.direction.rawValue)"
        )
    }

    /// Corner fan: the same petal models on a 90° arc when the cross
    /// cannot fit (see SwipePadPetalLayout.fanAngles for the slot
    /// contract). Petals shrink and drop the cross's 148 pt caption
    /// ribbon — each carries a compact mini-label instead, and the aimed
    /// petal's full text shows in the readout pill on the fan's bisector.
    @ViewBuilder
    private func fanLayer(
        petals: [SwipePadPetalModel],
        quadrant: SwipePadPetalLayout.FanQuadrant
    ) -> some View {
        let directions = petals.map(\.direction)
        ForEach(petals) { model in
            fanPetal(model: model)
                .offset(
                    SwipePadPetalLayout.fanPetalOffset(
                        for: model.direction,
                        directions: directions,
                        quadrant: quadrant,
                        puckDiameter: diameter
                    )
                )
        }
        ForEach(petals) { model in
            fanLabel(model: model)
                .offset(
                    SwipePadPetalLayout.fanLabelOffset(
                        for: model.direction,
                        directions: directions,
                        quadrant: quadrant,
                        puckDiameter: diameter,
                        puckCenter: position,
                        canvasSize: canvasSize
                    )
                )
        }
        if let activeDirection,
           let model = petals.first(where: { $0.direction == activeDirection }) {
            fanReadout(model: model)
                .offset(
                    SwipePadPetalLayout.fanReadoutOffset(
                        quadrant: quadrant,
                        puckDiameter: diameter,
                        puckCenter: position,
                        canvasSize: canvasSize
                    )
                )
        }
    }

    private func fanPetal(model: SwipePadPetalModel) -> some View {
        let isActive = activeDirection == model.direction
        let base = SwipePadPetalLayout.fanPetalDiameter(puckDiameter: diameter)
        let size = isActive ? base * SwipePadPetalLayout.petalMaxScale : base
        return petalDisc(model: model, isActive: isActive, size: size)
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.12), value: isActive)
            .accessibilityIdentifier(
                "swipepad-radial-petal-\(model.direction.rawValue)"
            )
    }

    private func fanLabel(model: SwipePadPetalModel) -> some View {
        let isActive = activeDirection == model.direction
        let tint = tintColor(model.tint)
        return petalLabelSurface {
            VStack(spacing: 1) {
                Text(model.label)
                    .font(Typography.tesseraMono(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isActive ? tint : Color.white.opacity(0.92))

                Text(displayMacro(model.caption))
                    .font(Typography.tesseraMono(size: 9))
                    .lineLimit(1)
                    .foregroundStyle(Color.white.opacity(0.58))
            }
            .padding(.vertical, 4)
            .frame(width: SwipePadPetalLayout.fanLabelWidth)
        }
        .animation(.easeInOut(duration: 0.12), value: isActive)
        .allowsHitTesting(false)
    }

    private func petalLabelSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return content()
            .floatingGlass(
                appearance.chromeMaterial,
                tint: Color.black.opacity(0.28),
                solidFill: Self.puckSolidFill,
                in: shape
            )
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
    }

    private func fanReadout(model: SwipePadPetalModel) -> some View {
        let tint = tintColor(model.tint)
        return VStack(spacing: 2) {
            Text(model.label)
                .font(Typography.tesseraMono(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(tint)

            Text(displayMacro(model.caption))
                .font(Typography.tesseraMono(size: 10))
                .lineLimit(1)
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .frame(width: 200)
        .floatingGlass(
            appearance.chromeMaterial,
            tint: .clear,
            solidFill: Self.puckSolidFill,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
        .allowsHitTesting(false)
        .transition(.scale(scale: 0.94).combined(with: .opacity))
    }

    /// Edge fallback for the radial: one row per petal, top-to-bottom in
    /// option order, each stating its drag direction with an arrow glyph.
    /// Purely visual, like the petals — firing stays on the puck drag.
    private func chipStack(petals: [SwipePadPetalModel]) -> some View {
        VStack(spacing: SwipePadPetalLayout.chipRowSpacing) {
            ForEach(petals) { model in
                chipRow(model: model)
            }
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("swipepad-chip-stack")
    }

    private func chipRow(model: SwipePadPetalModel) -> some View {
        let isActive = activeDirection == model.direction
        let tint = tintColor(model.tint)

        return HStack(spacing: 10) {
            Image(systemName: chipArrowSymbol(model.direction))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isActive ? tint : Color.white.opacity(0.92))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.label)
                    .font(Typography.tesseraMono(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isActive ? tint : Color.white.opacity(0.92))
                Text(displayMacro(model.caption))
                    .font(Typography.tesseraMono(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            Spacer(minLength: 0)

            Image(systemName: symbol(for: model))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? tint : Color.white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .frame(
            width: SwipePadPetalLayout.chipWidth,
            height: SwipePadPetalLayout.chipRowHeight
        )
        .floatingGlass(
            appearance.chromeMaterial,
            tint: .clear,
            solidFill: Self.puckSolidFill,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isActive ? tint.opacity(0.55) : Color.white.opacity(0.18),
                    lineWidth: 0.5
                )
        )
        .shadow(color: isActive ? tint.opacity(0.3) : .black.opacity(0.4), radius: isActive ? 14 : 10, y: 6)
        .animation(.easeInOut(duration: 0.12), value: isActive)
    }

    private func chipArrowSymbol(_ direction: SwipeDirection) -> String {
        switch direction {
        case .right: "arrow.right"
        case .left: "arrow.left"
        case .up: "arrow.up"
        case .down: "arrow.down"
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isDictating else { return }
                handleDragChanged(value)
            }
            .onEnded { _ in
                guard !isDictating else {
                    resetGestureState()
                    return
                }
                handleDragEnded()
            }
    }

    /// Make single-tap More and double-tap dictation mutually exclusive.
    /// A plain `.onTapGesture` beside a simultaneous double-tap recognizer
    /// can fire on the first tap of the double; the exclusive composition
    /// waits long enough to know which user intent won.
    private var puckTapGesture: some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { value in
                switch value {
                case .first:
                    handleDoubleTap()
                case .second:
                    handleSingleTap()
                }
            }
    }

    private func handleSingleTap() {
        if isDictating {
            dictationController.stop(commit: true)
        } else if currentSeparateMoreCount != nil {
            showMore(source: "puck-tap")
        } else if finishedTintIsVisible {
            acknowledgeFinished(source: "puck-tap")
        }
    }

    private func acknowledgeFinished(source: String) {
        guard let snapshot = hookSnapshot,
              snapshot.status == .justFinished
        else { return }
        acknowledgedFinishedKey = snapshot.fireGuardKey
        SwipePadDiagnostics.log("finished-ack source=\(source)")
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        if puckState == .idle {
            beginPress()
        }

        totalTranslation = value.translation
        let distance = magnitude(value.translation)

        if puckState == .pressing {
            if let pressStartedAt, Date.now.timeIntervalSince(pressStartedAt) >= 0.5, distance < 6 {
                withAnimation(.easeInOut(duration: 0.12)) {
                    puckState = .relocating
                }
                SwipePadDiagnostics.verbose(
                    "press#\(diagnosticPressID) transition=relocating distance=\(Int(distance.rounded()))"
                )
            } else if distance >= 24 {
                relocateCheckTask?.cancel()
                // Re-baseline the guard key at the moment petals become
                // visible — but only onto a live hook state. See
                // SwipePadFireGuard.keyAtRadialOpen for why hook→nil must
                // keep the touch-down key (stale-resolver fire hole).
                pressHookStateKey = SwipePadFireGuard.keyAtRadialOpen(
                    currentKey: hookStateKey,
                    pressedKey: pressHookStateKey
                )
                withAnimation(.easeInOut(duration: 0.12)) {
                    puckState = .radialOpen
                    petalVisible = true
                }
                let presentation = SwipePadPetalLayout.presentation(
                    directions: currentPetals.map(\.direction),
                    puckCenter: position,
                    canvasSize: canvasSize,
                    diameter: diameter
                )
                SwipePadDiagnostics.verbose(
                    "press#\(diagnosticPressID) transition=radial-open distance=\(Int(distance.rounded())) presentation=\(presentation) profile=\(profileDiagnostic(activeProfile))"
                )
            }
        }

        if puckState == .radialOpen {
            let nextDirection = resolvedDirection(for: value.translation)
            if nextDirection != activeDirection {
                SwipePadDiagnostics.verbose(
                    "press#\(diagnosticPressID) direction=\(String(describing: nextDirection)) distance=\(Int(distance.rounded()))"
                )
            }
            activeDirection = nextDirection
        }
    }

    private func handleDragEnded() {
        SwipePadDiagnostics.verbose(
            "press#\(diagnosticPressID) end state=\(puckState) direction=\(String(describing: activeDirection)) profile=\(profileDiagnostic(activeProfile)) doubleTapped=\(doubleTapped) translation=(\(Int(totalTranslation.width.rounded())),\(Int(totalTranslation.height.rounded())))"
        )

        if doubleTapped {
            SwipePadDiagnostics.log("press#\(diagnosticPressID) no-fire reason=double-tap")
            resetGestureState()
            return
        }

        switch puckState {
        case .relocating:
            let proposed = CGPoint(
                x: position.x + totalTranslation.width,
                y: position.y + totalTranslation.height
            )
            onRelocate(proposed)
            resetGestureState()
        case .radialOpen:
            if let activeDirection,
               let model = currentPetals.first(where: { $0.direction == activeDirection })
            {
                if case .showMore = model.action {
                    // Opening Agent Center sends zero bytes — never worth a
                    // false refusal, so it bypasses the fire guard.
                    SwipePadDiagnostics.log(
                        "press#\(diagnosticPressID) fire direction=\(activeDirection.rawValue) source=hook action=show-more"
                    )
                    onShowMore?()
                } else if !SwipePadFireGuard.allowsFire(
                    pressedKey: pressHookStateKey,
                    releaseKey: hookStateKey
                ) {
                    // Remote state moved between press-begin and release
                    // (prompt answered elsewhere, turn ended, options
                    // changed). The visible petals no longer match what the
                    // user aimed at — refuse rather than fire a stale
                    // answer. Keys can embed prompt text — verbose only.
                    SwipePadDiagnostics.log(
                        "press#\(diagnosticPressID) no-fire reason=hook-state-changed"
                    )
                    SwipePadDiagnostics.verbose(
                        "press#\(diagnosticPressID) no-fire detail pressed=\(pressHookStateKey ?? "nil") current=\(hookStateKey ?? "nil")"
                    )
                } else if case .macro(let spec) = model.action {
                    SwipePadDiagnostics.log(
                        "press#\(diagnosticPressID) fire direction=\(activeDirection.rawValue) source=\(hookSnapshot != nil ? "hook" : "profile") macroBytes=\(spec.utf8.count)"
                    )
                    onFireMacro(spec)
                }
            } else {
                SwipePadDiagnostics.log(
                    "press#\(diagnosticPressID) no-fire reason=missing-direction-or-petal direction=\(String(describing: activeDirection)) source=\(hookSnapshot != nil ? "hook" : "profile")"
                )
            }
            resetGestureState()
        case .idle, .pressing:
            SwipePadDiagnostics.log("press#\(diagnosticPressID) no-fire reason=ended-before-radial")
            resetGestureState()
        }
    }

    private func beginPress() {
        diagnosticPressID += 1
        let pressID = diagnosticPressID
        let cachedProfile = resolver.currentProfile
        pressStartedAt = .now
        puckState = .pressing
        totalTranslation = .zero
        activeDirection = nil
        petalVisible = false
        activeProfile = cachedProfile
        pressHookStateKey = hookStateKey

        if hookSnapshot != nil {
            // Hook mode: petals come from the live snapshot — no remote
            // process resolution round trip for this press.
            SwipePadDiagnostics.verbose(
                "press#\(pressID) begin source=hook state=\(pressHookStateKey ?? "nil")"
            )
        } else {
            SwipePadDiagnostics.verbose(
                "press#\(pressID) begin tmux.mode=\(tmux.mode) cachedProfile=\(profileDiagnostic(cachedProfile)) providerPresent=\(processNameProvider != nil) profiles=\(profilesDiagnostic())"
            )

            resolver.resolveActiveProfile(
                tmux: tmux,
                store: profileStore,
                processNameProvider: processNameProvider,
                paneProcessNameProvider: paneProcessNameProvider
            ) { profile in
                let previousProfile = activeProfile
                activeProfile = profile
                SwipePadDiagnostics.verbose(
                    "press#\(pressID) resolved profile=\(profileDiagnostic(profile)) previous=\(profileDiagnostic(previousProfile)) state=\(puckState) direction=\(String(describing: activeDirection))"
                )
            }
        }

        relocateCheckTask?.cancel()
        relocateCheckTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            if puckState == .pressing && magnitude(totalTranslation) < 6 {
                withAnimation(.easeInOut(duration: 0.12)) {
                    puckState = .relocating
                }
                SwipePadDiagnostics.log("press#\(pressID) transition=relocating timer")
            }
        }
    }

    private func handleDoubleTap() {
        guard !isDictating else {
            dictationController.stop(commit: true)
            return
        }

        // The Experimental settings "on-device dictation" toggle is a real
        // off switch: when off, the double-tap must never touch the mic.
        guard appearance.voiceDictationEnabled else { return }

        doubleTapped = true
        resetGestureState(clearDoubleTap: false)
        Task {
            await dictationController.start()
            try? await Task.sleep(for: .milliseconds(250))
            await MainActor.run {
                doubleTapped = false
            }
        }
    }

    private func resetGestureState(clearDoubleTap: Bool = true) {
        relocateCheckTask?.cancel()
        relocateCheckTask = nil

        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            puckState = .idle
            totalTranslation = .zero
            activeDirection = nil
            petalVisible = false
        }

        pressStartedAt = nil
        if clearDoubleTap {
            doubleTapped = false
        }
    }

    private func profileDiagnostic(_ profile: SwipePadProfile?) -> String {
        guard let profile else { return "nil" }
        let directions = profile.visibleDirections.map(\.rawValue).joined(separator: ",")
        return "id=\(String(profile.id.uuidString.prefix(8))) builtIn=\(profile.isBuiltIn) fallback=\(profile.id == SwipePadProfile.fallbackID) matcherPresent=\(!profile.matchProcess.isEmpty) directions=[\(directions)]"
    }

    private func profilesDiagnostic() -> String {
        let customCount = profileStore.profiles.filter { !$0.isBuiltIn }.count
        let matcherCount = profileStore.profiles.filter { !$0.matchProcess.isEmpty }.count
        return "count=\(profileStore.profiles.count) custom=\(customCount) matchers=\(matcherCount)"
    }

    /// Sector math must match what the open radial is showing: the fan
    /// quantizes to its 30° slots; cross AND chip modes quantize to the
    /// cardinal quadrants (chip rows state cardinal arrows). Uses the same
    /// presentation decision as radialLayer, so aim and rendering can never
    /// disagree.
    private func resolvedDirection(for translation: CGSize) -> SwipeDirection? {
        guard magnitude(translation) >= 24 else { return nil }
        if case .fan(let quadrant) = SwipePadPetalLayout.presentation(
            directions: currentPetals.map(\.direction),
            puckCenter: position,
            canvasSize: canvasSize,
            diameter: diameter
        ) {
            return SwipePadPetalLayout.fanDirection(
                for: translation,
                directions: currentPetals.map(\.direction),
                quadrant: quadrant
            )
        }
        return direction(for: translation)
    }

    private func direction(for translation: CGSize) -> SwipeDirection? {
        guard magnitude(translation) >= 24 else { return nil }

        let angle = atan2(translation.height, translation.width)
        let quarter = CGFloat.pi / 4

        if angle >= -quarter && angle < quarter {
            return .right
        } else if angle >= quarter && angle < 3 * quarter {
            return .down
        } else if angle <= -quarter && angle > -3 * quarter {
            return .up
        } else {
            return .left
        }
    }

    private func tintColor(_ tint: SwipePadPetalModel.Tint) -> Color {
        switch tint {
        case .affirmative: return SwipePadPalette.green
        case .negative: return SwipePadPalette.red
        case .caution: return SwipePadPalette.amber
        case .neutral: return T.accent
        }
    }

    private func symbol(for model: SwipePadPetalModel) -> String {
        if model.action == .showMore { return "ellipsis" }
        switch model.tint {
        case .affirmative: return "checkmark"
        case .negative: return "xmark"
        case .caution: return "exclamationmark"
        case .neutral: return "arrow.turn.down.left"
        }
    }

    private func displayMacro(_ macro: String) -> String {
        macro
            .replacingOccurrences(of: "shift-tab", with: "⇧ tab")
            .replacingOccurrences(of: "↵", with: " ↵")
    }

    private func pulsingDot(size: CGFloat) -> some View {
        Circle()
            .fill(Color.red)
            .frame(width: size, height: size)
            .shadow(color: Color.red.opacity(0.8), radius: 6)
            .scaleEffect(pulse ? 1.0 : 0.85)
            .onAppear(perform: startPulse)
    }

    private func startPulse() {
        // Reduce Motion and the automation gate both stop this repeatForever
        // — it drives the dictation dot/ring, and a forever animation blocks
        // UI-automation quiescence besides the a11y concern.
        guard !reduceMotion, !SwipePadMotion.staticRings else { return }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }

    private var transcriptWidth: CGFloat {
        min(320, max(180, canvasSize.width - 44))
    }

    private func caretIsVisible(at date: Date) -> Bool {
        Int(date.timeIntervalSinceReferenceDate / 0.85).isMultiple(of: 2)
    }

    private func elapsedText(at date: Date) -> String {
        let start = dictationController.startedAt ?? date
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func magnitude(_ translation: CGSize) -> CGFloat {
        sqrt(translation.width * translation.width + translation.height * translation.height)
    }
}
