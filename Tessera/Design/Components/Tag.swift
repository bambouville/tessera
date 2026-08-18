import SwiftUI

struct Tag: View {
    private let label: Text
    var color: Color? = nil

    @Environment(\.designTokens) private var T

    /// A translatable status word — "enforced", "missing", "secure enclave".
    init(text: LocalizedStringKey, color: Color? = nil) {
        self.label = Text(text)
        self.color = color
    }

    /// Data that must survive verbatim in every language: key algorithm
    /// names (`ssh-ed25519`), user-chosen key names, host addresses.
    init(verbatim text: String, color: Color? = nil) {
        self.label = Text(verbatim: text)
        self.color = color
    }

    private var bgColor: Color {
        color ?? (T.isLight ? Color.black.opacity(0.04) : Color.white.opacity(0.06))
    }

    var body: some View {
        label
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
            Tag(verbatim: "Default")
            Tag(verbatim: "Accent", color: tokens.accentSoft)
            Tag(verbatim: "Amber", color: tokens.amber.opacity(0.18))
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
