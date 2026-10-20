import XCTest
import Dispatch
import MoshCABI

private var observedMoshBatchSizes: [Int] = []

private let moshOutputCollector: @convention(c) (
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutableRawPointer?
) -> Void = { _, length, _ in
    observedMoshBatchSizes.append(length)
}

private final class ReentrantMoshCallbackContext {
    var client: OpaquePointer?
    var callbackCount = 0
    var reentrantQueryResult = TESSERA_MOSH_OK
}

private final class BlockingMoshCallbackContext {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didBlock = false

    func blockFirstCallback() {
        lock.lock()
        let shouldBlock = !didBlock
        didBlock = true
        lock.unlock()
        guard shouldBlock else { return }
        entered.signal()
        release.wait()
    }
}

private final class ConcurrentClientCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedClients: [OpaquePointer] = []
    private var storedFailureCount = 0

    func record(result: tessera_mosh_result, client: OpaquePointer?) {
        lock.lock()
        if result == TESSERA_MOSH_OK, let client {
            storedClients.append(client)
        } else {
            storedFailureCount += 1
        }
        lock.unlock()
    }

    var snapshot: (clients: [OpaquePointer], failureCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (storedClients, storedFailureCount)
    }
}

private let reentrantDestroyingCallback: @convention(c) (
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutableRawPointer?
) -> Void = { _, _, context in
    guard let context else { return }
    let box = Unmanaged<ReentrantMoshCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    box.callbackCount += 1
    guard box.callbackCount == 1, let client = box.client else { return }
    var connected: Int32 = 0
    box.reentrantQueryResult = tessera_mosh_client_is_connected(client, &connected)
    tessera_mosh_client_destroy(client)
    box.client = nil
}

private let blockingMoshCallback: @convention(c) (
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutableRawPointer?
) -> Void = { _, _, context in
    guard let context else { return }
    Unmanaged<BlockingMoshCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .blockFirstCallback()
}

final class MoshCABITests: XCTestCase {
    func testFreshRepaintFenceRejectsInvalidArgumentsAndWaitsWithoutEmittingOutput() {
        var token: UInt64 = 0
        var ready: Int32 = 0
        XCTAssertEqual(tessera_mosh_client_begin_full_repaint_fence(nil, &token), TESSERA_MOSH_INVALID_ARGUMENT)
        XCTAssertEqual(tessera_mosh_client_is_full_repaint_fence_ready(nil, 1, &ready), TESSERA_MOSH_INVALID_ARGUMENT)
        guard let client = makeClient(key: "qiXpjXIk6M8/nWtBn9s6rQ", callback: moshOutputCollector) else { return }
        defer { tessera_mosh_client_destroy(client) }
        XCTAssertEqual(tessera_mosh_client_begin_full_repaint_fence(client, nil), TESSERA_MOSH_INVALID_ARGUMENT)
        XCTAssertEqual(tessera_mosh_client_begin_full_repaint_fence(client, &token), TESSERA_MOSH_INVALID_STATE)
        XCTAssertEqual(tessera_mosh_client_is_full_repaint_fence_ready(client, 0, &ready), TESSERA_MOSH_INVALID_ARGUMENT)
        XCTAssertEqual(tessera_mosh_client_is_full_repaint_fence_ready(client, 1, nil), TESSERA_MOSH_INVALID_ARGUMENT)
        XCTAssertEqual(tessera_mosh_client_is_full_repaint_fence_ready(client, 1, &ready), TESSERA_MOSH_INVALID_STATE)

        XCTAssertEqual(tessera_mosh_client_start(client), TESSERA_MOSH_OK)
        let outputBeforeFence = observedMoshBatchSizes
        XCTAssertEqual(tessera_mosh_client_begin_full_repaint_fence(client, &token), TESSERA_MOSH_OK)
        XCTAssertGreaterThan(token, 0)
        XCTAssertEqual(tessera_mosh_client_is_full_repaint_fence_ready(client, token, &ready), TESSERA_MOSH_OK)
        XCTAssertEqual(ready, 0, "no sent state or server echo has advanced")
        XCTAssertEqual(observedMoshBatchSizes, outputBeforeFence, "fence creation and polling cannot collect terminal bytes")
        XCTAssertEqual(tessera_mosh_client_shutdown(client), TESSERA_MOSH_OK)
        XCTAssertEqual(tessera_mosh_client_is_full_repaint_fence_ready(client, token, &ready), TESSERA_MOSH_OK)
        XCTAssertEqual(ready, 0)
        XCTAssertEqual(tessera_mosh_client_begin_full_repaint_fence(client, &token), TESSERA_MOSH_OK)
        XCTAssertEqual(token, 0)
    }

