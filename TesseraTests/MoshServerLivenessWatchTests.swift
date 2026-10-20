import XCTest
import Citadel
import TesseraSessionCore
@testable import Tessera

@MainActor
final class MoshServerLivenessWatchTests: XCTestCase {
    func test_outageUsesContactAgeAtTheStrictServerLateBoundary() {
        XCTAssertNil(MoshOutageTiming.next(
            previous: nil, connected: true, reachable: true,
            serverContactAgeMilliseconds: 6_500, replyAgeMilliseconds: 10_000, now: 100
        ))
        XCTAssertNil(MoshOutageTiming.next(
            previous: nil, connected: true, reachable: false,
            serverContactAgeMilliseconds: 6_500, replyAgeMilliseconds: 10_000, now: 100
        ))
        let outage = MoshOutageTiming.next(
            previous: nil, connected: true, reachable: false,
            serverContactAgeMilliseconds: 6_501, replyAgeMilliseconds: 0, now: 100
        )
        XCTAssertEqual(outage, MoshOutageTiming(startedAt: 100, kind: .contact, seconds: 6))
        XCTAssertEqual(MoshOutageTiming.next(
            previous: outage, connected: true, reachable: false,
            serverContactAgeMilliseconds: 6_999, replyAgeMilliseconds: 0, now: 101
        )?.seconds, 6)
        XCTAssertEqual(MoshOutageTiming.next(
            previous: outage, connected: true, reachable: false,
            serverContactAgeMilliseconds: 7_000, replyAgeMilliseconds: 0, now: 101
        )?.seconds, 7)
    }

    func test_outageUsesReplyAgeAndPrefersLateServerContact() {
        let reply = MoshOutageTiming.next(
            previous: nil, connected: true, reachable: false,
            serverContactAgeMilliseconds: 6_500, replyAgeMilliseconds: 10_001, now: 100
        )
        XCTAssertEqual(reply, MoshOutageTiming(startedAt: 100, kind: .reply, seconds: 10))
        XCTAssertEqual(MoshOutageTiming.next(
            previous: reply, connected: true, reachable: false,
            serverContactAgeMilliseconds: 0, replyAgeMilliseconds: 10_999, now: 101
        )?.seconds, 10)
        XCTAssertEqual(MoshOutageTiming.next(
            previous: reply, connected: true, reachable: false,
            serverContactAgeMilliseconds: 0, replyAgeMilliseconds: 11_000, now: 101
        )?.seconds, 11)
        XCTAssertEqual(MoshOutageTiming.next(
            previous: nil, connected: true, reachable: false,
            serverContactAgeMilliseconds: 8_999, replyAgeMilliseconds: 20_000, now: 100
        ), MoshOutageTiming(startedAt: 100, kind: .contact, seconds: 8))
    }

    func test_outagePreservesIdentityAndMonotonicAgeUntilTheKindChanges() {
        let outage = MoshOutageTiming(startedAt: 100, kind: .reply, seconds: 12)
        XCTAssertEqual(MoshOutageTiming.next(
            previous: outage, connected: true, reachable: false,
            serverContactAgeMilliseconds: 0, replyAgeMilliseconds: 11_000, now: 50
        ), outage)
        XCTAssertEqual(MoshOutageTiming.next(
            previous: outage, connected: true, reachable: false,
            serverContactAgeMilliseconds: 7_000, replyAgeMilliseconds: 13_000, now: 101
        ), MoshOutageTiming(startedAt: 100, kind: .contact, seconds: 7))
        XCTAssertEqual(MoshOutageTiming.next(
            previous: outage, connected: true, reachable: false,
            serverContactAgeMilliseconds: 0, replyAgeMilliseconds: 15_999, now: 50
        ), MoshOutageTiming(startedAt: 100, kind: .reply, seconds: 15))
    }

