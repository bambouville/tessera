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
    // Wide enough that the footer (page dots + skip + back + next) stays on a
    // single line even at eight steps — a narrower callout wrapped "skip tour"
    // and "back" onto two lines once the dot row grew.
    private let calloutWidth: CGFloat = 360
    private let centeredCardWidth: CGFloat = 478

    @State private var calloutSize: CGSize = CGSize(width: 360, height: 188)

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
                        .lineLimit(1)
                        .fixedSize()
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
                .lineLimit(1)
                .fixedSize()
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
        case .filesPanel:
            FilesPanelIllustration(tokens: tokens)
        case .shareInOut:
            ShareInOutIllustration(tokens: tokens)
        case .agentImagePaste:
            AgentImagePasteIllustration(tokens: tokens)
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
            // window tab strip — each tmux window is a tab
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

            // the active window, split into two panes — the left pane is
            // focused (accent wash + cursor), a hairline splits it from the right
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

// MARK: - Illustration: simulated Claude Code prompt + swipe-pad puck

private struct ClaudeCodePromptIllustration: View {
    let tokens: DesignTokens

    private let brandColor = Color(rgbInt: 0xD97757)

    var body: some View {
        // Prompt on the left, puck on the right — side by side rather than the
        // puck overlaid on the prompt, which collided with the message text and
        // clipped the "approve" petal against the card edge.
        HStack(alignment: .center, spacing: 12) {
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

                Text("● I'll add the /health route.")
                    .font(Typography.tesseraMono(size: 11.5))
                    .foregroundStyle(tokens.fg)
                    .lineLimit(1)
                Text("  ⎿ Edit(src/server.ts)")
                    .font(Typography.tesseraMono(size: 11.5))
                    .foregroundStyle(tokens.fgDim)
                    .lineLimit(1)
                    .padding(.bottom, 9)

                // permission box
                VStack(alignment: .leading, spacing: 7) {
                    (Text("Edit ")
                        + Text("src/server.ts").foregroundColor(tokens.accent)
                        + Text("?"))
                        .font(Typography.tesseraMono(size: 11.5))
                        .foregroundStyle(tokens.fg)
                        .lineLimit(1)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("❯ 1. Yes")
                            .foregroundStyle(tokens.accent)
                        Text("  2. Yes, don't ask again")
                            .foregroundStyle(tokens.fgMuted)
                        Text("  3. No, tell Claude")
                            .foregroundStyle(tokens.fgMuted)
                    }
                    .font(Typography.tesseraMono(size: 11.5))
                    .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tokens.borderStrong, lineWidth: 1)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PuckPetalsIllustration(tokens: tokens)
                .frame(width: 146, height: 150)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
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
        ("⌘⇧W", "close window"),
        ("⌘1–9", "switch window"),
        ("⌘⇧[ ]", "prev / next window"),
        ("⌘D", "split pane"),
        ("⌘⇧E", "files panel"),
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

// MARK: - Illustration: Remote Files panel beside the shell

/// A mock terminal (left) sitting next to the trailing Files panel (right). The
/// panel's breadcrumb follows the terminal's cwd — the link glyph is accent-tinted
/// to signal "following" — with a few file rows and one in-flight download.
private struct FilesPanelIllustration: View {
    let tokens: DesignTokens

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            terminalColumn
                .frame(width: 150, alignment: .leading)

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

    var body: some View {
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

    private let brandColor = Color(rgbInt: 0xD97757)

    var body: some View {
        VStack(spacing: 0) {
            // source pill
            HStack(spacing: 8) {
                glyph("photo", size: 14, tokens.accent)
                Text("share or drop a screenshot")
                    .font(Typography.tesseraSans(size: 11.5))
                    .foregroundStyle(tokens.fg)
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
                Text("uploads to ~/.cache/tessera/ · types the path")
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(tokens.fgDim)
            }
            .padding(.top, 8)
            .padding(.bottom, 9)

            // agent composer with the [Image #1] token
            HStack(spacing: 0) {
                Text("› ")
                    .foregroundStyle(tokens.fgDim)
                Text("compare against this layout ")
                    .foregroundStyle(tokens.fg)
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
                Text("Claude Code & Codex read the path and attach the image")
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(tokens.fgDim)
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
