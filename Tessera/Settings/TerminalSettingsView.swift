// Tessera/Settings/TerminalSettingsView.swift
// Wave 1 stub — Codex-A fills body. Cursor style (block/bar/underline),
// cursor blink toggle, scrollback slider (1000–50000). Wired to AppearancePreferences.
import SwiftUI
import UIKit
import UserNotifications

struct TerminalSettingsView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(BellController.self) private var bellController
    @Environment(\.designTokens) private var T

    @State private var showDenialSheet = false

    var body: some View {
        @Bindable var appearance = appearance

        VStack(alignment: .leading, spacing: 0) {
            SettingsH("terminal")

            Field(label: "preview") {
                cursorPreview
            }

            Field(label: "cursor style") {
                HStack(spacing: 8) {
                    ForEach(CursorStyleOption.allCases, id: \.rawValue) { style in
                        cursorChip(
                            style,
                            selected: appearance.cursorStyle == style
                        ) {
                            appearance.cursorStyle = style
                        }
                    }
                }
            }

            ToggleRow(
                title: "cursor blink",
                subtitle: "blink the terminal cursor",
                isOn: $appearance.cursorBlink
            )
            .padding(.bottom, 18)

            Field(label: "scrollback lines · \(appearance.scrollbackLines)") {
                Slider(
                    value: Binding(
                        get: { Double(appearance.scrollbackLines) },
                        set: { appearance.scrollbackLines = Int($0) }
                    ),
                    in: 1000...50000,
                    step: 1000
                )
                .tint(T.accent)
            }
            .padding(.bottom, 24)

            SettingsH("startup")
                .padding(.top, 6)

            Field(label: "previous connections", sub: startupPolicyDescription) {
                HStack(spacing: 8) {
                    ForEach(SessionRestorePolicy.allCases, id: \.rawValue) { policy in
                        startupPolicyChip(
                            policy,
                            selected: appearance.sessionRestorePolicy == policy
                        ) {
                            appearance.sessionRestorePolicy = policy
                        }
                    }
                }
            }
            .padding(.bottom, 24)

            // §bell — quiet-by-default agent-turn-complete signaling.
            // Sound is OFF, visual + notification ON, matching the
            // "ping me when I'm not looking" design intent.
            SettingsH("bell")
                .padding(.top, 6)

            ToggleRow(
                title: "sound",
                subtitle: "soft tink when an agent finishes its turn · mixes with music",
                isOn: $appearance.bellSoundEnabled
            )

            ToggleRow(
                title: "visual flash",
                subtitle: "accent glow + dot on the tmux tab pill that bell'd",
                isOn: $appearance.bellVisualEnabled
            )

            ToggleRow(
                title: "notify when backgrounded",
                subtitle: "banner ping when tessera isn't focused",
                isOn: $appearance.bellNotificationEnabled
            )
            .onChange(of: appearance.bellNotificationEnabled) { _, newValue in
                guard newValue else { return }
                Task {
                    let status = await bellController.requestPermissionIfNeeded()
                    if status == .denied { showDenialSheet = true }
                }
            }
            .padding(.bottom, 12)

            Button(action: testBell) {
                Text("test bell")
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.accent)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(T.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(T.accent.opacity(0.7), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showDenialSheet) {
            BellPermissionDenialSheet()
        }
        .task {
            // First-visit nudge: if the user hasn't been asked yet
            // and the toggle is on (default), trigger the iOS prompt
            // so the away-channel actually works without them having
            // to flip the switch off-and-on. No-op once the system
            // status is determined either way.
            guard appearance.bellNotificationEnabled else { return }
            _ = await bellController.requestPermissionIfNeeded()
        }
    }

    /// Fire a synthetic bell so users can audit their channel choices.
    /// `isOriginOnScreen: false` ensures sound + notification routes
    /// fire even though we're technically in the foreground; the bell
    /// is "from the test button," not "from the pane the user is
    /// staring at."
    private func testBell() {
        bellController.ring(
            source: .session(UUID()),
            isOriginOnScreen: false,
            hostDisplayName: "tessera",
            paneTitle: "test"
        )
    }

    private var startupPolicyDescription: String {
        switch appearance.sessionRestorePolicy {
        case .ask:
            return "ask before reopening saved-host sessions on fresh launch"
        case .always:
            return "reopen restorable saved-host sessions without prompting"
        case .never:
            return "do not remember previous saved-host sessions"
        }
    }

    /// Live cursor preview. Mirrors the actual terminal canvas, which is
    /// pinned to black regardless of app theme — so the preview color choices
    /// are also fixed (white text on black bg) instead of following T tokens.
    private var cursorPreview: some View {
        HStack(alignment: .center, spacing: 0) {
            Text("$ echo hello")
                .font(Typography.tesseraMono(size: appearance.fontSize))
                .foregroundStyle(.white.opacity(0.85))

            BlinkingCursor(
                style: appearance.cursorStyle,
                blink: appearance.cursorBlink,
                fontSize: appearance.fontSize
            )
            .padding(.leading, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(T.border, lineWidth: 1)
        )
    }

    private func cursorChip(
        _ style: CursorStyleOption,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(style.rawValue)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(selected ? T.accent : T.fgMuted)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(selected ? T.accentSoft : T.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? T.accent : T.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func startupPolicyChip(
        _ policy: SessionRestorePolicy,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(policy.rawValue)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(selected ? T.accent : T.fgMuted)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(selected ? T.accentSoft : T.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? T.accent : T.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Renders one of three cursor shapes inside a fixed mono-cell-sized box,
/// optionally toggling visibility on a 1Hz cycle. `TimelineView(.periodic)`
/// re-renders the body twice per second so blinking happens for free without
/// state plumbing.
private struct BlinkingCursor: View {
    let style: CursorStyleOption
    let blink: Bool
    let fontSize: Double

    var body: some View {
        let cellWidth = CGFloat(fontSize) * 0.6
        let cellHeight = CGFloat(fontSize) * 1.2
        let strokeThickness = max(1.5, CGFloat(fontSize) * 0.1)
        let cursorColor = Color.white.opacity(0.9)

        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = !blink
                || (Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0)

            ZStack(alignment: alignment(for: style)) {
                Color.clear
                    .frame(width: cellWidth, height: cellHeight)

                shape(width: cellWidth, height: cellHeight, stroke: strokeThickness)
                    .foregroundStyle(cursorColor)
                    .opacity(on ? 1 : 0)
            }
        }
    }

    private func alignment(for style: CursorStyleOption) -> Alignment {
        switch style {
        case .block:     return .center
        case .bar:       return .leading
        case .underline: return .bottom
        }
    }

    @ViewBuilder
    private func shape(width: CGFloat, height: CGFloat, stroke: CGFloat) -> some View {
        switch style {
        case .block:
            Rectangle().frame(width: width, height: height)
        case .bar:
            Rectangle().frame(width: stroke, height: height)
        case .underline:
            Rectangle().frame(width: width, height: stroke)
        }
    }
}

/// Shown when the user enables "notify when backgrounded" but iOS
/// returns `.denied` — either because they tapped Don't Allow on the
/// permission prompt or because notifications are off in Settings.app.
/// Sends them straight to Settings.app for tessera so they can flip
/// it back on without hunting through the menu tree.
private struct BellPermissionDenialSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.designTokens) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("notifications denied")
                .font(Typography.tesseraMono(size: 16, weight: .semibold))
                .foregroundStyle(T.fg)

            Text("tessera can't send you a banner when an agent finishes if iOS notifications are off. flip them on in settings → tessera → notifications, then come back.")
                .font(Typography.tesseraMono(size: 13))
                .foregroundStyle(T.fgMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    dismiss()
                } label: {
                    Text("open settings")
                        .font(Typography.tesseraMono(size: 13, weight: .medium))
                        .foregroundStyle(T.fg)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .background(T.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(T.accent, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button("not now") { dismiss() }
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fgMuted)
                    .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(T.bg)
    }
}
