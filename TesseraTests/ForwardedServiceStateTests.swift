import XCTest
import PortForwarding
@testable import Tessera

/// Whether anything answers behind a tunnel: the classification of the SSH
/// server's answer, the cadence, and the forwarder/manager state machine the
/// top-bar glyph reads. Host-free — the forwarders stand in the states an SSH
/// `start` would produce and their probes are scripted; the real direct-tcpip
/// probe is covered against a live host in `RealHostTransportIntegrationTests`.
@MainActor
final class ForwardedServiceStateTests: XCTestCase {

    // MARK: - Classification

    func testConnectFailedMeansNothingIsServing() {
        XCTAssertEqual(
            ForwardedServiceProbeResult.classifying(
                openFailureDescription: "NIOSSHError.channelSetupRejected: Reason: 2 connect failed: Connection refused"
            ),
            .notServing
        )
    }

    func testAdministrativelyProhibitedSaysNothingAboutTheService() {
        XCTAssertEqual(
            ForwardedServiceProbeResult.classifying(
                openFailureDescription: "NIOSSHError.channelSetupRejected: Reason: 1 administratively prohibited: open failed"
            ),
            .forwardingProhibited
        )
    }

    func testOtherReasonsAndUnreadableAnswersAreInconclusive() {
        for description in [
            "NIOSSHError.channelSetupRejected: Reason: 4 resource shortage",
            "NIOSSHError.channelSetupRejected: Reason: 3 unknown channel type",
            "NIOSSHError.channelSetupRejected",
            "NIOSSHError.channelSetupRejected: Reason: ",
            "NIOSSHError.channelSetupRejected: Reason: 22 connect failed",
        ] {
            XCTAssertEqual(
                ForwardedServiceProbeResult.classifying(openFailureDescription: description),
                .inconclusive,
                description
            )
        }
    }

    func testErrorsThatAreNotChannelRejectionsAreInconclusive() {
        struct Unrelated: Error {}
        XCTAssertEqual(ForwardedServiceProbeResult.classifying(Unrelated()), .inconclusive)
        XCTAssertEqual(
            ForwardedServiceProbeResult.classifying(DirectTCPIPError.channelOpenFailed(underlying: Unrelated())),
            .inconclusive
        )
        XCTAssertEqual(
            ForwardedServiceProbeResult.classifying(DirectTCPIPError.asyncWrapFailed(underlying: Unrelated())),
            .inconclusive
        )
    }

    // MARK: - Cadence

    func testCadenceByState() {
        let start = ContinuousClock.now
        func due(
            _ service: ForwardedServiceState,
            prohibited: Bool = false,
            streak: Int = 0,
            after seconds: Int
        ) -> Bool {
            ForwardedServiceCadence.isDue(
                service: service,
                forwardingProhibited: prohibited,
                unconfirmedStreak: streak,
                lastChecked: start,
                now: start.advanced(by: .seconds(seconds))
            )
        }

        XCTAssertTrue(ForwardedServiceCadence.isDue(
            service: .serving, forwardingProhibited: true, unconfirmedStreak: 99, lastChecked: nil, now: start
        ), "a target never looked at is due at once")

        XCTAssertFalse(due(.unknown, after: 4))
        XCTAssertTrue(due(.unknown, after: 5))
        XCTAssertFalse(due(.notServing, after: 4))
        XCTAssertTrue(due(.notServing, after: 5))
        XCTAssertFalse(due(.serving, after: 14))
        XCTAssertTrue(due(.serving, after: 15))
        XCTAssertFalse(due(.unknown, prohibited: true, after: 59))
        XCTAssertTrue(due(.unknown, prohibited: true, after: 60))

        // About a minute of quick looks, then the backed-off cadence.
        XCTAssertTrue(due(.notServing, streak: 11, after: 5))
        XCTAssertFalse(due(.notServing, streak: 12, after: 29))
        XCTAssertTrue(due(.notServing, streak: 12, after: 30))
        XCTAssertFalse(due(.unknown, streak: 40, after: 29))
        // A serving target is on its own cadence whatever came before.
        XCTAssertTrue(due(.serving, streak: 40, after: 15))
    }

    // MARK: - Forwarder

