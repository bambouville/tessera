// Tessera/Settings/SecuritySettingsView.swift
import SwiftUI

struct SecuritySettingsView: View {
    @Environment(\.designTokens) private var T
    @Environment(AppearancePreferences.self) private var appearance

    private let autoLockOptions: [(label: String, minutes: Int)] = [
        ("Never", 0),
        ("1 Minute", 1),
        ("5 Minutes", 5),
        ("15 Minutes", 15),
        ("1 Hour", 60)
    ]

    private var autoLockDisplayLabel: String {
        let minutes = appearance.autoLockMinutes
        return autoLockOptions.first(where: { $0.minutes == minutes })?.label
            ?? "\(minutes) min"
    }

    var body: some View {
        @Bindable var appearance = appearance

        VStack(alignment: .leading, spacing: 0) {
            SettingsH("security")

            ToggleRow(
                title: "require device owner authentication to unlock",
                subtitle: "Face ID first, with device-passcode fallback",
                isOn: $appearance.requireFaceIDToUnlock
            )
            .padding(.bottom, 18)

            Field(label: "auto-lock after idle") {
                Menu {
                    ForEach(autoLockOptions, id: \.minutes) { option in
                        Button(option.label) { appearance.autoLockMinutes = option.minutes }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(autoLockDisplayLabel)
                            .font(Typography.tesseraMono(size: 13))
                            .foregroundStyle(T.fg)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(Typography.tesseraMono(size: 11))
                            .foregroundStyle(T.fgDim)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(T.inputBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(T.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            ToggleRow(
                title: "lock when backgrounded",
                isOn: $appearance.lockWhenBackgrounded
            )
            .padding(.bottom, 18)

            ToggleRow(
                title: "authorize key connection bursts",
                subtitle: "Face ID or passcode; a grant may cover the same endpoint and key for 30 seconds",
                isOn: $appearance.requireBiometricForKeyUse
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
