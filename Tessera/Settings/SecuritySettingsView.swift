// Tessera/Settings/SecuritySettingsView.swift
import SwiftUI

struct SecuritySettingsView: View {
    @Environment(\.designTokens) private var T
    @Environment(AppearancePreferences.self) private var appearance

    private let autoLockOptions: [Int] = [0, 1, 5, 15, 60]

    /// Built from the number rather than stored as fixed English strings —
    /// the minute count needs each language's own plural agreement, and the
    /// fallback for a value outside the list needs the same treatment.
    private func autoLockLabel(minutes: Int) -> String {
        switch minutes {
        case 0:  return String(localized: "Never", comment: "Auto-lock delay: never lock")
        case 1:  return String(localized: "1 minute", comment: "Auto-lock delay")
        case 60: return String(localized: "1 hour", comment: "Auto-lock delay")
        default: return String(localized: "\(minutes) minutes", comment: "Auto-lock delay: two or more minutes")
        }
    }

    private var backgroundLockBinding: Binding<Bool> {
        Binding(
            get: { appearance.effectiveLockWhenBackgrounded },
            set: { appearance.setBackgroundLockEnabled($0) }
        )
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
                    ForEach(autoLockOptions, id: \.self) { minutes in
                        Button(autoLockLabel(minutes: minutes)) {
                            appearance.autoLockMinutes = minutes
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: autoLockLabel(minutes: appearance.autoLockMinutes))
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
                subtitle: "also enables device owner authentication",
                isOn: backgroundLockBinding
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
