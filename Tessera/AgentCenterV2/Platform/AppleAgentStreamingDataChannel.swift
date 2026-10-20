import Foundation
import TesseraCore

/// Errors that are intentionally distinct from a provider-side projection
/// error.  In particular, `.streamingExecUnavailable` prevents the Stage 2
/// wiring layer from silently falling back to the one-shot, merged-output
/// command helpers used by Files and shell probes.
enum AppleAgentPlatformError: Error, Equatable, Sendable {
    case staleBinding
    case staleCarrierGeneration
    case cancelled
    case boundedPayloadExceeded
    case streamingExecUnavailable
    case malformedStreamFrame
}

/// Serializes carrier replacement with every Agent Center operation.  Session
/// ownership updates this fence on reconnect, tmux replacement, or a route
/// handoff; callers then fail before opening a side channel or injecting a
/// terminal byte into the old carrier.
actor AppleAgentCarrierFence {
    private var binding: AgentTerminalBinding

    init(binding: AgentTerminalBinding) {
        self.binding = binding
    }

    func replace(with binding: AgentTerminalBinding) {
        self.binding = binding
    }

    func requireCurrent(_ expected: AgentTerminalBinding) throws {
        guard binding == expected else { throw AppleAgentPlatformError.staleBinding }
    }

    func isCurrent(_ expected: AgentTerminalBinding) -> Bool {
        binding == expected
    }
}

/// The only transport distinction the Stage 2 platform layer exposes.  Each
/// case still uses the same bounded exec and terminal-action contracts above:
/// callers select a route from a live binding, then install the matching
/// session-owned factory.  This avoids a projection/action fork per carrier.
enum AppleAgentCarrierRoute: Sendable {
    case sshExec
    case sshTmuxExec
    case moshSideChannel
    case moshTmuxSideChannel

    init(binding: AgentTerminalBinding) {
        switch binding.transport {
        case .ssh: self = .sshExec
        case .sshTmux: self = .sshTmuxExec
        case .mosh: self = .moshSideChannel
        case .moshTmux: self = .moshTmuxSideChannel
        }
    }
}

/// Native side-channel handle.  Implementations must represent a dedicated
/// SSH exec/data channel: cancellation closes this channel only and must not
/// disconnect or write to the interactive agent PTY.
protocol AppleAgentStreamingExecHandle: Sendable {
    /// Frames retain the carrier generation supplied by the session-owned
    /// adapter.  Late stdout/stderr after reconnect is rejected below rather
    /// than accidentally attributed to a replacement carrier.
    func nextFrame() async throws -> AgentExecFrame?
    func cancel() async
    func send(_ data: Data) async throws
}

extension AppleAgentStreamingExecHandle {
    func send(_ data: Data) async throws { throw AppleAgentPlatformError.streamingExecUnavailable }
}

/// Injection point for the SSH, SSH+tmux, mosh, and mosh+tmux adapters.  The
/// owner of the existing LiveSession chooses the genuine side channel; this
/// type deliberately has no overload accepting `executeConnectedCommand` or
/// `FileBridge.exec`, since both are buffered one-shot APIs.
struct AppleAgentStreamingExecFactory: Sendable {
    let open: @Sendable (AgentExecRequest) async throws -> any AppleAgentStreamingExecHandle

    init(open: @escaping @Sendable (AgentExecRequest) async throws -> any AppleAgentStreamingExecHandle) {
        self.open = open
    }
}

/// Portable-core exec port backed by a bounded Apple streaming side channel.
/// The factory is supplied by session-owned code, keeping all concrete
/// transport distinctions at side-channel acquisition rather than in the
/// projection reducer.
actor AppleAgentStreamingExecPort: AgentRemoteExecPort {
    private let fence: AppleAgentCarrierFence
    private let factory: AppleAgentStreamingExecFactory

    init(binding: AgentTerminalBinding, factory: AppleAgentStreamingExecFactory) {
        fence = AppleAgentCarrierFence(binding: binding)
        self.factory = factory
    }

    func replaceBinding(_ binding: AgentTerminalBinding) async {
        await fence.replace(with: binding)
    }

    func execute(_ request: AgentExecRequest) async throws -> AgentExecStream {
        try Task.checkCancellation()
        try await fence.requireCurrent(request.binding)
        let handle = try await factory.open(request)
        do {
            try Task.checkCancellation()
            try await fence.requireCurrent(request.binding)
        } catch {
            await handle.cancel()
            throw error
        }
        return AppleAgentExecStream(fence: fence, expectedBinding: request.binding, handle: handle)
    }
}

