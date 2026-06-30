// Tessera/SessionLaunchOverlay.swift
//
// Unified launch-loading overlay used by both SSH (`SessionView`) and
// mosh (`MoshSessionView`). Replaces the v1 `TmuxLaunchLoadingOverlay`
// (stock iOS spinner) with a branded surface: Tessera mark with a
// breathing accent glow + blinking inner cursor, a crossfading phase
// caption that names what we're waiting on, an optional sub-line
// (typically the tmux session name), and an indeterminate accent bar.
//
// All phases are mapped to actually observable transitions in the
// session/tmux state machines (see the unified-overlay plan):
//   - `.connecting`           — session.state == .connecting (SSH
//                               handshake / mosh bootstrap + UDP).
//   - `.startingTmux`         — SSH+tmux only: .connected, awaiting
//                               tmux DCS prologue.
//   - `.attachingTmuxChannel` — mosh+tmux only: .connected, mosh
//                               side-channel SSH still connecting.
//   - `.attachingPane`        — tmux.mode == .tmuxControl but no real
//                               pane bytes have rendered yet.
//
// The overlay is presentation-only; both views compute the active
// phase and pass it in, and both dismiss the overlay on their own
// readiness signal.
import SwiftUI

enum SessionLaunchPhase: Equatable {
    case connecting
    case startingTmux
    case attachingTmuxChannel
    case attachingPane

    /// Lowercase mono caption shown under the mark. Kept short so the
    /// crossfade reads as a single line at the overlay's 14pt size.
    var caption: String {
        switch self {
        case .connecting:           return "connecting"
        case .startingTmux:         return "starting tmux"
        case .attachingTmuxChannel: return "attaching tmux"
        case .attachingPane:        return "attaching pane"
        }
    }
}

/// The hero loading surface itself. Themed against `DesignTokens` so
/// it blends with whatever `TerminalTheme` is active. Caller is
/// responsible for opacity / fade transitions when mounting/unmounting.
struct SessionLaunchOverlay: View {
    let T: DesignTokens
    let phase: SessionLaunchPhase
    /// Optional second-line caption; typically the resolved tmux
    /// session name for tmux modes, nil for plain shells. Reserves
    /// layout space even when nil so the caption block height is
    /// stable as the overlay transitions through phases.
    let subtitle: String?

    /// When non-nil the overlay renders its terminal/error state instead
    /// of the loading state: the connect attempt failed before reaching
    /// `.connected`. The overlay stays up (the owning view stops
    /// dismissing on `.failed`) so the dead shell never flashes through,
    /// and the reason is shown here with recovery actions rather than as
    /// a red string jammed into the top bar.
    var failureReason: String? = nil
    /// Open the host editor (where the identity/key is chosen).
    var onEditHost: () -> Void = {}
    /// Tear down the failed session and reconnect with the same settings.
    var onRetry: () -> Void = {}
    /// Drop the failed session and return to the host list.
    var onBack: () -> Void = {}

    var body: some View {
        ZStack {
            T.bg

            if let failureReason {
                LaunchOverlayFailure(
                    T: T,
                    reason: failureReason,
                    onEditHost: onEditHost,
                    onRetry: onRetry,
                    onBack: onBack
                )
            } else {
                VStack(spacing: 28) {
                    LaunchOverlayMark(T: T)
                        .frame(width: 64, height: 64)

                    LaunchOverlayCaption(T: T, phase: phase, subtitle: subtitle)

                    LaunchOverlayIndeterminateBar(T: T)
                        .frame(width: 200, height: 2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("connecting — \(phase.caption)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - failure state

/// Error layout shown when the connect attempt fails. Mirrors the
/// loading layout's centered rhythm (64pt mark, 28pt spacing, mono
/// captions) so it reads as the same surface "stopping" rather than a
/// different screen. The mark is the static Tessera mark with the inner
/// cursor tinted red — no breathing halo, no blink.
private struct LaunchOverlayFailure: View {
    let T: DesignTokens
    let reason: String
    let onEditHost: () -> Void
    let onRetry: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            BlinkingMark(T: T, size: 64, cursorOpacity: 1.0, cursorColor: T.red)
                .frame(width: 64, height: 64)

            VStack(spacing: 10) {
                Text("connection failed")
                    .font(Typography.tesseraMono(size: 14))
                    .foregroundStyle(T.fg)

                Text(reason)
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 12) {
                Btn("edit host", style: .primary, action: onEditHost)
                Btn("retry", action: onRetry)
                Btn("back", action: onBack)
            }
            // Btn reads its palette from the environment; the overlay is
            // handed theme-derived chrome tokens explicitly (not via the
            // environment), so scope them here or the buttons would use
            // the app-level tokens instead of the active terminal theme's.
            .environment(\.designTokens, T)
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("connection failed. \(reason)")
    }
}

// MARK: - mark + breathing glow + blinking cursor

/// The 64pt Tessera mark with two animations:
///   - The accent halo behind the mark breathes in/out on a 2.4s loop.
///   - The inner cursor square inside the mark blinks at the typical
///     terminal cursor cadence (~0.55s on / 0.55s off via opacity).
///
/// Geometry mirrors `TesseraLogo` exactly (140-viewbox; outer rect at
/// 22,22 size 96×96 corner 22; inner at 34,34 size 26×26 corner 5).
/// We don't reuse `TesseraLogo` directly because its inner cursor is
/// fixed; here it has to blink.
private struct LaunchOverlayMark: View {
    let T: DesignTokens

    @State private var glowOn = false
    @State private var cursorOn = true

    var body: some View {
        ZStack {
            // breathing accent halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [T.accent.opacity(0.30), T.accent.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 52
                    )
                )
                .frame(width: 104, height: 104)
                .opacity(glowOn ? 0.85 : 0.35)
                .scaleEffect(glowOn ? 1.05 : 0.92)

            // mark — single Path-based view so the layout box is
            // exactly 64×64 with no padding gymnastics. Both shapes
            // draw into the same 140-viewbox at the size's scale,
            // matching `TesseraLogo`'s coordinate system.
            BlinkingMark(T: T, size: 64, cursorOpacity: cursorOn ? 1.0 : 0.25)
        }
        .frame(width: 104, height: 104)      // halo footprint; mark sits centered
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                glowOn = true
            }
            // ~0.55s on, 0.55s off — slightly slower than xterm's default
            // 530ms blink so it reads as deliberate, not jittery.
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                cursorOn = false
            }
        }
    }
}

/// Path-based Tessera mark with an animatable inner cursor opacity.
/// Layout box is exactly `size × size`; both shapes position inside
/// the implicit 140-viewbox via raw `addRoundedRect` calls, so the
/// view centers naturally inside any parent without needing padding.
private struct BlinkingMark: View {
    let T: DesignTokens
    let size: CGFloat
    let cursorOpacity: Double
    /// Inner cursor fill. Defaults to the accent (loading state); the
    /// failure state overrides it to `T.red`.
    var cursorColor: Color? = nil

