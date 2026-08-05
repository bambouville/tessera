import SwiftUI
import UIKit

struct LockScreenView: View {
    let isInitialColdLaunch: Bool
    let onInitialColdLaunchPrompted: () -> Void

    @Environment(AppearancePreferences.self) private var appearance
    @Environment(AppLockController.self) private var controller
    @State private var isUnlocking = false
    @State private var didAutoPrompt = false

    private var activeTheme: TerminalTheme {
        TerminalTheme.find(id: appearance.terminalThemeID)
    }

    /// Lock-screen chrome keeps the theme's bg/fg but always carries the
    /// user's app accent, bypassing `respectsUserAccent`: the only accented
    /// element here is the brand mark's cursor square, which must match the
    /// configured accent — not the terminal theme's signature color.
    private var tokens: DesignTokens {
        let theme = activeTheme
        let userTokens = DesignTokens.make(
            mode: theme.isLight ? .light : .dark,
            accent: appearance.accent,
            customColor: appearance.accent == .custom
                ? Color(rgbInt: appearance.customAccentRGB)
                : nil
        )
        return theme.chromeTokens(
            accentOverride: userTokens.accent,
            accentSoftOverride: userTokens.accentSoft
        )
    }

    var body: some View {
        ZStack {
            tokens.bg.ignoresSafeArea()

            VStack(spacing: 14) {
                TesseraLogo(size: 84, color: tokens.fg)
                    .padding(.bottom, 2)

                Text("— locked —")
                    .font(Typography.tesseraMono(size: 11, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(tokens.fgDim)

                VStack(spacing: 10) {
                    if let message = authErrorMessage {
                        Text(message)
                            .font(Typography.tesseraMono(size: 11, weight: .medium))
                            .foregroundStyle(tokens.red)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: 340)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(tokens.red.opacity(tokens.isLight ? 0.08 : 0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(tokens.red.opacity(0.28), lineWidth: 0.5)
                            )
                    }

                    Button(action: requestUnlock) {
                        Text(isUnlocking ? "unlocking..." : "tap to unlock")
                            .font(Typography.tesseraMono(size: 13, weight: .medium))
                            .foregroundStyle(tokens.fg)
                            .frame(minWidth: 164)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(tokens.inputBg)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(tokens.borderStrong, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isUnlocking)
                }
                .padding(.top, 8)

                Text("face id · or device passcode")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(tokens.fgDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
        .environment(\.designTokens, tokens)
        .ignoresSafeArea()
        .onAppear {
            resignFirstResponder()
            guard appearance.requireFaceIDToUnlock,
                  isInitialColdLaunch,
                  !didAutoPrompt
            else { return }
            didAutoPrompt = true
            onInitialColdLaunchPrompted()
            requestUnlock()
        }
    }

    private var authErrorMessage: String? {
        guard let result = controller.lastAuthError else { return nil }
        switch result {
        case .failed:
            return "face id didn't match. tap to try again or use device passcode."
        case .unavailable:
            return "biometric authentication is unavailable. tap to use device passcode."
        case .authenticated, .userCancelled:
            return nil
        }
    }

    private func requestUnlock() {
        guard !isUnlocking else { return }
        isUnlocking = true
        Task {
            await controller.unlock()
            isUnlocking = false
        }
    }

    private func resignFirstResponder() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}
