import XCTest

/// Acceptance for the artifacts browser's chrome: the address edits its own
/// tab, a new tab is always new, and the browser's ⌘ chords reach it.
///
/// Host-free: `TESSERA_ARTIFACTS_BROWSER_HARNESS` seeds the tabs over an
/// in-memory reader, and the `laptop` scene's localhost:8001 page is served
/// by a fake handler that answers any path with a page naming that path. No
/// session is opened and no host is contacted.
final class ArtifactsBrowserChromeProbe: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        app = XCUIApplication()
        app.launchEnvironment["TESSERA_ARTIFACTS_BROWSER_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_ARTIFACTS_BROWSER_SCENE"] = "laptop"
    }

    /// Tapping the address puts the whole address in a field, all of it
    /// selected: typing replaces it rather than appending. Return loads the
    /// new path in the same tab.
    func testTheAddressEditsItsOwnTab() throws {
        try launchOnThePage()
        let before = tabCount()
        app.buttons["artifacts-address"].tap()

        let field = addressField()
        XCTAssertTrue(field.waitForExistence(timeout: 10), "tapping the address opened no field")
        XCTAssertEqual(field.value as? String, "localhost:8001/index.html", "the field should hold the tab's whole address")
        // Selected, so the first keystroke replaces it.
        field.typeText("localhost:8001/laptop.html")
        XCTAssertEqual(field.value as? String, "localhost:8001/laptop.html",
                       "typing should replace the selected address, not add to it")
        field.typeText("\n")

        XCTAssertTrue(app.staticTexts["/laptop.html"].waitForExistence(timeout: 20), "the tab never loaded the new path")
        XCTAssertFalse(field.exists, "Return should end editing")
        XCTAssertEqual(tabCount(), before, "editing the address must not open a tab")
        XCTAssertTrue(app.buttons["artifacts-tab-laptop-page"].exists, "the edited tab should keep its place")
        XCTAssertTrue(app.buttons["artifacts-tab-laptop-page"].isSelected)
    }

    /// ⌘L opens the same field a tap does, and tapping away puts the
    /// address back and leaves the page as it was. (Esc runs in
    /// `testHardwareKeysReachFocusedFields`: while a field has focus, the
    /// simulator's software keyboard takes `typeKey`'s Esc and ⌘ chords.)
    func testCommandLOpensWhatATapOpensAndTappingAwayRestores() throws {
        try launchOnThePage()
        let address = app.buttons["artifacts-address"]
        let label = address.label
        address.tap()
        let field = addressField()
        XCTAssertTrue(field.waitForExistence(timeout: 10), "tapping the address opened no field")
        let tapped = field.value as? String
        XCTAssertEqual(tapped, "localhost:8001/index.html")
        tapAway()
        XCTAssertTrue(waitForAbsence(of: field), "a tap away should end editing")

        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "⌘L opened no field")
        XCTAssertEqual(field.value as? String, tapped, "⌘L should do what a tap does")
        field.typeText("somewhere-else")
        XCTAssertEqual(field.value as? String, "somewhere-else", "⌘L should select the address, as a tap does")
        tapAway()
        XCTAssertTrue(waitForAbsence(of: field), "a tap away should end editing")
        XCTAssertTrue(app.staticTexts["/index.html"].exists, "a tap away must leave the page where it was")
        XCTAssertEqual(address.label, label, "a tap away should put the address back")
    }

    /// ⌘T, then an address on a port that already has a tab, opens a second
    /// tab beside the first instead of jumping to it.
    func testNewTabOpensBesideAnOpenPort() throws {
        try launchOnThePage()
        let before = tabCount()
        app.typeKey("t", modifierFlags: .command)
        let field = addressField()
        XCTAssertTrue(field.waitForExistence(timeout: 10), "⌘T opened no field")
        XCTAssertEqual((field.value as? String).flatMap { $0 == field.placeholderValue ? "" : $0 } ?? "", "",
                       "a new tab starts with an empty field")
        field.typeText("localhost:8001")
        let switchRow = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'switch to tab'")).firstMatch
        XCTAssertTrue(switchRow.waitForExistence(timeout: 10),
                      "the open localhost:8001 tab should be offered as a tab to switch to")
        field.typeText("/laptop.html")
        XCTAssertEqual(field.value as? String, "localhost:8001/laptop.html")
        field.typeText("\n")

        XCTAssertTrue(app.staticTexts["/laptop.html"].waitForExistence(timeout: 20), "the new tab never loaded")
        XCTAssertEqual(tabCount(), before + 1, "⌘T should have opened one more tab")
        XCTAssertTrue(app.buttons["artifacts-tab-laptop-page"].exists, "the first localhost:8001 tab should stay open")
        XCTAssertFalse(app.buttons["artifacts-tab-laptop-page"].isSelected, "the new tab should be the selected one")
    }

    /// The browser's chords act on the browser while it has the keyboard.
    func testBrowserChordsReachTheBrowser() throws {
        try launchOnThePage()
        assertOneNewTabControl("on a page")
        let count = tabCount()

        toggle("\\", [.command, .shift], until: { self.anything("artifacts-overview").exists }, "⌘⇧\\ showed no overview")
        XCTAssertFalse(anything("artifacts-tab-strip").exists, "the strip should hide behind the overview")
        assertOneNewTabControl("on the overview")
        toggle("\\", [.command, .shift], until: { !self.anything("artifacts-overview").exists },
               "⌘⇧\\ again should leave the overview")

        app.typeKey("1", modifierFlags: .command)
        let first = stripTabs().element(boundBy: 0)
        XCTAssertTrue(waitForSelection(of: first), "⌘1 should select the first tab")
        app.typeKey("9", modifierFlags: .command)
        let last = stripTabs().element(boundBy: count - 1)
        XCTAssertTrue(waitForSelection(of: last), "⌘9 should select the last tab")

        app.typeKey("[", modifierFlags: [.command, .shift])
        let previous = stripTabs().element(boundBy: count - 2)
        XCTAssertTrue(waitForSelection(of: previous), "⌘⇧[ should select the previous tab")
        app.typeKey("]", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForSelection(of: last), "⌘⇧] should select the next tab")

        let closing = last.identifier
        let closingLabel = last.label
        app.typeKey("w", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForAbsence(of: app.buttons[closing]), "⌘⇧W should close the tab")
        XCTAssertEqual(tabCount(), count - 1)
        app.typeKey("t", modifierFlags: [.command, .shift])
        // A reopened tab is a new tab: a new identity, the same address.
        let reopened = stripTabs().matching(NSPredicate(format: "label == %@", closingLabel)).firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10), "⌘⇧T should reopen the closed tab")
        XCTAssertTrue(waitForSelection(of: reopened), "the reopened tab should be the selected one")
        XCTAssertEqual(tabCount(), count)
    }

    /// Hardware keys while a field has focus: ⌘⇧\ from the page's own
    /// field reaches the browser, and Esc in the address bar ends editing.
    ///
    /// `typeKey` cannot press them here: with a field focused the
    /// simulator shows its software keyboard, which takes `typeKey`'s Esc and
    /// ⌘ chords as text input. So this runs only beside
    /// `artifacts-browser/tools/keys-probe.sh`, which watches for each
    /// `EXTERNAL-KEYS` line below and presses the keys through AXe as a
    /// hardware keyboard does.
    func testHardwareKeysReachFocusedFields() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_EXTERNAL_KEYS"] == "1" else {
            throw XCTSkip("needs a hardware-keyboard driver beside it; see the doc comment")
        }
        try launchOnThePage()
        let pageField = app.webViews.textFields.firstMatch
        XCTAssertTrue(pageField.waitForExistence(timeout: 20), "the page's field never appeared")
        pageField.tap()
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: pageField)
        XCTAssertEqual(XCTWaiter().wait(for: [focused], timeout: 10), .completed, "the page's field never took focus")
        print("EXTERNAL-KEYS page-field-ready")
        XCTAssertTrue(anything("artifacts-overview").waitForExistence(timeout: 120),
                      "⌘⇧\\ from a focused page field showed no overview")

        let open = app.buttons["artifacts-address"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let field = addressField()
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the overview's address opened no field")
        // The field takes focus on the turn after it appears; Esc before
        // that would reach nothing.
        let editing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [editing], timeout: 10), .completed, "the address field never took focus")
        print("EXTERNAL-KEYS address-ready")
        XCTAssertTrue(waitForAbsence(of: field, timeout: 120), "Esc should end editing")
        XCTAssertTrue(anything("artifacts-overview").exists, "Esc should leave the overview where it was")
    }

    // MARK: - Helpers

    private func launchOnThePage() throws {
        app.launch()
        XCTAssertTrue(app.buttons["artifacts-address"].waitForExistence(timeout: 30), "the browser never showed its address")
        XCTAssertTrue(app.staticTexts["/index.html"].waitForExistence(timeout: 20), "the localhost:8001 page never loaded")
    }

    /// A tap on the page below the suggestions (at most 360 pt under the
    /// toolbar) and above the software keyboard. The keyboard's element
    /// leaves out the shortcuts bar above its keys, about 55 pt.
    private func tapAway() {
        // The software keyboard can still be on its way in after ⌘L.
        let keyboard = app.keyboards.firstMatch
        let y = keyboard.waitForExistence(timeout: 5) ? keyboard.frame.minY - 100 : app.frame.height * 0.8
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: y)).tap()
    }

    private func addressField() -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "identifier IN %@", ["artifacts-address-field", "artifacts-quick-open-input"]))
            .firstMatch
    }

    private func anything(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The strip's tabs, left to right. Only the strip shows tabs while a
    /// page is on screen; the overview's cards replace it. Scoped to the
    /// strip: the toolbar's `artifacts-tab-menu` shares the prefix.
    private func stripTabs() -> XCUIElementQuery {
        anything("artifacts-tab-strip").buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'artifacts-tab-'"))
    }

    private func tabCount() -> Int { stripTabs().count }

    override func record(_ issue: XCTIssue) {
        if app != nil, app.state == .runningForeground {
            print("ArtifactsBrowserChromeProbe tree at failure:\n\(app.debugDescription)")
        }
        super.record(issue)
    }

    private func assertOneNewTabControl(_ where: String, file: StaticString = #filePath, line: UInt = #line) {
        let controls = app.buttons.matching(NSPredicate(format: "label == 'new tab' OR identifier == 'artifacts-new-tab'"))
        XCTAssertEqual(controls.allElementsBoundByIndex.filter(\.isHittable).count, 1,
                       "exactly one new-tab control should show \(`where`)", file: file, line: line)
        let overviews = app.buttons.matching(NSPredicate(format: "identifier == 'artifacts-show-overview'"))
        XCTAssertLessThanOrEqual(overviews.allElementsBoundByIndex.filter(\.isHittable).count, 1,
                                 "at most one overview control should show \(`where`)", file: file, line: line)
    }

    /// Presses a toggling chord until `state` holds. On a loaded simulator a
    /// synthesized press can outlast the key-repeat delay and toggle twice
    /// (the app logged two fires 0.87 s apart for one press), so a press that
    /// left the state unchanged is pressed again, at most three times.
    private func toggle(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags, until state: () -> Bool,
                        _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<3 {
            app.typeKey(key, modifierFlags: modifiers)
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if state() { return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
        }
        XCTFail(message, file: file, line: line)
    }

    private func waitForSelection(of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isSelected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func waitForAbsence(of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
