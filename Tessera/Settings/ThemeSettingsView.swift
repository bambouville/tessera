// Tessera/Settings/ThemeSettingsView.swift
// Wave 1 stub — Codex-B fills body. 2-column grid of theme preview cards
// (Void / Graphite / Amber CRT / Paper / Dracula / Nord). Selection persists
// to AppearancePreferences.terminalThemeID. SwiftTerm wiring deferred to W2.
import SwiftUI

struct ThemeSettingsView: View {
    @Environment(\.designTokens) private var T
    @Environment(AppearancePreferences.self) private var appearance

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsH("themes")

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(TerminalTheme.all) { theme in
                        card(for: theme)
                    }
                }

                backgroundSection
                    .padding(.top, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(T.bg)
    }

    // MARK: - Background picture

    private var selectedTheme: TerminalTheme {
        TerminalTheme.find(id: appearance.terminalThemeID)
    }

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("background")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)

            HStack(spacing: 8) {
                backgroundModeButton(usesImage: false, label: "theme color")
                backgroundModeButton(usesImage: true, label: "custom image")
            }
            .animation(.easeInOut(duration: 0.15), value: appearance.terminalBackgroundUsesImage)

            if appearance.terminalBackgroundUsesImage {
                TerminalBackgroundImageControls(
                    imageID: appearance.terminalBackgroundImageID,
                    dim: appearance.terminalBackgroundDim,
                    blur: appearance.terminalBackgroundBlur,
                    fillMode: TerminalBackgroundFillMode(
                        rawValue: appearance.terminalBackgroundFillMode
                    ) ?? .fill,
                    theme: selectedTheme,
                    onImport: { data in
                        guard let imported = TerminalBackgroundImageStore.importImage(data: data) else {
                            NSLog("[TerminalBackground] global import failed")
                            return
                        }
                        if let old = appearance.terminalBackgroundImageID {
                            TerminalBackgroundImageStore.delete(id: old)
                        }
                        appearance.terminalBackgroundImageID = imported.id
                    },
                    onRemove: {
                        if let old = appearance.terminalBackgroundImageID {
                            TerminalBackgroundImageStore.delete(id: old)
                        }
                        appearance.terminalBackgroundImageID = nil
                        appearance.terminalBackgroundUsesImage = false
                    },
                    onDimChanged: { appearance.terminalBackgroundDim = $0 },
                    onBlurChanged: { appearance.terminalBackgroundBlur = $0 },
                    onFillModeChanged: { appearance.terminalBackgroundFillMode = $0.rawValue }
                )

                if appearance.terminalBackgroundImageID != nil {
                    Text("applies to every session unless a host overrides it. full-screen apps that set their own colors (vim, htop) paint over the picture.")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("solid color from the selected theme.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
            }
        }
    }

    private func backgroundModeButton(usesImage: Bool, label: String) -> some View {
        let isSelected = appearance.terminalBackgroundUsesImage == usesImage
        return Btn(
            style: isSelected ? .primary : .default,
            full: true,
            action: { appearance.terminalBackgroundUsesImage = usesImage }
        ) {
            Text(label)
                .font(Typography.tesseraMono(size: 13, weight: isSelected ? .semibold : .regular))
        }
    }

    private func card(for theme: TerminalTheme) -> some View {
        let selected = appearance.terminalThemeID == theme.id

        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("$ ls -la")
                    .foregroundStyle(theme.fg)
                Text("drwxr-xr-x  projects/")
                    .foregroundStyle(theme.accent)
                Text("-rw-r--r--  readme.md")
                    .foregroundStyle(theme.fg.opacity(0.6))
            }
            .font(Typography.tesseraMono(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .background(theme.bg)

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.bg)
                    .frame(width: 10, height: 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(T.border, lineWidth: 1)
                    )

                Text(theme.name)
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fg)

                Spacer(minLength: 8)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(T.accent)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(T.accentSoft)
                    .padding(-4)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? T.accent : T.border, lineWidth: selected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            appearance.terminalThemeID = theme.id
        }
    }
}