    override func setUp() {
        super.setUp()
        observedMoshBatchSizes.removeAll()
    }

    func testVersionedHeaderAndBoundedLifecycleABI() {
        XCTAssertEqual(tessera_mosh_abi_version(), TESSERA_MOSH_C_ABI_VERSION)
        XCTAssertEqual(
            tessera_mosh_max_output_batch_bytes(),
            Int(TESSERA_MOSH_C_ABI_MAX_OUTPUT_BATCH_BYTES)
        )

        withClient(key: "qiXpjXIk6M8/nWtBn9s6rQ", callback: moshOutputCollector) { client in
            var value: Int32 = -1
            XCTAssertEqual(
                tessera_mosh_client_retains_bootstrap_key_material(client, &value),
                TESSERA_MOSH_OK
            )
            XCTAssertEqual(value, 1)
            XCTAssertEqual(tessera_mosh_client_start(client), TESSERA_MOSH_OK)
            XCTAssertEqual(tessera_mosh_client_start(client), TESSERA_MOSH_INVALID_STATE)
            XCTAssertFalse(observedMoshBatchSizes.isEmpty)
            XCTAssertTrue(observedMoshBatchSizes.allSatisfy {
                $0 > 0 && $0 <= Int(TESSERA_MOSH_C_ABI_MAX_OUTPUT_BATCH_BYTES)
            })

            XCTAssertEqual(
                tessera_mosh_client_is_connected(client, &value),
                TESSERA_MOSH_OK
            )
            XCTAssertTrue(value == 0 || value == 1)
            XCTAssertEqual(
                tessera_mosh_client_is_transport_reachable(client, &value),
                TESSERA_MOSH_OK
            )
            XCTAssertTrue(value == 0 || value == 1)
            XCTAssertEqual(
                tessera_mosh_client_is_shutdown_complete(client, &value),
                TESSERA_MOSH_OK
            )
            XCTAssertTrue(value == 0 || value == 1)
            XCTAssertEqual(
                tessera_mosh_client_application_mode_cursor_keys(client, &value),
                TESSERA_MOSH_OK
            )
            XCTAssertTrue(value == 0 || value == 1)

            XCTAssertEqual(
                tessera_mosh_client_retains_bootstrap_key_material(client, &value),
                TESSERA_MOSH_OK
            )
            XCTAssertEqual(value, 0)

            var wait: UInt64 = 0
            XCTAssertEqual(tessera_mosh_client_tick(client, &wait), TESSERA_MOSH_OK)
            XCTAssertEqual(tessera_mosh_client_inject_bytes(client, nil, 0), TESSERA_MOSH_OK)
            XCTAssertEqual(tessera_mosh_client_resize(client, 120, 40), TESSERA_MOSH_OK)
            XCTAssertEqual(
                tessera_mosh_client_force_full_repaint(client),
                TESSERA_MOSH_OK
            )

            var fd: Int32 = 0
            XCTAssertEqual(tessera_mosh_client_socket_fd(client, &fd), TESSERA_MOSH_OK)
            XCTAssertGreaterThanOrEqual(fd, -1)

            var count = 0
            let sizing = tessera_mosh_client_copy_socket_fds(client, nil, 0, &count)
            XCTAssertTrue(sizing == TESSERA_MOSH_OK || sizing == TESSERA_MOSH_BUFFER_TOO_SMALL)
            XCTAssertGreaterThanOrEqual(count, 0)
            XCTAssertEqual(tessera_mosh_client_shutdown(client), TESSERA_MOSH_OK)
            XCTAssertEqual(
                tessera_mosh_client_is_shutdown_complete(client, &value),
                TESSERA_MOSH_OK
            )
            XCTAssertTrue(value == 0 || value == 1)
        }
    }

