// Tessera/SwipePad/SwipePadOverlay.swift
// Floating swipe-pad overlay entry point.
import SwiftUI
import TmuxControl

struct SwipePadOverlay: View {
    let onSend: ([UInt8]) -> Void
    let tmux: TmuxController
    let outputActivityToken: Int
    let processNameProvider: SwipePadProcessNameProvider?
    let paneProcessNameProvider: SwipePadPaneProcessNameProvider?
    /// Hook-proof projection for this session; nil (previews, harnesses)
    /// keeps the pad permanently in resolver fallback mode.
    let agentContext: SwipePadAgentContext?
    /// Whether this session view is the selected, visible one. Hidden
    /// sessions stay mounted at opacity 0; their pads must not poll.
    let sessionIsActive: Bool
    /// Opens the Agent Center surface — fired by the "more" petal when a
    /// prompt has more options than the radial can hold.
    let onShowMore: (() -> Void)?
    @Bindable var profileStore: SwipePadProfileStore
    @Bindable var dictationController: SpeechDictationController

    @Environment(AppearancePreferences.self) private var appearance
    // \.scenePhase does not reliably reach nested session views (see the
    // SessionView app-phase note); the root-injected AppPhase does.
    @Environment(AppPhase.self) private var appPhase
    @State private var puckPosition: CGPoint = .zero
    @State private var hasInitializedPosition = false
    @State private var softwareKeyboardVisible = false
    /// One resolver per overlay lifetime — kept as @State so its
    /// `currentProfile` publication survives view re-renders and drives
    /// the puck's at-rest "matched" indicator via the .task polling
    /// loop below.
    @State private var resolver = SwipePadActiveProfileResolver()

    init(
        onSend: @escaping ([UInt8]) -> Void,
        tmux: TmuxController,
        outputActivityToken: Int = 0,
        processNameProvider: SwipePadProcessNameProvider? = nil,
        paneProcessNameProvider: SwipePadPaneProcessNameProvider? = nil,
        agentContext: SwipePadAgentContext? = nil,
        sessionIsActive: Bool = true,
        onShowMore: (() -> Void)? = nil,
        profileStore: SwipePadProfileStore,
        dictationController: SpeechDictationController
    ) {
        self.onSend = onSend
        self.tmux = tmux
        self.outputActivityToken = outputActivityToken
        self.processNameProvider = processNameProvider
        self.paneProcessNameProvider = paneProcessNameProvider
        self.agentContext = agentContext
        self.sessionIsActive = sessionIsActive
        self.onShowMore = onShowMore
        self.profileStore = profileStore
        self.dictationController = dictationController
    }

    private var hookSnapshot: SwipePadAgentSnapshot? { agentContext?.snapshot }

    /// Resolver polling runs only when every gate is open: no hook proof
    /// (lifecycle events replace discovery entirely), the session visible,
    /// and the app foregrounded. Task identity — any flip restarts or stops
    /// the loop immediately.
    private struct PollingKey: Equatable {
        let hookActive: Bool
        let sessionActive: Bool
        let sceneActive: Bool

        var allowsPolling: Bool { !hookActive && sessionActive && sceneActive }
    }

    private var pollingKey: PollingKey {
        PollingKey(
            hookActive: hookSnapshot != nil,
            sessionActive: sessionIsActive,
            sceneActive: appPhase.isActive
        )
    }

    /// Burst identity folds the gate in: a gate flip mid-burst (hook proof
    /// arriving, session hiding, backgrounding) cancels the remaining ticks
    /// instead of letting them fire remote probes the gate exists to stop.
    private struct BurstKey: Equatable {
        let token: Int
        let gate: PollingKey
    }

