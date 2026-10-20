import XCTest
import UIKit
import GameController
@testable import Tessera

final class ModifierStateTests: XCTestCase {
    func testSystemDismissalDoesNotResignTwiceAndPaneTapDoesNotFocusPreviousPane() {
        let state = ModifierState()
        var resignCount = 0
        var becomeCount = 0
        state.noteSoftwareKeyboardRequested(resign: { resignCount += 1; return true },
                                            become: { becomeCount += 1; return true })
        state.noteSoftwareKeyboardDismissed()
        XCTAssertTrue(state.suppressesSoftwareKeyboardReclaim)
        XCTAssertEqual(resignCount, 0)
        state.requestSoftwareKeyboardOnTerminalTap()
        XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
        XCTAssertEqual(becomeCount, 0, "Pane selection must not claim the previously focused pane")
    }
    func testSoftwareKeyboardDismissalPersistsUntilExplicitRequest() {
        let state = ModifierState()
        var resignCount = 0
        state.noteSoftwareKeyboardRequested {
            resignCount += 1
            return true
        }

        state.dismissSoftwareKeyboard()
        XCTAssertTrue(state.suppressesSoftwareKeyboardReclaim)
        XCTAssertEqual(resignCount, 1)

        state.noteSoftwareKeyboardRequested { false }
        XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
    }

    func testSoftwareKeyboardRequestRestoresResponderReclaim() {
        let state = ModifierState()
        var becomeCount = 0
        state.noteSoftwareKeyboardRequested(
            resign: { true },
            become: {
                becomeCount += 1
                return true
            }
        )

        state.dismissSoftwareKeyboard()
        XCTAssertTrue(state.suppressesSoftwareKeyboardReclaim)
        XCTAssertTrue(state.showSoftwareKeyboard())
        XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
        XCTAssertEqual(becomeCount, 1)
    }

    func testSoftwareKeyboardPipelineConsumesOnlyAnEligibleNextKey() {
        let state = ModifierState()
        state.tap(.ctrl)

        XCTAssertEqual(
            state.encodeSoftwareKeyboardPayload(Array("paste".utf8)),
            Array("paste".utf8)
        )
        XCTAssertTrue(state.armed.ctrl)

        XCTAssertEqual(
            state.encodeSoftwareKeyboardPayload(Array("c".utf8)),
            [0x03]
        )
        XCTAssertEqual(state.armed, .none)
    }

    func test_initialArmedIsNone() {
        let state = ModifierState()

        XCTAssertEqual(state.armed, .none)
    }

    func test_tapCtrlArmsCtrl() {
        let state = ModifierState()

        XCTAssertEqual(state.tap(.ctrl), ArmedModifiers(ctrl: true))
        XCTAssertEqual(state.armed, ArmedModifiers(ctrl: true))
    }

    func test_tapCtrlAgainClearsCtrl() {
        let state = ModifierState()

        state.tap(.ctrl)

        XCTAssertEqual(state.tap(.ctrl), .none)
        XCTAssertEqual(state.armed, .none)
    }

    func test_tapCtrlThenAltArmsBoth() {
        let state = ModifierState()

        state.tap(.ctrl)

        XCTAssertEqual(state.tap(.alt), ArmedModifiers(ctrl: true, alt: true))
        XCTAssertEqual(state.armed, ArmedModifiers(ctrl: true, alt: true))
    }

    func test_consumeOneShotReturnsArmedAndResets() {
        let state = ModifierState()
        state.tap(.ctrl)
        state.tap(.shift)

        XCTAssertEqual(state.consume(), ArmedModifiers(ctrl: true, shift: true))
        XCTAssertEqual(state.armed, .none)
    }

    func test_consumeStickyReturnsArmedAndLeavesState() {
        let state = ModifierState()
        state.behavior = .sticky
        state.tap(.alt)

        XCTAssertEqual(state.consume(), ArmedModifiers(alt: true))
        XCTAssertEqual(state.armed, ArmedModifiers(alt: true))
    }

    func test_cancelClearsRegardlessOfMode() {
        let state = ModifierState()
        state.behavior = .sticky
        state.tap(.ctrl)
        state.tap(.alt)
        state.tap(.shift)

        state.cancel()

        XCTAssertEqual(state.armed, .none)
    }
}

