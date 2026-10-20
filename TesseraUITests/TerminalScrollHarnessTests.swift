import XCTest
import CoreFoundation

final class SetupFlowPresentationHarnessTests: XCTestCase {
    func testNearbyZeroGrantReviewAndConfigureLater() { exercise(mode: "nearby") }
    func testQRCopySelectionReview() { exercise(mode: "qr") }
    func testLargeTextReviewAndRecovery() { exercise(mode: "nearby", large: true) }

    private func exercise(mode: String, large: Bool = false) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_SETUP_FLOW_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_SETUP_FLOW_MODE"] = mode
        app.launchEnvironment["TESSERA_SETUP_FLOW_LARGE_TEXT"] = large ? "1" : "0"
        app.launch()
        defer { app.terminate() }
        func capture(_ stage: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "setup-\(mode)-\(large ? "accessibility" : "standard")-\(stage)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        func tap(_ identifier: String) {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 8), identifier)
            for _ in 0..<10 {
                if button.isHittable && app.frame.contains(button.frame) { break }
                app.swipeUp()
            }
            XCTAssertTrue(button.isHittable, identifier)
            button.tap()
        }
        XCTAssertTrue(app.staticTexts["harness.code"].waitForExistence(timeout: 8))
        capture("verify")
        if large {
            tap("harness.reject")
            capture("mismatch")
            tap("start again")
        }
        tap("harness.match")
        capture("hosts")
        let next = app.buttons["next: choose data"]
        XCTAssertEqual(next.isEnabled, mode == "nearby", "Zero grants allowed nearby; empty copy disallowed for QR")
        if mode == "qr" {
            tap("harness.grant.11111111-1111-1111-1111-111111111111")
            tap("harness.grant.22222222-2222-2222-2222-222222222222")
        }
        tap("next: choose data")
        capture("include")
        tap("next: review transfer")
        capture("review")
        tap("harness.approve")
        capture("receipt")
        tap("harness.configure")
        XCTAssertTrue(app.staticTexts["harness.configured"].exists)
        capture("configure")
    }
}

final class QRLiveFixtureInspectionTests: XCTestCase {
    func testPerformApprovedFixtureStep() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TESSERA_QR_INSPECT"] == "1",
              let step = env["TESSERA_QR_STEP"] else {
            throw XCTSkip("Opt-in native driver for the disposable QR fixture")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.bambouville.TesseraApp")
        XCTAssertEqual(app.state, .runningForeground)
        // The live terminal cursor keeps XCTest's animation-idle heuristic
        // busy. Disable only that runner heuristic, not product animations.
        // Availability is checked because this is a simulator-only test hook.
        if app.responds(to: NSSelectorFromString("setIdleAnimationWaitEnabled:")) {
            app.setValue(false, forKey: "idleAnimationWaitEnabled")
        }
        func tap(_ label: String) {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "Missing fixture control: \(label)")
            button.tap()
        }
        switch step {
        case "remove-fixture-and-open-scan", "open-scan":
            if step == "remove-fixture-and-open-scan" {
                // Only the imported host on this disposable recipient. Keep
                // its generated local key so the retry proves a new model save.
                tap("hosts")
                let fixture = app.staticTexts["QR live VPS"].firstMatch
                XCTAssertTrue(fixture.waitForExistence(timeout: 5))
                fixture.press(forDuration: 1)
                tap("remove…")
                tap("remove host")
                XCTAssertTrue(fixture.waitForNonExistence(timeout: 5))
            }
            tap("settings")
            tap("sync & continuity")
            let scan = app.buttons["scan pairing code"]
            for _ in 0..<8 where !scan.isHittable { app.swipeUp() }
            tap("scan pairing code")
        case "enter-invitation":
            let invitation = try XCTUnwrap(env["TESSERA_QR_INVITATION"])
            let field = app.textViews["pairing.manual-text"]
            if !field.isHittable { tap("Enter a pairing code instead") }
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(invitation)
            tap("use code")
        case "import": tap("pairing.import")
        case "landscape":
            XCUIDevice.shared.orientation = .landscapeLeft
            let geometry = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in app.frame.width > app.frame.height },
                object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [geometry], timeout: 5), .completed)
        case "reopen":
            XCTAssertTrue(app.staticTexts.matching(identifier: "QR live VPS").firstMatch.exists)
            tap("reopen")
        case "trust-fixture":
            let fingerprint = try XCTUnwrap(env["TESSERA_QR_EXPECTED_HOST_FINGERPRINT"])
            let digest = String(fingerprint.dropFirst("SHA256:".count))
            XCTAssertTrue(fingerprint.hasPrefix("SHA256:") && digest.count == 43)
            XCTAssertEqual(Data(base64Encoded: digest + "=")?.count, 32)
            XCTAssertTrue(app.staticTexts["192.0.2.10:2222"].exists)
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(
                format: "label == %@ OR label == %@", fingerprint, fingerprint + "="
            )).firstMatch.exists, "Fixture host key must match independently verified full fingerprint")
            tap("Trust & Connect")
            XCTAssertTrue(app.buttons["Trust & Connect"].waitForNonExistence(timeout: 10))
        case "offer":
            XCTAssertTrue(app.staticTexts["QR live VPS"].exists)
            if app.buttons["Hide keyboard"].isHittable { tap("Hide keyboard") }
            tap("session-continuity-menu")
            tap("session-continuity-setup")
        case "verify":
            let expected = try XCTUnwrap(env["TESSERA_QR_EXPECTED_SAS"])
            let code = app.staticTexts["pairing.security-code"]
            XCTAssertTrue(code.waitForExistence(timeout: 10))
            XCTAssertEqual(code.label.filter(\.isNumber), expected)
            tap("pairing.codes-match")
        case "choose-data": tap("next: choose data")
        case "select-and-review":
            tap("next: choose data")
            tap("pairing.optional.trustedHostKeys")
            tap("next: review transfer")
        case "review": tap("next: review transfer")
        case "verify-and-select":
            let expected = try XCTUnwrap(env["TESSERA_QR_EXPECTED_SAS"])
            let code = app.staticTexts["pairing.security-code"]
            XCTAssertTrue(code.waitForExistence(timeout: 10))
            XCTAssertEqual(code.label.filter(\.isNumber), expected)
            tap("pairing.codes-match")
            tap("next: choose data")
            tap("pairing.optional.trustedHostKeys")
            tap("next: review transfer")
        case "approve":
            XCTAssertTrue(app.staticTexts.matching(identifier: "QR live VPS").firstMatch.exists)
            tap("pairing.approve")
        case "done": tap("done")
        case "restart-offer":
            tap("done")
            tap("session-continuity-menu")
            tap("session-continuity-setup")
        default: XCTFail("Unknown fixture step")
        }
        print("QR_FIXTURE_NATIVE_UI_BEGIN\n\(app.debugDescription)\nQR_FIXTURE_NATIVE_UI_END")
    }

    func testInspectRunningFixtureWithoutLaunchingOrConnecting() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_QR_INSPECT"] == "1" else {
            throw XCTSkip("Read-only inspection of an explicitly selected disposable QR fixture")
        }
        let app = XCUIApplication(bundleIdentifier: "com.bambouville.TesseraApp")
        XCTAssertEqual(app.state, .runningForeground)
        print("QR_FIXTURE_NATIVE_UI_BEGIN\n\(app.debugDescription)\nQR_FIXTURE_NATIVE_UI_END")
    }
}

final class CompactNavigationTransitionHarnessTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("compact navigation transition harness requires iPad")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testProductionShellTransitionMatrixRoundTrips() throws {
        launch(initialSize: "regular", initialRoute: "hosts")

        // Hosts is represented by nil regular selection. It must reset a stale
        // compact root to Hosts without persisting that presentation choice.
        let viewAll = app.buttons["view all hosts"]
        XCTAssertTrue(viewAll.waitForExistence(timeout: 5))
        tapCenter(viewAll)
        assertRoundTrip(
            compactTab: "hosts",
            regularVisible: app.descendants(matching: .any)["hosts-landing-page"],
            compactVisible: app.descendants(matching: .any)["hosts-landing-page"],
            route: "Hosts"
        )

        tapCenter(app.buttons["sidebar-navigation-keys"])
        assertRoundTrip(
            compactTab: "keys",
            regularVisible: app.buttons["+ generate"],
            compactVisible: app.buttons["+ generate"],
            route: "Keys",
            screenshotPath: "/tmp/tessera-compact-navigation-transition-current.png"
        )

        tapCenter(app.buttons["sidebar-navigation-known-hosts"])
        assertRoundTrip(
            compactTab: "keys",
            regularVisible: app.buttons["export"],
            compactVisible: app.descendants(matching: .any)["known-hosts-page"],
            route: "Known Hosts"
        )

        tapCenter(app.buttons["sidebar-navigation-settings"])
        assertRoundTrip(
            compactTab: "settings",
            regularVisible: app.staticTexts["appearance"],
            compactVisible: app.staticTexts["appearance"],
            route: "Settings"
        )

        tapCenter(app.buttons["agent-sidebar-row"])
        assertRoundTrip(
            compactTab: "sessions",
            regularVisible: app.descendants(matching: .any)["agent-center-page"],
            compactVisible: app.descendants(matching: .any)["agent-center-page"],
            route: "Agent Center"
        )

