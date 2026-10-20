import SwiftUI

struct StatusDot: View {
    var color: Color
    var pulse: Bool = false
    var size: CGFloat = 7

    @State private var animating: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // JSX uses tess-pulse keyframe (box-shadow ring); SwiftUI translates as opacity since replicating the box-shadow ring isn't worth the added complexity.
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulse ? (animating ? 1.0 : 0.4) : 1.0)
            .onAppear {
                // A static pulse holds the bright frame so the dot still
                // reads as live under DEBUG automation / Reduce Motion.
                guard pulse else { return }
                if reduceMotion || ContinuousMotion.isSuppressed {
                    animating = true
                    return
                }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    animating = true
                }
            }
    }
}

/// A connection dot that also carries a "needs attention" state. The dot keeps
/// its connection colour — amber on the dot already means connecting — and the
/// attention state is a ring around it instead. The ring arrives with three
/// ripples, then holds still: a one-time cue, never a continuous blink.
struct AttentionStatusDot: View {
    var color: Color
    var attention: Bool
    var attentionColor: Color
    var size: CGFloat = 7

    @State private var rippleTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ringDiameter: CGFloat { size + 6 }
    private var ringWidth: CGFloat { max(1.5, size * 0.2) }
    private var ringTransition: AnyTransition {
        reduceMotion || ContinuousMotion.isSuppressed
            ? .opacity
            : .scale(scale: 0.5).combined(with: .opacity)
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            // Overlays never take layout space, so the host label beside the
            // dot does not move when the ring comes or goes.
            .overlay {
                if attention {
                    ZStack {
                        Circle()
                            .strokeBorder(attentionColor, lineWidth: ringWidth)
                        Circle()
                            .strokeBorder(attentionColor, lineWidth: ringWidth)
                            .keyframeAnimator(
                                initialValue: Ripple(),
                                trigger: rippleTrigger
                            ) { ring, ripple in
                                ring.scaleEffect(ripple.scale).opacity(ripple.opacity)
                            } keyframes: { _ in
                                KeyframeTrack(\.scale) {
                                    Self.ripple(to: 2.2)
                                    Self.ripple(to: 2.2)
                                    Self.ripple(to: 2.2)
                                }
                                KeyframeTrack(\.opacity) {
                                    Self.ripple(from: 0.85)
                                    Self.ripple(from: 0.85)
                                    Self.ripple(from: 0.85)
                                }
                            }
                    }
                    .frame(width: ringDiameter, height: ringDiameter)
                    .transition(ringTransition)
                    // The ring and its ripple overflow the dot; taps there
                    // belong to whatever control sits underneath.
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .animation(.easeOut(duration: 0.2), value: attention)
            .onChange(of: attention) { _, isOn in
                guard isOn, !reduceMotion, !ContinuousMotion.isSuppressed else { return }
                rippleTrigger += 1
            }
    }

    private struct Ripple {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    @KeyframeTrackContentBuilder<CGFloat>
    private static func ripple(to scale: CGFloat) -> some KeyframeTrackContent<CGFloat> {
        MoveKeyframe(1)
        LinearKeyframe(scale, duration: 0.8, timingCurve: .easeOut)
    }

    @KeyframeTrackContentBuilder<Double>
    private static func ripple(from opacity: Double) -> some KeyframeTrackContent<Double> {
        MoveKeyframe(opacity)
        LinearKeyframe(0, duration: 0.8)
    }
}

private struct StatusDotPreviewPalette: View {
    var mode: AppearanceMode

    var body: some View {
        let tokens = DesignTokens.make(mode: mode, accent: .blue)

        HStack(spacing: 12) {
            StatusDot(color: tokens.green)
            StatusDot(color: tokens.green, pulse: true)
            AttentionStatusDot(color: tokens.green, attention: true, attentionColor: tokens.amber)
        }
        .padding()
        .background(tokens.bg)
        .environment(\.designTokens, tokens)
    }
}

#Preview {
    VStack(spacing: 20) {
        StatusDotPreviewPalette(mode: .dark)
        StatusDotPreviewPalette(mode: .light)
    }
    .padding()
}
