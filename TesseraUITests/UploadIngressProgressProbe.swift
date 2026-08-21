import XCTest

/// Host-free UI coverage for the actual in-app upload step. The share
/// extension is intentionally outside this harness: it must continue to stage
/// Photos/videos and dismiss immediately without starting SFTP.
final class UploadIngressProgressProbe: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchEnvironment["TESSERA_UPLOAD_HARNESS"] = "1"
        app.launch()
    }

    func testProgressButtonAndPasteWarningsStayOnOneLine() {
        let upload = app.buttons["Upload"]
        XCTAssertTrue(upload.waitForExistence(timeout: 10))
        upload.tap()

        let background = app.buttons["upload.background"]
        XCTAssertTrue(background.waitForExistence(timeout: 5))
        XCTAssertFalse(background.label.contains("\n"))
        sleep(2)
        attachScreenshot(named: "upload-progress")

        background.tap()
        XCTAssertTrue(app.staticTexts["Continue upload in background?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "copied to the clipboard")
        ).firstMatch.exists)
        // iPad renders confirmationDialog as a popover and omits explicit
        // cancel-role rows; dismissing its system region is Keep Sheet Open.
        app.otherElements["PopoverDismissRegion"].tap()

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Cancel this upload?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "will not be pasted")
        ).firstMatch.exists)
        dialogButton(labeled: "Cancel Upload").tap()

        XCTAssertTrue(upload.waitForExistence(timeout: 5))
        XCTAssertFalse(background.exists)
    }

    func testBackgroundConfirmationUsesClipboardDelivery() {
        let upload = app.buttons["Upload"]
        XCTAssertTrue(upload.waitForExistence(timeout: 10))
        upload.tap()

        let background = app.buttons["upload.background"]
        XCTAssertTrue(background.waitForExistence(timeout: 5))
        background.tap()
        XCTAssertTrue(app.staticTexts["Continue upload in background?"].waitForExistence(timeout: 3))
        let continueButton = dialogButton(labeled: "Continue in Background")
        XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
        continueButton.tap()

        let status = app.staticTexts["upload.harness.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(status.label, "background-copy")
    }

    func testCompactWidthUsesShortBackgroundLabel() throws {
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        guard app.frame.width <= 500 else {
            throw XCTSkip("Compact-width label is covered by the iPhone lane")
        }

        let upload = app.buttons["Upload"]
        XCTAssertTrue(upload.waitForExistence(timeout: 10))
        upload.tap()

        let background = app.buttons["upload.background"]
        XCTAssertTrue(background.waitForExistence(timeout: 5))
        XCTAssertEqual(background.label, "Background")
        XCTAssertFalse(background.label.contains("\n"))
        XCTAssertTrue(background.value as? String != nil)
    }

    func testRejectedBackgroundHandoffKeepsProgressSheetVisible() {
        app.terminate()
        app.launchEnvironment["TESSERA_UPLOAD_BACKGROUND_REJECT"] = "1"
        app.launch()

        let upload = app.buttons["Upload"]
        XCTAssertTrue(upload.waitForExistence(timeout: 10))
        upload.tap()

        let background = app.buttons["upload.background"]
        XCTAssertTrue(background.waitForExistence(timeout: 5))
        background.tap()
        XCTAssertTrue(app.staticTexts["Continue upload in background?"].waitForExistence(timeout: 3))
        dialogButton(labeled: "Continue in Background").tap()

        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "couldn't obtain background time")
        ).firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(background.exists)
    }

    func testUploadSurfaceIsLocalizedInFrench() {
        verifyLocalizedUploadSurface(
            language: "fr",
            locale: "fr_FR",
            sheetTitle: "téléverser vers l'hôte",
            uploadLabel: "Téléverser",
            sourceFragment: "depuis Photos",
            backgroundLabels: ["Continuer en arrière-plan", "Arrière-plan"],
            progressFragments: ["Téléversement en cours", "pour cent téléversé"],
            dialogTitle: "Continuer le téléversement en arrière-plan ?"
        )
    }

    func testUploadSurfaceIsLocalizedInJapanese() {
        verifyLocalizedUploadSurface(
            language: "ja",
            locale: "ja_JP",
            sheetTitle: "ホストにアップロード",
            uploadLabel: "アップロード",
            sourceFragment: "Photos から",
            backgroundLabels: ["バックグラウンドで続ける", "バックグラウンド"],
            progressFragments: ["アップロード中", "パーセントアップロード済み"],
            dialogTitle: "バックグラウンドでアップロードを続けますか？"
        )
    }

    private func verifyLocalizedUploadSurface(
        language: String,
        locale: String,
        sheetTitle: String,
        uploadLabel: String,
        sourceFragment: String,
        backgroundLabels: [String],
        progressFragments: [String],
        dialogTitle: String
    ) {
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts[sheetTitle].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", sourceFragment)
        ).firstMatch.exists)

        let upload = app.buttons[uploadLabel]
        XCTAssertTrue(upload.waitForExistence(timeout: 10))
        upload.tap()

        let background = app.buttons["upload.background"]
        XCTAssertTrue(background.waitForExistence(timeout: 5))
        XCTAssertTrue(backgroundLabels.contains(background.label), "unexpected label: \(background.label)")
        if app.frame.height <= 500 {
            XCTAssertEqual(
                background.label,
                backgroundLabels.last,
                "the compact iPhone surface must use the localized short label"
            )
        }
        let progress = background.value as? String ?? ""
        XCTAssertTrue(
            progressFragments.contains { progress.contains($0) },
            "unexpected progress: \(progress)"
        )

        background.tap()
        XCTAssertTrue(app.staticTexts[dialogTitle].waitForExistence(timeout: 3))
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Confirmation-dialog actions are surfaced by XCUITest with their text
    /// as the accessibility label, not the identifier. For "Continue in
    /// Background" the underlying progress button has the same label; the
    /// dialog action is the last visible match in presentation order.
    private func dialogButton(labeled label: String) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
        return matches.element(boundBy: max(0, matches.count - 1))
    }
}