    var body: some View {
        let scale = size / 140

        ZStack {
            Path { path in
                path.addRoundedRect(
                    in: CGRect(
                        x: 22 * scale,
                        y: 22 * scale,
                        width: 96 * scale,
                        height: 96 * scale
                    ),
                    cornerSize: CGSize(width: 22 * scale, height: 22 * scale),
                    style: .continuous
                )
            }
            .fill(T.fg)

            Path { path in
                path.addRoundedRect(
                    in: CGRect(
                        x: 34 * scale,
                        y: 34 * scale,
                        width: 26 * scale,
                        height: 26 * scale
                    ),
                    cornerSize: CGSize(width: 5 * scale, height: 5 * scale),
                    style: .continuous
                )
            }
            .fill(cursorColor ?? T.accent)
            .opacity(cursorOpacity)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - phase caption + sub-line

/// Two-line caption block under the mark. The phase line crossfades on
/// every change (`.id(phase)` re-mounts the Text so SwiftUI's identity
/// transition fires). The sub-line stays put — typically the tmux
/// session name we're attaching to.
private struct LaunchOverlayCaption: View {
    let T: DesignTokens
    let phase: SessionLaunchPhase
    let subtitle: String?

    var body: some View {
        VStack(spacing: 10) {
            Text(phase.caption)
                .font(Typography.tesseraMono(size: 14))
                .foregroundStyle(T.fg)
                .id(phase)
                .transition(.opacity)

            // Reserve space even when subtitle is nil so the layout
            // doesn't reflow on phases that don't need a second line.
            Text(subtitle ?? " ")
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)
                .opacity(subtitle == nil ? 0 : 1)
        }
        .frame(minHeight: 44)
        // Animation context for the .id(phase) → .transition(.opacity)
        // crossfade lives on the enclosing VStack so it actually wraps
        // the identity change. Putting `.animation(value:)` on the Text
        // itself doesn't work because the Text is replaced (not
        // mutated) when its id changes — the modifier comes with the
        // new instance and can't animate the old one out.
        .animation(.easeInOut(duration: 0.22), value: phase)
    }
}

// MARK: - indeterminate accent bar

/// 200×2pt slider driven off real time via `TimelineView` so the
/// slide loop is smooth and has no visible reset frame.
///
/// `withAnimation { x = end }.repeatForever(autoreverses: false)`
/// looks fine for a single cycle, but at each cycle boundary SwiftUI
/// snaps the animated property back to its original value before
/// starting the next iteration; that snap is rendered visibly as a
/// 1-frame backwards jump. Computing the offset from `context.date`
/// instead lets the bar wrap around in continuous time — the same
/// modulo trick TimelineView is designed for.
private struct LaunchOverlayIndeterminateBar: View {
    let T: DesignTokens

    /// Time-zero anchor captured on first body evaluation so the bar
    /// always starts fully off-screen left, not at a random phase
    /// inherited from `Date.timeIntervalSinceReferenceDate`.
    @State private var startDate = Date()

    private static let cycleSeconds: Double = 1.6
    /// Pill width as a fraction of the track.
    private static let pillFraction: CGFloat = 0.40

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geo in
                let trackWidth = geo.size.width
                let pillWidth  = trackWidth * Self.pillFraction

                let elapsed = context.date.timeIntervalSince(startDate)
                let progress = CGFloat(
                    (elapsed.truncatingRemainder(dividingBy: Self.cycleSeconds))
                        / Self.cycleSeconds
                )
                // Travel band: fully off-left (x = -pillWidth) to fully
                // off-right (x = trackWidth). Distance = trackWidth + pillWidth.
                let xOffset = -pillWidth + (trackWidth + pillWidth) * progress

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(T.fg.opacity(0.06))

                    Capsule()
                        .fill(T.accent.opacity(0.7))
                        .frame(width: pillWidth)
                        .offset(x: xOffset)
                }
            }
        }
    }
}
