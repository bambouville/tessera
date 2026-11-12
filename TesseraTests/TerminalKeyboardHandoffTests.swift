import Combine
import Foundation
import SwiftUI
import SwiftTerm
import UIKit
import XCTest
@testable import Tessera

@MainActor
final class TerminalKeyboardHandoffTests: XCTestCase {
    @MainActor
    private final class SurfaceState: ObservableObject {
        @Published var suppressed = true
        @Published var handoff: TerminalKeyboardHandoff? = nil
        @Published var mountsTerminal = true
        @Published var mountsSecondTerminal = false
        @Published var secondSuppressed = true
        @Published var coveringSheet = false
        @Published var updateID = 0
        var appliedUpdateID = -1
        var secondAppliedUpdateID = -1
        var mountCount = 0
        /// The update each primary-surface callback was installed by.
        var callbackUpdateIDs: [String: Int] = [:]
        weak var terminal: TesseraResponderAwareTerminalView?
        weak var secondTerminal: TesseraResponderAwareTerminalView?
    }

    private struct Host: View {
        @ObservedObject var state: SurfaceState
        let appearance: AppearancePreferences
        let shortcuts: ShortcutStore

        var body: some View {
            VStack(spacing: 0) {
                if state.mountsTerminal {
                    surface(isSecondary: false)
                }
                if state.mountsSecondTerminal {
                    surface(isSecondary: true)
                }
            }
            .environment(appearance)
            .environment(shortcuts)
            .environment(\.terminalKeyboardHandoff, state.handoff)
        }

        private func surface(isSecondary: Bool) -> some View {
            let updateID = state.updateID
            func record(_ callback: String) {
                if !isSecondary { state.callbackUpdateIDs[callback] = updateID }
            }
            return TerminalSurfaceBound(
                initialData: [],
                onMade: {
                    if isSecondary {
                        state.secondTerminal = $0 as? TesseraResponderAwareTerminalView
                    } else {
                        state.terminal = $0 as? TesseraResponderAwareTerminalView
                        state.mountCount += 1
                    }
                },
                onReady: { record("ready") },
                onSend: { _ in record("send") },
                onResize: { _, _ in record("resize") },
                onTitle: { _ in record("title") },
                onUserActivity: {
                    if isSecondary {
                        state.secondAppliedUpdateID = updateID
                    } else {
                        state.appliedUpdateID = updateID
                    }
                },
                onBell: { record("bell") },
                mouseReportingImpliesAltScreen: false,
                suppressDirectColorQueryResponses: true,
                tmuxShortcutsEnabled: false,
                onTmuxShortcut: { _ in },
                onFindShortcut: nil,
                onSwitcherShortcut: nil,
                onOpenSettings: nil,
                suppressFirstResponderReclaim: isSecondary ? state.secondSuppressed : state.suppressed,
                coveringSheetPresented: !isSecondary && state.coveringSheet,
                onHardwareKey: { _ in record("hardwareKey") }
            )
            .frame(width: 320, height: 120)
        }
    }

    @MainActor
    private final class Fixture {
        let state: SurfaceState
        let controller: UIHostingController<Host>
        let window: UIWindow
        let field: UITextField
        let secondField: UITextField
        let previousKeyWindow: UIWindow?

        init(scene: UIWindowScene, mountsTerminal: Bool) {
            state = SurfaceState()
            state.mountsTerminal = mountsTerminal
            controller = UIHostingController(rootView: Host(
                state: state,
                appearance: AppearancePreferences(),
                shortcuts: ShortcutStore()
            ))
            previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 600)
            window.rootViewController = controller
            field = UITextField(frame: CGRect(x: 20, y: 260, width: 300, height: 44))
            field.returnKeyType = .go
            secondField = UITextField(frame: CGRect(x: 20, y: 320, width: 300, height: 44))
            controller.view.addSubview(field)
            controller.view.addSubview(secondField)
            window.makeKeyAndVisible()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
    }