    func test_outageSwitchesFromContactToReplyWithoutAnotherAnnouncementIdentity() {
        let outage = MoshOutageTiming(startedAt: 100, kind: .contact, seconds: 20)
        XCTAssertEqual(MoshOutageTiming.next(
            previous: outage, connected: true, reachable: false,
            serverContactAgeMilliseconds: 0, replyAgeMilliseconds: 11_000, now: 120
        ), MoshOutageTiming(startedAt: 100, kind: .reply, seconds: 11))
    }

    func test_outageClearsOnRecoveryOrDisconnectAndRestartsItsIdentity() {
        let outage = MoshOutageTiming(startedAt: 100, kind: .contact, seconds: 12)
        for (connected, reachable) in [(true, true), (false, false)] {
            XCTAssertNil(MoshOutageTiming.next(
                previous: outage, connected: connected, reachable: reachable,
                serverContactAgeMilliseconds: 15_000, replyAgeMilliseconds: 20_000, now: 116
            ))
        }
        XCTAssertEqual(MoshOutageTiming.next(
            previous: nil, connected: true, reachable: false,
            serverContactAgeMilliseconds: 7_000, replyAgeMilliseconds: 0, now: 120
        )?.startedAt, 120)
        XCTAssertNil(MoshOutageTiming.next(
            previous: outage, connected: true, reachable: false,
            serverContactAgeMilliseconds: 15_000, replyAgeMilliseconds: 20_000, now: .nan
        ))
        XCTAssertNotNil(MoshOutageTiming.next(
            previous: nil, connected: true, reachable: false,
            serverContactAgeMilliseconds: .max, replyAgeMilliseconds: 0, now: 120
        ))
    }

    // MARK: - Watch

    func test_watchRunsOnlyWhileConnectedUnreachableActiveWithAPID() {
        let running = MoshServerLivenessWatch.Conditions(
            isSessionConnected: true,
            isTransportReachable: false,
            isAppInForeground: true,
            serverPID: 4242
        )
        XCTAssertEqual(running.watchedPID, 4242)

        var notConnected = running
        notConnected.isSessionConnected = false
        var reachable = running
        reachable.isTransportReachable = true
        var inactive = running
        inactive.isAppInForeground = false
        var noPID = running
        noPID.serverPID = nil
        var badPID = running
        badPID.serverPID = 0
        for conditions in [notConnected, reachable, inactive, noPID, badPID] {
            XCTAssertNil(conditions.watchedPID, "\(conditions)")
        }
    }

    func test_hostDownBacksOffOnTheLadderUntilTheHostSaysGone() async {
        let script = ScriptedProbe([
            .hostUnreachable, .hostUnreachable, .hostUnreachable,
            .hostUnreachable, .hostUnreachable, .gone,
        ])
        let clock = RecordingSleeps()
        let gone = expectation(description: "server gone")
        var gonePIDs: [Int] = []
        let watch = MoshServerLivenessWatch(
            probe: { pid in await script.next(pid: pid) },
            graceSleep: { seconds in clock.grace(seconds) },
            backoffSleep: { seconds, generation in clock.backoff(seconds, generation: generation) },
            onServerGone: { pid in
                gonePIDs.append(pid)
                gone.fulfill()
            }
        )

        watch.update(.unreachable(pid: 4242))
        await fulfillment(of: [gone], timeout: 5)

        XCTAssertEqual(gonePIDs, [4242])
        XCTAssertEqual(script.probedPIDs, Array(repeating: 4242, count: 6))
        XCTAssertEqual(clock.graceDelays, [MoshServerLivenessPolicy.unreachableGraceSeconds])
        XCTAssertEqual(clock.backoffDelays, [2, 4, 8, 15, 15])
        XCTAssertEqual(
            MoshServerLivenessPolicy.nextProbeDelaySeconds(after: .hostUnreachable, consecutiveHostFailures: 40),
            60,
            "a host down for hours is asked once a minute, not every 15 s"
        )
        XCTAssertEqual(watch.probeCount, 6)
        XCTAssertEqual(watch.lastOutcome, .gone)
        XCTAssertFalse(watch.isRunning)
    }

