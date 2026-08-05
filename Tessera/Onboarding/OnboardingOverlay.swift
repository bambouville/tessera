import SwiftUI

/// The top layer of the `ContentView` ZStack while the walkthrough runs. Reads
/// the merged onboarding anchors (resolved through the enclosing
/// `GeometryReader`), dims the screen, spotlights the active target, and floats
/// a callout card. When the controller is `.inactive` it renders nothing and
/// passes every touch through.
///
/// Rendered against the active terminal theme via
/// `TerminalTheme.chromeTokens(applying:)`, so the tour follows the user's
/// palette. Unlike `LockScreenView`, this keeps an opinionated theme's own
/// accent (`respectsUserAccent` gating applies) — the tour highlights sit
/// over themed chrome, whereas the lock screen's only accented element is
/// the brand mark, which always follows the user accent.
struct OnboardingOverlay: View {
    let controller: OnboardingController
    let anchors: [OnboardingTarget: Anchor<CGRect>]
    let geometry: GeometryProxy
    let compact: Bool

    @Environment(AppearancePreferences.self) private var appearance

    /// Padding around a spotlight target (matches the mockup's `pad = 7`).
    private let spotlightPad: CGFloat = 7
    private let spotlightStrokeWidth: CGFloat = 1.5
    private let spotlightEdgeInset: CGFloat = 2
    // Wide enough that the footer (page dots + skip + back + next) stays on a
    // single line even at nine steps — a narrower callout wrapped "skip tour"
    // and "back" onto two lines once the dot row grew.
    @State private var calloutSize: CGSize = CGSize(width: 360, height: 188)

    private var edgeMargin: CGFloat { compact ? 12 : 24 }
    private var usesCompactLandscapeLayout: Bool {
        compact && geometry.size.width > geometry.size.height
    }
    private var calloutWidth: CGFloat {
        min(360, max(280, geometry.size.width - edgeMargin * 2))
    }
    private var centeredCardWidth: CGFloat {
        min(usesCompactLandscapeLayout ? 600 : 478,
            max(280, geometry.size.width - edgeMargin * 2))
    }
    private var maximumCardHeight: CGFloat {
        max(220, geometry.size.height - edgeMargin * 2)
    }

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
                    tourLayer(
                        index: index,
                        step: controller.steps[index].presentation(compact: compact)
                    )
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

                Text(compact
                    ? "A fast terminal for SSH & Mosh — native tmux, remote files, "
                        + "agent-aware controls, and a keyboard built for your phone. "
                        + "Want a quick tour?"
                    : "A fast iPad terminal for SSH & Mosh — trackpad scrolling "
                        + "in TUIs, native tmux, truecolor, edge-to-edge. Want a "
                        + "quick tour?")
                    .tesseraSansScaled(size: 14)
                    .foregroundStyle(tokens.fgMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 22)

                HStack(spacing: 10) {
                    Btn(style: .primary, action: { controller.startTour() }) {
                        Text("take the tour")
                            .lineLimit(1)
                    }

                    Btn(style: .default, action: { controller.skip() }) {
                        Text("skip")
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 30)
            .padding(.bottom, 24)
            // maxWidth (not width) so the card fits narrow screens and the
            // scaled body copy wraps taller instead of clipping.
            .frame(width: min(440, max(280, geometry.size.width - edgeMargin * 2)))
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
                .stroke(tokens.accent, lineWidth: spotlightStrokeWidth)
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

            ViewThatFits(in: .vertical) {
                calloutCard(index: index, step: step, illustration: illustration)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView(.vertical) {
                    calloutCard(index: index, step: step, illustration: illustration)
                }
                .scrollIndicators(.hidden)
            }
            .frame(width: centeredCardWidth)
            .frame(maxHeight: maximumCardHeight)
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
                .lineLimit(1)
                .padding(.bottom, 8)

            Text(step.title)
                .font(Typography.tesseraMono(size: 15, weight: .medium))
                .foregroundStyle(tokens.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.bottom, 7)

            if usesCompactLandscapeLayout, let illustration {
                HStack(alignment: .top, spacing: 12) {
                    bodyText(step.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    illustrationView(illustration)
                        .frame(maxWidth: .infinity)
                }
                .padding(.bottom, 10)
            } else {
                bodyText(step.body)
                    .padding(.bottom, 14)

                if let illustration {
                    illustrationView(illustration)
                        .padding(.bottom, 14)
                }
            }

            footer(index: index, isLast: isLast)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 13)
        .frame(width: illustration == nil ? calloutWidth : centeredCardWidth, alignment: .leading)
        .background(cardBackground)
    }

