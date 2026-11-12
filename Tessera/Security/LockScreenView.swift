import SwiftUI
import UIKit

struct LockScreenView: View {
    let isInitialColdLaunch: Bool
    let onInitialColdLaunchPrompted: () -> Void

    @Environment(AppearancePreferences.self) private var appearance
    @Environment(AppLockController.self) private var controller
    @State private var isUnlocking = false
    @State private var didAutoPrompt = false
    @State private var laptop = LaptopCardLayout()

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
            // Laptop pose: the unlock button above the fold, never on the
            // hinge. The background still covers the whole window.
            .laptopCardPlacement(laptop, scrolls: true)
        }
        .readsLaptopCardLayout($laptop)
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
            return String(localized: "face id didn't match. tap to try again or use device passcode.")
        case .unavailable:
            return String(localized: "biometric authentication is unavailable. tap to use device passcode.")
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

// MARK: - Laptop pose

/// Laptop pose: a card centred on its window would sit on the hinge, which
/// cannot be touched. It centres on the screen above the fold instead. The
/// lock screen, the onboarding overlay and the continuation overlay share it.
struct LaptopCardLayout: Equatable {
    /// In the coordinates of the layer the card is centred in.
    var fold: DuoFold?
    /// The window's top safe area. SwiftUI reports none inside a layer laid
    /// out ignoring it, so `readsLaptopCardLayout` asks the window.
    var windowTopInset: CGFloat = 0
    /// The layer's top, global.
    var layerMinY: CGFloat = 0

    /// The layer's own top safe area.
    var topInset: CGFloat {
        max(0, windowTopInset - layerMinY)
    }

    /// From the top safe area to just above the hinge. Nil off laptop pose,
    /// where the card stays centred on its window.
    var screen: ClosedRange<CGFloat>? {
        guard let fold, !fold.splitsSideBySide else { return nil }
        let bottom = fold.frame.minY - LaptopPaletteLayout.foldClearance
        return bottom > topInset ? topInset...bottom : nil
    }

    /// A callout at `y` that would cross the hinge moves past it, to the side
    /// away from its target, so neither covers the other.
    func calloutY(
        _ y: CGFloat,
        height: CGFloat,
        target: CGRect,
        containerHeight: CGFloat,
        margin: CGFloat = 12
    ) -> CGFloat {
        guard let fold, !fold.splitsSideBySide else { return y }
        let hinge = fold.frame
        let above = hinge.minY - LaptopPaletteLayout.foldClearance - height
        let below = hinge.maxY + LaptopPaletteLayout.foldClearance
        guard y > above, y < below else { return y }
        let past = target.midY < hinge.midY ? below : above
        return max(margin, min(past, containerHeight - height - margin))
    }
}

extension View {
    /// On the layer a card is centred in: its fold, against the
    /// keyboard-free frame, and its top safe area. Inert off a Duo.
    func readsLaptopCardLayout(_ layout: Binding<LaptopCardLayout>) -> some View {
        background {
            Color.clear
                .ignoresSafeArea(.keyboard)
                .onDuoFoldChange { fold in
                    if layout.wrappedValue.fold != fold { layout.wrappedValue.fold = fold }
                }
                .background {
                    // Only a Duo reports a fold.
                    if layout.wrappedValue.fold != nil {
                        LaptopTopSafeAreaProbe { inset in
                            if layout.wrappedValue.windowTopInset != inset { layout.wrappedValue.windowTopInset = inset }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { minY in
                            if layout.wrappedValue.layerMinY != minY { layout.wrappedValue.layerMinY = minY }
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Centres this card on the screen above the fold, at most its height.
    /// `scrolls` lets a card that does not scroll itself scroll there when
    /// taller. Off laptop pose the card is left as it was. The card must fill
    /// the layer that read `layout`.
    @ViewBuilder
    func laptopCardPlacement(_ layout: LaptopCardLayout, scrolls: Bool = false) -> some View {
        if let screen = layout.screen {
            // The card's value appears twice below; one box keeps its nested
            // type off the main thread's stack.
            let card = stackBoundary()
            Group {
                if scrolls {
                    ViewThatFits(in: .vertical) {
                        card
                        ScrollView(.vertical) { card }
                            .scrollIndicators(.hidden)
                    }
                } else {
                    card
                }
            }
            .frame(maxWidth: .infinity, maxHeight: screen.upperBound - screen.lowerBound)
            .padding(.top, screen.lowerBound)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            self
        }
    }
}

/// Its window's top safe area, a run-loop turn after UIKit lays it out. A
/// body must not read the window's insets itself (see `WindowBottomSafeArea`).
private struct LaptopTopSafeAreaProbe: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    final class ProbeView: UIView {
        var onChange: ((CGFloat) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            refresh()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            refresh()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            refresh()
        }

        private func refresh() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.onChange?(window.safeAreaInsets.top)
            }
        }
    }
}