    func test_answersThatSettleNothingRecheckOnTheSettledIntervalAndResetTheLadder() async {
        let script = ScriptedProbe([
            .hostUnreachable, .hostUnreachable, .alive, .hostUnreachable, .unknown, .gone,
        ])
        let clock = RecordingSleeps()
        let gone = expectation(description: "server gone")
        let watch = MoshServerLivenessWatch(
            probe: { pid in await script.next(pid: pid) },
            graceSleep: { seconds in clock.grace(seconds) },
            backoffSleep: { seconds, generation in clock.backoff(seconds, generation: generation) },
            onServerGone: { _ in gone.fulfill() }
        )

        watch.update(.unreachable(pid: 7))
        await fulfillment(of: [gone], timeout: 5)

        XCTAssertEqual(clock.backoffDelays, [2, 4, 60, 2, 60])
    }

    /// A probe that put Face ID in front of the user never repeats it on a
    /// timer while the server is there or the user declined; a destination
    /// that was still unreachable after the prompt (behind a jump host) is
    /// asked again no more than once a settled interval. One that asked
    /// nothing keeps the timed ladder.
    func test_answersThatAskedTheOwnerWaitForAWakeOrTheSettledInterval() async {
        let script = ScriptedProbe([
            .init(outcome: .hostUnreachable),
            .init(outcome: .hostUnreachable, askedOwner: true),
            .init(outcome: .alive, askedOwner: true),
            .init(outcome: .unknown, askedOwner: true),
            .init(outcome: .gone, askedOwner: true),
        ])
        let clock = RecordingSleeps()
        let gone = expectation(description: "server gone")
        let watch = MoshServerLivenessWatch(
            probe: { pid in await script.next(pid: pid) },
            graceSleep: { seconds in clock.grace(seconds) },
            backoffSleep: { seconds, generation in clock.backoff(seconds, generation: generation) },
            onServerGone: { _ in gone.fulfill() }
        )

        watch.update(.unreachable(pid: 5))
        await fulfillment(of: [gone], timeout: 5)

        XCTAssertEqual(clock.requestedDelays, [2, 60, nil, nil])
    }

