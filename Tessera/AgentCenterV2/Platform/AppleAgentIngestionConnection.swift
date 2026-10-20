import Foundation
import TesseraCore

@MainActor
private final class AppleAgentSearchDeadline<Value: Sendable> {
    var continuation: CheckedContinuation<Value, Error>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        work?.cancel(); timer?.cancel(); work = nil; timer = nil
        continuation.resume(with: result)
        return true
    }
}

struct AppleAgentIngestionHostKey: Hashable {
    let sessionID: UUID
    let context: String
    init(sessionID: UUID, binding: AgentTerminalBinding? = nil) {
        self.sessionID = sessionID
        if let binding, let pid = binding.agentPID { context = "\(pid):\(binding.incarnation.rawValue)" }
        else { context = "default" }
    }
}

@MainActor
final class AppleAgentIngestionHost {
    let binding: AgentTerminalBinding
    let registrationID: UUID
    let opening: Task<AppleAgentIngestionConnection, Error>
    var connection: AppleAgentIngestionConnection?
    var threads: [AgentThreadID: String] = [:]
    private var handleClaims: [String: AgentThreadID] = [:]
    private var threadClaims: [AgentThreadID: String] = [:]

    func reserveHandles(_ claims: [(AgentThreadID, String)]) throws {
        var handles = handleClaims
        var identities = threadClaims
        for (thread, handle) in claims {
            guard handles[handle].map({ $0 == thread }) ?? true,
                  identities[thread].map({ $0 == handle }) ?? true,
                  threads[thread].map({ $0 == handle }) ?? true
            else { throw AgentIngestionError.malformedFrame }
            handles[handle] = thread
            identities[thread] = handle
        }
        handleClaims = handles
        threadClaims = identities
    }
    var claimedThreads = Set<AgentThreadID>()
    var openingWaiters = Set<UUID>()
    var bootstrapped: Set<AgentThreadID> = []
    var initialPrefetchStarted = Set<AgentThreadID>()
    var metadataTasks: [AgentThreadID: (id: UUID, task: Task<Void, Never>)] = [:]
    var interests: [AgentThreadID: Bool] = [:]
    var interestTask: Task<Void, Never>?
    var interestRevision: UInt64 = 0
    var pausedThreads = Set<AgentThreadID>()

    init(binding: AgentTerminalBinding, registrationID: UUID, factory: AppleAgentStreamingExecFactory, contextPID: Int? = nil, contextScope: String? = nil) {
        self.binding = binding; self.registrationID = registrationID
        opening = Task { try await AppleAgentIngestionConnection.open(factory: factory, binding: binding, contextPID: contextPID, contextScope: contextScope) }
    }

    func close() {
        interestTask?.cancel()
        metadataTasks.values.forEach { $0.task.cancel() }
        metadataTasks.removeAll()
        opening.cancel()
        Task { if let connection = try? await opening.value { await connection.close() } }
    }
}

