import Foundation
import XCTest
@testable import TesseraDomainCore

final class DomainCoreTests: XCTestCase {
    func testHostProfileEncodingIsSecretFreeByConstruction() throws {
        let profile = HostProfile(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "production",
            endpoint: HostEndpoint(user: "alice", address: "server.example", port: 22),
            transport: .mosh,
            launch: .pinnedTmux(sessionName: "dev"),
            jumpHostIDs: [],
            tags: ["prod"]
        )
        let data = try JSONEncoder().encode(profile)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in [
            "password", "privateKey", "storedKey", "credentialID", "keychain", "secret",
        ] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
        XCTAssertEqual(try JSONDecoder().decode(HostProfile.self, from: data), profile)
    }

    func testRouteRejectsDuplicateOrCyclicNodes() throws {
        let id = UUID()
        let node = ResolvedRouteNode(
            profile: HostProfile(
                id: id,
                name: "host",
                endpoint: HostEndpoint(user: "alice", address: "host")
            ),
            credentialReference: .none
        )
        XCTAssertThrowsError(try HostRoute(hops: [node], destination: node)) {
            XCTAssertEqual($0 as? DomainValidationError, .cyclicOrDuplicateRoute(id))
        }
    }

    func testConnectionRequestRequiresOnePolicyGeneration() throws {
        let host = HostProfile(
            name: "host",
            endpoint: HostEndpoint(user: "alice", address: "host")
        )
        let node = ResolvedRouteNode(profile: host, credentialReference: .none)
        let route = try HostRoute(hops: [], destination: node)
        let credential = TestCredential(generation: 7)
        XCTAssertThrowsError(try ConnectionRequest(
            route: route,
            credentials: [RouteCredential(hostID: host.id, capability: credential)],
            policyGeneration: 8
        )) {
            XCTAssertEqual($0 as? ConnectionRequestError, .mixedPolicyGeneration)
        }
    }

    func testConnectionRequestIsAgeAndGenerationBoundAtUse() throws {
        let createdAt = Date(timeIntervalSince1970: 100)
        let host = HostProfile(
            name: "host",
            endpoint: HostEndpoint(user: "alice", address: "host")
        )
        let node = ResolvedRouteNode(profile: host, credentialReference: .none)
        let route = try HostRoute(hops: [], destination: node)
        let credential = TestCredential(generation: 7)
        let request = try ConnectionRequest(
            route: route,
            credentials: [RouteCredential(hostID: host.id, capability: credential)],
            policyGeneration: 7,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(30)
        )

        XCTAssertNoThrow(try request.validateForUse(
            now: createdAt.addingTimeInterval(29),
            currentPolicyGeneration: 7
        ))
        XCTAssertThrowsError(try request.validateForUse(
            now: createdAt.addingTimeInterval(30),
            currentPolicyGeneration: 7
        )) {
            XCTAssertEqual($0 as? ConnectionRequestError, .expired)
        }
        XCTAssertThrowsError(try request.validateForUse(
            now: createdAt.addingTimeInterval(1),
            currentPolicyGeneration: 8
        )) {
            XCTAssertEqual(
                $0 as? ConnectionRequestError,
                .stalePolicy(expected: 7, actual: 8)
            )
        }
    }

    func testConnectionRequestRejectsCallerExtendedLifetime() throws {
        let createdAt = Date(timeIntervalSince1970: 100)
        let host = HostProfile(
            name: "host",
            endpoint: HostEndpoint(user: "alice", address: "host")
        )
        let route = try HostRoute(
            hops: [],
            destination: ResolvedRouteNode(profile: host, credentialReference: .none)
        )

        XCTAssertThrowsError(try ConnectionRequest(
            route: route,
            credentials: [],
            policyGeneration: 7,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(ConnectionRequest.maximumLifetime + 1)
        )) {
            XCTAssertEqual($0 as? ConnectionRequestError, .invalidLifetime)
        }
    }
}

private struct TestCredential: CredentialCapability {
    let generation: UInt64
    var kind: CredentialKind { .password }
    var credentialID: UUID? { nil }
    var policyGeneration: UInt64 { generation }
    var requiresOwnerAuthorization: Bool { false }
}