        // A saved host remains the same selected editor across both shells.
        tapCenter(app.buttons["view all hosts"])
        let hostSidebarRow = app.buttons[
            "sidebar-host-C011CA7E-0000-4000-8000-000000000001"
        ]
        XCTAssertTrue(hostSidebarRow.waitForExistence(timeout: 5))
        tapCenter(hostSidebarRow)
        assertRoundTrip(
            compactTab: "hosts",
            regularVisible: app.buttons["connect"],
            compactVisible: app.buttons["save"],
            route: "Host editor"
        )

    }

    func testSelectedLiveSessionRoundTripDoesNotRestartItsTask() throws {
        launch(initialSize: "regular", initialRoute: "session")

        XCTAssertTrue(app.buttons["Connection status"].waitForExistence(timeout: 10))
        assertSessionViewTaskStartCount(1)
        assertConnectCallCount(1)
        assertRoundTrip(
            compactTab: "sessions",
            regularVisible: app.buttons["Connection status"],
            compactVisible: app.buttons["Back — session keeps running"],
            route: "live session",
            checkSessionTask: true
        )
        assertConnectCallCount(1)
        XCTAssertTrue(
            app.staticTexts["idle"].exists,
            "the fixture session must remain idle; width changes cannot connect it"
        )
    }

    func testCompactFirstLaunchKeepsCompactRootNavigationUsable() throws {
        launch(initialSize: "compact", initialRoute: "hosts")

        assertSelectedTab("hosts", route: "compact-first Hosts")
        XCTAssertTrue(
            app.staticTexts["navigation fixture host"].waitForExistence(timeout: 10)
        )

        app.tabBars.buttons["sessions"].tap()
        assertSelectedTab("sessions", route: "compact-first Sessions")
        XCTAssertTrue(
            app.staticTexts["navigation fixture session"].waitForExistence(timeout: 5)
        )
    }

    private func launch(initialSize: String, initialRoute: String) {
        app = XCUIApplication()
        app.launchEnvironment["TESSERA_COMPACT_NAVIGATION_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_COMPACT_NAVIGATION_INITIAL_SIZE"] = initialSize
        app.launchEnvironment["TESSERA_COMPACT_NAVIGATION_INITIAL_ROUTE"] = initialRoute
        // Hold every forever animation (launch-overlay halo, status-dot
        // pulses) static: each width toggle otherwise pays two 60 s XCUITest
        // idle timeouts, ~16 minutes across this class.
        app.launchEnvironment["TESSERA_STATIC_RINGS"] = "1"
        app.launchArguments += [
            "-tessera.nearbyBootstrap.completed.v1", "YES",
            "-tessera.pref.hasSeenWelcome", "YES",
            "-tessera.pref.agentCenterEnabled", "YES",
        ]
        app.launch()
    }

    private func assertRoundTrip(
        compactTab: String,
        regularVisible: XCUIElement,
        compactVisible: XCUIElement,
        route: String,
        screenshotPath: String? = nil,
        checkSessionTask: Bool = false
    ) {
        XCTAssertTrue(
            regularVisible.waitForExistence(timeout: 5),
            "regular \(route) destination is not visible before resizing"
        )

        toggleWidth(to: "compact")
        if checkSessionTask {
            assertSessionViewTaskStartCount(1)
            assertConnectCallCount(1)
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        assertSelectedTab(compactTab, route: route)
        XCTAssertTrue(
            compactVisible.waitForExistence(timeout: 5),
            "compact \(route) destination is not visible after resizing"
        )

        if let screenshotPath {
            let screenshot = XCUIScreen.main.screenshot().pngRepresentation
            try? screenshot.write(to: URL(fileURLWithPath: screenshotPath))
        }

        toggleWidth(to: "regular")
        if checkSessionTask {
            assertSessionViewTaskStartCount(1)
            assertConnectCallCount(1)
        }
        let returnScreenshot = XCUIScreen.main.screenshot().pngRepresentation
        try? returnScreenshot.write(
            to: URL(fileURLWithPath: "/tmp/tessera-compact-navigation-return-current.png")
        )
        XCTAssertTrue(
            app.buttons["sidebar-navigation-keys"].waitForExistence(timeout: 5),
            "regular shell did not return after round-tripping \(route)"
        )
        XCTAssertTrue(
            regularVisible.waitForExistence(timeout: 5),
            "regular \(route) destination changed during the compact round trip"
        )
    }

    private func assertSessionViewTaskStartCount(
        _ expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let count = app.staticTexts["compact-navigation-session-task-start-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5), file: file, line: line)
        let predicate = NSPredicate(format: "label == %@", String(expectedCount))
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: count)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "width transition remounted the live SessionView",
            file: file,
            line: line
        )
    }

    private func assertConnectCallCount(
        _ expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let count = app.staticTexts["compact-navigation-connect-call-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5), file: file, line: line)
        let predicate = NSPredicate(format: "label == %@", String(expectedCount))
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: count)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "width transition initiated an additional connection or missed the baseline",
            file: file,
            line: line
        )
    }

    private func toggleWidth(to expectedSize: String) {
        let sizeState = app.staticTexts["compact-navigation-harness-size"]
        XCTAssertTrue(sizeState.waitForExistence(timeout: 5))
        let notification = "com.bambouville.TesseraApp.tests.compact-navigation.\(expectedSize)"
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notification as CFString),
            nil,
            nil,
            true
        )
        let predicate = NSPredicate(format: "label == %@", expectedSize)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: sizeState)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private func assertSelectedTab(_ label: String, route: String) {
        let tab = app.tabBars.buttons[label]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "missing \(label) tab for \(route)")
        let deadline = Date().addingTimeInterval(5)
        while !tab.isSelected && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(tab.isSelected, "\(route) mapped to the wrong compact tab")
    }

    /// XCUITest can retain an invalid semantic hit point after the DEBUG
    /// harness changes only horizontalSizeClass. A screen-coordinate tap at
    /// the element's current accessibility frame still exercises the actual
    /// SwiftUI hit-test and fails downstream if another layer intercepts it.
    private func tapCenter(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        let frame = element.frame
        let appFrame = app.frame
        XCTAssertFalse(frame.isEmpty, file: file, line: line)
        XCTAssertTrue(appFrame.intersects(frame), file: file, line: line)
        app.coordinate(
            withNormalizedOffset: CGVector(
                dx: (frame.midX - appFrame.minX) / appFrame.width,
                dy: (frame.midY - appFrame.minY) / appFrame.height
            )
        ).tap()
    }
}

/// Production presentation coverage for OpenSSH import. The previous
/// SwiftUI fileImporter silently ignored taps when mounted beneath Tessera's
/// custom key modal on iOS 26.
final class KeyImportPickerHarnessTests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testDocumentPickerCancelsAndReopens() {
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["TESSERA_COMPACT_NAVIGATION_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_COMPACT_NAVIGATION_INITIAL_SIZE"] = "compact"
        app.launchArguments += [
            "-tessera.nearbyBootstrap.completed.v1", "YES",
            "-tessera.pref.hasSeenWelcome", "YES",
        ]
        app.launch()

        let keysTab = app.tabBars.buttons["keys"]
        XCTAssertTrue(keysTab.waitForExistence(timeout: 10))
        keysTab.tap()

        let importButton = app.buttons["import"].firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.tap()

        let chooseFile = app.buttons["choose file…"]
        XCTAssertTrue(chooseFile.waitForExistence(timeout: 5))

        for attempt in 1...2 {
            chooseFile.tap()
            // The picker exposes different container identifiers between
            // iPad's split browser and iPhone's compact browser. Its system
            // Cancel action is stable on both; Tessera's own action is the
            // distinct lowercase "cancel" label.
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(
                cancel.waitForExistence(timeout: 10),
                "system document picker did not present on attempt \(attempt)"
            )

            cancel.tap()
            XCTAssertTrue(
                chooseFile.waitForExistence(timeout: 5),
                "OpenSSH import did not recover after cancelling attempt \(attempt)"
            )
        }
    }
}

/// Fast end-to-end check for Tessera's indirect-pointer scroll wiring.
///
/// The app launches a DEBUG-only, host-free TerminalSurfaceBound with 500
/// deterministic rows. The oracle is its real UIScrollView content offset,
/// projected through accessibility as `bottom` / `history`; Metal screenshots,
/// external typing, and live-session idle waits are intentionally absent.
final class TerminalScrollHarnessTests: XCTestCase {
    func testMarkdownPreviewDismissalPreservesPrompt() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_SCROLL_CAPTURE"] == "1" else {
            throw XCTSkip("driven by the disposable scroll integration lane")
        }
        XCUIDevice.shared.orientation = XCUIDevice.shared.supportsPointerInteraction ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_SCROLL_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_TOUCH_SCROLL_HARNESS"] = "0"
        app.launchEnvironment["TESSERA_IDLE_REDRAW_HARNESS"] = "preview"
        app.launchEnvironment["TESSERA_PREVIEW_RESIZE_PULSE"] = "1"
        app.launchEnvironment["TESSERA_PREVIEW_MODE"] = "popup"
        app.launch()
        defer { app.terminate() }
        let terminal = app.descendants(matching: .any)["terminal-scroll-harness"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 8))
        try waitForValue("preview-clean", on: terminal, timeout: 30)
    }

    func testIdleRedrawAndSplitColorRepaint() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_SCROLL_CAPTURE"] == "1" else {
            throw XCTSkip("driven by the disposable scroll integration lane")
        }
        XCUIDevice.shared.orientation = XCUIDevice.shared.supportsPointerInteraction ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        for (mode, expected) in [("1", "redraw-stable"), ("color", "repaint-clean")] {
            app.launchEnvironment["TESSERA_SCROLL_HARNESS"] = "1"
            app.launchEnvironment["TESSERA_TOUCH_SCROLL_HARNESS"] = "0"
            app.launchEnvironment["TESSERA_IDLE_REDRAW_HARNESS"] = mode
            app.launch()
            let terminal = app.descendants(matching: .any)["terminal-scroll-harness"]
            XCTAssertTrue(terminal.waitForExistence(timeout: 8))
            try waitForValue(expected, on: terminal, timeout: 20)
            app.terminate()
        }
    }

    func testPrimaryScrollMovesIntoHistoryAndBackToBottom() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_SCROLL_CAPTURE"] == "1" else {
            throw XCTSkip(
                "scroll wiring is driven by scripts/integration/run-integration-tests.sh"
            )
        }
        XCTAssertTrue(XCUIDevice.shared.supportsPointerInteraction)
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        // The runner injects TESSERA_SCROLL_HARNESS into the dedicated
        // simulator's launchd environment. `activate` avoids asking XCTest to
        // wait for terminal rendering to become globally quiescent.
        app.activate()

        let state = app.descendants(matching: .any)["terminal-scroll-harness"]
        XCTAssertTrue(state.waitForExistence(timeout: 8))
        try waitForValue("bottom", on: state, timeout: 5)

        app.scroll(byDeltaX: 0, deltaY: -800)
        try waitForValue("history", on: state, timeout: 5)

        // XCUITest's synthesized positive and negative deltas are not
        // guaranteed to deliver equal UIPan translations. Drive toward the
        // real boundary with a small cap; the production path clamps at the
        // live tail and the accessibility oracle confirms arrival.
        for _ in 0..<3 {
            if state.value as? String == "bottom" { break }
            app.scroll(byDeltaX: 0, deltaY: 800)
        }
        try waitForValue("bottom", on: state, timeout: 5)
    }

    func testHookProvenWorkingAgentConsumesPointerScrollAndShowsNotice() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_SCROLL_CAPTURE"] == "1" else {
            throw XCTSkip(
                "scroll wiring is driven by scripts/integration/run-integration-tests.sh"
            )
        }
        XCTAssertTrue(XCUIDevice.shared.supportsPointerInteraction)
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_SCROLL_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_SCROLL_BLOCK_HARNESS"] = "1"
        app.launch()
        defer { app.terminate() }

        let state = app.descendants(matching: .any)["terminal-scroll-harness"]
        XCTAssertTrue(state.waitForExistence(timeout: 8))
        try waitForValue("bottom", on: state, timeout: 5)

        app.scroll(byDeltaX: 0, deltaY: -800)

        try waitForValue("agent-blocked-bottom", on: state, timeout: 5)
        XCTAssertTrue(
            app.descendants(matching: .any)["agent-scroll-prevention-notice"]
                .waitForExistence(timeout: 2)
        )

        // A horizontal-dominant trackpad gesture can still carry a vertical
        // component. The guard must consume that Y delta as well.
        app.scroll(byDeltaX: 800, deltaY: -200)
        try waitForValue("agent-blocked-bottom", on: state, timeout: 5)
        XCTAssertEqual(
            state.value as? String,
            "agent-blocked-bottom",
            "blocked pointer input must leave primary-screen scrollback at the live tail"
        )
    }

    private func waitForValue(
        _ value: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) throws {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "expected scroll state \(value), got \(String(describing: element.value))"
        )
    }
}

