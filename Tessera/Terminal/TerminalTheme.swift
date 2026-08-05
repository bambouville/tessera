// Tessera/Terminal/TerminalTheme.swift
// Named terminal color schemes. UI consumes the SwiftUI `Color` accessors;
// the SwiftTerm wiring (TerminalSurfaceBound.applyAppearance) reads the raw
// `Int` RGB fields directly so this module doesn't have to import SwiftTerm
// (which name-collides with SwiftUI.Color).
import SwiftUI

struct TerminalTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let bgRGB: Int
    let fgRGB: Int
    let accentRGB: Int
    /// 16-color ANSI palette. Indices 0–7 are the standard normal-intensity
    /// colors (black, red, green, yellow, blue, magenta, cyan, white) and
    /// 8–15 are their bright variants. SwiftTerm.installColors requires
    /// exactly 16 entries.
    let ansi: [Int]

    var bg: Color { Color(rgbInt: bgRGB) }
    var fg: Color { Color(rgbInt: fgRGB) }
    var accent: Color { Color(rgbInt: accentRGB) }

    static let all: [TerminalTheme] = [
        TerminalTheme(
            id: "void",
            name: "Void",
            bgRGB: 0x000000,
            fgRGB: 0xD4D4D4,
            accentRGB: 0x5B9FFF,
            // VS Code Dark+ palette — neutral and high-contrast on pure black.
            ansi: [
                0x000000, 0xCD3131, 0x0DBC79, 0xE5E510,
                0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
                0x666666, 0xF14C4C, 0x23D18B, 0xF5F543,
                0x3B8EEA, 0xD670D6, 0x29B8DB, 0xE5E5E5
            ]
        ),
        TerminalTheme(
            id: "graphite",
            name: "Graphite",
            bgRGB: 0x1C1C1E,
            fgRGB: 0xEEEEEE,
            accentRGB: 0x30D158,
            // macOS Terminal "Pro" classic — saturated normals, brighter highs.
            ansi: [
                0x000000, 0x990000, 0x00A600, 0x999900,
                0x0000B2, 0xB200B2, 0x00A6B2, 0xBFBFBF,
                0x666666, 0xE50000, 0x00D900, 0xE5E500,
                0x0000FF, 0xE500E5, 0x00E5E5, 0xE5E5E5
            ]
        ),
        TerminalTheme(
            id: "amber",
            name: "Amber CRT",
            bgRGB: 0x0A0600,
            fgRGB: 0xFFB000,
            accentRGB: 0xFFB000,
            // CRT phosphor: every ANSI slot is an amber shade. Programs that
            // expect distinct colors will see brightness variation only.
            ansi: [
                0x1A1000, 0xB07300, 0xB07300, 0xFFB000,
                0xB07300, 0xFFB000, 0xB07300, 0xFFB000,
                0x503500, 0xFFB000, 0xFFB000, 0xFFCB42,
                0xFFB000, 0xFFCB42, 0xFFB000, 0xFFCB42
            ]
        ),
        TerminalTheme(
            id: "paper",
            name: "Paper",
            bgRGB: 0xFAFAFA,
            fgRGB: 0x111111,
            accentRGB: 0x0066CC,
            // Solarized Light — the canonical light-bg ANSI palette.
            ansi: [
                0x073642, 0xDC322F, 0x859900, 0xB58900,
                0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
                0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3
            ]
        ),
        TerminalTheme(
            id: "dracula",
            name: "Dracula",
            bgRGB: 0x282A36,
            fgRGB: 0xF8F8F2,
            accentRGB: 0xBD93F9,
            // Canonical Dracula palette per draculatheme.com/contribute.
            ansi: [
                0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C,
                0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5,
                0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF
            ]
        ),
        TerminalTheme(
            id: "nord",
            name: "Nord",
            bgRGB: 0x2E3440,
            fgRGB: 0xD8DEE9,
            accentRGB: 0x88C0D0,
            // Canonical Nord palette per nordtheme.com/docs/colors-and-palettes.
            ansi: [
                0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
                0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
                0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4
            ]
        )
    ]

    static func find(id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? all[0]
    }

    /// Whether the theme reads as a "light" theme — used to pick mode-
    /// appropriate semantic colors in chrome tokens. Standard sRGB luminance
    /// formula with a midpoint threshold.
    var isLight: Bool {
        let r = Double((bgRGB >> 16) & 0xFF) / 255
        let g = Double((bgRGB >>  8) & 0xFF) / 255
        let b = Double( bgRGB        & 0xFF) / 255
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 0.5
    }

    /// Whether this theme defers to the user's app-accent picker for
    /// chrome accents (active-tab tint, ⌘N hint color in SessionTopBar).
    /// True only for the intentionally-neutral themes — Void and Paper —
    /// where there's no theme-specific accent identity to preserve.
    /// Opinionated themes (Dracula's purple, Nord's frost, Amber CRT's
    /// monochrome, Graphite's green) keep their built-in `accent`
    /// because it's part of the theme's visual signature; overriding
    /// would clash with the canvas palette.
    var respectsUserAccent: Bool {
        id == "void" || id == "paper"
    }

    /// `DesignTokens` derived from this theme, intended for chrome that
    /// surrounds the terminal canvas (the SessionTopBar and the page
    /// backdrop). The terminal-canvas-bg-as-chrome-bg + fg-tinted muteds
    /// approach makes the top bar feel like an extension of the terminal.
    /// Semantic state colors (green/amber/red) stay fixed so connection
    /// dots remain recognizable across themes.
    ///
    /// Pass `accentOverride` (paired with `accentSoftOverride`) to
    /// substitute the user's app-accent for the theme's own. Callers
    /// should only do this when `respectsUserAccent == true`; the
    /// helper itself is unconditional so SessionView can remain the
    /// single source of truth for the gating policy.
    func chromeTokens(
        accentOverride: Color? = nil,
        accentSoftOverride: Color? = nil
    ) -> DesignTokens {
        let activeAccent = accentOverride ?? accent
        let activeSoft = accentSoftOverride
            ?? activeAccent.opacity(isLight ? 0.10 : 0.14)
        return DesignTokens(
            bg:            bg,
            // Glass tint for `floatingGlass` chrome (SessionTopBar). Must be
            // translucent: an opaque tint makes Liquid Glass / frosted render
            // as a solid slab — pure black over a background picture. The
            // wash keeps the theme's hue while letting the material (and the
            // picture behind it) show through; `.solid` ignores it entirely.
            sidebarBg:     bg.opacity(isLight ? 0.55 : 0.35),
            sidebarBorder: fg.opacity(0.06),
            panelBg:       bg,
            inputBg:       fg.opacity(0.06),
            inputBgSoft:   fg.opacity(0.04),
            fg:            fg,
            fgMuted:       fg.opacity(0.65),
            fgDim:         fg.opacity(0.40),
            fgFaint:       fg.opacity(0.18),
            accent:        activeAccent,
            accentSoft:    activeSoft,
            green:         Color(rgbInt: 0x30D158),
            red:           Color(rgbInt: 0xFF453A),
            amber:         Color(rgbInt: 0xFF9F0A),
            border:        fg.opacity(0.10),
            borderStrong:  fg.opacity(0.18),
            isLight:       isLight
        )
    }

    /// Convenience over `chromeTokens(accentOverride:accentSoftOverride:)`
    /// that pulls the user's accent (and its custom RGB) out of
    /// `AppearancePreferences` and applies the override only when this
    /// theme is one of the neutral ones (`respectsUserAccent`). The
    /// override is resolved against the theme's own light/dark polarity
    /// — Void uses the dark variant of the user accent, Paper uses the
    /// light variant — independently of system color scheme, since
    /// terminal themes don't follow system mode.
    func chromeTokens(applying appearance: AppearancePreferences) -> DesignTokens {
        guard respectsUserAccent else { return chromeTokens() }

        let mode: AppearanceMode = isLight ? .light : .dark
        let userTokens = DesignTokens.make(
            mode: mode,
            accent: appearance.accent,
            customColor: appearance.accent == .custom
                ? Color(rgbInt: appearance.customAccentRGB)
                : nil
        )
        return chromeTokens(
            accentOverride: userTokens.accent,
            accentSoftOverride: userTokens.accentSoft
        )
    }
}
