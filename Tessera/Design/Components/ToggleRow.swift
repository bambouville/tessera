import SwiftUI

struct ToggleRow: View {
    var title: String
    var subtitle: String?
    @Binding var isOn: Bool

    @Environment(\.designTokens) private var T

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fg)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(T.accent)
        }
    }
}

private struct ToggleRowPreview: View {
    @State private var darkEnabled = true
    @State private var darkDisabled = false
    @State private var lightEnabled = true
    @State private var lightDisabled = false

    var body: some View {
        HStack(spacing: 24) {
            VStack(spacing: 12) {
                ToggleRow(title: "Enabled", subtitle: "Dark mode", isOn: $darkEnabled)
                ToggleRow(title: "Disabled", isOn: $darkDisabled)
            }
            .padding()
            .background(DesignTokens.make(mode: .dark, accent: .blue).bg)
            .environment(\.designTokens, DesignTokens.make(mode: .dark, accent: .blue))

            VStack(spacing: 12) {
                ToggleRow(title: "Enabled", subtitle: "Light mode", isOn: $lightEnabled)
                ToggleRow(title: "Disabled", isOn: $lightDisabled)
            }
            .padding()
            .background(DesignTokens.make(mode: .light, accent: .blue).bg)
            .environment(\.designTokens, DesignTokens.make(mode: .light, accent: .blue))
        }
        .padding()
    }
}

#Preview {
    ToggleRowPreview()
}
