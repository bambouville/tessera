// TesseraTests/KeyboardFocusRetentionReproTests.swift
//
// Minimal reproductions for the dead-keyboard defect class re-investigated on
// 2026-09-18 (keys do nothing while touch still works).
//
// Scope note, deliberately recorded here: the 2026-09-12 fix
// (aa5fc179) repaired four independently reproduced input-loss paths but
// its own QA report declines to claim they explain the device incident. These
// tests cover the paths that reduce to a deterministic state transition. The
// paths that do not are listed at the bottom of this file with the seam each
// one needs before it can be tested at all.
//
// Every reclaim in TerminalSurfaceBound is gated on `!view.isFirstResponder`
// and on `suppressFirstResponderReclaim` being false, so a suppressor that
// latches true, or a first-responder flag that reads true while input is dead,
// disables all three recovery paths at once.

import UIKit
import XCTest
import TmuxControlCore
@testable import Tessera

@MainActor
final class KeyboardFocusRetentionReproTests: XCTestCase {

    // MARK: - Defect 1 — the Files panel's text-entry latch outlives the panel

    /// `FilesPanelController.textEntryActive` is ORed into
    /// `suppressFirstResponderReclaim` at SessionView.swift:1659, :1784 and
    /// :7788. It is written by exactly one place — the private
    /// `FilesPanelView.syncTextEntryFlag()` (Files/FilesPanelView.swift:492),
    /// driven by `.onChange` modifiers on a view that is only mounted while
    /// `filesPanel.isOpen` is true.
    ///
    /// Closing the panel while its search or path field still holds focus tears
    /// that view down, so `syncTextEntryFlag()` never runs again and the flag
    /// keeps its last value. `close()` does not clear it
    /// (Files/FilesPanelController.swift:89-92), so the terminal's reclaim stays
    /// suppressed for the life of the controller — i.e. for the life of the
    /// session. Touch keeps working; the keyboard never comes back.
    ///
    /// Reproduction path in the app: focus the panel's search field, then close
    /// the panel without defocusing first (tap the dismiss catcher at
    /// SessionView.swift:4143, press ⌘⇧E, or swipe the compact sheet down).
    func testClosingFilesPanelReleasesTerminalFocusSuppression() {
        let controller = FilesPanelController()
        controller.open()

        // Stands in for `searchFieldFocused` / `pathFieldFocused` going true,
        // which is the only way the real flag is ever set.
        controller.textEntryActive = true

        controller.close()

        XCTAssertFalse(
            controller.textEntryActive,
            """
            A closed Files panel must not keep suppressing the terminal's \
            first-responder reclaim. While this stays true, every reclaim path \
            in TerminalSurfaceBound (makeUIView, updateUIView, and \
            restoreKeyboardFocusAfterActivation) declines, and the keyboard \
            cannot recover by any in-app route.
            """
        )
    }

    /// Guards the narrower invariant the fix would need: whatever else `close()`
    /// does, a controller that is not open must not be advertising text entry.
    func testClosedFilesPanelNeverAdvertisesTextEntry() {
        let controller = FilesPanelController()
        controller.textEntryActive = true
        controller.close()

        XCTAssertFalse(
            controller.isOpen && controller.textEntryActive,
            "isOpen == false with textEntryActive == true is the latched state"
        )
        XCTAssertFalse(
            controller.textEntryActive,
            "textEntryActive must be false whenever the panel is closed"
        )
    }

    // MARK: - Defect 2 — precondition: focus can be taken in a non-key window

