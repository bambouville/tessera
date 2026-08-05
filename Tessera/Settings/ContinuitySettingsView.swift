import SwiftUI
import UIKit

struct ContinuitySettingsView: View {
    @Environment(\.designTokens) private var T
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(BootstrapCoordinator.self) private var bootstrapCoordinator

    var body: some View {
        @Bindable var appearance = appearance

        VStack(alignment: .leading, spacing: 0) {
            SettingsH("sync & continuity")

            Text("continuity")
                .font(Typography.kicker)
                .tracking(0.6)
                .foregroundStyle(T.fgDim)
                .textCase(.uppercase)
                .padding(.bottom, 12)

            ToggleRow(
                title: "hand off sessions",
                subtitle: "focused session appears in the App Switcher or Dock on your other devices",
                isOn: $appearance.handoffSessionsEnabled
            )
            .padding(.bottom, 18)

            truthRow(
                title: "while locked",
                detail: "suppressed",
                subtitle: "broadcast stops; incoming continuations wait for Face ID"
            )
            .padding(.bottom, 12)

            Text("Requires the same Apple Account on both devices, Bluetooth and Wi-Fi, and Handoff enabled in System Settings. Carries a pointer to the session — never a password or private key.")
                .font(Typography.tesseraMono(size: 10.5))
                .foregroundStyle(T.fgDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 30)

            Text("nearby setup")
                .font(Typography.kicker)
                .tracking(0.6)
                .foregroundStyle(T.fgDim)
                .textCase(.uppercase)
                .padding(.bottom, 12)

            Btn("send setup to nearby device", full: true) {
                bootstrapCoordinator.startOffering(
                    displayName: UIDevice.current.name
                )
            }
            .accessibilityIdentifier("continuity.nearby.send")
            .padding(.bottom, 8)

            Btn("receive setup from nearby device", full: true) {
                bootstrapCoordinator.startRecipientDiscovery(
                    displayName: UIDevice.current.name
                )
            }
            .accessibilityIdentifier("continuity.nearby.receive")
            .padding(.bottom, 8)

            Text("Choose send on the device that already has your setup, and receive on the device inheriting it. Both are visible only while the setup screen is open. The devices compare a fresh six-digit code before Face ID can approve an encrypted transfer.")
                .font(Typography.tesseraMono(size: 10.5))
                .foregroundStyle(T.fgDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func truthRow(
        title: String,
        detail: String,
        subtitle: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fg)

                Text(subtitle)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
            }

            Spacer(minLength: 8)

            Text(detail)
                .font(Typography.tesseraMono(size: 11, weight: .medium))
                .foregroundStyle(T.fgMuted)
        }
    }
}