/// Regression for direct-touch scrolling in alternate-screen TUIs such as
/// Claude Code. Unlike `XCUIApplication.scroll`, `swipeUp` synthesizes a
/// touchscreen pan and therefore exercises the phone-only failure path.
final class TerminalTouchScrollHarnessTests: XCTestCase {
    func testTouchSwipeForwardsMouseWheelInAlternateScreen() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_TOUCH_SCROLL_CAPTURE"] == "1" else {
            throw XCTSkip(
                "touch scroll wiring is driven by scripts/integration/run-scroll-harness-tests.sh"
            )
        }
        XCUIDevice.shared.orientation = .portrait

        let app = XCUIApplication()
        app.activate()

        let terminal = app.descendants(matching: .any)["terminal-touch-scroll-harness"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 8))
        try waitForValue("ready", on: terminal, timeout: 5)

        terminal.swipeUp()
        try waitForValue("mouse-wheel-forwarded", on: terminal, timeout: 5)
    }

    func testHookProvenWorkingAgentConsumesTouchScrollAndShowsNotice() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_TOUCH_SCROLL_CAPTURE"] == "1" else {
            throw XCTSkip(
                "touch scroll wiring is driven by scripts/integration/run-scroll-harness-tests.sh"
            )
        }
        XCUIDevice.shared.orientation = .portrait

        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_TOUCH_SCROLL_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_SCROLL_BLOCK_HARNESS"] = "1"
        app.launch()
        defer { app.terminate() }

        let terminal = app.descendants(matching: .any)["terminal-touch-scroll-harness"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 8))
        try waitForValue("ready", on: terminal, timeout: 5)

        terminal.swipeUp()

        try waitForValue("agent-scroll-blocked", on: terminal, timeout: 5)
        XCTAssertTrue(
            app.descendants(matching: .any)["agent-scroll-prevention-notice"]
                .waitForExistence(timeout: 2)
        )
    }

    /// mosh+tmux primary screen: finger pans reach the host's history hook
    /// the way a trackpad's do.
    func testMoshPrimaryFingerPanRequestsHistory() throws {
        let (_, terminal) = try launchPrimaryHarness(.moshPrimary, blocksAgentScrolling: false)
        terminal.swipeDown()
        try waitForValue("primary-history-requested", on: terminal, timeout: 5)
    }

    /// SSH+tmux primary screen: UIScrollView's own finger pan and its glide
    /// reach the host frame by frame, until a fling's glide carries past the
    /// oldest row. SwiftTerm reports none of them, and without them a finger
    /// never asked the inline history ladder for more than its 2000-row
    /// attach capture.
    func testInlinePrimaryFingerFramesReachTheHostThroughTheGlide() throws {
        let (_, terminal) = try launchPrimaryHarness(.inlinePrimary, blocksAgentScrolling: false)
        for _ in 0..<6 where terminal.value as? String != "native-frames-crossed-oldest" {
            terminal.swipeDown(velocity: .fast)
            sleep(2)
        }
        try waitForValue("native-frames-crossed-oldest", on: terminal, timeout: 5)
    }

    /// The blocker takes vertical-dominant finger pans only. A diagonal one
    /// must not reach UIScrollView's own pan on a primary screen either, where
    /// it would move history and, under SSH+tmux, ask for more.
    func testHookProvenWorkingAgentConsumesDiagonalInlinePrimaryFingerPan() throws {
        let (app, terminal) = try launchPrimaryHarness(.inlinePrimary, blocksAgentScrolling: true)
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.35)).press(
            forDuration: 0.05,
            thenDragTo: terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)),
            withVelocity: XCUIGestureVelocity(600),
            thenHoldForDuration: 0.1
        )
        try waitForValue("agent-scroll-blocked", on: terminal, timeout: 5)
        XCTAssertTrue(
            app.descendants(matching: .any)["agent-scroll-prevention-notice"]
                .waitForExistence(timeout: 2)
        )
        sleep(1)
        XCTAssertEqual(
            terminal.value as? String,
            "agent-scroll-blocked",
            "a diagonal finger pan moved primary history while an agent works"
        )
    }

    /// The blocker takes vertical-dominant finger pans. A diagonal one still
    /// carries a vertical component and must not reach the history hook.
    func testHookProvenWorkingAgentConsumesDiagonalMoshPrimaryFingerPan() throws {
        let (app, terminal) = try launchPrimaryHarness(.moshPrimary, blocksAgentScrolling: true)
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.35)).press(
            forDuration: 0.05,
            thenDragTo: terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)),
            withVelocity: XCUIGestureVelocity(600),
            thenHoldForDuration: 0.1
        )
        try waitForValue("agent-scroll-blocked", on: terminal, timeout: 5)
        XCTAssertTrue(
            app.descendants(matching: .any)["agent-scroll-prevention-notice"]
                .waitForExistence(timeout: 2)
        )
        sleep(1)
        XCTAssertEqual(
            terminal.value as? String,
            "agent-scroll-blocked",
            "a diagonal finger pan moved primary history while an agent works"
        )
    }

    private enum PrimaryHarness: String {
        case moshPrimary = "TESSERA_TOUCH_SCROLL_HARNESS_MOSH_PRIMARY"
        case inlinePrimary = "TESSERA_TOUCH_SCROLL_HARNESS_INLINE_PRIMARY"
    }

    private func launchPrimaryHarness(
        _ harness: PrimaryHarness,
        blocksAgentScrolling: Bool
    ) throws -> (XCUIApplication, XCUIElement) {
        guard ProcessInfo.processInfo.environment["TESSERA_TOUCH_SCROLL_CAPTURE"] == "1" else {
            throw XCTSkip(
                "touch scroll wiring is driven by scripts/integration/run-scroll-harness-tests.sh"
            )
        }
        XCUIDevice.shared.orientation = .portrait

        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_TOUCH_SCROLL_HARNESS"] = "1"
        app.launchEnvironment[harness.rawValue] = "1"
        if blocksAgentScrolling {
            app.launchEnvironment["TESSERA_AGENT_SCROLL_BLOCK_HARNESS"] = "1"
        }
        app.launch()
        addTeardownBlock { app.terminate() }

        let terminal = app.descendants(matching: .any)["terminal-touch-scroll-harness"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 8))
        try waitForValue("ready", on: terminal, timeout: 5)
        return (app, terminal)
    }

    private func waitForValue(
        _ value: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) throws {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "expected touch-scroll state \(value), got \(String(describing: element.value))"
        )
    }
}

/// Pin for ordinary XCUITest quiescence under the swipe pad's continuous
/// states. The dictation harness runs the pad's real repeatForever pulse
/// (dot + pill); without `TESSERA_STATIC_RINGS` every public-API tap stalls
/// waiting for app idle until XCTest's ~30 s per-event timeout lapses. The
/// launch environment is the checked-in default automation path — no
/// simulator accessibility mutation (Reduce Motion) required.
final class SwipePadQuiescenceHarnessTests: XCTestCase {
    func testStandardTapsCompleteWithStaticRings() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_SWIPEPAD_DICTATION_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_STATIC_RINGS"] = "1"
        app.launch()
        defer { app.terminate() }

        let restart = app.buttons["swipepad-harness-restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 15))

        // Two ordinary taps (each implicitly waits for app idle). With the
        // rings static these are near-instant; a regressed gate makes each
        // one sit out the full idle timeout, so the wall-clock bound is the
        // actual assertion.
        let started = Date()
        restart.tap()
        restart.tap()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed,
            20,
            "standard taps stalled (\(elapsed)s) — a continuous animation is defeating TESSERA_STATIC_RINGS"
        )

        let outcome = app.staticTexts["swipepad-harness-outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 5))
    }
}

/// Visual pin for the completion treatment: the host-free harness renders the
/// production puck in landscape and retains a screenshot in the test result.
final class SwipePadStatusGlowHarnessTests: XCTestCase {
    func testFinishedStateRendersOnTheWholePuck() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_SWIPEPAD_STATUS_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_SWIPEPAD_STATUS_HARNESS_STATE"] = "finished"
        app.launchEnvironment["TESSERA_STATIC_RINGS"] = "1"
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        defer { app.terminate() }

        let puck = app.descendants(matching: .any)["swipepad-puck"]
        XCTAssertTrue(puck.waitForExistence(timeout: 15))
        XCTAssertTrue(puck.label.contains("finished"))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "swipepad-finished-full-pad-glow"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Device-matrix pin for the unsaved cold-launch position. The production
/// four-petal surface is forced open so a screenshot and accessibility query
/// distinguish the cardinal radial from the edge chip-stack fallback.
final class SwipePadDefaultPlacementHarnessTests: XCTestCase {
    func testDefaultPlacementKeepsRadialInPortrait() throws {
        try runDefaultPlacementCheck(orientation: .portrait)
    }

    func testDefaultPlacementKeepsRadialInLandscape() throws {
        try runDefaultPlacementCheck(orientation: .landscapeLeft)
    }

    private func runDefaultPlacementCheck(
        orientation: UIDeviceOrientation
    ) throws {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_SWIPEPAD_OVERFLOW_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_SWIPEPAD_USE_DEFAULT_POSITION"] = "1"
        app.launchEnvironment["TESSERA_SWIPEPAD_FORCE_RADIAL_OPEN"] = "1"
        app.launchEnvironment["TESSERA_STATIC_RINGS"] = "1"
        XCUIDevice.shared.orientation = orientation
        app.launch()
        defer { app.terminate() }

        let puck = app.descendants(matching: .any)["swipepad-puck"]
        XCTAssertTrue(puck.waitForExistence(timeout: 15))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = orientation.isLandscape
            ? "swipepad-default-landscape"
            : "swipepad-default-portrait"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(
            app.descendants(matching: .any)["swipepad-radial-petal-right"]
                .waitForExistence(timeout: 3),
            "default position fell back to direction rows"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["swipepad-chip-stack"].exists
        )
    }
}

/// R4-F2 interaction closure: overflow stays separately reachable without
/// taking the configured down gesture away from its macro.
final class SwipePadOverflowHarnessTests: XCTestCase {
    func testPuckMoreAndDownMacroRemainIndependentlyReachable() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_SWIPEPAD_OVERFLOW_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_STATIC_RINGS"] = "1"
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        defer { app.terminate() }

        let puck = app.descendants(matching: .any)["swipepad-puck"]
        XCTAssertTrue(puck.waitForExistence(timeout: 15))

        let outcome = app.staticTexts["swipepad-overflow-outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 5))

        puck.tap()
        expectation(
            for: NSPredicate(format: "label CONTAINS %@", "more 1"),
            evaluatedWith: outcome
        )
        waitForExpectations(timeout: 5)

        let start = puck.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let down = puck.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 2.0))
        start.press(forDuration: 0.08, thenDragTo: down)
        expectation(
            for: NSPredicate(format: "label CONTAINS %@", "sent 35 0d"),
            evaluatedWith: outcome
        )
        waitForExpectations(timeout: 5)
    }
}

/// Regression coverage for the browse-page sidebar toggle in both iPad
/// orientations. The shell once stored `NavigationSplitViewVisibility` and
/// derived visibility from `!= .detailOnly`; on iPadOS 26 `.automatic`
/// compares equal to `.detailOnly` in portrait, so the floating reveal
/// button existed but assigning `.automatic` was a no-op. The launch
/// arguments below pre-complete first-open flows so the landing page is
/// interactive rather than covered by the Nearby Setup modal.
final class SidebarToggleHarnessTests: XCTestCase {
    func testSidebarToggleWorksInPortrait() throws {
        try runToggleCheck(orientation: .portrait)
    }

    func testSidebarToggleWorksInLandscape() throws {
        try runToggleCheck(orientation: .landscapeLeft)
    }

    private func runToggleCheck(orientation: UIDeviceOrientation) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("the floating sidebar toggle is an iPad affordance")
        }
        XCUIDevice.shared.orientation = orientation

        let app = XCUIApplication()
        app.launchArguments += [
            "-tessera.nearbyBootstrap.completed.v1", "YES",
            "-tessera.pref.hasSeenWelcome", "YES",
        ]
        app.launch()
        defer { app.terminate() }

        let collapse = app.descendants(matching: .any)["hide sidebar"].firstMatch
        let reveal = app.descendants(matching: .any)["show sidebar"].firstMatch

        // The sidebar starts expanded on every orientation.
        XCTAssertTrue(
            collapse.waitForExistence(timeout: 10),
            "sidebar collapse chevron missing after launch"
        )

        collapse.tap()
        XCTAssertTrue(
            reveal.waitForExistence(timeout: 5),
            "floating reveal button missing after collapsing the sidebar"
        )

        reveal.tap()
        XCTAssertTrue(
            collapse.waitForExistence(timeout: 5),
            "sidebar did not reopen after tapping the reveal button"
        )
    }
}