/// One duplex relay per app-owned host session, shared by all of its threads.
/// SSH authenticates the final destination; the relay authenticates the local
/// service using its private Unix socket and kernel peer identity. No listener,
/// bearer credential, or transcript is exposed on a jump host.
@MainActor
final class AppleAgentIngestionConnection {
    struct Reply {
        var object: [String: AgentJSONValue]
        var page: AgentProjectionPage?
        var inventory: [[String: AgentJSONValue]] = []
    }
    struct WindowCommit { let snapshot: AgentIngestionWindowSnapshot; let accepted: Bool }
    private struct Waiting {
        let continuation: CheckedContinuation<Reply, Error>
        var timeout: Task<Void, Never>?
        let inventoryRequest: Bool
        let controlThread: String?
        let fields: [String: AgentJSONValue]
        let idleDeadline: Duration
        let progressThread: String?
        let onReadStatus: (@MainActor (AgentIngestionReadStatus) -> Void)?
        var deadlineGeneration: UInt64 = 0
        var progressSequence: UInt64 = 0
        var progressBytes: UInt64 = 0
        var subscriptionRevoked = false
        var sendStarted = false
        var inventoryBegan = false
        var inventory: [[String: AgentJSONValue]] = []
        var bytes = 0
    }
    private let handle: any AppleAgentStreamingExecHandle
    private let binding: AgentTerminalBinding
    private var waiting: [String: Waiting] = [:]
    private var framer = AgentIngestionFramer()
    private var pages: AgentIngestionPageDecoder?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var writeTail: Task<Void, Error>?
    private var writeGeneration: UInt64 = 0
    private var queuedWrites = 0
    private var failure: Error?
    private var abandoned: Set<String> = []
    private(set) var epoch: String?
    private(set) var contextScope: String?
    private(set) var supportsPiSessions = false
    private(set) var supportsOpenCodeSessions = false
    private(set) var supportsKimiSessions = false
    private(set) var supportsReadProgress = false
    /// Largest viewport the host accepts in `window.ack`.
    private(set) var maxWindowSegments = AgentIngestionWindowCapacity.legacy.segments
    var isClosed: Bool { failure != nil }
    var onPage: (@MainActor (String, AgentProjectionPage) async -> Bool)?
    var onWindowPage: (@MainActor (String, AgentProjectionPage) async -> WindowCommit?)?
    private var windowLimits: [String: Int] = [:]
    private var pausedWatches: Set<String> = []
    private var activeWatches: Set<String> = []
    private var activeControls: Set<String> = []
    private var subscribedThreads: Set<String> = []
    private struct ReadProgress { let id: String; let sequence: UInt64; let bytes: UInt64 }
    private var displayedReadProgress: [String: ReadProgress] = [:]
    private var watchDrainWrites: [String: (thread: String, bytes: Data)] = [:]
    var onResync: (@MainActor (String) async -> Void)?
    var onCapacity: (@MainActor (String) async -> Void)?
    var onReadStatus: (@MainActor (String, AgentIngestionReadStatus) async -> Void)?
    var onReadComplete: (@MainActor (String) async -> Void)?
    var onSummary: (@MainActor (String, AgentIngestionSummary) async -> Bool)?
    var onHook: (@MainActor (String, AgentIngestionHook) async -> Void)?

    func isSubscribed(_ thread: String) -> Bool { !isClosed && subscribedThreads.contains(thread) }

    private func finishReadProgress(_ id: String, thread: String) async {
        guard displayedReadProgress[thread]?.id == id else { return }
        displayedReadProgress.removeValue(forKey: thread)
        await onReadComplete?(thread)
    }

    private init(handle: any AppleAgentStreamingExecHandle, binding: AgentTerminalBinding) {
        self.handle = handle; self.binding = binding
    }