    /// `restoreKeyboardFocusAfterActivation` (SessionView.swift:14882) guards on
    /// `window.isKeyWindow` and `windowScene.activationState == .foregroundActive`
    /// before reclaiming. The `updateUIView` reclaim (SessionView.swift:14657)
    /// has neither guard.
    ///
    /// The device log from 2026-09-18 shows the consequence: at 17:19:28.174 the
    /// scene goes to `background`, the terminal resigns at .195, and the
    /// unguarded reclaim takes first responder back at .516 — 342 ms into the
    /// background. On the next resume the activation repair runs
    /// `if !view.isFirstResponder`, reads true, and does nothing.
    ///
    /// This test pins the precondition only: UIKit accepts a first-responder
    /// claim from a view whose window is not key, so `isFirstResponder` is not a
    /// sound proxy for "this view will receive keys". It does NOT prove keys are
    /// dead afterwards — see the note at the bottom of this file.
    func testTerminalTakesFirstResponderWhileItsWindowIsNotKey() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)

        let keyWindow = UIWindow(windowScene: scene)
        keyWindow.rootViewController = UIViewController()
        keyWindow.makeKeyAndVisible()

        let offscreen = UIWindow(windowScene: scene)
        offscreen.rootViewController = UIViewController()
        offscreen.isHidden = false

        defer {
            offscreen.isHidden = true
            keyWindow.isHidden = true
            previousKeyWindow?.makeKey()
        }

        let terminal = TesseraResponderAwareTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        offscreen.rootViewController?.view.addSubview(terminal)

        XCTAssertFalse(
            offscreen.isKeyWindow,
            "precondition: the terminal's window is not the key window"
        )

        let accepted = terminal.becomeFirstResponder()

        XCTAssertTrue(
            accepted,
            """
            UIKit accepted a first-responder claim in a non-key window. The \
            updateUIView reclaim has no isKeyWindow / foregroundActive guard, so \
            it can leave isFirstResponder == true at a moment the activation \
            repair will then refuse to act on.
            """
        )
        XCTAssertTrue(terminal.isFirstResponder)
    }

    // MARK: - Defect 4 — the phone-only keyboard latch also applies on iPad

    /// `suppressesSoftwareKeyboardReclaim` is consumed as
    /// `(isPhone && modifierState.suppressesSoftwareKeyboardReclaim)` at
    /// SessionView.swift:1660, :1785 and :7789, which reads as "phone only".
    /// `CompactLayout.isPhone` is size-class driven
    /// (Design/DesignTokens.swift:12-15), so an iPad in Slide Over or a narrow
    /// Stage Manager window takes the phone branch — and hiding the software
    /// keyboard there also suppresses hardware-keyboard reclaim.
    ///
    /// Characterization, not a failing repro: this asserts today's behaviour so
    /// the iPad scope is recorded rather than rediscovered.
    func testCompactWidthTakesThePhoneKeyboardDismissalBranch() {
        XCTAssertTrue(
            CompactLayout.isPhone(.compact),
            "a compact-width iPad is treated as a phone by the keyboard latch"
        )
        XCTAssertFalse(CompactLayout.isPhone(.regular))
    }

    /// `dismissSoftwareKeyboard()` latches, and the only two clears are
    /// `showSoftwareKeyboard()` and `noteSoftwareKeyboardRequested()`
    /// (Keyboard/ModifierState.swift:56-75). The latter is invoked only from
    /// `view.onBecameFirstResponder` (SessionView.swift:14396, :14634), i.e. it
    /// requires the focus the latch itself prevents.
    ///
    /// Characterization: pins the latch's shape so a fix has a baseline.
    func testSoftwareKeyboardDismissalLatchesUntilAnExplicitShow() {
        let state = ModifierState()
        XCTAssertFalse(state.suppressesSoftwareKeyboardReclaim)

        state.dismissSoftwareKeyboard()
        XCTAssertTrue(
            state.suppressesSoftwareKeyboardReclaim,
            "dismissing the software keyboard suppresses reclaim"
        )

        state.showSoftwareKeyboard()
        XCTAssertFalse(
            state.suppressesSoftwareKeyboardReclaim,
            "an explicit show is one of only two clears"
        )
    }

    // MARK: - Defects 4 and 6 — the shared global-resign mechanism

    /// Three separate surfaces strip first responder app-wide rather than from
    /// a view they own, via `sendAction(#selector(UIResponder.resignFirstResponder),
    /// to: nil, …)`:
    ///   - Security/LockScreenView.swift:133-140 (app lock; defect 6)
    ///   - Keyboard/SessionAccessoryBar.swift:170 (hide-keyboard chip; defect 4)
    ///   - HostKeyVerificationView.swift:55-60 (mid-session TOFU sheet — reachable
    ///     on mosh+tmux, whose scrollback side channel is a second SSH connection)
    ///
    /// None of the three has a counterpart that restores focus. This is the same
    /// shape as the `window.endEditing(true)` that aa5fc179 removed from
    /// `TerminalBox.dismissTransientInteractions`, except it reaches wider.
    ///
    /// REFUTATION — recorded deliberately. I predicted this idiom strips a live
    /// terminal's first responder, and it does not. Measured on iPad sim,
    /// iOS 26.0, with the terminal first responder in the key window:
    ///
    ///     isKeyWindow=true beforeFR=true sendActionDelivered=true
    ///     afterSendAction=true  directResignReturned=true afterDirect=false
    ///
    /// `sendAction` reports delivery (every UIResponder answers
    /// `resignFirstResponder`, so target lookup always succeeds) yet the
    /// terminal keeps first responder, while a direct call on the same view
    /// resigns it immediately.
    ///
    /// Two consequences, neither of which I have proven further:
    ///   - the "app lock / host-key sheet strips terminal focus" premise behind
    ///     defects 4 and 6 is NOT established, and this probe contradicts it;
    ///   - conversely these three call sites may be silent no-ops, i.e. the
    ///     host-key sheet may not actually clear the keyboard it is trying to
    ///     get out from behind. That is a separate defect, not this one.
    ///
    /// Caveat: a synthetic test window is not the app's real SwiftUI hierarchy.
    /// Do not promote either consequence to a conclusion without a device check.
    func testGlobalResignActionDoesNotStripALiveTerminalsFirstResponder() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        let terminal = TesseraResponderAwareTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        window.rootViewController?.view.addSubview(terminal)
        XCTAssertTrue(terminal.becomeFirstResponder())

        XCTAssertTrue(window.isKeyWindow, "precondition: terminal is in the key window")

        let delivered = UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )

        XCTAssertTrue(delivered, "target lookup always succeeds for this selector")
        XCTAssertTrue(
            terminal.isFirstResponder,
            """
            Refutation pin: the global resign idiom used by LockScreenView, \
            SessionAccessoryBar and HostKeyVerificationView did NOT resign the \
            terminal. If this assertion ever starts failing, the idiom began \
            working and the defect-4/6 premise needs re-examining.
            """
        )

        XCTAssertTrue(
            terminal.resignFirstResponder(),
            "a direct resign on the same view does work"
        )
        XCTAssertFalse(terminal.isFirstResponder)
    }

    // MARK: - Defect 2 — can isFirstResponder actually go stale-true?

    /// Defect 2 requires that a terminal keeps `isFirstResponder == true` across
    /// the transition that ends its input session. If UIKit resigns it
    /// automatically, the premise collapses: `restoreKeyboardFocusAfterActivation`
    /// would find `!isFirstResponder` and repair normally.
    ///
    /// Probe 1: another window becomes key.
    func testFirstResponderSurvivesLosingKeyWindowStatus() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let first = UIWindow(windowScene: scene)
        first.rootViewController = UIViewController()
        first.makeKeyAndVisible()
        let second = UIWindow(windowScene: scene)
        second.rootViewController = UIViewController()
        defer {
            second.isHidden = true
            first.isHidden = true
            previousKeyWindow?.makeKey()
        }

        let terminal = TesseraResponderAwareTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        first.rootViewController?.view.addSubview(terminal)
        XCTAssertTrue(terminal.becomeFirstResponder())

        second.makeKeyAndVisible()

        print("DEFECT2PROBE afterOtherWindowKey isFirstResponder=\(terminal.isFirstResponder) ownWindowKey=\(first.isKeyWindow)")
    }

    /// Probe 2: the view is hidden, which is exactly what a backgrounded session
    /// does — `setSessionDrawingEnabled(false)` sets `isHidden`
    /// (TesseraTerminalView.swift:151-158). If UIKit resigns a hidden first
    /// responder, defect 2's stale-true premise fails for the session-switch
    /// path too.
    func testHidingATerminalReleasesFirstResponder() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        let terminal = TesseraResponderAwareTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        window.rootViewController?.view.addSubview(terminal)
        XCTAssertTrue(terminal.becomeFirstResponder())

        terminal.setSessionDrawingEnabled(false)

        XCTAssertTrue(terminal.isHidden, "precondition: drawing off hides the surface")
        XCTAssertFalse(
            terminal.isFirstResponder,
            """
            A terminal hidden by setSessionDrawingEnabled(false) must release the \
            keyboard. UIKit does not resign a hidden first responder on its own, \
            and only one view per window can hold it — so a retained claim here \
            routes every keystroke into a session the user cannot see.
            """
        )
    }

    // MARK: - Defect 3 — is peer authority reachable without a second device?

    /// Defect 3 needs `sessionIsControlledElsewhere` (i.e.
    /// `effectiveGridAuthorityPeerName != nil`, SessionView.swift:3396-3398) to
    /// be true. That comes from `TmuxGridAuthoritySnapshot.classify`, which
    /// returns `.peer` for any stamp whose `deviceID != localDeviceID`
    /// (TmuxControlCore/Authority.swift:75-88).
    ///
    /// `localDeviceID` is `self.gridAuthorityIdentity?.id` — Optional. This test
    /// settles whether our OWN stamp classifies as a peer when the identity has
    /// not been assigned yet, which would make peer authority — and therefore
    /// the silent `onSend` block at SessionView.swift:7707 — reachable with no
    /// second device involved at all.
    func testOwnStampClassifiesAsPeerWhenLocalIdentityIsMissing() {
        let identity = TmuxGridAuthorityIdentity(id: "device-A", displayName: "My iPad")
        let stamp = TmuxGridAuthorityStamp(identity: identity, generation: 1)

        let withIdentity = TmuxGridAuthoritySnapshot.classify(
            rawValue: stamp.wireValue,
            localDeviceID: identity.id
        )
        XCTAssertFalse(
            withIdentity.isPeer,
            "sanity: our own stamp is ours once the identity is known"
        )

        let withoutIdentity = TmuxGridAuthoritySnapshot.classify(
            rawValue: stamp.wireValue,
            localDeviceID: nil
        )

        // RESULT: classify() does return .peer for a nil localDeviceID — but the
        // path is NOT reachable in production. The only call site that passes
        // `localDeviceID` is TmuxController.swift:4345, inside the re-derive
        // that `replayAttachInitClientSize()` gates on `participatesInGridAuthority`
        // (:3136-3138), which is itself `gridAuthorityIdentity != nil`. The
        // identity is never assigned nil — all three assignments are concrete
        // (SessionView.swift:2383, :4431, TesseraApp.swift:900).
        //
        // So defect 3's "reachable with no second device" claim is REFUTED.
        // Pinned as a sharp edge: if the participatesInGridAuthority gate is
        // ever removed, a nil identity would silently yield peer authority and
        // start dropping keystrokes at SessionView.swift:7707.
        XCTAssertTrue(
            withoutIdentity.isPeer,
            "classify() treats a nil localDeviceID as a peer — safe only because the caller is gated"
        )
    }

    // MARK: - Defect 2 — does a stale-true responder poison the repair?

    /// `restoreKeyboardFocusAfterActivation` (SessionView.swift:14891-14897)
    /// bails when any OTHER `UITextInput` in the window is first responder:
    ///
    ///     if candidate !== view, candidate.isFirstResponder, candidate is UITextInput { return true }
    ///     guard !hasOtherTextResponder(window) else { return }
    ///
    /// Background sessions stay mounted in the same window at `.opacity(0)`
    /// (ContentView.swift), hidden via `setSessionDrawingEnabled(false)`. The
    /// probe above shows a hidden terminal KEEPS first responder. If SwiftTerm's
    /// TerminalView is a UITextInput, then a hidden background terminal holding a
    /// stale-true responder satisfies that bail condition — and permanently
    /// disables the activation repair for the terminal the user is actually on.
    ///
    /// This test settles both ingredients.
    func testHiddenTerminalSatisfiesTheActivationRepairsBailCondition() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        let background = TesseraResponderAwareTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let foreground = TesseraResponderAwareTerminalView(frame: background.frame)
        window.rootViewController?.view.addSubview(background)
        window.rootViewController?.view.addSubview(foreground)

        XCTAssertTrue(background.becomeFirstResponder())
        background.setSessionDrawingEnabled(false)

        let isTextInput = background is UITextInput
        let stillFirstResponder = background.isFirstResponder

        print("""
        DEFECT2PROBE bailCondition hidden=\(background.isHidden) \
        stillFirstResponder=\(stillFirstResponder) isUITextInput=\(isTextInput)
        """)

        XCTAssertFalse(
            stillFirstResponder && isTextInput,
            """
            A hidden background terminal is still first responder AND is a \
            UITextInput, which is exactly hasOtherTextResponder()'s bail \
            condition. While this holds, restoreKeyboardFocusAfterActivation \
            returns early for the terminal the user is actually looking at, and \
            the only remaining repair is a SwiftUI update pass.
            """
        )
    }
}

