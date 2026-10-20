import XCTest

/// Acceptance rig for opening a forwarded port in the in-app browser.
///
/// Host-free: `TESSERA_TUNNEL_BROWSER_HARNESS` stands three forwarders in the
/// three states the status sheet distinguishes and runs a real HTTP server on
/// loopback 8080, so no session is ever opened and no host is contacted. The
/// page the browser loads is served over a genuine TCP socket, which is what
/// makes this a test of ATS, `WKWebView`, and the chrome rather than of a
/// fixture.
///
/// Drive it with `scripts/uitest/run-tunnel-browser.sh`.
final class TunnelBrowserProbe: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["TESSERA_TUNNEL_BROWSER_HARNESS"] = "1"
    }

    /// The whole affordance, end to end: the tunnel glyph opens the sheet, the
    /// sheet offers the browse action only where the shared policy says a page
    /// can be there, and the action loads that page inside Tessera.
    func testTunnelGlyphOpensTheForwardedPortInTheInAppBrowser() throws {
        app.launch()

        let chip = app.buttons["harness-forwarding-chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "the tunnel glyph never appeared")
        milestone("01-bar")
        chip.tap()

        let sheetTitle = app.staticTexts["active tunnels"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 10), "the tunnel sheet never opened")
        milestone("02-sheet")

        // One browse action, not three: 15432 → 5432 is postgres (the shared
        // policy refuses it) and 9090 is addressable but idle (nothing is
        // listening, so there is nothing to open).
        let browseButtons = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'open in browser'")
        )
        XCTAssertEqual(
            browseButtons.count,
            1,
            "exactly one of the three tunnels should offer a page"
        )

        browseButtons.firstMatch.tap()

        // The page itself, served over the loopback socket. Its heading in the
        // accessibility tree is proof the load completed rather than that the
        // browser merely presented.
        let heading = app.staticTexts["tunnelled dev server"]
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "the forwarded page never loaded")
        milestone("03-page")

        XCTAssertTrue(
            app.staticTexts["http://127.0.0.1:8080/"].exists,
            "the chrome should show the address the shared policy built"
        )

        // Real history: follow the page's own link, then walk back with the
        // chrome's back button.
        app.links["open the second page"].tap()
        let second = app.staticTexts["second page"]
        XCTAssertTrue(second.waitForExistence(timeout: 20), "the second page never loaded")
        milestone("04-second")

        app.buttons["back"].tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "back did not return to the index")
        milestone("05-back")

        app.buttons["done"].tap()
        XCTAssertTrue(
            sheetTitle.waitForExistence(timeout: 10),
            "done should return to the tunnel sheet, not to the terminal"
        )
        milestone("06-dismissed")
    }

    /// The glyph follows whether anything answers behind the tunnel: the
    /// harness's loopback server stands on the far side, and stopping and
    /// starting it is a real listener going away and coming back. The chip's
    /// accessibility value is the glyph's colour as words — green is
    /// "serving", muted is "nothing serving" — and the screenshots carry the
    /// colour itself.
    func testTunnelGlyphTracksWhetherAnythingIsServing() throws {
        app.launch()

        let chip = app.buttons["harness-forwarding-chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "the tunnel glyph never appeared")
        let toggle = app.buttons["harness-toggle-server"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the harness server toggle never appeared")

        // Serving cadence is 15s; allow a margin on either side of it.
        expectValue(chip, "serving", within: 25)
        milestone("11-serving-bar")

        toggle.tap()
        expectValue(chip, "nothing serving", within: 25)
        milestone("12-stopped-bar")

        chip.tap()
        XCTAssertTrue(
            app.staticTexts["listening · nothing serving on remote port 3000"].waitForExistence(timeout: 10),
            "the sheet should say nothing answers behind the dev-server tunnel"
        )
        XCTAssertTrue(
            app.staticTexts["listening · 0 active"].exists,
            "the postgres tunnel is never probed and keeps its plain status"
        )
        milestone("13-stopped-sheet")
        app.buttons["close"].tap()

        toggle.tap()
        expectValue(chip, "serving", within: 15)
        milestone("14-restarted-bar")

        chip.tap()
        XCTAssertTrue(
            app.staticTexts["serving · 0 active"].waitForExistence(timeout: 10),
            "the sheet should say the dev-server tunnel is serving again"
        )
        milestone("15-restarted-sheet")
    }

    private func expectValue(
        _ element: XCUIElement,
        _ value: String,
        within seconds: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if element.value as? String == value { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail(
            "expected '\(value)' within \(Int(seconds))s, still '\(element.value as? String ?? "nil")'",
            file: file,
            line: line
        )
    }

    /// The runner screenshots on these lines: `XCUIScreenshot` is useless for
    /// anything the app draws on a Metal layer, and the runner's `simctl`
    /// capture is the one that sees the real screen.
    private func milestone(_ name: String) {
        print("TESSERA_VISUAL_EVENT \(name) epoch=\(Date().timeIntervalSince1970)")
        // Let the runner's poller catch the frame before the next interaction
        // changes it.
        Thread.sleep(forTimeInterval: 1.6)
    }
}