    /// The wake generation is read before each probe, so a path change that
    /// lands while the probe runs (a VPN coming up mid-login) ends the delay
    /// that follows at once instead of being lost.
    func test_aSignalDuringAProbeEndsTheDelayThatFollows() async {
        let wake = ConnectivityRetryWake(observesSystemEvents: false)
        var probes = 0
        let gone = expectation(description: "server gone")
        let watch = MoshServerLivenessWatch(
            probe: { _ in
                probes += 1
                if probes == 1 {
                    wake.signal(reason: "path changed mid-probe")
                    return .init(outcome: .alive)
                }
                return .init(outcome: .gone)
            },
            graceSleep: { _ in true },
            backoffSleep: { seconds, generation in
                await wake.sleep(seconds: seconds, unlessSignalledSince: generation) != .cancelled
            },
            wakeGeneration: { wake.generation },
            onServerGone: { _ in gone.fulfill() }
        )

        let started = Date()
        watch.update(.unreachable(pid: 3))
        await fulfillment(of: [gone], timeout: 5)

        XCTAssertEqual(probes, 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the 60 s recheck was skipped")
    }

    /// The probe belongs to a session; once that session is gone the watch
    /// stops instead of probing nothing on a timer forever.
    func test_aProbeWithoutAnOwnerStopsTheWatch() async {
        var probes = 0
        var goneCount = 0
        let watch = MoshServerLivenessWatch(
            probe: { _ in
                probes += 1
                return nil
            },
            graceSleep: { _ in true },
            backoffSleep: { _, _ in true },
            onServerGone: { _ in goneCount += 1 }
        )

        watch.update(.unreachable(pid: 13))
        await waitUntil { !watch.isRunning }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(probes, 1)
        XCTAssertEqual(watch.probeCount, 0)
        XCTAssertEqual(goneCount, 0)
    }

    func test_reachabilityReturningStopsTheWatchAndALaterLossStartsOverFromGrace() async {
        let script = ScriptedProbe([.hostUnreachable, .hostUnreachable])
        let clock = RecordingSleeps()
        let parked = expectation(description: "parked in backoff")
        parked.assertForOverFulfill = false
        let wake = ConnectivityRetryWake(observesSystemEvents: false)
        var goneCount = 0
        let watch = MoshServerLivenessWatch(
            probe: { pid in await script.next(pid: pid) },
            graceSleep: { seconds in clock.grace(seconds) },
            backoffSleep: { seconds, generation in
                _ = clock.backoff(seconds, generation: generation)
                parked.fulfill()
                return await wake.sleep(seconds: nil) != .cancelled
            },
            onServerGone: { _ in goneCount += 1 }
        )

        watch.update(.unreachable(pid: 9))
        await fulfillment(of: [parked], timeout: 5)
        XCTAssertTrue(watch.isRunning)

        var recovered = MoshServerLivenessWatch.Conditions.unreachable(pid: 9)
        recovered.isTransportReachable = true
        watch.update(recovered)
        XCTAssertFalse(watch.isRunning)
        await waitUntil { wake.sleeperCount == 0 }

        watch.update(.unreachable(pid: 9))
        XCTAssertTrue(watch.isRunning)
        await waitUntil { script.probedPIDs.count == 2 }
        XCTAssertEqual(clock.graceDelays.count, 2, "a new loss pays the grace period again")
        XCTAssertEqual(goneCount, 0)
        watch.stop(reason: "test")
    }

    func test_anAnswerThatArrivesAfterTheWatchStoppedIsDiscarded() async {
        let gate = ProbeGate()
        var goneCount = 0
        let watch = MoshServerLivenessWatch(
            probe: { _ in await gate.wait() },
            graceSleep: { _ in true },
            backoffSleep: { _, _ in true },
            onServerGone: { _ in goneCount += 1 }
        )

        watch.update(.unreachable(pid: 11))
        await waitUntil { gate.isWaiting }
        watch.stop(reason: "test")
        gate.answer(.init(outcome: .gone))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(goneCount, 0)
        XCTAssertEqual(watch.probeCount, 0)
    }

    func test_aNewServerPIDRestartsTheWatchForThatPID() async {
        let script = ScriptedProbe([.hostUnreachable, .gone])
        let gone = expectation(description: "server gone")
        let parked = expectation(description: "first pid parked")
        let wake = ConnectivityRetryWake(observesSystemEvents: false)
        var gonePIDs: [Int] = []
        var parkedOnce = false
        let watch = MoshServerLivenessWatch(
            probe: { pid in await script.next(pid: pid) },
            graceSleep: { _ in true },
            backoffSleep: { _, _ in
                if !parkedOnce {
                    parkedOnce = true
                    parked.fulfill()
                }
                return await wake.sleep(seconds: nil) != .cancelled
            },
            onServerGone: { pid in
                gonePIDs.append(pid)
                gone.fulfill()
            }
        )

        watch.update(.unreachable(pid: 1))
        await fulfillment(of: [parked], timeout: 5)
        watch.update(.unreachable(pid: 2))
        await fulfillment(of: [gone], timeout: 5)

        XCTAssertEqual(script.probedPIDs, [1, 2])
        XCTAssertEqual(gonePIDs, [2])
    }

    // MARK: - Retry wake

    func test_aSignalWakesEverySleeperAtOnce() async {
        let wake = ConnectivityRetryWake(observesSystemEvents: false)
        let first = Task { await wake.sleep(seconds: 60) }
        let second = Task { await wake.sleep(seconds: nil) }
        await waitUntil { wake.sleeperCount == 2 }

        wake.signal(reason: "test")

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .signalled)
        XCTAssertEqual(secondOutcome, .signalled)
        XCTAssertEqual(wake.sleeperCount, 0)
    }

    func test_aSignalDuringTheAttemptSkipsTheBackoffThatFollows() async {
        let wake = ConnectivityRetryWake(observesSystemEvents: false)
        let observed = wake.generation
        wake.signal(reason: "path changed mid-attempt")

        let outcome = await wake.sleep(seconds: 60, unlessSignalledSince: observed)

        XCTAssertEqual(outcome, .signalled)
        XCTAssertEqual(wake.sleeperCount, 0)
        let unchanged = wake.generation
        let elapsed = await wake.sleep(seconds: 0.01, unlessSignalledSince: unchanged)
        XCTAssertEqual(elapsed, .elapsed)
    }

