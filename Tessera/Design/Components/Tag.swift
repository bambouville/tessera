import SwiftUI

struct Tag: View {
    var text: String
    var color: Color? = nil

    @Environment(\.designTokens) private var T

    private var bgColor: Color {
        color ?? (T.isLight ? Color.black.opacity(0.04) : Color.white.opacity(0.06))
    }

    var body: some View {
        Text(text)
            .font(Typography.tesseraMono(size: 10))
            .foregroundStyle(T.fgMuted)
            .padding(.vertical, 2)
            .padding(.horizontal, 7)
            .background(bgColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(T.border, lineWidth: 1)
            )
    }
}

private struct TagPreviewPalette: View {
    var mode: AppearanceMode

    var body: some View {
        let tokens = DesignTokens.make(mode: mode, accent: .blue)

        HStack(spacing: 8) {
            Tag(text: "Default")
            Tag(text: "Accent", color: tokens.accentSoft)
            Tag(text: "Amber", color: tokens.amber.opacity(0.18))
        }
        .padding()
        .background(tokens.bg)
        .environment(\.designTokens, tokens)
    }
}

#Preview {
    VStack(spacing: 20) {
        TagPreviewPalette(mode: .dark)
        TagPreviewPalette(mode: .light)
    }
    .padding()
}
