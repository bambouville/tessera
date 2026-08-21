import XCTest

/// Measures Markdown-preview scrolling on a document the size of the one that
/// scrolled badly in the field. Host-free: the harness writes a synthetic
/// register to a temp file and previews it, so no session is opened.
///
/// The oracle is the app's own `ui-scroll surface=md-preview` line, read back
/// out of the simulator container by `scripts/uitest/run-markdown-scroll.sh` —
/// the same line a user report carries.
final class MarkdownScrollProbe: XCTestCase {

    /// `MD_BLOCKS` overrides the document size, so a run can test whether
    /// the per-block cost is really per block or scales with the document.
    private static var blockCount: Int {
        Int(ProcessInfo.processInfo.environment["MD_BLOCKS"] ?? "") ?? 450
    }

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["TESSERA_MARKDOWN_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_MARKDOWN_HARNESS_BLOCKS"] = "\(Self.blockCount)"
        if let kind = ProcessInfo.processInfo.environment["MD_KIND"], !kind.isEmpty {
            app.launchEnvironment["TESSERA_MARKDOWN_HARNESS_KIND"] = kind
        }
        // The real Settings toggle, so the lines travel the user's path.
        app.launchArguments += ["-Diagnostics.ScrollEnabled", "YES"]
        for (key, value) in Self.seams() {
            app.launchEnvironment[key] = value
        }
    }

    /// Seam overrides arrive as a comma-separated list in the runner's own
    /// environment, e.g. `MD_SEAMS=TESSERA_MARKDOWN_TEXT_SELECTION=0`.
    private static func seams() -> [String: String] {
        guard let raw = ProcessInfo.processInfo.environment["MD_SEAMS"], !raw.isEmpty else {
            return [:]
        }
        return raw.split(separator: ",").reduce(into: [:]) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return }
            result[String(parts[0])] = String(parts[1])
        }
    }

    func testScrollThroughALargeDocument() throws {
        app.launch()

        // The document renders asynchronously; wait for real content. The
        // staged document has its own title, so match on whichever arrives.
        let rendering = app.staticTexts["Rendering Markdown…"]
        _ = rendering.waitForExistence(timeout: 5)
        let anyHeading = app.staticTexts.element(boundBy: 0)
        XCTAssertTrue(anyHeading.waitForExistence(timeout: 40), "harness document never rendered")
        // Give the first layout pass room to settle before measuring.
        usleep(2_000_000)

        // `swipeUp` covers barely a screen and realises ~8 blocks; the
        // reported session realised 41 in 1.7s. Fling the full height at
        // gesture-velocity instead, twice per session, so each summary
        // covers a comparable amount of newly realised content.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10))

        for _ in 0..<6 {
            start.press(forDuration: 0.02, thenDragTo: end,
                        withVelocity: .fast, thenHoldForDuration: 0)
            start.press(forDuration: 0.02, thenDragTo: end,
                        withVelocity: .fast, thenHoldForDuration: 0)
            usleep(1_400_000)
        }
        usleep(2_000_000)
    }
}