    var body: some View {
        if !appearance.swipePadEnabled {
            EmptyView()
        } else {
            GeometryReader { proxy in
                let canvasSize = proxy.size
                let configuredDiameter = Self.diameter(for: appearance.swipePadSize)
                let diameter = UIDevice.current.userInterfaceIdiom == .phone
                    ? min(configuredDiameter, 52)
                    : configuredDiameter

                Group {
                    if compactLandscapeKeyboardActive(in: canvasSize) {
                        Color.clear
                            .allowsHitTesting(false)
                    } else {
                        ZStack {
                            SwipePadView(
                                diameter: diameter,
                                position: puckPosition,
                                canvasSize: canvasSize,
                                resolver: resolver,
                                tmux: tmux,
                                processNameProvider: processNameProvider,
                                paneProcessNameProvider: paneProcessNameProvider,
                                profileStore: profileStore,
                                dictationController: dictationController,
                                hookSnapshot: hookSnapshot,
                                agentContext: agentContext,
                                onShowMore: onShowMore,
                                sessionIsActive: sessionIsActive,
                                onFireMacro: fireMacro(_:),
                                onRelocate: { proposedPosition in
                                    relocate(
                                        proposedPosition,
                                        in: canvasSize,
                                        diameter: diameter
                                    )
                                }
                            )
                            .position(x: puckPosition.x, y: puckPosition.y)
                            .transition(.scale(scale: 0.82).combined(with: .opacity))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    configureDictationCommit()
                    resolver.setSuspended(!pollingKey.allowsPolling)
                    syncPosition(
                        in: canvasSize,
                        diameter: diameter,
                        animated: false,
                        force: !hasInitializedPosition
                    )
                }
                .onDisappear {
                    // Hidden sessions keep this overlay mounted (opacity 0),
                    // so this fires only on true teardown or the SwipePad
                    // feature toggling off. Either way the surface is gone:
                    // close the gate so any still-in-flight async work (the
                    // VoiceOver fallback's resolution included) refuses
                    // instead of firing into it. onAppear re-syncs the gate
                    // if the overlay returns.
                    resolver.setSuspended(true)
                }
                .onChange(of: pollingKey) { oldKey, newKey in
                    // Suspension (not just task identity) closes the gate for
                    // work already queued or in flight: a coalesced refresh
                    // or a landing async query must neither reschedule nor
                    // publish once polling is stopped.
                    resolver.setSuspended(!newKey.allowsPolling)
                    if oldKey.hookActive, !newKey.hookActive {
                        // Hook proof vanished (agent exited, or focus moved
                        // to an unhooked pane). The profile the resolver
                        // retained from before hook mode describes the
                        // *previous* foreground program — an immediate
                        // gesture would fire its macro into the new one.
                        // Show nothing until a fresh resolution lands.
                        resolver.invalidate(reason: "hook-mode-ended")
                    }
                }
                .task(id: pollingKey) {
                    // Light background polling so the puck's at-rest "matched"
                    // indicator updates without requiring a press. The
                    // output-activity task below handles bursty changes; this
                    // loop is the quiet fallback and the active-profile stale
                    // state cleanup path. Hook mode and hidden/backgrounded
                    // sessions run zero iterations — lifecycle events (or
                    // nothing) drive them, not remote probes.
                    guard pollingKey.allowsPolling else { return }
                    while !Task.isCancelled {
                        SwipePadDiagnostics.verbose(
                            "refresh-trigger source=poll tmux.mode=\(tmux.mode) activeWindow=\(String(describing: tmux.activeWindowId)) activePane=\(String(describing: tmux.activePaneId)) currentProfile=\(Self.profileDiagnostic(resolver.currentProfile))"
                        )
                        resolver.refresh(
                            tmux: tmux,
                            store: profileStore,
                            processNameProvider: processNameProvider,
                            paneProcessNameProvider: paneProcessNameProvider
                        )
                        let intervalSeconds: Int
                        if let profile = resolver.currentProfile,
                           !profile.matchProcess.isEmpty {
                            intervalSeconds = 1
                        } else {
                            intervalSeconds = 5
                        }
                        SwipePadDiagnostics.verbose(
                            "refresh-sleep source=poll interval=\(intervalSeconds)s currentProfile=\(Self.profileDiagnostic(resolver.currentProfile))"
                        )
                        try? await Task.sleep(for: .seconds(intervalSeconds))
                    }
                }
                .task(id: BurstKey(token: outputActivityToken, gate: pollingKey)) {
                    guard outputActivityToken != 0, pollingKey.allowsPolling else { return }
                    SwipePadDiagnostics.verbose(
                        "refresh-window source=output token=\(outputActivityToken) ticks=3"
                    )
                    for tick in 0..<3 {
                        guard !Task.isCancelled else { return }
                        SwipePadDiagnostics.verbose(
                            "refresh-trigger source=output token=\(outputActivityToken) tick=\(tick)"
                        )
                        resolver.refresh(
                            tmux: tmux,
                            store: profileStore,
                            processNameProvider: processNameProvider,
                            paneProcessNameProvider: paneProcessNameProvider
                        )
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                .onChange(of: canvasSize) { _, newSize in
                    // On orientation / size change: re-clamp the saved position
                    // (or apply the corner fallback if no position saved).
                    syncPosition(
                        in: newSize,
                        diameter: diameter,
                        animated: false,
                        force: true
                    )
                }
                .onChange(of: appearance.swipePadCorner) { _, _ in
                    // User explicitly picked a new "default corner" in settings.
                    // Clear the freeform position so the puck snaps to the new
                    // corner and stays there until next manual drag.
                    appearance.swipePadLastX = -1
                    appearance.swipePadLastY = -1
                    syncPosition(
                        in: canvasSize,
                        diameter: diameter,
                        animated: true,
                        force: true
                    )
                }
                .onChange(of: appearance.swipePadSize) { _, _ in
                    let configuredDiameter = Self.diameter(for: appearance.swipePadSize)
                    let newDiameter = UIDevice.current.userInterfaceIdiom == .phone
                        ? min(configuredDiameter, 52)
                        : configuredDiameter
                    syncPosition(
                        in: canvasSize,
                        diameter: newDiameter,
                        animated: true,
                        force: true
                    )
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIResponder.keyboardWillChangeFrameNotification
                    )
                ) { notification in
                    guard let frame = notification.userInfo?[
                        UIResponder.keyboardFrameEndUserInfoKey
                    ] as? CGRect else { return }
                    softwareKeyboardVisible = frame.minY < UIScreen.main.bounds.maxY - 1
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIResponder.keyboardWillHideNotification
                    )
                ) { _ in
                    softwareKeyboardVisible = false
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.72), value: appearance.swipePadEnabled)
        }
    }

    private func configureDictationCommit() {
        dictationController.onCommit = { text in
            let suffix: [UInt8] = appearance.voiceAppendReturn ? [0x0D] : []
            onSend(Array(text.utf8) + suffix)
        }
    }

    private func compactLandscapeKeyboardActive(in size: CGSize) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone
            && softwareKeyboardVisible
            && size.width > size.height
    }

    private func fireMacro(_ spec: String) {
        let bytes = MacroEncoder.encode(spec)
        guard !bytes.isEmpty else { return }
        onSend(bytes)
    }

    private func syncPosition(
        in size: CGSize,
        diameter: CGFloat,
        animated: Bool,
        force: Bool
    ) {
        guard force || !hasInitializedPosition else { return }
        let target = currentResolvedPosition(in: size, diameter: diameter)
        hasInitializedPosition = true

        if animated {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                puckPosition = target
            }
        } else {
            puckPosition = target
        }
    }

