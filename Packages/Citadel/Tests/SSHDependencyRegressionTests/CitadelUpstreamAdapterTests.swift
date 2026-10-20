@testable import Citadel
import Crypto
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

final class CitadelUpstreamAdapterTests: XCTestCase {
    func testAuthenticationIdentityAppearsBeforeSuccessIsForwarded() throws {
        let loop = EmbeddedEventLoop()
        let delegate = DeferredAuthentication()
        let connection = ServerConnectionAuthentication(delegate: delegate)
        XCTAssertEqual(connection.supportedAuthenticationMethods, .password)
        let response = request("alice", on: connection, loop: loop)
        XCTAssertNil(connection.username)
        var observed: String?
        response.whenSuccess { _ in observed = connection.username }
        try delegate.complete("alice", with: .success(.success))
        loop.run()
        XCTAssertEqual(observed, "alice")
    }

    func testFailedPartialAndThrowingAuthenticationNeverPublishIdentity() throws {
        for decision: Result<NIOSSHUserAuthenticationOutcome, Error> in [
            .success(.failure), .success(.partialSuccess(remainingMethods: .password)),
            .failure(FixtureError.rejected),
        ] {
            let loop = EmbeddedEventLoop()
            let delegate = DeferredAuthentication()
            let connection = ServerConnectionAuthentication(delegate: delegate)
            let response = request("untrusted", on: connection, loop: loop)
            var completed = false
            response.whenComplete { _ in completed = true }
            try delegate.complete("untrusted", with: decision)
            loop.run()
            XCTAssertTrue(completed)
            XCTAssertNil(connection.username)
        }
    }

    func testConcurrentConnectionsKeepSeparateAuthenticatedIdentities() throws {
        let loop = EmbeddedEventLoop()
        let delegate = DeferredAuthentication()
        let first = ServerConnectionAuthentication(delegate: delegate)
        let second = ServerConnectionAuthentication(delegate: delegate)
        _ = request("alice", on: first, loop: loop)
        _ = request("bob", on: second, loop: loop)
        try delegate.complete("bob", with: .success(.success))
        loop.run()
        XCTAssertNil(first.username)
        XCTAssertEqual(second.username, "bob")
        try delegate.complete("alice", with: .success(.success))
        loop.run()
        XCTAssertEqual(first.username, "alice")
        XCTAssertEqual(second.username, "bob")
    }

    func testLateInFlightDecisionsCannotChangeAuthenticatedIdentity() throws {
        for decision: Result<NIOSSHUserAuthenticationOutcome, Error> in [
            .success(.success), .success(.failure),
            .success(.partialSuccess(remainingMethods: .password)),
            .failure(FixtureError.rejected),
        ] {
            let loop = EmbeddedEventLoop()
            let delegate = DeferredAuthentication()
            let connection = ServerConnectionAuthentication(delegate: delegate)
            _ = request("alice", on: connection, loop: loop)
            _ = request("late-request", on: connection, loop: loop)
            try delegate.complete("alice", with: .success(.success))
            loop.run()
            XCTAssertEqual(connection.username, "alice")
            try delegate.complete("late-request", with: decision)
            loop.run()
            XCTAssertEqual(connection.username, "alice")
        }
    }

    func testSSHStringWritersPreserveLengthPrefixAndRollback() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        buffer.writeInteger(UInt8(0x42))
        XCTAssertEqual(buffer.writeSSHString([UInt8(1), 2, 3]), 7)
        XCTAssertEqual(buffer.writeCompositeSSHString { $0.writeString("test") }, 8)
        XCTAssertEqual(Array(buffer.readableBytesView), [0x42, 0, 0, 0, 3, 1, 2, 3, 0, 0, 0, 4, 116, 101, 115, 116])
        let before = buffer
        XCTAssertThrowsError(try buffer.writeCompositeSSHString { value in
            value.writeString("discard")
            throw FixtureError.rejected
        })
        XCTAssertEqual(buffer, before)
    }

    func testEd25519OpenSSHExportImportPreservesKeyAndSigning() throws {
        let key = Curve25519.Signing.PrivateKey()
        let restored = try Curve25519.Signing.PrivateKey(sshEd25519: key.makeSSHRepresentation(comment: "upstream-regression"))
        XCTAssertEqual(restored.rawRepresentation, key.rawRepresentation)
        let message = Data("Citadel upstream SSH migration".utf8)
        XCTAssertTrue(key.publicKey.isValidSignature(try restored.signature(for: message), for: message))
        XCTAssertEqual(NIOSSHPrivateKey(ed25519Key: restored).publicKey, NIOSSHPrivateKey(ed25519Key: key).publicKey)
    }

    private func request(
        _ username: String,
        on connection: ServerConnectionAuthentication,
        loop: EmbeddedEventLoop
    ) -> EventLoopFuture<NIOSSHUserAuthenticationOutcome> {
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOutcome.self)
        connection.requestReceived(
            request: .init(username: username, serviceName: "ssh-connection", request: .password(.init(password: "fixture-only"))),
            responsePromise: promise
        )
        return promise.futureResult
    }
}

private enum FixtureError: Error { case rejected }

private final class DeferredAuthentication: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password
    private var pending: [String: EventLoopPromise<NIOSSHUserAuthenticationOutcome>] = [:]

    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        pending[request.username] = responsePromise
    }

    func complete(_ username: String, with result: Result<NIOSSHUserAuthenticationOutcome, Error>) throws {
        try XCTUnwrap(pending.removeValue(forKey: username)).completeWith(result)
    }
}
