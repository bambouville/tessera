import SwiftUI

struct Chip: View {
    var text: String
    var selected: Bool
    var action: () -> Void

    @Environment(\.designTokens) private var T

    private var bgColor: Color {
        selected ? T.accentSoft : T.inputBgSoft
    }

    private var fgColor: Color {
        selected ? T.accent : T.fgMuted
    }

    private var borderColor: Color {
        selected ? T.accent : T.border
    }

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(fgColor)
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .background(bgColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct ChipPreviewPalette: View {
    var mode: AppearanceMode

    var body: some View {
        let tokens = DesignTokens.make(mode: mode, accent: .blue)

        HStack(spacing: 8) {
            Chip(text: "Selected", selected: true) {}
            Chip(text: "Idle", selected: false) {}
        }
        .padding()
        .background(tokens.bg)
        .environment(\.designTokens, tokens)
    }
}

#Preview {
    VStack(spacing: 20) {
        ChipPreviewPalette(mode: .dark)
        ChipPreviewPalette(mode: .light)
    }
    .padding()
}
