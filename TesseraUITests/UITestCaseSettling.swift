import XCTest

/// The UI test bundle's principal class (`NSPrincipalClass`), created once
/// before the first case runs. It ends every case with Tessera terminated.
///
/// Cases leave the app however they finish, and most begin by setting the
/// device orientation and then launching. After a case that left the app in
/// the foreground in another orientation, that launch terminated an app still
/// rotating inside SpringBoard's layout transition. The iOS 26 simulator's
/// SpringBoard asserts there (`SBMainSwitcherControllerCoordinator`) and dies,
/// and every later case fails with "Failed to get list of active
/// applications". With the app gone, a case's rotation turns only the home
/// screen.
@objc(UITestCaseSettling)
final class UITestCaseSettling: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        guard !(testCase is LeavesTheAppRunning) else { return }
        let app = XCUIApplication(bundleIdentifier: "com.bambouville.TesseraApp")
        guard app.state != .notRunning else { return }
        // A case can end on its own rotation or return from Home; let that
        // transition finish rather than ending the app inside it.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.terminate()
    }
}

/// A probe that reads an app the person left open, and so must not end it.
protocol LeavesTheAppRunning {}
