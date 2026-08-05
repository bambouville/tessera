import UIKit
import XCTest
@testable import Tessera

final class ContinuityFoundationTests: XCTestCase {
    func test_fullScreenContinuityPresentationBackgroundIsOpaqueInEveryMode() {
        let light = DesignTokens.make(mode: .light, accent: .blue)
        let dark = DesignTokens.make(mode: .dark, accent: .blue)

        XCTAssertEqual(UIColor(light.bg).cgColor.alpha, 0, accuracy: 0.001)
        XCTAssertEqual(UIColor(light.presentationBg).cgColor.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(UIColor(dark.presentationBg).cgColor.alpha, 1, accuracy: 0.001)
    }

    func test_descriptorRoundTripUsesOnlyTypedAllowlistAndExactWireKeys() throws {
        let descriptor = makeDescriptor()

        let data = try descriptor.handoffData()
        let decoded = try SessionActivityDescriptor(handoffData: data)
        XCTAssertEqual(decoded, descriptor)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "v", "hostID", "connectionKey", "name", "user", "address",
                "port", "transport", "launchMode", "tmux", "via", "hostKeyFP"
            ]
        )
        XCTAssertEqual(object["v"] as? Int, SessionActivityDescriptor.currentSchemaVersion)
        XCTAssertEqual(object["tmux"] as? String, "dev")
        XCTAssertEqual(object["hostKeyFP"] as? String, "SHA256:destination")

