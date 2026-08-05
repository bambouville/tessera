import XCTest
import CoreFoundation

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
        let simulatorName = ProcessInfo.processInfo.environment[
            "SIMULATOR_DEVICE_NAME"
        ] ?? ""
        guard simulatorName.localizedCaseInsensitiveContains("iPhone") else {
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
            where: { $0 > keyboardVisibleRows },
            description: "increase after hiding the keyboard"
        )

        let show = app.buttons["Show keyboard"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        XCTAssertTrue(show.isHittable)
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

final class IPhoneCompanionHarnessTests: XCTestCase {
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

    func testPreviewScrollsHorizontallyOverReorderGestures() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_ACCESSORY_EDITOR_HARNESS"] = "1"
        app.launch()
        defer { app.terminate() }

        let preview = app.scrollViews["accessory-bar-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        let trailingChip = preview.descendants(matching: .any)["tilde"]
        XCTAssertTrue(trailingChip.waitForExistence(timeout: 5))

        let initialX = trailingChip.frame.minX
        preview.swipeLeft()

        let movedLeft = NSPredicate(
            block: { _, _ in
                preview.descendants(matching: .any)["tilde"].frame.minX < initialX - 20
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

/// Host-free coverage for the simulator-only Handoff descriptor injector.
///
/// A never-seen descriptor must stop at local credential setup. These tests
/// intentionally never tap Connect: initiating a fixture/user-host connection
/// through UI automation would violate the integration contract. The tmux and
/// plain-shell forms are the UI-observable continuation distinction available
/// without seeding a credentialed SwiftData host inside production code.
final class ContinuityHarnessTests: XCTestCase {
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
