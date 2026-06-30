// Tessera/Settings/AppearanceSettingsView.swift
// Mode (system/dark/light), accent, font size slider, top bar height.
// All wired to AppearancePreferences.
import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(\.designTokens) private var T
    @Environment(\.colorScheme) private var systemColorScheme

    private let modes: [AppearanceModeOption] = [.system, .dark, .light]

    var body: some View {
        @Bindable var appearance = appearance

        VStack(alignment: .leading, spacing: 0) {
            SettingsH("appearance")

            Field(label: "mode", sub: "affects app chrome — terminal uses its own theme") {
                HStack(spacing: 10) {
                    ForEach(modes, id: \.rawValue) { mode in
                        modeCard(
                            mode,
                            selected: appearance.mode == mode
                        ) {
                            appearance.mode = mode
                        }
                    }
                }
            }

            Field(
                label: "chrome material",
                sub: "sidebar, top bar, and accessory bar surface — options the device can't render are hidden"
            ) {
                HStack(spacing: 10) {
                    ForEach(ChromeMaterial.supportedCases) { mat in
                        materialCard(
                            mat,
                            selected: appearance.chromeMaterial == mat
                        ) {
                            appearance.chromeMaterial = mat
                        }
                    }
                }
            }

            Field(label: "accent color") {
                HStack(spacing: 10) {
                    ForEach(AccentName.allCases, id: \.rawValue) { accent in
                        accentCard(
                            accent,
                            selected: appearance.accent == accent
                        ) {
                            appearance.accent = accent
                        }
                    }
                }
            }

            Field(label: "terminal font size · \(Int(appearance.fontSize)) pt") {
                VStack(alignment: .leading, spacing: 12) {
                    fontSizePreview

                    Slider(value: $appearance.fontSize, in: 10...20, step: 1)
                        .tint(T.accent)
                }
            }

            Field(
                label: "top bar height · \(Int(appearance.topBarHeight)) pt",
                sub: "drives both the absolute strip height and the proportional size of icons, tabs, and labels inside it"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    TopBarHeightPreview(height: appearance.topBarHeight)

                    Slider(
                        value: $appearance.topBarHeight,
                        in: AppearancePreferences.topBarHeightRange,
                        step: 1
                    )
                    .tint(T.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func materialCard(
        _ mat: ChromeMaterial,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(mat.label)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(selected ? T.accent : T.fg)

                Text(mat.caption)
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? T.accent : T.border, lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func modeCard(
        _ mode: AppearanceModeOption,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let preview = previewColors(for: mode)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                Text("$ whoami\nuser\n$ _")
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(preview.fg)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(preview.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 6) {
                    Text(mode.rawValue)
                        .font(Typography.tesseraMono(size: 12))
                        .foregroundStyle(selected ? T.accent : T.fg)

                    Spacer(minLength: 0)

                    if selected {
                        Text("active")
                            .font(Typography.tesseraMono(size: 10))
                            .foregroundStyle(T.accent)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? T.accent : T.border, lineWidth: selected ? 1.5 : 1)
            )
            .shadow(color: selected ? T.accentSoft : Color.clear, radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }

    /// Each mode card paints its preview with that mode's own bg/fg, regardless
    /// of the current environment's resolved tokens. Without this, the inactive
    /// card's text inherits the active mode's `fgMuted` and the contrast can
    /// invert (light-on-light or dark-on-dark) depending on which mode is live.
    private func previewColors(for mode: AppearanceModeOption) -> (bg: Color, fg: Color) {
        switch mode {
        case .dark:
            return (.black, .white.opacity(0.65))
        case .light:
            return (.white, .black.opacity(0.65))
        case .system:
            return systemColorScheme == .light
                ? (.white, .black.opacity(0.65))
                : (.black, .white.opacity(0.65))
        }
    }

    /// Live mockup of the terminal font at the user's chosen size. Updates
    /// continuously as the slider moves. Sized to match the current
    /// `appearance.fontSize` — same JetBrainsMono used in the live terminal,
    /// so the preview is faithful.
    private var fontSizePreview: some View {
        let preview = previewColors(for: appearance.mode)
        return Text("$ ls projects/\ntessera/  notes.md")
            .font(Typography.tesseraMono(size: appearance.fontSize))
            .foregroundStyle(preview.fg)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(preview.bg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(T.border, lineWidth: 1)
            )
    }

    @ViewBuilder
    private func accentCard(
        _ accent: AccentName,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if accent == .custom {
            customAccentCard(selected: selected, action: action)
        } else {
            Button(action: action) {
                VStack(spacing: 8) {
                    Circle()
                        .fill(swatchColor(for: accent))
                        .frame(width: 24, height: 24)

                    Text(accent.rawValue)
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(selected ? T.accent : T.fgMuted)
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(T.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? T.accent : T.border, lineWidth: selected ? 1.5 : 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// Custom card hosts a SwiftUI `ColorPicker`. Tapping the swatch opens the
    /// system picker; selecting a color sets `accent = .custom` and persists
    /// the chosen RGB so it survives across launches.
    private func customAccentCard(
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        @Bindable var appearance = appearance

        let pickerBinding = Binding<Color>(
            get: { Color(rgbInt: appearance.customAccentRGB) },
            set: { newColor in
                appearance.customAccentRGB = rgbInt(of: newColor)
                appearance.accent = .custom
            }
        )

        return ZStack {
            VStack(spacing: 8) {
                Circle()
                    .fill(Color(rgbInt: appearance.customAccentRGB))
                    .frame(width: 24, height: 24)

                Text("custom")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(selected ? T.accent : T.fgMuted)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? T.accent : T.border, lineWidth: selected ? 1.5 : 1)
            )

            ColorPicker("custom accent", selection: pickerBinding, supportsOpacity: false)
                .labelsHidden()
                .opacity(0.02)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .simultaneousGesture(TapGesture().onEnded { action() })
    }

    private func swatchColor(for accent: AccentName) -> Color {
        switch accent {
        case .blue:
            return Color(red: 61.0 / 255.0, green: 158.0 / 255.0, blue: 255.0 / 255.0)
        case .green:
            return Color(red: 74.0 / 255.0, green: 222.0 / 255.0, blue: 128.0 / 255.0)
        case .amber:
            return Color(red: 252.0 / 255.0, green: 211.0 / 255.0, blue: 77.0 / 255.0)
        case .custom:
            return Color(rgbInt: appearance.customAccentRGB)
        }
    }

    private func rgbInt(of color: Color) -> Int {
        let ui = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int(round(r * 255)) << 16) | (Int(round(g * 255)) << 8) | Int(round(b * 255))
    }
}

/// Live miniature of the in-session top bar at the chosen height. Mirrors
/// the v2 layout used by `SessionTopBar` (sidebar toggle, host pill with
/// tmux tag, three tabs with the active one accent-tinted, `+`, and home)
/// and applies the same `height / defaultTopBarHeight` scale factor to
/// every interior literal so the preview tracks the live bar 1:1. Built
/// against the user's active TerminalTheme so theme switches reflow the
/// preview chrome.
private struct TopBarHeightPreview: View {
    let height: Double

    @Environment(AppearancePreferences.self) private var appearance

    private var theme: TerminalTheme {
        TerminalTheme.find(id: appearance.terminalThemeID)
    }

    private var T: DesignTokens {
        theme.chromeTokens(applying: appearance)
    }

    /// Same formula as `SessionTopBar.scale` — keeps the preview's
    /// proportions in lockstep with the live bar.
    private var scale: CGFloat {
        max(0.6, CGFloat(height) / CGFloat(AppearancePreferences.defaultTopBarHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                chromeIcon("sidebar.left")

                hostPill

                tabRow

                Spacer(minLength: 4)

                plusButton

                chromeIcon("house")
            }
            .padding(.horizontal, 14)
            .frame(height: CGFloat(height))
            .frame(maxWidth: .infinity)
            .background(theme.bg)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(T.border)
                    .frame(height: 0.5)
            }

            // A sliver of "terminal canvas" so the preview reads as a
            // device frame rather than a floating bar — same bg as the
            // chrome, so the seam between them is invisible until the
            // border above kicks in.
            Text("(base) user@ipad ~ %")
                .font(Typography.tesseraMono(size: max(9, 11 * scale)))
                .foregroundStyle(theme.fg.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(theme.bg)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(T.border, lineWidth: 1)
        )
    }

    private func chromeIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14 * scale, weight: .medium))
            .foregroundStyle(T.fgMuted)
            .frame(width: 28 * scale, height: 24 * scale)
    }

    private var hostPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(T.green)
                .frame(width: 7 * scale, height: 7 * scale)
            Text("Local Mac")
                .font(Typography.tesseraMono(size: 12 * scale, weight: .medium))
                .foregroundStyle(T.fg)
            Text("·")
                .font(Typography.tesseraMono(size: 11 * scale))
                .foregroundStyle(T.fgDim)
            Text("tmux")
                .font(.system(size: 10 * scale, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(T.fgMuted)
        }
    }

    private var tabRow: some View {
        HStack(spacing: 2) {
            previewTab(name: "codex", number: 1, isActive: false)
            previewTab(name: "build", number: 2, isActive: true)
            previewTab(name: "zsh",   number: 3, isActive: false)
        }
    }

    private func previewTab(name: String, number: Int, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(Typography.tesseraMono(size: 12 * scale, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? T.fg : T.fgMuted)
            Text("⌘\(number)")
                .font(Typography.tesseraMono(size: 10.5 * scale))
                .foregroundStyle(isActive ? T.accent : T.fgFaint)
        }
        .padding(.horizontal, 9)
        .frame(height: 24 * scale)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? T.accentSoft : SwiftUI.Color.clear)
        )
    }

    private var plusButton: some View {
        Image(systemName: "plus")
            .font(.system(size: 10 * scale, weight: .semibold))
            .foregroundStyle(T.fgMuted)
            .frame(width: 22 * scale, height: 22 * scale)
            .background(
                Circle()
                    .strokeBorder(T.borderStrong, lineWidth: 0.5)
            )
    }
}