/// Production responder-path acceptance for the iPhone keyboard control.
///
/// The harness is host-free and uses the real TerminalSurfaceBound plus the
/// real SessionAccessoryBar. The accessory-bar button must restore first
/// responder after dismissal and show the keyboard again.
final class IPhoneKeyboardHarnessTests: XCTestCase {
    func testKeyboardButtonTogglesDismissalAndRestoration() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("iPhone keyboard harness requires an iPhone simulator")
        }

        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_IPHONE_KEYBOARD_HARNESS"] = "1"
        app.launch()
        defer { app.terminate() }

        let terminal = app.descendants(matching: .any)["iphone-keyboard-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        let state = app.descendants(matching: .any)["iphone-keyboard-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        try waitForValue("visible", on: state, timeout: 8)
        let viewportRows = app.descendants(matching: .any)[
            "iphone-terminal-viewport-rows"
        ]
        XCTAssertTrue(viewportRows.waitForExistence(timeout: 5))
        let keyboardVisibleRows = try waitForRows(
            on: viewportRows,
            timeout: 8,
            where: { $0 > 0 },
            description: "become positive"
        )

        let hideCount = app.descendants(matching: .any)[
            "iphone-keyboard-hide-count"
        ]
        XCTAssertTrue(hideCount.waitForExistence(timeout: 5))
        XCTAssertEqual(String(describing: hideCount.value ?? ""), "0")
        let orientationNoise = app.buttons[
            "iphone-keyboard-orientation-noise"
        ]
        XCTAssertTrue(orientationNoise.waitForExistence(timeout: 5))
        XCTAssertTrue(orientationNoise.isHittable)
        orientationNoise.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(
            String(describing: hideCount.value ?? ""),
            "0",
            "physical orientation noise must not dismiss the software keyboard"
        )
        XCTAssertEqual(String(describing: state.value ?? ""), "visible")
        XCTAssertEqual(
            String(describing: viewportRows.value ?? ""),
            String(keyboardVisibleRows),
            "physical orientation noise must not change the terminal viewport"
        )

        let hide = app.buttons["Hide keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        let leftArrow = app.descendants(matching: .any)["Left arrow"]
        XCTAssertTrue(leftArrow.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            leftArrow.frame.maxX,
            hide.frame.minX,
            "the iPhone keyboard-dismiss control must not cover the last fully visible navigation key"
        )
        XCTAssertTrue(hide.isHittable)
        hide.tap()
        try waitForValue("hidden", on: state, timeout: 8)
        _ = try waitForRows(
            on: viewportRows,
            timeout: 8,
            where: { $0 == keyboardVisibleRows },
            description: "remain stable after hiding the keyboard"
        )

        let show = app.buttons["Show keyboard"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        XCTAssertTrue(show.isHittable)
        let escape = app.descendants(matching: .any)["Escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(
            escape.frame.minX,
            app.frame.minX + 12,
            "the collapsed bar must clear the iPhone's leading display curve"
        )
        XCTAssertLessThanOrEqual(
            show.frame.maxX,
            app.frame.maxX - 12,
            "the collapsed bar must clear the iPhone's trailing display curve"
        )
        show.tap()
        try waitForValue("visible", on: state, timeout: 8)
        _ = try waitForRows(
            on: viewportRows,
            timeout: 8,
            where: { $0 == keyboardVisibleRows },
            description: "return after showing the keyboard"
        )
        XCTAssertTrue(app.buttons["Hide keyboard"].waitForExistence(timeout: 5))
    }

    func testOptInResizeChangesViewportRows() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("iPhone keyboard harness requires an iPhone simulator")
        }

        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_IPHONE_KEYBOARD_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_KEYBOARD_RESIZE_HARNESS"] = "1"
        app.launch()
        defer { app.terminate() }

        let state = app.descendants(matching: .any)["iphone-keyboard-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        try waitForValue("visible", on: state, timeout: 8)
        let viewportRows = app.descendants(matching: .any)[
            "iphone-terminal-viewport-rows"
        ]
        XCTAssertTrue(viewportRows.waitForExistence(timeout: 5))
        let keyboardVisibleRows = try waitForRows(
            on: viewportRows,
            timeout: 8,
            where: { $0 > 0 },
            description: "become positive"
        )

        let hide = app.buttons["Hide keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.tap()
        try waitForValue("hidden", on: state, timeout: 8)
        _ = try waitForRows(
            on: viewportRows,
            timeout: 8,
            where: { $0 > keyboardVisibleRows },
            description: "increase after opting into keyboard resize"
        )
    }

    private func waitForValue(
        _ value: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) throws {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "expected keyboard state \(value), got \(String(describing: element.value))"
        )
    }

    private func waitForRows(
        on element: XCUIElement,
        timeout: TimeInterval,
        where predicate: (Int) -> Bool,
        description: String
    ) throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let value = String(describing: element.value ?? "")
            if let rows = Int(value), predicate(rows) {
                return rows
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        XCTFail(
            "Expected viewport rows to \(description); final value was \(String(describing: element.value ?? ""))"
        )
        throw NSError(
            domain: "IPhoneKeyboardHarnessTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Viewport row expectation failed"]
        )
    }
}

/// The session's keyboard translation deliberately pushes the composed surface
/// up behind the software keyboard so SwiftTerm's grid never reflows. Find is
/// the one thing that trade-off cannot cover: the query field and match counter
/// are an input the user has to *read* while typing into it, and before
/// `KeyboardLiftExemptChrome` they rode the translation ~336 pt above the top of
/// the screen.
///
/// Frames, not existence: the field stayed hittable off-screen the whole time,
/// which is exactly why this went unnoticed.
final class IPhoneFindBarKeyboardHarnessTests: XCTestCase {
    func testFindFieldStaysOnScreenWithTheSoftwareKeyboardUp() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("software-keyboard find acceptance requires an iPhone simulator")
        }

        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_IPHONE_KEYBOARD_HARNESS"] = "1"
        app.launch()
        defer { app.terminate() }

        let state = app.descendants(matching: .any)["iphone-keyboard-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        let visible = NSPredicate(format: "value == %@", "visible")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: visible, object: state)],
                timeout: 8
            ),
            .completed,
            "the harness terminal must have raised the software keyboard"
        )

        let viewportRows = app.descendants(matching: .any)[
            "iphone-terminal-viewport-rows"
        ]
        XCTAssertTrue(viewportRows.waitForExistence(timeout: 5))

        let openFind = app.buttons["iphone-keyboard-open-find"]
        XCTAssertTrue(openFind.waitForExistence(timeout: 5))
        openFind.tap()

        let field = app.textFields["find-query-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // Focus (and therefore the keyboard) belongs to the find field now.
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: visible, object: state)],
                timeout: 8
            ),
            .completed
        )
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let screen = app.frame
        let frame = field.frame
        XCTAssertGreaterThanOrEqual(
            frame.minY,
            screen.minY,
            "the find query field must not sit above the top of the screen"
        )
        XCTAssertLessThanOrEqual(
            frame.maxY,
            keyboard.frame.minY,
            "the find query field must not sit under the software keyboard"
        )

        // The translation still has to be doing its job: a grid that reflowed to
        // fit above the keyboard would report roughly the 18–24 rows the phone
        // viewport holds, not the retained window-bottom height.
        let rows = Int(String(describing: viewportRows.value ?? "")) ?? 0
        XCTAssertGreaterThan(
            rows,
            26,
            "pinning the chrome must not reintroduce a keyboard-driven grid reflow"
        )

        // Reachable, not merely on screen: an element whose centre falls outside
        // the window is not hittable, which is the other half of the regression.
        // Focus is deliberately not asserted here — the harness terminal mounts
        // with the reclaim policy of an unfocused pane surface, not a live
        // session's, so who holds first responder is not a faithful signal.
        XCTAssertTrue(
            field.isHittable,
            "the find query field must be reachable where it renders"
        )
    }
}

/// Rendering acceptance for the accessory bar against the real software
/// keyboard. Unlike existence/hittability checks, this compares the rendered
/// frames so the keyboard cannot cover even a still-accessible portion of a
/// chip or the keyboard toggle.
final class KeyboardAccessoryOcclusionHarnessTests: XCTestCase {
    func testAccessoryBarClearsKeyboardInPortrait() throws {
        try assertAccessoryBarClearsKeyboard(orientation: .portrait)
    }

    func testAccessoryBarClearsKeyboardInLandscape() throws {
        try assertAccessoryBarClearsKeyboard(orientation: .landscapeLeft)
    }

    private func assertAccessoryBarClearsKeyboard(
        orientation: UIDeviceOrientation
    ) throws {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_IPHONE_KEYBOARD_HARNESS"] = "1"
        app.launch()
        defer { app.terminate() }

        let state = app.descendants(matching: .any)["iphone-keyboard-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        let visible = NSPredicate(format: "value == %@", "visible")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: visible, object: state)],
                timeout: 8
            ),
            .completed
        )

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        let escape = app.descendants(matching: .any)["Escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 5))
        let toggleLabel = UIDevice.current.userInterfaceIdiom == .phone
            ? "Hide keyboard"
            : "Hide accessory bar"
        let toggle = app.buttons[toggleLabel]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        let keyboardTop = keyboard.frame.minY
        for element in [escape, toggle] {
            XCTAssertLessThanOrEqual(
                element.frame.maxY,
                keyboardTop + 1,
                "\(element.label) must remain fully above the software keyboard"
            )
            XCTAssertTrue(
                element.isHittable,
                "\(element.label) must remain tappable above the software keyboard"
            )
        }
    }
}

/// The collapsed iPhone bar is intentionally translated instead of inserted
/// into layout: its controls must clear the Home-indicator gesture region
/// without changing SwiftTerm's viewport rows.
final class IPhoneCollapsedAccessorySafeAreaHarnessTests: XCTestCase {
    func testCollapsedAccessoryBarClearsSystemGestureRegionInPortrait() throws {
        try assertCollapsedAccessoryBarClearsSystemGestureRegion(
            orientation: .portrait
        )
    }

    func testCollapsedAccessoryBarClearsSystemGestureRegionInLandscape() throws {
        try assertCollapsedAccessoryBarClearsSystemGestureRegion(
            orientation: .landscapeLeft
        )
    }

    private func assertCollapsedAccessoryBarClearsSystemGestureRegion(
        orientation: UIDeviceOrientation
    ) throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("collapsed accessory safe-area acceptance requires an iPhone simulator")
        }

        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_IPHONE_KEYBOARD_HARNESS"] = "1"
        app.launch()
        defer { app.terminate() }

        let state = app.descendants(matching: .any)["iphone-keyboard-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        let hide = app.buttons["Hide keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 8))
        hide.tap()

        let hidden = NSPredicate(format: "value == %@", "hidden")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: hidden, object: state)],
                timeout: 8
            ),
            .completed
        )

        let show = app.buttons["Show keyboard"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        XCTAssertTrue(show.isHittable)
        let clearance = app.frame.maxY - show.frame.maxY
        XCTAssertGreaterThanOrEqual(
            clearance,
            20,
            "collapsed accessory controls must clear the Home-indicator safe area"
        )
    }
}

