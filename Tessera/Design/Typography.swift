// Tessera/Design/Typography.swift
import SwiftUI
import CoreText
import UIKit

enum Typography {
    static func tesseraMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("JetBrainsMono-Regular", size: size, relativeTo: .body)
            .weight(weight)
    }

    /// Non-scaling variant for chrome whose font size is derived from a fixed
    /// bar height (pane headers) or that must match the terminal grid's
    /// fixed-point rendering (screenshot harnesses) — Dynamic Type must not
    /// resize these.
    static func tesseraMonoFixed(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("JetBrainsMono-Regular", fixedSize: size)
            .weight(weight)
    }

    static func tesseraSans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .default)
    }
}

// MARK: - Semantic text roles
//
// Route same-role text through these instead of picking sizes at call sites —
// the audit that introduced them found seven page-title specs and five kicker
// specs in the wild. Case voice: titles are lowercase; kickers are uppercase.
extension Typography {
    /// Oversized landing header — the Hosts page and host detail only.
    static var heroTitle: Font { tesseraMono(size: 28) }
    /// Top-level page/pane title (sessions, keys, known hosts, agents,
    /// settings, tunnels) and full-screen flow step titles (Nearby Setup),
    /// phone and iPad.
    static var pageTitle: Font { tesseraMono(size: 24, weight: .medium) }
    /// Sheet and modal title.
    static var sheetTitle: Font { tesseraMono(size: 18, weight: .medium) }
    /// Uppercase micro section label. Pair with `.tracking(0.6)` and
    /// `T.fgDim` at the call site.
    static var kicker: Font { tesseraMono(size: 10, weight: .medium) }
}

// MARK: - Dynamic Type support for sans

extension UIContentSizeCategory {
    /// UIKit counterpart of a SwiftUI `DynamicTypeSize`, so `UIFontMetrics`
    /// resolves against the SwiftUI environment — including any
    /// `.dynamicTypeSize(...)` caps upstream — rather than the app-global
    /// setting.
    init(_ size: DynamicTypeSize) {
        switch size {
        case .xSmall:         self = .extraSmall
        case .small:          self = .small
        case .medium:         self = .medium
        case .large:          self = .large
        case .xLarge:         self = .extraLarge
        case .xxLarge:        self = .extraExtraLarge
        case .xxxLarge:       self = .extraExtraExtraLarge
        case .accessibility1: self = .accessibilityMedium
        case .accessibility2: self = .accessibilityLarge
        case .accessibility3: self = .accessibilityExtraLarge
        case .accessibility4: self = .accessibilityExtraExtraLarge
        case .accessibility5: self = .accessibilityExtraExtraExtraLarge
        @unknown default:     self = .large
        }
    }
}

/// `tesseraMono` scales with Dynamic Type (`relativeTo: .body`) but
/// `tesseraSans` cannot — SwiftUI's `Font.system(size:)` is fixed-size and has
/// no `relativeTo` variant. This modifier closes the gap: it recomputes the
/// point size through `UIFontMetrics`, resolved from the SwiftUI
/// `dynamicTypeSize` environment so `.dynamicTypeSize(...)` caps apply to
/// sans exactly as they do to mono.
private struct ScaledTesseraSans: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let size: CGFloat
    let weight: Font.Weight
    let textStyle: UIFont.TextStyle

    func body(content: Content) -> some View {
        let traits = UITraitCollection(
            preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize)
        )
        return content.font(.system(
            size: UIFontMetrics(forTextStyle: textStyle)
                .scaledValue(for: size, compatibleWith: traits),
            weight: weight
        ))
    }
}

extension View {
    /// Caps Dynamic Type growth for text inside fixed-height chrome bars
    /// (session top bar, find bar), whose heights are user settings that feed
    /// terminal layout and cannot grow. Apply to button LABELS or plain text,
    /// never to a view carrying a `.sheet`/`.popover`: presented content
    /// inherits the environment of the view its presentation modifier is
    /// attached to, and modal content must keep unrestricted text scaling.
    func chromeBarTextCap() -> some View {
        dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

extension View {
    /// `Typography.tesseraSans` that tracks Dynamic Type like `tesseraMono`
    /// does. Use for sans copy that sits next to scaling mono content, so
    /// values and their explanations grow together.
    func tesseraSansScaled(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo style: UIFont.TextStyle = .body
    ) -> some View {
        modifier(ScaledTesseraSans(size: size, weight: weight, textStyle: style))
    }
}

/// Call once at app startup (e.g. from TesseraApp.init) to register any
/// embedded TTF fonts in the main bundle before SwiftUI tries to resolve them.
func registerEmbeddedFonts() {
    guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) else { return }
    CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
}