private final class AppleAgentExecStream: @unchecked Sendable, AgentExecStream {
    private let fence: AppleAgentCarrierFence
    private let expectedBinding: AgentTerminalBinding
    private let handle: any AppleAgentStreamingExecHandle

    init(
        fence: AppleAgentCarrierFence,
        expectedBinding: AgentTerminalBinding,
        handle: any AppleAgentStreamingExecHandle
    ) {
        self.fence = fence
        self.expectedBinding = expectedBinding
        self.handle = handle
    }

    func nextFrame() async throws -> AgentExecFrame? {
        if Task.isCancelled {
            await handle.cancel()
            throw AppleAgentPlatformError.cancelled
        }
        try await fence.requireCurrent(expectedBinding)
        guard let frame = try await handle.nextFrame() else { return nil }
        guard frame.carrierGeneration == expectedBinding.carrierGeneration else {
            await handle.cancel()
            throw AppleAgentPlatformError.staleCarrierGeneration
        }
        try await fence.requireCurrent(expectedBinding)
        return frame
    }

    func cancel() async {
        await handle.cancel()
    }
}

/// A typed, streaming projection endpoint.  Provider command framing and
/// decoding live behind this endpoint so no projection read ever goes through
/// the interactive agent terminal.
struct AppleAgentProjectionEndpoint: Sendable {
    let inventory: @Sendable (AgentProjectionRequest, AgentTerminalBinding) async throws -> AsyncThrowingStream<AgentProjectionPage, Error>
    let project: @Sendable (AgentProjectionRequest, AgentTerminalBinding) async throws -> AsyncThrowingStream<AgentProjectionPage, Error>
    let search: @Sendable (AgentProjectionRequest, AgentTerminalBinding) async throws -> AsyncThrowingStream<AgentSearchResult, Error>
}

extension AppleAgentProjectionEndpoint {
    /// Builds the projector protocol directly on the bounded split-stream exec
    /// port. The remote program emits NDJSON frames, which may be split at any
    /// byte boundary by SSH; this decoder therefore owns framing and all
    /// response-size limits instead of assuming one stdout callback per line.
    static func projector(
        exec: any AgentRemoteExecPort,
        searchThreadID: AgentThreadID? = nil
    ) -> Self {
        Self(
            inventory: { request, binding in
                try await AppleAgentProjectorDecoder.pages(
                    request: request,
                    binding: binding,
                    exec: exec,
                    acceptInventory: true
                )
            },
            project: { request, binding in
                try await AppleAgentProjectorDecoder.pages(
                    request: request,
                    binding: binding,
                    exec: exec,
                    acceptInventory: false
                )
            },
            search: { request, binding in
                guard let searchThreadID else { throw AgentProjectionError.unsupported }
                return try await AppleAgentProjectorDecoder.searchResults(
                    request: request,
                    binding: binding,
                    threadID: searchThreadID,
                    exec: exec
                )
            }
        )
    }
}

private enum AppleAgentProjectorDecoder {
    private struct Frame: Decodable {
        let version: Int
        let kind: String
        let sourceIdentity: String?
        let from: String?
        let sequence: UInt64?
        let recordID: String?
        let sourceOffset: UInt64?
        let sourceHash: String?
        let record: AgentJSONValue?
        let cursor: String?
        let hasMore: Bool?
        let error: AgentProjectionError?
        let excerpt: String?
        let provider: String?
        let providerSessionID: String?
        let transcriptRef: String?
        let lastActivityNs: UInt64?
        let size: UInt64?
        let summary: AgentJSONValue?

        private enum CodingKeys: String, CodingKey {
            case version = "v"
            case kind, sourceIdentity, from, sequence, recordID, record, cursor, sourceOffset, sourceHash
            case hasMore, error, excerpt, provider, providerSessionID, transcriptRef, lastActivityNs, size, summary
        }
    }

