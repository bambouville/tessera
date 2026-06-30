// Tessera/SwipePad/SwipePadView.swift
// Visible swipe-pad puck, radial macro launcher, and dictation surface.
import SwiftUI
import TmuxControl

private enum PuckState {
    case idle, pressing, relocating, radialOpen
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
    let onFireMacro: (String) -> Void
    let onRelocate: (CGPoint) -> Void

    @Environment(AppearancePreferences.self) private var appearance
    @Environment(\.designTokens) private var T

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

    var body: some View {
        ZStack {
            radialLayer
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
        .simultaneousGesture(doubleTapGesture)
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: controlSize)
        .animation(.easeInOut(duration: 0.12), value: puckState)
        .onDisappear {
            relocateCheckTask?.cancel()
        }
    }

    @ViewBuilder
    private var radialLayer: some View {
        if puckState == .radialOpen {
            if let activeDirection {
                Circle()
                    .fill(directionTint(activeDirection).opacity(0.2))
                    .frame(width: 80, height: 80)
                    .blur(radius: 20)
                    .offset(totalTranslation)
                    .allowsHitTesting(false)
            }

            if petalVisible, let activeProfile {
                ForEach(SwipeDirection.allCases, id: \.self) { direction in
                    let binding = activeProfile.binding(for: direction)
                    if binding.isBound {
                        petal(direction: direction, macro: binding.macro)
                            .offset(petalOffset(for: direction))
                            .transition(.scale(scale: 0.82).combined(with: .opacity))
                    }
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
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.white.opacity(0.7))
                }

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(dictationController.transcript)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)

                    TimelineView(.animation(minimumInterval: 0.85)) { context in
                        Text("|")
                            .font(.system(size: 13))
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
    ///   - matched profile (not fallback, not nil) → sparkles
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
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 12)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .contentShape(Circle())
        .onTapGesture {
            if isDictating {
                dictationController.stop(commit: true)
            }
        }
        .onAppear(perform: startPulse)
        .accessibilityLabel(accessibilityLabel)
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
        if matchedIndicatorVisible {
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
                    .monospacedDigit()
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel dictation")
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
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.13))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 12)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
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

    private func petal(direction: SwipeDirection, macro: String) -> some View {
        let isActive = activeDirection == direction
        let tint = directionTint(direction)
        // Petal sizes track the puck so the action targets feel like the
        // same visual family. Active petal swells by ~25% as the aim cue.
        let size: CGFloat = isActive ? diameter * 1.25 : diameter
        let glyphSize: CGFloat = isActive ? size * 0.42 : size * 0.36

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
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))

                if isActive {
                    Circle()
                        .fill(tint.opacity(0.35))
                }

                Image(systemName: petalSymbol(for: direction))
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

            VStack(spacing: 2) {
                Text(petalLabel(for: direction))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? tint : Color.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.7), radius: 2, y: 1)

                Text(displayMacro(macro))
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
            }
            .fixedSize()
            .offset(y: size / 2 + captionGap + 14)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.12), value: isActive)
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

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                handleDoubleTap()
            }
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
                SwipePadDiagnostics.log(
                    "press#\(diagnosticPressID) transition=relocating distance=\(Int(distance.rounded()))"
                )
            } else if distance >= 24 {
                relocateCheckTask?.cancel()
                withAnimation(.easeInOut(duration: 0.12)) {
                    puckState = .radialOpen
                    petalVisible = true
                }
                SwipePadDiagnostics.log(
                    "press#\(diagnosticPressID) transition=radial-open distance=\(Int(distance.rounded())) profile=\(profileDiagnostic(activeProfile))"
                )
            }
        }

        if puckState == .radialOpen {
            let nextDirection = direction(for: value.translation)
            if nextDirection != activeDirection {
                SwipePadDiagnostics.log(
                    "press#\(diagnosticPressID) direction=\(String(describing: nextDirection)) distance=\(Int(distance.rounded()))"
                )
            }
            activeDirection = nextDirection
        }
    }

    private func handleDragEnded() {
        SwipePadDiagnostics.log(
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
               let macro = activeProfile?.binding(for: activeDirection).macro
            {
                SwipePadDiagnostics.log(
                    "press#\(diagnosticPressID) fire direction=\(activeDirection.rawValue) macroEmpty=\(macro.isEmpty) macroBytes=\(macro.utf8.count) profile=\(profileDiagnostic(activeProfile))"
                )
                onFireMacro(macro)
            } else {
                SwipePadDiagnostics.log(
                    "press#\(diagnosticPressID) no-fire reason=missing-direction-or-profile direction=\(String(describing: activeDirection)) profile=\(profileDiagnostic(activeProfile))"
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

        SwipePadDiagnostics.log(
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
            SwipePadDiagnostics.log(
                "press#\(pressID) resolved profile=\(profileDiagnostic(profile)) previous=\(profileDiagnostic(previousProfile)) state=\(puckState) direction=\(String(describing: activeDirection))"
            )
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

    private func petalOffset(for direction: SwipeDirection) -> CGSize {
        // Keep a stable visual gap between puck edge and petal edge across
        // all puck sizes: gap = ~28pt. With petal size == puck diameter,
        // offset = puck-radius + gap + petal-radius = diameter + 28.
        let r = diameter + 28
        switch direction {
        case .up:
            return CGSize(width: 0, height: -r)
        case .right:
            return CGSize(width: r, height: 0)
        case .down:
            return CGSize(width: 0, height: r)
        case .left:
            return CGSize(width: -r, height: 0)
        }
    }

    private func directionTint(_ direction: SwipeDirection) -> Color {
        switch direction {
        case .right:
            return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .left:
            return Color(red: 1.0, green: 0.27, blue: 0.23)
        case .up:
            return Color(red: 1.0, green: 0.62, blue: 0.04)
        case .down:
            return T.accent
        }
    }

    private func petalSymbol(for direction: SwipeDirection) -> String {
        switch direction {
        case .right:
            return "checkmark"
        case .left:
            return "xmark"
        case .up:
            return "arrow.up"
        case .down:
            return "arrow.down"
        }
    }

    private func petalLabel(for direction: SwipeDirection) -> String {
        switch direction {
        case .right:
            return "approve"
        case .left:
            return "deny"
        case .up:
            return "always"
        case .down:
            return "down"
        }
    }

    private func displayMacro(_ macro: String) -> String {
        macro.replacingOccurrences(of: "↵", with: " ↵")
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
