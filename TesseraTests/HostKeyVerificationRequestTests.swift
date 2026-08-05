import XCTest
import Crypto
import NIOPosix
import NIOSSH
@testable import Tessera

final class HostKeyVerificationRequestTests: XCTestCase {
    func test_validatorHandsUnknownKeyOffWithoutAwaitingHumanDecision() async throws {
        let hostKey = try makeHostKey()
        let endpoint = "approval-handoff-\(UUID().uuidString):22"
        let promptProbe = PromptProbe()
        let validator = TesseraHostKeyValidator(
            endpoint: endpoint,
            prompt: { _ in await promptProbe.prompt() }
        )
        let promise = MultiThreadedEventLoopGroup.singleton.next()
            .makePromise(of: Void.self)

        validator.validateHostKey(
            hostKey: hostKey,
            validationCompletePromise: promise
        )

        do {
            try await promise.futureResult.get()
            XCTFail("unknown key must leave the timed SSH handshake")
        } catch let approval as HostKeyApprovalRequired {
            XCTAssertEqual(approval.endpoint, endpoint)
            XCTAssertEqual(
                approval.challenge.fingerprint,
                KnownHostsStore.fingerprint(of: hostKey)
            )
            XCTAssertFalse(approval.challenge.isChanged)
            let promptCount = await promptProbe.promptCount()
            XCTAssertEqual(promptCount, 0)
        } catch {
            XCTFail("expected HostKeyApprovalRequired, got \(error)")
        }
    }

    func test_settlingRequestMoreThanOnceUsesFirstDecision() async throws {
        let rejectedFirst = try await settleWithRepeatedDecisions([false, true, false])
        XCTAssertFalse(rejectedFirst)

        let acceptedFirst = try await settleWithRepeatedDecisions([true, false, true])
        XCTAssertTrue(acceptedFirst)
    }

    func test_coalescingSameChallengeResolvesBothContinuations() async throws {
        let challenge = makeChallenge()
        let first = try await makeRequest(challenge: challenge)
        let second = try await makeRequest(challenge: challenge)

        XCTAssertTrue(first.request.isSameChallenge(as: second.request))
        first.request.coalesce(second.request)
        XCTAssertTrue(second.request.isResolved)

        await MainActor.run {
            first.request.accept()
        }

        let firstResult = await first.task.value
        let secondResult = await second.task.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
    }

    func test_validatorCoordinatorPromptedFirstCoalescesDuplicateAndAcceptsBoth() async throws {
        let hostKey = try makeHostKey()
        let endpoint = "coalesce-\(UUID().uuidString):22"
        let challenge = HostKeyVerificationChallenge(
            endpoint: endpoint,
            fingerprint: KnownHostsStore.fingerprint(of: hostKey),
            keyType: "ssh-ed25519",
            isChanged: false,
            oldFingerprint: nil
        )
        let probe = PromptProbe()
        let prompt: HostKeyVerificationPrompt = { _ in
            await probe.prompt()
        }
        let coordinator = HostKeyVerificationCoordinator()

        let first = Task {
            await coordinator.resolve(
                hostKey: hostKey,
                endpoint: endpoint,
                prompt: prompt,
                challenge: challenge
            )
        }
        await probe.waitForPrompt()

        let second = Task {
            await coordinator.resolve(
                hostKey: hostKey,
                endpoint: endpoint,
                prompt: prompt,
                challenge: challenge
            )
        }
        let duplicateJoined = await waitForWaiterCount(
            2,
            coordinator: coordinator,
            challenge: challenge
        )
        await probe.releasePrompt(accepted: true)

        let firstResult = await first.value
        let secondResult = await second.value
        let promptCount = await probe.promptCount()
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertTrue(duplicateJoined)
        XCTAssertEqual(promptCount, 1)

        let result = await KnownHostsStore.shared.check(hostKey, for: endpoint)
        if case .trusted = result {} else {
            XCTFail("expected accepted coordinator decision to trust host key")
        }
        await KnownHostsStore.shared.remove(endpoint: endpoint)
    }

    func test_cancellingOnlyPromptWaiterPreventsLaterAcceptanceFromPersistingTrust() async throws {
        let hostKey = try makeHostKey()
        let endpoint = "cancelled-prompt-\(UUID().uuidString):22"
        let challenge = makeChallenge(hostKey: hostKey, endpoint: endpoint)
        let probe = PromptProbe()
        let coordinator = HostKeyVerificationCoordinator()

        let request = Task {
            await coordinator.resolve(
                hostKey: hostKey,
                endpoint: endpoint,
                prompt: { _ in await probe.prompt() },
                challenge: challenge
            )
        }
        await probe.waitForPrompt()
        request.cancel()
        // Deliberately race a Trust response against the actor cleanup. The
        // synchronous cancellation token must make cancellation win even
        // before the waiter has been removed from actor-isolated state.
        await probe.releasePrompt(accepted: true)

        let accepted = await request.value
        XCTAssertFalse(accepted)
        let trustResult = await KnownHostsStore.shared.check(hostKey, for: endpoint)
        if case .unknown = trustResult {} else {
            XCTFail("a canceled request must not persist a later prompt decision")
        }
        await KnownHostsStore.shared.remove(endpoint: endpoint)
    }