    static func pages(
        request: AgentProjectionRequest,
        binding: AgentTerminalBinding,
        exec: any AgentRemoteExecPort,
        acceptInventory: Bool
    ) async throws -> AsyncThrowingStream<AgentProjectionPage, Error> {
        let frames = try await decode(request: request, binding: binding, exec: exec)
        var sourceIdentity: String?
        var from: String?
        var records: [AgentProjectionRecord] = []
        var cursor: String?
        var hasMore = false
        var summary: AgentJSONValue?
        var didEnd = false

        for frame in frames {
            switch frame.kind {
            case "page":
                guard !didEnd, !acceptInventory, sourceIdentity == nil,
                      let identity = frame.sourceIdentity else {
                    throw AppleAgentPlatformError.malformedStreamFrame
                }
                sourceIdentity = identity
                from = frame.from
                summary = frame.summary
            case "record":
                guard !didEnd, !acceptInventory,
                      let sequence = frame.sequence,
                      let recordID = frame.recordID,
                      let record = frame.record,
                      let value = AgentProjectionRecord(
                          sequence: sequence,
                          recordID: recordID,
                          record: record,
                          sourceOffset: frame.sourceOffset, sourceHash: frame.sourceHash
                      ) else { throw AppleAgentPlatformError.malformedStreamFrame }
                records.append(value)
            case "inventory":
                guard !didEnd, acceptInventory,
                      let sequence = frame.sequence,
                      let transcriptRef = frame.transcriptRef,
                      let provider = frame.provider,
                      provider == request.providerID.rawValue,
                      let providerSessionID = frame.providerSessionID,
                      let record = AgentProjectionRecord(
                          sequence: sequence,
                          recordID: transcriptRef,
                          record: .object([
                              "type": .string("inventory"),
                              "provider": .string(provider),
                              "providerSessionID": .string(providerSessionID),
                              "transcriptRef": .string(transcriptRef),
                              "lastActivityNs": frame.lastActivityNs.map { .number(Decimal($0)) } ?? .null,
                              "size": frame.size.map { .number(Decimal($0)) } ?? .null,
                          ])
                      ) else { throw AppleAgentPlatformError.malformedStreamFrame }
                records.append(record)
            case "end":
                guard !didEnd else { throw AppleAgentPlatformError.malformedStreamFrame }
                didEnd = true
                cursor = frame.cursor
                hasMore = frame.hasMore ?? false
            case "error":
                throw frame.error ?? AgentProjectionError.malformed
            default:
                throw AppleAgentPlatformError.malformedStreamFrame
            }
        }

        guard didEnd, acceptInventory || sourceIdentity != nil else {
            throw AppleAgentPlatformError.malformedStreamFrame
        }
        let identity = sourceIdentity ?? "inventory:\(request.providerID.rawValue)"
        guard let page = AgentProjectionPage(
            sourceIdentity: identity,
            from: from,
            to: cursor,
            records: records,
            cursor: cursor,
            hasMore: hasMore,
            summary: summary
        ) else { throw AppleAgentPlatformError.malformedStreamFrame }
        return one(page)
    }