    func test_cancellingASleeperEndsItsWait() async {
        let wake = ConnectivityRetryWake(observesSystemEvents: false)
        let sleeper = Task { await wake.sleep(seconds: 60) }
        await waitUntil { wake.sleeperCount == 1 }

        sleeper.cancel()

        let outcome = await sleeper.value
        XCTAssertEqual(outcome, .cancelled)
        await waitUntil { wake.sleeperCount == 0 }
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met within \(timeout)s", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private extension MoshServerLivenessWatch.Conditions {
    static func unreachable(pid: Int) -> Self {
        Self(
            isSessionConnected: true,
            isTransportReachable: false,
            isAppInForeground: true,
            serverPID: pid
        )
    }
}

@MainActor
private final class ScriptedProbe {
    private var answers: [MoshServerLivenessWatch.ProbeAnswer]
    private(set) var probedPIDs: [Int] = []

    init(_ outcomes: [MoshServerLivenessPolicy.Outcome]) {
        answers = outcomes.map { .init(outcome: $0) }
    }

    init(_ answers: [MoshServerLivenessWatch.ProbeAnswer]) {
        self.answers = answers
    }

    func next(pid: Int) async -> MoshServerLivenessWatch.ProbeAnswer? {
        probedPIDs.append(pid)
        await Task.yield()
        return answers.isEmpty ? .init(outcome: .hostUnreachable) : answers.removeFirst()
    }
}

@MainActor
private final class RecordingSleeps {
    private(set) var graceDelays: [TimeInterval] = []
    /// Every delay the watch asked for; nil waits for a wake signal only.
    private(set) var requestedDelays: [TimeInterval?] = []
    var backoffDelays: [TimeInterval] { requestedDelays.compactMap { $0 } }

    func grace(_ seconds: TimeInterval) -> Bool {
        graceDelays.append(seconds)
        return true
    }

    func backoff(_ seconds: TimeInterval?, generation _: UInt64) -> Bool {
        requestedDelays.append(seconds)
        return true
    }
}

@MainActor
private final class ProbeGate {
    private var continuation: CheckedContinuation<MoshServerLivenessWatch.ProbeAnswer?, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async -> MoshServerLivenessWatch.ProbeAnswer? {
        await withCheckedContinuation { continuation = $0 }
    }

    func answer(_ answer: MoshServerLivenessWatch.ProbeAnswer) {
        continuation?.resume(returning: answer)
        continuation = nil
    }
}

final class MoshServerLossRecoveryTests: XCTestCase {

    /// Reconnecting a tmux session or a bare shell is what the user would do
    /// by hand; a custom launch command runs again only under "always".
    func test_rebuildsWhatReconnectingByHandWouldAndKeepsLaunchCommands() {
        typealias Recovery = MoshServerLossRecovery
        for mode in [HostLaunchMode.autoTmux, .pinnedTmux] {
            for policy in SessionRestorePolicy.allCases {
                XCTAssertEqual(
                    Recovery.decide(launchMode: mode, launchCommand: "ignored", restorePolicy: policy, isAppLocked: false),
                    .rebuild,
                    "\(mode) \(policy)"
                )
            }
        }
        for command in [nil, "", "  \n"] {
            XCTAssertEqual(
                Recovery.decide(launchMode: .customCommand, launchCommand: command, restorePolicy: .never, isAppLocked: false),
                .rebuild,
                "a bare login shell is safe to reopen"
            )
        }
        XCTAssertEqual(
            Recovery.decide(launchMode: .customCommand, launchCommand: "./deploy.sh", restorePolicy: .always, isAppLocked: false),
            .rebuild
        )
        for policy in [SessionRestorePolicy.ask, .never] {
            XCTAssertEqual(
                Recovery.decide(launchMode: .customCommand, launchCommand: "./deploy.sh", restorePolicy: policy, isAppLocked: false),
                .keepForLaunchCommand
            )
        }
        XCTAssertEqual(
            Recovery.decide(launchMode: .autoTmux, launchCommand: nil, restorePolicy: .always, isAppLocked: true),
            .keepWhileLocked
        )
    }
}

@MainActor
final class MoshServerLivenessProbeTests: XCTestCase {

