import SwiftUI

/// The top layer of the `ContentView` ZStack while the walkthrough runs. Reads
/// the merged onboarding anchors (resolved through the enclosing
/// `GeometryReader`), dims the screen, spotlights the active target, and floats
/// a callout card. When the controller is `.inactive` it renders nothing and
/// passes every touch through.
///
/// Rendered against the active terminal theme via
/// `TerminalTheme.chromeTokens(applying:)`, exactly like `LockScreenView`, so the
/// tour follows the user's palette.
struct OnboardingOverlay: View {
    let controller: OnboardingController
    let anchors: [OnboardingTarget: Anchor<CGRect>]
    let geometry: GeometryProxy

    @Environment(AppearancePreferences.self) private var appearance

    /// Padding around a spotlight target (matches the mockup's `pad = 7`).
    private let spotlightPad: CGFloat = 7
    private let calloutWidth: CGFloat = 312
    private let centeredCardWidth: CGFloat = 478

    @State private var calloutSize: CGSize = CGSize(width: 312, height: 188)

    private var tokens: DesignTokens {
        TerminalTheme.find(id: appearance.terminalThemeID)
            .chromeTokens(applying: appearance)
    }

    var body: some View {
        ZStack {
            switch controller.phase {
            case .inactive:
                // Nothing hittable — taps fall straight through to the app.
                EmptyView()
            case .welcome:
                welcomeLayer
            case .touring(let index):
                if index >= 0 && index < controller.steps.count {
                    tourLayer(index: index, step: controller.steps[index])
                }
            }
        }
        .environment(\.designTokens, tokens)
    }

    // MARK: - Welcome