        let via = try XCTUnwrap(object["via"] as? [[String: Any]])
        XCTAssertEqual(via.count, 1)
        XCTAssertEqual(
            Set(via[0].keys),
            ["hostID", "name", "user", "address", "port", "transport", "hostKeyFP"]
        )
    }

    func test_hostExtractionCannotCarryCredentialOrShellSecrets() throws {
        let secretPassword = "secret-password-sentinel"
        let secretKeyFilename = "secret-private-key-sentinel"
        let secretCommand = "secret-command-sentinel"
        let secretEnvironment = "TOKEN=secret-env-sentinel"
        let secretSnippet = "secret-snippet-sentinel"
        let keyID = UUID()
        let host = Host(
            id: UUID(),
            name: "zeus",
            address: "zeus.lan",
            port: 22,
            user: "alice",
            password: secretPassword,
            transport: .mosh,
            privateKeyFilename: secretKeyFilename,
            storedKeyID: keyID,
            launchMode: .autoTmux,
            launchCommand: secretCommand,
            envVars: secretEnvironment,
            startupSnippet: secretSnippet
        )

        let descriptor = try SessionActivityDescriptor(
            host: host,
            resolvedTmuxSessionName: "tessera-01234567",
            hostKeyFingerprint: "SHA256:public"
        )
        let wire = String(decoding: try descriptor.handoffData(), as: UTF8.self)

        for secret in [
            secretPassword,
            secretKeyFilename,
            secretCommand,
            secretEnvironment,
            secretSnippet,
            keyID.uuidString
        ] {
            XCTAssertFalse(wire.contains(secret), "descriptor leaked \(secret)")
        }
        for forbiddenKey in [
            "password", "privateKey", "storedKey", "credential", "launchCommand",
            "envVars", "startupSnippet", "notes", "trustPin"
        ] {
            XCTAssertFalse(wire.contains(forbiddenKey), "descriptor exposed \(forbiddenKey)")
        }
    }

    func test_descriptorWithMaximumJumpChainFitsThreeKilobyteBudget() throws {
        let via = (0..<SessionActivityDescriptor.maximumViaCount).map { index in
            SessionActivityEndpoint(
                hostID: UUID(),
                name: "production-bastion-\(index)",
                user: "deployment-operator",
                address: "bastion-\(index).production.example.internal",
                port: 22,
                transport: .ssh,
                hostKeyFingerprint: "SHA256:0123456789abcdefghijklmnopqrstuv-\(index)"
            )
        }
        let endpoint = SessionActivityEndpoint(
            hostID: UUID(),
            name: "primary-production-terminal",
            user: "deployment-operator",
            address: "primary.production.example.internal",
            port: 22,
            transport: .mosh,
            hostKeyFingerprint: "SHA256:abcdefghijklmnopqrstuvwxyz0123456789AB"
        )
        let descriptor = SessionActivityDescriptor(
            endpoint: endpoint,
            launchMode: .autoTmux,
            tmuxSessionName: "tessera-01234567",
            via: via
        )

        let data = try descriptor.handoffData()
        XCTAssertLessThanOrEqual(data.count, SessionActivityDescriptor.maximumHandoffBytes)
    }

    func test_handoffBoundaryRejectsOversizedDescriptor() {
        let descriptor = SessionActivityDescriptor(
            endpoint: SessionActivityEndpoint(
                hostID: UUID(),
                name: String(repeating: "n", count: 4_000),
                user: "alice",
                address: "zeus.lan",
                port: 22,
                transport: .ssh
            ),
            launchMode: .customCommand,
            tmuxSessionName: nil
        )

        XCTAssertThrowsError(try descriptor.handoffData()) { error in
            guard let descriptorError = error as? SessionActivityDescriptor.DescriptorError,
                  case .exceedsHandoffBudget(
                let actual,
                let maximum
            ) = descriptorError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, 3 * 1024)
        }
    }

    func test_decoderRejectsUnknownSchemaVersion() throws {
        let data = try makeDescriptor().handoffData()
        let current = String(decoding: data, as: UTF8.self)
        let future = current.replacingOccurrences(of: "\"v\":1", with: "\"v\":99")

        XCTAssertThrowsError(
            try SessionActivityDescriptor(handoffData: Data(future.utf8))
        ) { error in
            XCTAssertEqual(
                error as? SessionActivityDescriptor.DescriptorError,
                .unsupportedSchemaVersion(99)
            )
        }
    }

    func test_honestActionTableCoversBothTransportsAndEveryLaunchMode() {
        let expected: [(HostTransport, HostLaunchMode, ContinuationAction)] = [
            (.ssh, .autoTmux, .continueSession),
            (.ssh, .pinnedTmux, .continueSession),
            (.ssh, .customCommand, .reconnect),
            (.mosh, .autoTmux, .continueSession),
            (.mosh, .pinnedTmux, .continueSession),
            (.mosh, .customCommand, .reconnect)
        ]

        for (transport, launchMode, action) in expected {
            let descriptor = SessionActivityDescriptor(
                endpoint: SessionActivityEndpoint(
                    hostID: UUID(),
                    name: "host",
                    user: "user",
                    address: "host.example",
                    port: 22,
                    transport: transport
                ),
                launchMode: launchMode,
                tmuxSessionName: action == .continueSession ? "dev" : nil
            )
            XCTAssertEqual(descriptor.continuationAction, action)
            XCTAssertEqual(
                descriptor.continuationAction.label,
                action == .continueSession ? "Continue" : "Reconnect"
            )
        }
    }

    func test_validationRequiresTmuxOnlyForContinue() {
        let endpoint = SessionActivityEndpoint(
            hostID: UUID(),
            name: "host",
            user: "user",
            address: "host.example",
            port: 22,
            transport: .ssh
        )
        let missing = SessionActivityDescriptor(
            endpoint: endpoint,
            launchMode: .autoTmux,
            tmuxSessionName: nil
        )
        let unexpected = SessionActivityDescriptor(
            endpoint: endpoint,
            launchMode: .customCommand,
            tmuxSessionName: "dev"
        )

        XCTAssertThrowsError(try missing.validate()) { error in
            XCTAssertEqual(
                error as? SessionActivityDescriptor.DescriptorError,
                .missingTmuxSessionName
            )
        }
        XCTAssertThrowsError(try unexpected.validate()) { error in
            XCTAssertEqual(
                error as? SessionActivityDescriptor.DescriptorError,
                .unexpectedTmuxSessionName
            )
        }
    }

    func test_descriptorRejectsShellUnsafeOrOversizedTmuxNames() {
        let endpoint = SessionActivityEndpoint(
            hostID: UUID(),
            name: "host",
            user: "user",
            address: "host.example",
            port: 22,
            transport: .ssh
        )
        for unsafe in [
            "dev; touch /tmp/pwned",
            "$(id)",
            "dev name",
            "dev\nother",
            "développement",
            String(repeating: "a", count: 257),
        ] {
            let descriptor = SessionActivityDescriptor(
                endpoint: endpoint,
                launchMode: .pinnedTmux,
                tmuxSessionName: unsafe
            )
            XCTAssertThrowsError(try descriptor.handoffData()) { error in
                XCTAssertEqual(
                    error as? SessionActivityDescriptor.DescriptorError,
                    .invalidTmuxSessionName,
                    "unexpected acceptance/failure for \(unsafe.debugDescription)"
                )
            }
        }

        let safe = SessionActivityDescriptor(
            endpoint: endpoint,
            launchMode: .pinnedTmux,
            tmuxSessionName: "prod.tail_2026-07"
        )
        XCTAssertNoThrow(try safe.handoffData())
    }

    func test_prefillAdoptsSenderAndViaUUIDsWithoutCredentials() {
        let descriptor = makeDescriptor()
        let prefill = descriptor.makePrefilledHost()

        XCTAssertEqual(prefill.id, descriptor.hostID)
        XCTAssertEqual(prefill.jumpChain.map(\.id), descriptor.via.map(\.hostID))
        XCTAssertEqual(prefill.name, descriptor.name)
        XCTAssertEqual(prefill.user, descriptor.user)
        XCTAssertEqual(prefill.address, descriptor.address)
        XCTAssertEqual(prefill.port, descriptor.port)
        XCTAssertEqual(prefill.transport, descriptor.transport)
        XCTAssertTrue(prefill.password.isEmpty)
        XCTAssertNil(prefill.privateKeyFilename)
        XCTAssertNil(prefill.storedKeyID)
        XCTAssertTrue(prefill.jumpChain.allSatisfy(\.password.isEmpty))
        XCTAssertEqual(
            prefill.continuationHostKeyFingerprints[descriptor.hostID],
            descriptor.hostKeyFP
        )
        XCTAssertEqual(
            prefill.continuationHostKeyFingerprints[descriptor.via[0].hostID],
            descriptor.via[0].hostKeyFP
        )
    }

    func test_resolverUsesUUIDThenEndpointThenPrefill() throws {
        let descriptor = makeDescriptor()
        let exactID = Host(
            id: descriptor.hostID,
            name: "locally renamed",
            address: "different.example",
            user: "local",
            launchMode: .customCommand
        )
        let sameEndpoint = Host(
            id: UUID(),
            name: "same endpoint",
            address: descriptor.address,
            port: descriptor.port,
            user: descriptor.user,
            transport: descriptor.transport,
            launchMode: descriptor.launchMode,
            jumpChain: descriptor.via.map {
                Host(
                    id: $0.hostID,
                    name: $0.name,
                    address: $0.address,
                    port: $0.port,
                    user: $0.user,
                    transport: $0.transport
                )
            }
        )
        let candidates = [
            ContinuationHostCandidate(
                host: sameEndpoint,
                connectionKey: descriptor.connectionKey
            ),
            ContinuationHostCandidate(host: exactID, connectionKey: "unrelated")
        ]

        XCTAssertEqual(
            ContinuationResolver.resolve(descriptor, among: candidates),
            .fastPath(exactID)
        )
        XCTAssertEqual(
            ContinuationResolver.resolve(descriptor, among: [candidates[0]]),
            .endpointMatch(sameEndpoint)
        )
        XCTAssertEqual(
            ContinuationResolver.resolve(
                descriptor,
                among: [ContinuationHostCandidate]()
            ),
            .prefill(descriptor)
        )
    }

    func test_endpointMatchRemapsDestinationTrustHintToLocalUUID() {
        let descriptor = makeDescriptor()
        let localID = UUID()
        let local = Host(
            id: localID,
            name: "local copy",
            address: descriptor.address,
            port: descriptor.port,
            user: descriptor.user,
            transport: descriptor.transport,
            launchMode: descriptor.launchMode,
            jumpChain: descriptor.via.map {
                Host(
                    id: $0.hostID,
                    name: $0.name,
                    address: $0.address,
                    port: $0.port,
                    user: $0.user,
                    transport: $0.transport
                )
            }
        )

        let hints = ContinuationTrustHintMapper.hints(
            from: descriptor,
            for: local
        )

        XCTAssertNotEqual(localID, descriptor.hostID)
        XCTAssertEqual(hints[localID], descriptor.hostKeyFP)
        XCTAssertNil(hints[descriptor.hostID])
        XCTAssertEqual(
            hints[descriptor.via[0].hostID],
            descriptor.via[0].hostKeyFP
        )
    }

    func test_trustHintMappingFailsClosedForMismatchedRoute() {
        let descriptor = makeDescriptor()
        var local = descriptor.makePrefilledHost()
        local.address = "different.example"

        XCTAssertTrue(
            ContinuationTrustHintMapper.hints(
                from: descriptor,
                for: local
            ).isEmpty
        )
    }

    func test_connectionKeyMatchesPersistedHostShapeIncludingViaIDs() {
        let descriptor = makeDescriptor()
        XCTAssertEqual(
            descriptor.connectionKey,
            "mosh:alice@zeus.lan:22&via=\(descriptor.via[0].hostID.uuidString)"
        )
    }

    func test_endpointMatchUsesOrderedRouteCoordinatesWhenAllUUIDsDiffer() {
        let descriptor = makeDescriptor()
        let localBastion = Host(
            id: UUID(),
            name: "local atlas",
            address: descriptor.via[0].address,
            port: descriptor.via[0].port,
            user: descriptor.via[0].user,
            transport: descriptor.via[0].transport
        )
        let local = Host(
            id: UUID(),
            name: "local zeus",
            address: descriptor.address,
            port: descriptor.port,
            user: descriptor.user,
            transport: descriptor.transport,
            launchMode: descriptor.launchMode,
            jumpChain: [localBastion]
        )

        XCTAssertEqual(
            ContinuationResolver.resolve(descriptor, among: [local]),
            .endpointMatch(local)
        )

        var wrongOrder = local
        wrongOrder.jumpChain = [
            Host(address: "other.internal", user: "deploy"),
            localBastion,
        ]
        XCTAssertEqual(
            ContinuationResolver.resolve(descriptor, among: [wrongOrder]),
            .prefill(descriptor)
        )
    }

    func test_endpointMatchHandlesThreeHopRoutesWithoutUUIDIdentity() throws {
        let route = [
            Host(id: UUID(), name: "edge", address: "edge.example", port: 22, user: "a"),
            Host(id: UUID(), name: "middle", address: "middle.example", port: 2201, user: "b"),
            Host(id: UUID(), name: "inner", address: "inner.example", port: 2202, user: "c"),
        ]
        let source = Host(
            id: UUID(),
            name: "destination",
            address: "private.example",
            port: 2222,
            user: "d",
            transport: .mosh,
            launchMode: .pinnedTmux,
            tmuxSessionName: "dev",
            jumpChain: route
        )
        let descriptor = try SessionActivityDescriptor(
            host: source,
            resolvedTmuxSessionName: "dev"
        )
        let localRoute = route.map {
            Host(
                id: UUID(),
                name: "local \($0.name)",
                address: $0.address,
                port: $0.port,
                user: $0.user,
                transport: $0.transport
            )
        }
        let local = Host(
            id: UUID(),
            name: "local destination",
            address: source.address,
            port: source.port,
            user: source.user,
            transport: source.transport,
            launchMode: source.launchMode,
            tmuxSessionName: source.tmuxSessionName,
            jumpChain: localRoute
        )

        XCTAssertEqual(
            ContinuationResolver.resolve(descriptor, among: [local]),
            .endpointMatch(local)
        )
    }

    func test_endpointMatchRouteCoordinatesCannotCollideThroughDelimiters() throws {
        let firstHop = Host(
            id: UUID(),
            name: "first",
            address: "h1",
            port: 22,
            user: "u1",
            transport: .ssh
        )
        let source = Host(
            id: UUID(),
            name: "destination",
            address: "h2",
            port: 22,
            user: "u2",
            transport: .ssh,
            launchMode: .customCommand,
            jumpChain: [firstHop]
        )
        let descriptor = try SessionActivityDescriptor(
            host: source,
            resolvedTmuxSessionName: nil
        )
        let delimiterCollision = Host(
            id: UUID(),
            name: "crafted direct host",
            address: "h2",
            port: 22,
            user: "u1@h1:22→ssh:u2",
            transport: .ssh
        )

        XCTAssertEqual(
            ContinuationResolver.resolve(descriptor, among: [delimiterCollision]),
            .prefill(descriptor)
        )
    }

    func test_endpointMatchRejectsAnActualConnectionKeyDelimiterCollision() throws {
        let source = Host(
            id: UUID(),
            name: "source",
            address: "c",
            port: 22,
            user: "a@b",
            transport: .ssh,
            launchMode: .customCommand
        )
        let descriptor = try SessionActivityDescriptor(
            host: source,
            resolvedTmuxSessionName: nil
        )
        let collision = Host(
            id: UUID(),
            name: "different endpoint",
            address: "b@c",
            port: 22,
            user: "a",
            transport: .ssh,
            launchMode: .customCommand
        )
        let candidate = ContinuationHostCandidate(host: collision)

        XCTAssertEqual(candidate.connectionKey, descriptor.connectionKey)
        XCTAssertNotEqual(candidate.resolverRoute, descriptor.resolverRoute)
        XCTAssertEqual(
            ContinuationResolver.resolve(descriptor, among: [candidate]),
            .prefill(descriptor)
        )
    }

    func test_endpointMatchRejectsBrokenSavedRouteFallback() throws {
        let source = Host(
            id: UUID(),
            name: "destination",
            address: "private.example",
            port: 22,
            user: "operator",
            transport: .ssh,
            launchMode: .customCommand
        )
        let descriptor = try SessionActivityDescriptor(
            host: source,
            resolvedTmuxSessionName: nil
        )
        let broken = Host(
            id: UUID(),
            name: "broken local route",
            address: source.address,
            port: source.port,
            user: source.user,
            transport: source.transport,
            jumpChainBrokenReason: "Missing jump host"
        )
        let candidate = ContinuationHostCandidate(
            host: broken,
            connectionKey: descriptor.connectionKey + "&via=broken:missing"
        )

        XCTAssertEqual(
            ContinuationResolver.resolve(descriptor, among: [candidate]),
            .prefill(descriptor)
        )
    }

    func test_prefillRoutePolicyReusesOnlyAnExactSavedBastionWithoutMutation() {
        let descriptor = makeDescriptor()
        let via = descriptor.via[0]
        let exact = ContinuationSavedRouteEndpoint(
            endpoint: via,
            jumpHostID: nil
        )

        XCTAssertNil(
            ContinuationRouteReusePolicy.conflict(
                for: descriptor,
                destinationIdentifierExists: false,
                savedVia: [via.hostID: exact]
            )
        )
        XCTAssertEqual(
            ContinuationRouteReusePolicy.conflict(
                for: descriptor,
                destinationIdentifierExists: false,
                savedVia: [
                    via.hostID: ContinuationSavedRouteEndpoint(
                        endpoint: via,
                        jumpHostID: UUID()
                    )
                ]
            ),
            .routeDiffers(via.hostID)
        )

        let changedEndpoint = SessionActivityEndpoint(
            hostID: via.hostID,
            name: via.name,
            user: via.user,
            address: "different.example.invalid",
            port: via.port,
            transport: via.transport
        )
        XCTAssertEqual(
            ContinuationRouteReusePolicy.conflict(
                for: descriptor,
                destinationIdentifierExists: false,
                savedVia: [
                    via.hostID: ContinuationSavedRouteEndpoint(
                        endpoint: changedEndpoint,
                        jumpHostID: nil
                    )
                ]
            ),
            .endpointDiffers(via.hostID)
        )
        XCTAssertEqual(
            ContinuationRouteReusePolicy.conflict(
                for: descriptor,
                destinationIdentifierExists: true,
                savedVia: [:]
            ),
            .destinationIdentifierAlreadyExists
        )
    }

    func test_prefillRoutePolicyRequiresEverySavedHopToKeepItsAdvertisedParent() {
        let outer = SessionActivityEndpoint(
            hostID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            name: "edge",
            user: "deploy",
            address: "edge.example",
            port: 22,
            transport: .ssh
        )
        let inner = SessionActivityEndpoint(
            hostID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            name: "core",
            user: "deploy",
            address: "core.internal",
            port: 2202,
            transport: .ssh
        )
        let descriptor = SessionActivityDescriptor(
            endpoint: SessionActivityEndpoint(
                hostID: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
                name: "terminal",
                user: "alice",
                address: "terminal.internal",
                port: 22,
                transport: .mosh
            ),
            launchMode: .autoTmux,
            tmuxSessionName: "tessera-live",
            via: [outer, inner]
        )
        let exactSavedRoute = [
            outer.hostID: ContinuationSavedRouteEndpoint(
                endpoint: outer,
                jumpHostID: nil
            ),
            inner.hostID: ContinuationSavedRouteEndpoint(
                endpoint: inner,
                jumpHostID: outer.hostID
            ),
        ]

        XCTAssertNil(
            ContinuationRouteReusePolicy.conflict(
                for: descriptor,
                destinationIdentifierExists: false,
                savedVia: exactSavedRoute
            )
        )

        var rerouted = exactSavedRoute
        rerouted[inner.hostID] = ContinuationSavedRouteEndpoint(
            endpoint: inner,
            jumpHostID: UUID()
        )
        XCTAssertEqual(
            ContinuationRouteReusePolicy.conflict(
                for: descriptor,
                destinationIdentifierExists: false,
                savedVia: rerouted
            ),
            .routeDiffers(inner.hostID)
        )
    }

    func test_handoffTmuxTargetReusesOnlyTheSameExactAutoTmuxSession() {
        XCTAssertTrue(
            ContinuationTmuxReusePolicy.mayReuseAutoTmuxSession(
                requestedSessionName: nil,
                activeSessionName: "any-live-target"
            )
        )
        XCTAssertTrue(
            ContinuationTmuxReusePolicy.mayReuseAutoTmuxSession(
                requestedSessionName: "  ",
                activeSessionName: nil
            )
        )
        XCTAssertTrue(
            ContinuationTmuxReusePolicy.mayReuseAutoTmuxSession(
                requestedSessionName: " production-tail ",
                activeSessionName: "production-tail"
            )
        )
        XCTAssertFalse(
            ContinuationTmuxReusePolicy.mayReuseAutoTmuxSession(
                requestedSessionName: "production-tail",
                activeSessionName: "different-session"
            )
        )
        XCTAssertFalse(
            ContinuationTmuxReusePolicy.mayReuseAutoTmuxSession(
                requestedSessionName: "production-tail",
                activeSessionName: nil
            )
        )
    }

    func test_jumpMoshFallbackDescriptorDerivesActualSSHRouteIdentity() throws {
        let jump = Host(
            id: UUID(),
            name: "bastion",
            address: "edge.example",
            port: 2222,
            user: "jump",
            transport: .ssh,
            launchMode: .customCommand
        )
        let actualFallback = Host(
            id: UUID(),
            name: "target",
            address: "target.internal",
            port: 22,
            user: "target",
            transport: .ssh,
            launchMode: .customCommand,
            jumpChain: [jump]
        )

        let descriptor = try SessionActivityDescriptor(
            host: actualFallback,
            resolvedTmuxSessionName: nil
        )

        XCTAssertEqual(descriptor.transport, .ssh)
        XCTAssertEqual(descriptor.launchMode, .customCommand)
        XCTAssertEqual(
            descriptor.connectionKey,
            "ssh:target@target.internal:22&via=\(jump.id.uuidString)"
        )
    }

    func test_insertionPlannerAlwaysPlansTheDestinationEvenWhenItIsSaved() {
        let descriptor = makeDescriptor()

        // The resolver's prefill contract means the destination is new
        // locally, so the planner includes it unconditionally — exactly like
        // the ContentView computation it shares the counting rule with.
        let planned = ContinuationInsertionPlanner.plannedInsertedHostIDs(
            for: descriptor
        ) { _ in true }

        XCTAssertEqual(planned, [descriptor.hostID])
    }

    func test_insertionPlannerExcludesSavedViaEndpointsAndIncludesUnsavedOnes() {
        let descriptor = makeDescriptor()
        let viaID = descriptor.via[0].hostID

        XCTAssertEqual(
            ContinuationInsertionPlanner.plannedInsertedHostIDs(for: descriptor) {
                $0 == viaID
            },
            [descriptor.hostID]
        )
        XCTAssertEqual(
            ContinuationInsertionPlanner.plannedInsertedHostIDs(for: descriptor) { _ in
                false
            },
            [descriptor.hostID, viaID]
        )
    }

    func test_insertionPlannerCountsAMixedSavedAndUnsavedChainPerEndpoint() {
        let outer = SessionActivityEndpoint(
            hostID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            name: "edge",
            user: "deploy",
            address: "edge.example",
            port: 22,
            transport: .ssh
        )
        let inner = SessionActivityEndpoint(
            hostID: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            name: "core",
            user: "deploy",
            address: "core.internal",
            port: 2202,
            transport: .ssh
        )
        let descriptor = SessionActivityDescriptor(
            endpoint: SessionActivityEndpoint(
                hostID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
                name: "terminal",
                user: "alice",
                address: "terminal.internal",
                port: 22,
                transport: .mosh
            ),
            launchMode: .customCommand,
            tmuxSessionName: nil,
            via: [outer, inner]
        )

        XCTAssertEqual(
            ContinuationInsertionPlanner.plannedInsertedHostIDs(for: descriptor) {
                $0 == outer.hostID
            },
            [descriptor.hostID, inner.hostID]
        )
        XCTAssertEqual(
            ContinuationInsertionPlanner.plannedInsertedHostIDs(for: descriptor) {
                $0 == inner.hostID
            },
            [descriptor.hostID, outer.hostID]
        )
    }

    func test_insertionPlannerWithEmptyViaPlansExactlyTheDestination() {
        let descriptor = SessionActivityDescriptor(
            endpoint: SessionActivityEndpoint(
                hostID: UUID(uuidString: "30000000-0000-0000-0000-000000000004")!,
                name: "direct",
                user: "alice",
                address: "direct.example",
                port: 22,
                transport: .ssh
            ),
            launchMode: .customCommand,
            tmuxSessionName: nil
        )

        XCTAssertEqual(
            ContinuationInsertionPlanner.plannedInsertedHostIDs(for: descriptor) { _ in true },
            [descriptor.hostID]
        )
    }

    func test_descriptorValidationRejectsDuplicateRouteHostIDs() {
        // A duplicate via ID can never reach the planner through a real
        // handoff: descriptor validation rejects the whole route, so the
        // Set-collapse case is pinned here at the validation level instead.
        let repeated = UUID(uuidString: "30000000-0000-0000-0000-000000000005")!
        let via = SessionActivityEndpoint(
            hostID: repeated,
            name: "bastion",
            user: "deploy",
            address: "bastion.example",
            port: 22,
            transport: .ssh
        )
        let descriptor = SessionActivityDescriptor(
            endpoint: SessionActivityEndpoint(
                hostID: UUID(uuidString: "30000000-0000-0000-0000-000000000006")!,
                name: "terminal",
                user: "alice",
                address: "terminal.internal",
                port: 22,
                transport: .ssh
            ),
            launchMode: .customCommand,
            tmuxSessionName: nil,
            via: [via, via]
        )

        XCTAssertThrowsError(try descriptor.validate()) { error in
            XCTAssertEqual(
                error as? SessionActivityDescriptor.DescriptorError,
                .duplicateRouteHostID(repeated)
            )
        }
    }

    private func makeDescriptor() -> SessionActivityDescriptor {
        let via = SessionActivityEndpoint(
            hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "atlas",
            user: "deploy",
            address: "atlas.internal",
            port: 2222,
            transport: .ssh,
            hostKeyFingerprint: "SHA256:bastion"
        )
        return SessionActivityDescriptor(
            endpoint: SessionActivityEndpoint(
                hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "zeus",
                user: "alice",
                address: "zeus.lan",
                port: 22,
                transport: .mosh,
                hostKeyFingerprint: "SHA256:destination"
            ),
            launchMode: .pinnedTmux,
            tmuxSessionName: "dev",
            via: [via]
        )
    }
}
