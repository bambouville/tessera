import SwiftUI

struct ToggleRow: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
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

/// Sample copy for the Xcode canvas only. Building the key at runtime
/// keeps these out of string extraction, so they never reach the
/// shipped catalog as untranslated entries.
private struct ToggleRowPreview: View {
    private static let onSample = "Enabled"
    private static let offSample = "Disabled"
    private static let darkSample = "Dark mode"
    private static let lightSample = "Light mode"

    @State private var darkEnabled = true
    @State private var darkDisabled = false
    @State private var lightEnabled = true
    @State private var lightDisabled = false

    var body: some View {
        HStack(spacing: 24) {
            VStack(spacing: 12) {
                ToggleRow(title: LocalizedStringKey(Self.onSample), subtitle: LocalizedStringKey(Self.darkSample), isOn: $darkEnabled)
                ToggleRow(title: LocalizedStringKey(Self.offSample), isOn: $darkDisabled)
            }
            .padding()
            .background(DesignTokens.make(mode: .dark, accent: .blue).bg)
            .environment(\.designTokens, DesignTokens.make(mode: .dark, accent: .blue))

            VStack(spacing: 12) {
                ToggleRow(title: LocalizedStringKey(Self.onSample), subtitle: LocalizedStringKey(Self.lightSample), isOn: $lightEnabled)
                ToggleRow(title: LocalizedStringKey(Self.offSample), isOn: $lightDisabled)
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
