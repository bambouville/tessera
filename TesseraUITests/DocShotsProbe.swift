import XCTest

/// Input-only driver for public-docs screenshot capture. Like
/// `VisualCaptureProbe`, verification and capture stay outside XCUITest —
/// the external driver script watches TESSERA_VISUAL_EVENT marks in the
/// xcodebuild log and records with simctl. This probe drives the REAL app
/// (no harness screens) against the disposable integration fixtures.
///
/// Authentication is key-based end to end: the probe generates an Ed25519
/// key through Tessera's own Keys UI and copies its authorized_keys line to
/// the simulator pasteboard, the driver installs that line on both fixtures,
/// and every host then connects with `identity` set. Nothing types a password.
final class DocShotsProbe: XCTestCase {

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_VISUAL_CAPTURE"] == "1" else {
            throw XCTSkip("doc shots are driven by an external capture script")
        }
        continueAfterFailure = false
    }

    private var stableAddress: String {
        ProcessInfo.processInfo.environment["TESSERA_DOCSHOT_STABLE"] ?? ""
    }
    private var chaosAddress: String {
        ProcessInfo.processInfo.environment["TESSERA_DOCSHOT_CHAOS"] ?? ""
    }

    private let keyName = "ipad"

    private func mark(_ name: String) {
        print("TESSERA_VISUAL_EVENT \(name) epoch=\(Date().timeIntervalSince1970)")
    }

    private func holdForExternalCapture() {
        usleep(3_500_000)
    }

    // MARK: - Element helpers

    /// First hittable button matching the label, preferring the widest match.
    /// A collapsed sidebar carries buttons with identical labels at tiny
    /// frames; tapping one of those silently does nothing.
    private func button(
        _ app: XCUIApplication,
        labelContains text: String,
        minWidth: CGFloat = 40,
        timeout: TimeInterval = 10
    ) -> XCUIElement? {
        let query = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", text)
        )
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let candidates = query.allElementsBoundByIndex.filter {
                $0.isHittable && $0.frame.width >= minWidth
            }
            if let best = candidates.max(by: { $0.frame.width < $1.frame.width }) {
                return best
            }
            usleep(300_000)
        } while Date() < deadline
        return nil
    }

    private func tap(
        _ app: XCUIApplication,
        labelContains text: String,
        minWidth: CGFloat = 40,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let element = button(app, labelContains: text, minWidth: minWidth) {
            element.tap()
            return
        }
        // Some custom SwiftUI controls (the host editor's segmented tab bar)
        // report isHittable == false while still accepting taps. Fall back to
        // a plain label match rather than failing.
        let fallback = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", text)
        ).firstMatch
        guard fallback.waitForExistence(timeout: 5) else {
            XCTFail("no button matching \(text)", file: file, line: line)
            return
        }
        fallback.tap()
    }

    /// Exact-label tap. Required where one label is a substring of another
    /// on screen at the same time (the Keys page's "+ generate" opener versus
    /// the modal's "generate" confirm).
    private func tapExact(
        _ app: XCUIApplication,
        _ label: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let query = app.buttons.matching(NSPredicate(format: "label == %@", label))
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let hit = query.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                hit.tap()
                return
            }
            usleep(300_000)
        } while Date() < deadline
        XCTFail("no hittable button labelled exactly \(label)", file: file, line: line)
    }

    /// Tap, wait for keyboard focus, type, then verify the field took the
    /// text — typeText silently drops input when focus has not landed.
    private func fill(
        _ app: XCUIApplication,
        _ field: XCUIElement,
        with text: String,
        submit: Bool = false
    ) {
        XCTAssertTrue(field.waitForExistence(timeout: 8), "missing field for \(text)")
        let before = field.value as? String ?? ""
        for attempt in 0..<3 {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
            usleep(400_000)
            field.typeText(text)
            usleep(400_000)
            let now = field.value as? String ?? ""
            if !now.isEmpty && now != before { break }
            mark("fill-retry-\(attempt)")
        }
        if submit { field.typeText("\n") }
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.count > 0 else { return }
        let hide = app.keyboards.buttons["Hide keyboard"]
        if hide.exists { hide.tap() }
        else if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        usleep(600_000)
    }

    /// The host editor's full-width connect bar. Other "connect" controls
    /// exist elsewhere in the UI and act on the saved host instead.
    private func tapConnectBar(_ app: XCUIApplication) {
        guard let bar = button(app, labelContains: "connect", minWidth: 400) else {
            XCTFail("host editor connect bar not found")
            return
        }
        bar.tap()
    }

    private func acceptUnknownHostIfPrompted(_ app: XCUIApplication) {
        let accept = app.buttons["Accept New Key"].firstMatch
        if accept.waitForExistence(timeout: 5) { accept.tap() }
    }

    /// tmux window TABS only. "tmux-window-<id>-close" also begins with
    /// "tmux-window-", so a BEGINSWITH match includes every tab's ✕ and
    /// tapping one raises the close-window confirmation instead.
    private func tmuxTabs(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                        "tmux-window-", "-tab")
        )
    }

    private func waitForTmuxTab(_ app: XCUIApplication, timeout: TimeInterval = 90) {
        let tabs = tmuxTabs(app)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count >= 1"),
            object: tabs
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "tmux window tab never appeared"
        )
    }

    // MARK: - Key setup

    /// Generate an Ed25519 key through the real Keys UI and copy its
    /// authorized_keys line to the pasteboard for the driver to install.
    private func generateAndPublishKey(_ app: XCUIApplication) {
        app.buttons["sidebar-navigation-keys"].tap()
        usleep(1_200_000)

        tapExact(app, "+ generate")
        let nameField = app.textFields["my new key"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8), "generate modal missing")
        fill(app, nameField, with: keyName)
        dismissKeyboard(app)
        mark("generate-modal")
        // Ed25519 is the default algorithm; confirm the modal.
        tapExact(app, "generate")
        usleep(3_000_000)
        mark("key-generated")

        // Select the new key to reveal its detail panel.
        guard let row = button(app, labelContains: keyName, minWidth: 100) else {
            XCTFail("generated key row missing")
            return
        }
        row.tap()
        usleep(1_500_000)
        mark("keys-page")
        holdForExternalCapture()

        tap(app, labelContains: "copy public key")
        usleep(1_000_000)
        // The driver reads the pasteboard here and installs the line on both
        // fixtures, then this probe proceeds once the wait elapses.
        mark("pubkey-copied")
        usleep(30_000_000)
        mark("pubkey-installed")
    }

    /// Fill the host editor. No password is entered anywhere: `identity`
    /// carries the credential and is persisted, so SwiftData writes that
    /// re-create this view cannot drop it.
    private func fillHostEditor(
        _ app: XCUIApplication,
        name: String,
        address: String,
        transport: String?
    ) {
        fill(app, app.textFields["my-server"], with: name)
        fill(app, app.textFields["192.168.1.10"], with: address)
        let port = app.textFields["22"]
        XCTAssertTrue(port.waitForExistence(timeout: 5))
        port.doubleTap()
        port.typeText("2222")
        fill(app, app.textFields["username"], with: "tessera")
        dismissKeyboard(app)

        // identity picker: menu labelled "None" until a key is chosen.
        guard let picker = button(app, labelContains: "None", minWidth: 200) else {
            XCTFail("identity picker missing")
            return
        }
        picker.tap()
        usleep(800_000)
        let option = app.buttons[keyName].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "key option missing in picker")
        option.tap()
        usleep(1_000_000)

        if let transport {
            tap(app, labelContains: transport, minWidth: 100)
            usleep(600_000)
        }
    }

    private func openNewHostEditor(_ app: XCUIApplication) {
        if let newHost = button(app, labelContains: "new host", minWidth: 60) {
            newHost.tap()
        } else if let cta = button(app, labelContains: "add your first host") {
            cta.tap()
        } else {
            XCTFail("no add-host affordance found")
        }
        usleep(1_500_000)
    }

    // MARK: - Flows

    func testDocShotsSaturnFlow() throws {
        XCTAssertFalse(stableAddress.isEmpty, "TESSERA_DOCSHOT_STABLE is unset")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        usleep(1_500_000)

        generateAndPublishKey(app)

        // Back to hosts ("view all hosts" clears the sidebar selection),
        // then create saturn over SSH with that identity.
        app.buttons["view all hosts"].firstMatch.tap()
        usleep(1_200_000)
        openNewHostEditor(app)
        fillHostEditor(app, name: "saturn", address: stableAddress, transport: nil)
        usleep(800_000)
        mark("host-editor")
        holdForExternalCapture()

        // Forwarding rule first: it auto-starts with the connection, so the
        // tunnels page later shows a live tunnel. Safe to do before connecting
        // because the credential is a persisted identity, not transient state.
        tap(app, labelContains: "forwarding", minWidth: 100)
        tap(app, labelContains: "add forwarding rule")
        let portFields = app.textFields.matching(
            NSPredicate(format: "label == %@ OR placeholderValue == %@", "8080", "8080")
        )
        XCTAssertTrue(portFields.firstMatch.waitForExistence(timeout: 5))
        let localPort = portFields.element(boundBy: 0)
        localPort.tap()
        localPort.typeText("8080\n")
        let remotePort = portFields.element(boundBy: 1)
        remotePort.tap()
        remotePort.typeText("18080\n")
        fill(app, app.textFields["web app"], with: "dev server", submit: true)
        dismissKeyboard(app)
        tap(app, labelContains: "add rule")
        usleep(1_500_000)
        mark("forwarding-rule")
        holdForExternalCapture()

        tap(app, labelContains: "connection", minWidth: 100)
        usleep(800_000)
        tapConnectBar(app)
        acceptUnknownHostIfPrompted(app)
        waitForTmuxTab(app)

        // Driver stages panes and a second window on the fixture now.
        mark("connected")
        usleep(22_000_000)
        mark("tmux-panes")
        holdForExternalCapture()

        // Move to the staged "logs" window so the first window can take a
        // bell while it is hidden.
        let tabs = tmuxTabs(app)
        if tabs.count >= 2 {
            tabs.element(boundBy: tabs.count - 1).tap()
            usleep(1_500_000)
            mark("bell-stage")
            usleep(9_000_000)
            mark("tmux-bell")
            holdForExternalCapture()
        }

        // Files panel.
        let files = app.buttons["chrome-folder"]
        XCTAssertTrue(files.waitForExistence(timeout: 5), "files toggle missing")
        files.tap()
        usleep(4_000_000)
        mark("files-panel")
        holdForExternalCapture()
        files.tap()
        usleep(800_000)

        // Tunnels page. The rule was added before connecting and auto-starts
        // with the session, so it is already running with real counters.
        app.buttons["chrome-house"].tap()
        usleep(1_500_000)
        app.buttons["sidebar-navigation-tunnels"].tap()
        usleep(2_000_000)
        mark("tunnels-stage")
        usleep(7_000_000)
        mark("tunnels-page")
        holdForExternalCapture()
        mark("saturn-flow-done")
    }

    func testDocShotsAtlasAndExtras() throws {
        XCTAssertFalse(chaosAddress.isEmpty, "TESSERA_DOCSHOT_CHAOS is unset")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        usleep(1_500_000)

        // The key from flow A persists in Keychain + SwiftData.
        openNewHostEditor(app)
        fillHostEditor(app, name: "atlas", address: chaosAddress, transport: "mosh")
        usleep(600_000)
        tapConnectBar(app)
        acceptUnknownHostIfPrompted(app)
        waitForTmuxTab(app)
        usleep(3_000_000)

        // Known hosts, with both fixtures pinned and one row expanded.
        app.buttons["chrome-house"].tap()
        usleep(1_200_000)
        app.buttons["sidebar-navigation-known-hosts"].tap()
        let row = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", stableAddress)
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "known-host row missing")
        row.tap()
        usleep(1_500_000)
        mark("known-hosts")
        holdForExternalCapture()

        // Turn the swipe pad on in settings → experimental.
        app.buttons["sidebar-navigation-settings"].tap()
        tap(app, labelContains: "experimental", minWidth: 60)
        let swipeLabel = app.staticTexts["swipe pad"]
        XCTAssertTrue(swipeLabel.waitForExistence(timeout: 8), "swipe pad row missing")
        let rowY = swipeLabel.frame.midY
        let nearest = app.switches.allElementsBoundByIndex.min(by: {
            abs($0.frame.midY - rowY) < abs($1.frame.midY - rowY)
        })
        if let nearest, abs(nearest.frame.midY - rowY) < 24 {
            nearest.tap()
        } else {
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(
                dx: 0.95,
                dy: rowY / window.frame.height
            )).tap()
        }
        usleep(1_000_000)

        // Back into the live atlas session for the radial-menu shot.
        guard let session = button(app, labelContains: "atlas", minWidth: 80) else {
            XCTFail("atlas sidebar row missing")
            return
        }
        session.tap()
        waitForTmuxTab(app, timeout: 40)
        usleep(2_000_000)

        let puck = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Swipe pad")
        ).firstMatch
        XCTAssertTrue(puck.waitForExistence(timeout: 10), "swipe pad puck missing")
        let start = puck.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        mark("swipe-pad")
        start.press(
            forDuration: 0.08,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: -150)),
            withVelocity: .fast,
            thenHoldForDuration: 6.0
        )
        usleep(500_000)
        mark("atlas-extras-done")
    }
}