    private var welcomeLayer: some View {
        ZStack {
            dimBackdrop(opacity: 0.76)

            VStack(spacing: 0) {
                TesseraLogo(size: 52, color: tokens.fg)
                    .padding(.bottom, 18)

                Text("welcome to Tessera")
                    .font(Typography.tesseraMono(size: 22, weight: .semibold))
                    .foregroundStyle(tokens.fg)
                    .padding(.bottom, 10)

                Text("A fast iPad terminal for SSH & Mosh — trackpad scrolling "
                    + "in TUIs, native tmux, truecolor, edge-to-edge. Want a "
                    + "quick tour?")
                    .font(Typography.tesseraSans(size: 14))
                    .foregroundStyle(tokens.fgMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 22)

                HStack(spacing: 10) {
                    Btn(style: .primary, action: { controller.startTour() }) {
                        Text("take the tour")
                    }

                    Btn(style: .default, action: { controller.skip() }) {
                        Text("skip")
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 30)
            .padding(.bottom, 24)
            .frame(width: 440)
            .background(cardBackground)
        }
    }

    // MARK: - Tour

    @ViewBuilder
    private func tourLayer(index: Int, step: OnboardingStep) -> some View {
        switch step.kind {
        case .spotlight(let target, let placement):
            if let rect = resolvedRect(for: target) {
                spotlightLayer(index: index, step: step, hole: hole(for: rect), placement: placement)
            } else {
                // Target not on screen (e.g. replaying the tour with hosts
                // present, so the empty-state CTA isn't rendered) — degrade to a
                // centered card so the step's copy still shows.
                centeredLayer(index: index, step: step, illustration: nil)
            }
        case .illustration(let illustration):
            centeredLayer(index: index, step: step, illustration: illustration)
        }
    }

    private func spotlightLayer(
        index: Int,
        step: OnboardingStep,
        hole: CGRect,
        placement: OnboardingPlacement
    ) -> some View {
        ZStack(alignment: .topLeading) {
            // Hit-blocker beneath the dim so taps in the spotlight hole don't
            // reach the real element — the tour is passive, never driving the
            // user into a real flow.
            tapBlocker

            // Visual dim with a punched-out hole (even-odd fill, no compositing).
            Path { path in
                path.addRect(CGRect(origin: .zero, size: geometry.size))
                path.addRoundedRect(in: hole, cornerSize: CGSize(width: 9, height: 9))
            }
            .fill(Color.black.opacity(0.72), style: FillStyle(eoFill: true))
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // Accent ring around the hole.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(tokens.accent, lineWidth: 1.5)
                .frame(width: hole.width, height: hole.height)
                .position(x: hole.midX, y: hole.midY)
                .allowsHitTesting(false)

            calloutCard(index: index, step: step, illustration: nil)
                .fixedSize()
                .background(calloutSizeReader)
                .offset(calloutOffset(hole: hole, placement: placement))
        }
        .ignoresSafeArea()
    }

    private func centeredLayer(
        index: Int,
        step: OnboardingStep,
        illustration: OnboardingIllustration?
    ) -> some View {
        ZStack {
            dimBackdrop(opacity: 0.72)

            calloutCard(index: index, step: step, illustration: illustration)
                .frame(width: centeredCardWidth)
        }
    }

    // MARK: - Callout card

    private func calloutCard(
        index: Int,
        step: OnboardingStep,
        illustration: OnboardingIllustration?
    ) -> some View {
        let isLast = index == controller.steps.count - 1

        return VStack(alignment: .leading, spacing: 0) {
            Text("STEP \(index + 1) OF \(controller.steps.count)")
                .font(Typography.tesseraMono(size: 10.5, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(tokens.accent)
                .padding(.bottom, 8)

            Text(step.title)
                .font(Typography.tesseraMono(size: 15, weight: .medium))
                .foregroundStyle(tokens.fg)
                .padding(.bottom, 7)

            Text(step.body)
                .font(Typography.tesseraSans(size: 13))
                .foregroundStyle(tokens.fgMuted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            if let illustration {
                illustrationView(illustration)
                    .padding(.bottom, 14)
            }

            HStack(spacing: 8) {
                dots(current: index)

                Spacer(minLength: 8)

                // skip is present on every step, per the locked design.
                Button(action: { controller.skip() }) {
                    Text("skip tour ✕")
                        .font(Typography.tesseraMono(size: 12))
                        .foregroundStyle(tokens.fgDim)
                }
                .buttonStyle(.plain)

                if index > 0 {
                    calloutButton("back", filled: false) { controller.back() }
                }

                calloutButton(isLast ? "done" : "next", filled: true) {
                    controller.next()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 13)
        .frame(width: illustration == nil ? calloutWidth : centeredCardWidth - 32, alignment: .leading)
        .background(cardBackground)
    }

    private func dots(current: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<controller.steps.count, id: \.self) { i in
                Circle()
                    .fill(i == current ? tokens.accent : tokens.fgFaint)
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func calloutButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.tesseraMono(size: 12, weight: filled ? .semibold : .regular))
                .foregroundStyle(filled ? primaryButtonFg : tokens.fgMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(filled ? tokens.accent : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(filled ? Color.clear : tokens.borderStrong, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Illustrations

    @ViewBuilder
    private func illustrationView(_ illustration: OnboardingIllustration) -> some View {
        switch illustration {
        case .mockTerminal:
            MockTerminalIllustration(tokens: tokens)
        case .claudeCodePromptWithPuck:
            ClaudeCodePromptIllustration(tokens: tokens)
        case .shortcuts:
            ShortcutsIllustration(tokens: tokens)
        }
    }

    // MARK: - Shared chrome

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(tokens.panelBg)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(tokens.borderStrong, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.5), radius: 24, y: 14)
    }

    private func dimBackdrop(opacity: Double) -> some View {
        Color.black.opacity(opacity)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { /* consume — passive tour */ }
    }

    private var tapBlocker: some View {
        Color.black.opacity(0.0001)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { /* consume — passive tour */ }
    }

    private var primaryButtonFg: Color {
        tokens.isLight ? .white : .black
    }

    // MARK: - Geometry helpers

    private func resolvedRect(for target: OnboardingTarget) -> CGRect? {
        guard let anchor = anchors[target] else { return nil }
        return geometry[anchor]
    }

    private func hole(for rect: CGRect) -> CGRect {
        rect.insetBy(dx: -spotlightPad, dy: -spotlightPad)
    }

    /// Top-leading offset for the callout card, clamped to the container — the
    /// same logic the mockup's `render()` proved.
    private func calloutOffset(hole: CGRect, placement: OnboardingPlacement) -> CGSize {
        let gap: CGFloat = 14
        var x: CGFloat
        var y: CGFloat
        switch placement {
        case .below:
            x = hole.midX - calloutSize.width / 2
            y = hole.maxY + gap
        case .right:
            x = hole.maxX + gap
            y = hole.minY
        }
        x = max(12, min(x, geometry.size.width - calloutSize.width - 12))
        y = max(12, min(y, geometry.size.height - calloutSize.height - 12))
        return CGSize(width: x, height: y)
    }

    private var calloutSizeReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: CalloutSizeKey.self, value: proxy.size)
        }
        .onPreferenceChange(CalloutSizeKey.self) { size in
            if size != .zero { calloutSize = size }
        }
    }
}

private struct CalloutSizeKey: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Illustration: mock tmux terminal

private struct MockTerminalIllustration: View {
    let tokens: DesignTokens

    var body: some View {
        VStack(spacing: 0) {
            // tab strip
            HStack(spacing: 6) {
                tab("1:vim", active: false, bell: false)
                tab("2:server", active: true, bell: true)
                tab("3:logs", active: false, bell: false)
                Spacer(minLength: 0)
                Text("+")
                    .font(Typography.tesseraMono(size: 14))
                    .foregroundStyle(tokens.fgDim)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) {
                Rectangle().fill(tokens.border).frame(height: 1)
            }

            // output
            VStack(alignment: .leading, spacing: 3) {
                line("$ npm run dev", color: tokens.fgMuted)
                line("  ▸ ready in 240ms", color: tokens.fgDim)
                line("  ✓ listening on http://localhost:3000", color: tokens.green)
                HStack(spacing: 0) {
                    Text("$ ")
                        .font(Typography.tesseraMono(size: 11.5))
                        .foregroundStyle(tokens.fgMuted)
                    Rectangle()
                        .fill(tokens.accent)
                        .frame(width: 7, height: 13)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
    }

    private func tab(_ title: String, active: Bool, bell: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(active ? tokens.accent : tokens.fgMuted)
            if bell {
                Circle().fill(tokens.accent).frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? tokens.accentSoft : Color.clear)
        )
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typography.tesseraMono(size: 11.5))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Illustration: simulated Claude Code prompt + swipe-pad puck

private struct ClaudeCodePromptIllustration: View {
    let tokens: DesignTokens

    private let brandColor = Color(rgbInt: 0xD97757)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                // brand row
                HStack(spacing: 8) {
                    Circle()
                        .fill(brandColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: brandColor.opacity(0.7), radius: 4)
                    Text("Claude Code")
                        .font(Typography.tesseraMono(size: 11.5))
                        .foregroundStyle(tokens.fgMuted)
                }
                .padding(.bottom, 9)

                Text("● I'll add the /health route to the server.")
                    .font(Typography.tesseraMono(size: 11.5))
                    .foregroundStyle(tokens.fg)
                Text("  ⎿ Edit(src/server.ts)")
                    .font(Typography.tesseraMono(size: 11.5))
                    .foregroundStyle(tokens.fgDim)
                    .padding(.bottom, 9)

                // permission box
                VStack(alignment: .leading, spacing: 7) {
                    (Text("Edit ")
                        + Text("src/server.ts").foregroundColor(tokens.accent)
                        + Text("?"))
                        .font(Typography.tesseraMono(size: 11.5))
                        .foregroundStyle(tokens.fg)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("❯ 1. Yes")
                            .foregroundStyle(tokens.accent)
                        Text("  2. Yes, and don't ask again")
                            .foregroundStyle(tokens.fgMuted)
                        Text("  3. No, tell Claude what to do")
                            .foregroundStyle(tokens.fgMuted)
                    }
                    .font(Typography.tesseraMono(size: 11.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: 300, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tokens.borderStrong, lineWidth: 1)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)

            PuckPetalsIllustration(tokens: tokens)
                .frame(width: 158, height: 148)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
    }
}

/// The radial swipe-pad puck: a center circle with four labeled petals. Petal
/// colors map onto the prompt — right=approve (green), left=deny (red),
/// up=always (amber), down=macro (accent).
private struct PuckPetalsIllustration: View {
    let tokens: DesignTokens

    var body: some View {
        ZStack {
            petal("↑", "always", tokens.amber)
                .frame(maxHeight: .infinity, alignment: .top)
            petal("↓", "macro", tokens.accent)
                .frame(maxHeight: .infinity, alignment: .bottom)
            petal("←", "deny", tokens.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            petal("→", "approve", tokens.green)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Circle()
                .fill(tokens.accent.opacity(0.22))
                .overlay(Circle().strokeBorder(tokens.accent, lineWidth: 1.5))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "dot.scope")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(tokens.accent)
                )
        }
    }

    private func petal(_ arrow: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(arrow).font(Typography.tesseraMono(size: 11, weight: .semibold))
            Text(label).font(Typography.tesseraMono(size: 9, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(color.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(color.opacity(0.45), lineWidth: 1)
                )
        )
    }
}

// MARK: - Illustration: keyboard-shortcut cheat grid

private struct ShortcutsIllustration: View {
    let tokens: DesignTokens

    private let rows: [(String, String)] = [
        ("⌘N", "new host"),
        ("⌘F", "find in scrollback"),
        ("⌘T", "new tmux window"),
        ("⌘1–9", "switch window"),
        ("⌘⇧W", "close window"),
        ("⌘⇧[ ]", "prev / next window"),
        ("⌘K", "session switcher"),
        ("⌘,", "settings")
    ]

    private let columns = [
        GridItem(.flexible(), spacing: 18, alignment: .leading),
        GridItem(.flexible(), spacing: 18, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.0) { chord, label in
                HStack(spacing: 9) {
                    Text(chord)
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(tokens.fg)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(tokens.inputBgSoft)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(tokens.borderStrong, lineWidth: 1)
                                )
                        )
                    Text(label)
                        .font(Typography.tesseraSans(size: 12))
                        .foregroundStyle(tokens.fgMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