    func testProbeAnswersMoveTheServiceState() async throws {
        let script = ScriptedProbe([.serving, .notServing, .serving])
        let forwarder = listening(web, probe: script)

        XCTAssertEqual(forwarder.service, .unknown)
        XCTAssertFalse(forwarder.isServing)
        XCTAssertEqual(forwarder.listeningStatusText, String(localized: "listening · checking…"))

        forwarder.probeServiceIfDue(now: .now)
        try await waitUntil { forwarder.service == .serving }
        XCTAssertTrue(forwarder.isServing)
        XCTAssertEqual(forwarder.listeningStatusText, String(localized: "serving · 0 active"))

        forwarder.probeServiceIfDue(now: .now, force: true)
        try await waitUntil { forwarder.service == .notServing }
        XCTAssertFalse(forwarder.isServing)
        // Ungrouped: a port interpolated as a number reads "3,000".
        XCTAssertEqual(forwarder.listeningStatusText, "listening · nothing serving on remote port 3000")

        forwarder.probeServiceIfDue(now: .now, force: true)
        try await waitUntil { forwarder.service == .serving }
        XCTAssertEqual(script.calls, 3)
    }

    func testCadenceHoldsBetweenProbes() async throws {
        let script = ScriptedProbe([.serving, .serving])
        let forwarder = listening(web, probe: script)

        forwarder.probeServiceIfDue(now: .now)
        try await waitUntil { forwarder.service == .serving }

        // The answer stamped its own clock; a tick a moment later is not due.
        forwarder.probeServiceIfDue(now: .now)
        try await settle()
        XCTAssertEqual(script.calls, 1)

        forwarder.probeServiceIfDue(now: .now.advanced(by: .seconds(16)))
        try await waitUntil { script.calls == 2 }
    }

    func testAnUnansweredLookStillCountsAsALook() async throws {
        // Unknown, not serving: the serving cadence would hide a missing
        // stamp, since its interval outlasts the tick below either way.
        let script = ScriptedProbe([.inconclusive, .inconclusive])
        let forwarder = listening(web, probe: script)

        forwarder.probeServiceIfDue(now: .now)
        try await waitUntil { script.calls == 1 }
        try await settle()
        XCTAssertEqual(forwarder.service, .unknown)

        forwarder.probeServiceIfDue(now: .now.advanced(by: .seconds(1)))
        try await settle()
        XCTAssertEqual(script.calls, 1, "a timed-out look must not be retried on every tick")

        forwarder.probeServiceIfDue(now: .now.advanced(by: .seconds(6)))
        try await waitUntil { script.calls == 2 }
    }

    func testOneUnansweredLookKeepsTheLastAnswerAndASecondDropsIt() async throws {
        for known in [ForwardedServiceProbeResult.serving, .notServing] {
            let script = ScriptedProbe([known, .inconclusive, .inconclusive])
            let forwarder = listening(web, probe: script)
            let learned: ForwardedServiceState = known == .serving ? .serving : .notServing

            forwarder.probeServiceIfDue(now: .now)
            try await waitUntil { forwarder.service == learned }

            forwarder.probeServiceIfDue(now: .now, force: true)
            try await waitUntil { script.calls == 2 }
            try await settle()
            XCTAssertEqual(forwarder.service, learned, "one slow answer must not flicker the glyph")

            // A transport that died quietly answers nothing: the glyph must
            // not stay green on a tunnel that can no longer carry a page.
            forwarder.probeServiceIfDue(now: .now, force: true)
            try await waitUntil { forwarder.service == .unknown }
            XCTAssertFalse(forwarder.isServing)
            XCTAssertEqual(forwarder.listeningStatusText, String(localized: "listening · checking…"))
        }
    }

    func testAnAnswerBetweenUnansweredLooksStartsTheCountAgain() async throws {
        let script = ScriptedProbe([.serving, .inconclusive, .serving, .inconclusive])
        let forwarder = listening(web, probe: script)

        forwarder.probeServiceIfDue(now: .now)
        try await waitUntil { forwarder.service == .serving }
        for call in 2...4 {
            forwarder.probeServiceIfDue(now: .now, force: true)
            try await waitUntil { script.calls == call }
            try await settle()
        }
        XCTAssertEqual(forwarder.service, .serving)
    }

    func testOneProbeInFlightAtATime() async throws {
        let gate = GatedProbe()
        let forwarder = listening(web, probe: gate)

        forwarder.probeServiceIfDue(now: .now)
        try await waitUntil { gate.calls == 1 }
        forwarder.probeServiceIfDue(now: .now, force: true)
        forwarder.probeServiceIfDue(now: .now.advanced(by: .seconds(60)))
        try await settle()
        XCTAssertEqual(gate.calls, 1)

        gate.release(.serving)
        try await waitUntil { forwarder.service == .serving }
        forwarder.probeServiceIfDue(now: .now, force: true)
        try await waitUntil { gate.calls == 2 }
        gate.release(.serving)
    }

