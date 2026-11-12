import SwiftUI
import XCTest
@testable import Tessera

final class TerminalThemeSelectionTests: XCTestCase {
    func testAutomaticSelectionFollowsTheAppearance() {
        XCTAssertEqual(TerminalTheme.resolvedID(selection: TerminalTheme.automaticID, prefersLight: true), "paper")
        XCTAssertEqual(TerminalTheme.resolvedID(selection: TerminalTheme.automaticID, prefersLight: false), "void")
    }

    func testExplicitSelectionIgnoresTheAppearance() {
        for id in TerminalTheme.all.map(\.id) {
            XCTAssertEqual(TerminalTheme.resolvedID(selection: id, prefersLight: true), id)
            XCTAssertEqual(TerminalTheme.resolvedID(selection: id, prefersLight: false), id)
        }
    }

    func testAutomaticIsNoThemeOfItsOwn() {
        XCTAssertFalse(TerminalTheme.all.contains { $0.id == TerminalTheme.automaticID })
    }

    func testImportKeepsKnownThemesAndFollowsTheAppearanceOtherwise() {
        XCTAssertEqual(TerminalTheme.importedSelection("nord"), "nord")
        XCTAssertEqual(TerminalTheme.importedSelection("paper"), "paper")
        XCTAssertEqual(TerminalTheme.importedSelection(TerminalTheme.automaticID), TerminalTheme.automaticID)
        // Android's placeholder, and a theme from a newer build.
        XCTAssertEqual(TerminalTheme.importedSelection("default"), TerminalTheme.automaticID)
        XCTAssertEqual(TerminalTheme.importedSelection("solarized-next"), TerminalTheme.automaticID)
    }

    func testPreferencesResolveTheAutomaticThemeFromModeAndObservedScheme() {
        let appearance = AppearancePreferences()
        let mode = appearance.mode
        let selection = appearance.terminalThemeSelection
        let scheme = appearance.observedColorScheme
        defer {
            appearance.mode = mode
            appearance.terminalThemeSelection = selection
            appearance.noteColorScheme(scheme)
        }

        appearance.terminalThemeSelection = TerminalTheme.automaticID
        appearance.mode = .system
        appearance.noteColorScheme(.light)
        XCTAssertEqual(appearance.terminalThemeID, "paper")
        appearance.noteColorScheme(.dark)
        XCTAssertEqual(appearance.terminalThemeID, "void")

        // A forced app mode decides, whatever the system's scheme.
        appearance.mode = .light
        XCTAssertEqual(appearance.terminalThemeID, "paper")
        appearance.mode = .dark
        appearance.noteColorScheme(.light)
        XCTAssertEqual(appearance.terminalThemeID, "void")

        appearance.terminalThemeSelection = "nord"
        XCTAssertEqual(appearance.terminalThemeID, "nord")
    }
}