final class IPhoneCompanionHarnessTests: XCTestCase {
    func testIntegrationRepairIsPresentedByExactSessionChrome() throws {
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .phone
            ? .portrait
            : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_IPHONE_SESSION_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_IPHONE_SESSION_HARNESS_MODE"] =
            UIDevice.current.userInterfaceIdiom == .phone ? "integration" : "integration-popover"
        // Idle waits must not stretch into the presentation delay.
        app.launchEnvironment["TESSERA_STATIC_RINGS"] = "1"
        // The chrome starts its delay no earlier than this, so the warning can
        // appear no earlier than `launched` + the delay. Absence is asserted
        // only while that is still provably true.
        let delay = 5.0 // Core: AgentIntegrationCheckPolicy.warningPresentationDelayMilliseconds
        let launched = Date()
        app.launch()
        defer { app.terminate() }
        func withinDelay() -> Bool { Date().timeIntervalSince(launched) < delay - 1 }

        if UIDevice.current.userInterfaceIdiom == .phone {
            // The phone bar has no warning control: the status dot carries it,
            // and only after the warning has held for the presentation delay.
            let switcher = app.buttons["compact-session-switcher"]
            XCTAssertTrue(switcher.waitForExistence(timeout: 10))
            let early = XCUIScreen.main.screenshot()
            let earlyLabel = switcher.label
            if withinDelay() {
                XCTAssertFalse(earlyLabel.contains("Agent integration inactive here"),
                               "the warning must wait out the presentation delay")
                if let early = Self.attentionRingPixels(around: switcher.frame, in: early) {
                    XCTAssertLessThan(early, 20, "no ring before the delay")
                }
            }
            expectation(
                for: NSPredicate(format: "label CONTAINS %@", "Agent integration inactive here"),
                evaluatedWith: switcher
            )
            waitForExpectations(timeout: 15)
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(launched), delay)
            XCTAssertFalse(app.buttons["agent-integration-warning"].exists)
            // The dot keeps its connection colour and gains an amber ring.
            let ring = try XCTUnwrap(
                Self.attentionRingPixels(around: switcher.frame, in: XCUIScreen.main.screenshot()),
                "the connected (green) status dot must still be visible"
            )
            XCTAssertGreaterThan(ring, 100, "the status dot must carry the warning ring")
            switcher.tap()
        } else {
            if withinDelay() {
                XCTAssertFalse(app.buttons["agent-integration-warning"].exists,
                               "the warning must wait out the presentation delay")
            }
            XCTAssertTrue(app.buttons["agent-integration-warning"].waitForExistence(timeout: 15))
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(launched), delay)
        }
        XCTAssertTrue(app.staticTexts["Agent integration inactive here"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Enable in this shell"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["agent-center-v2-integration-status"].exists)
    }

    /// Amber pixels in the ring's annulus around the green status dot at the
    /// leading edge of `frame`, or nil when no green dot is visible there.
    private static func attentionRingPixels(around frame: CGRect, in screenshot: XCUIScreenshot) -> Int? {
        let image = screenshot.image
        guard let cgImage = image.cgImage, image.size.width > 0 else { return nil }
        let scale = CGFloat(cgImage.width) / image.size.width
        let region = CGRect(x: (frame.minX - 8) * scale, y: frame.minY * scale,
                            width: 48 * scale, height: frame.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard !region.isEmpty, let crop = cgImage.cropping(to: region) else { return nil }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        var greenX = 0, greenY = 0, green = 0
        for y in 0..<height { for x in 0..<width {
            let (r, g, b) = rgb(x, y)
            if g > 150, r < 130, b < 150 { greenX += x; greenY += y; green += 1 }
        } }
        guard green > 20 else { return nil }
        let centerX = Double(greenX) / Double(green), centerY = Double(greenY) / Double(green)
        // The dot is 7pt across and the steady ring 13pt; count between them.
        let inner = 4.5 * Double(scale), outer = 8 * Double(scale)
        var amber = 0
        for y in 0..<height { for x in 0..<width {
            let distance = ((Double(x) - centerX) * (Double(x) - centerX) + (Double(y) - centerY) * (Double(y) - centerY)).squareRoot()
            guard distance >= inner, distance <= outer else { continue }
            let (r, g, b) = rgb(x, y)
            if r > 150, g > 80, b < 90, r - b > 100 { amber += 1 }
        } }
        return amber
    }

    func testContinuityPopoverKeepsTerminalBarVisibleAndRunsBothActions() throws {
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .phone
            ? .portrait
            : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_IPHONE_SESSION_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_IPHONE_SESSION_HARNESS_MODE"] = "continuity"
        app.launch()
        defer { app.terminate() }

        let continuity = app.buttons["session-continuity-menu"]
        let trailingControl = UIDevice.current.userInterfaceIdiom == .phone
            ? app.buttons["session-disconnect"]
            : app.buttons["session-home"]
        XCTAssertTrue(continuity.waitForExistence(timeout: 10))
        XCTAssertTrue(trailingControl.waitForExistence(timeout: 10))
        XCTAssertTrue(continuity.isHittable)
        XCTAssertTrue(trailingControl.isHittable)
        XCTAssertFalse(
            continuity.frame.intersects(trailingControl.frame),
            "continuity and the trailing session control need distinct hit targets"
        )
        let continuityFrame = continuity.frame
        let trailingFrame = trailingControl.frame

        continuity.tap()
        let continueAction = app.buttons["session-continuity-continue"]
        let setUpAction = app.buttons["session-continuity-setup"]
        XCTAssertTrue(continueAction.waitForExistence(timeout: 5))
        XCTAssertTrue(setUpAction.exists)
        XCTAssertTrue(continuity.exists, "the popover must retain its bar anchor")
        XCTAssertTrue(trailingControl.exists, "opening continuity must not hide the terminal bar")
        XCTAssertEqual(continuity.frame, continuityFrame)
        XCTAssertEqual(trailingControl.frame, trailingFrame)

        let result = app.staticTexts["continuity-action-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        continueAction.tap()
        expectation(
            for: NSPredicate(format: "value == %@", "continue"),
            evaluatedWith: result
        )
        waitForExpectations(timeout: 5)

        continuity.tap()
        XCTAssertTrue(setUpAction.waitForExistence(timeout: 5))
        setUpAction.tap()
        expectation(
            for: NSPredicate(format: "value == %@", "set-up"),
            evaluatedWith: result
        )
        waitForExpectations(timeout: 5)
    }

    func testTmuxWindowLongPressOffersSwitchRenameAndCloseActions() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_IPHONE_SESSION_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_IPHONE_SESSION_HARNESS_MODE"] = "palette"
        app.launch()
        defer { app.terminate() }

        let window = app.descendants(matching: .any)["tmux-window-@1"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.press(forDuration: 1)

        XCTAssertTrue(app.buttons["Switch to"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close window"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Close pane"].exists)

        app.buttons["Rename"].tap()
        XCTAssertTrue(app.alerts["Rename tmux window"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Window name"].exists)
        app.buttons["Cancel"].tap()
    }

    func testTmuxPaneLongPressOffersSwitchSplitAndCloseActions() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_IPHONE_SESSION_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_IPHONE_SESSION_HARNESS_MODE"] = "palette"
        app.launch()
        defer { app.terminate() }

        let pane = app.descendants(matching: .any)["tmux-pane-%20"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.press(forDuration: 1)

        XCTAssertTrue(app.buttons["Switch to"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Split left / right"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Split top / bottom"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close pane"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Close window"].exists)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(app.buttons["Close pane"].exists)
        XCTAssertFalse(app.buttons["Close window"].exists)
    }
}

final class TmuxWindowListHarnessTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("the tab strip and its overflow list are iPad-only")
        }
    }

    private func launchWindowListHarness() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_TMUX_WINDOW_LIST_HARNESS"] = "1"
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["tmux-window-list-harness"]
                .waitForExistence(timeout: 8)
        )
        return app
    }

    private func openWindowList(in app: XCUIApplication) {
        let chevron = app.buttons["tmux-tab-overflow"]
        XCTAssertTrue(
            chevron.waitForExistence(timeout: 5),
            "a 16-window strip must overflow and show the chevron"
        )
        chevron.tap()
        XCTAssertTrue(
            app.buttons["tmux-window-list-15-row"].waitForExistence(timeout: 5),
            "the popover should open with the active window's row on screen"
        )
    }

    func testMultiPaneCloseFromListConfirmsAfterPopoverDismiss() throws {
        // Pin for the popover→alert hop: the confirmation is staged until
        // the popover's dismiss completes (content onDisappear); if UIKit
        // drops the presentation mid-transition, this alert never appears
        // and the X is silently dead for split windows.
        let app = launchWindowListHarness()
        defer { app.terminate() }
        openWindowList(in: app)

        app.buttons["tmux-window-list-14-close"].tap()
        XCTAssertTrue(
            app.buttons["Close all 2 panes"].waitForExistence(timeout: 5),
            "the confirmation must survive the popover dismiss transition"
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "contains 2 panes")
            ).firstMatch.exists,
            "confirmation should disclose the pane count"
        )
        app.buttons["Cancel"].firstMatch.tap()

        openWindowList(in: app)
        XCTAssertTrue(
            app.buttons["tmux-window-list-14-close"].waitForExistence(timeout: 3),
            "cancelling must preserve the split window"
        )
    }

    func testLayoutPendingWindowConfirmsAndHydratedSinglePaneDoesNot() throws {
        // @16's %window-add details query is never answered by the harness:
        // its pane count is still a guess (link-window/move-window can add
        // an already-split window), so closing it must fail closed with a
        // confirmation during the gap.
        let app = launchWindowListHarness()
        defer { app.terminate() }
        openWindowList(in: app)

        app.buttons["tmux-window-list-16-close"].tap()
        XCTAssertTrue(
            app.buttons["Close window"].waitForExistence(timeout: 5),
            "closing a layout-pending window must ask first"
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "still syncing")
            ).firstMatch.exists,
            "the pending confirmation should explain the layout is syncing"
        )
        app.buttons["Cancel"].firstMatch.tap()

        // A hydrated single-pane window still closes immediately from the
        // open list — no alert, its row disappears in place.
        openWindowList(in: app)
        app.buttons["tmux-window-list-13-close"].tap()
        XCTAssertTrue(
            app.buttons["tmux-window-list-13-close"].waitForNonExistence(timeout: 3),
            "hydrated single-pane close from the list must be immediate"
        )
        XCTAssertFalse(app.buttons["Cancel"].exists)
    }
}

final class AccessoryEditorHarnessTests: XCTestCase {
    func testPreviewTapStillRemovesChip() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_ACCESSORY_EDITOR_HARNESS"] = "1"
        app.launch()
        defer { app.terminate() }

        let preview = app.scrollViews["accessory-bar-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        let escape = preview.descendants(matching: .any)["Escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 5))

        escape.tap()
        XCTAssertFalse(escape.waitForExistence(timeout: 2))
    }

    func testPreviewScrollsHorizontallyOverReorderGestures() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_ACCESSORY_EDITOR_HARNESS"] = "1"
        app.launch()
        defer { app.terminate() }

        let preview = app.scrollViews["accessory-bar-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        // Chips surface under their display name, not their raw value — the
        // sibling tests above match "Escape" and "Left arrow" the same way
        // (AccessoryChip.displayName, Keyboard/AccessoryChip.swift:171).
        // Matching "tilde" found nothing, so this case had been red since it
        // was written.
        let trailingChip = preview.descendants(matching: .any)["Tilde"]
        XCTAssertTrue(trailingChip.waitForExistence(timeout: 5))

        // The behaviour under test only exists when the chip row overflows its
        // container. On a regular-width iPad all ten seeded chips fit, so there
        // is nothing to scroll and the swipe is a no-op — that is a property of
        // the device, not a defect, so skip rather than fail. Verified: passes
        // on iPhone 17 Pro, fits without overflow on iPad Pro 11-inch.
        try XCTSkipUnless(
            trailingChip.frame.maxX > preview.frame.maxX,
            "chip row fits without overflow on this device; horizontal scrolling is not exercised"
        )

        let initialX = trailingChip.frame.minX
        preview.swipeLeft()

        let movedLeft = NSPredicate(
            block: { _, _ in
                preview.descendants(matching: .any)["Tilde"].frame.minX < initialX - 20
            }
        )
        let expectation = XCTNSPredicateExpectation(
            predicate: movedLeft,
            object: trailingChip
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "a quick horizontal swipe should scroll the Preview instead of being captured by chip reorder gestures"
        )
    }

    func testPreviewStillLongPressReorders() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_ACCESSORY_EDITOR_HARNESS"] = "1"
        app.launch()
        defer { app.terminate() }

        let preview = app.scrollViews["accessory-bar-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        let escape = preview.descendants(matching: .any)["Escape"]
        let leftArrow = preview.descendants(matching: .any)["Left arrow"]
        XCTAssertTrue(escape.waitForExistence(timeout: 5))
        XCTAssertTrue(leftArrow.waitForExistence(timeout: 5))

        let initialX = escape.frame.minX
        escape.press(forDuration: 0.4, thenDragTo: leftArrow)

        let movedRight = NSPredicate(
            block: { _, _ in
                preview.descendants(matching: .any)["Escape"].frame.minX > initialX + 20
            }
        )
        let expectation = XCTNSPredicateExpectation(
            predicate: movedRight,
            object: escape
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "holding before dragging should still reorder Preview chips"
        )
    }
}