    func testUnconfirmedTargetsBackOffUntilSomeoneLooksAgain() async throws {
        let script = ScriptedProbe(Array(repeating: .notServing, count: 20) + [.serving])
        let forwarder = listening(web, probe: script)
        var clock = ContinuousClock.now

        // Twelve quick looks, five seconds apart.
        for look in 1...12 {
            forwarder.probeServiceIfDue(now: clock)
            try await waitUntil { script.calls == look }
            try await waitUntil { !forwarder.probeInFlightForTesting }
            clock = ContinuousClock.now.advanced(by: .seconds(5))
        }

        // The thirteenth waits for the backed-off cadence.
        forwarder.probeServiceIfDue(now: ContinuousClock.now.advanced(by: .seconds(29)))
        try await settle()
        XCTAssertEqual(script.calls, 12)
        forwarder.probeServiceIfDue(now: ContinuousClock.now.advanced(by: .seconds(31)))
        try await waitUntil { script.calls == 13 }
        try await waitUntil { !forwarder.probeInFlightForTesting }

        // Someone starts looking again: quick looks resume.
        forwarder.restartServiceCadence()
        forwarder.probeServiceIfDue(now: ContinuousClock.now.advanced(by: .seconds(6)))
        try await waitUntil { script.calls == 14 }
    }

    func testNonWebRulesAreNeverProbedActively() async throws {
        let script = ScriptedProbe([.serving])
        let forwarder = listening(
            PortForwardRule.localForward(localPort: 15_432, remotePort: 5_432, label: "postgres"),
            probe: script
        )

        forwarder.probeServiceIfDue(now: .now, force: true)
        try await settle()
        XCTAssertEqual(script.calls, 0)
        XCTAssertFalse(forwarder.probesServiceActively)
        XCTAssertFalse(forwarder.watchesService)
        XCTAssertEqual(forwarder.listeningStatusText, String(localized: "listening · 0 active"))

        // Serving only while a connection is in flight.
        forwarder.harnessForceState(.active(connectionCount: 1))
        XCTAssertTrue(forwarder.isServing)
        forwarder.harnessForceState(.listening)
        XCTAssertFalse(forwarder.isServing)
    }

    func testHTTPSTargetsAreNeverProbedActively() async throws {
        let script = ScriptedProbe([.serving])
        let forwarder = listening(
            PortForwardRule.localForward(localPort: 18_443, remotePort: 8_443, label: "tls"),
            probe: script
        )
        XCTAssertEqual(ForwardedWebPolicy.webTarget(for: forwarder.rule)?.scheme, "https")

        forwarder.probeServiceIfDue(now: .now, force: true)
        try await settle()
        XCTAssertEqual(script.calls, 0)
        XCTAssertFalse(forwarder.probesServiceActively)
    }

    func testAConnectionInFlightIsProofAndIsNotProbed() async throws {
        let script = ScriptedProbe([.notServing])
        let forwarder = listening(web, probe: script)
        forwarder.harnessForceState(.active(connectionCount: 1))

        forwarder.probeServiceIfDue(now: .now, force: true)
        try await settle()
        XCTAssertEqual(script.calls, 0)
        XCTAssertTrue(forwarder.isServing)
    }

    func testRetargetingForgetsTheOldTargetAndDropsItsProbe() async throws {
        let gate = GatedProbe()
        let forwarder = listening(web, probe: gate)

        forwarder.probeServiceIfDue(now: .now)
        try await waitUntil { gate.calls == 1 }

        var retargeted = forwarder.rule
        retargeted.target = PortForwardEndpoint(host: "localhost", port: 4_000)
        forwarder.update(rule: retargeted)
        XCTAssertEqual(forwarder.service, .unknown)

        // The answer about port 3000 arrives after the edit: it is not about
        // this rule any more.
        gate.release(.serving)
        try await waitUntil { !gate.isWaiting }
        try await settle()
        XCTAssertEqual(forwarder.service, .unknown)

        // The slot is free again and the new target is due at once.
        forwarder.probeServiceIfDue(now: .now)
        try await waitUntil { gate.calls == 2 }
        XCTAssertEqual(gate.lastTarget?.port, 4_000)
        gate.release(.serving)
        try await waitUntil { forwarder.service == .serving }
    }

    func testALabelEditKeepsWhatWasLearned() async throws {
        let forwarder = listening(web, probe: ScriptedProbe([.serving]))
        forwarder.probeServiceIfDue(now: .now)
        try await waitUntil { forwarder.service == .serving }

        var relabelled = forwarder.rule
        relabelled.label = "renamed"
        forwarder.update(rule: relabelled)
        XCTAssertEqual(forwarder.service, .serving)
    }