@MainActor
final class TerminalKeyboardDismissalTests: XCTestCase {
    func testTerminalTapClearsIntentBeforeUIKitCanReenterFocusRequest() async throws {
        try await withSurface { state, _, view, _ in
            state.dismissSoftwareKeyboard()
            await settle()
            XCTAssertEqual(view.allowsFirstResponderRequest?(true), true)
            XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertEqual(view.allowsFirstResponderRequest?(false), true)
            XCTAssertTrue(view.becomeFirstResponder())
        }
    }

    func testHardwareAttachmentHidePreservesFocusButLaterManualHideCounts() async throws {
        try await withSurface { state, _, view, _ in
            NotificationCenter.default.post(name: .GCKeyboardDidConnect, object: nil)
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            await settle()
            XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertTrue(view.isFirstResponder)
            NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
            await settle()
            XCTAssertTrue(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertFalse(view.isFirstResponder)
        }
    }

    func testHideAfterWindowLosesKeyDoesNotSeedStaleVisibility() async throws {
        try await withSurface(softwareKeyboard: false) { state, _, view, window in
            NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
            let other = UIWindow(windowScene: window.windowScene!)
            other.rootViewController = UIViewController()
            other.makeKeyAndVisible()
            defer { other.isHidden = true }
            XCTAssertFalse(window.isKeyWindow)
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            window.makeKey()
            let replacement = makeCoordinator(state: state, view: view)
            XCTAssertTrue(view.becomeFirstResponder())
            XCTAssertTrue(view.resignFirstResponder())
            await settle()
            XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertTrue(replacement.permitsFirstResponderReclaim)
        }
    }

    func testNewCoordinatorInheritsVisibleKeyboardWithoutAnotherShowNotification() async throws {
        try await withSurface { state, _, view, _ in
            // A newly mounted pane can inherit an already presented keyboard.
            // Its coordinator never received the earlier willShow notification.
            let replacement = makeCoordinator(state: state, view: view)
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
            XCTAssertFalse(replacement.permitsFirstResponderReclaim)
            await settle()
            XCTAssertTrue(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertFalse(view.isFirstResponder)
        }
    }

    func testSupersedingShowCancelsKeyboardReconfigurationHide() async throws {
        try await withSurface { state, coordinator, view, _ in
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
            await settle()
            XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertTrue(view.isFirstResponder)
            XCTAssertTrue(coordinator.permitsFirstResponderReclaim)
        }
    }

    func testDelayedTransitionHideIsNotAnExplicitDismissal() async throws {
        try await withSurface { state, _, view, _ in
            // Model UIKit retaining/reinstating the responder without a new
            // show event, then delivering the app-owned hide asynchronously.
            view.onWillResignFirstResponder?(true)
            view.onDidResignFirstResponder?(true)
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            await settle()
            XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertTrue(view.isFirstResponder)
        }
    }

    func testSystemHideThatRetainsFirstResponderStillRequiresAnExplicitRequest() async throws {
        try await withSurface { state, coordinator, view, _ in
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
            XCTAssertTrue(view.isFirstResponder, "This UIKit path hides its input view before resigning")
            XCTAssertFalse(coordinator.permitsFirstResponderReclaim)
            await settle()
            XCTAssertTrue(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertFalse(view.isFirstResponder)
            XCTAssertFalse(view.becomeFirstResponder())
            XCTAssertTrue(state.showSoftwareKeyboard())
        }
    }

    func testSystemHideStillCountsWhenTerminalWasTappedWithFindOpen() async throws {
        try await withSurface { state, coordinator, view, _ in
            // Find remaining open prevents automatic reclaim, but a user can
            // still tap the terminal and subsequently hide its keyboard.
            coordinator.noteFocusSuppression(true)
            XCTAssertTrue(view.isFirstResponder)
            XCTAssertTrue(view.resignFirstResponder())
            await settle()
            XCTAssertTrue(state.suppressesSoftwareKeyboardReclaim)
            coordinator.noteFocusSuppression(false)
            XCTAssertFalse(coordinator.permitsFirstResponderReclaim)
        }
    }

    func testFocusLossWithoutSoftwareKeyboardRemainsAutomaticallyRecoverable() async throws {
        try await withSurface(softwareKeyboard: false) { state, coordinator, view, window in
            try await Task.sleep(for: .milliseconds(600))
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            XCTAssertLessThanOrEqual(window.keyboardLayoutGuide.layoutFrame.height, window.safeAreaInsets.bottom)
            XCTAssertTrue(view.resignFirstResponder())
            await settle()
            XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertTrue(coordinator.permitsFirstResponderReclaim)
        }
    }

    func testSystemResignationBlocksQueuedReclaimThenLatchesUntilExplicitShow() async throws {
        try await withSurface { state, coordinator, view, _ in
            XCTAssertTrue(coordinator.permitsFirstResponderReclaim)
            XCTAssertTrue(view.resignFirstResponder())
            XCTAssertFalse(coordinator.permitsFirstResponderReclaim, "A previously queued reclaim must stop synchronously")
            await settle()
            XCTAssertTrue(state.suppressesSoftwareKeyboardReclaim)
            coordinator.bindKeyboardFocus(to: view)
            coordinator.noteFocusSuppression(false)
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            await settle()
            XCTAssertFalse(view.isFirstResponder)
            XCTAssertFalse(coordinator.permitsFirstResponderReclaim)
            XCTAssertTrue(state.showSoftwareKeyboard())
            XCTAssertTrue(view.isFirstResponder)
            XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
        }
    }

    func testResignationToLocalTextFieldIsNotDismissalAndCannotBeReclaimed() async throws {
        try await withSurface { state, coordinator, view, window in
            let field = UITextField(frame: CGRect(x: 0, y: 350, width: 200, height: 40))
            window.rootViewController!.view.addSubview(field)
            XCTAssertTrue(field.becomeFirstResponder())
            await settle()
            XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertFalse(coordinator.permitsFirstResponderReclaim)
            XCTAssertTrue(field.isFirstResponder)
            field.resignFirstResponder()
            await settle()
            XCTAssertTrue(coordinator.permitsFirstResponderReclaim)
            XCTAssertFalse(view.isFirstResponder)
        }
    }

    func testProgrammaticCleanupAndHiddenSurfaceDoNotBecomeDismissals() async throws {
        try await withSurface { state, coordinator, view, _ in
            let box = TerminalBox(traceLabel: "keyboard-dismissal-test")
            box.attach(view)
            box.dismissTransientInteractions()
            await settle()
            XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertTrue(coordinator.permitsFirstResponderReclaim)
            XCTAssertTrue(view.becomeFirstResponder())
            view.setSessionDrawingEnabled(false)
            await settle()
            XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertFalse(coordinator.permitsFirstResponderReclaim)
            view.setSessionDrawingEnabled(true)
            XCTAssertTrue(coordinator.permitsFirstResponderReclaim)
        }
    }

    func testFocusAndPermissionChangesCancelPendingDismissal() async throws {
        for transition in ["local-input", "locked", "inactive", "hardware-connect"] {
            try await withSurface { state, coordinator, view, _ in
                XCTAssertTrue(view.resignFirstResponder())
                switch transition {
                case "local-input": coordinator.noteFocusSuppression(true)
                case "locked": coordinator.inputAllowed = { false }
                case "inactive": NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
                default: NotificationCenter.default.post(name: .GCKeyboardDidConnect, object: nil)
                }
                await settle()
                XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim, transition)
            }
        }
    }

    func testNewFocusRequestInvalidatesOlderResignation() async throws {
        try await withSurface { state, _, view, _ in
            XCTAssertTrue(view.resignFirstResponder())
            XCTAssertFalse(view.becomeFirstResponder(), "A passive UIKit reactivation is not a user request")
            XCTAssertTrue(state.showSoftwareKeyboard())
            await settle()
            XCTAssertTrue(view.isFirstResponder)
            XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
        }
    }

    func testPassiveUIKitReactivationAndLocalEditingPreserveDismissedIntent() async throws {
        try await withSurface { state, _, view, window in
            state.dismissSoftwareKeyboard()
            await settle()
            XCTAssertFalse(view.becomeFirstResponder())
            let field = UITextField(frame: CGRect(x: 0, y: 350, width: 200, height: 40))
            window.rootViewController!.view.addSubview(field)
            XCTAssertTrue(field.becomeFirstResponder())
            await settle()
            XCTAssertTrue(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertFalse(view.becomeFirstResponder())
            XCTAssertTrue(field.isFirstResponder)
            field.resignFirstResponder()
            await settle()
            XCTAssertTrue(state.suppressesSoftwareKeyboardReclaim)
        }
    }

    func testFailedResignationCannotLatchDismissal() async throws {
        try await withSurface { state, coordinator, view, _ in
            view.onWillResignFirstResponder?(false)
            XCTAssertFalse(coordinator.permitsFirstResponderReclaim)
            view.onDidResignFirstResponder?(false)
            await settle()
            XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertTrue(coordinator.permitsFirstResponderReclaim)
        }
    }

    func testDismissalSurvivesLifecycleHardwareAndPaneIdentityChanges() async throws {
        try await withSurface { state, coordinator, view, _ in
            state.dismissSoftwareKeyboard()
            await settle()
            coordinator.setScrollRetentionID("another-pane")
            coordinator.noteFocusSuppression(true)
            coordinator.noteFocusSuppression(false)
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.post(name: .GCKeyboardDidConnect, object: nil)
            await settle()
            XCTAssertTrue(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertFalse(view.isFirstResponder)
            XCTAssertFalse(coordinator.permitsFirstResponderReclaim)
        }
    }

    func testKeyboardOwnershipTransferStillRecognizesNextSystemDismissal() async throws {
        try await withSurface { state, coordinator, view, window in
            let field = UITextField(frame: CGRect(x: 0, y: 350, width: 200, height: 40))
            window.rootViewController!.view.addSubview(field)
            XCTAssertTrue(field.becomeFirstResponder())
            await settle()
            XCTAssertTrue(view.becomeFirstResponder())
            XCTAssertTrue(view.resignFirstResponder())
            await settle()
            XCTAssertTrue(state.suppressesSoftwareKeyboardReclaim)
            XCTAssertFalse(coordinator.permitsFirstResponderReclaim)
        }
    }

    private func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func withSurface(
        softwareKeyboard: Bool = true,
        _ body: (ModifierState, TerminalSurfaceBound.Coordinator, TesseraResponderAwareTerminalView, UIWindow) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKey?.makeKey() }
        let state = ModifierState()
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.inputAccessoryView = nil
        if !softwareKeyboard { view.inputView = UIView(frame: .zero) }
        window.rootViewController!.view.addSubview(view)
        let coordinator = makeCoordinator(state: state, view: view)
        XCTAssertTrue(view.becomeFirstResponder())
        // Let real UIKit presentation finish before injecting the policy
        // events below; a delayed willShow would otherwise supersede them.
        try await Task.sleep(for: .milliseconds(600))
        if softwareKeyboard {
            NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        }
        try await body(state, coordinator, view, window)
    }

    private func makeCoordinator(state: ModifierState, view: TesseraResponderAwareTerminalView) -> TerminalSurfaceBound.Coordinator {
        let coordinator = TerminalSurfaceBound.Coordinator(
            onReady: {}, onSend: { _ in }, onResize: { _, _ in }, onTitle: { _ in },
            onUserActivity: nil, onBell: nil, onPrimaryScrollbackDelta: nil,
            onPrimaryScrollbackUnderflow: nil, agentScrollBlockingActive: false,
            onAgentScrollBlocked: nil, mouseReportingImpliesAltScreen: false,
            suppressDirectColorQueryResponses: true, softwareModifierState: state,
            onHardwareKey: nil, onTerminalScrolled: nil, scrollRetentionID: nil,
            onScrollDiagnostic: nil)
        coordinator.terminalView = view
        coordinator.noteFocusSuppression(false)
        coordinator.bindKeyboardFocus(to: view)
        coordinator.observeHardwareKeyboard()
        return coordinator
    }
}
