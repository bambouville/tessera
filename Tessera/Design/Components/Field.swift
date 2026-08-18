import SwiftUI

struct Field<Content: View>: View {
    var label: LocalizedStringKey
    var sub: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    @Environment(\.designTokens) private var T

    init(label: LocalizedStringKey, sub: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.sub = sub
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(label)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)
                .fixedSize(horizontal: false, vertical: true)

            content()

            if let sub = sub {
                Text(sub)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
                .frame(height: 18)
        }
    }
}

/// Sample copy for the Xcode canvas only. Building the key at runtime
/// keeps these out of string extraction, so they never reach the
/// shipped catalog as untranslated entries.
#Preview {
    let darkSample = "Dark Field"
    let lightSample = "Light Field"
    let subSample = "Supporting context"

    HStack(spacing: 24) {
        VStack(alignment: .leading) {
            Field(label: LocalizedStringKey(darkSample), sub: LocalizedStringKey(subSample)) {
                Text(verbatim: "Placeholder")
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(DesignTokens.make(mode: .dark, accent: .blue).fg)
            }
        }
        .padding()
        .background(DesignTokens.make(mode: .dark, accent: .blue).bg)
        .environment(\.designTokens, DesignTokens.make(mode: .dark, accent: .blue))

        VStack(alignment: .leading) {
            Field(label: LocalizedStringKey(lightSample)) {
                Text(verbatim: "Placeholder")
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(DesignTokens.make(mode: .light, accent: .blue).fg)
            }
        }
        .padding()
        .background(DesignTokens.make(mode: .light, accent: .blue).bg)
        .environment(\.designTokens, DesignTokens.make(mode: .light, accent: .blue))
    }
    .padding()
}