    /// The vendored client only accepts a numeric UDP target; the core must
    /// resolve the name both platforms hand it, so a host saved by DNS name
    /// starts exactly like one saved by address.
    func testStartResolvesAHostNameToTheNumericTargetTheClientRequires() {
        let created = Self.createClient(
            key: "qiXpjXIk6M8/nWtBn9s6rQ",
            callback: nil,
            host: "localhost"
        )
        XCTAssertEqual(created.result, TESSERA_MOSH_OK)
        guard let client = created.client else { return XCTFail("no client") }
        defer { tessera_mosh_client_destroy(client) }
        XCTAssertEqual(tessera_mosh_client_start(client), TESSERA_MOSH_OK)
        var fd: Int32 = -1
        XCTAssertEqual(tessera_mosh_client_socket_fd(client, &fd), TESSERA_MOSH_OK)
        XCTAssertGreaterThanOrEqual(fd, 0, "a resolved target must yield a bound UDP socket")
        XCTAssertEqual(tessera_mosh_client_shutdown(client), TESSERA_MOSH_OK)
    }

    func testStartReportsAnUnresolvableHostNameInsteadOfABadIPAddress() {
        let created = Self.createClient(
            key: "qiXpjXIk6M8/nWtBn9s6rQ",
            callback: nil,
            host: "tessera-no-such-host.invalid"
        )
        XCTAssertEqual(created.result, TESSERA_MOSH_OK)
        guard let client = created.client else { return XCTFail("no client") }
        defer { tessera_mosh_client_destroy(client) }
        XCTAssertEqual(tessera_mosh_client_start(client), TESSERA_MOSH_FAILURE)
        var required = 0
        XCTAssertEqual(
            tessera_mosh_client_copy_last_error(client, nil, 0, &required),
            TESSERA_MOSH_BUFFER_TOO_SMALL
        )
        var bytes = [CChar](repeating: 0, count: required)
        XCTAssertEqual(
            tessera_mosh_client_copy_last_error(client, &bytes, bytes.count, &required),
            TESSERA_MOSH_OK
        )
        let message = String(cString: bytes)
        XCTAssertTrue(message.contains("Could not resolve the mosh host tessera-no-such-host.invalid"), message)
        XCTAssertFalse(message.contains("Bad IP address"), message)
    }

    func testInvalidVersionAndArgumentsFailClosed() {
        var output: OpaquePointer?
        var config = tessera_mosh_client_config_v1()
        config.abi_version = 999
        config.struct_size = UInt32(MemoryLayout<tessera_mosh_client_config_v1>.size)
        "127.0.0.1".withCString { host in
            "qiXpjXIk6M8/nWtBn9s6rQ".withCString { key in
                config.host = host
                config.port = 60_001
                config.base64_key = key
                XCTAssertEqual(
                    tessera_mosh_client_create(&config, &output),
                    TESSERA_MOSH_INVALID_ARGUMENT
                )
            }
        }
        XCTAssertNil(output)
        XCTAssertEqual(tessera_mosh_client_tick(nil, nil), TESSERA_MOSH_INVALID_ARGUMENT)

        withClient(key: "qiXpjXIk6M8/nWtBn9s6rQ", callback: nil) { client in
            let byte: UInt8 = 0
            XCTAssertEqual(
                tessera_mosh_client_inject_bytes(
                    client,
                    [byte],
                    Int(TESSERA_MOSH_C_ABI_MAX_INPUT_BATCH_BYTES) + 1
                ),
                TESSERA_MOSH_INVALID_ARGUMENT
            )
        }
    }

    func testFailureDiagnosticIsBoundedAndDoesNotEchoBootstrapKey() {
        let invalidKey = "AAAAAAAAAAAAAAAAAAAAAB"
        withClient(key: invalidKey, callback: nil) { client in
            XCTAssertEqual(tessera_mosh_client_start(client), TESSERA_MOSH_FAILURE)
            var required = 0
            XCTAssertEqual(
                tessera_mosh_client_copy_last_error(client, nil, 0, &required),
                TESSERA_MOSH_BUFFER_TOO_SMALL
            )
            XCTAssertGreaterThan(required, 1)
            var bytes = [CChar](repeating: 0, count: required)
            XCTAssertEqual(
                tessera_mosh_client_copy_last_error(client, &bytes, bytes.count, &required),
                TESSERA_MOSH_OK
            )
            let message = String(cString: bytes)
            XCTAssertFalse(message.contains(invalidKey))

            var retained: Int32 = 1
            XCTAssertEqual(
                tessera_mosh_client_retains_bootstrap_key_material(client, &retained),
                TESSERA_MOSH_OK
            )
            XCTAssertEqual(retained, 0)
        }
    }

