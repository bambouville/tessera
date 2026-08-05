import SwiftUI
import UIKit

enum AppearanceMode { case dark, light }

/// Single authority for the phone-vs-iPad presentation split. iPhone idiom
/// always presents the compact phone experience, even where the size class
/// goes regular (Pro Max landscape) — otherwise the iPad sidebar shell wraps
/// phone-styled pages whose idiom checks hide controls the iPad flows expect.
/// iPad stays size-class-driven so Split View still adapts.
enum CompactLayout {
    static func isPhone(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone
            || horizontalSizeClass == .compact
    }
}

enum AccentName: String, CaseIterable {
    case blue, green, amber, custom

    /// Default RGB used when AccentName is `.custom` and no override is supplied.
    /// Hex 0xFF375F = the prior `.pink` accent — preserves a recognizable color
    /// for users who want a distinctive non-default tint.
    static let defaultCustomRGB: Int = 0xFF375F

    fileprivate func hex(mode: AppearanceMode) -> Color {
        switch (self, mode) {
        case (.blue,  .dark):  return Color(rgb: 0x5B9FFF)
        case (.blue,  .light): return Color(rgb: 0x0060DF)
        case (.green, .dark):  return Color(rgb: 0x30D158)
        case (.green, .light): return Color(rgb: 0x008A3C)
        case (.amber, .dark):  return Color(rgb: 0xFF9F0A)
        case (.amber, .light): return Color(rgb: 0xB26B00)
        case (.custom, _):     return Color(rgb: UInt32(Self.defaultCustomRGB))
        }
    }

    fileprivate func soft(mode: AppearanceMode) -> Color {
        switch (self, mode) {
        case (.blue,  .dark):  return Color(r: 91,  g: 159, b: 255, a: 0.14)
        case (.blue,  .light): return Color(r: 0,   g: 96,  b: 223, a: 0.10)
        case (.green, .dark):  return Color(r: 48,  g: 209, b: 88,  a: 0.14)
        case (.green, .light): return Color(r: 0,   g: 138, b: 60,  a: 0.10)
        case (.amber, .dark):  return Color(r: 255, g: 159, b: 10,  a: 0.14)
        case (.amber, .light): return Color(r: 178, g: 107, b: 0,   a: 0.10)
        case (.custom, _):
            return Color(rgb: UInt32(Self.defaultCustomRGB))
                .opacity(mode == .dark ? 0.14 : 0.10)
        }
    }
}

struct DesignTokens {
    let bg: Color
    let sidebarBg: Color
    let sidebarBorder: Color
    let panelBg: Color
    let inputBg: Color
    let inputBgSoft: Color
    let fg: Color
    let fgMuted: Color
    let fgDim: Color
    let fgFaint: Color
    let accent: Color
    let accentSoft: Color
    let green: Color
    let red: Color
    let amber: Color
    let border: Color
    let borderStrong: Color
    let isLight: Bool

    /// Opaque canvas for full-screen presentations layered above existing
    /// content. The normal light-mode `bg` is intentionally clear so the app's
    /// root system background can show through, but using that token for a
    /// modal overlay leaves the underlying page visible and unreadable.
    var presentationBg: Color {
        isLight ? .white : bg
    }

    /// `customColor` is consulted only when `accent == .custom`. It overrides
    /// both `accent` and `accentSoft` — soft is derived as `customColor` with
    /// alpha 0.14 (dark) or 0.10 (light) to match the named-accent treatment.
    static func make(
        mode: AppearanceMode,
        accent: AccentName,
        customColor: Color? = nil
    ) -> DesignTokens {
        let resolvedAccent: Color
        let resolvedSoft: Color
        if accent == .custom, let c = customColor {
            resolvedAccent = c
            resolvedSoft = c.opacity(mode == .dark ? 0.14 : 0.10)
        } else {
            resolvedAccent = accent.hex(mode: mode)
            resolvedSoft = accent.soft(mode: mode)
        }
        return _make(mode: mode, accent: resolvedAccent, accentSoft: resolvedSoft)
    }

    private static func _make(
        mode: AppearanceMode,
        accent resolvedAccent: Color,
        accentSoft resolvedSoft: Color
    ) -> DesignTokens {
        switch mode {
        case .dark:
            return DesignTokens(
                bg:            Color(rgb: 0x000000),
                sidebarBg:     Color(r: 210, g: 210, b: 214, a: 0.18),
                sidebarBorder: Color(r: 255, g: 255, b: 255, a: 0.06),
                panelBg:       Color(rgb: 0x0A0A0A),
                inputBg:       Color(rgb: 0x141414),
                inputBgSoft:   Color(rgb: 0x1C1C1E),
                fg:            Color(rgb: 0xFFFFFF),
                fgMuted:       Color(r: 235, g: 235, b: 245, a: 0.60),
                fgDim:         Color(r: 235, g: 235, b: 245, a: 0.35),
                fgFaint:       Color(r: 235, g: 235, b: 245, a: 0.18),
                accent:        resolvedAccent,
                accentSoft:    resolvedSoft,
                green:         Color(rgb: 0x30D158),
                red:           Color(rgb: 0xFF453A),
                amber:         Color(rgb: 0xFF9F0A),
                border:        Color(r: 255, g: 255, b: 255, a: 0.08),
                borderStrong:  Color(r: 255, g: 255, b: 255, a: 0.14),
                isLight:       false
            )
        case .light:
            return DesignTokens(
                bg:            .clear,
                sidebarBg:     Color(r: 255, g: 255, b: 255, a: 0.50),
                sidebarBorder: Color(r: 0,   g: 0,   b: 0,   a: 0.08),
                panelBg:       Color(r: 255, g: 255, b: 255, a: 0.75),
                inputBg:       Color(r: 255, g: 255, b: 255, a: 0.80),
                inputBgSoft:   Color(r: 255, g: 255, b: 255, a: 0.60),
                fg:            Color(rgb: 0x1A1A1A),
                fgMuted:       Color(r: 0, g: 0, b: 0, a: 0.60),
                fgDim:         Color(r: 0, g: 0, b: 0, a: 0.40),
                fgFaint:       Color(r: 0, g: 0, b: 0, a: 0.18),
                accent:        resolvedAccent,
                accentSoft:    resolvedSoft,
                green:         Color(rgb: 0x00A63C),
                red:           Color(rgb: 0xD70015),
                amber:         Color(rgb: 0xB26B00),
                border:        Color(r: 0, g: 0, b: 0, a: 0.08),
                borderStrong:  Color(r: 0, g: 0, b: 0, a: 0.14),
                isLight:       true
            )
        }
    }
}

