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
    @Bindable var profileStore: SwipePadProfileStore
    @Bindable var dictationController: SpeechDictationController

    @Environment(AppearancePreferences.self) private var appearance
    @State private var puckPosition: CGPoint = .zero
    @State private var hasInitializedPosition = false
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
        profileStore: SwipePadProfileStore,
        dictationController: SpeechDictationController
    ) {
        self.onSend = onSend
        self.tmux = tmux
        self.outputActivityToken = outputActivityToken
        self.processNameProvider = processNameProvider
        self.paneProcessNameProvider = paneProcessNameProvider
        self.profileStore = profileStore
        self.dictationController = dictationController
    }

    var body: some View {
        if !appearance.swipePadEnabled {
            EmptyView()
        } else {
            GeometryReader { proxy in
                let canvasSize = proxy.size
                let diameter = Self.diameter(for: appearance.swipePadSize)

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    configureDictationCommit()
                    syncPosition(
                        in: canvasSize,
                        diameter: diameter,
                        animated: false,
                        force: !hasInitializedPosition
                    )
                }
                .task {
                    // Light background polling so the puck's at-rest "matched"
                    // indicator updates without requiring a press. The
                    // output-activity task below handles bursty changes; this
                    // loop is the quiet fallback and the active-profile stale
                    // state cleanup path.
                    while !Task.isCancelled {
                        SwipePadDiagnostics.log(
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
                        SwipePadDiagnostics.log(
                            "refresh-sleep source=poll interval=\(intervalSeconds)s currentProfile=\(Self.profileDiagnostic(resolver.currentProfile))"
                        )
                        try? await Task.sleep(for: .seconds(intervalSeconds))
                    }
                }
                .task(id: outputActivityToken) {
                    guard outputActivityToken != 0 else { return }
                    SwipePadDiagnostics.log(
                        "refresh-window source=output token=\(outputActivityToken) ticks=3"
                    )
                    for tick in 0..<3 {
                        guard !Task.isCancelled else { return }
                        SwipePadDiagnostics.log(
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
                    let newDiameter = Self.diameter(for: appearance.swipePadSize)
                    syncPosition(
                        in: canvasSize,
                        diameter: newDiameter,
                        animated: true,
                        force: true
                    )
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
        return resolvedCornerPosition(
            appearance.swipePadCorner,
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
    /// No additional inset — letting the user park flush against the edge
    /// is part of the "drop where you want" UX.
    private func clampedPosition(_ point: CGPoint, in size: CGSize, diameter: CGFloat) -> CGPoint {
        let radius = diameter / 2
        let minX = radius
        let maxX = max(radius, size.width - radius)
        let minY = radius
        let maxY = max(radius, size.height - radius)
        return CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }

    private func resolvedCornerPosition(_ corner: String, in size: CGSize, diameter: CGFloat) -> CGPoint {
        let edgeInset: CGFloat = 22
        let radius = diameter / 2

        switch corner {
        case "topLeft":
            return CGPoint(x: edgeInset + radius, y: edgeInset + radius)
        case "topRight":
            return CGPoint(x: size.width - edgeInset - radius, y: edgeInset + radius)
        case "bottomLeft":
            return CGPoint(x: edgeInset + radius, y: size.height - edgeInset - radius)
        default:
            return CGPoint(x: size.width - edgeInset - radius, y: size.height - edgeInset - radius)
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
