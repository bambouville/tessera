import XCTest
import Crypto
import NIOSSH
@testable import Tessera

final class HostKeyVerificationRequestTests: XCTestCase {
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

    func test_validatorCoordinatorPromptsOnceForConcurrentSameChallenge() async throws {
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

        let first = Task {
            await HostKeyVerificationCoordinator.shared.resolve(
                hostKey: hostKey,
                endpoint: endpoint,
                prompt: prompt,
                challenge: challenge
            )
        }
        await probe.waitForPrompt()

        let second = Task {
            await HostKeyVerificationCoordinator.shared.resolve(
                hostKey: hostKey,
                endpoint: endpoint,
                prompt: prompt,
                challenge: challenge
            )
        }
        await probe.releasePrompt(accepted: true)

        let firstResult = await first.value
        let secondResult = await second.value
        let promptCount = await probe.promptCount()
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(promptCount, 1)

        let result = await KnownHostsStore.shared.check(hostKey, for: endpoint)
        if case .trusted = result {} else {
            XCTFail("expected accepted coordinator decision to trust host key")
        }
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

    private func makeHostKey() throws -> NIOSSHPublicKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let line = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: privateKey.publicKey,
            comment: "test"
        )
        let head = line.split(separator: " ").prefix(2).joined(separator: " ")
        return try NIOSSHPublicKey(openSSHPublicKey: head)
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
}
