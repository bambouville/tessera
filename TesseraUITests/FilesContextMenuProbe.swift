import XCTest

/// Repro rig for the Files-panel context-menu flicker: a long directory plus
/// the live cwd poller's cadence made the presented `UIMenu` re-publish on
/// every panel body pass, so UIKit crossfaded the platter (the visible
/// flicker) and dropped the tap that was in flight.
///
/// Host-free — it runs the panel on `MockFileBridge` through the
/// `TESSERA_FILES_HARNESS` screen, so no session is ever opened. Drive it
/// with `scripts/uitest/run-files-context-menu.sh`.
final class FilesContextMenuProbe: XCTestCase {

    /// Rows in the synthetic directory. The reporter's listing was of this
    /// order; a short directory does not re-render expensively enough.
    private static let fileCount = 220

    /// Churn cadence. `RemoteCwdPoller` reports every 2.5s on a live
    /// session; the probe runs it faster so a single held menu sees several
    /// reports inside the capture window.
    private static let churnMilliseconds = 700

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["TESSERA_FILES_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_FILES_HARNESS_FILECOUNT"] = "\(Self.fileCount)"
        app.launchEnvironment["TESSERA_FILES_HARNESS_CHURN"] = "\(Self.churnMilliseconds)"
        app.launchEnvironment["TESSERA_FILES_MENU_DIAG"] = "1"
    }

    /// Shipping behaviour. Rows short-circuit, so panel churn never reaches
    /// the presented menu: `FilesChurnDiag` must report `sinceMenu=0` for
    /// the whole hold.
    func testRowContextMenuSurvivesPanelChurn() throws {
        try holdMenuAcrossChurn()
    }

    /// Control arm: identical hold with the panel completely idle (no churn
    /// task). Anything that still repaints the platter here is intrinsic to
    /// the presentation, not to the panel re-rendering under it.
    func testRowContextMenuWithoutPanelChurn() throws {
        app.launchEnvironment["TESSERA_FILES_HARNESS_CHURN"] = "0"
        try holdMenuAcrossChurn()
    }

    /// Second control: idle panel *and* no opaque backstop, so the only
    /// thing left moving is UIKit's own menu presentation.
    func testRowContextMenuWithoutBackstop() throws {
        app.launchEnvironment["TESSERA_FILES_HARNESS_CHURN"] = "0"
        app.launchEnvironment["TESSERA_FILES_BACKSTOP"] = "0"
        try holdMenuAcrossChurn()
    }

    /// Third control: idle panel, no custom lifted preview. Isolates the
    /// repaint UIKit does when it hosts and sizes a SwiftUI preview view.
    func testRowContextMenuWithoutCustomPreview() throws {
        app.launchEnvironment["TESSERA_FILES_HARNESS_CHURN"] = "0"
        app.launchEnvironment["TESSERA_FILES_MENU_PREVIEW"] = "0"
        try holdMenuAcrossChurn()
    }

    /// Fourth control: idle panel, no row drag interaction. `.onDrag`
    /// installs a `UIDragInteraction` on the same view the context menu
    /// lifts from, and both arbitrate the same long press.
    func testRowContextMenuWithoutRowDrag() throws {
        app.launchEnvironment["TESSERA_FILES_HARNESS_CHURN"] = "0"
        app.launchEnvironment["TESSERA_FILES_ROW_DRAG"] = "0"
        try holdMenuAcrossChurn()
    }

    /// End-to-end check of the surface the user actually exports: no test
    /// env forcing, just the real Settings toggle flipped through the
    /// defaults override, so the lines have to travel the same path as a
    /// user report — `DiagnosticLogStore` → Application Support →
    /// `tessera-diagnostics.log`. The runner reads the file back out of the
    /// simulator container.
    func testDiagnosticsReachTheExportedLog() throws {
        app.launchEnvironment.removeValue(forKey: "TESSERA_FILES_MENU_DIAG")
        app.launchArguments += ["-Diagnostics.ScrollEnabled", "YES"]
        app.launch()

        let row = app.descendants(matching: .any)["files.row.report_0003_analysis.md"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "synthetic listing never appeared")

        // Scroll the list itself — the panel's touch sensor is what opens a
        // tree scroll session, so a window-centre swipe would miss it.
        row.swipeUp(velocity: .fast)
        usleep(1_500_000)
        row.swipeDown(velocity: .fast)
        usleep(1_500_000)

        row.press(forDuration: 1.2)
        let sendPath = menuItem(labeled: "Send Path to Terminal")
        XCTAssertTrue(sendPath.waitForExistence(timeout: 6), "context menu never presented")
        usleep(1_500_000)
        sendPath.tap()
        usleep(2_500_000)
    }

    /// The shipping row owns a UIKit `UIContextMenuInteraction`, so SwiftUI
    /// catalog coverage alone cannot prove the action titles or the single
    /// accessibility element are localized at that boundary.
    func testUIKitMenuAndAccessibilityAreLocalizedInFrench() {
        verifyLocalizedUIKitRow(
            language: "fr",
            locale: "fr_FR",
            accessibilityLabel: "src, dossier",
            sendPathLabel: "Envoyer le chemin au terminal",
            copyPathLabel: "Copier le chemin"
        )
    }

    func testUIKitMenuAndAccessibilityAreLocalizedInJapanese() {
        verifyLocalizedUIKitRow(
            language: "ja",
            locale: "ja_JP",
            accessibilityLabel: "src、フォルダ",
            sendPathLabel: "パスをターミナルに送る",
            copyPathLabel: "パスをコピー"
        )
    }

    /// Fifth control: the same hold on a bare `Text` with a plain
    /// `.contextMenu` that shares nothing with the Files panel. Whatever
    /// repaints here cannot be caused by the panel.
    func testPlainContextMenuHold() throws {
        app.launchEnvironment["TESSERA_FILES_HARNESS_CHURN"] = "0"
        app.launchEnvironment["TESSERA_FILES_MENU_PROBES"] = "1"
        try holdMenuAcrossChurn(rowIdentifier: "files.row.plain-probe",
                                firedAction: "send:plain-probe")
    }

    /// Sixth control: a UIKit-native `UIContextMenuInteraction`, no SwiftUI
    /// bridge anywhere in the menu path.
    func testUIKitContextMenuHold() throws {
        app.launchEnvironment["TESSERA_FILES_HARNESS_CHURN"] = "0"
        app.launchEnvironment["TESSERA_FILES_MENU_PROBES"] = "1"
        try holdMenuAcrossChurn(rowIdentifier: "files.row.uikit-probe",
                                firedAction: nil)
    }

    /// Seventh control: the UIKit interaction, but carrying a hosted
    /// SwiftUI preview — the shape `.contextMenu(preview:)` produces.
    func testUIKitContextMenuHoldWithHostedPreview() throws {
        app.launchEnvironment["TESSERA_FILES_HARNESS_CHURN"] = "0"
        app.launchEnvironment["TESSERA_FILES_MENU_PROBES"] = "1"
        app.launchEnvironment["TESSERA_FILES_MENU_PROBE_PREVIEW"] = "1"
        try holdMenuAcrossChurn(rowIdentifier: "files.row.uikit-probe",
                                firedAction: nil)
    }

    /// The row's menu back on SwiftUI's `.contextMenu`, for the before/after
    /// pair against the shipping UIKit path.
    func testRowContextMenuOnSwiftUI() throws {
        app.launchEnvironment["TESSERA_FILES_HARNESS_CHURN"] = "0"
        app.launchEnvironment["TESSERA_FILES_UIKIT_MENU"] = "0"
        try holdMenuAcrossChurn()
    }

    /// Shipping UIKit path with the panel idle — the arm the recording is
    /// graded on for the single post-presentation flicker.
    func testRowContextMenuIdleOnUIKit() throws {
        app.launchEnvironment["TESSERA_FILES_HARNESS_CHURN"] = "0"
        try holdMenuAcrossChurn()
    }

    /// The row's primary action, which moved onto the UIKit view's own tap
    /// recognizer along with the menu. A row tap must still open Quick Look.
    func testRowTapOpensPreview() throws {
        app.launchEnvironment["TESSERA_FILES_HARNESS_CHURN"] = "0"
        app.launch()

        let row = app.descendants(matching: .any)["files.row.report_0003_analysis.md"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "synthetic listing never appeared")
        row.tap()

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15), "row tap did not open the preview")
        done.tap()
    }

    /// UIKit path with no hosted preview — isolates whether the hosted
    /// SwiftUI preview is what keeps the app from going idle while the menu
    /// is open.
    func testRowContextMenuUIKitWithoutPreview() throws {
        app.launchEnvironment["TESSERA_FILES_HARNESS_CHURN"] = "0"
        app.launchEnvironment["TESSERA_FILES_MENU_PREVIEW"] = "0"
        try holdMenuAcrossChurn()
    }

    /// Bug-present arm, same binary. The DEBUG seam drops the row-level
    /// short-circuit, so every panel pass rebuilds every realized row —
    /// including the presented menu's items and preview. Recorded next to
    /// the fixed arm as the before/after pair.
    func testRowContextMenuChurnsWithoutRowIsolation() throws {
        app.launchEnvironment["TESSERA_FILES_ROW_EQUATABLE"] = "0"
        try holdMenuAcrossChurn()
    }

    // NOTE ON RUNTIME: arms that present the UIKit context menu take ~2
    // minutes. XCUITest logs "App animations complete notification not
    // received" and waits 60s twice — UIKit does not post that notification
    // for its own menu presentation. The recording shows the screen pixel
    // still throughout, so nothing is animating; it is a harness artifact,
    // not app work. Do not "fix" it by shortening the hold.

    /// Presents a row's context menu, holds it open across several churn
    /// ticks for the external recorder, then taps a menu item. The tap
    /// landing is the regression oracle: with the menu re-publishing under
    /// it, the item never fires.
    private func holdMenuAcrossChurn(
        rowIdentifier: String = "files.row.report_0003_analysis.md",
        firedAction: String? = "send:report_0003_analysis.md"
    ) throws {
        app.launch()

        let row = app.descendants(matching: .any)[rowIdentifier]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "synthetic listing never appeared")

        mark("files-menu-before")
        row.press(forDuration: 1.2)

        let sendPath = menuItem(labeled: "Send Path to Terminal")
        XCTAssertTrue(
            sendPath.waitForExistence(timeout: 6),
            "context menu never presented"
        )
        mark("files-menu-presented")

        // Hold the menu open across several churn ticks — this is the
        // window the recording grades for flicker.
        usleep(4_000_000)
        mark("files-menu-held")

        sendPath.tap()

        // The harness echoes the fired action into its status label. The
        // UIKit control has no such echo — it only has to present.
        if let firedAction {
            let fired = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", firedAction)
            ).firstMatch
            XCTAssertTrue(
                fired.waitForExistence(timeout: 5),
                "menu item tap never reached the action — the platter was rebuilt under it"
            )
        }
        mark("files-menu-fired")
        usleep(1_000_000)
    }

    // MARK: - Helpers

    private func verifyLocalizedUIKitRow(
        language: String,
        locale: String,
        accessibilityLabel: String,
        sendPathLabel: String,
        copyPathLabel: String
    ) {
        app.launchEnvironment["TESSERA_FILES_HARNESS_FILECOUNT"] = "0"
        app.launchEnvironment["TESSERA_FILES_HARNESS_CHURN"] = "0"
        app.launchArguments += [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
        ]
        app.launch()

        let row = app.descendants(matching: .any)["files.row.src"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "canned directory never appeared")
        XCTAssertEqual(row.label, accessibilityLabel)
        row.press(forDuration: 1.2)

        XCTAssertTrue(
            menuItem(labeled: sendPathLabel).waitForExistence(timeout: 6),
            "localized UIKit menu never presented"
        )
        XCTAssertTrue(menuItem(labeled: copyPathLabel).exists)
        XCTAssertFalse(menuItem(labeled: "Send Path to Terminal").exists)
    }

    /// Context-menu items bridge to `UIMenu`, which XCUITest surfaces as
    /// buttons somewhere under the menu platter — query by label across
    /// element types rather than guessing the container.
    private func menuItem(labeled label: String) -> XCUIElement {
        let byButton = app.buttons[label]
        if byButton.exists { return byButton }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    private func mark(_ name: String) {
        print("TESSERA_VISUAL_EVENT \(name) epoch=\(Date().timeIntervalSince1970)")
    }
}
