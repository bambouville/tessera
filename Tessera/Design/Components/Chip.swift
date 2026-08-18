import SwiftUI

struct Chip: View {
    var text: LocalizedStringKey
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

/// Sample copy for the Xcode canvas only. Building the key at runtime
/// keeps these out of string extraction, so they never reach the
/// shipped catalog as untranslated entries.
private struct ChipPreviewPalette: View {
    private static let selectedSample = "Selected"
    private static let idleSample = "Idle"

    var mode: AppearanceMode

    var body: some View {
        let tokens = DesignTokens.make(mode: mode, accent: .blue)

        HStack(spacing: 8) {
            Chip(text: LocalizedStringKey(Self.selectedSample), selected: true) {}
            Chip(text: LocalizedStringKey(Self.idleSample), selected: false) {}
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
