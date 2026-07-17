import XCTest
import SwiftData
@testable import Tessera

/// Pure-logic coverage for jump-chain resolution: ordering, cycles, depth,
/// dangling links, editor eligibility, and the Host DTO bridge.
@MainActor
final class HostJumpChainResolverTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        container = try TesseraModelContainer.make(inMemory: true)
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        container = nil
        context = nil
    }

    private func makeHost(_ name: String, address: String = "10.0.0.1") -> PersistedHost {
        let host = PersistedHost(name: name, address: address, port: 22)
        context.insert(host)
        return host
    }

    func test_resolve_directHostHasEmptyChain() throws {
        let host = makeHost("direct")
        try context.save()
        let resolution = HostJumpChainResolver.resolve(for: host, in: context)
        XCTAssertFalse(resolution.isBroken)
        XCTAssertTrue(resolution.hops.isEmpty)
    }

    func test_resolve_singleHopOrdersBastionFirst() throws {
        let bastion = makeHost("bastion")
        let target = makeHost("target")
        HostJumpChainResolver.setJumpHost(bastion.id, for: target.id, in: context)
        try context.save()

        let resolution = HostJumpChainResolver.resolve(for: target, in: context)
        XCTAssertFalse(resolution.isBroken)
        XCTAssertEqual(resolution.hops.map(\.id), [bastion.id])
    }

    func test_resolve_multiHopFlattensOutermostFirst() throws {
        // device → outer → middle → target
        let outer = makeHost("outer")
        let middle = makeHost("middle")
        let target = makeHost("target")
        HostJumpChainResolver.setJumpHost(outer.id, for: middle.id, in: context)
        HostJumpChainResolver.setJumpHost(middle.id, for: target.id, in: context)
        try context.save()

        let resolution = HostJumpChainResolver.resolve(for: target, in: context)
        XCTAssertFalse(resolution.isBroken)
        XCTAssertEqual(resolution.hops.map(\.id), [outer.id, middle.id])
    }

    func test_resolve_cycleIsBrokenNotInfinite() throws {
        let a = makeHost("a")
        let b = makeHost("b")
        HostJumpChainResolver.setJumpHost(a.id, for: b.id, in: context)
        HostJumpChainResolver.setJumpHost(b.id, for: a.id, in: context)
        try context.save()

        let resolution = HostJumpChainResolver.resolve(for: a, in: context)
        XCTAssertTrue(resolution.isBroken)
        XCTAssertTrue(resolution.brokenReason?.contains("cycle") == true)
    }

    func test_resolve_danglingBastionIsBroken() throws {
        let target = makeHost("target")
        HostJumpChainResolver.setJumpHost(UUID(), for: target.id, in: context)
        try context.save()

        let resolution = HostJumpChainResolver.resolve(for: target, in: context)
        XCTAssertTrue(resolution.isBroken)
        XCTAssertTrue(resolution.brokenReason?.contains("no longer exists") == true)
    }

    func test_resolve_depthOverflowIsBroken() throws {
        var previous = makeHost("h0")
        var last = previous
        for index in 1...(HostJumpChainResolver.maxDepth + 1) {
            let next = makeHost("h\(index)")
            HostJumpChainResolver.setJumpHost(previous.id, for: next.id, in: context)
            previous = next
            last = next
        }
        try context.save()

        let resolution = HostJumpChainResolver.resolve(for: last, in: context)
        XCTAssertTrue(resolution.isBroken)
        XCTAssertTrue(resolution.brokenReason?.contains("hops") == true)
    }

    func test_eligibleJumpHosts_excludeSelfAndCycleFormers() throws {
        // c → b → a; when editing `a`, both b and c would create a cycle.
        let a = makeHost("a")
        let b = makeHost("b")
        let c = makeHost("c")
        let unrelated = makeHost("unrelated")
        HostJumpChainResolver.setJumpHost(a.id, for: b.id, in: context)
        HostJumpChainResolver.setJumpHost(b.id, for: c.id, in: context)
        try context.save()

        let eligible = Set(
            HostJumpChainResolver.eligibleJumpHosts(for: a.id, in: context).map(\.id)
        )
        XCTAssertEqual(eligible, [unrelated.id])
    }

    func test_eligibleJumpHosts_excludeBlankBrokenAndDepthExhaustedCandidates() throws {
        let target = makeHost("target")
        let blank = makeHost("blank", address: "   ")
        let dangling = makeHost("dangling")
        HostJumpChainResolver.setJumpHost(UUID(), for: dangling.id, in: context)

        var depthCandidate = makeHost("depth-0")
        for index in 1...HostJumpChainResolver.maxDepth {
            let outer = makeHost("depth-\(index)")
            HostJumpChainResolver.setJumpHost(outer.id, for: depthCandidate.id, in: context)
            depthCandidate = outer
        }
        try context.save()

        let eligible = Set(
            HostJumpChainResolver.eligibleJumpHosts(for: target.id, in: context)
                .map(\.id)
        )
        XCTAssertFalse(eligible.contains(blank.id))
        XCTAssertFalse(eligible.contains(dangling.id))
        // The innermost candidate owns an eight-hop chain already; adding the
        // edited target would overflow the resolver's cap.
        let innermost = try XCTUnwrap(
            context.fetch(FetchDescriptor<PersistedHost>())
                .first { $0.name == "depth-0" }
        )
        XCTAssertFalse(eligible.contains(innermost.id))
    }

    func test_setJumpHost_updateAndClearRoundTrip() throws {
        let bastion1 = makeHost("bastion1")
        let bastion2 = makeHost("bastion2")
        let target = makeHost("target")
        try context.save()

        HostJumpChainResolver.setJumpHost(bastion1.id, for: target.id, in: context)
        XCTAssertEqual(
            HostJumpChainResolver.link(for: target.id, in: context)?.jumpHostID,
            bastion1.id
        )
        HostJumpChainResolver.setJumpHost(bastion2.id, for: target.id, in: context)
        XCTAssertEqual(
            HostJumpChainResolver.link(for: target.id, in: context)?.jumpHostID,
            bastion2.id
        )
        HostJumpChainResolver.setJumpHost(nil, for: target.id, in: context)
        XCTAssertNil(HostJumpChainResolver.link(for: target.id, in: context))
    }

    func test_removeOutgoingLink_keepsIncomingLinksSoDependentsFailClosed() throws {
        let bastion = makeHost("bastion")
        let target = makeHost("target")
        HostJumpChainResolver.setJumpHost(bastion.id, for: target.id, in: context)
        try context.save()

        // Deleting the bastion GCs only ITS outgoing link (it has none);
        // target's link at the deleted bastion must remain and break.
        HostJumpChainResolver.removeOutgoingLink(for: bastion.id, in: context)
        context.delete(bastion)
        try context.save()

        let resolution = HostJumpChainResolver.resolve(for: target, in: context)
        XCTAssertTrue(resolution.isBroken)
    }

    func test_hostDTO_carriesResolvedChainAndBrokenReason() throws {
        let outer = makeHost("outer")
        let middle = makeHost("middle")
        let target = makeHost("target")
        HostJumpChainResolver.setJumpHost(outer.id, for: middle.id, in: context)
        HostJumpChainResolver.setJumpHost(middle.id, for: target.id, in: context)
        try context.save()

        let dto = Host(from: target)
        XCTAssertNil(dto.jumpChainBrokenReason)
        XCTAssertEqual(dto.jumpChain.map(\.id), [outer.id, middle.id])
        // Hops are flat — no recursive chains on hop DTOs.
        XCTAssertTrue(dto.jumpChain.allSatisfy(\.jumpChain.isEmpty))

        // Broken chains surface on the DTO instead of silently connecting
        // direct.
        HostJumpChainResolver.setJumpHost(UUID(), for: target.id, in: context)
        try context.save()
        let broken = Host(from: target)
        XCTAssertNotNil(broken.jumpChainBrokenReason)
        XCTAssertTrue(broken.jumpChain.isEmpty)
    }

    func test_connectionKeyTracksFullNestedRouteAndBrokenState() throws {
        let outerA = makeHost("outer-a")
        let outerB = makeHost("outer-b")
        let middle = makeHost("middle")
        let target = makeHost("target")
        HostJumpChainResolver.setJumpHost(outerA.id, for: middle.id, in: context)
        HostJumpChainResolver.setJumpHost(middle.id, for: target.id, in: context)
        try context.save()

        let first = target.connectionKey
        XCTAssertTrue(first.contains(outerA.id.uuidString))
        XCTAssertTrue(first.contains(middle.id.uuidString))

        HostJumpChainResolver.setJumpHost(outerB.id, for: middle.id, in: context)
        try context.save()
        let changed = target.connectionKey
        XCTAssertNotEqual(changed, first)
        XCTAssertTrue(changed.contains(outerB.id.uuidString))

        HostJumpChainResolver.setJumpHost(UUID(), for: middle.id, in: context)
        try context.save()
        XCTAssertTrue(target.connectionKey.contains("via=broken:"))
        XCTAssertNotEqual(target.connectionKey, changed)
    }

    func test_hostKeyEndpointNamespacesTunneledPrivateAddressesByRoute() {
        XCTAssertEqual(
            sshHostKeyEndpoint(routeEndpoints: ["bastion-a:22"]),
            "bastion-a:22"
        )
        XCTAssertNotEqual(
            sshHostKeyEndpoint(routeEndpoints: ["bastion-a:22", "10.0.0.5:22"]),
            sshHostKeyEndpoint(routeEndpoints: ["bastion-b:22", "10.0.0.5:22"])
        )
    }

    func test_hostDTO_appliesTransientPasswordsToEachResolvedHop() throws {
        let outer = makeHost("outer")
        let middle = makeHost("middle")
        let target = makeHost("target")
        outer.identity = Identity(user: "outer", credentialMode: .password)
        middle.identity = Identity(user: "middle", credentialMode: .password)
        HostJumpChainResolver.setJumpHost(outer.id, for: middle.id, in: context)
        HostJumpChainResolver.setJumpHost(middle.id, for: target.id, in: context)
        try context.save()

        let dto = Host(
            from: target,
            transientJumpPasswords: [
                outer.id: HostTransientPasswordCredential(
                    password: "outer-secret",
                    revision: nil
                ),
                middle.id: HostTransientPasswordCredential(
                    password: "middle-secret",
                    revision: nil
                ),
            ]
        )

        XCTAssertEqual(dto.jumpChain.map(\.password), ["outer-secret", "middle-secret"])
        XCTAssertTrue(dto.jumpChain.allSatisfy {
            if case .ephemeral = $0.passwordCredentialRevision { return true }
            return false
        })
    }

    func test_remoteMoshTerminationCommandVerifiesPIDIdentityBeforeKill() {
        let command = MoshSession.remoteMoshServerTerminationCommand(serverPID: 1234)
        XCTAssertTrue(command.contains("ps -p \"$pid\" -o comm="))
        XCTAssertTrue(command.contains("*mosh-server*"))
        XCTAssertTrue(command.contains("kill -TERM \"$pid\""))
    }

    func test_policyRefreshFallback_scrubsHopPasswords() {
        var bastion = Host(name: "bastion", address: "1.2.3.4", password: "hop-secret")
        bastion.jumpChain = []
        var host = Host(name: "target", address: "5.6.7.8", password: "target-secret")
        host.jumpChain = [bastion]

        let fallback = host.policyRefreshFallback
        XCTAssertNotEqual(fallback.password, "target-secret")
        XCTAssertEqual(fallback.jumpChain.count, 1)
        XCTAssertNotEqual(fallback.jumpChain[0].password, "hop-secret")
    }

    func test_establishSSHChain_failsClosedOnBrokenChain() async {
        var host = Host(name: "target", address: "203.0.113.9")
        host.jumpChainBrokenReason = "A configured jump host no longer exists."
        do {
            _ = try await establishSSHChain(
                for: host,
                requireBiometric: false,
                isSecureEnclave: false,
                hostKeyPrompt: nil
            )
            XCTFail("broken chain must not connect")
        } catch let error as SSHChainError {
            guard case .brokenChain(let reason) = error else {
                return XCTFail("unexpected chain error: \(error)")
            }
            XCTAssertEqual(reason, "A configured jump host no longer exists.")
        } catch {
            XCTFail("expected SSHChainError, got \(error)")
        }
    }
}
