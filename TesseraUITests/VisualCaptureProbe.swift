import XCTest

/// Input-only driver for visual evidence capture. Verification deliberately
/// stays outside XCUITest because SwiftTerm's CAMetalLayer is black in
/// XCUIScreenshot; the integration runner records with simctl and submits all
/// visual cases to one aggregate reviewer.
final class VisualCaptureProbe: XCTestCase {
    func testSetLandscapeOnly() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        usleep(500_000)
    }

    func testSetLandscapeWithActiveApp() throws {
        try requireVisualCaptureRun()
        // iPhone SpringBoard does not adopt a landscape orientation on its own.
        // Keep Tessera active while changing the device orientation so the
        // orientation persists for the following external simctl captures.
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_FORCE_TOUR_STEP"] = "0"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        usleep(500_000)
    }

    func testCaptureOnboardingLayoutMatrix() throws {
        try requireVisualCaptureRun()
        let app = XCUIApplication()
        continueAfterFailure = false
        let orientations: [(String, UIDeviceOrientation)] = [
            ("portrait", .portrait),
            ("landscape", .landscapeLeft),
        ]

        for (orientationName, orientation) in orientations {
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "TESSERA_FORCE_TOUR_STEP")
            app.launchEnvironment["TESSERA_FORCE_TOUR_WELCOME"] = "1"
            app.launch()
            XCUIDevice.shared.orientation = orientation

            let welcome = app.staticTexts["welcome to Tessera"]
            XCTAssertTrue(
                welcome.waitForExistence(timeout: 5),
                "missing onboarding welcome in \(orientationName)"
            )
            usleep(600_000)
            mark("onboarding-\(orientationName)-welcome")
            usleep(1_500_000)

            app.terminate()
            app.launchEnvironment.removeValue(forKey: "TESSERA_FORCE_TOUR_WELCOME")
            app.launchEnvironment["TESSERA_FORCE_TOUR_STEP"] = "0"
            app.launch()
            XCUIDevice.shared.orientation = orientation

            for step in 0..<9 {
                let counter = app.staticTexts["STEP \(step + 1) OF 9"]
                XCTAssertTrue(
                    counter.waitForExistence(timeout: 5),
                    "missing onboarding step \(step + 1) in \(orientationName)"
                )
                usleep(600_000)

                mark("onboarding-\(orientationName)-step-\(step + 1)")
                usleep(1_500_000)

                if step < 8 {
                    let next = app.buttons["onboarding-next"]
                    XCTAssertTrue(next.waitForExistence(timeout: 2), "next button is missing")
                    next.tap()
                }
            }
        }
    }

    func testFilesContextMenuLifecycle() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.activate()

        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "README.md")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "README fixture row is missing")

        mark("before-long-press")
        // Give the external simctl recorder an unmistakable stable frame
        // after XCUITest's runner completes its portrait -> landscape change.
        usleep(500_000)
        row.press(forDuration: 1.1)
        mark("menu-presented")
        usleep(1_200_000)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.10)).tap()
        mark("menu-dismissed")
        usleep(1_500_000)
        mark("post-dismiss-settled")
    }

    func testAgentHookHelpDisclosureExpands() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_HOOK_HELP_HARNESS"] = "1"
        app.launch()

        let disclosure = app.buttons["agent-hook-show-more"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 8), "Show more control is missing")
        disclosure.tap()

        let source = app.descendants(matching: .any)["agent-hook-source"]
        XCTAssertTrue(
            source.waitForExistence(timeout: 5),
            "Show more did not reveal the integration source"
        )
        assertAgentHookSourceIsRendered(in: app)
        usleep(2_000_000)
    }

    func testAgentCenterHarnessCoversLifecycleStatesAndIdentity() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_HARNESS"] = "1"
        app.launch()

        let sidebarAgents = app.buttons["agent-sidebar-row"]
        XCTAssertTrue(sidebarAgents.waitForExistence(timeout: 8))
        let badgeSummary = String(describing: sidebarAgents.value ?? "")
        XCTAssertTrue(badgeSummary.contains("1 agent needs input"))
        XCTAssertFalse(
            badgeSummary.contains("agent just finished"),
            "Viewing Agent Center should clear the unread completion badge without changing the card state"
        )
        XCTAssertTrue(badgeSummary.contains("5 agents total"))

        func reveal(_ identifier: String) -> XCUIElement {
            let element = app.descendants(matching: .any)[identifier]
            for _ in 0..<8 where !element.exists || !element.isHittable {
                app.swipeUp()
            }
            return element
        }

        XCTAssertEqual(
            reveal("agent-status-7").label,
            "waiting for input",
            "Codex plan approval is not represented as a blocking state"
        )
        XCTAssertTrue(reveal("agent-provider-session-7").label.contains("codex-7"))
        XCTAssertTrue(reveal("agent-task-7").label.contains("Audit Agent Center reliability"))
        XCTAssertEqual(reveal("agent-status-12").label, "working")
        XCTAssertTrue(reveal("agent-task-12").label.contains("Validate Agent Center"))
        XCTAssertEqual(reveal("agent-status-13").label, "just finished")
        XCTAssertTrue(reveal("agent-task-13").label.contains("Review Agent Center integration"))
        XCTAssertEqual(reveal("agent-status-9").label, "idle at prompt")
        XCTAssertTrue(reveal("agent-task-9").label.contains("Document lifecycle diagnostics"))
        XCTAssertEqual(reveal("agent-status-raw").label, "status unavailable")
    }

    func testAgentAttentionTopBarAndPopoverUseCurrentWindowVisibility() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_ATTENTION_HARNESS"] = "1"
        app.launch()

        let summary = app.buttons["agent-attention-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8), "Agent attention summary is missing")
        XCTAssertTrue(summary.label.contains("1 agent needs input"))
        XCTAssertTrue(summary.label.contains("1 agent finished"))

        let currentFinishedTab = app.buttons["tmux-window-2-tab"]
        XCTAssertTrue(currentFinishedTab.exists)
        XCTAssertFalse(
            currentFinishedTab.label.contains("agent just finished"),
            "The currently visible finished tab must not retain green attention chrome"
        )
        let hiddenFinishedTab = app.buttons["tmux-window-3-tab"]
        XCTAssertTrue(hiddenFinishedTab.exists)
        XCTAssertTrue(
            hiddenFinishedTab.label.contains("agent just finished"),
            "An unread completion on another tab must retain green attention chrome"
        )
        summary.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["agent-attention-popover"]
                .waitForExistence(timeout: 3),
            "Agent attention popover did not open"
        )
        let codexOpenButtons = app.buttons.matching(
            NSPredicate(format: "label == %@", "Open Codex on tmux-lab")
        )
        XCTAssertEqual(codexOpenButtons.count, 2)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "pane %10")
            ).firstMatch.exists
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "pane %30")
            ).firstMatch.exists
        )
        XCTAssertFalse(
            app.buttons["Open Claude Code on tmux-lab"].exists,
            "The currently visible agent should already be acknowledged"
        )

        let waitingOpen = app.buttons["agent-attention-open-10"]
        XCTAssertTrue(waitingOpen.exists)
        waitingOpen.tap()
        let onlyFinished = NSPredicate(
            format: "label CONTAINS %@ AND NOT label CONTAINS %@",
            "1 agent finished",
            "needs input"
        )
        expectation(for: onlyFinished, evaluatedWith: summary)
        waitForExpectations(timeout: 3)

        summary.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["agent-attention-row-30"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.descendants(matching: .any)["agent-attention-row-10"].exists)

        app.buttons["agent-attention-open-30"].tap()
        expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: summary
        )
        waitForExpectations(timeout: 3)
        XCTAssertFalse(
            hiddenFinishedTab.label.contains("agent just finished"),
            "Opening the finished agent must clear its green tab marker"
        )
    }

    func testAgentNotificationDeliversWhileBackgroundAssertionIsActive() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_NOTIFICATION_HARNESS"] = "1"
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
        }

        let arm = app.buttons["agent-notification-arm"]
        XCTAssertTrue(arm.waitForExistence(timeout: 8))
        expectation(
            for: NSPredicate(format: "isEnabled == true"),
            evaluatedWith: arm
        )
        waitForExpectations(timeout: 5)

        arm.tap()
        XCUIDevice.shared.press(.home)
        usleep(4_000_000)
        app.activate()

        let verification = app.staticTexts["agent-notification-verification"]
        XCTAssertTrue(verification.waitForExistence(timeout: 5))
        expectation(
            for: NSPredicate(format: "label CONTAINS %@", "delivered=true"),
            evaluatedWith: verification
        )
        waitForExpectations(timeout: 5)
        XCTAssertTrue(
            verification.label.contains("pending=false"),
            "an immediate notification should be delivered, not left on a timer"
        )
    }

    func testAgentCenterInstallPromptOpensHelpAndSource() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_HARNESS"] = "1"
        app.launch()

        let install = app.buttons["install status hook"]
        XCTAssertTrue(install.waitForExistence(timeout: 8), "Install status hook action is missing")
        for _ in 0..<4 where !install.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(install.isHittable, "Install status hook action is not reachable")
        install.tap()

        let confirmation = app.alerts["Install agent status hook?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3), "Install confirmation is missing")
        let help = confirmation.buttons["Help"]
        XCTAssertTrue(help.exists, "Agent Center install confirmation does not expose Help")
        help.tap()

        let disclosure = app.buttons["agent-hook-show-more"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "Hook help did not open")
        disclosure.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["agent-hook-source"].waitForExistence(timeout: 5),
            "Agent Center help did not disclose the exact install source"
        )
        assertAgentHookSourceIsRendered(in: app)
    }

    func testAgentIntegrationWarningOpensHelpAndSource() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_INTEGRATION_WARNING_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_INTEGRATION_WARNING_AUTO_OPEN"] = "0"
        app.launch()

        let warning = app.buttons["agent-integration-warning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 8), "Integration warning is missing")
        warning.tap()
        let fix = app.buttons["agent-integration-fix"]
        XCTAssertTrue(
            fix.waitForExistence(timeout: 3),
            "State-specific integration action is missing"
        )
        let persistentFix = app.buttons["agent-integration-persist"]
        XCTAssertTrue(
            persistentFix.waitForExistence(timeout: 3),
            "Persistent startup activation action is missing"
        )
        persistentFix.tap()
        let confirmation = app.alerts["Enable integration automatically?"]
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 3),
            "Terminal mutation does not require an explicit confirmation"
        )
        XCTAssertTrue(
            confirmation.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "empty bash/zsh prompt")
            ).firstMatch.exists,
            "Confirmation does not explain the empty-prompt safety boundary"
        )
        XCTAssertTrue(
            confirmation.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "startup file")
            ).firstMatch.exists,
            "Confirmation does not disclose the shell startup-file edit"
        )
        let help = confirmation.buttons["Help"]
        XCTAssertTrue(help.exists, "Mutation confirmation does not expose Help")
        help.tap()

        let disclosure = app.buttons["agent-hook-show-more"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "Hook source help did not open")
        disclosure.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["agent-hook-source"].waitForExistence(timeout: 5),
            "Hook source was not disclosed from the warning prompt"
        )
        assertAgentHookSourceIsRendered(in: app)
    }

    func testAgentIntegrationMissingAgentConfirmationDisclosesOneStepActivation() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_INTEGRATION_WARNING_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_INTEGRATION_WARNING_AUTO_OPEN"] = "0"
        app.launchEnvironment["TESSERA_AGENT_INTEGRATION_WARNING_STATE"] = "missing-agent"
        app.launch()

        let warning = app.buttons["agent-integration-warning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 8), "Missing-install warning is missing")
        warning.tap()
        let fix = app.buttons["agent-integration-fix"]
        XCTAssertTrue(fix.waitForExistence(timeout: 3), "Install action is missing")
        XCTAssertEqual(fix.label, "Install integration")
        fix.tap()

        let confirmation = app.alerts["Install agent integration?"]
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 3),
            "Missing-install mutation does not require one explicit confirmation"
        )
        XCTAssertTrue(
            confirmation.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "reaches an empty bash/zsh prompt")
            ).firstMatch.exists,
            "Confirmation does not disclose conditional same-terminal activation"
        )
        XCTAssertTrue(
            confirmation.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "never types into a running agent")
            ).firstMatch.exists,
            "Confirmation does not disclose the foreground-agent safety boundary"
        )
        XCTAssertTrue(confirmation.buttons["Install"].exists)
    }

    func testCompactAgentIntegrationWarningAppearsInHostSwitcher() throws {
        try requireVisualCaptureRun()
        // Preserve the current device-class orientation. The focused iPhone
        // lane runs in portrait, while the aggregate iPad visual suite is
        // intentionally kept in landscape; the harness forces compact width
        // independently, so rotating mid-suite only destabilizes SpringBoard.
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_INTEGRATION_WARNING_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_INTEGRATION_WARNING_AUTO_OPEN"] = "0"
        app.launchEnvironment["TESSERA_AGENT_INTEGRATION_WARNING_COMPACT"] = "1"
        app.launchEnvironment["TESSERA_AGENT_INTEGRATION_WARNING_STATE"] = "missing-agent"
        app.launch()

        let switcher = app.buttons["compact-session-switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 8), "Compact host switcher is missing")
        XCTAssertTrue(
            switcher.label.contains("Agent integration not installed"),
            "Compact host name does not announce the hook warning"
        )
        switcher.tap()

        let warningRow = app.descendants(matching: .any)[
            "agent-integration-warning-switcher-row"
        ]
        XCTAssertTrue(
            warningRow.waitForExistence(timeout: 5),
            "Hook warning is not the first switcher section"
        )
        let install = app.buttons["agent-integration-warning-switcher-action"]
        XCTAssertTrue(install.exists)
        XCTAssertEqual(install.label, "Install integration")
        install.tap()
        XCTAssertTrue(
            app.alerts["Install agent integration?"].waitForExistence(timeout: 3),
            "Compact switcher action bypassed the existing safety confirmation"
        )
    }

    func testWaitForLiveScrollReady() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.activate()
        let status = app.descendants(matching: .any)["live-scroll-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        let ready = NSPredicate(format: "value == %@", "ready")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: status)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 55),
            .completed,
            "live scroll harness did not become ready; value=\(String(describing: status.value))"
        )
        usleep(1_500_000)
    }

    private func assertAgentHookSourceIsRendered(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sourceText = app.staticTexts["agent-hook-source-text"]
        XCTAssertTrue(
            sourceText.waitForExistence(timeout: 5),
            "The disclosed integration source text did not render",
            file: file,
            line: line
        )
        XCTAssertTrue(
            sourceText.label.contains("agent-lifecycle-hook.sh"),
            "The rendered disclosure does not contain the hook source heading",
            file: file,
            line: line
        )
        let source = app.descendants(matching: .any)["agent-hook-source"]
        let installedVersion = source.value as? String
        XCTAssertNotNil(
            installedVersion,
            "The rendered disclosure does not expose its production protocol version",
            file: file,
            line: line
        )
        XCTAssertTrue(
            installedVersion.map {
                sourceText.label.contains("TESSERA_AGENT_INTEGRATION_VERSION=\($0)")
            } ?? false,
            "The rendered disclosure does not contain the installed protocol version",
            file: file,
            line: line
        )
    }

    func testLivePrimaryScrollRoundTrip() throws {
        try requireVisualCaptureRun()
        let app = readyLiveScrollApp()
        mark("primary-before")
        usleep(1_500_000)
        app.scroll(byDeltaX: 0, deltaY: -900)
        usleep(2_500_000)
        mark("primary-history")
        usleep(1_250_000)
        app.scroll(byDeltaX: 0, deltaY: 1_200)
        usleep(2_000_000)
        mark("primary-restored")
        usleep(1_250_000)
    }

    func testLiveAltScreenScrollRoundTrip() throws {
        try requireVisualCaptureRun()
        let app = readyLiveScrollApp()
        mark("alt-before")
        usleep(750_000)
        app.scroll(byDeltaX: 0, deltaY: -300)
        usleep(1_500_000)
        mark("alt-moved")
        usleep(1_000_000)
        app.scroll(byDeltaX: 0, deltaY: 300)
        usleep(1_500_000)
        mark("alt-restored")
        usleep(1_250_000)
    }

    func testLiveScrollVisualSequence() throws {
        try requireVisualCaptureRun()
        let app = waitForLiveScrollApp()
        XCTAssertGreaterThan(liveTerminal(in: app).frame.height, 200)

        mark("primary-before")
        holdForExternalCapture()
        scrollLiveTerminal(in: app, deltaY: -900)
        usleep(2_500_000)
        mark("primary-moved")
        holdForExternalCapture()
        scrollLiveTerminal(in: app, deltaY: 1_200)
        usleep(2_000_000)
        mark("primary-restored")
        holdForExternalCapture()

        mark("htop-before")
        holdForExternalCapture()
        scrollLiveTerminal(in: app, deltaY: 900)
        usleep(1_500_000)
        mark("htop-moved")
        holdForExternalCapture()
        scrollLiveTerminal(in: app, deltaY: -900)
        usleep(1_500_000)
        mark("htop-restored")
        // Plain mosh's remote htop does not reliably observe the fixture's
        // cross-SSH sentinel while it owns the PTY. Its 30-second watchdog
        // advances to Vim; leave enough paint time before the baseline.
        usleep(12_000_000)

        mark("vim-before")
        holdForExternalCapture()
        // Use the same asymmetric magnitude strategy as the primary-screen
        // round trip. Smaller symmetric wheel bursts can be swallowed by Vim
        // or fail to overcome the preceding synthesized gesture on the
        // simulator, yielding a no-op/continued-direction evidence frame even
        // though the forwarding path is live.
        scrollLiveTerminal(in: app, deltaY: 900)
        usleep(1_500_000)
        mark("vim-moved")
        holdForExternalCapture()
        scrollLiveTerminal(in: app, deltaY: -1_200)
        usleep(1_500_000)
        mark("vim-restored")
        holdForExternalCapture()
    }

    /// Lifecycle driver for the inline tmux foreground-repaint regression.
    /// The external simctl recorder is the oracle because SwiftTerm renders
    /// through CAMetalLayer and XCUIScreenshot sees a black surface.
    func testLiveTmuxForegroundRefresh() throws {
        try requireVisualCaptureRun()
        let app = waitForLiveScrollApp()
        XCTAssertGreaterThan(liveTerminal(in: app).frame.height, 200)

        let status = app.descendants(matching: .any)["live-scroll-status"]
        mark("foreground-before-background")
        usleep(1_500_000)
        XCUIDevice.shared.press(.home)
        let leftForeground = NSPredicate { _, _ in
            app.state != .runningForeground
        }
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: leftForeground, object: app)],
                timeout: 5
            ),
            .completed,
            "Home did not move Tessera out of the foreground"
        )
        XCTAssertNotEqual(
            app.state,
            .notRunning,
            "Tessera terminated instead of entering a background state"
        )
        mark("foreground-backgrounded")
        usleep(1_500_000)

        let activationStarted = Date()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        mark("foreground-activated")
        let live = NSPredicate(format: "value BEGINSWITH %@", "foreground-live")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: live, object: status)],
                timeout: 10
            ),
            .completed,
            "post-activation bytes did not traverse tmux into the rendered terminal"
        )
        let recoveryLatency = Date().timeIntervalSince(activationStarted)
        XCTAssertLessThan(
            recoveryLatency,
            4.0,
            "foreground recovery did not return Tessera and live tmux output promptly"
        )
        // Foreground metadata can remain empty while the control channel
        // recovers. Keep the recording alive through the controller's full
        // retry window so a delayed history replay cannot hide after teardown.
        usleep(20_000_000)
        XCTAssertGreaterThan(liveTerminal(in: app).frame.height, 200)
        guard let probeValue = status.value as? String,
              let feedCountField = probeValue.components(separatedBy: "|")
                .first(where: { $0.hasPrefix("feed-count=") }),
              let feedCount = Int(feedCountField.dropFirst("feed-count=".count)),
              let totalFeedField = probeValue.components(separatedBy: "|")
                .first(where: { $0.hasPrefix("total-feed=") }),
              let totalFeed = Int(totalFeedField.dropFirst("total-feed=".count)),
              let maxFeedText = probeValue.components(separatedBy: "max-feed=").last,
              let maxFeed = Int(maxFeedText)
        else {
            XCTFail("invalid foreground probe status: \(String(describing: status.value))")
            return
        }
        print("TESSERA_FOREGROUND_PROBE \(probeValue)")
        XCTAssertLessThanOrEqual(
            feedCount,
            4,
            "foreground recovery presented queued tmux redraws as separate visible feed steps (max-feed=\(maxFeed))"
        )
        XCTAssertGreaterThanOrEqual(
            totalFeed,
            250_000,
            "foreground regression did not exercise the expected large background redraw burst"
        )
        mark("foreground-settled")
        usleep(1_500_000)
    }

    func testTmuxWindowCloseControls() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_TMUX_WINDOW_CLOSE_HARNESS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["tmux-window-close-harness"]
                .waitForExistence(timeout: 8)
        )
        let singleClose = app.buttons["tmux-window-1-close"]
        let splitClose = app.buttons["tmux-window-2-close"]
        let zoomedSplitClose = app.buttons["tmux-window-3-close"]
        XCTAssertTrue(singleClose.exists, "single-pane tab is missing its X")
        XCTAssertTrue(splitClose.exists, "split tab is missing its X")
        XCTAssertTrue(zoomedSplitClose.exists, "zoomed split tab is missing its X")

        singleClose.tap()
        XCTAssertTrue(
            singleClose.waitForNonExistence(timeout: 3),
            "single-pane X should close immediately without confirmation"
        )
        XCTAssertFalse(app.buttons["Close window"].exists)

        // Regression: a freshly-created window (bare %window-add, layout not
        // hydrated yet) is single-pane and must close without the spurious
        // "pane information still loading" confirmation.
        let freshClose = app.buttons["tmux-window-4-close"]
        XCTAssertTrue(freshClose.exists, "fresh un-hydrated tab is missing its X")
        freshClose.tap()
        XCTAssertTrue(
            freshClose.waitForNonExistence(timeout: 3),
            "fresh single-pane X should close immediately without confirmation"
        )
        XCTAssertFalse(app.buttons["Close window"].exists)
        XCTAssertFalse(app.buttons["Cancel"].exists)

        splitClose.tap()
        var destructive = app.buttons["Close all 2 panes"]
        XCTAssertTrue(
            destructive.waitForExistence(timeout: 3),
            "split-window X did not require confirmation"
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "contains 2 panes")
            ).firstMatch.exists,
            "confirmation does not disclose the split pane count"
        )
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(splitClose.exists, "cancelling must preserve the split window")

        splitClose.tap()
        destructive = app.buttons["Close all 2 panes"]
        XCTAssertTrue(destructive.waitForExistence(timeout: 3))
        destructive.tap()
        XCTAssertTrue(
            splitClose.waitForNonExistence(timeout: 3),
            "confirming must close the targeted split window"
        )

        zoomedSplitClose.tap()
        XCTAssertTrue(
            app.buttons["Close all 2 panes"].waitForExistence(timeout: 3),
            "zoom must not hide the second pane from close confirmation"
        )
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(zoomedSplitClose.exists)
    }

    private func readyLiveScrollApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.activate()
        let status = app.descendants(matching: .any)["live-scroll-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "ready")
        return app
    }

    private func waitForLiveScrollApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.activate()
        let status = app.descendants(matching: .any)["live-scroll-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        let ready = NSPredicate(format: "value == %@", "ready")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: status)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 55),
            .completed,
            "live scroll harness did not become ready; value=\(String(describing: status.value))"
        )
        usleep(8_000_000)
        return app
    }

    private func liveTerminal(in app: XCUIApplication) -> XCUIElement {
        let terminal = app.descendants(matching: .any)["live-scroll-terminal"]
        XCTAssertTrue(
            terminal.waitForExistence(timeout: 5),
            "production terminal is not exposed by the live scroll harness"
        )
        return terminal
    }

    private func scrollLiveTerminal(in app: XCUIApplication, deltaY: CGFloat) {
        // Reacquire for every gesture. The DEBUG harness retags mosh's revealed
        // capture-pane TerminalView when it replaces the shared live surface.
        let terminal = liveTerminal(in: app)
        XCTAssertGreaterThan(terminal.frame.height, 200)
        terminal.scroll(byDeltaX: 0, deltaY: deltaY)
    }

    private func mark(_ name: String) {
        print("TESSERA_VISUAL_EVENT \(name) epoch=\(Date().timeIntervalSince1970)")
    }

    private func holdForExternalCapture() {
        // simctl must take three Metal-backed screenshots and select the most
        // complete frame. Keep XCTest (and therefore the app) alive until the
        // slowest of those captures has finished, including the final marker.
        usleep(3_000_000)
    }

    private func requireVisualCaptureRun() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_VISUAL_CAPTURE"] == "1" else {
            throw XCTSkip("visual probes are driven by scripts/integration/run-integration-tests.sh")
        }
    }
}