    private func bodyText(_ body: String) -> some View {
        Text(body)
            .tesseraSansScaled(size: 13)
            .foregroundStyle(tokens.fgMuted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func footer(index: Int, isLast: Bool) -> some View {
        if compact {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    dots(current: index)
                    Spacer(minLength: 8)
                    skipButton
                }

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if index > 0 {
                        calloutButton("back", filled: false) { controller.back() }
                    }
                    calloutButton(isLast ? "done" : "next", filled: true) {
                        controller.next()
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                dots(current: index)
                Spacer(minLength: 8)
                skipButton
                if index > 0 {
                    calloutButton("back", filled: false) { controller.back() }
                }
                calloutButton(isLast ? "done" : "next", filled: true) {
                    controller.next()
                }
            }
        }
    }

    private var skipButton: some View {
        Button(action: { controller.skip() }) {
            Text("skip tour ✕")
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(tokens.fgDim)
                .lineLimit(1)
                .fixedSize()
                .frame(minHeight: compact ? 44 : 0)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding-skip")
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
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(minHeight: compact ? 44 : 0)
                .padding(.vertical, compact ? 0 : 7)
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
        .accessibilityIdentifier("onboarding-\(title)")
    }

    // MARK: - Illustrations

    @ViewBuilder
    private func illustrationView(_ illustration: OnboardingIllustration) -> some View {
        switch illustration {
        case .keySecurity:
            KeySecurityIllustration(tokens: tokens)
        case .mockTerminal:
            MockTerminalIllustration(tokens: tokens, compact: compact)
        case .agentCenter:
            AgentCenterIllustration(tokens: tokens)
        case .swipePad:
            SwipePadGestureIllustration(tokens: tokens)
        case .shortcuts:
            ShortcutsIllustration(tokens: tokens)
        case .filesPanel:
            FilesPanelIllustration(tokens: tokens, compact: compact)
        case .shareInOut:
            ShareInOutIllustration(tokens: tokens, compact: compact)
        case .agentImagePaste:
            AgentImagePasteIllustration(tokens: tokens, compact: compact)
        case .phoneControls:
            PhoneControlsIllustration(tokens: tokens)
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
        Self.spotlightHole(
            for: rect,
            in: CGRect(origin: .zero, size: geometry.size),
            padding: spotlightPad,
            edgeInset: spotlightEdgeInset
        )
    }

    static func spotlightHole(
        for rect: CGRect,
        in bounds: CGRect,
        padding: CGFloat = 7,
        edgeInset: CGFloat = 2
    ) -> CGRect {
        rect.insetBy(dx: -padding, dy: -padding)
            .intersection(bounds.insetBy(dx: edgeInset, dy: edgeInset))
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

// MARK: - Illustration: key security choices

private struct KeySecurityIllustration: View {
    let tokens: DesignTokens

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                keyCard(systemName: "key.horizontal", title: "Ed25519", detail: "recoverable")
                keyCard(systemName: "lock.shield", title: "P-256 Enclave", detail: "device-bound")
            }

            HStack(spacing: 7) {
                Image(systemName: "faceid")
                    .foregroundStyle(tokens.accent)
                Text("biometrics or passcode")
                    .foregroundStyle(tokens.fg)
                Spacer(minLength: 4)
                Text("optional")
                    .foregroundStyle(tokens.fgDim)
            }
            .font(Typography.tesseraMono(size: 10))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(tokens.inputBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(12)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
    }

    private func keyCard(systemName: String, title: String, detail: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemName)
                .font(.system(size: 13))
                .foregroundStyle(tokens.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(tokens.fg)
                Text(detail).foregroundStyle(tokens.fgDim)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .font(Typography.tesseraMono(size: 10))
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(tokens.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.border, lineWidth: 1)
        )
    }
}

// MARK: - Illustration: mock tmux terminal

private struct MockTerminalIllustration: View {
    let tokens: DesignTokens
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            // window tab strip — each tmux window is a tab
            HStack(spacing: 6) {
                tab("1:vim", active: false, bell: false)
                tab("2:server", active: true, bell: true)
                if !compact {
                    tab("3:logs", active: false, bell: false)
                }
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

            if compact {
                // iPhone preserves the tmux split but presents only the focused
                // pane, edge to edge. Never imply an iPad-style side-by-side
                // split on the phone.
                pane(active: true, showCursor: true, lines: [
                    ("$ npm run dev", tokens.fgMuted),
                    ("▸ ready in 240ms", tokens.fgDim),
                    ("✓ localhost:3000", tokens.green),
                ])
            } else {
                // Regular width shows both panes in the active tmux window.
                HStack(alignment: .top, spacing: 0) {
                    pane(active: true, showCursor: true, lines: [
                        ("$ npm run dev", tokens.fgMuted),
                        ("▸ ready in 240ms", tokens.fgDim),
                        ("✓ localhost:3000", tokens.green),
                    ])

                    pane(active: false, showCursor: false, lines: [
                        ("$ tail -f app.log", tokens.fgMuted),
                        ("12:04 GET /   200", tokens.fgDim),
                        ("12:04 GET /api 200", tokens.fgDim),
                        ("12:05 POST /in 201", tokens.fgDim),
                    ])
                    .overlay(alignment: .leading) {
                        Rectangle().fill(tokens.border).frame(width: 1)
                    }
                }
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
    }

    private func pane(active: Bool, showCursor: Bool, lines: [(String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, item in
                Text(item.0)
                    .font(Typography.tesseraMono(size: 11.5))
                    .foregroundStyle(item.1)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showCursor {
                HStack(spacing: 0) {
                    Text("$ ")
                        .font(Typography.tesseraMono(size: 11.5))
                        .foregroundStyle(tokens.fgMuted)
                    Rectangle()
                        .fill(tokens.accent)
                        .frame(width: 7, height: 13)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? tokens.accentSoft : Color.clear)
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
}

// MARK: - Illustration: Agent Center

private struct AgentCenterIllustration: View {
    let tokens: DesignTokens

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("agent center · 3")
                    .font(Typography.tesseraMono(size: 10.5, weight: .medium))
                    .foregroundStyle(tokens.fgMuted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("all sessions")
                    .font(Typography.tesseraMono(size: 9.5))
                    .foregroundStyle(tokens.fgDim)
                    .lineLimit(1)
            }

            agentRow(
                provider: "Codex",
                task: "review authentication flow",
                location: "prod · api",
                status: "needs input",
                color: tokens.amber
            )
            agentRow(
                provider: "Claude Code",
                task: "add the health route",
                location: "dev · server",
                status: "working",
                color: tokens.green
            )
        }
        .padding(12)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
    }

    private func agentRow(
        provider: String,
        task: String,
        location: String,
        status: String,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider)
                    .font(Typography.tesseraMono(size: 10.5, weight: .medium))
                    .foregroundStyle(tokens.fg)
                    .lineLimit(1)
                Text(task)
                    .font(Typography.tesseraSans(size: 10.5))
                    .foregroundStyle(tokens.fgMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(status)
                    .font(Typography.tesseraMono(size: 9.5, weight: .medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
                Text(location)
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(tokens.fgDim)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 46)
        .background(tokens.inputBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.border, lineWidth: 1)
        )
    }
}

// MARK: - Illustration: Swipe Pad center radial

private struct SwipePadGestureIllustration: View {
    let tokens: DesignTokens

    var body: some View {
        ZStack {
            Capsule()
                .fill(tokens.green.opacity(0.45))
                .frame(width: 64, height: 3)
                .offset(x: 45)
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tokens.green)
                .offset(x: 56)

            petal(symbol: "checkmark.shield", label: "always", color: tokens.amber)
                .offset(y: -63)
            petal(symbol: "xmark", label: "deny", color: tokens.red)
                .offset(x: -78)
            petal(symbol: "checkmark", label: "approve", color: tokens.green, active: true)
                .offset(x: 78)
            petal(symbol: "ellipsis", label: "more", color: tokens.fgMuted)
                .offset(y: 63)

            VStack(spacing: 3) {
                Circle()
                    .fill(tokens.accent.opacity(0.22))
                    .overlay(Circle().strokeBorder(tokens.accent, lineWidth: 1.5))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "dot.scope")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(tokens.accent)
                    )
                Text("start")
                    .font(Typography.tesseraMono(size: 9, weight: .medium))
                    .foregroundStyle(tokens.accent)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 184)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
    }

    private func petal(
        symbol: String,
        label: String,
        color: Color,
        active: Bool = false
    ) -> some View {
        VStack(spacing: 3) {
            Circle()
                .fill(color.opacity(active ? 0.32 : 0.16))
                .overlay(
                    Circle().strokeBorder(color.opacity(active ? 0.8 : 0.45), lineWidth: 1)
                )
                .frame(width: active ? 46 : 42, height: active ? 46 : 42)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(color)
                )
            Text(label)
                .font(Typography.tesseraMono(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

// MARK: - Illustration: keyboard-shortcut cheat grid

private struct ShortcutsIllustration: View {
    let tokens: DesignTokens

    private let rows: [(String, String)] = [
        ("⌘N", "new host"),
        ("⌘F", "find in scrollback"),
        ("⌘T", "new tmux window"),
        ("⌘⇧W", "close window"),
        ("⌘1–9", "switch window"),
        ("⌘⇧[ ]", "prev / next window"),
        ("⌘D", "split pane"),
        ("⌘⇧E", "files panel"),
        ("⌘⇧A", "agent center"),
        ("⌘K", "session switcher"),
        ("⌘,", "settings")
    ]

    private let columns = [
        GridItem(.flexible(), spacing: 18, alignment: .leading),
        GridItem(.flexible(), spacing: 18, alignment: .leading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                            .minimumScaleFactor(0.78)
                        Spacer(minLength: 0)
                    }
                }
            }

            Rectangle()
                .fill(tokens.border)
                .frame(height: 1)
                .padding(.vertical, 11)

            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(tokens.fgDim)
                Text("full list in Settings → Keyboard")
                    .font(Typography.tesseraSans(size: 11.5))
                    .foregroundStyle(tokens.fgDim)
            }
        }
    }
}

// MARK: - Illustration: phone terminal controls

private struct PhoneControlsIllustration: View {
    let tokens: DesignTokens

    private let keys = ["esc", "tab", "ctrl", "⌘", "←", "↑", "↓", "→"]
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 4
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "keyboard")
                    .foregroundStyle(tokens.accent)
                Text("software keyboard accessory")
                    .font(Typography.tesseraMono(size: 10.5, weight: .medium))
                    .foregroundStyle(tokens.fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(Typography.tesseraMono(size: 11, weight: .medium))
                        .foregroundStyle(key == "ctrl" ? tokens.accent : tokens.fgMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(key == "ctrl" ? tokens.accentSoft : tokens.inputBgSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(key == "ctrl" ? tokens.accent : tokens.border, lineWidth: 1)
                        )
                }
            }

            HStack(spacing: 12) {
                legend(dot: tokens.accent, text: "tap once · next key")
                legend(dot: tokens.amber, text: "tap twice · locked")
            }
        }
        .padding(12)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
    }

    private func legend(dot: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text)
                .font(Typography.tesseraMono(size: 8.5))
                .foregroundStyle(tokens.fgDim)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Illustration: Remote Files panel beside the shell

/// A mock terminal (left) sitting next to the trailing Files panel (right). The
/// panel's breadcrumb follows the terminal's cwd — the link glyph is accent-tinted
/// to signal "following" — with a few file rows and one in-flight download.
private struct FilesPanelIllustration: View {
    let tokens: DesignTokens
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if !compact {
                terminalColumn
                    .frame(width: 150, alignment: .leading)
            }

            // Hairline divider drawn on the panel's leading edge so it spans the
            // panel's (taller) height exactly, without a greedy `maxHeight`
            // frame that would blow the whole card up to fill the screen.
            panelColumn
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(tokens.border)
                        .frame(width: 1)
                }
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
    }

