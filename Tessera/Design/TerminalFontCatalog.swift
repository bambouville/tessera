// Tessera/Design/TerminalFontCatalog.swift
// The selectable terminal typefaces, mirroring
// `android/design/.../TerminalFontCatalog.kt`. The `.ttf` files themselves are
// shared: both platforms build from `SharedAssets/fonts/font/`, so a family
// added here is the same bytes Android renders.
//
// Chrome typography (`Typography.tesseraMono`) deliberately stays on JetBrains
// Mono no matter what is picked here — this setting governs the terminal grid,
// not the app's own text, and Android draws the same line.
import SwiftUI
import UIKit

struct TerminalFontOption: Identifiable, Equatable {
    /// Persisted identity and cross-device wire value. Matches the Android
    /// resource name (`R.font.<id>`), which is why it is lowercase snake case.
    let id: String
    /// Proper noun — the foundry's name for the family. Never localized.
    let name: String
    /// PostScript name baked into the `.ttf`, which is how CoreText resolves a
    /// registered face. `nil` means "whatever monospace the OS ships", the one
    /// option that bundles nothing.
    let postScriptName: String?
    /// One-line character note shown under the family name in the picker.
    let note: LocalizedStringResource

    var isSystem: Bool { postScriptName == nil }
}

enum TerminalFontCatalog {
    static let defaultID = "jetbrains_mono"

    /// Order is the picker order: the default first, then the families most
    /// people arrive already using, then the more particular ones.
    static let all: [TerminalFontOption] = [
        TerminalFontOption(
            id: "jetbrains_mono",
            name: "JetBrains Mono",
            postScriptName: "JetBrainsMono-Regular",
            note: LocalizedStringResource(
                "tall x-height, coding ligatures",
                comment: "One-line description of a terminal typeface")
        ),
        TerminalFontOption(
            id: "fira_code",
            name: "Fira Code",
            postScriptName: "FiraCode-Regular",
            note: LocalizedStringResource(
                "the widest ligature set",
                comment: "One-line description of a terminal typeface")
        ),
        TerminalFontOption(
            id: "hack",
            name: "Hack",
            postScriptName: "Hack-Regular",
            note: LocalizedStringResource(
                "wide, plain, built for small sizes",
                comment: "One-line description of a terminal typeface")
        ),
        TerminalFontOption(
            id: "cascadia_mono",
            name: "Cascadia Mono",
            postScriptName: "CascadiaMono-Regular",
            note: LocalizedStringResource(
                "Windows Terminal's face, no ligatures",
                comment: "One-line description of a terminal typeface")
        ),
        TerminalFontOption(
            id: "source_code_pro",
            name: "Source Code Pro",
            postScriptName: "SourceCodePro-Regular",
            note: LocalizedStringResource(
                "Adobe's classic, humanist shapes",
                comment: "One-line description of a terminal typeface")
        ),
        TerminalFontOption(
            id: "ibm_plex_mono",
            name: "IBM Plex Mono",
            postScriptName: "IBMPlexMono-Regular",
            note: LocalizedStringResource(
                "warm and slightly narrow",
                comment: "One-line description of a terminal typeface")
        ),
        TerminalFontOption(
            id: "geist_mono",
            name: "Geist Mono",
            postScriptName: "GeistMono-Regular",
            note: LocalizedStringResource(
                "geometric, very open counters",
                comment: "One-line description of a terminal typeface")
        ),
        TerminalFontOption(
            id: "ubuntu_mono",
            name: "Ubuntu Mono",
            postScriptName: "UbuntuMono-Regular",
            note: LocalizedStringResource(
                "narrow — fits the most columns",
                comment: "One-line description of a terminal typeface")
        ),
        TerminalFontOption(
            id: "inconsolata",
            name: "Inconsolata",
            postScriptName: "Inconsolata-Regular",
            note: LocalizedStringResource(
                "light and compact",
                comment: "One-line description of a terminal typeface")
        ),
        TerminalFontOption(
            id: "dejavu_sans_mono",
            name: "DejaVu Sans Mono",
            postScriptName: "DejaVuSansMono",
            note: LocalizedStringResource(
                "the broadest Unicode coverage",
                comment: "One-line description of a terminal typeface")
        ),
        TerminalFontOption(
            id: "system",
            name: "System",
            postScriptName: nil,
            note: LocalizedStringResource(
                "SF Mono, whatever the OS ships",
                comment: "One-line description of the system monospaced typeface")
        )
    ]

    static func find(id: String) -> TerminalFontOption {
        all.first { $0.id == id } ?? all.first { $0.id == defaultID }!
    }

    /// Normalizes a stored or received value to a catalog id.
    ///
    /// Two shapes reach this. Builds before the picker existed persisted a
    /// PostScript name in `tessera.pref.monoFontName` and sent the same string
    /// as the manifest's `monospacedFontName`, so those still resolve. Anything
    /// unrecognized — a family a newer build added, or Android's old
    /// `"monospace"` placeholder — falls back to the default rather than
    /// leaving the terminal with a face it cannot draw.
    static func resolve(_ raw: String) -> String {
        if all.contains(where: { $0.id == raw }) { return raw }
        if let match = all.first(where: { $0.postScriptName == raw }) { return match.id }
        return defaultID
    }
}

/// Builds the `UIFont` handed to SwiftTerm and the SwiftUI `Font` used by the
/// settings preview from the same catalog entry, so what the picker shows and
/// what the grid renders can never be two different faces.
enum TerminalFontResolver {
    /// Glyphs the terminal must be able to draw whatever family is selected:
    /// STIX covers the text-presentation geometric symbols agents emit
    /// (U+23F4–U+23FA), Menlo covers box drawing and the rest of the legacy
    /// terminal repertoire. Explicit emoji presentation (VS16) still falls
    /// through to color emoji.
    private static let cascadeNames = ["STIXTwoMath-Regular", "Menlo-Regular"]

    static func uiFont(id: String, size: CGFloat) -> UIFont {
        let option = TerminalFontCatalog.find(id: id)
        let base = option.postScriptName.flatMap { UIFont(name: $0, size: size) }
            ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let cascade = cascadeNames.compactMap {
            UIFont(name: $0, size: size)?.fontDescriptor
        }
        guard !cascade.isEmpty else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: cascade])
        return UIFont(descriptor: descriptor, size: size)
    }

    static func font(id: String, size: CGFloat) -> Font {
        Font(uiFont(id: id, size: size))
    }
}