    /// Resolve the puck's resting position. Priority:
    ///   1. Last freeform drop position (clamped to canvas bounds), if saved.
    ///   2. The cold-launch corner from settings.
    private func currentResolvedPosition(in size: CGSize, diameter: CGFloat) -> CGPoint {
        if appearance.swipePadLastX >= 0 && appearance.swipePadLastY >= 0 {
            return clampedPosition(
                CGPoint(
                    x: CGFloat(appearance.swipePadLastX),
                    y: CGFloat(appearance.swipePadLastY)
                ),
                in: size,
                diameter: diameter
            )
        }
        return clampedPosition(
            resolvedCornerPosition(
                appearance.swipePadCorner,
                in: size,
                diameter: diameter
            ),
            in: size,
            diameter: diameter
        )
    }

    /// Called when the user releases a long-press-drag. Keep the puck where
    /// they dropped it; only clamp if part of the puck would clip a canvas
    /// edge. The clamped center is then persisted so the next launch /
    /// orientation change picks up the same spot (re-clamped to fit).
    private func relocate(_ proposedPosition: CGPoint, in size: CGSize, diameter: CGFloat) {
        let clamped = clampedPosition(proposedPosition, in: size, diameter: diameter)

        appearance.swipePadLastX = Double(clamped.x)
        appearance.swipePadLastY = Double(clamped.y)

        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            puckPosition = clamped
        }
    }

    /// Clamp a candidate puck center so the full puck stays on-screen.
    /// Phone keeps the bottom edge above the one-swipe home-indicator zone;
    /// the other edges and iPad remain flush-capable.
    private func clampedPosition(_ point: CGPoint, in size: CGSize, diameter: CGFloat) -> CGPoint {
        let radius = diameter / 2
        let bottomClearance: CGFloat = UIDevice.current.userInterfaceIdiom == .phone
            ? 34
            : 0
        let minX = radius
        let maxX = max(radius, size.width - radius)
        let minY = radius
        let maxY = max(radius, size.height - radius - bottomClearance)
        return CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }

    private func resolvedCornerPosition(_ corner: String, in size: CGSize, diameter: CGFloat) -> CGPoint {
        // Phone: home at the actual corner — the fan presentation keeps the
        // petals on-canvas there, so the puck no longer needs the cross's
        // mid-screen insets. The bottom edge intentionally overshoots and
        // lets clampedPosition apply its home-indicator clearance, keeping
        // that constant in one place.
        if UIDevice.current.userInterfaceIdiom == .phone {
            let inset = SwipePadPetalLayout.fanCornerInset(puckDiameter: diameter)
            let x = corner.hasSuffix("Left") ? inset : size.width - inset
            let y = corner.hasPrefix("top") ? inset : size.height
            return CGPoint(x: x, y: y)
        }

        // iPad: unchanged — the cross radial fits at these insets, and the
        // trained cardinal gestures stay primary at home.
        let insets = SwipePadPetalLayout.radialCenterInsets(
            directions: SwipePadPetalLayout.directionOrder,
            diameter: diameter
        )

        switch corner {
        case "topLeft":
            return CGPoint(x: insets.leading, y: insets.top)
        case "topRight":
            return CGPoint(x: size.width - insets.trailing, y: insets.top)
        case "bottomLeft":
            return CGPoint(x: insets.leading, y: size.height - insets.bottom)
        default:
            return CGPoint(
                x: size.width - insets.trailing,
                y: size.height - insets.bottom
            )
        }
    }

    private static func profileDiagnostic(_ profile: SwipePadProfile?) -> String {
        guard let profile else {
            return "nil"
        }
        return "id:\(String(profile.id.uuidString.prefix(8))),builtIn:\(profile.isBuiltIn),matcher:\(!profile.matchProcess.isEmpty)"
    }

    private static func diameter(for size: String) -> CGFloat {
        switch size {
        case "compact":
            return 44
        case "large":
            return 64
        default:
            return 52
        }
    }
}
