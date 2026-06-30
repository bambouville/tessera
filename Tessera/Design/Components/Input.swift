import SwiftUI

struct Input: View {
    @Binding var text: String
    var placeholder: String = ""
    var mono: Bool = true
    var secure: Bool = false
    var disabled: Bool = false

    @Environment(\.designTokens) private var T
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .focused($focused)
        .font(mono ? Typography.tesseraMono(size: 13) : Typography.tesseraSans(size: 13))
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