    func testARuleThatStopsBeingWatchedForgetsWhatItLearned() async throws {
        let forwarder = listening(web, probe: ScriptedProbe([.serving]))
        forwarder.probeServiceIfDue(now: .now)
        try await waitUntil { forwarder.service == .serving }

        // Same target, but a listener the shared web policy no longer calls
        // a page: nothing will look at it again, so its last answer must go.
        var unwatched = forwarder.rule
        unwatched.bind = PortForwardEndpoint(host: "0.0.0.0", port: unwatched.bind.port)
        forwarder.update(rule: unwatched)
        XCTAssertFalse(forwarder.watchesService)
        XCTAssertEqual(forwarder.service, .unknown)
        XCTAssertFalse(forwarder.isServing)
    }

    func testStopForgetsTheService() async throws {
        let forwarder = listening(web, probe: ScriptedProbe([.serving]))
        forwarder.probeServiceIfDue(now: .now)
        try await waitUntil { forwarder.service == .serving }

        await forwarder.stop()
        XCTAssertEqual(forwarder.state, .idle)
        XCTAssertEqual(forwarder.service, .unknown)
        XCTAssertFalse(forwarder.isServing)
    }

    func testProhibitedForwardingIsNotServingAndStopsSayingChecking() async throws {
        let forwarder = listening(web, probe: ScriptedProbe([.forwardingProhibited]))
        forwarder.probeServiceIfDue(now: .now)
        try await waitUntil { forwarder.forwardingProhibited }

        XCTAssertEqual(forwarder.service, .unknown)
        XCTAssertFalse(forwarder.isServing)
        XCTAssertEqual(forwarder.listeningStatusText, String(localized: "listening · 0 active"))
    }

    // MARK: - Manager

    func testManagerCountsServingForwardersAndProbesOnDemand() async throws {
        let manager = PortForwarderManager()
        let devServer = listening(web, probe: ScriptedProbe([.serving]))
        let metrics = listening(
            PortForwardRule.localForward(localPort: 9_091, remotePort: 9_090, label: "metrics"),
            probe: ScriptedProbe([.notServing])
        )
        let postgres = listening(
            PortForwardRule.localForward(localPort: 15_432, remotePort: 5_432, label: "postgres"),
            probe: ScriptedProbe([.serving])
        )
        for forwarder in [devServer, metrics, postgres] {
            manager.harnessInsert(forwarder)
        }
        XCTAssertEqual(manager.servingCount, 0)

        manager.probeServicesNow()
        try await waitUntil { devServer.service == .serving && metrics.service == .notServing }
        XCTAssertEqual(manager.servingCount, 1)
        XCTAssertEqual(postgres.service, .unknown)
    }

    func testMonitoringStopsWithItsTask() async throws {
        let script = ScriptedProbe(Array(repeating: .notServing, count: 10))
        let manager = PortForwarderManager()
        manager.harnessInsert(listening(web, probe: script))

        let monitor = Task { await manager.monitorServices() }
        try await waitUntil { script.calls == 1 }
        monitor.cancel()
        await monitor.value

        let callsAtCancel = script.calls
        try await Task.sleep(for: .seconds(6))
        XCTAssertEqual(script.calls, callsAtCancel, "a cancelled monitor must not keep dialling")
    }

    // MARK: - Fixtures

    private var web: PortForwardRule {
        PortForwardRule.localForward(localPort: 18_080, remotePort: 3_000, label: "dev server")
    }

    private func listening(_ rule: PortForwardRule, probe: ProbeScript) -> PortForwarder {
        let forwarder = PortForwarder(rule: rule)
        forwarder.harnessForceState(.listening)
        forwarder.harnessServiceProbe = { target in await probe.answer(target) }
        return forwarder
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("condition not met within \(timeout)", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Long enough for a spawned probe task to have run and reported.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }
}

@MainActor
private protocol ProbeScript: AnyObject {
    func answer(_ target: PortForwardEndpoint) async -> ForwardedServiceProbeResult
}

/// Answers from a list, in order.
@MainActor
private final class ScriptedProbe: ProbeScript {
    private var answers: [ForwardedServiceProbeResult]
    private(set) var calls = 0

    init(_ answers: [ForwardedServiceProbeResult]) {
        self.answers = answers
    }

    func answer(_ target: PortForwardEndpoint) async -> ForwardedServiceProbeResult {
        calls += 1
        return answers.isEmpty ? .inconclusive : answers.removeFirst()
    }
}

/// Holds each probe open until the test releases it.
@MainActor
private final class GatedProbe: ProbeScript {
    private(set) var calls = 0
    private(set) var lastTarget: PortForwardEndpoint?
    private var pending: CheckedContinuation<ForwardedServiceProbeResult, Never>?

    var isWaiting: Bool { pending != nil }

    func answer(_ target: PortForwardEndpoint) async -> ForwardedServiceProbeResult {
        calls += 1
        lastTarget = target
        return await withCheckedContinuation { pending = $0 }
    }

    func release(_ result: ForwardedServiceProbeResult) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: result)
    }
}