    /// Only a failure to reach or log in to the host keeps the ladder going.
    /// Credentials, host-key trust and cancellation say nothing about the
    /// server, including when a bastion hop wraps them.
    func test_failuresThatNeedTheUserAreUnknownNotUnreachable() {
        let refused = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
        XCTAssertEqual(MoshSession.livenessOutcome(for: refused), .hostUnreachable)
        XCTAssertEqual(
            MoshSession.livenessOutcome(for: SSHChainHopError(hopIndex: 0, hopLabel: "bastion", underlying: refused)),
            .hostUnreachable
        )
        let needsTheUser: [Error] = [
            CancellationError(),
            AuthResolutionError.biometricCancelled,
            AuthResolutionError.appLocked,
            HostKeyRejectedError(),
            SSHChainHopError(hopIndex: 0, hopLabel: "bastion", underlying: AuthResolutionError.biometricCancelled),
            SSHChainHopError(hopIndex: 1, hopLabel: "inner", underlying: HostKeyRejectedError()),
        ]
        for error in needsTheUser {
            XCTAssertEqual(MoshSession.livenessOutcome(for: error), .unknown, "\(error)")
        }
        XCTAssertEqual(
            MoshSession.livenessOutcome(for: SSHClientError.allAuthenticationOptionsFailed),
            .unknown,
            "a host that refuses the key is up; the credential is the user's to fix"
        )
        XCTAssertEqual(
            MoshSession.livenessOutcome(for: SSHClientError.channelCreationFailed),
            .hostUnreachable
        )
    }

    /// The preflight waits for the identification line however TCP splits
    /// it, after any lines a server may send first, and accepts nothing else.
    func test_theSSHIdentificationLineIsReadAcrossSplitsAndPreambles() {
        func scan(_ text: String) -> MoshSession.SSHIdentificationScan {
            MoshSession.scanSSHIdentification(Array(text.utf8))
        }
        XCTAssertEqual(scan("SSH-2.0-OpenSSH_9.9\r\n"), .identified)
        XCTAssertEqual(scan("SSH-2.0-Tailscale"), .identified)
        XCTAssertEqual(scan(""), .needMore)
        XCTAssertEqual(scan("SS"), .needMore, "the banner's first bytes alone")
        XCTAssertEqual(scan("Notice: authorized use only\r\n"), .needMore, "a preamble line")
        XCTAssertEqual(scan("Notice: authorized use only\r\nSSH-2.0-OpenSSH_9.9\r\n"), .identified)
        XCTAssertEqual(scan("Notice\r\nSS"), .needMore)
        XCTAssertEqual(scan("Notice mentions SSH-2.0 mid-line\r\n"), .needMore, "only a line start counts")
        let junk = String(repeating: "x", count: 100) + "\r\n"
        XCTAssertEqual(scan(String(repeating: junk, count: 90)), .notSSH)
        // Reads that keep ending in a partial marker cannot outrun the limit.
        let teasing = String(repeating: "x", count: 1_021) + "\nSS"
        XCTAssertEqual(scan(String(repeating: teasing, count: 7)), .needMore, "still under 8 KiB")
        XCTAssertEqual(scan(String(repeating: teasing, count: 8)), .notSSH)
        XCTAssertEqual(scan(String(repeating: teasing, count: 12)), .notSSH)
        XCTAssertEqual(
            scan(String(repeating: "x", count: 8_190) + "\nSSH-2.0-late\r\n"),
            .notSSH,
            "the identification line has to start within the limit"
        )
    }

