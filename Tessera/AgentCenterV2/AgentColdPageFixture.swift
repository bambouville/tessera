#if DEBUG
import Darwin
import CryptoKit
import Foundation
import SwiftUI
import TesseraCore

/// Private finite-corpus benchmark only. No provider control, user host, or
/// production transport selection. The external runner owns the helper and
/// Unix delay proxy, optionally backed by an authenticated loopback SSH fixture.
@MainActor
final class AgentColdPageFixture: NSObject {
    struct Configuration: Decodable {
        let directory: String
        let socket: String
        let transcript: String
        let provider: String
        let expectedInventory: Int
        let expectedInventorySHA256: String
        let inventoryBeforeBootstrap: Bool
        let coldApp: Bool?
    }
    static weak var active: AgentColdPageFixture?
    private weak var model: AgentCenterV2PresentationModel?
    private let runtime = AgentCenterRuntime()
    private var connection: AppleAgentIngestionConnection?
    private var configuration: Configuration?
    private var threadID: AgentThreadID?
    private var displayLink: CADisplayLink?
    private var displayTicks = 0
    private var completed = false
    private var measurements: [String: Any] = [:]

    init(model: AgentCenterV2PresentationModel) { self.model = model; super.init(); Self.active = self }

    static func now() -> UInt64 {
        var time = timespec(); clock_gettime(CLOCK_MONOTONIC, &time)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }
    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
    private func publish(_ value: [String: Any], name: String) throws {
        guard let configuration else { throw AgentIngestionError.malformedFrame }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: configuration.directory).appendingPathComponent(name), options: .atomic)
    }
    func start() async {
        var stage = "configuration"
        do {
            guard let encoded = ProcessInfo.processInfo.environment["TESSERA_COLD_PAGE_CONFIG"],
                  let data = Data(base64Encoded: encoded), data.count < 8192 else { throw AgentIngestionError.malformedFrame }
            let config = try JSONDecoder().decode(Configuration.self, from: data)
            // Foundation standardization rewrites /private/tmp to /tmp on
            // Darwin. Validate the original private path without that alias.
            let directory = config.directory
            let components = directory.split(separator: "/", omittingEmptySubsequences: false)
            var info = stat()
            guard directory.hasPrefix("/private/tmp/tessera-native-paint-"),
                  !components.contains("."), !components.contains(".."), !components.dropFirst().contains(""),
                  directory.utf8.count < 90, lstat(directory, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
                  config.socket == directory + "/proxy.sock", config.transcript.hasPrefix(directory + "/"),
                  (1...16384).contains(config.expectedInventory),
                  let provider = AgentProviderID(rawValue: config.provider), [.claude, .codex].contains(provider)
            else { throw AgentIngestionError.malformedFrame }
            configuration = config
            stage = "orientation"
            // Fixture construction precedes attaching the root view. Geometry
            // requests made before foreground activation are not effective.
            for _ in 0..<50 {
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   scene.activationState == .foregroundActive, scene.windows.contains(where: { $0.isKeyWindow }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            if UIDevice.current.userInterfaceIdiom == .pad,
               let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                // The run-scoped XCUITest sets physical device orientation.
                // iPad multitasking can reject app-requested geometry (101).
                for _ in 0..<30 {
                    if scene.interfaceOrientation.isLandscape { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            // Allow the resident app's empty fixture surface to settle before
            // the runner starts a fresh helper. This is not app-launch timing.
            if config.coldApp != true { try await Task.sleep(for: .milliseconds(500)) }
            if UIDevice.current.userInterfaceIdiom == .pad,
               let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               !scene.interfaceOrientation.isLandscape { throw AgentIngestionError.malformedFrame }
            measurements["appBaselineRSSBytes"] = Self.residentBytes()
            stage = "ready-file"
            try publish(["readyNS": Self.now(), "appPID": getpid()], name: "ready.json")
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("private-native-paint")!, transport: .ssh, capabilities: [.observe])
            let factory = AppleAgentStreamingExecFactory { request in
                let handle = try await AgentColdPageSocket.open(path: config.socket, generation: request.binding.carrierGeneration)
                try await handle.send(request.stdin)
                return handle
            }
            stage = "hello"
            let connection = try await AppleAgentIngestionConnection.open(factory: factory, binding: binding)
            self.connection = connection
            measurements["helloNS"] = Self.now()
            let host = UUID()
            if config.inventoryBeforeBootstrap {
                stage = "inventory"
                try await loadInventory(connection: connection, host: host, config: config)
            }
            stage = "resolve"
            let resolved = try await connection.request(["kind": .string("resolve"), "provider": .string(config.provider),
                "transcriptRef": .string(config.transcript)])
            guard let handle = resolved.object["thread"]?.stringValue,
                  let session = resolved.object["sessionID"]?.stringValue,
                  let thread = AgentThreadID(hostID: host, providerID: provider, providerSessionID: session)
            else { throw AgentIngestionError.malformedFrame }
            threadID = thread
            await runtime.register(.init(id: thread, providerName: config.provider,
                availability: .init(content: true, status: false, actions: false, spawn: false, fork: false, search: false)))
            // The real app navigates when the user selects a thread, before
            // the asynchronous bootstrap completes. Do not serialize a fresh
            // phone navigation animation after reading the entire first page.
            model?.apply(list: await runtime.listSnapshot())
            if let initial = await runtime.snapshot(for: thread) { model?.apply(thread: initial) }
            model?.select(thread)
            model?.requestNarrowThreadNavigation(thread)
            stage = "bootstrap"
            let reply = try await connection.request(["kind": .string("window.read"), "thread": .string(handle),
                "operation": .string("bootstrap"), "windowVersion": .number(0), "limit": .number(100)])
            guard let page = reply.page, !page.records.isEmpty,
                  await runtime.apply(page: page, to: thread).accepted,
                  let snapshot = await runtime.snapshot(for: thread), !snapshot.messages.isEmpty,
                  let window = snapshot.ingestionWindow else { throw AgentIngestionError.malformedFrame }
            measurements["modelNS"] = Self.now()
            measurements["records"] = page.records.count
            measurements["messages"] = snapshot.messages.count
            measurements["hostPeakRSSBytes"] = reply.object["hostPeakRSSBytes"]?.numberValue
            measurements["bytesRead"] = reply.object["bytesRead"]?.numberValue
            model?.apply(list: await runtime.listSnapshot())
            model?.apply(thread: snapshot)
            try await connection.acknowledgeWindow(page, thread: handle, snapshot: window)
            if !config.inventoryBeforeBootstrap {
                stage = "inventory"
                try await loadInventory(connection: connection, host: host, config: config)
            }
        } catch {
            let failureErrno = errno
            NSLog("TESSERA_NATIVE_PAINT failure stage=%@ errno=%d domain=%@ code=%ld", stage, errno,
                  (error as NSError).domain, (error as NSError).code)
            try? publish(["error": "native_cold_page_failed", "stage": stage, "failedNS": Self.now(),
                          "errno": failureErrno, "errorCode": (error as NSError).code], name: "paint.json")
            model?.reportUnavailable("Private cold-page benchmark failed")
            if let connection { await connection.close() }
        }
    }

    private func loadInventory(connection: AppleAgentIngestionConnection, host: UUID, config: Configuration) async throws {
        var sources = Set<String>()
        var seen = Set<String>()
        var cursor: String?
        repeat {
            var fields: [String: AgentJSONValue] = ["kind": .string("inventory"), "limit": .number(500)]
            if let cursor { fields["cursor"] = .string(cursor) }
            let reply = try await connection.request(fields)
            var summaries: [AgentThreadSummary] = []
            for row in reply.inventory {
                guard let name = row["provider"]?.stringValue, let kind = AgentProviderID(rawValue: name),
                      let session = row["sessionID"]?.stringValue,
                      let source = row["transcriptRef"]?.stringValue, sources.insert(source).inserted,
                      let id = AgentThreadID(hostID: host, providerID: kind, providerSessionID: session)
                else { throw AgentIngestionError.malformedFrame }
                guard sources.count <= config.expectedInventory else { throw AgentIngestionError.capacityExceeded }
                summaries.append(.init(id: id, providerName: name,
                    availability: .init(content: true, status: false, actions: false, spawn: false, fork: false, search: false)))
            }
            for offset in stride(from: 0, to: summaries.count, by: 100) {
                try await runtime.registerInventoryPage(Array(summaries[offset..<min(offset + 100, summaries.count)]))
            }
            if reply.object["hasMore"]?.boolValue == true {
                guard let next = reply.object["cursor"]?.stringValue, seen.insert(next).inserted else { throw AgentIngestionError.malformedFrame }
                cursor = next
            } else { cursor = nil }
        } while cursor != nil
        let digest = SHA256.hash(data: Data(sources.sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard sources.count == config.expectedInventory, digest == config.expectedInventorySHA256
        else { throw AgentIngestionError.malformedFrame }
        measurements["inventoryCount"] = sources.count
        measurements["inventoryNS"] = Self.now()
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        try publish(["inventoryCount": sources.count, "inventoryNS": Self.now(),
                     "appAfterInventoryRSSBytes": Self.residentBytes(),
                     "appAfterInventoryLifetimePeakRSSBytes": usage.ru_maxrss], name: "inventory.json")
    }

    static func visibleTail(thread: AgentThreadID) {
        guard let active, active.threadID == thread, !active.completed, active.displayLink == nil else { return }
        active.measurements["visibleLayoutNS"] = now()
        let link = CADisplayLink(target: active, selector: #selector(displayed))
        active.displayLink = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func displayed() {
        displayTicks += 1
        guard displayTicks >= 2 else { return }
        displayLink?.invalidate(); displayLink = nil; completed = true
        measurements["paintNS"] = Self.now()
        measurements["appPaintRSSBytes"] = Self.residentBytes()
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        measurements["appLifetimePeakRSSBytes"] = usage.ru_maxrss
        measurements["scope"] = "visible transcript tail layout plus two display-link ticks; video verification required"
        do { try publish(measurements, name: "paint.json") }
        catch { model?.reportUnavailable("Private benchmark result could not be recorded") }
    }
}

/// Dedicated queues keep blocking Unix I/O off both the UI actor and Swift's
/// cooperative executor. Shutdown wakes reads; the FD closes only at deinit,
/// after all queued operations have released this object (no FD-reuse race).
private final class AgentColdPageSocket: AppleAgentStreamingExecHandle, @unchecked Sendable {
    private let descriptor: Int32
    private let generation: UInt64
    private let lock = NSLock()
    private var stopped = false
    private let input = DispatchQueue(label: "tessera.private-cold-page.input")
    private let output = DispatchQueue(label: "tessera.private-cold-page.output")
    private init(descriptor: Int32, generation: UInt64) { self.descriptor = descriptor; self.generation = generation }
    deinit { Darwin.close(descriptor) }
    private var closed: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    static func open(path: String, generation: UInt64) async throws -> AgentColdPageSocket {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                var success = false
                defer { if fd >= 0 && !success { Darwin.close(fd) } }
                var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
                let bytes = Array(path.utf8) + [0]
                guard fd >= 0, bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                    NSLog("TESSERA_NATIVE_PAINT socket allocation errno=%d length=%ld", errno, bytes.count)
                    continuation.resume(throwing: AgentIngestionError.malformedFrame); return
                }
                withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
                address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                var noSignal: Int32 = 1
                guard connected == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
                      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    NSLog("TESSERA_NATIVE_PAINT socket connect=%d errno=%d", connected, errno)
                    continuation.resume(throwing: AgentIngestionError.remote("privateBenchmarkSocket")); return
                }
                success = true
                continuation.resume(returning: AgentColdPageSocket(descriptor: fd, generation: generation))
            }
        }
    }
    private func stop() {
        lock.lock(); let first = !stopped; stopped = true; lock.unlock()
        if first { Darwin.shutdown(descriptor, SHUT_RDWR) }
    }
    func cancel() async { stop() }
    func nextFrame() async throws -> AgentExecFrame? {
        try await withCheckedThrowingContinuation { continuation in
            input.async { [self] in
                var bytes = [UInt8](repeating: 0, count: 65536)
                while !closed {
                    var descriptor = pollfd(fd: self.descriptor, events: Int16(POLLIN), revents: 0)
                    let ready = Darwin.poll(&descriptor, 1, 100)
                    if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                    let count = Darwin.read(self.descriptor, &bytes, bytes.count)
                    if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    if count > 0 {
                        continuation.resume(returning: AgentExecFrame(carrierGeneration: generation, kind: .stdout(Data(bytes.prefix(count)))))
                    } else if count == 0 { continuation.resume(returning: nil) }
                    else { continuation.resume(throwing: AgentIngestionError.remote("privateBenchmarkRead")) }
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            output.async { [self] in
                var position = 0
                while !closed && position < data.count {
                    var descriptor = pollfd(fd: self.descriptor, events: Int16(POLLOUT), revents: 0)
                    let ready = Darwin.poll(&descriptor, 1, 100)
                    if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                    let count = data.withUnsafeBytes { Darwin.write(self.descriptor, $0.baseAddress!.advanced(by: position), data.count - position) }
                    if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    guard count > 0 else { continuation.resume(throwing: AgentIngestionError.remote("privateBenchmarkWrite")); return }
                    position += count
                }
                if position == data.count { continuation.resume() }
                else { continuation.resume(throwing: CancellationError()) }
            }
        }
    }
}
#endif