    static func withSearchDeadline<T: Sendable>(_ duration: Duration = .seconds(30),
        discard: @escaping @Sendable (T) async -> Void = { _ in },
        operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let state = AppleAgentSearchDeadline<T>()
        let result: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.continuation = continuation
                state.work = Task {
                    do {
                        let value = try await operation()
                        if !state.finish(.success(value)) { await discard(value) }
                    } catch { state.finish(.failure(error)) }
                }
                state.timer = Task {
                    do { try await Task.sleep(for: duration) } catch { return }
                    state.finish(.failure(AgentIngestionError.remote("deadlineExceeded")))
                }
            }
        } onCancel: { Task { @MainActor in state.finish(.failure(CancellationError())) } }
        do { try Task.checkCancellation() }
        catch { await discard(result); throw error }
        return result
    }

    static func open(factory: AppleAgentStreamingExecFactory, binding: AgentTerminalBinding, contextPID: Int? = nil, contextScope: String? = nil, openingDeadline: Duration = .seconds(15)) async throws -> AppleAgentIngestionConnection {
        var fields: [String: AgentJSONValue] = ["kind": .string("hello"), "id": .string("hello"), "v": .number(3)]
        if let contextScope {
            guard contextScope.count == 16, contextScope.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw AgentIngestionError.malformedFrame }
            fields["contextScope"] = .string(contextScope)
        } else if let contextPID {
            guard contextPID > 1, contextPID <= Int(Int32.max) else { throw AgentIngestionError.malformedFrame }
            fields["contextPID"] = .number(Decimal(contextPID))
        }
        let hello = try AgentIngestionFramer.encode(.object(fields))
        guard let request = AgentExecRequest(binding: binding, stdin: hello, program: .ingestionHost) else {
            throw AgentIngestionError.malformedFrame
        }
        // The hello deadline starts only after the SSH exec exists. Bound
        // opening too: a blackholed carrier can stall channel admission before
        // it ever provides a handle, retaining every coalesced borrower.
        let handle = try await withSearchDeadline(openingDeadline, discard: { await $0.cancel() }) {
            try await factory.open(request)
        }
        let connection = AppleAgentIngestionConnection(handle: handle, binding: binding)
        connection.startReading()
        do {
            let reply = try await connection.wait(id: "hello")
            guard reply.object["kind"]?.stringValue == "hello",
                  reply.object["v"]?.numberValue == 3,
                  reply.object["capabilities"]?.arrayValue?.contains(.string("bounded.windows")) == true,
                  reply.object["capabilities"]?.arrayValue?.contains(.string("window.partitions")) == true else {
                throw AgentIngestionError.remote("unsupported")
            }
            if let scope = reply.object["contextScope"]?.stringValue, !scope.isEmpty {
                guard scope.count == 16, scope.allSatisfy({ "0123456789abcdef".contains($0) }),
                      contextScope == nil || contextScope == scope else { throw AgentIngestionError.malformedFrame }
                connection.contextScope = scope
            }
            connection.supportsPiSessions = reply.object["capabilities"]?.arrayValue?.contains(.string(AgentPiSessionAdapter.wireCapability)) == true
            connection.supportsOpenCodeSessions = reply.object["capabilities"]?.arrayValue?.contains(.string(AgentOpenCodeSQLiteAdapter.wireCapability)) == true
            connection.supportsKimiSessions = reply.object["capabilities"]?.arrayValue?.contains(.string(AgentKimiWireAdapter.wireCapability)) == true
            connection.supportsReadProgress = reply.object["capabilities"]?.arrayValue?.contains(.string("read.progress.v1")) == true
            connection.maxWindowSegments = helloMaxWindowSegments(reply.object)
            guard (contextPID == nil && contextScope == nil) || connection.contextScope != nil else {
                throw AgentIngestionError.remote("contextScopeUnavailable")
            }
            connection.heartbeat = Task { [weak connection] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(10))
                        guard let connection else { return }
                        _ = try await connection.request(["kind": .string("heartbeat")])
                    } catch {
                        if !Task.isCancelled { await connection?.close(error: error) }
                        return
                    }
                }
            }
            return connection
        } catch { await connection.close(error: error); throw error }
    }

    func request(_ fields: [String: AgentJSONValue], deadline: Duration = .seconds(15),
                 onReadStatus: (@MainActor (AgentIngestionReadStatus) -> Void)? = nil) async throws -> Reply {
        let retryable = ["resolve", "inventory", "window.read", "summary"].contains(fields["kind"]?.stringValue ?? "")
        for attempt in 0...4 {
            do { return try await requestOnce(fields, deadline: deadline, onReadStatus: onReadStatus) }
            catch AgentIngestionError.remote("busy") where retryable && attempt < 4 {
                // Admission rejection only: no transaction was started. Never
                // retry ACKs, controls, arbitrary errors, or terminal actions.
                try await Task.sleep(for: .milliseconds(50 << attempt))
            }
        }
        throw AgentIngestionError.remote("busy")
    }

    private func requestOnce(_ fields: [String: AgentJSONValue], deadline: Duration,
                             onReadStatus: (@MainActor (AgentIngestionReadStatus) -> Void)?) async throws -> Reply {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard waiting.count < 16 else { throw AgentIngestionError.capacityExceeded }
        let control = ["subscribe", "unsubscribe", "window.release"].contains(fields["kind"]?.stringValue ?? "")
            ? fields["thread"]?.stringValue : nil
        if let control, !activeControls.insert(control).inserted { throw AgentIngestionError.remote("controlBusy") }
        let priorWatchPause = control.map { pausedWatches.contains($0) }
        var controlCommitted = false
        defer {
            if let control {
                activeControls.remove(control)
                if !controlCommitted, !isClosed {
                    // An unsent abandonment or explicit remote rejection did
                    // not change the remote watch. Restore its local gate too.
                    if priorWatchPause == true { pausedWatches.insert(control) }
                    else { pausedWatches.remove(control) }
                }
            }
        }
        let id = UUID().uuidString
        var object = fields; object["id"] = .string(id)
        object.removeValue(forKey: "readProgress")
        if supportsReadProgress && ["window.read", "summary", "bootstrap", "history", "updates", "subscribe"].contains(fields["kind"]?.stringValue ?? "") {
            object["readProgress"] = .bool(true)
        }
        if let thread = fields["thread"]?.stringValue {
            if ["unsubscribe", "window.release"].contains(fields["kind"]?.stringValue ?? "") {
                pausedWatches.insert(thread)
            } else if fields["kind"]?.stringValue == "subscribe" {
                pausedWatches.remove(thread)
            }
            if fields["kind"]?.stringValue == "subscribe", fields["interest"]?.stringValue == "fast" {
                object["limit"] = .number(Decimal(windowLimits[thread] ?? 100))
            }
        }
        let bytes = try AgentIngestionFramer.encode(.object(object))
        // Register before writing; a fast local reply can otherwise arrive
        // while the request is suspended in SSH's output backpressure.
        let reply: Reply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(id: id, fields: object, controlThread: control, deadline: deadline,
                    onReadStatus: onReadStatus, continuation: continuation)
                Task { [weak self] in
                    do {
                        let drainThread = ["unsubscribe", "window.release"].contains(fields["kind"]?.stringValue ?? "")
                            ? fields["thread"]?.stringValue : nil
                        try await self?.sendRequest(bytes, id: id, drainThread: drainThread)
                    }
                    catch { await self?.close(error: error) }
                }
            }
        } onCancel: { Task {
            await self.cancelRequest(id)
            if fields["kind"]?.stringValue == "window.read", let thread = fields["thread"]?.stringValue {
                try? await self.cancelWindow(id, thread: thread)
            }
        } }
        do { try Task.checkCancellation() }
        catch {
            // A successful control ACK discarded by caller cancellation still
            // leaves an unowned remote mutation. Retire only this child relay.
            if control != nil { await close(error: error) }
            throw error
        }
        controlCommitted = true
        if fields["kind"]?.stringValue == "window.release", let control { windowLimits.removeValue(forKey: control) }
        return reply
    }

    private func cancelRequest(_ id: String) async {
        watchDrainWrites.removeValue(forKey: id)
        guard let request = waiting.removeValue(forKey: id) else { return }
        request.timeout?.cancel(); request.continuation.resume(throwing: CancellationError())
        if let thread = request.fields["thread"]?.stringValue { await finishReadProgress(id, thread: thread) }
        if request.controlThread != nil, request.sendStarted {
            await close(error: CancellationError())
            return
        }
        abandoned.insert(id)
        if abandoned.count > 128 { await close(error: AgentIngestionError.capacityExceeded) }
    }

    func acknowledge(_ requestID: String) async throws {
        try await send(AgentIngestionFramer.encode(.object([
            "kind": .string("ack"), "id": .string(UUID().uuidString), "requestID": .string(requestID)])))
    }

    func acknowledgeWindow(_ page: AgentProjectionPage, thread: String, snapshot: AgentIngestionWindowSnapshot) async throws {
        guard let range = page.ingestion, range.window?.version == snapshot.version, snapshot.epoch == epoch,
              let head = snapshot.headSegmentID, !snapshot.viewportSegmentIDs.isEmpty,
              snapshot.viewportSegmentIDs.count <= maxWindowSegments else {
            throw AgentIngestionError.staleEpoch
        }
        try await send(AgentIngestionFramer.encode(.object([
            "kind": .string("window.ack"), "id": .string("window_ack_" + UUID().uuidString), "thread": .string(thread),
            "transaction": .string(range.requestID), "windowVersion": .number(Decimal(snapshot.version)),
            "viewport": .array(snapshot.viewportSegmentIDs.map(AgentJSONValue.string)), "head": .string(head)])))
    }

    func cancelWindow(_ transaction: String, thread: String) async throws {
        try await send(AgentIngestionFramer.encode(.object([
            "kind": .string("window.cancel"), "id": .string("window_cancel_" + UUID().uuidString),
            "thread": .string(thread), "transaction": .string(transaction)])))
    }

    func close(error: Error = CancellationError()) async {
        guard failure == nil else { return }
        failure = error; reader?.cancel(); heartbeat?.cancel(); writeTail?.cancel()
        watchDrainWrites.removeAll()
        displayedReadProgress.removeAll(); subscribedThreads.removeAll()
        let pending = waiting; waiting.removeAll()
        for request in pending.values { request.timeout?.cancel(); request.continuation.resume(throwing: error) }
        await handle.cancel()
    }

    /// Hosts without `window.capacity.v1` accept four viewport segments. A
    /// malformed advertisement (string, fraction, missing) never grows the
    /// window: it reads as a legacy host, as on Android. Core clamps the same range.
    nonisolated static func helloMaxWindowSegments(_ hello: [String: AgentJSONValue]) -> Int {
        let legacy = AgentIngestionWindowCapacity.legacy.segments
        guard hello["capabilities"]?.arrayValue?.contains(.string("window.capacity.v1")) == true,
              var advertised = hello["maxWindowSegments"]?.numberValue else { return legacy }
        var integral = Decimal()
        NSDecimalRound(&integral, &advertised, 0, .plain)
        guard integral == advertised else { return legacy }
        let clamped = min(max(advertised, Decimal(legacy)), Decimal(AgentIngestionWindowCapacity.maximumSegments))
        return NSDecimalNumber(decimal: clamped).intValue
    }

    private func wait(id: String) async throws -> Reply {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { register(id: id, continuation: $0) }
        } onCancel: { Task { await self.close(error: CancellationError()) } }
    }

    private func register(id: String, fields: [String: AgentJSONValue] = [:], controlThread: String? = nil,
        deadline: Duration = .seconds(15), onReadStatus: (@MainActor (AgentIngestionReadStatus) -> Void)? = nil,
        continuation: CheckedContinuation<Reply, Error>) {
        if let failure { continuation.resume(throwing: failure); return }
        waiting[id] = Waiting(continuation: continuation, inventoryRequest: fields["kind"]?.stringValue == "inventory",
            controlThread: controlThread, fields: fields, idleDeadline: deadline,
            progressThread: fields["readProgress"]?.boolValue == true && fields["kind"]?.stringValue != "subscribe"
                ? fields["thread"]?.stringValue : nil, onReadStatus: onReadStatus)
        renewIdleDeadline(id)
    }

    private func renewIdleDeadline(_ id: String) {
        guard var request = waiting[id] else { return }
        request.timeout?.cancel()
        request.deadlineGeneration &+= 1
        let generation = request.deadlineGeneration, deadline = request.idleDeadline
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: deadline) } catch { return }
            guard let self, let request = self.waiting[id], request.deadlineGeneration == generation else { return }
            self.waiting.removeValue(forKey: id)
            self.watchDrainWrites.removeValue(forKey: id)
            self.abandoned.insert(id)
            request.continuation.resume(throwing: AgentIngestionError.remote("deadlineExceeded"))
            if let thread = request.fields["thread"]?.stringValue { await self.finishReadProgress(id, thread: thread) }
            if request.controlThread != nil, request.sendStarted {
                await self.close(error: AgentIngestionError.remote("deadlineExceeded"))
                return
            }
            if request.fields["kind"]?.stringValue == "window.read", let thread = request.fields["thread"]?.stringValue {
                try? await self.cancelWindow(id, thread: thread)
            }
            if self.abandoned.count > 128 { await self.close(error: AgentIngestionError.capacityExceeded) }
        }
        request.timeout = timeout
        waiting[id] = request
    }

    private func sendRequest(_ bytes: Data, id: String, drainThread: String? = nil) async throws {
        guard waiting[id] != nil else { return }
        if let drainThread, activeWatches.contains(drainThread) {
            // Registered deadline remains active. Do not block the reader or
            // cancel a watch after Core commit but before its wire ACK.
            watchDrainWrites[id] = (drainThread, bytes)
            return
        }
        try await send(bytes, requestID: id)
    }

    private func finishWatch(_ thread: String) {
        activeWatches.remove(thread)
        let writes = watchDrainWrites.filter { $0.value.thread == thread }
        for (id, write) in writes {
            watchDrainWrites.removeValue(forKey: id)
            Task {
                do { try await sendRequest(write.bytes, id: id) }
                catch { await close(error: error) }
            }
        }
    }

    private func send(_ bytes: Data, requestID: String? = nil) async throws {
        if let failure { throw failure }
        guard queuedWrites < 32 else { throw AgentIngestionError.capacityExceeded }
        queuedWrites += 1
        defer { queuedWrites -= 1 }
        let previous = writeTail
        writeGeneration &+= 1
        let generation = writeGeneration
        let handle = self.handle
        let task = Task {
            try await previous?.value
            try Task.checkCancellation()
            if let requestID {
                // The request may expire while another write owns the SSH
                // channel. Never emit an abandoned control from this queue.
                guard var request = self.waiting[requestID] else { return }
                request.sendStarted = true
                self.waiting[requestID] = request
            }
            try await handle.send(bytes)
        }
        writeTail = task
        defer { if writeGeneration == generation { writeTail = nil } }
        try await task.value
    }

    private func startReading() {
        reader = Task { [weak self] in
            guard let self else { return }
            do {
                while let frame = try await handle.nextFrame() {
                    try Task.checkCancellation()
                    guard frame.carrierGeneration == binding.carrierGeneration else { throw AgentIngestionError.staleEpoch }
                    switch frame.kind {
                    case .stdout(let data):
                        var completed: [Data] = []
                        try framer.append(data) { completed.append($0) }
                        for value in completed { try await receive(value) }
                    case .stderr(let data):
                        if !data.isEmpty { throw AgentIngestionError.remote("helperDiagnostic") }
                    case .exit:
                        try framer.finish(); try pages?.finish()
                        throw AgentIngestionError.remote("disconnected")
                    }
                }
                throw AgentIngestionError.remote("disconnected")
            } catch { await close(error: error) }
        }
    }

    private func receive(_ data: Data) async throws {
        let value = try JSONDecoder().decode(AgentJSONValue.self, from: data)
        guard value.isBounded(), let object = value.objectValue, let kind = object["kind"]?.stringValue,
              let receivedEpoch = object["serviceEpoch"]?.stringValue else { throw AgentIngestionError.malformedFrame }
        if epoch == nil {
            guard kind == "hello", object["id"]?.stringValue == "hello" else { throw AgentIngestionError.malformedFrame }
            pages = try AgentIngestionPageDecoder(epoch: receivedEpoch); epoch = receivedEpoch
        }
        guard epoch == receivedEpoch else { throw AgentIngestionError.staleEpoch }
        if kind == "read.progress" {
            guard supportsReadProgress, let id = object["id"]?.stringValue,
                  let thread = object["thread"]?.stringValue,
                  let sequenceText = object["sequence"]?.stringValue, let sequence = UInt64(sequenceText), String(sequence) == sequenceText,
                  let bytesText = object["bytesRead"]?.stringValue, let bytes = UInt64(bytesText), String(bytes) == bytesText,
                  let rawStatus = object["status"] else { throw AgentIngestionError.malformedFrame }
            let status = try AgentIngestionReadStatus.decode(rawStatus)
            guard status.isProgress else { throw AgentIngestionError.malformedFrame }
            if var request = waiting[id], request.progressThread == thread, request.sendStarted {
                // Replayed progress and unrelated work cannot keep a stalled
                // read alive. No cursor, transaction or ACK changes here.
                guard sequence > request.progressSequence, bytes > request.progressBytes else { return }
                request.progressSequence = sequence; request.progressBytes = bytes
                waiting[id] = request
                renewIdleDeadline(id)
                displayedReadProgress[thread] = .init(id: id, sequence: sequence, bytes: bytes)
                await onReadStatus?(thread, status)
            } else if id.hasPrefix("watch_"), subscribedThreads.contains(thread), !pausedWatches.contains(thread) {
                guard sequence > 0, bytes > 0 else { return }
                if let prior = displayedReadProgress[thread], prior.id == id,
                   sequence <= prior.sequence || bytes <= prior.bytes { return }
                displayedReadProgress[thread] = .init(id: id, sequence: sequence, bytes: bytes)
                await onReadStatus?(thread, status)
            }
            return
        }
        if kind == "read.complete" {
            guard supportsReadProgress, let id = object["id"]?.stringValue, id.hasPrefix("watch_"),
                  let thread = object["thread"]?.stringValue else { throw AgentIngestionError.malformedFrame }
            if subscribedThreads.contains(thread), !pausedWatches.contains(thread) { await finishReadProgress(id, thread: thread) }
            return
        }
        if let id = object["id"]?.stringValue, waiting[id]?.inventoryRequest == true,
           !kind.hasPrefix("inventory."), kind != "error" { throw AgentIngestionError.malformedFrame }
        if kind == "hookPreview" {
            if let thread = object["thread"]?.stringValue,
               let hook = try? AgentIngestionHook.decode(data, epoch: receivedEpoch, thread: thread) {
                await onHook?(thread, hook)
            }
            return
        }
        if kind == "summary", let thread = object["thread"]?.stringValue {
            if let id = object["id"]?.stringValue, abandoned.remove(id) != nil { return }
            let summary = try AgentIngestionSummary.decode(data, epoch: receivedEpoch, thread: thread)
            await finishReadProgress(summary.requestID, thread: thread)
            if let request = waiting.removeValue(forKey: summary.requestID) {
                request.timeout?.cancel()
                _ = await onSummary?(thread, summary)
                request.continuation.resume(returning: Reply(object: object))
                return
            }
            guard summary.requestID.hasPrefix("watch_") else { throw AgentIngestionError.malformedFrame }
            if let onSummary, await onSummary(thread, summary) { try await acknowledge(summary.requestID) }
            else {
                try await send(AgentIngestionFramer.encode(.object(["kind": .string("unsubscribe"),
                    "id": .string(UUID().uuidString), "thread": .string(thread)])))
                await onResync?(thread)
            }
            return
        }
        if kind.hasPrefix("page.") {
            guard let complete = try pages?.accept(data), let id = complete.page.ingestion?.requestID else { return }
            if abandoned.remove(id) != nil { return }
            await finishReadProgress(id, thread: complete.thread)
            if let request = waiting.removeValue(forKey: id) {
                request.timeout?.cancel(); request.continuation.resume(returning: Reply(object: object, page: complete.page))
            } else {
                guard id.hasPrefix("watch_") else { throw AgentIngestionError.malformedFrame }
                if pausedWatches.contains(complete.thread) {
                    if complete.page.ingestion?.window != nil { try await cancelWindow(id, thread: complete.thread) }
                    return
                }
                activeWatches.insert(complete.thread)
                defer { finishWatch(complete.thread) }
                if complete.page.ingestion?.window != nil, let onWindowPage,
                   let commit = await onWindowPage(complete.thread, complete.page) {
                    if commit.accepted { try await acknowledgeWindow(complete.page, thread: complete.thread, snapshot: commit.snapshot) }
                    else {
                        try await cancelWindow(id, thread: complete.thread)
                        if windowLimits[complete.thread] == 1 {
                            try await send(AgentIngestionFramer.encode(.object([
                                "kind": .string("unsubscribe"), "id": .string(UUID().uuidString), "thread": .string(complete.thread)])))
                            await onCapacity?(complete.thread); return
                        }
                        let limit = max(1, (windowLimits[complete.thread] ?? 100) / 2)
                        windowLimits[complete.thread] = limit
                        // Preserve the old viewport and cursor. Smaller head
                        // transactions catch up without a source reset.
                        try await send(AgentIngestionFramer.encode(.object([
                            "kind": .string("subscribe"), "id": .string(UUID().uuidString), "thread": .string(complete.thread),
                            "interest": .string("fast"), "limit": .number(Decimal(limit)), "readProgress": .bool(supportsReadProgress),
                            "windowVersion": .number(Decimal(commit.snapshot.version)),
                            "liveCursor": .string(commit.snapshot.liveCursor ?? "") ])))
                    }
                } else if complete.page.ingestion?.window == nil, let onPage, await onPage(complete.thread, complete.page) {
                    try await acknowledge(id)
                } else {
                    if complete.page.ingestion?.window != nil { try await cancelWindow(id, thread: complete.thread) }
                    // Do not await a reply from inside the reader itself.
                    // Retire just this thread, then let its owner rebootstrap.
                    try await send(AgentIngestionFramer.encode(.object([
                        "kind": .string("unsubscribe"), "id": .string(UUID().uuidString),
                        "thread": .string(complete.thread)])))
                    await onResync?(complete.thread)
                }
            }
            return
        }
        if kind == "resyncRequired", let thread = object["thread"]?.stringValue {
            subscribedThreads.remove(thread)
            let priorProgress = displayedReadProgress.removeValue(forKey: thread)
            for id in Array(waiting.keys) where waiting[id]?.controlThread == thread && waiting[id]?.fields["kind"]?.stringValue == "subscribe" {
                waiting[id]?.subscriptionRevoked = true
            }
            // Host read/index/resource limits are never mobile retention
            // pressure. Keep the native cause and its recovery instruction.
            if let rawStatus = object["status"] {
                let status = try AgentIngestionReadStatus.decode(rawStatus)
                await onReadStatus?(thread, status)
                if status.recovery == .rebootstrap { await onResync?(thread) }
            } else {
                if priorProgress != nil { await onReadComplete?(thread) }
                await onResync?(thread)
            }
            return
        }
        if kind == "window.cancelled", let transaction = object["transaction"]?.stringValue { abandoned.remove(transaction) }
        guard let id = object["id"]?.stringValue else { return }
        if abandoned.contains(id) {
            if kind != "inventory.begin" && kind != "inventory.thread" { abandoned.remove(id) }
            return
        }
        guard var request = waiting[id] else { return }
        if kind.hasPrefix("inventory.") {
            guard request.inventoryRequest else { throw AgentIngestionError.malformedFrame }
            guard request.bytes + data.count + 4 <= 262_144 else { throw AgentIngestionError.capacityExceeded }
            request.bytes += data.count + 4
            switch kind {
            case "inventory.begin":
                guard !request.inventoryBegan else { throw AgentIngestionError.malformedFrame }
                request.inventoryBegan = true; waiting[id] = request; return
            case "inventory.thread":
                guard request.inventoryBegan else { throw AgentIngestionError.malformedFrame }
                guard request.inventory.count < 500 else { throw AgentIngestionError.capacityExceeded }
                request.inventory.append(object); waiting[id] = request; return
            case "inventory.end":
                guard request.inventoryBegan else { throw AgentIngestionError.malformedFrame }
            default: throw AgentIngestionError.malformedFrame
            }
        }
        let errorStatus = kind == "error" ? try object["status"].map(AgentIngestionReadStatus.decode) : nil
        waiting.removeValue(forKey: id); request.timeout?.cancel()
        if kind != "error", let thread = request.controlThread {
            if request.fields["kind"]?.stringValue == "subscribe" {
                if !request.subscriptionRevoked { subscribedThreads.insert(thread) }
            } else {
                subscribedThreads.remove(thread)
                if let progress = displayedReadProgress[thread], progress.id.hasPrefix("watch_") {
                    await finishReadProgress(progress.id, thread: thread)
                }
            }
        }
        if kind == "error" {
            if let status = errorStatus {
                request.onReadStatus?(status)
                if let thread = request.fields["thread"]?.stringValue {
                    displayedReadProgress.removeValue(forKey: thread)
                    await onReadStatus?(thread, status)
                    if status.recovery == .rebootstrap { await onResync?(thread) }
                }
                request.continuation.resume(throwing: AgentIngestionError.remote(status.code))
            } else {
                if let thread = request.fields["thread"]?.stringValue { await finishReadProgress(id, thread: thread) }
                request.continuation.resume(throwing: AgentIngestionError.remote(object["code"]?.stringValue ?? "unknown"))
            }
        }
        else { request.continuation.resume(returning: Reply(object: object, inventory: request.inventory)) }
    }
}