    /// A probe is charged only for prompts its own connection began.
    /// Another tab's prompt meanwhile is not its own, and a sheet the system
    /// took down asked nothing the user answered.
    func test_aProbeIsChargedOnlyForPromptsItsOwnConnectionBegan() async {
        let mine = SSHPromptAttribution()
        let other = SSHPromptAttribution()
        SSHPromptAttribution.$current.withValue(other) {
            SSHHandshakePromptGate.begin()
            SSHHandshakePromptGate.end()
        }
        XCTAssertTrue(other.askedOwner)
        XCTAssertFalse(mine.askedOwner, "another connection's prompt")

        // The key's Face ID runs in a task the connection starts.
        await SSHPromptAttribution.$current.withValue(mine) {
            await Task { @MainActor in
                SSHHandshakePromptGate.begin()
                SSHHandshakePromptGate.end()
            }.value
        }
        XCTAssertTrue(mine.askedOwner)

        let interrupted = SSHPromptAttribution()
        interrupted.noteBegan()
        interrupted.noteInterruptedBySystem()
        XCTAssertFalse(interrupted.askedOwner, "Control Center took the sheet down")

        // A bastion's Face ID answered, then the destination's taken down:
        // the attempt never finished asking, so it is not charged.
        let twoHops = SSHPromptAttribution()
        twoHops.noteBegan()
        twoHops.noteBegan()
        twoHops.noteInterruptedBySystem()
        XCTAssertFalse(twoHops.askedOwner)
    }

    /// Two connections to one key share one Face ID evaluation. The one that
    /// started it asked the owner; the one that joined it asked nothing more.
    func test_aProbeThatJoinsAnotherConnectionsFaceIDIsNotChargedForIt() async {
        let gate = PromptReleaseGate()
        let cache = BiometricSessionCache(evaluator: { _ in
            gate.noteEvaluation()
            await SSHHandshakePromptGate.begin()
            await gate.wait()
            await SSHHandshakePromptGate.end()
            return .userCancelled
        })
        let key = BiometricGrantKey(
            hostID: UUID(),
            endpoint: "fixture.invalid:22",
            keyID: UUID(),
            policyGeneration: 1
        )
        let starter = SSHPromptAttribution()
        let joiner = SSHPromptAttribution()
        let first = Task { @MainActor in
            await SSHPromptAttribution.$current.withValue(starter) {
                await cache.evaluate(key: key, reason: "first")
            }
        }
        for _ in 0..<200 where !starter.askedOwner { await Task.yield() }
        XCTAssertTrue(starter.askedOwner)
        let second = Task { @MainActor in
            await SSHPromptAttribution.$current.withValue(joiner) {
                await cache.evaluate(key: key, reason: "second")
            }
        }
        for _ in 0..<20 { await Task.yield() }
        gate.release()
        _ = await first.value
        _ = await second.value
        XCTAssertEqual(gate.evaluations, 1, "the second connection must have joined, not prompted again")
        XCTAssertFalse(joiner.askedOwner)
    }

    /// A rebuild after server loss re-checks the launch it is about to run:
    /// a custom command edited in since the lost session started is refused
    /// before any connection is made, and the session fails with Retry.
    func test_aRebuildRefusesACustomCommandTheDecisionDidNotApprove() async {
        let host = Host(
            address: "127.0.0.1",
            port: 1,
            user: "nobody",
            transport: .mosh,
            launchMode: .customCommand,
            launchCommand: "./deploy.sh"
        )
        let session = MoshSession(
            host: host,
            requireBiometric: false,
            isSecureEnclave: false,
            preserveTmuxGeometry: false,
            serverLossRecoveryRestorePolicy: .never
        )
        session.connect()
        let deadline = Date().addingTimeInterval(5)
        while case .connecting = session.state, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.state, .failed(MoshSession.serverLossMessage))
        session.disconnect()
    }

