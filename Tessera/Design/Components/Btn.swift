import SwiftUI

enum BtnStyle {
    case primary, `default`, danger
}

struct Btn<Label: View>: View {
    var action: () -> Void
    var style: BtnStyle = .default
    var compact: Bool = false
    var full: Bool = false
    @ViewBuilder var label: () -> Label

    @Environment(\.designTokens) private var T

    init(
        style: BtnStyle = .default,
        compact: Bool = false,
        full: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.action = action
        self.style = style
        self.compact = compact
        self.full = full
        self.label = label
    }

    init(
        _ text: String,
        style: BtnStyle = .default,
        compact: Bool = false,
        full: Bool = false,
        action: @escaping () -> Void
    ) where Label == Text {
        self.action = action
        self.style = style
        self.compact = compact
        self.full = full
        self.label = { Text(text) }
    }

    private var colors: (bg: Color, fg: Color, border: Color) {
        switch style {
        case .primary:
            // JSX hardcodes white-on-black (dark-mode-only prototype). For light
            // mode we invert via T.fg / T.bg so the button stays visible against
            // the page background.
            let primaryFg: Color = T.isLight ? .white : .black
            return (T.fg, primaryFg, T.fg)
        case .default:
            return (T.inputBg, T.fg, T.border)
        case .danger:
            return (.clear, T.red, T.red)
        }
    }

    var body: some View {
        Button(action: action) {
            label()
                .font(Typography.tesseraMono(size: 13))
                .foregroundStyle(colors.fg)
                .padding(.horizontal, compact ? 12 : 16)
                .padding(.vertical, compact ? 6 : 10)
                .frame(maxWidth: full ? .infinity : nil)
                .background(colors.bg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(colors.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct BtnPreviewPalette: View {
    var mode: AppearanceMode

    var body: some View {
        let tokens = DesignTokens.make(mode: mode, accent: .blue)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Btn("Primary", style: .primary) {}
                Btn("Default", style: .default) {}
                Btn("Danger", style: .danger) {}
            }

            HStack(spacing: 8) {
                Btn("Primary", style: .primary, compact: true) {}
                Btn("Default", style: .default, compact: true) {}
                Btn("Danger", style: .danger, compact: true) {}
            }
        }
        .padding()
        .background(tokens.bg)
        .environment(\.designTokens, tokens)
    }
}

#Preview {
    VStack(spacing: 20) {
        BtnPreviewPalette(mode: .dark)
        BtnPreviewPalette(mode: .light)
    }
    .padding()
}
