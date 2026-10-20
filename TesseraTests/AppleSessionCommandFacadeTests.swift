import Combine
import Foundation
import SwiftUI
import SwiftTerm
import TesseraCore
import TmuxControl
import UIKit
import XCTest
@testable import Citadel
@testable import Tessera

@MainActor
final class AppleSessionCommandFacadeTests: XCTestCase {
    func testBackgroundTerminalCleanupDoesNotResignAnotherViewsFirstResponder() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        let background = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let foreground = TesseraResponderAwareTerminalView(frame: background.frame)
        let field = UITextField(frame: CGRect(x: 0, y: 320, width: 300, height: 44))
        for view in [background, foreground, field] {
            window.rootViewController?.view.addSubview(view)
        }
        let box = TerminalBox(traceLabel: "keyboard-background-test")
        box.attach(background)
        background.setSessionDrawingEnabled(false)
        XCTAssertTrue(foreground.becomeFirstResponder())
        box.dismissTransientInteractions()
        XCTAssertTrue(foreground.isFirstResponder, "Retiring a hidden terminal must not end another terminal's input session")
        XCTAssertTrue(field.becomeFirstResponder())
        box.dismissTransientInteractions()
        XCTAssertTrue(field.isFirstResponder, "Background cleanup must not dismiss a local text field")
        background.setSessionDrawingEnabled(true)
        XCTAssertTrue(background.becomeFirstResponder())
        box.dismissTransientInteractions()
        XCTAssertFalse(background.isFirstResponder, "Cleanup must still dismiss its own input session")
    }

    func testSSHPublicationDoesNotWaitForMainActorAndPreservesAttemptOrder() async {
        let session = SSHSession(host: Host(id: UUID(), transport: .ssh))
        let first = UUID()
        let second = UUID()
        let published = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session._publishPTYOutputForTesting([1, 2], attemptID: first)
            session._publishPTYOutputForTesting([3, 4], attemptID: second)
            published.signal()
        }
        // Deliberately hold MainActor: the real SSH publication seam must not
        // need this actor even once to make progress. No network is opened.
        XCTAssertEqual(published.wait(timeout: .now() + 1), .success)
        var iterator = session.appleAttemptOutputEvents.makeAsyncIterator()
        let one = await iterator.next()
        let two = await iterator.next()
        XCTAssertEqual(one?.attemptID, first)
        XCTAssertEqual(one?.bytes, [1, 2])
        XCTAssertEqual(two?.attemptID, second)
        XCTAssertEqual(two?.bytes, [3, 4])
    }

    func testCoreGraphicsDrawHookPreservesSwiftTermPixelOutputAndForwardsOnce() {
        let defaults = UserDefaults.standard
        let key = DiagnosticLogStore.verboseDiagnosticsDefaultsKey
        let previousVerboseValue = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previousVerboseValue {
                defaults.set(previousVerboseValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        let control = TerminalView(frame: frame)
        let instrumented = TesseraResponderAwareTerminalView(frame: frame)
        instrumented.bindLatencyDiagnostics(host: UUID())
        XCTAssertFalse(instrumented.isUsingMetalRenderer)

        // Hide the blinking cursor so the two independent views have stable,
        // byte-for-byte comparable backing-store pixels.
        let bytes = Array("\u{1b}[?25lrenderer-hook\r\n$ ".utf8)
        control.feed(byteArray: bytes[...])
        instrumented.feed(byteArray: bytes[...])

        func renderedPixels(of view: UIView) -> Data? {
            view.layoutIfNeeded()
            view.setNeedsDisplay(view.bounds)
            view.layer.displayIfNeeded()
            let image = UIGraphicsImageRenderer(size: view.bounds.size).image { context in
                view.layer.render(in: context.cgContext)
            }
            guard let pixels = image.cgImage?.dataProvider?.data else { return nil }
            return pixels as Data
        }

        let controlPixels = renderedPixels(of: control)
        let entryCountBefore = instrumented.latencyDrawCallbackEntryCount
        let forwardedCountBefore = instrumented.latencyDrawForwardedCallCount
        let instrumentedPixels = renderedPixels(of: instrumented)

        XCTAssertNotNil(controlPixels)
        XCTAssertEqual(instrumentedPixels, controlPixels)
        XCTAssertEqual(
            instrumented.latencyDrawCallbackEntryCount - entryCountBefore,
            1,
            "one UIKit display must enter the diagnostic trampoline once"
        )
        XCTAssertEqual(
            instrumented.latencyDrawForwardedCallCount - forwardedCountBefore,
            1,
            "the trampoline must invoke SwiftTerm's saved draw IMP exactly once"
        )
    }

    func testCoreGraphicsDrawHookPassesThroughWithoutVerboseDiagnostics() {
        let defaults = UserDefaults.standard
        let key = DiagnosticLogStore.verboseDiagnosticsDefaultsKey
        let previousVerboseValue = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let previousVerboseValue {
                defaults.set(previousVerboseValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        let control = TerminalView(frame: frame)
        let container = TesseraTerminalContainer(frame: frame)
        let instrumented = container.terminalView
        container.layoutIfNeeded()
        XCTAssertTrue(instrumented.sessionDrawingEnabled)
        XCTAssertGreaterThan(instrumented.bounds.width, 0)
        XCTAssertGreaterThan(instrumented.bounds.height, 0)

        let bytes = Array("\u{1b}[?25lnon-verbose-pass-through\r\n$ ".utf8)
        control.feed(byteArray: bytes[...])
        instrumented.feed(byteArray: bytes[...])

        func renderedPixels(of view: UIView) -> Data? {
            view.layoutIfNeeded()
            view.setNeedsDisplay(view.bounds)
            view.layer.displayIfNeeded()
            let image = UIGraphicsImageRenderer(size: view.bounds.size).image { context in
                view.layer.render(in: context.cgContext)
            }
            guard let pixels = image.cgImage?.dataProvider?.data else { return nil }
            return pixels as Data
        }

        let controlPixels = renderedPixels(of: control)
        let entryCountBefore = instrumented.latencyDrawCallbackEntryCount
        let forwardedCountBefore = instrumented.latencyDrawForwardedCallCount
        let instrumentedPixels = renderedPixels(of: instrumented)

        XCTAssertNotNil(controlPixels)
        XCTAssertEqual(instrumentedPixels, controlPixels)
        XCTAssertEqual(instrumented.latencyDrawCallbackEntryCount - entryCountBefore, 1)
        XCTAssertEqual(instrumented.latencyDrawForwardedCallCount - forwardedCountBefore, 1)
    }

    func testHiddenTerminalKeepsBufferCurrentWithoutDrawingAndRepaintsOnUnhide() async throws {
        let defaults = UserDefaults.standard
        let key = DiagnosticLogStore.verboseDiagnosticsDefaultsKey
        let previousVerboseValue = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previousVerboseValue {
                defaults.set(previousVerboseValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            return XCTFail("the renderer test requires the test host's UIWindowScene")
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let reference = TesseraTerminalContainer(
            frame: CGRect(x: 0, y: 0, width: 320, height: 240)
        )
        let candidate = TesseraTerminalContainer(
            frame: CGRect(x: 0, y: 0, width: 320, height: 240)
        )
        // SwiftTerm's bare initializer uses a transparent native canvas.
        // Session surfaces immediately replace that with the normal opaque
        // theme canvas; mirror production here so repeated incremental draws
        // cannot accumulate alpha differently from the reveal's full repaint.
        for container in [reference, candidate] {
            container.backgroundColor = .black
            container.isOpaque = true
            container.terminalView.nativeBackgroundColor = .black
            container.terminalView.nativeForegroundColor = .lightGray
            container.terminalView.backgroundColor = .black
            container.terminalView.isOpaque = true
        }
        let hosting = UIHostingController(rootView: TerminalOpacityHarness(
            reference: reference,
            candidate: candidate,
            candidateVisible: false
        ))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 640, height: 240)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        hosting.view.frame = window.bounds
        hosting.view.layoutIfNeeded()
        reference.layoutIfNeeded()
        candidate.layoutIfNeeded()
        XCTAssertNotNil(reference.window)
        XCTAssertNotNil(candidate.window)
        reference.terminalView.bindLatencyDiagnostics(host: UUID())
        candidate.terminalView.bindLatencyDiagnostics(host: UUID())

        func attachWindowImage(named name: String) {
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { context in
                window.layer.render(in: context.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let initial = Array("\u{1b}[?25lbefore-hidden\r\n".utf8)
        let referenceDrawsBefore = reference.terminalView.latencyDrawForwardedCallCount
        reference.terminalView.feed(byteArray: initial[...])
        let alphaDrawsBefore = candidate.terminalView.latencyDrawForwardedCallCount
        candidate.terminalView.feed(byteArray: initial[...])
        await assertEventually {
            reference.terminalView.latencyDrawForwardedCallCount > referenceDrawsBefore
        }
        await assertEventually {
            candidate.terminalView.latencyDrawForwardedCallCount > alphaDrawsBefore
        }
        attachWindowImage(named: "terminal-opacity-zero-baseline")
        let contentOffsetBeforeHidden = candidate.terminalView.contentOffset

        // Let the alpha-hidden view finish any already-scheduled display before
        // measuring the stronger UIKit visibility gate proposed for production.
        candidate.terminalView.setSessionDrawingEnabled(false)
        XCTAssertFalse(candidate.terminalView.sessionDrawingEnabled)
        try await Task.sleep(for: .milliseconds(100))
        let hiddenEntriesBefore = candidate.terminalView.latencyDrawCallbackEntryCount
        let hiddenDrawsBefore = candidate.terminalView.latencyDrawForwardedCallCount
        let additional = Array("while-hidden\r\nafter-hidden\r\n$ ".utf8)
        reference.terminalView.feed(byteArray: additional[...])
        candidate.terminalView.feed(byteArray: additional[...])
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(
            candidate.terminalView.latencyDrawForwardedCallCount,
            hiddenDrawsBefore,
            "the renderer gate must suppress inherited CoreGraphics work while output keeps arriving"
        )
        NSLog(
            "[TesseraTest] hidden-draw callbackEntryDelta=%d gatedForwardedDelta=%d",
            candidate.terminalView.latencyDrawCallbackEntryCount - hiddenEntriesBefore,
            candidate.terminalView.latencyDrawForwardedCallCount - hiddenDrawsBefore
        )
        XCTAssertEqual(
            candidate.terminalView.getTerminal().buffer.x,
            reference.terminalView.getTerminal().buffer.x
        )
        XCTAssertEqual(
            candidate.terminalView.getTerminal().buffer.y,
            reference.terminalView.getTerminal().buffer.y
        )

        hosting.rootView = TerminalOpacityHarness(
            reference: reference,
            candidate: candidate,
            candidateVisible: true
        )
        try await Task.sleep(for: .milliseconds(20))
        candidate.terminalView.setSessionDrawingEnabled(true)
        XCTAssertTrue(candidate.terminalView.sessionDrawingEnabled)
        await assertEventually {
            candidate.terminalView.latencyDrawForwardedCallCount > hiddenDrawsBefore
        }
        XCTAssertEqual(
            candidate.terminalView.contentOffset.x,
            contentOffsetBeforeHidden.x,
            accuracy: 0.5
        )
        XCTAssertEqual(
            candidate.terminalView.contentOffset.y,
            contentOffsetBeforeHidden.y,
            accuracy: 0.5,
            "reveal repaint must not move the reader's viewport"
        )
        attachWindowImage(named: "terminal-unhidden-repaint")

        func pixels(of view: UIView) -> Data? {
            view.layer.displayIfNeeded()
            let image = UIGraphicsImageRenderer(size: view.bounds.size).image { context in
                view.layer.render(in: context.cgContext)
            }
            guard let pixels = image.cgImage?.dataProvider?.data else { return nil }
            return pixels as Data
        }

        let candidatePixels = pixels(of: candidate.terminalView)
        let referencePixels = pixels(of: reference.terminalView)
        let cursorParity = candidate.terminalView.getTerminal().buffer.x
            == reference.terminalView.getTerminal().buffer.x
            && candidate.terminalView.getTerminal().buffer.y
            == reference.terminalView.getTerminal().buffer.y
        let pixelParity = candidatePixels != nil && candidatePixels == referencePixels
        NSLog(
            "[TesseraTest] unhide-output-parity cursor=%@ pixels=%@",
            cursorParity.description,
            pixelParity.description
        )
        XCTAssertTrue(cursorParity)
        XCTAssertNotNil(referencePixels)
        XCTAssertTrue(
            pixelParity,
            "the unhidden catch-up repaint must match a continuously visible terminal"
        )
    }

    func testTerminalSurfaceBoundInitiallyHiddenStillReachesReadyGeometry() async throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            return XCTFail("the terminal surface test requires the test host's UIWindowScene")
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let appearance = AppearancePreferences()
        let shortcuts = ShortcutStore()
        var madeView: TesseraResponderAwareTerminalView?
        var readyCount = 0
        let terminalSurface = TerminalSurfaceBound(
            initialData: Array("\u{1b}[?25linitially-hidden\r\n".utf8),
            onMade: { madeView = $0 as? TesseraResponderAwareTerminalView },
            onReady: { readyCount += 1 },
            onSend: { _ in },
            onResize: { _, _ in },
            onTitle: { _ in },
            onUserActivity: nil,
            onBell: nil,
            mouseReportingImpliesAltScreen: false,
            suppressDirectColorQueryResponses: true,
            tmuxShortcutsEnabled: false,
            onTmuxShortcut: { _ in },
            onFindShortcut: nil,
            onSwitcherShortcut: nil,
            onOpenSettings: nil,
            suppressFirstResponderReclaim: true,
            onHardwareKey: nil
        )
        let initiallyHiddenSurface = terminalSurface
            .frame(width: 320, height: 240)
            .environment(appearance)
            .environment(shortcuts)
            .environment(\.terminalDrawingEnabled, false)
        let hosting = UIHostingController(rootView: initiallyHiddenSurface)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        hosting.view.frame = window.bounds
        hosting.view.layoutIfNeeded()
        await assertEventually {
            madeView != nil && readyCount == 1
        }
        guard let initiallyMadeView = madeView else {
            return XCTFail("TerminalSurfaceBound did not make its view")
        }
        XCTAssertFalse(initiallyMadeView.sessionDrawingEnabled)
        XCTAssertGreaterThan(initiallyMadeView.bounds.width, 0)
        XCTAssertGreaterThan(initiallyMadeView.bounds.height, 0)
        XCTAssertGreaterThan(initiallyMadeView.getTerminal().cols, 0)
        XCTAssertGreaterThan(initiallyMadeView.getTerminal().rows, 0)
        XCTAssertEqual(readyCount, 1)

        hosting.rootView = terminalSurface
            .frame(width: 320, height: 240)
            .environment(appearance)
            .environment(shortcuts)
            .environment(\.terminalDrawingEnabled, true)
        await assertEventually {
            initiallyMadeView.sessionDrawingEnabled
        }
        XCTAssertTrue(madeView === initiallyMadeView)
        XCTAssertEqual(readyCount, 1, "visibility updates must not remount the terminal")

        hosting.rootView = terminalSurface
            .frame(width: 320, height: 240)
            .environment(appearance)
            .environment(shortcuts)
            .environment(\.terminalDrawingEnabled, false)
        await assertEventually {
            !initiallyMadeView.sessionDrawingEnabled
        }
        XCTAssertTrue(madeView === initiallyMadeView)
        XCTAssertEqual(readyCount, 1, "visibility updates must not remount the terminal")
    }

    func testTTYDiagnosticsLocatesUnconsumedSocketBacklog() {
        let d = TTYOutputDiagnostics()
        d.received(bytes: 10, nanos: 1_000_000)
        d.received(bytes: 20, nanos: 2_000_000)
        let blocked = d.snapshot(nanos: 5_001_000_000, resetWindow: true)
        XCTAssertEqual(blocked.pendingChunks, 2)
        XCTAssertEqual(blocked.pendingBytes, 30)
        XCTAssertEqual(blocked.oldestPendingMs, 5_000)
        d.consumed(bytes: 10, nanos: 5_002_000_000)
        let drained = d.snapshot(nanos: 5_003_000_000, resetWindow: true)
        XCTAssertEqual(drained.pendingChunks, 1)
        XCTAssertEqual(drained.pendingBytes, 20)
        XCTAssertEqual(drained.maximumReadWaitMs, 5_001)
        XCTAssertEqual(drained.oldestPendingMs, 5_001)
    }

    func testSharedCommandsDriveLegacyTransportPrimitivesExactly() async {
        let hostID = UUID()
        let session = CommandRecordingSession(hostID: hostID)
        let facade = AppleSessionCommandFacade(session: session)
        let intent = ConnectionIntent(
            requestID: UUID(),
            hostID: hostID,
            policyGeneration: 19
        )

        XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        XCTAssertEqual(session.appleActiveSessionAttemptID, intent.requestID)
        session.projectState(.connected)
        await assertEventually { facade.state == .connected }

        let input = Data([0x00, 0x1b, 0x41, 0xff])
        XCTAssertEqual(facade.dispatch(.sendInput(input)), .handled)
        await assertEventually { session.sentInputs == [[0x00, 0x1b, 0x41, 0xff]] }

        // A compact iPhone viewport must cross this boundary unchanged.
        XCTAssertEqual(facade.dispatch(.resize(columns: 37, rows: 12)), .handled)
        await assertEventually { session.resizeRequests.count == 1 }
        XCTAssertEqual(session.resizeRequests.first?.columns, 37)
        XCTAssertEqual(session.resizeRequests.first?.rows, 12)

        XCTAssertEqual(facade.dispatch(.disconnect), .handled)
        await assertEventually { session.disconnectCallCount == 1 }
    }

    func testSubscribeBeforeConnectSeesOrderedIdempotentStateProjection() async {
        let session = CommandRecordingSession(hostID: UUID())
        let facade = AppleSessionCommandFacade(session: session)
        let recorder = SessionEventRecorder()
        let task = recordEvents(from: facade, into: recorder)
        let intent = ConnectionIntent(hostID: session.host.id, policyGeneration: 7)

        XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        // The backend publisher and the explicit post-connect sample both
        // report connecting; manual duplicate projections must remain inert.
        session.projectState(.connecting)
        session.projectState(.connected)
        session.projectState(.connected)

        await assertEventually {
            recorder.states == [
                .idle,
                .connecting(attemptID: intent.requestID),
                .connected,
            ]
        }
        task.cancel()
    }

    func testBackendConnectThatRemainsIdleReturnsSharedStateToIdleAndCanRetry() async {
        let session = CommandRecordingSession(hostID: UUID())
        session.stateAfterConnect = .idle
        let facade = AppleSessionCommandFacade(session: session)
        let recorder = SessionEventRecorder()
        let task = recordEvents(from: facade, into: recorder)

        facade.connect()
        await assertEventually {
            session.connectCallCount == 1 && facade.state == .idle
                && recorder.states.count >= 3
        }
        facade.connect()
        await assertEventually {
            session.connectCallCount == 2 && facade.state == .idle
                && recorder.states.count >= 5
        }

        XCTAssertEqual(recorder.states, [
            .idle,
            .connecting(attemptID: session.startedAttemptIDs[0]),
            .idle,
            .connecting(attemptID: session.startedAttemptIDs[1]),
            .idle,
        ])
        task.cancel()
    }

    func testFacadeLookupOfInitialIdleSessionDoesNotConnect() async {
        let session = CommandRecordingSession(hostID: UUID())

        _ = AppleSessionCommandFacade(session: session)
        _ = AppleSessionCommandFacade(session: session)
        await Task.yield()

        XCTAssertEqual(session.connectCallCount, 0)
        XCTAssertEqual(session.state, .idle)
    }

    func testStaleIdleProjectionCannotRewindNewerFacadeAttempt() async {
        let session = CommandRecordingSession(hostID: UUID())
        let facade = AppleSessionCommandFacade(session: session)
        let first = ConnectionIntent(hostID: session.host.id, policyGeneration: 1)
        let second = ConnectionIntent(hostID: session.host.id, policyGeneration: 2)

        XCTAssertEqual(facade.dispatch(.connect(first)), .handled)
        await assertEventually {
            session.connectCallCount == 1
                && facade.state == .connecting(attemptID: first.requestID)
        }
        session.projectState(.disconnected)
        XCTAssertEqual(facade.dispatch(.connect(second)), .handled)
        await assertEventually {
            session.connectCallCount == 2
                && facade.state == .connecting(attemptID: second.requestID)
        }

        session.tagAttempt(first.requestID)
        session.projectState(.idle)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(facade.state, .connecting(attemptID: second.requestID))
    }

    func testConnectForAnotherHostIsRejectedWithoutTouchingTransport() async {
        let session = CommandRecordingSession(hostID: UUID())
        let facade = AppleSessionCommandFacade(session: session)
        let otherHostIntent = ConnectionIntent(hostID: UUID(), policyGeneration: 1)

        XCTAssertEqual(facade.dispatch(.connect(otherHostIntent)), .rejectedHost)
        await Task.yield()
        XCTAssertEqual(session.connectCallCount, 0)
    }

    func testCancellationAndDestructionUseReleasedDisconnectPath() async {
        let session = CommandRecordingSession(hostID: UUID())
        let facade = AppleSessionCommandFacade(session: session)
        let intent = ConnectionIntent(hostID: session.host.id, policyGeneration: 2)

        XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        XCTAssertEqual(facade.dispatch(.cancelConnect(attemptID: intent.requestID)), .handled)
        await assertEventually { session.disconnectCallCount == 1 }
        XCTAssertEqual(facade.dispatch(.destroy), .handled)
        await assertEventually { session.disconnectCallCount == 2 }
    }

    func testDisconnectRetainsRemovedSessionUntilBackendOperationCompletes() async {
        let probe = DisconnectCallProbe()
        var session: CommandRecordingSession? = CommandRecordingSession(
            hostID: UUID(),
            disconnectProbe: probe
        )
        weak var weakSession = session
        let facade = AppleSessionCommandFacade(session: session!)

        facade.disconnect()
        session = nil

        await assertEventually { probe.count == 1 }
        await assertEventually { weakSession == nil }
    }

    func testTmuxLifecycleAndChallengeCommandsUseExplicitAppleAdapters() async {
        let session = CommandRecordingSession(hostID: UUID())
        let tmux = TmuxController(controlPath: .sideChannel)
        let fixture = await makeHostKeyFixture()
        var challenge: ChallengeResponse?
        var projectedChallengeID: UUID?
        let facade = AppleSessionCommandFacade(
            session: session,
            tmux: tmux,
            challengeResponder: { challenge = $0 }
        )
        let challengeCancellable = facade.challengeRequests.sink {
            projectedChallengeID = $0?.id
        }
        let intent = ConnectionIntent(hostID: session.host.id, policyGeneration: 3)
        XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        session.projectState(.connected)
        await assertEventually { facade.state == .connected }

        XCTAssertEqual(facade.dispatch(.selectTmuxWindow("@1")), .handled)
        XCTAssertEqual(facade.dispatch(.selectTmuxPane("%2")), .handled)
        XCTAssertEqual(facade.dispatch(.sendTmuxPaneInput(
            data: Data([0x41]),
            paneID: "%2",
            receipt: nil
        )), .handled)
        XCTAssertEqual(facade.dispatch(.sendTmuxPaneKey(
            .escape,
            paneID: "%2",
            receipt: nil
        )), .handled)
        XCTAssertEqual(facade.dispatch(.createTmuxWindow), .handled)
        XCTAssertEqual(facade.dispatch(.closeTmuxWindow("@1")), .handled)
        XCTAssertEqual(facade.dispatch(.closeTmuxPane("%2")), .handled)
        XCTAssertEqual(facade.dispatch(.splitTmuxPane("%2", axis: .vertical, before: false)), .handled)
        XCTAssertEqual(facade.dispatch(.cycleTmuxPane(forward: true)), .handled)
        XCTAssertEqual(facade.dispatch(.setTmuxPaneZoomed("%2", zoomed: true)), .handled)
        XCTAssertEqual(facade.dispatch(.renameTmuxWindow("@1", name: "work")), .handled)
        XCTAssertEqual(facade.dispatch(.setTmuxGridPresentation(.paneGrid)), .handled)
        XCTAssertEqual(facade.dispatch(.claimTmuxGridAuthority(
            reason: .forceRefresh,
            repaintEvenIfSame: true
        )), .handled)
        XCTAssertEqual(facade.dispatch(.reclaimTmuxGridAuthority(reason: .user)), .handled)
        XCTAssertEqual(facade.dispatch(
            .completeTmuxGridAuthorityRepaint(generation: 7)
        ), .handled)
        XCTAssertEqual(facade.dispatch(.setFocused(false)), .handled)
        XCTAssertEqual(facade.dispatch(.setApplicationVisibility(.active)), .handled)
        XCTAssertEqual(facade.dispatch(.requestFullRepaint), .handled)
        session.projectChallenge(fixture.request)
        await assertEventually { projectedChallengeID == fixture.request.id }
        let response = ChallengeResponse(
            challengeID: fixture.request.id,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration,
            decision: .approve
        )
        XCTAssertEqual(facade.dispatch(.submitChallengeResponse(response)), .handled)
        await assertEventually { challenge == response }
        fixture.request.reject()
        _ = await fixture.decision.value
        withExtendedLifetime(challengeCancellable) {}
        XCTAssertEqual(session.disconnectCallCount, 0)
        XCTAssertTrue(session.sentInputs.isEmpty)
        XCTAssertTrue(session.resizeRequests.isEmpty)
    }

    func testLogicalInputRoutesAcrossAllFourTransports() async {
        let input: [UInt8] = [0x54, 0x0D]

        let plainSSH = connectedRecordingSession(transport: .ssh)
        AppleSessionCommandFacade(session: plainSSH).sendInput(input)
        await assertEventually { plainSSH.sentInputs == [input] }

        let sshTmuxSession = connectedRecordingSession(transport: .ssh)
        let inlineTmux = TmuxController(controlPath: .inline)
        inlineTmux.sendBytes = { bytes in sshTmuxSession.send(bytes) }
        enterTmuxModeWithActivePane(inlineTmux)
        await drainTmuxSubscriptionFlush()
        sshTmuxSession.clearSentInputs()
        AppleSessionCommandFacade(session: sshTmuxSession, tmux: inlineTmux).sendInput(input)
        await assertEventually {
            sshTmuxSession.sentInputs == [Array("send-keys -t %5 -H 54 0d\n".utf8)]
        }

        let plainMosh = connectedRecordingSession(transport: .mosh)
        AppleSessionCommandFacade(session: plainMosh).sendInput(input)
        await assertEventually { plainMosh.sentInputs == [input] }

        let moshTmuxSession = connectedRecordingSession(transport: .mosh)
        let sideChannelTmux = TmuxController(controlPath: .sideChannel)
        sideChannelTmux.sendBytes = { bytes in moshTmuxSession.send(bytes) }
        enterTmuxModeWithActivePane(sideChannelTmux)
        await drainTmuxSubscriptionFlush()
        moshTmuxSession.clearSentInputs()
        AppleSessionCommandFacade(session: moshTmuxSession, tmux: sideChannelTmux)
            .sendInput(input)
        await assertEventually { moshTmuxSession.sentInputs == [input] }

        moshTmuxSession.clearSentInputs()
        XCTAssertEqual(
            AppleSessionCommandFacade(session: moshTmuxSession, tmux: sideChannelTmux)
                .dispatch(.sendTmuxPaneInput(
                    data: Data(input),
                    paneID: "%5",
                    receipt: nil
                )),
            .handled
        )
        await assertEventually {
            moshTmuxSession.sentInputs == [Array("send-keys -t %5 -H 54 0d\n".utf8)]
        }
    }

    func testResizeUsesOneFacadePathThroughActiveTmux() async {
        let session = CommandRecordingSession(hostID: UUID())
        session.beginDirectAttempt(UUID())
        session.projectState(.connected)
        let tmux = TmuxController(controlPath: .inline)
        tmux.sendBytes = { bytes in session.send(bytes) }
        enterTmuxModeWithActivePane(tmux)
        session.clearSentInputs()
        let facade = AppleSessionCommandFacade(session: session, tmux: tmux)

        XCTAssertEqual(facade.dispatch(.resize(columns: 37, rows: 12)), .handled)
        await assertEventually {
            session.resizeRequests.last?.columns == 37
                && session.resizeRequests.last?.rows == 12
                && session.sentInputs.contains(where: {
                    String(decoding: $0, as: UTF8.self).contains("refresh-client -C 37,12")
                })
        }
    }

    func testGridAuthorityChangesCrossPortableEventBoundary() async {
        let session = CommandRecordingSession(hostID: UUID())
        let tmux = TmuxController(controlPath: .sideChannel)
        tmux.feedTerminal = { _ in }
        tmux.sendBytes = { _ in }
        tmux.gridAuthorityIdentity = .init(id: "SELF-DEVICE", displayName: "iPad")
        let facade = AppleSessionCommandFacade(session: session, tmux: tmux)
        let recorder = SessionEventRecorder()
        let task = recordEvents(from: facade, into: recorder)

        await Task.yield()
        tmux.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        tmux.ingest(Array("%session-changed $0 test\r\n%window-add @0\r\n".utf8))
        tmux.ingest(Array(
            "%subscription-changed tessera-authority $0 @0 0 %0 : v1 PEER-DEVICE 1 iPhone\r\n".utf8
        ))

        await assertEventually {
            recorder.authorities.last == .peer(
                deviceID: "PEER-DEVICE",
                displayName: "iPhone",
                generation: 1
            )
        }
        task.cancel()
    }

    private func yieldedController(id: String, peer: String = "Mac", hydrated: Bool = false) -> TmuxController {
        let tmux = TmuxController(controlPath: .sideChannel)
        tmux.feedTerminal = { _ in }
        tmux.sendBytes = { _ in }
        tmux.gridAuthorityIdentity = .init(id: id, displayName: "iPad")
        tmux.updateClientSize(cols: 166, rows: 54)
        // A session starts hidden and refuses taps; these fixtures stand
        // for a tab on screen, with no show gesture of their own.
        tmux.gridAuthorityAdoptShown()
        if hydrated { enterHydratedTmuxModeWithActivePane(tmux) } else { enterTmuxModeWithActivePane(tmux) }
        tmux.ingest(Array(
            "%subscription-changed tessera-authority $0 @0 0 %0 : v1 PEER 1 \(peer)\r\n".utf8
        ))
        return tmux
    }

    /// The veil's tap crosses the facade and lands in the shared reducer,
    /// which owns idempotence (no app-side admission token): a second tap
    /// during the visible claim is a no-op, and a contest folds back to the
    /// tappable veil.
    func testVeilTapReachesTheReducerAndAContestFoldsBackToTheVeil() async {
        let session = CommandRecordingSession(hostID: UUID())
        let tmux = yieldedController(id: "SELF")
        XCTAssertEqual(tmux.gridAuthorityPresentation, .veiled(peerName: "Mac"))
        XCTAssertFalse(tmux.gridAuthorityAllowsInput)

        let facade = AppleSessionCommandFacade(session: session, tmux: tmux)
        XCTAssertEqual(facade.dispatch(.reclaimTmuxGridAuthority(reason: .user)), .handled)
        await assertEventually { tmux.gridAuthorityReclaimInFlight }
        XCTAssertEqual(
            tmux.gridAuthorityPresentation,
            .reclaiming(peerName: "Mac", awaitingConnection: false)
        )
        XCTAssertEqual(facade.dispatch(.reclaimTmuxGridAuthority(reason: .user)), .handled)

        // Same peer label, newer generation: the contest must still end the
        // claim even though an equality-based observer sees "Mac" throughout.
        tmux.ingest(Array(
            "%subscription-changed tessera-authority $0 @0 0 %0 : v1 PEER 2 Mac\r\n".utf8
        ))
        XCTAssertFalse(tmux.gridAuthorityReclaimInFlight)
        XCTAssertEqual(tmux.gridAuthorityPresentation, .veiled(peerName: "Mac"))
    }

    func testReclaimCommandMutatesOnlyTheControllerItWasDispatchedFor() async {
        let session = CommandRecordingSession(hostID: UUID())
        let origin = yieldedController(id: "ORIGIN")
        let replacement = yieldedController(id: "REPLACEMENT")
        let originFacade = AppleSessionCommandFacade(session: session, tmux: origin)
        _ = AppleSessionCommandFacade(session: session, tmux: replacement)

        XCTAssertEqual(originFacade.dispatch(.reclaimTmuxGridAuthority(reason: .user)), .handled)
        await assertEventually { origin.gridAuthorityReclaimInFlight }
        XCTAssertFalse(replacement.gridAuthorityReclaimInFlight)
        XCTAssertEqual(replacement.gridAuthorityPresentation, .veiled(peerName: "Mac"))
    }

    /// A focus refused while a peer holds the grid is retained, never
    /// written, and neither claims the grid nor types into the pane. Peer to
    /// mine needs a settled claim (or a fresh read with geometry evidence),
    /// which these in-process fixtures cannot drive; the live lanes cover the
    /// retry that follows settlement.
    func testPendingTerminalFocusIsRetainedWithoutWritingWhileYielded() async {
        let carrier = SSHSession(host: Host(id: UUID(), transport: .ssh))
        let live = LiveSession(session: .ssh(carrier), hostName: "fixture", hostKey: "fixture", launchMode: .autoTmux)
        let registry = SessionRegistry()
        registry.syncActiveSessions([live])
        let tmux = yieldedController(id: "SELF", hydrated: true)
        let backend = connectedRecordingSession(transport: .mosh)
        let facade = AppleSessionCommandFacade(session: backend, tmux: tmux)
        var wire: [String] = []
        tmux.sendBytes = { wire.append(String(decoding: $0, as: UTF8.self)) }
        await drainTmuxSubscriptionFlush()
        XCTAssertTrue(wire.allSatisfy { $0.hasPrefix("refresh-client -B ") },
                      "deferred setup must only register subscriptions")
        wire.removeAll()
        registry.requestTmuxFocus(sessionID: live.id, windowID: WindowId(1), paneID: PaneId(5))
        let token = registry.tmuxFocusRequest?.token
        for _ in 0..<3 {
            registry.handleTmuxFocusRequest(sessionID: live.id, carrier: carrier, tmux: tmux, commands: facade, isShown: true)
        }
        await Task.yield()
        XCTAssertEqual(registry.tmuxFocusRequest?.token, token)
        XCTAssertTrue(wire.isEmpty, "focus must not claim a peer's grid: \(wire)")
        XCTAssertTrue(tmux.gridAuthority.isPeer)
        XCTAssertTrue(backend.sentInputs.isEmpty)
    }

    /// Agent Center requests focus before its reveal renders (a phone
    /// switches tabs after it): a view not yet shown keeps the request, and
    /// the shown view selects the exact window and pane once.
    func testPendingTerminalFocusWaitsForItsViewToBeShown() async {
        let carrier = SSHSession(host: Host(id: UUID(), transport: .ssh))
        let live = LiveSession(session: .ssh(carrier), hostName: "fixture", hostKey: "fixture", launchMode: .autoTmux)
        let registry = SessionRegistry()
        registry.syncActiveSessions([live])
        let tmux = TmuxController(controlPath: .sideChannel)
        tmux.feedTerminal = { _ in }
        tmux.gridAuthorityIdentity = .init(id: "SELF", displayName: "iPad")
        tmux.updateClientSize(cols: 166, rows: 54)
        tmux.gridAuthorityAdoptShown()
        var wire: [String] = []
        tmux.sendBytes = { wire.append(String(decoding: $0, as: UTF8.self)) }
        enterHydratedTmuxModeWithActivePane(tmux)
        XCTAssertFalse(tmux.gridAuthority.isPeer)
        XCTAssertTrue(tmux.isWindowListHydrated)
        // The facade holds its session weakly; the test keeps it alive.
        let session = connectedRecordingSession(transport: .ssh)
        let facade = AppleSessionCommandFacade(session: session, tmux: tmux)
        registry.requestTmuxFocus(sessionID: live.id, windowID: WindowId(1), paneID: PaneId(5))
        let before = wire.count
        registry.handleTmuxFocusRequest(sessionID: live.id, carrier: carrier, tmux: tmux, commands: facade, isShown: false)
        await Task.yield()
        XCTAssertNotNil(registry.tmuxFocusRequest)
        XCTAssertFalse(wire.dropFirst(before).contains { $0.contains("select-window") || $0.contains("select-pane") })
        registry.handleTmuxFocusRequest(sessionID: live.id, carrier: carrier, tmux: tmux, commands: facade, isShown: true)
        await assertEventually { wire.contains { $0.contains("select-pane") } }
        XCTAssertNil(registry.tmuxFocusRequest)
        let selections = wire.dropFirst(before).filter { $0.contains("select-window") || $0.contains("select-pane") }
        XCTAssertEqual(selections.count, 2, "\(selections)")
        XCTAssertTrue(selections.first?.contains("select-window") == true && selections.first?.contains("@1") == true)
        XCTAssertEqual(selections.last, "select-pane -Z -t %5\n")
        withExtendedLifetime(session) {}
    }

    /// A control client still attaching has no authoritative window list:
    /// the request waits for it instead of reading the target as gone.
    func testPendingTerminalFocusWaitsForAnAuthoritativeWindowList() async {
        let carrier = SSHSession(host: Host(id: UUID(), transport: .ssh))
        let live = LiveSession(session: .ssh(carrier), hostName: "fixture", hostKey: "fixture", launchMode: .autoTmux)
        let registry = SessionRegistry()
        registry.syncActiveSessions([live])
        let tmux = TmuxController(controlPath: .sideChannel)
        tmux.feedTerminal = { _ in }
        tmux.gridAuthorityIdentity = .init(id: "SELF", displayName: "iPad")
        tmux.updateClientSize(cols: 166, rows: 54)
        tmux.gridAuthorityAdoptShown()
        var wire: [String] = []
        tmux.sendBytes = { wire.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertNotEqual(tmux.mode, .tmuxControl)
        XCTAssertFalse(tmux.isWindowListHydrated)
        // The facade holds its session weakly; the test keeps it alive.
        let session = connectedRecordingSession(transport: .ssh)
        let facade = AppleSessionCommandFacade(session: session, tmux: tmux)
        registry.requestTmuxFocus(sessionID: live.id, windowID: WindowId(1), paneID: PaneId(5))
        let token = registry.tmuxFocusRequest?.token
        registry.handleTmuxFocusRequest(sessionID: live.id, carrier: carrier, tmux: tmux, commands: facade, isShown: true)
        await Task.yield()
        XCTAssertEqual(registry.tmuxFocusRequest?.token, token)
        XCTAssertFalse(wire.contains { $0.contains("select-window") || $0.contains("select-pane") })
        enterHydratedTmuxModeWithActivePane(tmux)
        XCTAssertTrue(tmux.isWindowListHydrated)
        let before = wire.count
        registry.handleTmuxFocusRequest(sessionID: live.id, carrier: carrier, tmux: tmux, commands: facade, isShown: true)
        await assertEventually { wire.dropFirst(before).contains { $0.contains("select-pane") } }
        XCTAssertNil(registry.tmuxFocusRequest)
        let selections = wire.dropFirst(before).filter { $0.contains("select-window") || $0.contains("select-pane") }
        XCTAssertEqual(selections.count, 2, "\(selections)")
        XCTAssertTrue(selections.first?.contains("select-window") == true && selections.first?.contains("@1") == true)
        XCTAssertEqual(selections.last, "select-pane -Z -t %5\n")
        withExtendedLifetime(session) {}
    }

    func testPendingTerminalFocusCancelsOnHideOrCarrierReplacement() async {
        for reason in ["hidden", "controller", "generation", "pane", "removed", "carrier"] {
            let carrier = SSHSession(host: Host(id: UUID(), transport: .ssh))
            let live = LiveSession(session: .ssh(carrier), hostName: "fixture", hostKey: "fixture", launchMode: .autoTmux)
            let registry = SessionRegistry()
            registry.syncActiveSessions([live])
            let tmux = yieldedController(id: "SELF", hydrated: true)
            let backend = connectedRecordingSession(transport: .mosh)
            let facade = AppleSessionCommandFacade(session: backend, tmux: tmux)
            var wire: [String] = []
            tmux.sendBytes = { wire.append(String(decoding: $0, as: UTF8.self)) }
            registry.requestTmuxFocus(sessionID: live.id, windowID: WindowId(1), paneID: PaneId(5))
            registry.handleTmuxFocusRequest(sessionID: live.id, carrier: carrier, tmux: tmux, commands: facade, isShown: true)
            XCTAssertNotNil(registry.tmuxFocusRequest)
            switch reason {
            case "hidden": registry.cancelTmuxFocus(sessionID: live.id)
            case "controller":
                registry.handleTmuxFocusRequest(sessionID: live.id, carrier: carrier,
                    tmux: yieldedController(id: "SELF"), commands: facade, isShown: true)
            case "generation":
                tmux.reset()
                registry.handleTmuxFocusRequest(sessionID: live.id, carrier: carrier, tmux: tmux, commands: facade, isShown: true)
            case "pane":
                tmux.ingest(Array("%layout-change @1 dead,80x24,0,0,6 dead,80x24,0,0,6\r\n".utf8))
                registry.handleTmuxFocusRequest(sessionID: live.id, carrier: carrier, tmux: tmux, commands: facade, isShown: true)
            case "removed": registry.syncActiveSessions([])
            default:
                let replacement = SSHSession(host: carrier.host)
                registry.syncActiveSessions([LiveSession(id: live.id, session: .ssh(replacement), hostName: "fixture",
                    hostKey: "fixture", launchMode: .autoTmux)])
            }
            XCTAssertNil(registry.tmuxFocusRequest, reason)
            tmux.ingest(Array("%subscription-changed tessera-authority $0 @0 0 %0 : v1 SELF 2 iPad\r\n".utf8))
            registry.handleTmuxFocusRequest(sessionID: live.id, carrier: carrier, tmux: tmux, commands: facade, isShown: true)
            await Task.yield()
            XCTAssertFalse(wire.contains { $0.contains("select-window") || $0.contains("select-pane") }, reason)
            XCTAssertTrue(backend.sentInputs.isEmpty)
        }
    }

    func testPendingTerminalFocusReplacementAndDeadlineCannotReplayAnOldToken() async {
        let carrier = SSHSession(host: Host(id: UUID(), transport: .ssh))
        let live = LiveSession(session: .ssh(carrier), hostName: "fixture", hostKey: "fixture", launchMode: .autoTmux)
        let registry = SessionRegistry()
        registry.syncActiveSessions([live])
        let tmux = yieldedController(id: "SELF", hydrated: true)
        let backend = connectedRecordingSession(transport: .mosh)
        let facade = AppleSessionCommandFacade(session: backend, tmux: tmux)
        var wire: [String] = []
        tmux.sendBytes = { wire.append(String(decoding: $0, as: UTF8.self)) }
        await drainTmuxSubscriptionFlush()
        XCTAssertTrue(wire.allSatisfy { $0.hasPrefix("refresh-client -B ") },
                      "deferred setup must only register subscriptions")
        wire.removeAll()
        registry.requestTmuxFocus(sessionID: live.id, windowID: WindowId(1), paneID: PaneId(5), lifetime: .milliseconds(20))
        let oldToken = registry.tmuxFocusRequest?.token
        registry.handleTmuxFocusRequest(sessionID: live.id, carrier: carrier, tmux: tmux, commands: facade, isShown: true)
        registry.requestTmuxFocus(sessionID: live.id, windowID: WindowId(1), paneID: PaneId(5), lifetime: .milliseconds(200))
        let newToken = registry.tmuxFocusRequest?.token
        XCTAssertNotEqual(newToken, oldToken)
        registry.handleTmuxFocusRequest(sessionID: live.id, carrier: carrier, tmux: tmux, commands: facade, isShown: true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(registry.tmuxFocusRequest?.token, newToken, "the retired timer cannot cancel its replacement")
        await assertEventually { registry.tmuxFocusRequest == nil }
        tmux.ingest(Array("%subscription-changed tessera-authority $0 @0 0 %0 : v1 SELF 2 iPad\r\n".utf8))
        registry.handleTmuxFocusRequest(sessionID: live.id, carrier: carrier, tmux: tmux, commands: facade, isShown: true)
        await Task.yield()
        XCTAssertTrue(wire.isEmpty)
        XCTAssertTrue(backend.sentInputs.isEmpty)
    }

    /// S5′: one typed gate at dispatch. Mosh bytes (D23) and window commands
    /// stop while a peer holds the grid; acknowledged pane replies pass.
    func testDispatchRefusesTypingAndMutationsWhileYielded() async {
        let session = connectedRecordingSession(transport: .mosh)
        let tmux = yieldedController(id: "SELF")
        let facade = AppleSessionCommandFacade(session: session, tmux: tmux)
        var wire: [[UInt8]] = []
        tmux.sendBytes = { wire.append($0) }
        await drainTmuxSubscriptionFlush()
        XCTAssertTrue(wire.allSatisfy { String(decoding: $0, as: UTF8.self).hasPrefix("refresh-client -B ") },
                      "deferred setup must only register subscriptions")
        wire.removeAll()
        // Most input sites hold a facade without the controller; the
        // coordinator still gates them on the session's controller.
        let untargeted = AppleSessionCommandFacade(session: session)

        XCTAssertEqual(facade.dispatch(.sendInput(Data("ls\r".utf8))), .refused(.yielded))
        XCTAssertEqual(untargeted.dispatch(.sendInput(Data("ls\r".utf8))), .refused(.yielded))
        XCTAssertEqual(facade.dispatch(.selectTmuxWindow("@0")), .refused(.yielded))
        XCTAssertEqual(facade.dispatch(.claimTmuxGridAuthority(reason: .forceRefresh, repaintEvenIfSame: true)),
                       .refused(.yielded))
        let sending = Task { await facade.sendTmuxPaneInputAcknowledged([0x61], paneID: PaneId(0)) }
        await assertEventually { wire.contains(Array("send-keys -t %0 -H 61\n".utf8)) }
        for number in 20...40 {
            tmux.ingest(Array("%begin 0 \(number) 1\r\n%end 0 \(number) 1\r\n".utf8))
        }
        let agentSent = await sending.value
        XCTAssertTrue(agentSent)
        XCTAssertEqual(wire, [Array("send-keys -t %0 -H 61\n".utf8)], "a reply must not claim or replay geometry")
        XCTAssertEqual(tmux.gridAuthorityPresentation, .veiled(peerName: "Mac"))
        XCTAssertEqual(facade.dispatch(.sendTmuxPaneInput(data: Data("x".utf8), paneID: "%0", receipt: nil)),
                       .refused(.yielded))
        XCTAssertEqual(facade.authorityRefusal(for: .sendTmuxPaneInput(data: Data("x".utf8), paneID: "%0", receipt: nil)),
                       .yielded)
        XCTAssertNil(facade.authorityRefusal(for: .resize(columns: 120, rows: 40)))

        XCTAssertEqual(facade.dispatch(.resize(columns: 120, rows: 40)), .handled)
        await assertEventually { session.resizeRequests.last?.columns == 120 }
        XCTAssertTrue(session.sentInputs.isEmpty, "no refused byte reached the mosh transport")
        XCTAssertEqual(facade.dispatch(.reclaimTmuxGridAuthority(reason: .user)), .handled)
    }

    /// S5′ at apply time: input admitted at dispatch is dropped if a peer
    /// takes the grid while it waits in the ordered queue.
    func testInputQueuedBeforeAPeerStampIsDroppedWhenApplied() async {
        let session = connectedRecordingSession(transport: .mosh)
        let tmux = TmuxController(controlPath: .sideChannel)
        tmux.feedTerminal = { _ in }
        tmux.sendBytes = { _ in }
        tmux.gridAuthorityIdentity = .init(id: "SELF", displayName: "iPad")
        tmux.updateClientSize(cols: 166, rows: 54)
        tmux.gridAuthorityAdoptShown()
        enterTmuxModeWithActivePane(tmux)
        tmux.ingest(Array("%subscription-changed tessera-authority $0 @0 0 %0 : v1 SELF 1 iPad\r\n".utf8))
        let facade = AppleSessionCommandFacade(session: session, tmux: tmux)

        XCTAssertEqual(facade.dispatch(.sendInput(Data("before\r".utf8))), .handled)
        await assertEventually { session.sentInputs.contains(Array("before\r".utf8)) }

        XCTAssertEqual(facade.dispatch(.sendInput(Data("queued\r".utf8))), .handled)
        tmux.ingest(Array("%subscription-changed tessera-authority $0 @0 0 %0 : v1 PEER 2 Mac\r\n".utf8))
        XCTAssertFalse(tmux.gridAuthorityAllowsInput)
        // Ordered behind the input: once it lands, the input was applied.
        XCTAssertEqual(facade.dispatch(.resize(columns: 100, rows: 30)), .handled)
        await assertEventually { session.resizeRequests.last?.columns == 100 }
        XCTAssertFalse(session.sentInputs.contains(Array("queued\r".utf8)))
    }

    func testAcknowledgedPaneInputQueuedBeforeAPeerStampIsWrittenWhenApplied() async {
        let session = connectedRecordingSession(transport: .mosh)
        let tmux = TmuxController(controlPath: .sideChannel)
        tmux.feedTerminal = { _ in }
        tmux.sendBytes = { _ in }
        tmux.gridAuthorityIdentity = .init(id: "SELF", displayName: "iPad")
        tmux.updateClientSize(cols: 166, rows: 54)
        tmux.gridAuthorityAdoptShown()
        enterTmuxModeWithActivePane(tmux)
        // The attached window already fits this grid, so taking the stamp
        // leaves no new-window size replay in flight behind the input.
        tmux.ingest(Array("%layout-change @1 dead,166x54,0,0,5 dead,166x54,0,0,5 *\r\n".utf8))
        tmux.ingest(Array("%subscription-changed tessera-authority $0 @0 0 %0 : v1 SELF 1 iPad\r\n".utf8))
        let facade = AppleSessionCommandFacade(session: session, tmux: tmux)
        var wire: [[UInt8]] = []
        tmux.sendBytes = { wire.append($0) }
        await drainTmuxSubscriptionFlush()
        XCTAssertTrue(wire.allSatisfy { String(decoding: $0, as: UTF8.self).hasPrefix("refresh-client -B ") },
                      "deferred setup must only register subscriptions")
        wire.removeAll()
        let receipt = SessionCommandReceipt()

        XCTAssertEqual(facade.dispatch(.sendTmuxPaneInput(data: Data([0x61]), paneID: "%5", receipt: receipt)), .handled)
        tmux.ingest(Array("%subscription-changed tessera-authority $0 @0 0 %0 : v1 PEER 2 Mac\r\n".utf8))
        await assertEventually { wire.contains(Array("send-keys -t %5 -H 61\n".utf8)) }
        for number in 20...40 {
            tmux.ingest(Array("%begin 0 \(number) 1\r\n%end 0 \(number) 1\r\n".utf8))
        }
        XCTAssertEqual(wire, [Array("send-keys -t %5 -H 61\n".utf8)])
        XCTAssertEqual(tmux.gridAuthorityPresentation, .veiled(peerName: "Mac"))
        XCTAssertTrue(session.sentInputs.isEmpty)
    }

    /// A show over our own grid waits for its read: typing waits, window
    /// commands may proceed (D7's narrower gate).
    func testAResumeOverTheOwnGridRefusesTypingButAdmitsWindowCommands() {
        let session = CommandRecordingSession(hostID: UUID())
        let tmux = TmuxController(controlPath: .sideChannel)
        tmux.feedTerminal = { _ in }
        tmux.sendBytes = { _ in }
        tmux.gridAuthorityIdentity = .init(id: "SELF", displayName: "iPad")
        tmux.updateClientSize(cols: 166, rows: 54)
        enterTmuxModeWithActivePane(tmux)
        tmux.ingest(Array("%subscription-changed tessera-authority $0 @0 0 %0 : v1 SELF 1 iPad\r\n".utf8))
        tmux.gridAuthorityShown()
        XCTAssertEqual(tmux.gridAuthorityPresentation, .resuming(awaitingConnection: false))
        let facade = AppleSessionCommandFacade(session: session, tmux: tmux)

        XCTAssertEqual(facade.dispatch(.sendInput(Data("x".utf8))), .refused(.resuming))
        XCTAssertEqual(facade.dispatch(.selectTmuxWindow("@0")), .handled)
        // The verdict reads without sending: an uploaded path waits out the
        // resume in its pending slot, and acknowledged typing is refused at
        // once, before anything is queued.
        XCTAssertEqual(facade.authorityRefusal(for: .sendInput(Data("x".utf8))), .resuming)
        XCTAssertNil(facade.authorityRefusal(for: .sendTmuxPaneInput(data: Data("x".utf8), paneID: "%5", receipt: nil)))
        var deliveries: [AppleSessionCommandFacade.InputDelivery] = []
        facade.sendInputAcknowledged(Array("/tmp/a".utf8)) { deliveries.append($0) }
        XCTAssertEqual(deliveries, [.refused])
    }

    /// Acknowledged typing (an uploaded path) is `sendInput` in all but the
    /// report: it is queued before the call returns, so a key typed after
    /// it cannot overtake it, and it reports once it was sent.
    func testAcknowledgedTypingIsSentInOrderWithKeys() async {
        let session = connectedRecordingSession(transport: .mosh)
        let facade = AppleSessionCommandFacade(session: session)
        var deliveries: [AppleSessionCommandFacade.InputDelivery] = []

        facade.sendInputAcknowledged(Array("'/tmp/a b'".utf8)) { deliveries.append($0) }
        XCTAssertEqual(facade.dispatch(.sendInput(Data("\r".utf8))), .handled)

        await assertEventually { session.sentInputs.count == 2 }
        XCTAssertEqual(session.sentInputs, [Array("'/tmp/a b'".utf8), Array("\r".utf8)])
        XCTAssertEqual(deliveries, [.sent])
    }

    /// Acknowledged typing admitted at dispatch and dropped when applied,
    /// because a peer took the grid meanwhile, reports the refusal, so an
    /// uploaded path can go to the clipboard instead of vanishing.
    func testAcknowledgedTypingDroppedWhenAppliedReportsTheRefusal() async {
        let session = connectedRecordingSession(transport: .mosh)
        let tmux = TmuxController(controlPath: .sideChannel)
        tmux.feedTerminal = { _ in }
        tmux.sendBytes = { _ in }
        tmux.gridAuthorityIdentity = .init(id: "SELF", displayName: "iPad")
        tmux.updateClientSize(cols: 166, rows: 54)
        tmux.gridAuthorityAdoptShown()
        enterTmuxModeWithActivePane(tmux)
        tmux.ingest(Array("%subscription-changed tessera-authority $0 @0 0 %0 : v1 SELF 1 iPad\r\n".utf8))
        let facade = AppleSessionCommandFacade(session: session, tmux: tmux)
        var deliveries: [AppleSessionCommandFacade.InputDelivery] = []

        facade.sendInputAcknowledged(Array("/tmp/a".utf8)) { deliveries.append($0) }
        XCTAssertTrue(deliveries.isEmpty, "admitted at dispatch, not yet applied")
        tmux.ingest(Array("%subscription-changed tessera-authority $0 @0 0 %0 : v1 PEER 2 Mac\r\n".utf8))

        await assertEventually { !deliveries.isEmpty }
        XCTAssertEqual(deliveries, [.refused])
        XCTAssertTrue(session.sentInputs.isEmpty)
    }

    /// Inline control mode types into the active pane. With none, tmux
    /// drops the bytes, and acknowledged typing says so.
    func testAcknowledgedTypingWithoutAnActivePaneReportsTheDrop() async {
        let session = connectedRecordingSession(transport: .ssh)
        let tmux = TmuxController(controlPath: .inline)
        tmux.feedTerminal = { _ in }
        tmux.sendBytes = { _ in }
        var entry = [UInt8](arrayLiteral: 0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70)
        entry.append(contentsOf: Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        tmux.ingest(entry)
        XCTAssertEqual(tmux.mode, .tmuxControl)
        XCTAssertNil(tmux.activePaneId)
        let facade = AppleSessionCommandFacade(session: session, tmux: tmux)
        var deliveries: [AppleSessionCommandFacade.InputDelivery] = []

        facade.sendInputAcknowledged(Array("/tmp/a".utf8)) { deliveries.append($0) }

        await assertEventually { !deliveries.isEmpty }
        XCTAssertEqual(deliveries, [.dropped])
        XCTAssertTrue(session.sentInputs.isEmpty)
    }

    /// S2′ resume: a show over a peer keeps the terminal visible (no veil
    /// frame) while input waits for the fresh read.
    func testShowOverAPeerResumesWithoutTheVeilAndGatesInput() {
        let tmux = yieldedController(id: "SELF")
        tmux.gridAuthorityShown()
        XCTAssertEqual(tmux.gridAuthorityPresentation, .resuming(awaitingConnection: false))
        XCTAssertFalse(tmux.gridAuthorityPresentation.showsVeil)
        XCTAssertFalse(tmux.gridAuthorityAllowsInput)

        // M2: hiding cancels the unsent intent. The peer still holds the
        // grid, but a hidden session projects `.resuming` (never the veil)
        // until its next show decides, and input stays refused.
        tmux.gridAuthorityHidden()
        XCTAssertEqual(tmux.gridAuthorityPresentation, .resuming(awaitingConnection: false),
                       "a hidden session never draws the veil")
        XCTAssertFalse(tmux.gridAuthorityPresentation.showsVeil)
        XCTAssertFalse(tmux.gridAuthorityAllowsInput, "the peer still holds the grid")
        XCTAssertFalse(tmux.gridAuthorityHasPendingIntent, "hiding cancels the unsent intent")
    }

    /// D8: only a deliberate key takes control back from the veil.
    func testVeilKeyPolicyAdmitsOnlyReturnAndPrintableKeys() {
        typealias Policy = ContinuedElsewhereKeyPolicy
        XCTAssertTrue(Policy.takesBack(key: .return, characters: "\r", modifiers: []))
        XCTAssertTrue(Policy.takesBack(key: KeyEquivalent("a"), characters: "a", modifiers: []))
        XCTAssertTrue(Policy.takesBack(key: KeyEquivalent("A"), characters: "A", modifiers: .shift))
        XCTAssertTrue(Policy.takesBack(key: KeyEquivalent("é"), characters: "é", modifiers: .option))
        XCTAssertTrue(Policy.takesBack(key: .space, characters: " ", modifiers: []))

        XCTAssertFalse(Policy.takesBack(key: .escape, characters: "\u{1B}", modifiers: []))
        XCTAssertFalse(Policy.takesBack(key: KeyEquivalent("j"), characters: "j", modifiers: [.command, .shift]),
                       "⌘ chords (the session switcher) never take back")
        XCTAssertFalse(Policy.takesBack(key: KeyEquivalent("c"), characters: "\u{03}", modifiers: .control))
        XCTAssertFalse(Policy.takesBack(key: .upArrow, characters: "\u{F700}", modifiers: []))
        XCTAssertFalse(Policy.takesBack(key: KeyEquivalent("\u{F72C}"), characters: "\u{F72C}", modifiers: []),
                       "page keys are system keys")
        XCTAssertFalse(Policy.takesBack(key: .tab, characters: "\t", modifiers: []))
        XCTAssertFalse(Policy.takesBack(key: KeyEquivalent(" "), characters: "", modifiers: .shift),
                       "a modifier-only press carries no characters")
    }

    /// D8: only the displayed, unlocked session's veil may hold focus or
    /// reclaim. Hidden sessions stay mounted at opacity 0 and the lock covers
    /// a still-mounted ContentView, so both gates are needed.
    func testVeilGestureGateAdmitsOnlyTheDisplayedUnlockedSession() {
        typealias Policy = ContinuedElsewhereKeyPolicy
        XCTAssertTrue(Policy.admitsGesture(sessionIsActive: true, appIsLocked: false))
        XCTAssertFalse(Policy.admitsGesture(sessionIsActive: false, appIsLocked: false),
                       "a hidden session's veil never reclaims")
        XCTAssertFalse(Policy.admitsGesture(sessionIsActive: true, appIsLocked: true),
                       "nothing reclaims behind the app lock")
        XCTAssertFalse(Policy.admitsGesture(sessionIsActive: false, appIsLocked: true))
    }

    /// P9: a veiled terminal stops drawing once the veil covers it (output
    /// is still consumed), and the veil's repeat-forever glyph runs only
    /// where someone can see it.
    func testVeilStopsTerminalDrawingAndBreathesOnlyWhenSeen() {
        typealias Policy = ContinuedElsewherePresentationPolicy
        XCTAssertTrue(Policy.terminalDraws(inherited: true, veiled: false, veilHasFadedIn: false))
        XCTAssertTrue(Policy.terminalDraws(inherited: true, veiled: true, veilHasFadedIn: false),
                      "the terminal stays drawn while the veil fades in over it")
        XCTAssertFalse(Policy.terminalDraws(inherited: true, veiled: true, veilHasFadedIn: true),
                       "the veil's material covers the terminal")
        XCTAssertTrue(Policy.terminalDraws(inherited: true, veiled: false, veilHasFadedIn: true),
                      "a lifting veil redraws the terminal at once")
        XCTAssertFalse(Policy.terminalDraws(inherited: false, veiled: false, veilHasFadedIn: false),
                       "an unselected session never draws")
        XCTAssertFalse(Policy.terminalDraws(inherited: false, veiled: true, veilHasFadedIn: false))
        XCTAssertEqual(Policy.veilFadeDuration, 0.35)

        XCTAssertTrue(Policy.breathes(displayed: true, appIsActive: true))
        XCTAssertFalse(Policy.breathes(displayed: false, appIsActive: true),
                       "a hidden tab's mounted veil stays still")
        XCTAssertFalse(Policy.breathes(displayed: true, appIsActive: false),
                       "nothing animates in the background")
    }

    /// The drawing gate keys off the veil being on screen, the same
    /// predicate that draws it: under the launch overlay, or while the
    /// session is not connected, no veil covers the terminal, so it must
    /// keep drawing even though a peer holds the grid.
    func testDrawingGateFollowsTheVeilOnScreenNotThePeer() {
        typealias Policy = ContinuedElsewherePresentationPolicy
        XCTAssertTrue(Policy.veilIsDrawn(veilUp: true, launchOverlayShown: false, connected: true))
        XCTAssertFalse(Policy.veilIsDrawn(veilUp: false, launchOverlayShown: false, connected: true))
        XCTAssertFalse(Policy.veilIsDrawn(veilUp: true, launchOverlayShown: true, connected: true),
                       "the launch overlay outranks the veil")
        XCTAssertFalse(Policy.veilIsDrawn(veilUp: true, launchOverlayShown: false, connected: false),
                       "connection loss outranks the veil")
    }

    /// A fade counts only for the raise it began on. A veil lifted and
    /// raised again before the old fade's task noticed must wait for its
    /// own fade rather than stop drawing at once.
    func testVeilRaisedAgainWaitsForItsOwnFade() {
        var fade = ContinuedElsewhereVeilFade()
        XCTAssertFalse(fade.hasFadedIn)
        let first = fade.raise
        fade.fadeFinished(raise: first)
        XCTAssertTrue(fade.hasFadedIn, "the veil up since the start has faded in")

        fade.veilChanged()
        XCTAssertFalse(fade.hasFadedIn, "lifting forgets the fade at once")
        fade.veilChanged()
        XCTAssertFalse(fade.hasFadedIn, "raised again: not covered yet")
        fade.fadeFinished(raise: first)
        XCTAssertFalse(fade.hasFadedIn, "a superseded fade does not count")
        let second = fade.raise
        fade.fadeFinished(raise: second)
        XCTAssertTrue(fade.hasFadedIn)

        // A fade finishing just after its veil lifted cannot carry over.
        fade.veilChanged()
        fade.fadeFinished(raise: second)
        XCTAssertFalse(fade.hasFadedIn)
        fade.veilChanged()
        XCTAssertFalse(fade.hasFadedIn)
    }

    /// D8: with the terminal resigned, its chords reach the veil. None of
    /// them (find, files, refresh, tmux windows and panes, copy/paste) takes
    /// control back, and a rebind cannot escape the rule because every
    /// binding must carry ⌘.
    func testNoTerminalChordTakesBackControl() {
        typealias Policy = ContinuedElsewhereKeyPolicy
        var checked = 0
        for action in ShortcutAction.allCases {
            guard let binding = action.defaultBinding else { continue }
            var modifiers: EventModifiers = []
            if binding.modifiers.contains(.command) { modifiers.insert(.command) }
            if binding.modifiers.contains(.shift) { modifiers.insert(.shift) }
            if binding.modifiers.contains(.control) { modifiers.insert(.control) }
            if binding.modifiers.contains(.option) { modifiers.insert(.option) }
            let key: KeyEquivalent
            let characters: String
            switch binding.key {
            case .character(let value):
                guard let first = value.first else { continue }
                key = KeyEquivalent(first)
                characters = value
            case .return:
                key = .return
                characters = "\r"
            default:
                continue
            }
            XCTAssertFalse(
                Policy.takesBack(key: key, characters: characters, modifiers: modifiers),
                "\(action) takes back control"
            )
            checked += 1
        }
        XCTAssertGreaterThan(checked, 20, "the chord inventory was not exercised")
        for (key, characters) in [(KeyEquivalent("c"), "c"), (KeyEquivalent("v"), "v")] {
            XCTAssertFalse(Policy.takesBack(key: key, characters: characters, modifiers: .command))
        }
        XCTAssertEqual(
            KeyBinding([.option], .character("r")).validate(),
            .rejected(.needsCommand)
        )
    }

    func testSessionPresentationInventoryHasNoDirectMutationBypass() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "Tessera/SessionView.swift",
            "Tessera/Navigation/SessionTmuxChrome.swift",
            "Tessera/Panes/PaneGridView.swift",
            "Tessera/AgentCenterV2/Adapters/AppleAgentSessionSourceFactory.swift",
        ]
        let tmuxMutationPattern = #"tmux\.(?:sendInput(?:Acknowledged)?|sendKeyAcknowledged|selectWindow|selectPane(?:PreservingWindowZoom)?|newWindow|killWindow|killPane|killActivePane|killCurrentWindow|previousWindow|nextWindow|splitActivePane|splitPane|cyclePane|togglePaneZoom|setPaneZoomed|renameWindow|moveWindow|renumberWindows|updateClientSize|claimActiveViewport|reclaimGridAuthority|completeGridAuthoritySideChannelRepaint|setGridAuthorityUsesCompactSinglePaneGrid)\s*\("#
        let transportMutationPattern = #"\bsession\.(?:connect|disconnect|resize|send)\s*\("#
        let rawTmuxSink = "tmux.sendBytes = { [session] bytes in session.send(bytes) }"

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: repositoryURL.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertNil(
                source.range(of: tmuxMutationPattern, options: .regularExpression),
                "\(relativePath) bypasses SessionCommand for a tmux mutation"
            )
            let withoutBackendSink = source.replacingOccurrences(of: rawTmuxSink, with: "")
            XCTAssertNil(
                withoutBackendSink.range(
                    of: transportMutationPattern,
                    options: .regularExpression
                ),
                "\(relativePath) bypasses SessionCommand for a transport mutation"
            )
        }
    }

    func testHostKeyChallengePublishesAfterEngineAcceptanceAndClearsOnTerminalState() async {
        let session = CommandRecordingSession(hostID: UUID())
        let facade = AppleSessionCommandFacade(session: session)
        let fixture = await makeHostKeyFixture()
        var projectedIDs: [UUID?] = []
        let cancellable = facade.challengeRequests.sink { projectedIDs.append($0?.id) }
        let intent = ConnectionIntent(hostID: session.host.id, policyGeneration: 4)
        XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
        await assertEventually { session.connectCallCount == 1 }

        session.projectChallenge(fixture.request)
        // Crossing the Apple publisher alone is insufficient; publication is
        // deferred until SessionEngine validates attempt and policy context.
        XCTAssertEqual(projectedIDs, [nil])
        await assertEventually { projectedIDs.last == fixture.request.id }

        XCTAssertTrue(facade.respondToHostKeyChallenge(
            fixture.request.id,
            decision: .approve
        ))
        let accepted = await fixture.decision.value
        XCTAssertTrue(accepted)
        session.projectState(.disconnected)
        await assertEventually { facade.state == .disconnected }
        await assertEventually { projectedIDs.last.map { $0 == nil } == true }
        withExtendedLifetime(cancellable) {}
    }

    func testAnsweredHostKeyIsNotReplayedToALateSubscriber() async {
        let session = CommandRecordingSession(hostID: UUID())
        let facade = AppleSessionCommandFacade(session: session)
        let fixture = await makeHostKeyFixture()
        defer { fixture.request.reject() }
        var projectedID: UUID?
        let cancellable = facade.challengeRequests.sink { projectedID = $0?.id }
        defer { withExtendedLifetime(cancellable) {} }
        let intent = ConnectionIntent(hostID: session.host.id, policyGeneration: 4)
        XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        session.projectChallenge(fixture.request)
        await assertEventually { projectedID == fixture.request.id }

        XCTAssertTrue(facade.respondToHostKeyChallenge(fixture.request.id, decision: .approve))
        // The engine has not consumed the answer yet; a presenter that
        // re-subscribes now must not receive the prompt again.
        XCTAssertFalse(fixture.request.isResolved)
        var replayed: [UUID?] = []
        let late = facade.challengeRequests.sink { replayed.append($0?.id) }
        XCTAssertEqual(replayed, [nil])
        await assertEventually { fixture.request.isResolved }
        let accepted = await fixture.decision.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(replayed.compactMap { $0 }, [])
        withExtendedLifetime(late) {}
    }

    func testHostKeyAnsweredAfterChallengeLifetimeStillApproves() async {
        let session = CommandRecordingSession(hostID: UUID())
        let clock = HostKeyTestClock()
        let facade = AppleSessionCommandFacade(session: session, now: { clock.now() })
        let fixture = await makeHostKeyFixture()
        defer { fixture.request.reject() }
        let recorder = SessionEventRecorder()
        let task = recordEvents(from: facade, into: recorder)
        defer { task.cancel() }
        var projectedIDs: [UUID?] = []
        let cancellable = facade.challengeRequests.sink { projectedIDs.append($0?.id) }
        defer { withExtendedLifetime(cancellable) {} }
        let intent = ConnectionIntent(hostID: session.host.id, policyGeneration: 4)
        XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        session.projectChallenge(fixture.request)
        await assertEventually { projectedIDs.last == fixture.request.id }

        clock.advance(by: 61)
        XCTAssertTrue(facade.respondToHostKeyChallenge(fixture.request.id, decision: .approve))
        await assertEventually { fixture.request.isResolved }
        guard fixture.request.isResolved else { return }
        let accepted = await fixture.decision.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(facade._challengeRenewalCountForTesting, 1)
        await assertEventually { recorder.challenges.count == 2 }
        XCTAssertEqual(projectedIDs.compactMap { $0 }, [fixture.request.id])
    }

    func testHostKeyRejectedAfterChallengeLifetimeResolvesTheRequest() async {
        let session = CommandRecordingSession(hostID: UUID())
        let clock = HostKeyTestClock()
        let facade = AppleSessionCommandFacade(session: session, now: { clock.now() })
        let fixture = await makeHostKeyFixture()
        defer { fixture.request.reject() }
        var projectedID: UUID?
        let cancellable = facade.challengeRequests.sink { projectedID = $0?.id }
        defer { withExtendedLifetime(cancellable) {} }
        let intent = ConnectionIntent(hostID: session.host.id, policyGeneration: 4)
        XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        session.projectChallenge(fixture.request)
        await assertEventually { projectedID == fixture.request.id }

        clock.advance(by: 61)
        XCTAssertTrue(facade.respondToHostKeyChallenge(fixture.request.id, decision: .reject))
        await assertEventually { fixture.request.isResolved }
        guard fixture.request.isResolved else { return }
        let accepted = await fixture.decision.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(facade._challengeRenewalCountForTesting, 1)
    }

    func testHostKeyAnsweredWithinLifetimeDoesNotRenew() async {
        let session = CommandRecordingSession(hostID: UUID())
        let clock = HostKeyTestClock()
        let facade = AppleSessionCommandFacade(session: session, now: { clock.now() })
        let fixture = await makeHostKeyFixture()
        defer { fixture.request.reject() }
        var projectedID: UUID?
        let cancellable = facade.challengeRequests.sink { projectedID = $0?.id }
        defer { withExtendedLifetime(cancellable) {} }
        let intent = ConnectionIntent(hostID: session.host.id, policyGeneration: 4)
        XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        session.projectChallenge(fixture.request)
        await assertEventually { projectedID == fixture.request.id }

        clock.advance(by: 10)
        XCTAssertTrue(facade.respondToHostKeyChallenge(fixture.request.id, decision: .approve))
        await assertEventually { fixture.request.isResolved }
        guard fixture.request.isResolved else { return }
        let accepted = await fixture.decision.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(facade._challengeRenewalCountForTesting, 0)
    }

    func testRenewalKeepsTheOriginalAttemptSoASupersededRequestStaysRefused() async {
        let session = CommandRecordingSession(hostID: UUID())
        let clock = HostKeyTestClock()
        let facade = AppleSessionCommandFacade(session: session, now: { clock.now() })
        let fixture = await makeHostKeyFixture()
        defer { fixture.request.reject() }
        let recorder = SessionEventRecorder()
        let task = recordEvents(from: facade, into: recorder)
        defer { task.cancel() }
        var projectedID: UUID?
        let cancellable = facade.challengeRequests.sink { projectedID = $0?.id }
        defer { withExtendedLifetime(cancellable) {} }
        let first = ConnectionIntent(hostID: session.host.id, policyGeneration: 4)
        XCTAssertEqual(facade.dispatch(.connect(first)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        session.projectChallenge(fixture.request)
        await assertEventually { projectedID == fixture.request.id }

        session.projectState(.disconnected)
        await assertEventually { facade.state == .disconnected }
        let second = ConnectionIntent(hostID: session.host.id, policyGeneration: 4)
        XCTAssertEqual(facade.dispatch(.connect(second)), .handled)
        await assertEventually { session.connectCallCount == 2 }
        clock.advance(by: 61)
        XCTAssertTrue(facade.respondToHostKeyChallenge(fixture.request.id, decision: .approve))
        // The rejection proves the response was processed, without a timed negative wait.
        await assertEventually {
            recorder.recoverableWarnings.contains { $0.code == "apple_adapter_rejected" }
        }
        XCTAssertEqual(facade._challengeRenewalCountForTesting, 1)
        XCTAssertFalse(fixture.request.isResolved)
    }

    func testTerminalOutputPreservesExactChunkBoundariesInSharedEvents() async {
        let session = CommandRecordingSession(hostID: UUID())
        let generation = SessionGeneration(rawValue: 42)
        let facade = AppleSessionCommandFacade(session: session, generation: generation)
        let recorder = SessionEventRecorder()
        let task = recordEvents(from: facade, into: recorder)
        let intent = ConnectionIntent(hostID: session.host.id, policyGeneration: 5)

        XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        session.projectState(.connected)
        await assertEventually { facade.state == .connected }

        session.emit([0x1b, 0x5b, 0x41])
        session.emit([])
        session.emit([0x00, 0xff])

        await assertEventually {
            recorder.terminalChunks == [
                Data([0x1b, 0x5b, 0x41]),
                Data(),
                Data([0x00, 0xff]),
            ]
        }
        XCTAssertTrue(recorder.terminalGenerations.allSatisfy { $0 == generation })
        task.cancel()
    }

    func testQueuedOldAttemptBytesCannotBeReclassifiedAfterReconnect() async {
        let session = CommandRecordingSession(hostID: UUID())
        let facade = AppleSessionCommandFacade(session: session)
        let recorder = SessionEventRecorder()
        let task = recordEvents(from: facade, into: recorder)
        let first = ConnectionIntent(hostID: session.host.id, policyGeneration: 1)
        XCTAssertEqual(facade.dispatch(.connect(first)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        session.projectState(.connected)
        await assertEventually { facade.state == .connected }

        // Keep these operations in one MainActor turn. The stale chunk is
        // bound to attempt 1 but queued behind an attempt-2 reconnect,
        // reproducing the old processing-time generation snapshot bug.
        session.projectState(.disconnected)
        let second = ConnectionIntent(hostID: session.host.id, policyGeneration: 2)
        XCTAssertEqual(facade.dispatch(.connect(second)), .handled)
        session.projectState(.connecting)
        session.projectState(.connected)
        facade._ingestTransportBytesForTesting(Data([0x41]), attemptID: first.requestID)
        // The first valid reconnect chunk crosses the same boundary in this
        // turn, before `facade.generation` can receive the engine event.
        facade._ingestTransportBytesForTesting(Data([0x42]))

        await assertEventually { facade.generation.rawValue == 2 && facade.state == .connected }
        await assertEventually { recorder.terminalChunks == [Data([0x42])] }
        task.cancel()
    }

    func testDelayedDisconnectFromAttemptACannotTearDownActiveAttemptB() async {
        let session = CommandRecordingSession(hostID: UUID())
        let facade = AppleSessionCommandFacade(session: session)
        let recorder = SessionEventRecorder()
        let task = recordEvents(from: facade, into: recorder)
        let first = ConnectionIntent(hostID: session.host.id, policyGeneration: 1)
        let second = ConnectionIntent(hostID: session.host.id, policyGeneration: 2)

        XCTAssertEqual(facade.dispatch(.connect(first)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        session.projectState(.connected)
        await assertEventually { facade.state == .connected }
        session.projectState(.disconnected)
        await assertEventually { facade.state == .disconnected }

        XCTAssertEqual(facade.dispatch(.connect(second)), .handled)
        await assertEventually { session.connectCallCount == 2 }
        session.projectState(.connected)
        await assertEventually { facade.state == .connected }
        let connectedGeneration = facade.generation

        facade._ingestTransportStateForTesting(
            .disconnected,
            originatingIntent: first
        )
        await assertEventually {
            recorder.recoverableWarnings.last?.code == "apple_adapter_rejected"
        }
        XCTAssertEqual(facade.state, .connected)
        XCTAssertEqual(facade.generation, connectedGeneration)
        XCTAssertTrue(
            recorder.recoverableWarnings.last?.arguments["reason"]?.contains("staleAttempt")
                == true
        )

        facade._ingestTransportStateForTesting(
            .disconnected,
            originatingIntent: second
        )
        await assertEventually { facade.state == .disconnected }
        task.cancel()
    }

    func testFacadeAdoptsDirectTransportAttemptWithoutRelabelingOutput() async {
        let session = CommandRecordingSession(hostID: UUID())
        let attemptID = UUID()
        session.beginDirectAttempt(attemptID)
        let facade = AppleSessionCommandFacade(session: session)
        let recorder = SessionEventRecorder()
        let task = recordEvents(from: facade, into: recorder)

        session.projectState(.connected)
        await assertEventually { facade.state == .connected }
        session.emit([0x7f])

        await assertEventually { recorder.terminalChunks == [Data([0x7f])] }
        XCTAssertEqual(
            recorder.states.first,
            .connecting(attemptID: attemptID)
        )
        task.cancel()
    }

    func testAllFourReleasedTransportConfigurationsEnterSameFacade() async {
        let configurations: [(HostTransport, Bool)] = [
            (.ssh, false), (.ssh, true), (.mosh, false), (.mosh, true),
        ]
        for (transport, usesTmux) in configurations {
            let session = CommandRecordingSession(hostID: UUID(), transport: transport)
            let tmux = usesTmux ? TmuxController(controlPath: .sideChannel) : nil
            let facade = AppleSessionCommandFacade(session: session, tmux: tmux)
            let intent = ConnectionIntent(hostID: session.host.id, policyGeneration: 6)

            XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
            await assertEventually { session.connectCallCount == 1 }
            session.projectState(.connected)
            await assertEventually { facade.state == .connected }
            XCTAssertEqual(facade.dispatch(.sendInput(Data([0x54]))), .handled)
            await assertEventually { session.sentInputs == [[0x54]] }
        }
    }

    // MARK: - Bounded interactive-input latency (input-stall findings §1)

    func testQueueDiagnosticsIdentifyHostAndAwaitedEngineRoundTrips() async {
        let previousVerbose = DiagnosticLogStore.isVerboseEnabled
        UserDefaults.standard.set(true, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey)
        defer {
            UserDefaults.standard.set(previousVerbose, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey)
        }
        let session = CommandRecordingSession(hostID: UUID())
        let facade = AppleSessionCommandFacade(session: session)
        let intent = ConnectionIntent(hostID: session.host.id, policyGeneration: 1)
        XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        session.projectState(.connected)
        await assertEventually { facade.state == .connected }
        // Exercise the real five-second aggregation boundary without changing
        // the production clock or adding a test-only logging path.
        try? await Task.sleep(for: .milliseconds(5_100))
        facade._ingestTransportBytesForTesting(Data([0x41]))
        let prefix = "session-output-queue host=\(session.host.id.uuidString.prefix(8)) "
        await assertEventually {
            let log = DiagnosticLogStore.attachmentData()
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return log.split(separator: "\n").contains {
                $0.contains(prefix) && $0.contains("engineRoundTrips='command{count=1,")
            }
        }
    }

    func testInteractiveInputOvertakesQueuedObservationalOutputBacklog() async {
        let session = CommandRecordingSession(hostID: UUID())
        let facade = AppleSessionCommandFacade(session: session)
        let recorder = SessionEventRecorder()
        let task = recordEvents(from: facade, into: recorder)
        let intent = ConnectionIntent(hostID: session.host.id, policyGeneration: 1)
        XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        session.projectState(.connected)
        await assertEventually { facade.state == .connected }

        // Sustained observational flood queued ahead of the keystrokes in
        // admission order — the head-of-line scenario from the device log.
        let floodChunkCount = 5_000
        for index in 0..<floodChunkCount {
            facade._ingestTransportBytesForTesting(
                Data([UInt8(truncatingIfNeeded: index)])
            )
        }
        var orderedBacklogAtFirstSend: Int?
        session.onSend = {
            if orderedBacklogAtFirstSend == nil {
                orderedBacklogAtFirstSend = facade._orderedLaneCountForTesting
            }
        }
        XCTAssertEqual(facade.dispatch(.sendInput(Data([0x54]))), .handled)
        XCTAssertEqual(facade.dispatch(.sendInput(Data([0x55]))), .handled)

        await assertEventually { session.sentInputs.count == 2 }
        // Exact input ordering, no drops, no duplication.
        XCTAssertEqual(session.sentInputs, [[0x54], [0x55]])
        // Bounded admission-to-backend latency: the first keystroke reached
        // the transport while (nearly) the whole observational backlog was
        // still queued. A FIFO regression would drain all chunks first and
        // report a backlog of zero here.
        XCTAssertGreaterThan(orderedBacklogAtFirstSend ?? 0, floodChunkCount / 2)
        // The overtaken output is delayed, never dropped or reordered.
        await assertEventually(timeout: .seconds(10)) {
            recorder.terminalChunks.count == floodChunkCount
        }
        XCTAssertEqual(recorder.terminalChunks.first, Data([0x00]))
        XCTAssertEqual(
            recorder.terminalChunks.last,
            Data([UInt8(truncatingIfNeeded: floodChunkCount - 1)])
        )
        task.cancel()
    }

    func testInputAdmittedAfterDisconnectReportRespectsLifecycleBarrier() async {
        let session = CommandRecordingSession(hostID: UUID())
        let facade = AppleSessionCommandFacade(session: session)
        let recorder = SessionEventRecorder()
        let task = recordEvents(from: facade, into: recorder)
        let intent = ConnectionIntent(hostID: session.host.id, policyGeneration: 1)
        XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        session.projectState(.connected)
        await assertEventually { facade.state == .connected }

        // Queue tail output, then a transport-reported disconnect, then a
        // keystroke — all in one MainActor turn so everything is pending.
        let tailChunkCount = 500
        for _ in 0..<tailChunkCount {
            facade._ingestTransportBytesForTesting(Data([0x41]))
        }
        facade._ingestTransportStateForTesting(.disconnected, originatingIntent: intent)
        XCTAssertEqual(facade.dispatch(.sendInput(Data([0x54]))), .handled)

        await assertEventually { facade.state == .disconnected }
        await assertEventually {
            recorder.recoverableWarnings.contains { $0.code == "apple_adapter_rejected" }
        }
        // The keystroke may overtake bulk output but never an earlier-admitted
        // lifecycle boundary: it must observe the disconnect and be rejected,
        // not reach the transport.
        XCTAssertEqual(session.sentInputs, [])
        // Tail bytes admitted before the disconnect still render first —
        // prioritization must not cost end-of-session output.
        await assertEventually { recorder.terminalChunks.count == tailChunkCount }
        task.cancel()
    }

    func testInputOrderingExactAcrossInterleavedFloods() async {
        let session = CommandRecordingSession(hostID: UUID())
        let facade = AppleSessionCommandFacade(session: session)
        let recorder = SessionEventRecorder()
        let task = recordEvents(from: facade, into: recorder)
        let intent = ConnectionIntent(hostID: session.host.id, policyGeneration: 1)
        XCTAssertEqual(facade.dispatch(.connect(intent)), .handled)
        await assertEventually { session.connectCallCount == 1 }
        session.projectState(.connected)
        await assertEventually { facade.state == .connected }

        var expected: [[UInt8]] = []
        for wave in 0..<10 {
            for _ in 0..<200 {
                facade._ingestTransportBytesForTesting(Data([0x2E]))
            }
            let byte = UInt8(0x60 + wave)
            expected.append([byte])
            XCTAssertEqual(facade.dispatch(.sendInput(Data([byte]))), .handled)
        }

        await assertEventually { session.sentInputs.count == expected.count }
        XCTAssertEqual(session.sentInputs, expected)
        await assertEventually(timeout: .seconds(10)) {
            recorder.terminalChunks.count == 2_000
        }
        task.cancel()
    }

    func testBulkBatchesBoundWorkAndPreservePacketReceipts() async {
        let session = CommandRecordingSession(hostID: UUID())
        let facade = AppleSessionCommandFacade(session: session)
        let recorder = SessionEventRecorder()
        let task = recordEvents(from: facade, into: recorder)
        defer { task.cancel() }
        facade.connect()
        await assertEventually { session.connectCallCount == 1 }
        session.projectState(.connected)
        await assertEventually { facade.state == .connected }
        let sizes = [32_768, 32_768, 1, 81_920] + Array(repeating: 1, count: 70)
        let chunks = sizes.enumerated().map { Data(repeating: UInt8($0.offset), count: $0.element) }
        let receipts = sizes.indices.map { TerminalOutputReceipt(deliveryID: UInt64($0 + 1), repaintRequestID: 99) }
        for index in chunks.indices {
            facade._ingestTransportBytesForTesting(chunks[index], receipt: receipts[index])
        }
        await assertEventually { recorder.terminalChunks.count == chunks.count }
        XCTAssertEqual(recorder.terminalChunks, chunks)
        XCTAssertEqual(recorder.terminalReceipts, receipts.map(Optional.some))
        let batches = facade._bulkBatchesForTesting.filter { $0.bytes > 0 }
        XCTAssertEqual(batches.map(\.items), [2, 1, 1, 32, 32, 6])
        XCTAssertTrue(batches.allSatisfy { $0.items <= 32 && ($0.bytes <= 65_536 || $0.items == 1) })
    }

    func testReconnectDuringBacklogPreservesOldTailButRejectsLateOldAttempt() async {
        let session = CommandRecordingSession(hostID: UUID())
        let facade = AppleSessionCommandFacade(session: session)
        let recorder = SessionEventRecorder()
        let task = recordEvents(from: facade, into: recorder)
        defer { task.cancel() }
        let first = ConnectionIntent(hostID: session.host.id, policyGeneration: 1)
        let second = ConnectionIntent(hostID: session.host.id, policyGeneration: 2)
        _ = facade.dispatch(.connect(first))
        await assertEventually { session.connectCallCount == 1 }
        session.projectState(.connected)
        await assertEventually { facade.state == .connected }
        for _ in 0..<500 { facade._ingestTransportBytesForTesting(Data([0x41]), attemptID: first.requestID) }
        facade._ingestTransportStateForTesting(.disconnected, originatingIntent: first)
        _ = facade.dispatch(.connect(second))
        await assertEventually { session.connectCallCount == 2 }
        session.projectState(.connected)
        await assertEventually { facade.state == .connected }
        facade._ingestTransportBytesForTesting(Data([0xFF]), attemptID: first.requestID)
        facade._ingestTransportBytesForTesting(Data([0x42]), attemptID: second.requestID)
        await assertEventually { recorder.terminalChunks.last == Data([0x42]) }
        XCTAssertEqual(recorder.terminalChunks, Array(repeating: Data([0x41]), count: 500) + [Data([0x42])])
    }

    private func recordEvents(
        from facade: AppleSessionCommandFacade,
        into recorder: SessionEventRecorder
    ) -> Task<Void, Never> {
        let events = facade.events
        return Task { @MainActor in
            for await event in events { recorder.append(event) }
        }
    }

    private func assertEventually(
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(predicate(), "condition did not become true", file: file, line: line)
    }

    private func makeHostKeyFixture() async -> HostKeyFixture {
        let box = HostKeyRequestBox()
        let challenge = HostKeyVerificationChallenge(
            endpoint: "example.test:22",
            fingerprint: "SHA256:test",
            keyType: "ssh-ed25519",
            isChanged: false,
            oldFingerprint: nil
        )
        let decision = Task { @MainActor in
            await withCheckedContinuation { continuation in
                box.request = HostKeyVerificationRequest(
                    challenge: challenge,
                    continuation: continuation
                )
            }
        }
        await assertEventually { box.request != nil }
        return HostKeyFixture(request: box.request!, decision: decision)
    }

    private func drainTmuxSubscriptionFlush() async {
        // Hydration defers the subscription flush to the next main-actor turn.
        await Task { @MainActor in }.value
        await Task { @MainActor in }.value
    }

    private func enterTmuxModeWithActivePane(_ tmux: TmuxController) {
        var entry = [UInt8](arrayLiteral: 0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70)
        entry.append(contentsOf: Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        tmux.ingest(entry)
        for number in 2...8 {
            tmux.ingest(Array(
                "%begin 0 \(number) 1\r\n%end 0 \(number) 1\r\n".utf8
            ))
        }
        tmux.ingest(Array("%window-add @1\r\n".utf8))
        tmux.ingest(Array("%window-pane-changed @1 %5\r\n".utf8))
        tmux.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
    }

    /// Agent Center's source factory defers navigation to the reveal path and
    /// sends planner keys to a tmux pane by name, through the facade.
    func testFactoryDefersJumpAndSendsPromptKeysByName() async throws {
        let session = connectedRecordingSession(transport: .ssh)
        let tmux = TmuxController(controlPath: .sideChannel)
        tmux.feedTerminal = { _ in }
        tmux.sendBytes = { _ in }
        var entry = [UInt8](arrayLiteral: 0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70)
        entry.append(contentsOf: Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        tmux.ingest(entry)
        for number in 2...20 {
            tmux.ingest(Array("%begin 0 \(number) 1\r\n%end 0 \(number) 1\r\n".utf8))
        }
        var wire: [String] = [], rawWrites = 0
        tmux.sendBytes = { wire.append(String(decoding: $0, as: UTF8.self)) }
        let source = AgentSessionSourceFactory.make(sessionID: session.host.id, hostName: "fixture", baseTransportLabel: "ssh",
            tmux: tmux, terminalBox: TerminalBox(traceLabel: "named-keys"), tmuxSessionName: { "rig" }, profiles: { [] },
            rawProcessProvider: { nil }, sessionCommands: AppleSessionCommandFacade(session: session, tmux: tmux),
            rawSend: { _ in rawWrites += 1 })
        let location = AgentLocation(sessionID: session.host.id, hostName: "fixture", transportLabel: "ssh+tmux",
            tmuxSessionName: "rig", windowID: 1, windowName: "agent", paneID: 3)
        source.jump(location)
        XCTAssertTrue(wire.isEmpty, "the reveal path owns the bounded focus request")
        let keys: [AgentPromptAnswerKey] = [.enter, .escape, .tab, .backTab, .up, .down, .left, .right, .shiftLeft, .controlRightBracket]
        for (number, key) in keys.enumerated() {
            wire.removeAll()
            let sending = Task { await source.send(location, Array(key.bytes.utf8)) }
            for _ in 0..<100 where wire.isEmpty { await Task.yield() }
            XCTAssertEqual(wire, ["send-keys -t %3 \(key.rawValue)\n"])
            tmux.ingest(Array("%begin 0 \(30 + number) 1\r\n%end 0 \(30 + number) 1\r\n".utf8))
            let acknowledged = await sending.value
            XCTAssertTrue(acknowledged)
        }
        XCTAssertEqual(rawWrites, 0)
    }

    /// `enterTmuxModeWithActivePane` plus the layout and attach replies that
    /// hydrate the window list; selection is refused on an unhydrated list.
    private func enterHydratedTmuxModeWithActivePane(_ tmux: TmuxController) {
        enterTmuxModeWithActivePane(tmux)
        hydrateTmuxWindowList(tmux)
    }

    private func hydrateTmuxWindowList(_ tmux: TmuxController) {
        tmux.ingest(Array("%layout-change @1 b25d,80x24,0,0,5 b25d,80x24,0,0,5 *\r\n".utf8))
        let metadata = ["%5", "0", "0", "pane title", "editor", "host", "0"].joined(separator: "\t")
        let replies: [(Int, String)] = [(9, "editor"), (10, metadata), (11, metadata), (12, "viewport"), (13, metadata), (14, "deep")]
        for (number, body) in replies {
            tmux.ingest(Array("%begin 0 \(number) 1\r\n\(body)\r\n%end 0 \(number) 1\r\n".utf8))
        }
    }

    private func connectedRecordingSession(transport: HostTransport) -> CommandRecordingSession {
        let session = CommandRecordingSession(hostID: UUID(), transport: transport)
        session.beginDirectAttempt(UUID())
        session.projectState(.connected)
        return session
    }
}

@MainActor
private struct TerminalOpacityHarness: View {
    let reference: TesseraTerminalContainer
    let candidate: TesseraTerminalContainer
    let candidateVisible: Bool

    var body: some View {
        HStack(spacing: 0) {
            ExistingTerminalContainerView(container: reference)
                .frame(width: 320, height: 240)
            ExistingTerminalContainerView(container: candidate)
                .frame(width: 320, height: 240)
                .opacity(candidateVisible ? 1 : 0)
        }
        .frame(width: 640, height: 240)
    }
}

@MainActor
private struct ExistingTerminalContainerView: UIViewRepresentable {
    let container: TesseraTerminalContainer

    func makeUIView(context: Context) -> TesseraTerminalContainer {
        container
    }

    func updateUIView(_ uiView: TesseraTerminalContainer, context: Context) {}
}

@MainActor
private final class CommandRecordingSession: AppleSessionBackendEventSource {
    let host: Host
    var state: SessionState = .idle {
        didSet { stateSubject.send(state) }
    }
    var remoteWorkingDirectory: String? {
        didSet { workingDirectorySubject.send(remoteWorkingDirectory) }
    }
    var pendingPathInjection: String?

    let outputStream: AsyncStream<[UInt8]>
    private let outputContinuation: AsyncStream<[UInt8]>.Continuation
    let appleAttemptOutputEvents: AsyncStream<SessionAttemptOutputChunk>
    private let appleAttemptOutputContinuation: AsyncStream<SessionAttemptOutputChunk>.Continuation
    private var preparedAttemptID: UUID?
    private let stateSubject = CurrentValueSubject<SessionState, Never>(.idle)
    private let workingDirectorySubject = CurrentValueSubject<String?, Never>(nil)
    private let challengeSubject = CurrentValueSubject<HostKeyVerificationRequest?, Never>(nil)
    private let disconnectProbe: DisconnectCallProbe

    private(set) var connectCallCount = 0
    private(set) var startedAttemptIDs: [UUID] = []
    var stateAfterConnect: SessionState = .connecting
    var disconnectCallCount: Int { disconnectProbe.count }
    private(set) var sentInputs: [[UInt8]] = []
    private(set) var resizeRequests: [(columns: Int, rows: Int)] = []

    var appleSessionStateEvents: AnyPublisher<SessionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    var appleWorkingDirectoryEvents: AnyPublisher<String?, Never> {
        workingDirectorySubject.eraseToAnyPublisher()
    }
    var appleHostKeyChallengeEvents: AnyPublisher<HostKeyVerificationRequest?, Never> {
        challengeSubject.eraseToAnyPublisher()
    }
    var appleActiveSessionAttemptID: UUID? { preparedAttemptID }

    init(
        hostID: UUID,
        transport: HostTransport = .ssh,
        disconnectProbe: DisconnectCallProbe? = nil
    ) {
        host = Host(id: hostID, transport: transport)
        self.disconnectProbe = disconnectProbe ?? DisconnectCallProbe()
        (outputStream, outputContinuation) = AsyncStream.makeStream(of: [UInt8].self)
        (appleAttemptOutputEvents, appleAttemptOutputContinuation) = AsyncStream.makeStream(
            of: SessionAttemptOutputChunk.self
        )
    }

    deinit {
        outputContinuation.finish()
        appleAttemptOutputContinuation.finish()
    }

    func prepareAppleSessionAttempt(_ attemptID: UUID) {
        preparedAttemptID = attemptID
    }

    func beginDirectAttempt(_ attemptID: UUID) {
        preparedAttemptID = attemptID
        state = .connecting
    }

    func tagAttempt(_ attemptID: UUID) {
        preparedAttemptID = attemptID
    }

    func connect() {
        connectCallCount += 1
        if let preparedAttemptID { startedAttemptIDs.append(preparedAttemptID) }
        state = stateAfterConnect
    }

    /// Synchronous MainActor observation point at the exact instant a
    /// backend send is applied, for queue-depth ground truth.
    var onSend: (() -> Void)?

    func send(_ bytes: [UInt8]) {
        sentInputs.append(bytes)
        onSend?()
    }

    func clearSentInputs() { sentInputs.removeAll(keepingCapacity: true) }

    func resize(cols: Int, rows: Int) {
        resizeRequests.append((cols, rows))
    }

    func disconnect() {
        disconnectProbe.count += 1
        state = .disconnected
    }

    func projectState(_ value: SessionState) { state = value }
    func projectChallenge(_ request: HostKeyVerificationRequest?) {
        challengeSubject.send(request)
    }
    func emit(_ bytes: [UInt8]) {
        outputContinuation.yield(bytes)
        guard let preparedAttemptID else { return }
        appleAttemptOutputContinuation.yield(SessionAttemptOutputChunk(
            attemptID: preparedAttemptID,
            bytes: bytes
        ))
    }
}

@MainActor
private final class DisconnectCallProbe {
    var count = 0
}

@MainActor
private final class SessionEventRecorder {
    private(set) var states: [SharedSessionState] = []
    private(set) var challenges: [SessionChallenge] = []
    private(set) var terminalChunks: [Data] = []
    private(set) var terminalReceipts: [TerminalOutputReceipt?] = []
    private(set) var terminalGenerations: [SessionGeneration] = []
    private(set) var recoverableWarnings: [CoreFailure] = []
    private(set) var authorities: [GridAuthoritySnapshot] = []

    func append(_ event: SessionEvent) {
        switch event {
        case .stateChanged(_, let state): states.append(state)
        case .challenge(_, let challenge): challenges.append(challenge)
        case .terminalBytes(let generation, let bytes, let receipt):
            terminalGenerations.append(generation)
            terminalChunks.append(bytes)
            terminalReceipts.append(receipt)
        case .recoverableWarning(_, let warning):
            recoverableWarnings.append(warning)
        case .gridAuthorityChanged(_, let authority):
            authorities.append(authority)
        default: break
        }
    }
}

@MainActor
private final class HostKeyRequestBox {
    var request: HostKeyVerificationRequest?
}

private final class HostKeyTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date = date.addingTimeInterval(interval)
    }
}

private struct HostKeyFixture {
    let request: HostKeyVerificationRequest
    let decision: Task<Bool, Never>
}
