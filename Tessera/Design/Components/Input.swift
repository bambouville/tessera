import SwiftUI
import UIKit

struct Input: View {
    @Binding var text: String
    var placeholder: String = ""
    var mono: Bool = true
    var secure: Bool = false
    var disabled: Bool = false

    @Environment(\.designTokens) private var T
    // Read so the sans branch's UIFontMetrics size recomputes when the user's
    // text size changes — keeps both branches scaling with Dynamic Type.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focused: Bool

    private var inputFont: Font {
        mono
            ? Typography.tesseraMono(size: 13)
            : Typography.tesseraSans(
                size: UIFontMetrics(forTextStyle: .body).scaledValue(
                    for: 13,
                    compatibleWith: UITraitCollection(
                        preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize)
                    )
                )
            )
    }

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .focused($focused)
        .font(inputFont)
        .foregroundStyle(T.fg)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(focused ? T.accent : T.border, lineWidth: 1)
        )
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

private struct InputPreview: View {
    @State private var darkText = "Tessera"
    @State private var lightText = ""

    var body: some View {
        HStack(spacing: 24) {
            Input(text: $darkText, placeholder: "Dark input")
                .padding()
                .background(DesignTokens.make(mode: .dark, accent: .blue).bg)
                .environment(\.designTokens, DesignTokens.make(mode: .dark, accent: .blue))

            Input(text: $lightText, placeholder: "Light input", mono: false)
                .padding()
                .background(DesignTokens.make(mode: .light, accent: .blue).bg)
                .environment(\.designTokens, DesignTokens.make(mode: .light, accent: .blue))
        }
        .padding()
    }
}

#Preview {
    InputPreview()
}