    static func searchResults(
        request: AgentProjectionRequest,
        binding: AgentTerminalBinding,
        threadID: AgentThreadID,
        exec: any AgentRemoteExecPort
    ) async throws -> AsyncThrowingStream<AgentSearchResult, Error> {
        let frames = try await decode(request: request, binding: binding, exec: exec)
        var results: [AgentSearchResult] = []
        var didEnd = false
        for frame in frames {
            switch frame.kind {
            case "searchResult":
                guard !didEnd, let recordID = frame.recordID, let excerpt = frame.excerpt else {
                    throw AppleAgentPlatformError.malformedStreamFrame
                }
                results.append(.init(threadID: threadID, recordID: recordID, excerpt: excerpt))
            case "end":
                guard !didEnd else { throw AppleAgentPlatformError.malformedStreamFrame }
                didEnd = true
            case "error": throw frame.error ?? AgentProjectionError.malformed
            default: throw AppleAgentPlatformError.malformedStreamFrame
            }
        }
        guard didEnd else { throw AppleAgentPlatformError.malformedStreamFrame }
        return AsyncThrowingStream { continuation in
            results.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    private static func decode(
        request: AgentProjectionRequest,
        binding: AgentTerminalBinding,
        exec: any AgentRemoteExecPort
    ) async throws -> [Frame] {
        var stdin = try JSONEncoder().encode(request)
        stdin.append(0x0A)
        guard let execRequest = AgentExecRequest(binding: binding, stdin: stdin) else {
            throw AgentProjectionError.malformed
        }
        let stream = try await exec.execute(execRequest)
        var stdout = Data()
        var stderrBytes = 0
        var exitStatus: Int32?
        do {
            while let frame = try await stream.nextFrame() {
                switch frame.kind {
                case .stdout(let data):
                    guard stdout.count + data.count <= AgentProjectionRequest.maximumBytes else {
                        throw AppleAgentPlatformError.boundedPayloadExceeded
                    }
                    stdout.append(data)
                case .stderr(let data):
                    stderrBytes += data.count
                    guard stderrBytes <= AgentExecFrame.maximumDiagnosticBytes else {
                        throw AppleAgentPlatformError.boundedPayloadExceeded
                    }
                case .exit(let status):
                    exitStatus = status
                }
            }
        } catch {
            await stream.cancel()
            throw error
        }

        let lines = stdout.split(separator: 0x0A, omittingEmptySubsequences: true)
        let diagnosticFields = AgentProjectionDiagnostics.errorFields(stdout: stdout)
        if !diagnosticFields.isEmpty {
            let detail = diagnosticFields.keys.sorted().map { "\($0)=\(diagnosticFields[$0]!)" }.joined(separator: " ")
            DiagnosticLogStore.appendAgentCenter("v2-projector-failure provider=\(request.providerID.rawValue) \(detail)")
        }
        guard !lines.isEmpty, lines.allSatisfy({ $0.count <= AgentExecFrame.maximumFrameBytes }) else {
            throw AppleAgentPlatformError.malformedStreamFrame
        }
        let decoder = JSONDecoder()
        let frames = try lines.map { line -> Frame in
            let frame = try decoder.decode(Frame.self, from: Data(line))
            guard frame.version == 1 else { throw AgentProjectionError.adapterOutdated }
            return frame
        }
        if let error = frames.compactMap(\.error).first { throw error }
        guard exitStatus == 0 else { throw AgentProjectionError.channelUnavailable }
        return frames
    }

    private static func one<Element: Sendable>(
        _ element: Element
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(element)
            continuation.finish()
        }
    }
}

/// Bridges a carrier-fenced Apple data channel to the portable projection
/// ports.  The returned streams cancel their producer when their consumer is
/// cancelled or goes away, so projector cancellation closes only its data
/// channel.
actor AppleAgentRemoteDataChannel: AgentRemoteDataChannel {
    private let fence: AppleAgentCarrierFence
    private var binding: AgentTerminalBinding
    private let endpoint: AppleAgentProjectionEndpoint

    init(binding: AgentTerminalBinding, endpoint: AppleAgentProjectionEndpoint) {
        fence = AppleAgentCarrierFence(binding: binding)
        self.binding = binding
        self.endpoint = endpoint
    }

    func replaceBinding(_ replacement: AgentTerminalBinding) async {
        binding = replacement
        await fence.replace(with: replacement)
    }

    func inventory(_ request: AgentProjectionRequest) async throws -> AsyncThrowingStream<AgentProjectionPage, Error> {
        guard request.kind == .inventory else { throw AgentProjectionError.malformed }
        return try await guardedPages(request, open: endpoint.inventory)
    }

    func project(_ request: AgentProjectionRequest) async throws -> AsyncThrowingStream<AgentProjectionPage, Error> {
        guard request.kind == .project else { throw AgentProjectionError.malformed }
        return try await guardedPages(request, open: endpoint.project)
    }

    func search(_ request: AgentProjectionRequest) async throws -> AsyncThrowingStream<AgentSearchResult, Error> {
        guard request.kind == .search else { throw AgentProjectionError.malformed }
        let expectedBinding = binding
        try await fence.requireCurrent(expectedBinding)
        let source = try await endpoint.search(request, expectedBinding)
        return guarded(source) { result in
            try await self.fence.requireCurrent(expectedBinding)
            guard result.excerpt.utf8.count <= 16_384 else { throw AppleAgentPlatformError.boundedPayloadExceeded }
            return result
        }
    }

    private func guardedPages(
        _ request: AgentProjectionRequest,
        open: @escaping @Sendable (AgentProjectionRequest, AgentTerminalBinding) async throws -> AsyncThrowingStream<AgentProjectionPage, Error>
    ) async throws -> AsyncThrowingStream<AgentProjectionPage, Error> {
        let expectedBinding = binding
        try await fence.requireCurrent(expectedBinding)
        let source = try await open(request, expectedBinding)
        return guarded(source) { page in
            try await self.fence.requireCurrent(expectedBinding)
            guard page.records.count <= request.limitRecords else { throw AppleAgentPlatformError.boundedPayloadExceeded }
            let encodedSize = try JSONEncoder().encode(page).count
            guard encodedSize <= request.limitBytes else { throw AppleAgentPlatformError.boundedPayloadExceeded }
            return page
        }
    }

    private nonisolated func guarded<Element: Sendable>(
        _ source: AsyncThrowingStream<Element, Error>,
        validate: @escaping @Sendable (Element) async throws -> Element
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await element in source {
                        try Task.checkCancellation()
                        continuation.yield(try await validate(element))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
