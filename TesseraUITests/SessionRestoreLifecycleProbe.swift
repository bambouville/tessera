import XCTest

/// Restore's wiring, driven through real app lifecycle edges.
///
/// The decisions restore makes are the shared core's and are already pinned by
/// `ForegroundRestoreCohortTests`. Nothing here re-tests them. These cases
/// cover the layer above — the guard order, the latch, which edge writes what —
/// which no unit test on iOS can reach: that state is SwiftUI `@State` on
/// `ContentView`, so there is nothing to construct and drive. A UI test can.
///
/// Host-free: `SessionRestoreDebugHarness` seeds fixture hosts at a closed
/// loopback port, so a restore reconnect refuses immediately and nothing the
/// user owns is ever dialled.
///
/// These cases pass today. They exist so that pulling the restore driver out of
/// `ContentView` — and everything after it — shows up here as a failure rather
/// than as sessions quietly not coming back a week later.
///
/// A UI test runs out of process and cannot read the app container, so the
/// assertions are made by `scripts/uitest/run-restore-lifecycle-gate.sh` over
/// the mirrored `[Tessera][RestoreDiag]` lines in the system log. Each case
/// segments that log with its own `[Tessera][RestoreHarness] case=` marker.
final class SessionRestoreLifecycleProbe: XCTestCase {

    /// Long enough for the 500 ms window tick to run several passes and for a
    /// settled window to close, short enough to keep the suite bearable.
    private static let settleSeconds: TimeInterval = 8

    /// Below the 5 s alive floor on purpose: a visit this short is the common
    /// case, and the one that used to inherit the previous wake's clock.
    private static let shortVisitSeconds: TimeInterval = 2

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app?.terminate()
    }

    // MARK: - the wake edge

    /// Every return to the foreground owes its stored sessions a wake window.
    func testWakeFromBackgroundOpensARestoreWindow() {
        launch(caseName: "wake", policy: "always", hostCount: 2)
        settle()

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: Self.shortVisitSeconds)
        app.activate()
        settle()
    }

    /// A visit shorter than the alive floor must still get a window of its own,
    /// on its own clock. Carrying the previous wake's clock made the floor read
    /// as long spent, retired every entry on the first pass, and left a
    /// detection window of zero — for every app visit under five seconds.
    func testShortVisitsEachGetTheirOwnWindow() {
        launch(caseName: "short-visits", policy: "always", hostCount: 2)
        settle()

        for _ in 0..<3 {
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: Self.shortVisitSeconds)
            app.activate()
            Thread.sleep(forTimeInterval: Self.shortVisitSeconds)
        }
        settle()
    }

    // MARK: - the relaunch edge

    /// Force-quitting from the app switcher is a termination, not an
    /// instruction to forget. The next launch restores.
    ///
    /// This is the case Android currently fails: there the equivalent gesture —
    /// a swipe out of recents — deletes both restore stores outright.
    func testRelaunchAfterTerminationRestores() {
        launch(caseName: "relaunch-seed", policy: "always", hostCount: 2)
        settle()

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: Self.shortVisitSeconds)
        app.terminate()

        // The second launch must find what the first one left, so it seeds
        // nothing of its own.
        launch(caseName: "relaunch", policy: "always", hostCount: 0, seedsFixtures: false)
        settle()
    }

    // MARK: - the document

    /// One entry this device can no longer restore says nothing about the rest.
    /// Clearing the whole document on a partial miss threw away live sessions'
    /// snapshots along with the dead host's.
    func testAPartlyUnrestorableDocumentIsNotClearedWholesale() {
        launch(
            caseName: "partial-document",
            policy: "always",
            hostCount: 1,
            orphanSnapshotCount: 1
        )
        settle()
    }

    /// A launch that opens a host before restore evaluates must still restore
    /// the others. This is `A6` in `docs/android-session-restore-plan.md`:
    /// "launch with a share / notification intent while a document exists —
    /// `startup_restore_plan` still emitted". Android was fixed for it in
    /// `c3626868`; iOS refused to run at all whenever any session existed, so
    /// a share target, an agent notification tap, a continuity handoff or a URL
    /// open silently took restore with it and then cleared the document.
    func testALaunchThatOpensAHostStillRestoresTheOthers() {
        launch(
            caseName: "launch-opens-host",
            policy: "always",
            hostCount: 2,
            preopensHostCount: 1
        )
        settle()
    }

    /// The trap in the same fix: with the guard gone, a document whose every
    /// entry is already on screen reaches `skip(.nothingRestorable)`. Clearing
    /// there turns a silent no-restore into data loss — those entries were
    /// excluded, not judged unrestorable.
    func testADocumentAlreadyFullyOnScreenIsNotCleared() {
        launch(
            caseName: "launch-opens-everything",
            policy: "always",
            hostCount: 1,
            preopensHostCount: 1
        )
        settle()
    }

    // MARK: - the prompt

    /// Under "ask" the sheet is raised once and stays up. A 500 ms tick behind
    /// an unguarded sheet re-presented it dozens of times across one window,
    /// resetting the user's toggle on every pass.
    ///
    /// Compact width coerces "ask" to "always", so this case is only meaningful
    /// on a regular-width simulator; the gate script picks an iPad.
    func testTheAskPromptIsRaisedOnceAndStaysUp() {
        launch(caseName: "ask-prompt", policy: "ask", hostCount: 2)
        settle()

        // The sheet is a decision about which sessions exist; nothing should
        // have dismissed it while the window ticked underneath. Its title is
        // the identity here — the probe deliberately does not answer it, so
        // the buttons stay untouched.
        XCTAssertTrue(
            app.staticTexts["reopen previous connections"].waitForExistence(timeout: 5),
            "the restore prompt should still be on screen after the window has ticked"
        )
    }

    // MARK: - driving

    private func launch(
        caseName: String,
        policy: String,
        hostCount: Int,
        orphanSnapshotCount: Int = 0,
        seedsFixtures: Bool = true,
        seedsDocument: Bool = true,
        preopensHostCount: Int = 0
    ) {
        let configuration: [String: Any] = [
            "caseName": caseName,
            "seedsFixtures": seedsFixtures,
            "hostCount": hostCount,
            "orphanSnapshotCount": orphanSnapshotCount,
            "seedsDocument": seedsDocument,
            "preopensHostCount": preopensHostCount,
        ]
        let encoded = try! JSONSerialization.data(withJSONObject: configuration)
        app = XCUIApplication()
        app.launchEnvironment["TESSERA_RESTORE_HARNESS"] = encoded.base64EncodedString()
        app.launchArguments += ["-tessera.pref.sessionRestorePolicy", policy]
        app.launch()
    }

    private func settle() {
        Thread.sleep(forTimeInterval: Self.settleSeconds)
    }
}