    private var terminalColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            termLine("~/projects/dashboard", tokens.fgDim)
            termLine("$ npm run build", tokens.fgMuted)
            termLine("  ✓ built in 1.2s", tokens.green.opacity(0.8))
            HStack(spacing: 0) {
                Text("$ ")
                    .font(Typography.tesseraMono(size: 9.5))
                    .foregroundStyle(tokens.fgMuted)
                Rectangle()
                    .fill(tokens.accent)
                    .frame(width: 6, height: 11)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 11)
    }

    private func termLine(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Typography.tesseraMono(size: 9.5))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var panelColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // header
            HStack(spacing: 7) {
                glyph("folder", size: 12, tokens.fgMuted)
                Text("Files")
                    .font(Typography.tesseraMono(size: 12, weight: .semibold))
                    .foregroundStyle(tokens.fg)
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    Circle().fill(tokens.green).frame(width: 5, height: 5)
                    Text("qi@perch")
                        .foregroundStyle(tokens.fgMuted)
                    Text("· sftp")
                        .foregroundStyle(tokens.fgDim)
                }
                .font(Typography.tesseraMono(size: 9))
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 7)

            // breadcrumb — the link glyph is the follow indicator
            HStack(spacing: 6) {
                glyph("link", size: 11, tokens.accent)
                crumbs
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tokens.inputBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(tokens.border, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            // rows
            VStack(spacing: 2) {
                fileRow(chevron: true, expanded: true, glyphName: "folder",
                        name: "src", meta: "12 items", selected: true, progress: nil)
                fileRow(chevron: false, expanded: false, glyphName: "doc",
                        name: "App.tsx", meta: "4.1 KB", selected: false, progress: nil)
                fileRow(chevron: false, expanded: false, glyphName: "photo",
                        name: "screenshot.png", meta: nil, selected: false, progress: 0.64)
                fileRow(chevron: false, expanded: false, glyphName: "doc.text",
                        name: "README.md", meta: "2.3 KB", selected: false, progress: nil)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }

    private var crumbs: some View {
        (Text("~ ").foregroundColor(tokens.fgMuted)
            + Text("/ ").foregroundColor(tokens.fgFaint)
            + Text("projects ").foregroundColor(tokens.fgMuted)
            + Text("/ ").foregroundColor(tokens.fgFaint)
            + Text("dashboard").foregroundColor(tokens.fg))
            .font(Typography.tesseraMono(size: 10))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileRow(
        chevron: Bool, expanded: Bool, glyphName: String,
        name: String, meta: String?, selected: Bool, progress: Double?
    ) -> some View {
        HStack(spacing: 7) {
            // disclosure slot — fixed width so names align whether or not a
            // chevron is present.
            Group {
                if chevron {
                    glyph("chevron.right", size: 8, tokens.fgDim)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .frame(width: 9, alignment: .leading)

            glyph(glyphName, size: 11, tokens.fgMuted)

            Text(name)
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(tokens.fg)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let progress {
                HStack(spacing: 5) {
                    ProgressBar(fraction: progress, tokens: tokens)
                        .frame(width: 44, height: 3)
                    Text("\(Int(progress * 100))%")
                        .font(Typography.tesseraMono(size: 9))
                        .foregroundStyle(tokens.accent)
                }
            } else if let meta {
                Text(meta)
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(tokens.fgDim)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? tokens.accentSoft : Color.clear)
        )
    }

    private func glyph(_ name: String, size: CGFloat, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
    }
}

/// A tiny determinate bar used by the Files-panel illustration's download row.
private struct ProgressBar: View {
    let fraction: Double
    let tokens: DesignTokens

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tokens.inputBgSoft)
                Capsule().fill(tokens.accent)
                    .frame(width: proxy.size.width * fraction)
            }
        }
    }
}

