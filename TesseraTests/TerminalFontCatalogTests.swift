import UIKit
import XCTest
@testable import Tessera

/// The id list is pinned here and in `TerminalFontCatalogTest.kt` against the
/// same literal, because the two catalogs are hand-mirrored: a family added to
/// one platform and forgotten on the other would ship as a preference that
/// syncs across devices and then renders as the default on arrival.
final class TerminalFontCatalogTests: XCTestCase {

    private let expectedIDs = [
        "jetbrains_mono",
        "fira_code",
        "hack",
        "cascadia_mono",
        "source_code_pro",
        "ibm_plex_mono",
        "geist_mono",
        "ubuntu_mono",
        "inconsolata",
        "dejavu_sans_mono",
        "system"
    ]

    override func setUp() {
        super.setUp()
        // The app registers embedded faces at launch; a test host has not run
        // that path, and CoreText will not resolve a PostScript name until it
        // has. Registration is idempotent.
        registerEmbeddedFonts()
    }

    func test_catalogIDsAndOrderMatchTheSharedList() {
        XCTAssertEqual(TerminalFontCatalog.all.map(\.id), expectedIDs)
    }

    func test_defaultIsTheFirstEntry() {
        XCTAssertEqual(TerminalFontCatalog.defaultID, "jetbrains_mono")
        XCTAssertEqual(TerminalFontCatalog.all.first?.id, TerminalFontCatalog.defaultID)
    }

    /// The one test that catches a `.ttf` that never made it into the bundle,
    /// or whose PostScript name in the catalog does not match the file. Both
    /// are silent at runtime — CoreText just hands back the system face — so
    /// the picker would offer a family that renders as something else.
    func test_everyBundledFamilyResolvesToItsOwnFace() {
        for option in TerminalFontCatalog.all {
            guard let postScriptName = option.postScriptName else { continue }
            let font = UIFont(name: postScriptName, size: 13)
            XCTAssertNotNil(font, "\(option.name) did not register as \(postScriptName)")
            XCTAssertEqual(font?.fontName, postScriptName, "\(option.name) resolved elsewhere")
        }
    }

    func test_everyBundledFamilyIsFixedPitch() {
        for option in TerminalFontCatalog.all where option.postScriptName != nil {
            let font = TerminalFontResolver.uiFont(id: option.id, size: 13)
            let narrow = ("i" as NSString).size(withAttributes: [.font: font]).width
            let wide = ("W" as NSString).size(withAttributes: [.font: font]).width
            XCTAssertEqual(
                narrow, wide, accuracy: 0.01,
                "\(option.name) is not monospaced — the grid would tear"
            )
        }
    }

    /// The whole point of the cascade: whatever family is selected, the glyphs
    /// a TUI leans on have to come out as glyphs. Box drawing is in every
    /// bundled face; the geometric play/record symbols agents emit are not, and
    /// reach the terminal through the fallback list instead.
    func test_theSystemOptionStillGetsTheTerminalCascade() {
        let font = TerminalFontResolver.uiFont(id: "system", size: 13)
        let cascade = font.fontDescriptor.fontAttributes[.cascadeList] as? [UIFontDescriptor]
        XCTAssertEqual(cascade?.count, 2)
    }

    func test_resolveMapsLegacyPostScriptNamesOntoIDs() {
        XCTAssertEqual(TerminalFontCatalog.resolve("JetBrainsMono-Regular"), "jetbrains_mono")
        XCTAssertEqual(TerminalFontCatalog.resolve("DejaVuSansMono"), "dejavu_sans_mono")
    }

    func test_resolveFallsBackForValuesThisBuildCannotRender() {
        // Android's pre-picker manifest placeholder, a face Tessera never
        // bundled, and a family from a build newer than this one.
        XCTAssertEqual(TerminalFontCatalog.resolve("monospace"), "jetbrains_mono")
        XCTAssertEqual(TerminalFontCatalog.resolve("Menlo-Regular"), "jetbrains_mono")
        XCTAssertEqual(TerminalFontCatalog.resolve("victor_mono"), "jetbrains_mono")
        XCTAssertEqual(TerminalFontCatalog.resolve(""), "jetbrains_mono")
    }

    func test_resolveIsIdempotentOverEveryCatalogID() {
        for option in TerminalFontCatalog.all {
            XCTAssertEqual(TerminalFontCatalog.resolve(option.id), option.id)
        }
    }

    func test_findFallsBackRatherThanTrapping() {
        XCTAssertEqual(TerminalFontCatalog.find(id: "nonexistent").id, "jetbrains_mono")
    }

    /// A stored value the catalog does not know must not survive into the live
    /// preference, or `applyAppearance` would install a face SwiftTerm cannot
    /// measure and the grid would fall back mid-session.
    @MainActor
    func test_preferenceNormalizesOnAssignment() {
        let appearance = AppearancePreferences()
        let original = appearance.terminalFontID
        defer { appearance.terminalFontID = original }

        appearance.terminalFontID = "hack"
        XCTAssertEqual(appearance.terminalFontID, "hack")

        appearance.terminalFontID = "JetBrainsMono-Regular"
        XCTAssertEqual(appearance.terminalFontID, "jetbrains_mono")

        appearance.terminalFontID = "victor_mono"
        XCTAssertEqual(appearance.terminalFontID, "jetbrains_mono")
    }
}
