import SwiftUI

struct Field<Content: View>: View {
    var label: String
    var sub: String?
    @ViewBuilder var content: () -> Content

    @Environment(\.designTokens) private var T

    init(label: String, sub: String? = nil, @ViewBuilder content: @escaping () -> Content) {
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

#Preview {
    HStack(spacing: 24) {
        VStack(alignment: .leading) {
            Field(label: "Dark Field", sub: "Supporting context") {
                Text("Placeholder")
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(DesignTokens.make(mode: .dark, accent: .blue).fg)
            }
        }
        .padding()
        .background(DesignTokens.make(mode: .dark, accent: .blue).bg)
        .environment(\.designTokens, DesignTokens.make(mode: .dark, accent: .blue))

        VStack(alignment: .leading) {
            Field(label: "Light Field") {
                Text("Placeholder")
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
