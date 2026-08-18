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

    /// Titles are `LocalizedStringKey`, not `String`, so every literal call
    /// site is picked up by string extraction and translated automatically.
    /// A runtime string (a host name, a user-chosen label) is not a
    /// translatable key — pass it through the `ViewBuilder` initializer above
    /// as `Text(verbatim:)` instead.
    init(
        _ titleKey: LocalizedStringKey,
        style: BtnStyle = .default,
        compact: Bool = false,
        full: Bool = false,
        action: @escaping () -> Void
    ) where Label == Text {
        self.action = action
        self.style = style
        self.compact = compact
        self.full = full
        self.label = { Text(titleKey) }
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
            // Style names, and preview-only — they must not reach the catalog.
            HStack(spacing: 8) {
                Btn(style: .primary, action: {}) { Text(verbatim: "Primary") }
                Btn(style: .default, action: {}) { Text(verbatim: "Default") }
                Btn(style: .danger, action: {}) { Text(verbatim: "Danger") }
            }

            HStack(spacing: 8) {
                Btn(style: .primary, compact: true, action: {}) { Text(verbatim: "Primary") }
                Btn(style: .default, compact: true, action: {}) { Text(verbatim: "Default") }
                Btn(style: .danger, compact: true, action: {}) { Text(verbatim: "Danger") }
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