    func test_validatorCoordinatorPromptlessFirstUpgradesToPromptedDuplicate() async throws {
        let hostKey = try makeHostKey()
        let endpoint = "promptless-first-\(UUID().uuidString):22"
        let challenge = makeChallenge(hostKey: hostKey, endpoint: endpoint)
        let graceGate = SuspensionGate()
        let probe = PromptProbe()
        let coordinator = HostKeyVerificationCoordinator(promptUpgradeGrace: {
            await graceGate.suspend()
        })

        let promptless = Task {
            await coordinator.resolve(
                hostKey: hostKey,
                endpoint: endpoint,
                prompt: nil,
                challenge: challenge
            )
        }
        await graceGate.waitUntilSuspended()

        let prompted = Task {
            await coordinator.resolve(
                hostKey: hostKey,
                endpoint: endpoint,
                prompt: { _ in await probe.prompt() },
                challenge: challenge
            )
        }
        await probe.waitForPrompt()
        await probe.releasePrompt(accepted: true)

        let promptlessResult = await promptless.value
        let promptedResult = await prompted.value
        let promptCount = await probe.promptCount()
        XCTAssertTrue(promptlessResult)
        XCTAssertTrue(promptedResult)
        XCTAssertEqual(promptCount, 1)

        let result = await KnownHostsStore.shared.check(hostKey, for: endpoint)
        if case .trusted = result {} else {
            XCTFail("expected prompted duplicate to own the shared trust decision")
        }
        await graceGate.release()
        await KnownHostsStore.shared.remove(endpoint: endpoint)
    }

    func test_validatorCoordinatorPromptlessOnlyFailsClosedAfterBoundedGrace() async throws {
        let hostKey = try makeHostKey()
        let endpoint = "promptless-only-\(UUID().uuidString):22"
        let challenge = makeChallenge(hostKey: hostKey, endpoint: endpoint)
        let graceGate = SuspensionGate()
        let coordinator = HostKeyVerificationCoordinator(promptUpgradeGrace: {
            await graceGate.suspend()
        })

        let result = Task {
            await coordinator.resolve(
                hostKey: hostKey,
                endpoint: endpoint,
                prompt: nil,
                challenge: challenge
            )
        }
        await graceGate.waitUntilSuspended()
        await graceGate.release()

        let accepted = await result.value
        XCTAssertFalse(accepted)
        let trustResult = await KnownHostsStore.shared.check(hostKey, for: endpoint)
        if case .unknown = trustResult {} else {
            XCTFail("promptless validation must not trust the host key")
        }
        await KnownHostsStore.shared.remove(endpoint: endpoint)
    }

    func test_validatorCoordinatorStalePromptlessChallengeAcceptsAlreadyTrustedKey() async throws {
        let hostKey = try makeHostKey()
        let endpoint = "stale-promptless-\(UUID().uuidString):22"
        let staleChallenge = makeChallenge(hostKey: hostKey, endpoint: endpoint)
        let promptProbe = PromptProbe()
        let graceGate = SuspensionGate()
        let coordinator = HostKeyVerificationCoordinator(promptUpgradeGrace: {
            await graceGate.suspend()
        })

        let promptedAccepted = await coordinator.resolve(
            hostKey: hostKey,
            endpoint: endpoint,
            prompt: { _ in
                await promptProbe.recordImmediateDecision(true)
            },
            challenge: staleChallenge
        )
        let promptCountAfterTrust = await promptProbe.promptCount()
        XCTAssertTrue(promptedAccepted)
        XCTAssertEqual(promptCountAfterTrust, 1)

        // This models a validator that captured `.unknown` before the first
        // decision completed, but entered the coordinator only afterward.
        let promptless = Task {
            await coordinator.resolve(
                hostKey: hostKey,
                endpoint: endpoint,
                prompt: nil,
                challenge: staleChallenge
            )
        }
        await graceGate.waitUntilSuspended()
        await graceGate.release()

        let promptlessAccepted = await promptless.value
        let finalPromptCount = await promptProbe.promptCount()
        XCTAssertTrue(promptlessAccepted)
        XCTAssertEqual(finalPromptCount, 1)
        await KnownHostsStore.shared.remove(endpoint: endpoint)
    }