    // Even negative cases wait for the SwiftUI update and its deferred reclaim;
    // checking the field immediately after changing state would false-green.
    private func settle(
        _ controller: UIViewController,
        minimumDuration: TimeInterval = 0.15,
        timeout: TimeInterval = 3,
        until condition: () -> Bool
    ) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        var satisfiedAt: TimeInterval?
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            let now = ProcessInfo.processInfo.systemUptime
            if condition() {
                // Drain further turns after observing an update: its layout
                // may just have queued the asynchronous responder reclaim.
                if let satisfiedAt, now - satisfiedAt >= minimumDuration { return true }
                if satisfiedAt == nil { satisfiedAt = now }
            } else {
                satisfiedAt = nil
            }
        } while ProcessInfo.processInfo.systemUptime - start < timeout
        return false
    }

    private func makeFixture(mountsTerminal: Bool = true) throws -> Fixture {
        XCTAssertEqual(UIApplication.shared.applicationState, .active,
                       "keyboard reclaim requires an active test host")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive },
            "keyboard reclaim requires a foregroundActive UIWindowScene")
        let fixture = Fixture(scene: scene, mountsTerminal: mountsTerminal)
        // Clean up even if a prerequisite throws before returning the fixture.
        var ready = false
        defer { if !ready { fixture.close() } }
        // A cold terminal mount on a loaded machine can outlast the 3 s that
        // the behavior checks below allow; only this setup gets longer.
        XCTAssertTrue(settle(fixture.controller, timeout: 15) {
            fixture.window.isKeyWindow
                && (!mountsTerminal || fixture.state.terminal?.window === fixture.window)
        }, "the terminal test window never became key or mounted its surface")
        _ = try XCTUnwrap(fixture.window.isKeyWindow ? fixture.window : nil,
                          "keyboard reclaim requires a key window")
        if mountsTerminal {
            _ = try XCTUnwrap(fixture.state.terminal, "TerminalSurfaceBound never mounted")
        }
        XCTAssertTrue(fixture.field.becomeFirstResponder())
        XCTAssertTrue(settle(fixture.controller) { fixture.field.isFirstResponder },
                      "the stand-in palette field never acquired first responder")
        XCTAssertFalse(fixture.state.terminal?.isFirstResponder == true)
        ready = true
        return fixture
    }

    /// Cases about consumption, suppression and replay take a window a loaded
    /// simulator cannot outlast; only the expiry case uses the production one.
    private func publishHandoff(
        _ fixture: Fixture, age: TimeInterval = 0, validity: TimeInterval = 30
    ) {
        fixture.state.handoff = TerminalKeyboardHandoff(
            issuedAt: ProcessInfo.processInfo.systemUptime - age, validity: validity
        )
        fixture.state.updateID += 1
    }

    private func hasAppliedUpdate(_ fixture: Fixture, isSecondary: Bool = false) -> Bool {
        let terminal = isSecondary ? fixture.state.secondTerminal : fixture.state.terminal
        let coordinator = terminal?.terminalDelegate as? TerminalSurfaceBound.Coordinator
        // The callback captures the revision installed by make/updateUIView,
        // so an unchanged handoff still proves the representable was updated.
        coordinator?.onUserActivity?()
        let appliedUpdateID = isSecondary ? fixture.state.secondAppliedUpdateID : fixture.state.appliedUpdateID
        return appliedUpdateID == fixture.state.updateID
            && coordinator?.keyboardHandoff === fixture.state.handoff
    }

    private func assertFieldKeepsFocus(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(settle(fixture.controller) {
            hasAppliedUpdate(fixture)
        }, "the requested SwiftUI update never settled", file: file, line: line)
        XCTAssertTrue(fixture.field.window === fixture.window, file: file, line: line)
        XCTAssertTrue(fixture.field.isFirstResponder, file: file, line: line)
        XCTAssertFalse(fixture.state.terminal?.isFirstResponder == true, file: file, line: line)
    }

    func testLiveHandoffTransfersFocusWhilePaletteFieldRemainsMounted() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let terminal = try XCTUnwrap(fixture.state.terminal)

        fixture.state.suppressed = false
        publishHandoff(fixture)

        XCTAssertTrue(settle(fixture.controller) {
            hasAppliedUpdate(fixture) && terminal.isFirstResponder
        }, "a live handoff never transferred focus from the still-mounted field")
        XCTAssertTrue(terminal.isFirstResponder)
        XCTAssertFalse(fixture.field.isFirstResponder)
        XCTAssertTrue(fixture.field.window === fixture.window)
        XCTAssertEqual(fixture.state.mountCount, 1)
        XCTAssertTrue(try XCTUnwrap(fixture.state.handoff).isSpent)
    }

    func testNoHandoffPreservesOtherTextResponder() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }

        fixture.state.suppressed = false
        fixture.state.updateID += 1

        assertFieldKeepsFocus(fixture)
    }

    func testExpiredHandoffPreservesOtherTextResponder() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }

        fixture.state.suppressed = false
        publishHandoff(fixture, age: TerminalKeyboardHandoff.validityDuration + 1,
                       validity: TerminalKeyboardHandoff.validityDuration)

        assertFieldKeepsFocus(fixture)
    }

    func testConsumedHandoffCannotStealFocusAgain() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let terminal = try XCTUnwrap(fixture.state.terminal)
        fixture.state.suppressed = false
        publishHandoff(fixture)
        XCTAssertTrue(settle(fixture.controller, minimumDuration: 0.02) {
            terminal.isFirstResponder
        }, "the initial handoff was never consumed")
        let handoff = try XCTUnwrap(fixture.state.handoff)
        XCTAssertTrue(handoff.isSpent, "successful reclaim must spend before another field begins editing")

        XCTAssertTrue(fixture.field.becomeFirstResponder())
        fixture.state.updateID += 1
        assertFieldKeepsFocus(fixture)

        XCTAssertTrue(fixture.state.handoff === handoff)
        XCTAssertTrue(handoff.isSpent)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - handoff.issuedAt, handoff.validity,
                          "this case must exercise consumption before the handoff expires")
        XCTAssertEqual(fixture.state.mountCount, 1)
    }

    func testSuppressionStillBlocksLiveHandoff() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }

        publishHandoff(fixture)

        XCTAssertTrue(fixture.state.suppressed)
        assertFieldKeepsFocus(fixture)
        let handoff = try XCTUnwrap(fixture.state.handoff)
        XCTAssertTrue(handoff.isLive, "suppression must block an otherwise live handoff")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - handoff.issuedAt, handoff.validity,
                          "this case must exercise suppression before the handoff expires")
    }

    func testCoveringSheetYieldsFocusOnceAndReturnsItOnClose() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let terminal = try XCTUnwrap(fixture.state.terminal)
        XCTAssertTrue(fixture.field.resignFirstResponder())
        fixture.state.suppressed = false
        fixture.state.updateID += 1
        XCTAssertTrue(settle(fixture.controller) { terminal.isFirstResponder },
                      "the unsuppressed terminal never reclaimed focus")

        fixture.state.coveringSheet = true
        fixture.state.updateID += 1
        XCTAssertTrue(settle(fixture.controller) {
            hasAppliedUpdate(fixture) && !terminal.isFirstResponder
        }, "raising the sheet must resign the terminal and hold reclaim off")

        // A terminal tap under the open sheet takes focus; later updates
        // while the sheet stays up must not strip it again.
        XCTAssertTrue(terminal.becomeFirstResponder())
        fixture.state.updateID += 1
        XCTAssertTrue(settle(fixture.controller) {
            hasAppliedUpdate(fixture) && terminal.isFirstResponder
        }, "focus taken under the sheet was resigned again")

        XCTAssertTrue(terminal.resignFirstResponderForTransition())
        fixture.state.updateID += 1
        XCTAssertTrue(settle(fixture.controller) {
            hasAppliedUpdate(fixture) && !terminal.isFirstResponder
        }, "the open sheet must keep holding reclaim off")
        fixture.state.coveringSheet = false
        fixture.state.updateID += 1
        XCTAssertTrue(settle(fixture.controller) {
            hasAppliedUpdate(fixture) && terminal.isFirstResponder
        }, "closing the sheet never returned focus to the terminal")
    }

    func testLiveHandoffReachesNewlyMountedSurface() throws {
        let fixture = try makeFixture(mountsTerminal: false)
        defer { fixture.close() }

        fixture.state.suppressed = false
        fixture.state.mountsTerminal = true
        publishHandoff(fixture)

        // The make/update reclaims can run before SwiftUI attaches the new
        // surface; record each prerequisite change for a failure report.
        let start = ProcessInfo.processInfo.systemUptime
        var trace: [String] = []
        let acquired = settle(fixture.controller) {
            let terminal = fixture.state.terminal
            let coordinator = terminal?.terminalDelegate as? TerminalSurfaceBound.Coordinator
            let sample = "inWindow=\(terminal?.window === fixture.window) keyWindow=\(fixture.window.isKeyWindow) "
                + "handoffLive=\(fixture.state.handoff?.isLive == true) "
                + "permitsReclaim=\(coordinator?.permitsFirstResponderReclaim == true) "
                + "fieldFocused=\(fixture.field.isFirstResponder)"
            if trace.last?.hasSuffix(sample) != true {
                trace.append(String(format: "%.3fs ", ProcessInfo.processInfo.systemUptime - start) + sample)
            }
            return terminal?.isFirstResponder == true
        }
        XCTAssertTrue(acquired, "a pane mounted during the handoff never acquired first responder:\n"
                      + trace.joined(separator: "\n"))
        XCTAssertFalse(fixture.field.isFirstResponder)
        XCTAssertTrue(fixture.field.window === fixture.window)
        XCTAssertEqual(fixture.state.mountCount, 1)
    }

    func testSurfaceAttachedAfterItsDeferredReclaimTakesLiveHandoff() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let terminal = try XCTUnwrap(fixture.state.terminal)
        let container = try XCTUnwrap(terminal.superview)

        // Detach so the update's deferred reclaims certainly run without a
        // window, as when SwiftUI has not yet attached a newly mounted pane.
        terminal.removeFromSuperview()
        fixture.state.suppressed = false
        publishHandoff(fixture)
        XCTAssertTrue(settle(fixture.controller) {
            hasAppliedUpdate(fixture)
        }, "the requested SwiftUI update never settled")
        XCTAssertNil(terminal.window)
        XCTAssertTrue(fixture.field.isFirstResponder)
        let handoff = try XCTUnwrap(fixture.state.handoff)
        XCTAssertTrue(handoff.isLive, "this case must reattach before the handoff expires")

        // No further SwiftUI update follows: only the attach retry can reclaim.
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        XCTAssertTrue(settle(fixture.controller, minimumDuration: 0.02) {
            terminal.isFirstResponder
        }, "attaching the surface never retried its deferred reclaim")
        XCTAssertFalse(fixture.field.isFirstResponder)
        XCTAssertTrue(handoff.isSpent)
        XCTAssertEqual(fixture.state.mountCount, 1)
    }

    func testConsumedHandoffCannotBeReplayedAcrossSurfaces() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        fixture.state.mountsSecondTerminal = true
        XCTAssertTrue(settle(fixture.controller, minimumDuration: 0.02) {
            fixture.state.secondTerminal?.window === fixture.window
        }, "the second TerminalSurfaceBound never mounted")
        let firstTerminal = try XCTUnwrap(fixture.state.terminal)
        let secondTerminal = try XCTUnwrap(fixture.state.secondTerminal)
        XCTAssertFalse(firstTerminal === secondTerminal)
        XCTAssertTrue(fixture.state.secondSuppressed)

        fixture.state.suppressed = false
        publishHandoff(fixture)
        let handoff = try XCTUnwrap(fixture.state.handoff)
        XCTAssertTrue(settle(fixture.controller, minimumDuration: 0.02) {
            hasAppliedUpdate(fixture) && firstTerminal.isFirstResponder
        }, "surface A never consumed the shared handoff")
        // Assert before refocusing: that field's begin-editing notification
        // would otherwise conceal a failure to spend on successful reclaim.
        XCTAssertTrue(handoff.isSpent)
        XCTAssertFalse(secondTerminal.isFirstResponder)

        fixture.state.suppressed = true
        XCTAssertTrue(fixture.field.becomeFirstResponder())
        fixture.state.secondSuppressed = false
        fixture.state.updateID += 1
        XCTAssertTrue(settle(fixture.controller) {
            hasAppliedUpdate(fixture) && hasAppliedUpdate(fixture, isSecondary: true)
        }, "both surfaces must apply the focus switch and drain deferred reclaim")

        XCTAssertTrue(fixture.state.handoff === handoff)
        XCTAssertTrue(fixture.field.isFirstResponder)
        XCTAssertFalse(firstTerminal.isFirstResponder)
        XCTAssertFalse(secondTerminal.isFirstResponder,
                       "surface B must not replay a handoff consumed by surface A")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - handoff.issuedAt, handoff.validity,
                          "this case must exercise shared consumption before expiry")
    }

    func testNewTextInputRevokesPaletteHandoffBeforeTerminalReclaim() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let palette = CommandPalette()
        palette.open(sessions: [])
        palette.close()
        let handoff = try XCTUnwrap(palette.keyboardHandoff)
        fixture.state.handoff = handoff
        XCTAssertTrue(fixture.state.suppressed)
        XCTAssertTrue(handoff.isLive)

        // A real responder transfer exercises the observers installed by the
        // production palette-close path, without posting a synthetic notice.
        XCTAssertTrue(fixture.secondField.becomeFirstResponder())
        XCTAssertTrue(fixture.secondField.isFirstResponder)
        XCTAssertTrue(handoff.isSpent, "a new text input must revoke the palette handoff")
        XCTAssertFalse(handoff.isLive)
        // The palette's own window: measured where revocation is checked, since
        // the settle below can outlast it on a loaded simulator.
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - handoff.issuedAt, handoff.validity,
                          "this case must exercise editing revocation before expiry")

        fixture.state.suppressed = false
        fixture.state.updateID += 1
        XCTAssertTrue(settle(fixture.controller) {
            hasAppliedUpdate(fixture)
        }, "the terminal update and deferred reclaim never settled")
        XCTAssertTrue(fixture.secondField.window === fixture.window)
        XCTAssertTrue(fixture.secondField.isFirstResponder)
        XCTAssertFalse(fixture.field.isFirstResponder)
        XCTAssertFalse(fixture.state.terminal?.isFirstResponder == true)
    }

    /// The coordinator outlives the view values SwiftUI makes on every state
    /// change. A callback kept from the first would act on that first state:
    /// a resize after an iPad grew out of compact went out under the compact
    /// guard and never reached the server.
    func testEveryTerminalCallbackActsOnTheLatestUpdate() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        for _ in 0..<2 {
            fixture.state.updateID += 1
            XCTAssertTrue(settle(fixture.controller) { hasAppliedUpdate(fixture) }, "the update never applied")
        }
        let coordinator = try XCTUnwrap(fixture.state.terminal?.terminalDelegate as? TerminalSurfaceBound.Coordinator)
        fixture.state.callbackUpdateIDs = [:]
        coordinator.onReady()
        coordinator.onSend([0x61][...])
        coordinator.onResize(80, 24)
        coordinator.onTitle("title")
        coordinator.onBell?()
        coordinator.onHardwareKey?(.pageUp)
        let latest = fixture.state.updateID
        XCTAssertEqual(fixture.state.callbackUpdateIDs, ["ready": latest, "send": latest, "resize": latest,
                                                         "title": latest, "bell": latest, "hardwareKey": latest])
    }

    func testPaletteClosePublishesOncePerOpenToClosedTransition() {
        let palette = CommandPalette()
        XCTAssertNil(palette.keyboardHandoff)
        palette.close()
        XCTAssertNil(palette.keyboardHandoff)

        palette.open(sessions: [])
        XCTAssertNil(palette.keyboardHandoff)
        let beforeClose = ProcessInfo.processInfo.systemUptime
        palette.close()
        guard let first = palette.keyboardHandoff else {
            XCTFail("closing an open palette must publish a handoff")
            return
        }
        XCTAssertFalse(palette.isOpen)
        XCTAssertEqual(first.validity, TerminalKeyboardHandoff.validityDuration)
        XCTAssertGreaterThanOrEqual(first.issuedAt, beforeClose)
        XCTAssertLessThanOrEqual(first.issuedAt, ProcessInfo.processInfo.systemUptime)
        palette.close()
        XCTAssertTrue(palette.keyboardHandoff === first)

        palette.open(sessions: [])
        XCTAssertTrue(palette.keyboardHandoff === first)
        let beforeSecondClose = ProcessInfo.processInfo.systemUptime
        palette.close()
        guard let second = palette.keyboardHandoff else {
            XCTFail("a second close transition must publish a handoff")
            return
        }
        XCTAssertFalse(second === first)
        XCTAssertGreaterThanOrEqual(second.issuedAt, beforeSecondClose)
        XCTAssertLessThanOrEqual(second.issuedAt, ProcessInfo.processInfo.systemUptime)
    }
}