/// Host-free regression for the takeover veil. The tmux chip and the veil
/// read the controller's one presentation (S3′), so they react to the same
/// peer authority update, and a tap reaches the shared reducer.
final class GridAuthorityEventHarnessTests: XCTestCase {
    func testPeerAuthorityShowsFullTakeoverOverlayInLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_GRID_AUTHORITY_HARNESS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["grid-authority.direct-chip"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["grid-authority.portable-overlay"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["take back control"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "grid-authority-takeover-landscape"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTakeBackFromTheVeilPresentsProgress() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_GRID_AUTHORITY_HARNESS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["grid-authority.direct-chip"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["grid-authority.portable-overlay"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["take back control"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "grid-authority-take-back-landscape"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["take back control"].tap()
        XCTAssertTrue(
            app.staticTexts["taking back control…"].waitForExistence(timeout: 2),
            "a tap on the veil starts the claim through the command facade"
        )
        XCTAssertFalse(app.buttons["take back control"].exists)
    }
}

/// Host-free check of the production shell's show-edge app facts. A cold
/// launch posts no willEnterForeground and reads `applicationState` as
/// background while ContentView is built: fed only by those, the coordinator
/// stayed in the background, so a restored session was never shown (and never
/// took control) until the app had been backgrounded once.
final class SessionShowEdgeLaunchTests: XCTestCase {
    func testColdLaunchAndReturnCountAsForeground() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_SHOW_EDGE_PROBE"] = "1"
        app.launch()

        let probe = app.descendants(matching: .any)["show-edges.app-facts"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "the production shell publishes its app facts")
        // The lock is its own fact; only the foreground fact and its
        // transitions are graded here.
        XCTAssertTrue(
            wait(for: probe, labelContains: ["foreground=true", "foregroundChanges=1"]),
            "a cold launch is a foreground, with no background round trip: \(probe.label)"
        )

        XCUIDevice.shared.press(.home)
        let left = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state != %d", XCUIApplication.State.runningForeground.rawValue),
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 10), .completed, "home backgrounds the app")
        app.activate()
        XCTAssertTrue(
            wait(for: probe, labelContains: ["foreground=true", "foregroundChanges=3"]),
            "the background and the return each reach the coordinator once: \(probe.label)"
        )
    }

    private func wait(for element: XCUIElement, labelContains texts: [String]) -> Bool {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: texts.map {
            NSPredicate(format: "label CONTAINS %@", $0)
        })
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}

/// Host-free coverage for the simulator-only Handoff descriptor injector.
///
/// A never-seen descriptor must stop at local credential setup. These tests
/// intentionally never tap Connect: initiating a fixture/user-host connection
/// through UI automation would violate the integration contract. The tmux and
/// plain-shell forms are the UI-observable continuation distinction available
/// without seeding a credentialed SwiftData host inside production code.
final class ContinuityHarnessTests: XCTestCase {
    func testQROfferKeepsGuidanceAndCancelReachable() {
        assertQROffer(orientation: .landscapeLeft)
    }

    func testQROfferCompactPortrait() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        assertQROffer(orientation: .portrait)
    }

    private func assertQROffer(orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_QR_REVIEW"] = "send"
        app.launch()
        XCTAssertTrue(app.staticTexts["Scan with your other device"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["cancel"].isHittable)
        XCTAssertTrue(app.staticTexts["Next, compare a six-digit code on both screens."].exists)
        // app.screenshot() crops a portrait-sized region out of landscape on
        // iPhone in this Xcode runtime. Capture the actual display instead.
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "QR offer native layout"
        capture.lifetime = .keepAlways
        add(capture)
        let code = app.images["Pairing QR code"]
        XCTAssertTrue(code.waitForExistence(timeout: 8))
        app.swipeUp()
        let scrolled = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        scrolled.name = "QR offer scrolled code and next step"
        scrolled.lifetime = .keepAlways
        add(scrolled)
        app.swipeDown()
        XCTAssertTrue(app.buttons["cancel"].isHittable)
        app.buttons["cancel"].tap()
    }

    func testQRManualEntryRemainsUsableWithSoftwareKeyboard() {
        assertQRManualEntry(orientation: .landscapeLeft)
    }

    func testQRManualEntryCompactPortrait() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        assertQRManualEntry(orientation: .portrait)
    }

    private func assertQRManualEntry(orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_QR_REVIEW"] = "receive"
        app.launch()
        // Resolve the first-use permission sheet before finding/tapping the
        // disclosure. XCTest's default interruption handler otherwise replays
        // the tap after unavailable-camera handling has already expanded it,
        // accidentally collapsing the fallback again.
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .alerts["“Tessera” would like to access the Camera."]
        if permission.waitForExistence(timeout: 3) {
            permission.buttons["Allow"].tap()
        }
        let entry = app.descendants(matching: .any)["pairing.manual-text"]
        XCTAssertTrue(app.buttons["Enter a pairing code instead"].waitForExistence(timeout: 10))
        if !entry.waitForExistence(timeout: 2) { app.buttons["Enter a pairing code instead"].tap() }
        XCTAssertTrue(app.buttons["use code"].waitForExistence(timeout: 5))
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        entry.typeText("not-a-valid-pairing-code")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "exercise the actual software keyboard")
        XCTAssertTrue(app.buttons["use code"].isHittable)
        app.buttons["use code"].tap()
        XCTAssertTrue(app.staticTexts["This code is invalid or expired. Ask the other device to show a new pairing code."].waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "QR invalid manual entry with keyboard"
        capture.lifetime = .keepAlways
        add(capture)
        // Invalid input must remain on the inert scanner, never open a socket.
        XCTAssertTrue(app.staticTexts["scan pairing code"].exists)
    }

    func testSSHContinueDescriptorUsesNamedTmuxAndCredentialGate() throws {
        try assertCredentialRoute(
            // Include a non-base64 separator so the DEBUG hook selects its
            // mnemonic path rather than interpreting the token as payload.
            harnessValue: "ssh-tmux",
            transportDescription: "single SSH connection; tmux tabs stay on the main session.",
            expectsTmux: true
        )
    }

    func testMoshContinueDescriptorUsesNamedTmuxAndCredentialGate() throws {
        try assertCredentialRoute(
            harnessValue: "mosh-tmux",
            transportDescription: "mosh terminal over UDP; tmux tabs use a second SSH side channel.",
            expectsTmux: true
        )
    }

    func testSSHReconnectDescriptorUsesPlainShellAndCredentialGate() throws {
        try assertCredentialRoute(
            harnessValue: "plain-ssh",
            transportDescription: "single SSH connection; tmux tabs stay on the main session.",
            expectsTmux: false
        )
    }

    func testMoshReconnectDescriptorUsesPlainShellAndCredentialGate() throws {
        try assertCredentialRoute(
            harnessValue: "plain-mosh",
            transportDescription: "mosh terminal over UDP; tmux tabs use a second SSH side channel.",
            expectsTmux: false
        )
    }

    func testMatchedSSHContinueShowsContinueLabelAndExactResolution() throws {
        try assertMatchedRoute(
            harnessValue: "match-exact-ssh-tmux",
            actionLabel: "could not continue",
            address: "exact-ssh-tmux.continuity.invalid",
            resolution: "exact saved-host match"
        )
    }

    func testMatchedMoshContinueShowsContinueLabelAndEndpointResolution() throws {
        try assertMatchedRoute(
            harnessValue: "match-endpoint-mosh-tmux",
            actionLabel: "could not continue",
            address: "endpoint-mosh-tmux.continuity.invalid",
            resolution: "endpoint saved-host match"
        )
    }

    func testMatchedSSHReconnectShowsReconnectLabelAndExactResolution() throws {
        try assertMatchedRoute(
            harnessValue: "match-exact-plain-ssh",
            actionLabel: "could not reconnect",
            address: "exact-plain-ssh.continuity.invalid",
            resolution: "exact saved-host match"
        )
    }

    func testMatchedMoshReconnectShowsReconnectLabelAndEndpointResolution() throws {
        try assertMatchedRoute(
            harnessValue: "match-endpoint-plain-mosh",
            actionLabel: "could not reconnect",
            address: "endpoint-plain-mosh.continuity.invalid",
            resolution: "endpoint saved-host match"
        )
    }

    func testLockedContinuationRemainsHiddenUntilReplay() throws {
        try requireHarnessEnvironment()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_CONTINUITY_HARNESS"] = "locked-ssh-tmux"
        app.launch()
        defer { app.terminate() }

        let source = app.staticTexts["from your other device"]
        XCTAssertFalse(
            source.exists,
            "a descriptor received behind the lock boundary became visible before replay"
        )
        XCTAssertTrue(
            source.waitForExistence(timeout: 10),
            "the stashed descriptor was not replayed after the harness unlock boundary"
        )
        let cancel = app.buttons["cancel"].firstMatch
        XCTAssertTrue(cancel.exists)
        cancel.tap()
    }

    func testInformedTOFUMatchPromotesTrustedAction() throws {
        try assertInformedTOFU(
            mode: "match",
            message: "Matches the key iPad trusts.",
            primaryAction: "Trust & Connect",
            safeTerminalAction: "Cancel"
        )
    }

    func testInformedTOFUMismatchPromotesSafeAction() throws {
        try assertInformedTOFU(
            mode: "mismatch",
            message: "Differs from the key iPad trusts. Verify out of band before connecting.",
            primaryAction: "Don't Connect",
            safeTerminalAction: "Don't Connect",
            secondaryAction: "Trust Anyway"
        )
    }

    private func assertCredentialRoute(
        harnessValue: String,
        transportDescription: String,
        expectsTmux: Bool
    ) throws {
        guard ProcessInfo.processInfo.environment["TESSERA_CONTINUITY_CAPTURE"] == "1" else {
            throw XCTSkip(
                "continuity descriptor injection is driven by scripts/integration/run-integration-tests.sh"
            )
        }

        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_CONTINUITY_HARNESS"] = harnessValue
        app.launch()
        defer {
            // Keep the next case independent even when an assertion above
            // fails before the normal Cancel path.
            let bootstrapClose = app.buttons["close"].firstMatch
            if bootstrapClose.exists && bootstrapClose.isHittable {
                bootstrapClose.tap()
            }
            let editorCancel = app.buttons["cancel"].firstMatch
            if editorCancel.exists && editorCancel.isHittable {
                editorCancel.tap()
            }
            app.terminate()
        }

        let title = app.staticTexts["add host & connect"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 10),
            "the injected descriptor did not reach the continuation credential editor"
        )
        XCTAssertTrue(app.staticTexts["from your other device"].exists)
        XCTAssertTrue(app.staticTexts["authenticate to continuity harness"].exists)
        XCTAssertTrue(app.secureTextFields["password"].exists)
        XCTAssertTrue(app.staticTexts[transportDescription].exists)

        let primaryLabel = UIDevice.current.userInterfaceIdiom == .phone
            ? "add & connect"
            : "connect"
        let connect = app.buttons[primaryLabel]
        XCTAssertTrue(
            connect.exists,
            "the continuation editor did not expose its \(primaryLabel) action"
        )
        XCTAssertFalse(
            connect.isEnabled,
            "a secret-free descriptor must not bypass this device's credential gate"
        )

        if UIDevice.current.userInterfaceIdiom == .phone {
            if expectsTmux {
                XCTAssertTrue(app.staticTexts["continue tmux session"].exists)
                XCTAssertTrue(
                    app.staticTexts["continuity-harness"].exists,
                    "the compact Continue summary lost the exact tmux rendezvous"
                )
            } else {
                XCTAssertTrue(app.staticTexts["reconnect with a new shell"].exists)
                XCTAssertFalse(app.staticTexts["continuity-harness"].exists)
            }
        } else if expectsTmux {
            XCTAssertTrue(
                app.staticTexts["tmux session name"].exists,
                "a Continue descriptor must preserve its exact named-tmux route"
            )
            let tmuxName = app.textFields.matching(
                NSPredicate(format: "value == %@", "continuity-harness")
            ).firstMatch
            XCTAssertTrue(tmuxName.exists)
            XCTAssertEqual(tmuxName.value as? String, "continuity-harness")
            XCTAssertFalse(app.staticTexts["launch command"].exists)
        } else {
            XCTAssertTrue(
                app.staticTexts["launch command"].exists,
                "a Reconnect descriptor must remain an honest plain-shell route"
            )
            XCTAssertFalse(app.staticTexts["tmux session name"].exists)
        }

        // Cancel deletes the temporary SwiftData prefill so each of the four
        // transport/mode cases starts from the same never-seen-host boundary.
        let cancel = app.buttons["cancel"].firstMatch
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertFalse(title.waitForExistence(timeout: 3))
    }

