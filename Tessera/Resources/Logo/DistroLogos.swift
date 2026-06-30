import SwiftUI

/// Maps an `osHint` value to its monochrome distro logo. The four Linux
/// logos (ubuntu / debian / alpine / linux) are rendered from SVGs
/// bundled in `Assets.xcassets` as template imagesets, so they pick up
/// the surrounding `foregroundStyle` (white in the OSBadge).
/// `raspbian` falls back to the Greek π glyph rather than the
/// trademarked raspberry mark.
///
/// Source SVGs (all GPL-3-compatible):
///  - ubuntu / debian / linux — Font Awesome Free 6.x brand glyphs
///                              (CC BY 4.0, attribution required).
///                              Single-path, monochrome, designed for
///                              template tinting at small sizes —
///                              feature cuts (Tux's eyes/beak,
///                              Ubuntu's friend dots) are negative
///                              space inside one filled path.
///  - alpine                  — Wikimedia: New_Logo_Alpine_Linux.svg
///                              (CC0).
enum DistroLogo {
    static func glyph(for osHint: String, size: CGFloat) -> AnyView? {
        let normalized = osHint.lowercased()
        switch normalized {
        case "ubuntu", "debian", "alpine", "linux":
            return AnyView(
                Image(normalized)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            )
        case "raspbian":
            // The official raspberry mark is trademarked and only
            // distributed under fair use on Wikipedia, so we use the
            // Greek π letter instead — instantly readable as "Pi" and
            // free of trademark concerns.
            return AnyView(
                Text("π")
                    .font(.system(size: size * 0.95, weight: .bold))
                    .frame(width: size, height: size)
            )
        default:
            return nil
        }
    }
}
