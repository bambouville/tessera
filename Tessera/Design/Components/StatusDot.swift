import SwiftUI

struct StatusDot: View {
    var color: Color
    var pulse: Bool = false
    var size: CGFloat = 7

    @State private var animating: Bool = false

    // JSX uses tess-pulse keyframe (box-shadow ring); SwiftUI translates as opacity since replicating the box-shadow ring isn't worth the added complexity.
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulse ? (animating ? 1.0 : 0.4) : 1.0)
            .onAppear {
                if pulse {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        animating = true
                    }
                }
            }
    }
}

private struct StatusDotPreviewPalette: View {
    var mode: AppearanceMode

    var body: some View {
        let tokens = DesignTokens.make(mode: mode, accent: .blue)

        HStack(spacing: 12) {
            StatusDot(color: tokens.green)
            StatusDot(color: tokens.green, pulse: true)
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