    func test_peerFingerprintComparisonIsInformationalAndExact() async throws {
        let matching = HostKeyVerificationChallenge(
            endpoint: "match.example:22",
            fingerprint: "SHA256:actual",
            keyType: "ssh-ed25519",
            isChanged: false,
            oldFingerprint: nil,
            peerFingerprint: "SHA256:actual",
            peerLabel: "iPad"
        )
        let mismatching = HostKeyVerificationChallenge(
            endpoint: "mismatch.example:22",
            fingerprint: "SHA256:actual",
            keyType: "ssh-ed25519",
            isChanged: false,
            oldFingerprint: nil,
            peerFingerprint: "SHA256:different",
            peerLabel: "iPad"
        )

        XCTAssertEqual(matching.peerFingerprintMatches, true)
        XCTAssertEqual(mismatching.peerFingerprintMatches, false)
        let matchingRequest = try await makeRequest(challenge: matching).request
        let mismatchingRequest = try await makeRequest(challenge: mismatching).request
        XCTAssertEqual(matchingRequest.peerFingerprintMatches, true)
        XCTAssertEqual(mismatchingRequest.peerFingerprintMatches, false)
        await MainActor.run {
            matchingRequest.reject()
            mismatchingRequest.reject()
        }
    }

    func test_acceptedMatchingPeerHintWritesAuditLabel() async throws {
        let hostKey = try makeHostKey()
        let endpoint = "peer-audit-\(UUID().uuidString):22"
        let fingerprint = KnownHostsStore.fingerprint(of: hostKey)
        let challenge = HostKeyVerificationChallenge(
            endpoint: endpoint,
            fingerprint: fingerprint,
            keyType: "ssh-ed25519",
            isChanged: false,
            oldFingerprint: nil,
            peerFingerprint: fingerprint,
            peerLabel: "iPad"
        )

        let accepted = await HostKeyVerificationCoordinator.shared.resolve(
            hostKey: hostKey,
            endpoint: endpoint,
            prompt: { _ in true },
            challenge: challenge
        )

        XCTAssertTrue(accepted)
        let rows = await KnownHostsStore.shared.list()
        let row = rows.filter { $0.id == endpoint }.first
        XCTAssertEqual(row?.matchedPeerLabel, "iPad")
        await KnownHostsStore.shared.remove(endpoint: endpoint)
    }

    private func settleWithRepeatedDecisions(_ decisions: [Bool]) async throws -> Bool {
        let (request, decisionTask) = try await makeRequest(challenge: makeChallenge())

        await MainActor.run {
            for decision in decisions {
                if decision {
                    request.accept()
                } else {
                    request.reject()
                }
            }
        }

        return await decisionTask.value
    }

    private func makeChallenge() -> HostKeyVerificationChallenge {
        HostKeyVerificationChallenge(
            endpoint: "host.example:22",
            fingerprint: "SHA256:test",
            keyType: "ssh-ed25519",
            isChanged: false,
            oldFingerprint: nil
        )
    }

    private func makeChallenge(
        hostKey: NIOSSHPublicKey,
        endpoint: String
    ) -> HostKeyVerificationChallenge {
        HostKeyVerificationChallenge(
            endpoint: endpoint,
            fingerprint: KnownHostsStore.fingerprint(of: hostKey),
            keyType: "ssh-ed25519",
            isChanged: false,
            oldFingerprint: nil
        )
    }

    private func makeHostKey() throws -> NIOSSHPublicKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let line = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: privateKey.publicKey,
            comment: "test"
        )
        let head = line.split(separator: " ").prefix(2).joined(separator: " ")
        return try NIOSSHPublicKey(openSSHPublicKey: head)
    }

    private func waitForWaiterCount(
        _ expectedCount: Int,
        coordinator: HostKeyVerificationCoordinator,
        challenge: HostKeyVerificationChallenge
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await coordinator.pendingWaiterCount(for: challenge) == expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func makeRequest(
        challenge: HostKeyVerificationChallenge
    ) async throws -> (request: HostKeyVerificationRequest, task: Task<Bool, Never>) {
        var decisionTask: Task<Bool, Never>!
        let requests = AsyncStream<HostKeyVerificationRequest> { stream in
            decisionTask = Task {
                await withCheckedContinuation { continuation in
                    let request = HostKeyVerificationRequest(
                        challenge: challenge,
                        continuation: continuation
                    )
                    stream.yield(request)
                    stream.finish()
                }
            }
        }

        var iterator = requests.makeAsyncIterator()
        let nextRequest = await iterator.next()
        let request = try XCTUnwrap(nextRequest)
        return (request, decisionTask)
    }
}

private actor PromptProbe {
    private var calls = 0
    private var promptWaiters: [CheckedContinuation<Void, Never>] = []
    private var promptContinuation: CheckedContinuation<Bool, Never>?

    func prompt() async -> Bool {
        calls += 1
        return await withCheckedContinuation { continuation in
            promptContinuation = continuation
            let waiters = promptWaiters
            promptWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitForPrompt() async {
        if promptContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            promptWaiters.append(continuation)
        }
    }

    func releasePrompt(accepted: Bool) {
        promptContinuation?.resume(returning: accepted)
        promptContinuation = nil
    }

    func promptCount() -> Int {
        calls
    }

    func recordImmediateDecision(_ accepted: Bool) -> Bool {
        calls += 1
        return accepted
    }
}

private actor SuspensionGate {
    private var isSuspended = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = entryWaiters
        entryWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