    /// A probe whose exec never answers is abandoned on time, and what it
    /// holds is released.
    func test_aStalledProbeIsAbandonedAndReleased() async {
        let abandoned = expectation(description: "abandoned")
        let stalled = Task { () -> MoshServerLivenessPolicy.Outcome in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return .alive
        }
        let started = Date()
        let outcome = await MoshSession.value(
            of: stalled,
            timeoutSeconds: 0.3,
            fallback: .hostUnreachable,
            onAbandon: { abandoned.fulfill() }
        )
        XCTAssertEqual(outcome, .hostUnreachable)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        await fulfillment(of: [abandoned], timeout: 1)
        XCTAssertTrue(stalled.isCancelled)
    }

    /// Time under a Face ID or passcode sheet does not count toward the
    /// abandonment timeout, so a slow answer is not torn down and re-asked.
    func test_ownerAuthenticationTimeDoesNotCountTowardTheProbeTimeout() async {
        let release = ProbeRelease()
        let probe = Task { @MainActor () -> MoshServerLivenessPolicy.Outcome in
            await release.wait()
            return .gone
        }
        SSHHandshakePromptGate.begin()
        let racing = Task { @MainActor in
            await MoshSession.value(of: probe, timeoutSeconds: 0.3, fallback: .hostUnreachable, onAbandon: {})
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        SSHHandshakePromptGate.end()
        release.open()
        let outcome = await racing.value
        XCTAssertEqual(outcome, .gone, "the prompt paused the clock past three timeouts")
    }
}

@MainActor
private final class ProbeRelease {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

final class MoshBootstrapRetryLadderTests: XCTestCase {

    /// Fast failures — a host name that does not resolve yet while a VPN comes
    /// up — retry densely for the whole budget instead of waiting out a 10 s
    /// rung after the second try.
    @MainActor
    func test_fastFailuresRetryDenselyUntilTheBudgetIsSpent() {
        var charged: TimeInterval = 0
        var delays: [TimeInterval] = []
        while let delay = MoshSession.bootstrapRetryDelay(
            retriesUsed: delays.count,
            chargedSeconds: charged
        ) {
            delays.append(delay)
            charged += MoshSession.bootstrapRetryCharge(forAttemptSeconds: 0.2) + delay
            XCTAssertLessThan(delays.count, 100, "the budget must end the ladder")
        }
        XCTAssertEqual(Array(delays.prefix(5)), [1, 2, 3, 5, 8])
        XCTAssertTrue(delays.dropFirst(5).allSatisfy { $0 == 8 })
        XCTAssertLessThanOrEqual(charged, 60 + 0.2)
        XCTAssertGreaterThan(charged, 45, "fast failures keep trying for most of a minute")
    }

    /// Attempts that each run into a connect timeout still span the ~50 s
    /// outages seen in the field, and a suspension in the middle of an attempt
    /// cannot spend the whole budget at once.
    @MainActor
    func test_timeoutsStillSpanTheFieldOutageAndSuspensionsAreCapped() {
        var charged: TimeInterval = 0
        var attemptStarts: [TimeInterval] = [0]
        var wall: TimeInterval = 0
        var retries = 0
        while true {
            wall += 15
            charged += MoshSession.bootstrapRetryCharge(forAttemptSeconds: 15)
            guard let delay = MoshSession.bootstrapRetryDelay(
                retriesUsed: retries,
                chargedSeconds: charged
            ) else { break }
            retries += 1
            charged += delay
            wall += delay
            attemptStarts.append(wall)
        }
        XCTAssertGreaterThanOrEqual(wall, 50, "attempts cover the field outage window")
        XCTAssertEqual(attemptStarts.count, 4)

        XCTAssertEqual(MoshSession.bootstrapRetryCharge(forAttemptSeconds: 3_600), 16)
        XCTAssertNotNil(MoshSession.bootstrapRetryDelay(
            retriesUsed: 1,
            chargedSeconds: MoshSession.bootstrapRetryCharge(forAttemptSeconds: 3_600)
        ), "an attempt that spanned a long suspension still leaves retries")
    }
}

/// Holds a fake Face ID evaluation open until the test releases it.
private final class PromptReleaseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var evaluationCount = 0

    var evaluations: Int { lock.withLock { evaluationCount } }

    func noteEvaluation() { lock.withLock { evaluationCount += 1 } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }
}