// MARK: - Not reducible to a test at this commit
//
// Defect 2, second half — "isFirstResponder is true but keys are dead".
//   The test above pins only the precondition. Proving the rest needs a device
//   or simulator harness that (a) backgrounds the app, (b) lets the unguarded
//   reclaim run, (c) foregrounds, and (d) presses a real hardware key. XCUITest
//   cannot assert app-internal responder state across an activate() boundary,
//   so the observable would have to be a diagnostic line. The existing
//   `keyboard-input` breadcrumbs already discriminate it: insert-text present
//   means UIKit delivered and something downstream ate the bytes; insert-text
//   absent with focus-acquired standing means the input session is dead.
//
// Defect 3 — the mosh input gate and the take-over veil disagree.
//   `onSend` drops bytes on `!sessionIsControlledElsewhere`
//   (SessionView.swift:7707) while the veil that explains it additionally
//   requires `presentationSessionState == .connected` (:4059). Both predicates
//   are computed properties on the MoshSessionView struct, so neither is
//   reachable from a test. This needs the pair extracted into a pure policy
//   type — the pattern SavedHostAdmissionPolicy and SharedSessionPolicy already
//   use — after which the defect is a table test asserting the two agree for
//   every (authority, sessionState) pair.
//
// Defect 4, second half — "hardware keys die with the software keyboard".
//   The two tests above pin the latch's shape and the compact-width iPad scope.
//   The defect proper — that after `dismissSoftwareKeyboard()` a HARDWARE key no
//   longer reaches the terminal, and the only clears require the focus the latch
//   prevents — needs a real key press. Reachable from the existing
//   TESSERA_HARDWARE_KEY_HARNESS rig, which already drives hardware chords;
//   it would need a hide-keyboard affordance added to the harness view.
//
// Defect 5 — GCKeyboard singleton handler clobber.
//   `installHardwareKeyPassthroughIfNeeded` (SessionView.swift:15157) writes
//   the shared `GCKeyboard.coalesced` handler behind a per-coordinator
//   `hardwareKeyboard === keyboard` guard, so a coordinator that loses the
//   handler can never retake it. Needs two mosh coordinators and a real
//   coalesced keyboard; not reachable without injecting the GCKeyboard
//   dependency. Scope: `onHardwareKey` is non-nil only on the mosh session
//   surface (SessionView.swift:7792), so this needs two mosh sessions mounted,
//   and it costs PageUp/PageDown only — not all keys.
//
// Defect 6 — app-lock unlock has no reclaim of its own.
//   `LockScreenView.onAppear` resigns app-wide (Security/LockScreenView.swift:100);
//   `AppLockController.unlock()` only flips `isLocked` and nothing restores focus.
//   `restoreKeyboardFocusAfterActivation` cannot cover it: on a passcode-fallback
//   unlock `didBecomeActive` arrives while `isLocked` is still true, so
//   `inputAllowed()` is false and the one-shot bails; on a pure Face ID unlock
//   there is usually no `didBecomeActive` at all. What rescues it today is
//   incidental — `mainContent` reads `isLocked` (TesseraApp.swift:778), so the
//   root body re-evaluates and the non-Equatable `\.terminalInputAllowed` closure
//   at :604 compares as changed, invalidating every reader.
//   Not unit-testable: `unlock()` goes through `BiometricGate.evaluate`, which
//   needs LocalAuthentication.
//   STATUS DOWNGRADED: the resign half of this defect is not established. See
//   testGlobalResignActionDoesNotStripALiveTerminalsFirstResponder above — the
//   global idiom did not resign a live terminal in a synthetic key window. The
//   "and nothing brings it back" half still needs the full app, but the premise
//   that focus is lost at lock time now needs a device check first.