// MARK: - Illustration: share in & out

/// The native iOS share sheet, both directions. Top lane: a remote file exported
/// OUT to Files / Mail / Messages. Bottom lane: a photo shared IN, landing on the
/// host. Monochrome app tiles — no literal colored app icons.
private struct ShareInOutIllustration: View {
    let tokens: DesignTokens
    let compact: Bool

    var body: some View {
        if compact {
            compactBody
        } else {
            regularBody
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            compactLane(
                directionLabel: "OUT",
                directionGlyph: "arrow.up",
                fileGlyph: "doc",
                fileName: "server.log",
                destination: "Files · Mail · Messages"
            )
            Rectangle().fill(tokens.border).frame(height: 1)
            compactLane(
                directionLabel: "IN",
                directionGlyph: "arrow.down",
                fileGlyph: "photo",
                fileName: "photo.heic",
                destination: "qi@perch · ~/projects"
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
    }

    private func compactLane(
        directionLabel: String,
        directionGlyph: String,
        fileGlyph: String,
        fileName: String,
        destination: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                direction(directionLabel, arrow: directionGlyph)
                chip(glyphName: fileGlyph, name: fileName, size: nil)
                Spacer(minLength: 0)
            }
            HStack(spacing: 7) {
                glyph("arrow.turn.down.right", size: 12, tokens.fgDim)
                Text(destination)
                    .font(Typography.tesseraMono(size: 9.5))
                    .foregroundStyle(tokens.fgMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.leading, 8)
        }
    }

    private var regularBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // OUT — remote file to apps
            HStack(spacing: 9) {
                direction("OUT", arrow: "arrow.up")
                chip(glyphName: "doc", name: "server.log", size: "18 MB")
                glyph("arrow.right", size: 15, tokens.fgDim)
                HStack(spacing: 6) {
                    appTile("folder")
                    appTile("envelope")
                    appTile("message")
                }
            }

            Rectangle()
                .fill(tokens.border)
                .frame(height: 1)
                .padding(.vertical, 10)

            // IN — a shared photo landing on the host
            HStack(spacing: 9) {
                direction("IN", arrow: "arrow.down")
                chip(glyphName: "photo", name: "photo.heic", size: nil)
                glyph("arrow.right", size: 15, tokens.fgDim)
                hostChip
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
    }

    private func direction(_ label: String, arrow: String) -> some View {
        HStack(spacing: 5) {
            glyph(arrow, size: 12, tokens.accent)
            Text(label)
                .font(Typography.tesseraMono(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(tokens.accent)
        }
        .frame(width: 46, alignment: .leading)
    }

    private func chip(glyphName: String, name: String, size: String?) -> some View {
        HStack(spacing: 6) {
            glyph(glyphName, size: 12, tokens.fgMuted)
            Text(name)
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(tokens.fg)
            if let size {
                Text(size)
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(tokens.fgDim)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tokens.inputBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tokens.border, lineWidth: 1)
                )
        )
    }

    private func appTile(_ glyphName: String) -> some View {
        glyph(glyphName, size: 15, tokens.fgMuted)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tokens.inputBgSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(tokens.border, lineWidth: 1)
                    )
            )
    }