extension Color {
    /// Build a `Color` from a 24-bit RGB integer. Used by AppearancePreferences
    /// to materialize the user-picked custom accent.
    init(rgbInt: Int) {
        self.init(
            red:   Double((rgbInt >> 16) & 0xFF) / 255,
            green: Double((rgbInt >>  8) & 0xFF) / 255,
            blue:  Double( rgbInt        & 0xFF) / 255
        )
    }

    fileprivate init(rgb: UInt32) {
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >>  8) & 0xFF) / 255,
            blue:  Double( rgb        & 0xFF) / 255
        )
    }

    fileprivate init(r: Int, g: Int, b: Int, a: Double) {
        self.init(
            .sRGB,
            red:   Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: a
        )
    }
}

// MARK: - Chrome material (Liquid Glass / Material / Solid)

/// Fidelity of the floating chrome material (sidebar, top bar, accessory bar).
/// Persisted in `AppearancePreferences.chromeMaterial`. Resolution against the
/// running OS happens in `resolved` / `floatingGlass(_:…)`: `.liquidGlass` is
/// iPadOS-26-only and falls back to `.frosted` below 26. Reduce Transparency is
/// honored automatically by both the Liquid Glass and Material backends, so the
/// chrome goes opaque for that accessibility setting regardless of this choice.
enum ChromeMaterial: String, CaseIterable, Identifiable {
    /// Native Liquid Glass — translucent, refractive, dynamically tinted. iPadOS 26+.
    case liquidGlass
    /// SwiftUI `Material` frosted blur — translucent, content visible beneath. iOS 15+.
    case frosted
    /// Opaque plain panel — no translucency. The "plainest visuals" option.
    case solid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .liquidGlass: return "liquid glass"
        case .frosted:     return "frosted"
        case .solid:       return "solid"
        }
    }

    var caption: String {
        switch self {
        case .liquidGlass: return "translucent, refractive"
        case .frosted:     return "translucent blur"
        case .solid:       return "opaque, plainest"
        }
    }

    /// Whether the running OS can render this material.
    var isAvailable: Bool {
        switch self {
        case .liquidGlass:
            if #available(iOS 26, *) { return true } else { return false }
        case .frosted, .solid:
            return true
        }
    }

    /// Materials the running OS can render, highest fidelity first. Drives the
    /// Settings picker so unsupported options are never shown.
    static var supportedCases: [ChromeMaterial] { allCases.filter(\.isAvailable) }

    /// Highest-fidelity material the running OS supports — the default.
    static var highestSupported: ChromeMaterial { supportedCases.first ?? .frosted }

    /// This value clamped to availability (`.liquidGlass` → `.frosted` below 26).
    var resolved: ChromeMaterial { isAvailable ? self : .frosted }
}

extension View {
    /// Applies the floating chrome material behind `shape`, honoring the user's
    /// `ChromeMaterial` choice and the running OS. The view's own content (icons,
    /// text) stays on top; pass borders/hairlines as separate overlays at the
    /// call site (matching the existing sidebar/top-bar border overlays).
    ///
    /// - `tint`: a *translucent* wash layered over the blur to color the glass
    ///   (e.g. `T.sidebarBg`); ignored by `.solid`.
    /// - `solidFill`: the opaque fill used by `.solid` (and Reduce Transparency).
    @ViewBuilder
    func floatingGlass(
        _ material: ChromeMaterial,
        tint: Color,
        solidFill: Color,
        in shape: some Shape
    ) -> some View {
        switch material.resolved {
        case .liquidGlass:
            if #available(iOS 26, *) {
                self.glassEffect(.regular.tint(tint), in: shape)
            } else {
                self.background(tint, in: shape).background(.regularMaterial, in: shape)
            }
        case .frosted:
            // tint sits directly behind the content; Material behind the tint
            // blurs whatever is behind the whole chrome (the terminal / page).
            self.background(tint, in: shape).background(.regularMaterial, in: shape)
        case .solid:
            self.background(solidFill, in: shape)
        }
    }
}

private struct DesignTokensKey: EnvironmentKey {
    static let defaultValue = DesignTokens.make(mode: .dark, accent: .blue)
}

extension EnvironmentValues {
    var designTokens: DesignTokens {
        get { self[DesignTokensKey.self] }
        set { self[DesignTokensKey.self] = newValue }
    }
}