    func testConcurrentCallsAreSerializedAndDestroyRacesAreSafe() {
        guard let client = makeClient(key: "qiXpjXIk6M8/nWtBn9s6rQ", callback: nil) else {
            return
        }
        XCTAssertEqual(tessera_mosh_client_start(client), TESSERA_MOSH_OK)

        let queue = DispatchQueue(
            label: "MoshCABITests.concurrent",
            attributes: .concurrent
        )
        let group = DispatchGroup()
        let resultLock = NSLock()
        var results: [tessera_mosh_result] = []
        for index in 0..<96 {
            group.enter()
            queue.async {
                let result: tessera_mosh_result
                if index.isMultiple(of: 3) {
                    var connected: Int32 = 0
                    result = tessera_mosh_client_is_connected(client, &connected)
                } else if index.isMultiple(of: 2) {
                    result = tessera_mosh_client_resize(client, 80 + Int32(index), 24)
                } else {
                    result = tessera_mosh_client_inject_bytes(client, nil, 0)
                }
                resultLock.lock()
                results.append(result)
                resultLock.unlock()
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(results.count, 96)
        XCTAssertTrue(results.allSatisfy { $0 == TESSERA_MOSH_OK })

        results.removeAll(keepingCapacity: true)
        for index in 0..<96 {
            group.enter()
            queue.async {
                if index == 24 {
                    tessera_mosh_client_destroy(client)
                } else {
                    var connected: Int32 = 0
                    let result = tessera_mosh_client_is_connected(client, &connected)
                    resultLock.lock()
                    results.append(result)
                    resultLock.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(results.count, 95)
        XCTAssertTrue(results.allSatisfy {
            $0 == TESSERA_MOSH_OK || $0 == TESSERA_MOSH_INVALID_ARGUMENT
        })

        var connected: Int32 = 0
        XCTAssertEqual(
            tessera_mosh_client_is_connected(client, &connected),
            TESSERA_MOSH_INVALID_ARGUMENT
        )
        tessera_mosh_client_destroy(client)
    }

    func testDestroyedHandleNeverAliasesRecreatedClient() {
        guard let retired = makeClient(key: "qiXpjXIk6M8/nWtBn9s6rQ", callback: nil) else {
            return
        }
        let retiredIdentity = UInt(bitPattern: retired)
        tessera_mosh_client_destroy(retired)

        guard let current = makeClient(key: "qiXpjXIk6M8/nWtBn9s6rQ", callback: nil) else {
            return
        }
        defer { tessera_mosh_client_destroy(current) }
        XCTAssertNotEqual(UInt(bitPattern: current), retiredIdentity)

        var value: Int32 = -1
        XCTAssertEqual(
            tessera_mosh_client_is_connected(retired, &value),
            TESSERA_MOSH_INVALID_ARGUMENT
        )
        tessera_mosh_client_destroy(retired)
        XCTAssertEqual(
            tessera_mosh_client_retains_bootstrap_key_material(current, &value),
            TESSERA_MOSH_OK
        )
        XCTAssertEqual(value, 1)
    }

    func testConcurrentCreateDestroyPermanentlyRetiresEveryHandle() {
        let capture = ConcurrentClientCapture()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let created = Self.createClient(key: "qiXpjXIk6M8/nWtBn9s6rQ", callback: nil)
            capture.record(result: created.result, client: created.client)
        }
        let created = capture.snapshot
        XCTAssertEqual(created.failureCount, 0)
        XCTAssertEqual(created.clients.count, 64)
        XCTAssertEqual(
            Set(created.clients.map { UInt(bitPattern: $0) }).count,
            created.clients.count
        )

        DispatchQueue.concurrentPerform(iterations: created.clients.count) { index in
            tessera_mosh_client_destroy(created.clients[index])
        }

        guard let current = makeClient(key: "qiXpjXIk6M8/nWtBn9s6rQ", callback: nil) else {
            return
        }
        defer { tessera_mosh_client_destroy(current) }
        let currentIdentity = UInt(bitPattern: current)
        XCTAssertFalse(created.clients.contains {
            UInt(bitPattern: $0) == currentIdentity
        })

        for retired in created.clients {
            var value: Int32 = -1
            XCTAssertEqual(
                tessera_mosh_client_is_connected(retired, &value),
                TESSERA_MOSH_INVALID_ARGUMENT
            )
            tessera_mosh_client_destroy(retired)
        }

        var retained: Int32 = -1
        XCTAssertEqual(
            tessera_mosh_client_retains_bootstrap_key_material(current, &retained),
            TESSERA_MOSH_OK
        )
        XCTAssertEqual(retained, 1)
    }

    func testCallbackCanDestroyItsClientWithoutDeadlockOrUseAfterFree() {
        let context = ReentrantMoshCallbackContext()
        let contextPointer = Unmanaged.passUnretained(context).toOpaque()
        guard let client = makeClient(
            key: "qiXpjXIk6M8/nWtBn9s6rQ",
            callback: reentrantDestroyingCallback,
            context: contextPointer
        ) else {
            return
        }
        context.client = client

        XCTAssertEqual(tessera_mosh_client_start(client), TESSERA_MOSH_OK)
        XCTAssertGreaterThanOrEqual(context.callbackCount, 1)
        XCTAssertEqual(context.reentrantQueryResult, TESSERA_MOSH_INVALID_STATE)

        var connected: Int32 = 0
        XCTAssertEqual(
            tessera_mosh_client_is_connected(client, &connected),
            TESSERA_MOSH_INVALID_ARGUMENT
        )
        tessera_mosh_client_destroy(client)
    }

    func testExternalDestroyWaitsForSynchronousCallbackToReturn() {
        let context = BlockingMoshCallbackContext()
        let contextPointer = Unmanaged.passUnretained(context).toOpaque()
        guard let client = makeClient(
            key: "qiXpjXIk6M8/nWtBn9s6rQ",
            callback: blockingMoshCallback,
            context: contextPointer
        ) else {
            return
        }

        let queue = DispatchQueue(
            label: "MoshCABITests.destroy-wait",
            attributes: .concurrent
        )
        let startDone = DispatchGroup()
        startDone.enter()
        queue.async {
            _ = tessera_mosh_client_start(client)
            startDone.leave()
        }

        guard context.entered.wait(timeout: .now() + 1) == .success else {
            context.release.signal()
            _ = startDone.wait(timeout: .now() + 1)
            tessera_mosh_client_destroy(client)
            return XCTFail("Mosh start did not synchronously enter its output callback")
        }

        let destroyDone = DispatchGroup()
        for _ in 0..<2 {
            destroyDone.enter()
            queue.async {
                tessera_mosh_client_destroy(client)
                destroyDone.leave()
            }
        }
        XCTAssertEqual(destroyDone.wait(timeout: .now() + 0.05), .timedOut)

        context.release.signal()
        XCTAssertEqual(startDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(destroyDone.wait(timeout: .now() + 1), .success)

        var connected: Int32 = 0
        XCTAssertEqual(
            tessera_mosh_client_is_connected(client, &connected),
            TESSERA_MOSH_INVALID_ARGUMENT
        )
    }

    private func withClient(
        key: String,
        callback: tessera_mosh_output_callback?,
        body: (OpaquePointer) -> Void
    ) {
        guard let client = makeClient(key: key, callback: callback) else { return }
        defer { tessera_mosh_client_destroy(client) }
        body(client)
    }

    private func makeClient(
        key: String,
        callback: tessera_mosh_output_callback?,
        context: UnsafeMutableRawPointer? = nil
    ) -> OpaquePointer? {
        let created = Self.createClient(key: key, callback: callback, context: context)
        XCTAssertEqual(created.result, TESSERA_MOSH_OK)
        guard let client = created.client else {
            XCTFail("C ABI did not create a client")
            return nil
        }
        return client
    }

    private static func createClient(
        key: String,
        callback: tessera_mosh_output_callback?,
        context: UnsafeMutableRawPointer? = nil,
        host hostName: String = "127.0.0.1"
    ) -> (result: tessera_mosh_result, client: OpaquePointer?) {
        var client: OpaquePointer?
        var result = TESSERA_MOSH_FAILURE
        var config = tessera_mosh_client_config_v1()
        config.abi_version = TESSERA_MOSH_C_ABI_VERSION
        config.struct_size = UInt32(MemoryLayout<tessera_mosh_client_config_v1>.size)
        config.port = 60_001
        config.output_callback = callback
        config.output_context = context

        hostName.withCString { host in
            key.withCString { keyBytes in
                config.host = host
                config.base64_key = keyBytes
                result = tessera_mosh_client_create(&config, &client)
            }
        }
        return (result, client)
    }
}