    private var hostChip: some View {
        HStack(spacing: 6) {
            glyph("folder", size: 12, tokens.accent)
            (Text("qi@perch ").foregroundColor(tokens.fg)
                + Text("~/projects").foregroundColor(tokens.fgDim))
                .font(Typography.tesseraMono(size: 10))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tokens.accentSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tokens.accent.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func glyph(_ name: String, size: CGFloat, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
    }
}

// MARK: - Illustration: agent image paste

/// "Paste a screenshot": a share/drop source pill, the upload connector, and the
/// agent composer showing the realistic `[Image #1]` token Claude Code / Codex
/// render once the injected path is recognized.
private struct AgentImagePasteIllustration: View {
    let tokens: DesignTokens
    let compact: Bool

    private let brandColor = Color(rgbInt: 0xD97757)

    var body: some View {
        VStack(spacing: 0) {
            // source pill
            HStack(spacing: 8) {
                glyph("photo", size: 14, tokens.accent)
                Text(compact ? "share a screenshot" : "share or drop a screenshot")
                    .font(Typography.tesseraSans(size: 11.5))
                    .foregroundStyle(tokens.fg)
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(tokens.inputBgSoft)
                    .overlay(Capsule().strokeBorder(tokens.accent, lineWidth: 1))
            )
            .shadow(color: Color.black.opacity(0.5), radius: 10, y: 6)

            // connector
            VStack(spacing: 3) {
                glyph("arrow.down", size: 15, tokens.fgDim)
                Text(compact ? "upload · type path" : "uploads to ~/.cache/tessera/ · types the path")
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(tokens.fgDim)
                    .lineLimit(1)
            }
            .padding(.top, 8)
            .padding(.bottom, 9)

            // agent composer with the [Image #1] token
            HStack(spacing: 0) {
                Text("› ")
                    .foregroundStyle(tokens.fgDim)
                if !compact {
                    Text("compare against this layout ")
                        .foregroundStyle(tokens.fg)
                }
                Text("[Image #1]")
                    .foregroundStyle(tokens.accent)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tokens.accentSoft)
                    )
                Rectangle()
                    .fill(tokens.fgMuted)
                    .frame(width: 5, height: 12)
                    .padding(.leading, 2)
                Spacer(minLength: 0)
            }
            .font(Typography.tesseraMono(size: 11))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(tokens.borderStrong, lineWidth: 1)
            )

            // caption
            HStack(spacing: 7) {
                Circle()
                    .fill(brandColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: brandColor.opacity(0.7), radius: 4)
                Text(compact
                    ? "Claude Code & Codex attach the image"
                    : "Claude Code & Codex read the path and attach the image")
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(tokens.fgDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
    }

    private func glyph(_ name: String, size: CGFloat, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
    }
}