    private func assertMatchedRoute(
        harnessValue: String,
        actionLabel: String,
        address: String,
        resolution: String
    ) throws {
        try requireHarnessEnvironment()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_CONTINUITY_HARNESS"] = harnessValue
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts[actionLabel].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["continuity harness · dev@\(address):22"].exists,
            "the overlay did not render the injected descriptor endpoint"
        )
        XCTAssertTrue(
            app.staticTexts[
                "Harness resolved an \(resolution) and stopped before connecting."
            ].exists,
            "the DEBUG resolver oracle reached a different route"
        )
        let close = app.buttons["close"].firstMatch
        XCTAssertTrue(close.exists)
        close.tap()
    }

    private func assertInformedTOFU(
        mode: String,
        message: String,
        primaryAction: String,
        safeTerminalAction: String,
        secondaryAction: String? = nil
    ) throws {
        try requireHarnessEnvironment()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_CONTINUITY_HOSTKEY_HARNESS"] = mode
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[primaryAction].exists)
        if let secondaryAction {
            XCTAssertTrue(app.buttons[secondaryAction].exists)
        }
        let terminal = app.buttons[safeTerminalAction]
        XCTAssertTrue(terminal.exists)
        terminal.tap()
        XCTAssertFalse(app.staticTexts[message].waitForExistence(timeout: 3))
    }

    private func requireHarnessEnvironment() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_CONTINUITY_CAPTURE"] == "1" else {
            throw XCTSkip(
                "continuity descriptor injection is driven by scripts/integration/run-integration-tests.sh"
            )
        }
    }
}

/// Exercises the primary buttons on every browse surface in portrait and
/// landscape, on both device idioms, and reports all dead taps at once
/// instead of stopping at the first.
final class OrientationButtonSweepTests: XCTestCase {
    private var failures: [String] = []
    private var app: XCUIApplication!

    func testIPadPortraitSweep() throws { try runPadSweep(.portrait) }
    func testIPadLandscapeSweep() throws { try runPadSweep(.landscapeLeft) }
    func testIPhonePortraitSweep() throws { try runPhoneSweep(.portrait) }
    func testIPhoneLandscapeSweep() throws { try runPhoneSweep(.landscapeLeft) }

    // MARK: - iPad (regular shell)

    private func runPadSweep(_ orientation: UIDeviceOrientation) throws {
        try requireDevice(idiom: .pad)
        launch(orientation)

        // Sidebar starts expanded; its nav rows route to each browse page.
        expect(any("hide sidebar"), "sidebar collapse chevron at launch")
        tapAndExpect(button("keys"), any("+ generate"), "sidebar keys row -> keys page")
        tapAndExpect(button("known hosts"), any("export"), "sidebar known-hosts row -> page")
        tapAndExpect(button("tunnels"), text("no tunnels yet"), "sidebar tunnels row -> page")
        tapAndExpect(button("settings"), text("appearance"), "sidebar settings row -> page")
        tapAndExpect(any("view all hosts"), text("no hosts yet"), "sidebar view-all -> landing")

        // Collapse / reveal round-trip.
        tapAndExpect(any("hide sidebar"), any("show sidebar"), "collapse sidebar")
        tapAndExpect(any("show sidebar"), any("hide sidebar"), "reveal sidebar")

        // Landing CTAs.
        tapAndExpect(button("new host, ⌘N"), any("cancel"), "header new-host chip -> editor")
        note("sidebar state in editor")
        tapAndExpect(any("cancel"), text("no hosts yet"), "editor cancel -> landing")
        note("sidebar state after editor cancel")
        tapAndExpect(button("add your first host, ⌘N"), any("cancel"), "empty-state CTA -> editor")
        tapAndExpect(any("cancel"), text("no hosts yet"), "editor cancel -> landing (2)")
        tapAndExpect(button("generate a key"), any("+ generate"), "empty-state generate-a-key -> keys page")
        note("sidebar state on keys page")

        // Sidebar + button (re-reveal first if a prior step collapsed it).
        if any("show sidebar").exists {
            tapAndExpect(any("show sidebar"), any("hide sidebar"), "re-reveal before sidebar +")
        }
        tapAndExpect(button("new host"), any("cancel"), "sidebar + button -> editor")
        tapAndExpect(any("cancel"), any("hide sidebar"), "editor cancel returns")

        finish(orientation)
    }

    // MARK: - iPhone (compact shell)

    private func runPhoneSweep(_ orientation: UIDeviceOrientation) throws {
        try requireDevice(idiom: .phone)
        launch(orientation)

        expect(app.tabBars.firstMatch, "compact tab bar at launch")
        tapAndExpect(tab("sessions"), text("no active sessions"), "sessions tab")
        tapAndExpect(tab("keys"), any("+ generate"), "keys tab")
        // keys <-> known hosts selector inside the keys tab.
        tapAndExpect(nonTabButton("known hosts"), any("verified"), "selector -> known hosts")
        tapAndExpect(nonTabButton("keys"), any("+ generate"), "selector -> keys")
        tapAndExpect(tab("settings"), text("appearance"), "settings tab")
        tapAndExpect(tab("hosts"), text("no hosts yet"), "hosts tab")

        // Landing CTAs (phone labels carry no ⌘N chip).
        tapAndExpect(button("add your first host"), any("cancel"), "empty-state CTA -> editor")
        tapAndExpect(any("cancel"), text("no hosts yet"), "editor cancel -> landing")
        tapAndExpect(button("generate a key"), any("+ generate"), "generate-a-key -> keys tab")

        finish(orientation)
    }

    // MARK: - Helpers

    private func requireDevice(idiom: UIUserInterfaceIdiom) throws {
        guard UIDevice.current.userInterfaceIdiom == idiom else {
            let expected = idiom == .pad ? "iPad" : "iPhone"
            throw XCTSkip("sweep requires the \(expected) device idiom")
        }
    }

    private func launch(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        app = XCUIApplication()
        app.launchArguments += [
            "-tessera.nearbyBootstrap.completed.v1", "YES",
            "-tessera.pref.hasSeenWelcome", "YES",
        ]
        app.launch()
    }

    private func finish(_ orientation: UIDeviceOrientation) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "/tmp/tessera-sweep-\(name.hash)-final.png"))
        app.terminate()
        XCTAssertTrue(
            failures.isEmpty,
            "sweep failures (orientation \(orientation.rawValue)):\n" + failures.joined(separator: "\n")
        )
    }

    private func any(_ label: String) -> XCUIElement {
        app.descendants(matching: .any)[label].firstMatch
    }

    private func button(_ label: String) -> XCUIElement {
        app.buttons[label].firstMatch
    }

    private func text(_ label: String) -> XCUIElement {
        app.staticTexts[label].firstMatch
    }

    private func tab(_ label: String) -> XCUIElement {
        app.tabBars.buttons[label].firstMatch
    }

    private func nonTabButton(_ label: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label == %@", label)
        ).allElementsBoundByIndex.first {
            !$0.frame.intersects(app.tabBars.firstMatch.frame)
        } ?? app.buttons[label].firstMatch
    }

    private func expect(
        _ element: XCUIElement, _ step: String, timeout: TimeInterval = 8
    ) {
        if !element.waitForExistence(timeout: timeout) {
            failures.append("MISSING: \(step)")
            snapFailure(step)
        }
    }

    private func tapAndExpect(
        _ control: XCUIElement, _ outcome: XCUIElement, _ step: String
    ) {
        guard control.waitForExistence(timeout: 6) else {
            failures.append("CONTROL ABSENT: \(step)")
            snapFailure(step)
            return
        }
        control.tap()
        if !outcome.waitForExistence(timeout: 6) {
            failures.append("DEAD TAP: \(step)")
            snapFailure(step)
        }
    }

    private func note(_ label: String) {
        let state = any("hide sidebar").exists
            ? "expanded"
            : (any("show sidebar").exists ? "collapsed" : "absent")
        NSLog("SWEEP-NOTE \(label): sidebar \(state)")
    }

    private func snapFailure(_ step: String) {
        let slug = step.replacingOccurrences(
            of: "[^a-zA-Z0-9]+", with: "-", options: .regularExpression
        )
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "/tmp/tessera-sweep-fail-\(slug).png"))
    }
}

/// A plain UIKit-backed input control, with no terminal mounted, distinguishes
/// Simulator keyboard restoration failures from Tessera focus-policy failures.
final class NativeKeyboardEnvironmentProbeTests: XCTestCase {
    enum Result { case restored, initialPresentationUnavailable, reopeningUnavailable }

    func testNativeTextFieldReopensAfterSystemHideWithoutATerminal() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad keyboard control") }
        let result = Self.probeReopen(in: self)
        XCTAssertNotEqual(result, .initialPresentationUnavailable, "Fresh native reference must first show usable input")
        #if targetEnvironment(simulator)
        if result == .reopeningUnavailable { throw XCTSkip("Native UITextField cannot reopen after system Hide in this Simulator; verify on physical iPad") }
        #endif
        XCTAssertEqual(result, .restored, "No TerminalSurfaceBound or keyboard coordinator exists in this native control")
    }

    static func probeReopen(in test: XCTestCase) -> Result {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_HARDWARE_KEY_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_SOFTWARE_KEYBOARD_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_SOFTWARE_KEYBOARD_REFERENCE"] = "1"
        app.launch()
        defer { app.terminate() }
        let field = app.textFields["hardware-key-local-input"]
        field.tap()
        guard app.keyboards.keys["a"].waitForExistence(timeout: 5),
              app.keyboards.keys["a"].isHittable else {
            print("TESSERA_NATIVE_REFERENCE_INITIAL_PRESENTATION_UNAVAILABLE")
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "native-reference-initial-unavailable"
            attachment.lifetime = .keepAlways
            test.add(attachment)
            return .initialPresentationUnavailable
        }
        let hide = app.keyboards.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'hide' OR label CONTAINS[c] 'dismiss'")).firstMatch
        hide.tap()
        app.buttons["hardware-key-focus"].tap()
        field.tap()
        Thread.sleep(forTimeInterval: 2)
        let restored = app.keyboards.keys["a"].firstMatch.isHittable
        print("TESSERA_NATIVE_REFERENCE_REOPEN \(restored)")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "native-reference-reopen"
        attachment.lifetime = .keepAlways
        test.add(attachment)
        return restored ? .restored : .reopeningUnavailable
    }
}

final class SoftwareKeyboardDismissalHarnessTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testSystemKeyboardDismissalSurvivesUpdatesAndForegroundUntilTerminalTap() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The system dismiss key belongs to the iPad keyboard")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        launchHarness(softwareKeyboard: true)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let keyboard = app.keyboards.firstMatch
        let hide = keyboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'hide' OR label CONTAINS[c] 'dismiss'")).firstMatch
        XCTAssertTrue(hide.exists, "System keyboard controls: \(keyboard.debugDescription)")
        hide.tap()
        app.buttons["keyboard-refresh"].tap()
        captureKeyboardMilestone("system-dismissed")
        XCTAssertEqual(app.staticTexts["keyboard-intent"].label, "dismissed")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "System dismissal must survive SwiftUI updates")
        let terminal = app.descendants(matching: .any)["hardware-key-harness"]
        XCUIDevice.shared.press(.home)
        app.activate()
        app.buttons["keyboard-refresh"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Foreground must preserve dismissal")
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["keyboard-intent"].label, "automatic")
        #if targetEnvironment(simulator)
        if !app.keyboards.keys["b"].firstMatch.isHittable {
            captureKeyboardMilestone("native-restore-unavailable")
            app.terminate()
            // Do not call a missing keyboard a passing restoration. Establish
            // native input unavailable with no terminal mounted before marking
            // this final visual/delivery assertion as environment-limited.
            let reference = NativeKeyboardEnvironmentProbeTests.probeReopen(in: self)
            if reference != .restored {
                throw XCTSkip("Dismissal/foreground/tap policy passed; native UITextField control is also unusable (\(reference)). Physical iPad visual check required")
            }
            XCTFail("Terminal keyboard did not reopen although the native reference control did")
            return
        }
        #endif
        assertSoftwareKeyReachesTerminal("b")
        captureKeyboardMilestone("tap-restored")
    }

    func testExplicitDismissalSurvivesOutputVisibilityRotationAndLocalInput() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad transition fixture") }
        XCUIDevice.shared.orientation = .landscapeLeft
        launchHarness(softwareKeyboard: true)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        app.buttons["keyboard-dismiss"].tap()
        for _ in 0..<3 { app.buttons["keyboard-refresh"].tap() }
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(app.staticTexts["keyboard-intent"].label, "dismissed")
        app.buttons["hardware-key-toggle"].tap()
        app.buttons["hardware-key-toggle"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Revealing a terminal preserves user dismissal")
        XCUIDevice.shared.orientation = .landscapeRight
        // Rotation can finish after XCTest reports the new orientation. Capture
        // and settle before resolving the next button: a stale screen-space
        // coordinate can otherwise tap the terminal and legitimately reopen it.
        captureKeyboardMilestone("explicit-dismissed")
        XCTAssertEqual(app.staticTexts["keyboard-intent"].label, "dismissed")
        app.buttons["keyboard-refresh"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Rotation must not restore dismissed input")
        let field = app.textFields["hardware-key-local-input"]
        field.tap()
        field.typeText("local")
        app.buttons["keyboard-refresh"].tap()
        XCTAssertEqual(field.value as? String, "local")
        XCTAssertEqual(app.staticTexts["keyboard-intent"].label, "dismissed")
        captureKeyboardMilestone("local-input")
        app.buttons["hardware-key-focus"].tap()
        app.buttons["keyboard-refresh"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Closing another input preserves terminal dismissal")
        app.buttons["keyboard-show"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["keyboard-intent"].label, "automatic")
        assertSoftwareKeyReachesTerminal()
    }

    func testDismissedMouseReportingTerminalRestoresOnFirstTapWithoutSendingClick() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad transition fixture") }
        XCUIDevice.shared.orientation = .landscapeLeft
        launchHarness(mouseReporting: true, softwareKeyboard: true)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        app.buttons["keyboard-dismiss"].tap()
        app.buttons["keyboard-refresh"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let terminal = app.descendants(matching: .any)["hardware-key-harness"]
        let point = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45))
        point.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "1B 5B 3C")).firstMatch.exists)
        assertSoftwareKeyReachesTerminal()
        captureKeyboardMilestone("mouse-restored")
        point.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "1B 5B 3C")).firstMatch.waitForExistence(timeout: 5))
    }

    private func launchHarness(mouseReporting: Bool = false, softwareKeyboard: Bool = true) {
        app = XCUIApplication()
        app.launchArguments += ["-tessera.pref.cursorBlink", "NO"]
        app.launchEnvironment["TESSERA_HARDWARE_KEY_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_HARDWARE_KEY_MOUSE"] = mouseReporting ? "1" : "0"
        app.launchEnvironment["TESSERA_SOFTWARE_KEYBOARD_HARNESS"] = softwareKeyboard ? "1" : "0"
        app.launch()
    }

    private func captureKeyboardMilestone(_ name: String) {
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("TESSERA_KEYBOARD_CAPTURE \(name)")
        Thread.sleep(forTimeInterval: 3)
    }

    private func assertSoftwareKeyReachesTerminal(_ character: String = "a") {
        let key = app.keyboards.keys[character].firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertTrue(key.isHittable)
        key.tap()
        let hex = String(format: "%02X", character.utf8.first!)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", hex)).firstMatch.waitForExistence(timeout: 5),
                      "Restoration must show a usable software keyboard, not just an accessibility node")
    }
}

/// Hardware-keyboard modifier chords against the real UIKit dispatch order.
/// Only XCUITest can produce a modified UIPress; encoder unit tests cannot pin
/// the dispatch gate that must deliver the chord.
final class HardwareKeyChordHarnessTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testTypingSurvivesVisibilityAndForegroundTransitions() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        launchHarness()
        XCTAssertTrue(app.buttons["hardware-key-toggle"].waitForExistence(timeout: 10))
        app.typeKey("a", modifierFlags: [])
        assertSent("61", "Initial hardware typing")
        for key in ["b", "c", "d"] {
            app.buttons["hardware-key-toggle"].tap()
            app.buttons["hardware-key-toggle"].tap()
            app.typeKey(key, modifierFlags: [])
            assertSent(String(format: "%02X", key.utf8.first!), "Typing after terminal reveal")
        }
        for key in ["e", "h", "i"] {
            XCUIDevice.shared.press(.home)
            app.activate()
            // iPhone Home is portrait. Activation reports runningForeground
            // before the landscape input service has completed its transition;
            // an event injected in that interval is dropped by Simulator even
            // though the responder is restored (a later key works untouched).
            Thread.sleep(forTimeInterval: 3)
            app.typeKey(key, modifierFlags: [])
            assertSent(String(format: "%02X", key.utf8.first!), "Typing after foreground")
        }
        let field = app.textFields["hardware-key-local-input"]
        field.tap()
        app.typeKey("f", modifierFlags: [])
        XCTAssertEqual(field.value as? String, "f")
        XCUIDevice.shared.press(.home)
        app.activate()
        Thread.sleep(forTimeInterval: 3)
        app.typeKey("j", modifierFlags: [])
        XCTAssertEqual(field.value as? String, "fj", "Foreground recovery must not steal local text input")
        app.buttons["hardware-key-focus"].tap()
        app.typeKey("g", modifierFlags: [])
        assertSent("67", "Typing after local text entry")
        captureKeyboardMilestone("foreground")
    }

    func testForegroundRecoveryRespectsLiveInputPermission() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        launchHarness(blockOnWake: true)
        app.typeKey("a", modifierFlags: [])
        assertSent("61", "Initial hardware typing")
        XCUIDevice.shared.press(.home)
        app.activate()
        Thread.sleep(forTimeInterval: 3)
        app.typeKey("z", modifierFlags: [])
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "7A")).firstMatch.exists,
                       "A locked input policy must block activation reclaim")
    }

    func testMouseReportingTapRestoresHardwareTypingAfterFocusLoss() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        launchHarness(mouseReporting: true)
        XCTAssertTrue(app.buttons["hardware-key-release"].waitForExistence(timeout: 10))
        app.typeKey("a", modifierFlags: [])
        assertSent("61", "Initial hardware typing")
        // Model a transient UIKit interaction ending the input session without
        // changing SwiftUI state. The next terminal tap must restore typing.
        app.buttons["hardware-key-release"].tap()
        let terminal = app.descendants(matching: .any)["hardware-key-harness"]
        XCTAssertEqual(terminal.value as? String, "unfocused")
        let point = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.05))
        point.tap()
        app.typeKey("z", modifierFlags: [])
        assertSent("7A", "A mouse-reporting terminal tap must reclaim keyboard focus")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "1B 5B 3C")).firstMatch.exists,
                       "The first tap restores focus without clicking the remote TUI")
        point.tap()
        for suffix in [" 4D   ", " 6D   "] {
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "1B 5B 3C", suffix)).firstMatch.waitForExistence(timeout: 5),
                          "The next tap must deliver both SGR press and release")
        }
        captureKeyboardMilestone("mouse-focus")
    }

    func testBackgroundTerminalCleanupPreservesForegroundHardwareTyping() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        launchHarness()
        XCTAssertTrue(app.buttons["hardware-key-background-cleanup"].waitForExistence(timeout: 10))
        app.typeKey("a", modifierFlags: [])
        assertSent("61", "Initial hardware typing")
        app.buttons["hardware-key-background-cleanup"].tap()
        app.typeKey("q", modifierFlags: [])
        assertSent("71", "Background session cleanup must preserve the foreground terminal's input")

        let field = app.textFields["hardware-key-local-input"]
        field.tap()
        app.typeKey("x", modifierFlags: [])
        XCTAssertEqual(field.value as? String, "x")
        app.buttons["hardware-key-background-cleanup"].tap()
        app.typeKey("y", modifierFlags: [])
        XCTAssertEqual(field.value as? String, "xy", "Background cleanup must preserve local text entry too")
        captureKeyboardMilestone("background-cleanup")
    }

    func testShiftReachesTheWireAsAModifier() throws {
        launchHarness()

        let terminal = app.descendants(matching: .any)["hardware-key-harness"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))

        // A bare arrow is SwiftTerm's own path and must be untouched.
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
        assertSent("1B 5B 41", "a bare ↑ must still ride SwiftTerm's own path")

        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: .shift)
        assertSent("1B 5B 31 3B 32 41", "⇧↑ must encode CSI 1;2 A, not a bare CSI A")

        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: .shift)
        assertSent("1B 5B 31 3B 32 44", "⇧← must encode CSI 1;2 D")

        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [.shift, .control])
        assertSent("1B 5B 31 3B 36 42", "⇧⌃↓ must carry both modifiers (parameter 6)")

        // ⌥← stays meta word-motion: readline binds ESC b, and re-encoding it
        // as CSI 1;3 D would break word jumps in every shell.
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: .option)
        assertSent("1B 62", "⌥← must stay ESC b")
    }

    /// The regression this whole change could plausibly have caused.
    ///
    /// Shift on an ordinary key is not a terminal modifier at all — it is how
    /// the keyboard picks a character, and that character arrives through
    /// `UITextInput`, not through the keyCode switch the fix sits in front of.
    /// A letter or digit matches neither encoding table, so the modified-key
    /// path declines it and the press falls through exactly as before. Typing
    /// is too load-bearing to leave that as an argument.
    func testShiftStillTypesCapitalsAndShiftedPunctuation() throws {
        launchHarness()

        let terminal = app.descendants(matching: .any)["hardware-key-harness"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))

        app.typeKey("a", modifierFlags: [])
        assertSent("61", "a must send lowercase a")

        app.typeKey("a", modifierFlags: .shift)
        assertSent("41", "⇧a must send capital A, not a modified sequence")

        app.typeKey("1", modifierFlags: .shift)
        assertSent("21", "⇧1 must send !")

        app.typeKey("2", modifierFlags: .shift)
        assertSent("40", "⇧2 must send @")

        // ⌃ and ⌥ on a letter are terminal modifiers and keep their own
        // meanings — the fix must not have swallowed those either.
        app.typeKey("c", modifierFlags: .control)
        assertSent("03", "⌃C must still be 0x03")
    }

    private func launchHarness(mouseReporting: Bool = false, blockOnWake: Bool = false) {
        app = XCUIApplication()
        app.launchEnvironment["TESSERA_HARDWARE_KEY_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_HARDWARE_KEY_MOUSE"] = mouseReporting ? "1" : "0"
        app.launchEnvironment["TESSERA_HARDWARE_KEY_BLOCK_ON_WAKE"] = blockOnWake ? "1" : "0"
        app.launch()
    }

    private func captureKeyboardMilestone(_ name: String) {
        // The integration runner captures the real Metal framebuffer, not
        // XCUITest's black terminal attachments, at these settled milestones.
        print("TESSERA_KEYBOARD_CAPTURE \(name)")
        Thread.sleep(forTimeInterval: 3)
    }

    private func assertSent(_ hex: String, _ message: String) {
        let match = app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH %@", hex)
        ).firstMatch
        guard match.waitForExistence(timeout: 5) else {
            // What actually went on the wire is the whole diagnosis: a bare
            // `CSI A` means SwiftTerm claimed the chord at gate 4, nothing at
            // all means it never reached the app.
            let seen = app.staticTexts.allElementsBoundByIndex
                .map(\.label)
                .joined(separator: " | ")
            XCTFail("\(message) — never saw \(hex). Log held: [\(seen)]")
            return
        }
    }
}
